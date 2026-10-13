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
    private var isSleeping = false
    private var isStopped = false

    public init(audio: AudioState = .init(), bluetooth: BluetoothState = .init()) {
        rawAudio = audio
        self.bluetooth = bluetooth
        self.audio = Self.presentedAudio(audio, bluetooth: bluetooth)
    }

    public mutating func updateAudio(_ raw: AudioState) -> AudioBluetoothUpdate {
        guard !isStopped, !isSleeping else { return update() }
        let changed = raw.outputDeviceID != rawAudio.outputDeviceID
            || raw.outputUID != rawAudio.outputUID || raw.outputIdentifier != rawAudio.outputIdentifier
        rawAudio = raw
        audio = Self.presentedAudio(raw, bluetooth: bluetooth)
        return update(outputIdentityChanged: changed)
    }

    public mutating func updateBluetooth(_ state: BluetoothState) -> AudioBluetoothUpdate {
        guard !isStopped else { return update() }
        let membershipChanged = Self.membership(state) != Self.membership(bluetooth)
            || Self.disconnectedMembership(state) != Self.disconnectedMembership(bluetooth)
        let refresh = state.authorization != bluetooth.authorization || state.power != bluetooth.power || membershipChanged
        bluetooth = state
        audio = Self.presentedAudio(rawAudio, bluetooth: state)
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

    /// Checked again against a freshly read HAL route before any native write.
    /// Connected-list absence and permission denial are not disconnect evidence.
    public static func permitsControl(audio: AudioState, bluetooth: BluetoothState) -> Bool {
        guard audio.outputKind.isBluetooth else { return true }
        if bluetooth.authorization == .allowed, bluetooth.power == .off { return false }
        let addresses = BluetoothAudioUIDAddress.extract(from: audio.outputUID)
        return addresses.count != 1 || addresses.isDisjoint(with: disconnectedMembership(bluetooth))
    }

    private static func presentedAudio(_ raw: AudioState, bluetooth: BluetoothState) -> AudioState {
        guard raw.outputKind.isBluetooth else { return raw }
        if !permitsControl(audio: raw, bluetooth: bluetooth) {
            // A true disconnect can reach us before HAL switches away from its
            // old UID. Remove obsolete controls/dots while preserving raw route
            // identifiers so no new hardware identity is invented for writes.
            var unavailable = raw
            unavailable.outputKind = .unavailable
            unavailable.canSetVolume = false
            unavailable.canSetMute = false
            unavailable.volume = 0
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
}
