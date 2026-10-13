import AppKit
import Combine
import CoreBluetooth
import IOBluetooth
import IOKit
import IOKit.hid
import OrbitBarCore

/// Observes existing connections only. It never scans, pairs, opens an audio
/// connection, or changes Bluetooth power.
@MainActor
final class BluetoothMonitor: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var state = BluetoothState()

    private var central: CBCentralManager?
    private var connectObservation: IOBluetoothUserNotification?
    private var disconnectObservations: [String: IOBluetoothUserNotification] = [:]
    private var connectedEventAddresses = Set<String>()
    private var workspaceObservations: [NSObjectProtocol] = []
    private var timer: Timer?
    private var pendingRefresh: Task<Void, Never>?
    private var retryRefresh: Task<Void, Never>?
    private var registryRead: Task<Void, Never>?
    private var registryWorker: Task<[RegistryBluetoothRecord], Never>?
    private var registryObservations: BluetoothRegistryObservations?
    private var connectionSession = BluetoothConnectionSession()
    private var registryRecords: [RegistryBluetoothRecord] = []
    private var lastAudioOutputIdentity: String?
    private var batteryUpdatingIDs = Set<String>()
    private var classicConnectedIDs = Set<String>()
    private var isRunning = false
    private var isSleeping = false

    init(automaticStart: Bool = true) {
        super.init()
        if automaticStart { start() }
        else { publish(BluetoothState(authorization: Self.authorization())) }
    }

    func refresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        guard isRunning, !isSleeping else { return }

        let authorization = Self.authorization()
        guard authorization == .allowed else {
            connectionSession.suspend(serviceIDsByDevice: batterySourcesByDevice())
            removeConnectionObservations()
            invalidateRegistryRead()
            registryRecords.removeAll()
            batteryUpdatingIDs.removeAll()
            classicConnectedIDs.removeAll()
            publish(BluetoothState(authorization: authorization))
            return
        }
        ensureCentral()
        let power = readPower()
        guard power == .on else {
            connectionSession.suspend(serviceIDsByDevice: batterySourcesByDevice())
            removeConnectionObservations()
            invalidateRegistryRead()
            registryRecords.removeAll()
            batteryUpdatingIDs.removeAll()
            classicConnectedIDs.removeAll()
            publish(BluetoothState(authorization: authorization, power: power))
            return
        }
        ensureConnectObservation()
        if registryObservations == nil {
            registryObservations = BluetoothRegistryObservations(
                onTopologyChange: { [weak self] serviceIDs, removed, time in
                    Task { @MainActor [weak self] in self?.registryTopologyChanged(serviceIDs: serviceIDs, removed: removed, at: time) }
                },
                onPropertyChange: { [weak self] serviceID, time in
                    Task { @MainActor [weak self] in self?.registryPropertiesChanged(serviceID: serviceID, at: time) }
                })
        }
        publishConnectedDevices()
        updateRegistryRecords()
    }

    /// Constructing a Bluetooth manager can request access. This is called only
    /// from the user's explicit permission button when access is undetermined.
    func requestAccess() {
        guard isRunning, !isSleeping else { return }
        if Self.authorization() == .notDetermined { ensureCentral() }
        refresh()
    }

    /// HAL may report the new route before the Bluetooth notification/list has
    /// caught up. Retry briefly without scanning or creating a connection.
    func currentAudioOutputDidChange(_ audio: AudioState) {
        let identity = "\(audio.outputIdentifier ?? "")|\(audio.outputUID ?? "")|\(audio.outputDeviceID.map(String.init) ?? "")|\(audio.outputKind.rawValue)|\(audio.outputName)"
        guard identity != lastAudioOutputIdentity else { return }
        lastAudioOutputIdentity = identity
        guard isRunning, !isSleeping else { return }
        invalidateRegistryRead()
        refresh()
        scheduleShortRetries()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        retryRefresh?.cancel()
        retryRefresh = nil
        invalidateRegistryRead()
        removeConnectionObservations()
        central?.delegate = nil
        central = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservations { center.removeObserver(observer) }
        workspaceObservations.removeAll()
        registryRecords.removeAll()
        batteryUpdatingIDs.removeAll()
        publish(BluetoothState(authorization: state.authorization, power: .unknown))
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, !self.isSleeping else { return }
            self.invalidateRegistryRead()
            self.refresh()
            self.scheduleShortRetries()
        }
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    if name == NSWorkspace.willSleepNotification { self.suspend() }
                    else { self.resume() }
                }
            })
        }
        startPolling()
        refresh()
    }

    private func startPolling() {
        guard timer == nil, isRunning, !isSleeping else { return }
        timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer?.tolerance = 10
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func suspend() {
        isSleeping = true
        connectionSession.suspend(serviceIDsByDevice: batterySourcesByDevice())
        timer?.invalidate()
        timer = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        retryRefresh?.cancel()
        retryRefresh = nil
        invalidateRegistryRead()
        removeConnectionObservations()
        central?.delegate = nil
        central = nil
        registryRecords.removeAll()
        batteryUpdatingIDs.removeAll()
        publish(BluetoothState(authorization: state.authorization, power: .unknown))
    }

    private func resume() {
        isSleeping = false
        startPolling()
        refresh()
        scheduleShortRetries()
    }

    private func scheduleRefresh() {
        guard isRunning, !isSleeping, pendingRefresh == nil else { return }
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.isRunning, !self.isSleeping else { return }
            self.refresh()
        }
    }

    private func scheduleShortRetries() {
        retryRefresh?.cancel()
        retryRefresh = Task { @MainActor [weak self] in
            // Absolute retry times: 0.3, 0.8, 1.6, 3.2, and 5.2 seconds.
            for delay in [300, 500, 800, 1_600, 2_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, self.isRunning, !self.isSleeping else { return }
                self.refresh()
            }
            self?.retryRefresh = nil
        }
    }

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    private static func authorization() -> BluetoothAuthorization {
        switch CBManager.authorization {
        case .notDetermined: return .notDetermined
        case .allowedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private func readPower() -> BluetoothPowerState {
        if let central {
            switch central.state {
            case .poweredOn: return .on
            case .poweredOff: return .off
            case .resetting, .unauthorized: return .unknown
            case .unknown, .unsupported: break
            @unknown default: return .unknown
            }
        }
        // This public classic controller API can provide the initial value before
        // the asynchronous CoreBluetooth state callback arrives.
        guard let host = IOBluetoothHostController.default() else { return .unavailable }
        switch host.powerState {
        case kBluetoothHCIPowerStateON: return .on
        case kBluetoothHCIPowerStateOFF: return .off
        default: return .unknown
        }
    }

    private func ensureConnectObservation() {
        guard connectObservation == nil else { return }
        connectObservation = IOBluetoothDevice.register(forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:)))
    }

    @objc nonisolated private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString
        let time = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, !self.isSleeping else { return }
            guard let address, let id = RegistryBluetoothReader.normalizedAddress(address),
                  self.connectionSession.didConnect(id, previousServiceIDs: self.batterySources(for: id), at: time) else { return }
            self.connectedEventAddresses.insert(address)
            self.batteryUpdatingIDs.insert(id)
            self.registryRecords.removeAll { $0.address == id }
            self.clearDisplayedBattery(for: id)
            self.invalidateRegistryRead()
            self.refresh()
            self.scheduleShortRetries()
        }
    }

    @objc nonisolated private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString
        let time = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, !self.isSleeping else { return }
            guard let address, let id = RegistryBluetoothReader.normalizedAddress(address),
                  self.connectionSession.didDisconnect(id, serviceIDs: self.connectionSources(for: id),
                    batteryServiceIDs: self.batterySources(for: id), at: time) else { return }
            self.connectedEventAddresses.remove(address)
            self.batteryUpdatingIDs.remove(id)
            self.registryRecords.removeAll { $0.address == id }
            self.removeDisplayedDevice(id)
            self.invalidateRegistryRead()
            self.refresh()
            self.scheduleShortRetries()
        }
    }

    private func removeConnectionObservations() {
        connectObservation?.unregister()
        connectObservation = nil
        for observation in disconnectObservations.values { observation.unregister() }
        disconnectObservations.removeAll()
        connectedEventAddresses.removeAll()
        registryObservations?.stop()
        registryObservations = nil
    }

    private func connectedDevices() -> [IOBluetoothDevice] {
        var devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for address in connectedEventAddresses {
            if let device = IOBluetoothDevice(addressString: address) { devices.append(device) }
        }
        var seen = Set<String>()
        let now = ProcessInfo.processInfo.systemUptime
        return devices.filter { device in
            guard let address = device.addressString,
                  let id = RegistryBluetoothReader.normalizedAddress(address) else { return false }
            // The paired list and a connect event often return the same object.
            // One refresh must produce one getter observation per address; a
            // duplicate false must not count as a later disconnect observation.
            guard seen.insert(id).inserted else { return false }
            guard connectionSession.acceptsClassicConnection(id, isConnected: device.isConnected(), now: now,
                serviceIDs: connectionSources(for: id), batteryServiceIDs: batterySources(for: id)) else {
                if connectionSession.isBlocked(id) { batteryUpdatingIDs.remove(id) }
                return false
            }
            return true
        }
    }

    private func publishConnectedDevices(registryReadComplete: Bool = false) {
        guard Self.authorization() == .allowed, readPower() == .on else { return }
        let devices = connectedDevices()
        classicConnectedIDs = Set(devices.compactMap { device in
            device.addressString.flatMap(RegistryBluetoothReader.normalizedAddress)
        })
        var activeIDs = Set<String>()
        var displayed: [BluetoothDeviceState] = []
        for device in devices {
            guard let address = device.addressString,
                  let id = RegistryBluetoothReader.normalizedAddress(address) else { continue }
            activeIDs.insert(id)
            if disconnectObservations[id] == nil {
                disconnectObservations[id] = device.register(forDisconnectNotification: self,
                    selector: #selector(deviceDisconnected(_:device:)))
            }
            let name = device.name ?? "蓝牙设备"
            if !registryReadComplete, !state.devices.contains(where: { $0.id == id }) { batteryUpdatingIDs.insert(id) }
            let battery = batteryReading(for: id)
            displayed.append(BluetoothDeviceState(id: id, name: name,
                kind: Self.kind(major: device.deviceClassMajor, minor: device.deviceClassMinor), battery: battery.reading,
                isBatteryUpdating: batteryUpdatingIDs.contains(id), isBatteryStale: battery.isStale))
        }
        let expiredIDs = disconnectObservations.keys.filter { !activeIDs.contains($0) }
        for id in expiredIDs { disconnectObservations.removeValue(forKey: id)?.unregister() }

        // BLE HID devices aren't always represented in the classic paired list.
        // A live Bluetooth IOHIDDevice service is an existing system connection.
        let registryObservationTime = ProcessInfo.processInfo.systemUptime
        for record in RegistryBluetoothReader.preferredRecords(registryRecords.filter(\.isLiveHID)) {
            guard let id = record.address, !activeIDs.contains(id),
                  connectionSession.acceptsRegistryConnection(id, serviceIDs: [record.serviceID], now: registryObservationTime) else { continue }
            activeIDs.insert(id)
            if !registryReadComplete, !state.devices.contains(where: { $0.id == id }) { batteryUpdatingIDs.insert(id) }
            let battery = batteryReading(for: id)
            displayed.append(BluetoothDeviceState(id: id, name: record.name ?? "蓝牙设备",
                kind: record.kind, battery: battery.reading, isBatteryUpdating: batteryUpdatingIDs.contains(id),
                isBatteryStale: battery.isStale))
        }
        publish(BluetoothState(authorization: .allowed, power: .on, devices: displayed,
                               disconnectedDeviceIDs: connectionSession.disconnectedDeviceIDs))
        registryObservations?.observeProperties(serviceIDs: Set(registryRecords.flatMap(\.observedServiceIDs)).union(connectionSession.quarantinedServiceIDs))
    }

    private func batteryReading(for id: String) -> (reading: BluetoothBatteryState, isStale: Bool) {
        guard let record = RegistryBluetoothReader.preferredRecord(for: id, in: registryRecords),
              let source = record.batteryServiceID, !connectionSession.isBlocked(id) else { return (.init(), false) }
        let currentSession = connectionSession.acceptsBattery(id, serviceIDs: [source])
        return (record.battery, record.battery.hasReading && !currentSession)
    }

    private func batterySources(for id: String) -> Set<UInt64> {
        Set(registryRecords.filter { $0.address == id }.compactMap(\.batteryServiceID))
    }

    private func connectionSources(for id: String) -> Set<UInt64> {
        Set(registryRecords.filter { $0.address == id && $0.isLiveHID }.map(\.serviceID))
    }

    private func batterySourcesByDevice() -> [String: Set<UInt64>] {
        registryRecords.reduce(into: [:]) { sources, record in
            if let id = record.address, let source = record.batteryServiceID { sources[id, default: []].insert(source) }
        }
    }

    private func removeDisplayedDevice(_ id: String) {
        var updated = state
        updated.devices.removeAll { $0.id == id }
        updated.disconnectedDeviceIDs = connectionSession.disconnectedDeviceIDs
        publish(updated)
    }

    private func clearDisplayedBattery(for id: String) {
        var updated = state
        updated.disconnectedDeviceIDs = connectionSession.disconnectedDeviceIDs
        for index in updated.devices.indices where updated.devices[index].id == id {
            updated.devices[index].battery = .init()
            updated.devices[index].isBatteryUpdating = true
            updated.devices[index].isBatteryStale = false
        }
        publish(updated)
    }

    private func registryTopologyChanged(serviceIDs: Set<UInt64>, removed: Bool, at time: Double) {
        guard isRunning, !isSleeping else { return }
        if removed {
            for record in registryRecords where record.isLiveHID && serviceIDs.contains(record.serviceID) {
                guard let id = record.address else { continue }
                let classicStillConnected = IOBluetoothDevice(addressString: id)?.isConnected() == true
                if !classicStillConnected {
                    if connectionSession.didDisconnect(id, serviceIDs: connectionSources(for: id),
                        batteryServiceIDs: batterySources(for: id), at: time) { removeDisplayedDevice(id) }
                }
            }
            registryRecords.removeAll { !Set($0.observedServiceIDs).isDisjoint(with: serviceIDs) }
        }
        invalidateRegistryRead()
        scheduleRefresh()
        scheduleShortRetries()
    }

    private func registryPropertiesChanged(serviceID: UInt64, at time: Double) {
        guard isRunning, !isSleeping else { return }
        connectionSession.batteryPropertiesChanged(serviceID: serviceID, at: time)
        invalidateRegistryRead()
        scheduleRefresh()
    }

    private static func kind(major: BluetoothDeviceClassMajor, minor: BluetoothDeviceClassMinor) -> BluetoothDeviceKind {
        switch major {
        case UInt32(kBluetoothDeviceClassMajorAudio):
            switch minor {
            case UInt32(kBluetoothDeviceClassMinorAudioHeadset), UInt32(kBluetoothDeviceClassMinorAudioHandsFree),
                 UInt32(kBluetoothDeviceClassMinorAudioHeadphones): return .headphones
            case UInt32(kBluetoothDeviceClassMinorAudioLoudspeaker), UInt32(kBluetoothDeviceClassMinorAudioHiFi): return .speaker
            default: return .other
            }
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            if minor & UInt32(kBluetoothDeviceClassMinorPeripheral1Keyboard) != 0 { return .keyboard }
            if minor & UInt32(kBluetoothDeviceClassMinorPeripheral1Pointing) != 0 { return .mouse }
            if [UInt32(kBluetoothDeviceClassMinorPeripheral2Joystick), UInt32(kBluetoothDeviceClassMinorPeripheral2Gamepad)].contains(minor & 0x0F) {
                return .gameController
            }
            return .other
        case UInt32(kBluetoothDeviceClassMajorPhone): return .phone
        default: return .other
        }
    }

    private func updateRegistryRecords() {
        // A refresh that happens during a previous read must start a new read;
        // skipping it would let the old result replace the new connection session.
        invalidateRegistryRead()
        let token = connectionSession.beginRead()
        let knownAddresses = classicConnectedIDs
        let worker = Task.detached(priority: .utility) {
            RegistryBluetoothReader.read(knownConnectedAddresses: knownAddresses)
        }
        registryWorker = worker
        registryRead = Task { @MainActor [weak self] in
            let records = await worker.value
            guard !Task.isCancelled, let self, self.isRunning, !self.isSleeping,
                  self.connectionSession.accepts(token) else { return }
            self.registryRead = nil
            self.registryWorker = nil
            guard Self.authorization() == .allowed, self.readPower() == .on else { return }
            self.registryRecords = records
            for record in RegistryBluetoothReader.preferredRecords(records) {
                if let id = record.address, let source = record.batteryServiceID {
                    self.connectionSession.observeBattery(id, serviceID: source, observation: record.batteryObservation)
                }
            }
            self.batteryUpdatingIDs.removeAll()
            self.publishConnectedDevices(registryReadComplete: true)
        }
    }

    private func invalidateRegistryRead() {
        connectionSession.invalidateReads()
        registryRead?.cancel()
        registryRead = nil
        registryWorker?.cancel()
        registryWorker = nil
    }

    private func publish(_ value: BluetoothState) {
        if value != state { state = value }
    }
}

