import Foundation

public struct AudioBluetoothUpdate: Equatable, Sendable {
    public let audio: AudioState
    public let requiresAudioRefresh: Bool
    public let outputIdentityChanged: Bool
    public let connectionMembershipChanged: Bool
}

/// Keeps actual HAL routing separate from accessory-derived presentation.
/// This is also the refresh/callback policy used by the native StatusMonitor.
public struct AudioBluetoothCoordinator: Sendable {
    public private(set) var audio: AudioState
    private var rawAudio: AudioState
    private var bluetooth: BluetoothState
    private var association: RouteAssociation?
    private var isSleeping = false
    private var isStopped = false

    public init(audio: AudioState = .init(), bluetooth: BluetoothState = .init()) {
        rawAudio = audio
        self.bluetooth = bluetooth
        self.audio = audio
        updateAssociation()
        self.audio = presentedAudio()
    }

    public mutating func updateAudio(_ raw: AudioState) -> AudioBluetoothUpdate {
        guard !isStopped, !isSleeping else { return update() }
        let changed = raw.outputDeviceID != rawAudio.outputDeviceID
            || raw.outputUID != rawAudio.outputUID || raw.outputIdentifier != rawAudio.outputIdentifier
        rawAudio = raw
        updateAssociation()
        audio = presentedAudio()
        return update(outputIdentityChanged: changed)
    }

    public mutating func updateBluetooth(_ state: BluetoothState) -> AudioBluetoothUpdate {
        guard !isStopped else { return update() }
        let membershipChanged = Self.membership(state) != Self.membership(bluetooth)
            || Self.disconnectedMembership(state) != Self.disconnectedMembership(bluetooth)
        let refresh = state.authorization != bluetooth.authorization || state.power != bluetooth.power || membershipChanged
        bluetooth = state
        updateAssociation()
        audio = presentedAudio()
        // Battery/name/category changes use the stored HAL route. A connection
        // change refreshes HAL once, but cannot trigger an output callback itself.
        return update(requiresAudioRefresh: refresh && !isSleeping,
                      connectionMembershipChanged: membershipChanged)
    }

    public mutating func setSleeping(_ sleeping: Bool) { isSleeping = sleeping }
    public mutating func stop() { isStopped = true }

    private func update(requiresAudioRefresh: Bool = false, outputIdentityChanged: Bool = false,
                        connectionMembershipChanged: Bool = false) -> AudioBluetoothUpdate {
        AudioBluetoothUpdate(audio: audio, requiresAudioRefresh: requiresAudioRefresh,
                             outputIdentityChanged: outputIdentityChanged,
                             connectionMembershipChanged: connectionMembershipChanged)
    }

    private static func membership(_ state: BluetoothState) -> Set<String> {
        Set(state.devices.map { BluetoothAddress.normalize($0.id) ?? $0.id })
    }

    private static func disconnectedMembership(_ state: BluetoothState) -> Set<String> {
        Set(state.disconnectedDeviceIDs.compactMap(BluetoothAddress.normalize))
    }

    /// Stateless address/radio evidence; opaque routes need the instance guard.
    /// Connected-list absence and permission denial are not disconnect evidence.
    public static func permitsControl(audio: AudioState, bluetooth: BluetoothState) -> Bool {
        guard audio.outputKind.isBluetooth else { return true }
        if bluetooth.authorization == .allowed, bluetooth.power == .off { return false }
        let addresses = BluetoothAudioUIDAddress.extract(from: audio.outputUID)
        return addresses.count != 1 || addresses.isDisjoint(with: disconnectedMembership(bluetooth))
    }

    /// Includes earlier reliable matching for opaque UIDs. Native writes pass
    /// their freshly read identity; a different route never inherits this link.
    public func permitsControl(audio observed: AudioState) -> Bool {
        guard !isStopped, !isSleeping, Self.permitsControl(audio: observed, bluetooth: bluetooth) else { return false }
        guard let association, association.matches(observed) else { return true }
        return !Self.disconnectedMembership(bluetooth).contains(association.deviceID)
    }

    private mutating func updateAssociation() {
        if association?.matches(rawAudio) == true { return }
        association = nil
        guard bluetooth.authorization == .allowed, bluetooth.power == .on else { return }
        var raw = rawAudio
        raw.bluetoothDeviceID = nil
        if let device = BluetoothOutputMatcher.currentDevice(audio: raw, devices: bluetooth.devices) {
            association = RouteAssociation(audio: raw, deviceID: device.id)
        }
    }

    private func presentedAudio() -> AudioState {
        var raw = rawAudio
        raw.bluetoothDeviceID = association?.matches(raw) == true ? association?.deviceID : nil
        guard raw.outputKind.isBluetooth else { return raw }
        if !permitsControl(audio: raw) {
            // A true disconnect can reach us before HAL switches away from its
            // old UID. Remove obsolete controls/dots while preserving raw route
            // identifiers so no new hardware identity is invented for writes.
            var unavailable = raw
            unavailable.outputKind = .unavailable
            unavailable.canSetVolume = false
            unavailable.canSetMute = false
            unavailable.volume = 0
            unavailable.isMuted = false
            return unavailable
        }
        guard bluetooth.authorization == .allowed, bluetooth.power == .on,
              let device = BluetoothOutputMatcher.currentDevice(audio: raw, devices: bluetooth.devices) else { return raw }
        var presented = raw
        // Some HAL Bluetooth drivers expose a generic speaker terminal even for
        // headphones. Connected-device CoD is better presentation evidence, while
        // the raw UID, route identity, volume and mute capabilities remain intact.
        switch device.kind {
        case .headphones: presented.outputKind = .bluetoothHeadphones
        case .speaker: presented.outputKind = .bluetoothAudio
        default: break
        }
        return presented
    }

    private struct RouteAssociation: Sendable {
        let halID: UInt32
        let uid: String
        let identifier: String
        let deviceID: String

        init?(audio: AudioState, deviceID: String) {
            guard audio.outputKind.isBluetooth, let halID = audio.outputDeviceID, halID != 0,
                  let uid = audio.outputUID, !uid.isEmpty,
                  let identifier = audio.outputIdentifier, !identifier.isEmpty,
                  let address = BluetoothAddress.normalize(deviceID) else { return nil }
            self.halID = halID; self.uid = uid; self.identifier = identifier; self.deviceID = address
        }

        func matches(_ audio: AudioState) -> Bool {
            audio.outputKind.isBluetooth && audio.outputDeviceID == halID
                && audio.outputUID == uid && audio.outputIdentifier == identifier
        }
    }
}
