import AppKit
import AudioToolbox
import Combine
import CoreAudio
import CoreWLAN
import IOKit
import IOKit.ps
import Network
import OrbitBarCore

/// Reads the current system state without requesting location or microphone access.
@MainActor
final class StatusMonitor: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot
    /// Fired after storing a changed actual HAL output, never for volume,
    /// accessory battery, or presentation-only classification changes.
    var onAudioOutputChange: ((AudioState) -> Void)?

    private let pathMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "app.orbitbar.network", qos: .utility)
    private var networkPath: NWPath?
    private var timer: Timer?
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var audioObservers: [AudioObservation] = []
    private var observedDevice: AudioDeviceID = kAudioObjectUnknown
    private var observedChannels: [AudioObjectPropertyElement] = []
    private var observedStreams: [AudioStreamID] = []
    private var isRunning = false
    private var hasStopped = false
    private var isSleeping = false
    private var pendingAudioRefresh: Task<Void, Never>?
    private var outputRefreshRetries: Task<Void, Never>?
    private var outputRetryPlan = AudioOutputRetryPlan()
    private var currentDevice: AudioDeviceID = kAudioObjectUnknown
    private var currentOutputIdentifier: String?
    private var fallbackMute: (device: AudioDeviceID, volume: Double)?
    private var channelBalance = ChannelVolumeBalance()
    private var audioBluetoothCoordinator = AudioBluetoothCoordinator()
    private var cachedBatteryHealth: (cycles: Int?, percent: Int?) = (nil, nil)
    private var batteryHealthReadAt: TimeInterval?

    init(automaticStart: Bool = true) {
        snapshot = SystemSnapshot()
        refresh()
        if automaticStart { start() }
    }

    func refresh() {
        guard !hasStopped, !isSleeping else { return }
        cancelPendingAudioRefresh()
        var updated = snapshot
        updated.battery = readBattery()
        updated.network = readNetwork()
        let audioUpdate = audioBluetoothCoordinator.updateAudio(readAudio())
        updated.audio = audioUpdate.audio
        publish(updated, outputIdentityChanged: audioUpdate.outputIdentityChanged)
    }

    func updateBluetooth(_ state: BluetoothState) {
        guard !hasStopped, state != snapshot.bluetooth else { return }
        let bluetoothUpdate = audioBluetoothCoordinator.updateBluetooth(state)
        let audioUpdate = bluetoothUpdate.requiresAudioRefresh
            ? audioBluetoothCoordinator.updateAudio(readAudio()) : bluetoothUpdate
        var updated = snapshot
        updated.bluetooth = state
        updated.audio = audioUpdate.audio
        if bluetoothUpdate.connectionMembershipChanged { scheduleOutputRefreshRetries() }
        publish(updated, outputIdentityChanged: audioUpdate.outputIdentityChanged)
    }

    private func publish(_ updated: SystemSnapshot, outputIdentityChanged: Bool) {
        if updated != snapshot { snapshot = updated }
        // @Published emits before storing its new value. Invoke the bridge only
        // after assignment so an accessory refresh observes the new HAL route.
        if outputIdentityChanged, isRunning, !isSleeping, !hasStopped {
            onAudioOutputChange?(snapshot.audio)
        }
    }

    private func prepareDevice(_ device: AudioDeviceID, identifier: String?) {
        if device != currentDevice || identifier != currentOutputIdentifier {
            currentDevice = device
            currentOutputIdentifier = identifier
            fallbackMute = nil
            channelBalance.reset()
        }
    }

    private func readAudio(device: AudioDeviceID? = nil) -> AudioState {
        let device = device ?? AudioHardware.defaultOutputDevice()
        let channels = AudioHardware.outputChannels(device: device)
        let streams = AudioHardware.outputStreams(device: device)
        let route = AudioHardware.readRoute(device: device, channels: channels, streams: streams)
        prepareDevice(device, identifier: route.identifier)
        if isRunning, device != observedDevice || channels != observedChannels || streams != observedStreams {
            if device == observedDevice, channels != observedChannels || streams != observedStreams {
                fallbackMute = nil
                channelBalance.reset()
            }
            observeOutputDevice(device, channels: channels, streams: streams)
        }
        var audio = AudioHardware.readState(device: device, channels: channels, route: route)
        if let saved = fallbackMute {
            if saved.device == device, audio.volume == 0 {
                // A volume-only device has no HAL mute flag. Preserve the logical
                // mute state while this application's saved mute is still active.
                audio.isMuted = true
            } else {
                // A device switch or an external volume change invalidates the
                // saved mute; restoring it later would override the user's choice.
                fallbackMute = nil
            }
        }
        return audio
    }

    private func refreshAudio() {
        guard !hasStopped, !isSleeping else { return }
        cancelPendingAudioRefresh()
        let audioUpdate = audioBluetoothCoordinator.updateAudio(readAudio())
        var updated = snapshot
        updated.audio = audioUpdate.audio
        publish(updated, outputIdentityChanged: audioUpdate.outputIdentityChanged)
    }

    private func scheduleAudioRefresh() {
        guard isRunning, !isSleeping, pendingAudioRefresh == nil else { return }
        // HAL may publish a separate event for each channel and for virtual main
        // volume. Read once per burst; direct slider writes still update immediately.
        pendingAudioRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self, self.isRunning, !self.isSleeping else { return }
            self.refreshAudio()
        }
    }

    private func cancelPendingAudioRefresh() {
        pendingAudioRefresh?.cancel()
        pendingAudioRefresh = nil
    }

    private func scheduleOutputRefreshRetries() {
        cancelOutputRefreshRetries()
        guard isRunning, !isSleeping, !hasStopped else { return }
        outputRetryPlan.schedule(at: ProcessInfo.processInfo.systemUptime)
        let generation = outputRetryPlan.generation
        outputRefreshRetries = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.outputRetryPlan.nextDelay(at: ProcessInfo.processInfo.systemUptime, for: generation) else { break }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, let self, self.isRunning, !self.isSleeping, !self.hasStopped,
                      self.outputRetryPlan.generation == generation else { return }
                self.refreshAudio()
            }
            if let self, self.outputRetryPlan.generation == generation { self.outputRefreshRetries = nil }
        }
    }

    private func cancelOutputRefreshRetries() {
        outputRefreshRetries?.cancel()
        outputRefreshRetries = nil
        outputRetryPlan.cancel()
    }

    @discardableResult
    func setVolume(_ value: Double, expectedDeviceID: UInt32? = nil,
                   expectedOutputIdentifier: String? = nil) -> Bool {
        guard value.isFinite, !isSleeping, !hasStopped, snapshot.audio.canSetVolume else { return false }
        let device = AudioHardware.defaultOutputDevice()
        let route = AudioHardware.readRoute(device: device)
        let expected = expectedDeviceID ?? snapshot.audio.outputDeviceID
        let identifier = expectedOutputIdentifier ?? snapshot.audio.outputIdentifier
        guard route.isAlive, AudioBluetoothCoordinator.permitsControl(
            audio: AudioState(outputUID: route.uid, outputKind: route.kind), bluetooth: snapshot.bluetooth
        ), AudioOutputIdentity.permitsWrite(
            expectedDeviceID: expected, expectedIdentifier: identifier,
            currentDeviceID: device, currentIdentifier: route.identifier
        ) else { refreshAudio(); return false }
        prepareDevice(device, identifier: route.identifier)
        let clamped = min(1, max(0, value))
        let succeeded = AudioHardware.setVolume(clamped, device: device, balance: &channelBalance)
        if succeeded {
            fallbackMute = nil
            if clamped > 0 { _ = AudioHardware.setMuted(false, device: device) }
        }
        // Failed writes must read back actual state, too. This prevents the panel
        // from retaining a slider value that the output device refused.
        refreshAudio()
        return succeeded
    }

    @discardableResult
    func toggleMute(expectedDeviceID: UInt32? = nil, expectedOutputIdentifier: String? = nil) -> Bool {
        guard !isSleeping, !hasStopped, snapshot.audio.canSetMute else { return false }
        let device = AudioHardware.defaultOutputDevice()
        let route = AudioHardware.readRoute(device: device)
        guard route.isAlive, AudioBluetoothCoordinator.permitsControl(
            audio: AudioState(outputUID: route.uid, outputKind: route.kind), bluetooth: snapshot.bluetooth
        ), AudioOutputIdentity.permitsWrite(
            expectedDeviceID: expectedDeviceID ?? snapshot.audio.outputDeviceID,
            expectedIdentifier: expectedOutputIdentifier ?? snapshot.audio.outputIdentifier,
            currentDeviceID: device, currentIdentifier: route.identifier
        ) else { refreshAudio(); return false }
        let state = readAudio(device: device)
        var succeeded = false
        if AudioHardware.canSetMuted(device: device) {
            if AudioHardware.setMuted(!state.isMuted, device: device) {
                fallbackMute = nil
                succeeded = true
            }
        } else if state.canSetVolume, !state.isMuted || fallbackMute != nil {
            // Some devices expose a volume control but no hardware mute control.
            if let saved = fallbackMute, saved.device == device, state.volume == 0 {
                if AudioHardware.setVolume(saved.volume, device: device, balance: &channelBalance) {
                    fallbackMute = nil
                    succeeded = true
                }
            } else if state.volume > 0 {
                if AudioHardware.setVolume(0, device: device, balance: &channelBalance) {
                    fallbackMute = (device, state.volume)
                    succeeded = true
                }
            }
        }
        refreshAudio()
        return succeeded
    }

    /// Called when the application terminates. Removing listeners prevents stale callbacks.
    func stop() {
        hasStopped = true
        audioBluetoothCoordinator.stop()
        onAudioOutputChange = nil
        cancelOutputRefreshRetries()
        guard isRunning else { return }
        isRunning = false
        cancelPendingAudioRefresh()
        timer?.invalidate()
        timer = nil
        pathMonitor.cancel()
        pathMonitor.pathUpdateHandler = nil
        for (center, observer) in notificationObservers { center.removeObserver(observer) }
        notificationObservers.removeAll()
        removeAudioObservers()
        observedDevice = kAudioObjectUnknown
        observedChannels.removeAll()
        observedStreams.removeAll()
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.networkPath = path
                if !self.isSleeping { self.refresh() }
            }
        }
        pathMonitor.start(queue: networkQueue)

        startPolling()
        observeNotification(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter)
        observeNotification(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter)
        observeNotification(.NSProcessInfoPowerStateDidChange, center: .default)
        addAudioObserver(
            object: AudioObjectID(kAudioObjectSystemObject),
            address: AudioHardware.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        )
        addAudioObserver(object: AudioObjectID(kAudioObjectSystemObject),
                         address: AudioHardware.address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal))
        observeOutputDevice(AudioHardware.defaultOutputDevice())
        refresh()
    }

    private func startPolling() {
        guard timer == nil, isRunning, !isSleeping else { return }
        timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, !self.isSleeping else { return }
                self.refresh()
            }
        }
        if let timer {
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func observeNotification(_ name: Notification.Name, center: NotificationCenter) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                if name == NSWorkspace.willSleepNotification {
                    self.isSleeping = true
                    self.audioBluetoothCoordinator.setSleeping(true)
                    self.timer?.invalidate()
                    self.timer = nil
                    self.cancelPendingAudioRefresh()
                    self.cancelOutputRefreshRetries()
                    return
                }
                if name == NSWorkspace.didWakeNotification {
                    self.isSleeping = false
                    self.audioBluetoothCoordinator.setSleeping(false)
                    self.batteryHealthReadAt = nil
                    self.startPolling()
                }
                guard !self.isSleeping else { return }
                self.refresh()
            }
        }
        notificationObservers.append((center, observer))
    }

    private func observeOutputDevice(_ device: AudioDeviceID, channels: [AudioObjectPropertyElement]? = nil,
                                     streams: [AudioStreamID]? = nil) {
        removeAudioObservers(onlyDevice: true)
        observedDevice = device
        observedChannels = channels ?? AudioHardware.outputChannels(device: device)
        observedStreams = streams ?? AudioHardware.outputStreams(device: device)
        guard device != kAudioObjectUnknown else { return }
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain)] + observedChannels {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute,
                             kAudioDevicePropertyDataSource, kAudioDevicePropertyJackIsConnected] {
                addAudioObserver(object: device, address: AudioHardware.address(selector, element: element))
            }
        }
        addAudioObserver(object: device, address: AudioHardware.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume))
        addAudioObserver(object: device, address: AudioHardware.address(kAudioDevicePropertyStreamConfiguration))
        addAudioObserver(object: device, address: AudioHardware.address(kAudioDevicePropertyStreams))
        for selector in [kAudioObjectPropertyName, kAudioDevicePropertyDeviceIsAlive,
                         kAudioDevicePropertyTransportType, kAudioDevicePropertyDeviceUID] {
            addAudioObserver(object: device, address: AudioHardware.address(selector, scope: kAudioObjectPropertyScopeGlobal))
        }
        for stream in observedStreams {
            for selector in [kAudioStreamPropertyTerminalType, kAudioStreamPropertyIsActive] {
                addAudioObserver(object: stream, address: AudioHardware.address(selector, scope: kAudioObjectPropertyScopeGlobal))
            }
        }
    }

    private func addAudioObserver(object: AudioObjectID, address: AudioObjectPropertyAddress) {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.scheduleAudioRefresh()
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            audioObservers.append(AudioObservation(object: object, address: address, block: block))
        }
    }

    private func removeAudioObservers(onlyDevice: Bool = false) {
        let removed = audioObservers.filter { !onlyDevice || $0.object != AudioObjectID(kAudioObjectSystemObject) }
        for observer in removed {
            var address = observer.address
            AudioObjectRemovePropertyListenerBlock(observer.object, &address, .main, observer.block)
        }
        if onlyDevice {
            audioObservers.removeAll { $0.object != AudioObjectID(kAudioObjectSystemObject) }
        } else {
            audioObservers.removeAll()
        }
    }

    private func readNetwork() -> NetworkState {
        let client = CWWiFiClient.shared()
        let interfaces = client.interfaces() ?? []
        guard let path = networkPath else {
            // Before NWPathMonitor's initial callback, use association data only.
            if let interface = interfaces.first(where: { $0.powerOn() && $0.rssiValue() < 0 }) {
                return wifiState(interface)
            }
            return NetworkState()
        }
        guard path.status == .satisfied else { return NetworkState() }
        // A wired path should win when Ethernet and Wi-Fi are both available.
        if path.usesInterfaceType(.wiredEthernet) {
            return NetworkState(kind: .ethernet, signalLevel: 3, name: "以太网")
        }
        if path.usesInterfaceType(.wifi) {
            let activeNames = Set(path.availableInterfaces.filter { $0.type == .wifi }.map(\.name))
            let interface = interfaces.first { activeNames.contains($0.interfaceName ?? "") && $0.powerOn() }
                ?? interfaces.first { $0.powerOn() && $0.rssiValue() < 0 }
            return interface.map(wifiState) ?? NetworkState(kind: .wifi, signalLevel: 0)
        }
        return NetworkState(kind: .other, signalLevel: 3, name: "已连接")
    }

    private func wifiState(_ interface: CWInterface) -> NetworkState {
        let rssi = interface.rssiValue()
        // CoreWLAN returns zero when signal strength is unavailable. Do not turn
        // that sentinel into a misleading full-strength indicator.
        let level: Int
        if rssi >= 0 { level = 0 }
        else if rssi >= -60 { level = 3 }
        else if rssi >= -75 { level = 2 }
        else { level = 1 }
        // macOS may redact the SSID without location permission; it is optional.
        return NetworkState(kind: .wifi, signalLevel: level, name: interface.ssid())
    }

    private func readBattery() -> BatteryState {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryState(isLowPowerMode: lowPower)
        }
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue(),
                  let details = raw as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  (details[kIOPSIsPresentKey] as? NSNumber)?.boolValue != false else { continue }
            let current = (details[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (details[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let percent = SystemReadingNormalization.batteryPercent(current: current, maximum: maximum)
            let charging = (details[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
            let onBattery = details[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let externalPower = details[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let remaining = (details[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue
            let health = batteryHealth()
            return BatteryState(
                isPresent: true,
                percent: percent,
                isCharging: charging,
                isExternalPower: externalPower,
                isLowPowerMode: lowPower,
                minutesRemaining: SystemReadingNormalization.minutesRemaining(remaining, onBattery: onBattery, charging: charging),
                cycleCount: health.cycles,
                healthPercent: health.percent
            )
        }
        // Mac desktops and machines without an internal battery use a neutral ring.
        return BatteryState(isExternalPower: true, isLowPowerMode: lowPower)
    }

    private func batteryHealth() -> (cycles: Int?, percent: Int?) {
        let now = ProcessInfo.processInfo.systemUptime
        if let readAt = batteryHealthReadAt, now - readAt < 300 { return cachedBatteryHealth }
        cachedBatteryHealth = Self.readBatteryHealth()
        batteryHealthReadAt = now
        return cachedBatteryHealth
    }

    private static func readBatteryHealth() -> (cycles: Int?, percent: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return (nil, nil) }
        let cycleReading = (values["CycleCount"] as? NSNumber)?.intValue
        let cycles = cycleReading.flatMap { $0 >= 0 ? $0 : nil }
        let design = (values["DesignCapacity"] as? NSNumber)?.doubleValue
        // Registry capacity keys vary by hardware. MaxCapacity can be a 0...100
        // percentage on Apple Silicon, so use it only when it contains mAh.
        let percent = SystemReadingNormalization.healthPercent(
            design: design,
            nominal: (values["NominalChargeCapacity"] as? NSNumber)?.doubleValue,
            raw: (values["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue,
            legacy: (values["MaxCapacity"] as? NSNumber)?.doubleValue
        )
        return (cycles, percent)
    }
}

private struct AudioObservation {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}

private struct AudioRoute {
    let isAlive: Bool
    let name: String
    let uid: String?
    let identifier: String?
    let kind: AudioOutputKind
}

/// HAL output properties are read directly; no recording session is opened.
private enum AudioHardware {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        readUInt32(object: AudioObjectID(kAudioObjectSystemObject),
                   address: address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal))
            ?? kAudioObjectUnknown
    }

    static func readState(device: AudioDeviceID, channels: [AudioObjectPropertyElement], route: AudioRoute) -> AudioState {
        guard device != kAudioObjectUnknown, route.isAlive else { return AudioState() }
        // A property can exist while a hot-plugged device temporarily refuses the
        // read. Try virtual main and channels before displaying an artificial zero.
        let mainVolume = readFloat(object: device, address: address(kAudioDevicePropertyVolumeScalar))
        let volume = mainVolume ?? readVirtualMainVolume(device: device)
            ?? channels.compactMap { readFloat(object: device, address: address(kAudioDevicePropertyVolumeScalar, element: $0)) }.max()
            ?? 0
        let muteAddresses = readableAddresses(device: device, selector: kAudioDevicePropertyMute, channels: channels)
        let muted = muteAddresses.compactMap { readUInt32(object: device, address: $0) }
        let isMuted = !muted.isEmpty && muted.count == muteAddresses.count && muted.allSatisfy { $0 != 0 }
        let canSetVolume = !writableAddresses(device: device, selector: kAudioDevicePropertyVolumeScalar, channels: channels).isEmpty
            || isVirtualMainVolumeWritable(device: device)
        return AudioState(volume: Double(volume), isMuted: isMuted,
                          canSetVolume: canSetVolume,
                          canSetMute: canSetMuted(device: device, channels: channels) || canSetVolume,
                          outputName: route.name, outputDeviceID: device, outputUID: route.uid,
                          outputIdentifier: route.identifier, outputKind: route.kind)
    }

    static func readRoute(device: AudioDeviceID, channels: [AudioObjectPropertyElement]? = nil,
                          streams: [AudioStreamID]? = nil) -> AudioRoute {
        guard device != kAudioObjectUnknown,
              readUInt32(object: device, address: address(kAudioDevicePropertyDeviceIsAlive,
                                                        scope: kAudioObjectPropertyScopeGlobal)) == 1 else {
            return AudioRoute(isAlive: false, name: "未检测到输出设备", uid: nil, identifier: nil, kind: .unavailable)
        }
        let name = readString(object: device, selector: kAudioObjectPropertyName) ?? "音频输出"
        let uid = readString(object: device, selector: kAudioDevicePropertyDeviceUID)
        let transportValue = readUInt32(object: device, address: address(kAudioDevicePropertyTransportType,
                                                                        scope: kAudioObjectPropertyScopeGlobal))
        let transport: AudioOutputTransport
        switch transportValue {
        case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
        case kAudioDeviceTransportTypeUSB: transport = .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: transport = .hdmi
        case nil, kAudioDeviceTransportTypeUnknown: transport = .unknown
        default: transport = .other
        }
        let elements = [AudioObjectPropertyElement(kAudioObjectPropertyElementMain)] + (channels ?? outputChannels(device: device))
        let selectedSources = elements.flatMap { element in
            readUInt32Array(object: device, address: address(kAudioDevicePropertyDataSource, element: element))
                .map { (element, $0) }
        }
        let sources = selectedSources.map(\.1)
        let sourceNames = selectedSources.compactMap { sourceName(device: device, element: $0.0, source: $0.1) }
        let terminalTypes = (streams ?? outputStreams(device: device)).compactMap { stream -> UInt32? in
            // An inactive stream can represent a different jack on the same HAL
            // device. It must not label the currently selected output as headphones.
            let active = readUInt32(object: stream, address: address(kAudioStreamPropertyIsActive,
                                                                    scope: kAudioObjectPropertyScopeGlobal))
            guard active != 0 else { return nil }
            return readUInt32(object: stream, address: address(kAudioStreamPropertyTerminalType,
                                                              scope: kAudioObjectPropertyScopeGlobal))
        }
        let terminals: [AudioOutputTerminal] = terminalTypes.map {
            switch $0 {
            case kAudioStreamTerminalTypeHeadphones: .headphones
            case kAudioStreamTerminalTypeSpeaker, kAudioStreamTerminalTypeLFESpeaker,
                 kAudioStreamTerminalTypeReceiverSpeaker: .speaker
            case kAudioStreamTerminalTypeHDMI, kAudioStreamTerminalTypeDisplayPort: .hdmi
            default: .other
            }
        }
        let kind = AudioOutputClassifier.classify(transport: transport, terminals: terminals,
                                                 dataSourceName: sourceNames.joined(separator: " / "), deviceName: name)
        let identifier = AudioOutputIdentity.identifier(deviceID: device, uid: uid,
                                                        dataSources: sources, terminalTypes: terminalTypes)
        return AudioRoute(isAlive: true, name: name, uid: uid, identifier: identifier, kind: kind)
    }

    static func outputStreams(device: AudioDeviceID) -> [AudioStreamID] {
        guard device != kAudioObjectUnknown else { return [] }
        return readUInt32Array(object: device, address: address(kAudioDevicePropertyStreams)).filter { stream in
            readUInt32(object: stream, address: address(kAudioStreamPropertyDirection,
                                                       scope: kAudioObjectPropertyScopeGlobal)) != 1
        }
    }

    static func setVolume(_ value: Double, device: AudioDeviceID, balance: inout ChannelVolumeBalance) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var scalar = Float32(value)
        var main = address(kAudioDevicePropertyVolumeScalar)
        if isWritable(device: device, address: &main) {
            return AudioObjectSetPropertyData(device, &main, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr
        }
        // The system's virtual main control preserves channel balance and handles
        // the device's preferred channel layout when no physical main exists.
        if isVirtualMainVolumeWritable(device: device) {
            var virtualMain = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            if AudioObjectSetPropertyData(device, &virtualMain, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &scalar) == noErr { return true }
        }
        let addresses = writableAddresses(device: device, selector: kAudioDevicePropertyVolumeScalar, channels: outputChannels(device: device))
        let current = addresses.reduce(into: [UInt32: Float32]()) { values, property in
            if let volume = readFloat(object: device, address: property) { values[property.mElement] = volume }
        }
        guard !addresses.isEmpty, current.count == addresses.count else { return false }
        let scaled = balance.scaledVolumes(device: device, current: current, target: scalar)
        var completed: [AudioObjectPropertyAddress] = []
        for var address in addresses {
            guard var channelVolume = scaled[address.mElement] else { continue }
            guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &channelVolume) == noErr else {
                // A device can disappear between channel writes. Restore earlier
                // writes when possible instead of reporting a partial mute as success.
                for var written in completed {
                    if var previous = current[written.mElement] {
                        _ = AudioObjectSetPropertyData(device, &written, 0, nil, UInt32(MemoryLayout<Float32>.size), &previous)
                    }
                }
                return false
            }
            completed.append(address)
        }
        return completed.count == addresses.count
    }

    private static func readVirtualMainVolume(device: AudioDeviceID) -> Float32? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              value.isFinite else { return nil }
        return value
    }

    private static func isVirtualMainVolumeWritable(device: AudioDeviceID) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func canSetMuted(device: AudioDeviceID, channels: [AudioObjectPropertyElement]? = nil) -> Bool {
        let channels = channels ?? outputChannels(device: device)
        let readable = readableAddresses(device: device, selector: kAudioDevicePropertyMute, channels: channels)
        let writable = writableAddresses(device: device, selector: kAudioDevicePropertyMute, channels: channels)
        // Do not offer hardware mute if only some channels can be muted. A full
        // software volume mute is safer than leaving another channel audible.
        return !readable.isEmpty && Set(readable.map(\.mElement)) == Set(writable.map(\.mElement))
    }

    static func setMuted(_ muted: Bool, device: AudioDeviceID) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        let addresses = writableAddresses(device: device, selector: kAudioDevicePropertyMute, channels: outputChannels(device: device))
        let previous = addresses.reduce(into: [UInt32: UInt32]()) { values, property in
            if let mute = readUInt32(object: device, address: property) { values[property.mElement] = mute }
        }
        guard !addresses.isEmpty, previous.count == addresses.count else { return false }
        var completed: [AudioObjectPropertyAddress] = []
        for var address in addresses {
            guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr else {
                for var written in completed {
                    if var oldMute = previous[written.mElement] {
                        _ = AudioObjectSetPropertyData(device, &written, 0, nil, UInt32(MemoryLayout<UInt32>.size), &oldMute)
                    }
                }
                return false
            }
            completed.append(address)
        }
        return completed.count == addresses.count
    }

    static func outputChannels(device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        guard device != kAudioObjectUnknown else { return [] }
        var address = address(kAudioDevicePropertyStreamConfiguration)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return count > 0 ? (1...count).map { AudioObjectPropertyElement($0) } : []
    }

    private static func readableAddresses(device: AudioDeviceID, selector: AudioObjectPropertySelector,
                                          channels: [AudioObjectPropertyElement]) -> [AudioObjectPropertyAddress] {
        var main = address(selector)
        if AudioObjectHasProperty(device, &main) { return [main] }
        return channels.compactMap { channel in
            var property = address(selector, element: channel)
            return AudioObjectHasProperty(device, &property) ? property : nil
        }
    }

    private static func writableAddresses(device: AudioDeviceID, selector: AudioObjectPropertySelector,
                                          channels: [AudioObjectPropertyElement]) -> [AudioObjectPropertyAddress] {
        guard device != kAudioObjectUnknown else { return [] }
        var main = address(selector)
        if isWritable(device: device, address: &main) { return [main] }
        return channels.compactMap { channel in
            var property = address(selector, element: channel)
            return isWritable(device: device, address: &property) ? property : nil
        }
    }

    private static func isWritable(device: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func readUInt32(object: AudioObjectID, address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private static func readFloat(object: AudioObjectID, address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value.isFinite ? value : nil
    }

    private static func readUInt32Array(object: AudioObjectID, address: AudioObjectPropertyAddress) -> [UInt32] {
        var address = address
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &byteCount) == noErr,
              byteCount > 0, byteCount.isMultiple(of: UInt32(MemoryLayout<UInt32>.size)) else { return [] }
        var values = [UInt32](repeating: 0, count: Int(byteCount) / MemoryLayout<UInt32>.size)
        let result = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &byteCount, buffer.baseAddress!)
        }
        guard result == noErr, Int(byteCount) <= values.count * MemoryLayout<UInt32>.size else { return [] }
        return Array(values.prefix(Int(byteCount) / MemoryLayout<UInt32>.size))
    }

    private static func readString(object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        // Name and DeviceUID both return retained CFStrings, per the HAL contract.
        return value?.takeRetainedValue() as String?
    }

    private static func sourceName(device: AudioDeviceID, element: AudioObjectPropertyElement,
                                   source: UInt32) -> String? {
        var source = source
        var value: Unmanaged<CFString>?
        var property = address(kAudioDevicePropertyDataSourceNameForIDCFString, element: element)
        let result: OSStatus = withUnsafeMutablePointer(to: &source) { input in
            withUnsafeMutablePointer(to: &value) { output in
                var translation = AudioValueTranslation(mInputData: UnsafeMutableRawPointer(input),
                                                        mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                                        mOutputData: UnsafeMutableRawPointer(output),
                                                        mOutputDataSize: UInt32(MemoryLayout<CFString?>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &translation)
            }
        }
        guard result == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