/// Registry matching observes local service publication/removal; it does not
/// perform Bluetooth discovery or open an HID device for input monitoring.
@MainActor
private final class BluetoothRegistryObservations {
    nonisolated let onTopologyChange: @Sendable (Set<UInt64>, Bool, Double) -> Void
    nonisolated let onPropertyChange: @Sendable (UInt64, Double) -> Void
    private var port: IONotificationPortRef?
    private var source: CFRunLoopSource?
    private var iterators: [io_iterator_t] = []
    private var propertyObservations: [UInt64: io_object_t] = [:]

    init(onTopologyChange: @escaping @Sendable (Set<UInt64>, Bool, Double) -> Void,
         onPropertyChange: @escaping @Sendable (UInt64, Double) -> Void) {
        self.onTopologyChange = onTopologyChange
        self.onPropertyChange = onPropertyChange
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        for className in RegistryBluetoothReader.matchingClasses {
            for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = IO_OBJECT_NULL
                let result: kern_return_t
                if notification == kIOTerminatedNotification {
                    result = IOServiceAddMatchingNotification(port, notification, IOServiceMatching(className),
                        bluetoothRegistryRemoved, Unmanaged.passUnretained(self).toOpaque(), &iterator)
                } else {
                    result = IOServiceAddMatchingNotification(port, notification, IOServiceMatching(className),
                        bluetoothRegistryAdded, Unmanaged.passUnretained(self).toOpaque(), &iterator)
                }
                if result == KERN_SUCCESS {
                    iterators.append(iterator)
                    // A matching iterator must be drained once to arm its events.
                    drainBluetoothRegistryIterator(iterator)
                }
            }
        }
    }

    func observeProperties(serviceIDs: Set<UInt64>) {
        for id in propertyObservations.keys.filter({ !serviceIDs.contains($0) }) {
            if let observation = propertyObservations.removeValue(forKey: id) { IOObjectRelease(observation) }
        }
        guard let port else { return }
        for id in serviceIDs where propertyObservations[id] == nil {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
            guard service != IO_OBJECT_NULL else { continue }
            defer { IOObjectRelease(service) }
            var observation: io_object_t = IO_OBJECT_NULL
            let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest,
                bluetoothRegistryPropertyChanged, Unmanaged.passUnretained(self).toOpaque(), &observation)
            if result == KERN_SUCCESS { propertyObservations[id] = observation }
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators.removeAll()
        for observation in propertyObservations.values { IOObjectRelease(observation) }
        propertyObservations.removeAll()
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }
}

@discardableResult
private func drainBluetoothRegistryIterator(_ iterator: io_iterator_t) -> Set<UInt64> {
    var identifiers = Set<UInt64>()
    while true {
        let service = IOIteratorNext(iterator)
        guard service != IO_OBJECT_NULL else { return identifiers }
        var identifier: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS { identifiers.insert(identifier) }
        IOObjectRelease(service)
    }
}

private func bluetoothRegistryAdded(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    let identifiers = drainBluetoothRegistryIterator(iterator)
    guard let context else { return }
    let observer = Unmanaged<BluetoothRegistryObservations>.fromOpaque(context).takeUnretainedValue()
    observer.onTopologyChange(identifiers, false, ProcessInfo.processInfo.systemUptime)
}

private func bluetoothRegistryRemoved(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    let identifiers = drainBluetoothRegistryIterator(iterator)
    guard let context else { return }
    let observer = Unmanaged<BluetoothRegistryObservations>.fromOpaque(context).takeUnretainedValue()
    observer.onTopologyChange(identifiers, true, ProcessInfo.processInfo.systemUptime)
}

private func bluetoothRegistryPropertyChanged(_ context: UnsafeMutableRawPointer?, _ service: io_service_t,
                                             _ message: natural_t, _ argument: UnsafeMutableRawPointer?) {
    // IOMessage.h's iokit_common_msg macro is not imported into Swift. Its public
    // kIOMessageServicePropertyChange value is sys_iokit | 0x130.
    guard message == 0xE0000130, let context else { return }
    var identifier: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { return }
    let observer = Unmanaged<BluetoothRegistryObservations>.fromOpaque(context).takeUnretainedValue()
    observer.onPropertyChange(identifier, ProcessInfo.processInfo.systemUptime)
}
