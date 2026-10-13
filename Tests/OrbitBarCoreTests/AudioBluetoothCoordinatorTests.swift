import XCTest
@testable import OrbitBarCore

final class AudioBluetoothCoordinatorTests: XCTestCase {
    private let first = BluetoothDeviceState(id: "AA:BB:CC:DD:EE:FF", name: "Studio", kind: .headphones)
    private let second = BluetoothDeviceState(id: "11:22:33:44:55:66", name: "Studio", kind: .speaker)

    private func state(_ devices: [BluetoothDeviceState]) -> BluetoothState {
        BluetoothState(authorization: .allowed, power: .on, devices: devices)
    }

    private func route(_ device: BluetoothDeviceState, halID: UInt32 = 42, volume: Double = 0.4) -> AudioState {
        AudioState(volume: volume, canSetVolume: true, canSetMute: true, outputName: device.name,
                   outputDeviceID: halID, outputUID: "\(device.id):output", outputIdentifier: "route:\(device.id)",
                   outputKind: .bluetoothAudio)
    }

    func testConnectedHeadphoneCategoryEnhancesGenericHALSpeakerWithoutChangingControls() {
        let raw = route(first)
        var coordinator = AudioBluetoothCoordinator(audio: raw)
        let connection = coordinator.updateBluetooth(state([first]))
        XCTAssertTrue(connection.requiresAudioRefresh)
        let read = coordinator.updateAudio(raw)
        XCTAssertEqual(read.audio.outputKind, .bluetoothHeadphones)
        XCTAssertEqual(read.audio.outputUID, raw.outputUID)
        XCTAssertEqual(read.audio.outputIdentifier, raw.outputIdentifier)
        XCTAssertEqual(read.audio.volume, raw.volume)
        XCTAssertEqual(read.audio.canSetMute, raw.canSetMute)
        XCTAssertFalse(read.outputIdentityChanged)
        XCTAssertFalse(coordinator.updateBluetooth(state([first])).requiresAudioRefresh)
    }

    func testBatteryOnlyUpdatesDoNotRequireHALOrOutputNotifications() {
        var coordinator = AudioBluetoothCoordinator(audio: route(first), bluetooth: state([first]))
        var updated = first
        for battery in [90, 89, 50, 0] {
            updated.battery = BluetoothBatteryState(overall: battery)
            let change = coordinator.updateBluetooth(state([updated]))
            XCTAssertFalse(change.requiresAudioRefresh)
            XCTAssertFalse(change.outputIdentityChanged)
            XCTAssertEqual(change.audio.outputKind, .bluetoothHeadphones)
        }
        let volumeChange = coordinator.updateAudio(route(first, volume: 0.8))
        XCTAssertEqual(volumeChange.audio.volume, 0.8)
        XCTAssertFalse(volumeChange.outputIdentityChanged)
    }

    func testPowerAndAuthorizationChangesRefreshOnceEvenWithoutMembers() {
        var coordinator = AudioBluetoothCoordinator()
        for state in [BluetoothState(authorization: .allowed, power: .off),
                      BluetoothState(authorization: .allowed, power: .on),
                      BluetoothState(authorization: .denied, power: .on)] {
            XCTAssertTrue(coordinator.updateBluetooth(state).requiresAudioRefresh)
            XCTAssertFalse(coordinator.updateBluetooth(state).requiresAudioRefresh)
        }
    }

    func testCategoryAndNameUpdatesUseCachedRawRouteWithoutReadingHAL() {
        var coordinator = AudioBluetoothCoordinator(audio: route(first), bluetooth: state([first]))
        var changed = first
        changed.name = "Renamed speaker"
        changed.kind = .speaker
        let update = coordinator.updateBluetooth(state([changed]))
        XCTAssertFalse(update.requiresAudioRefresh)
        XCTAssertFalse(update.outputIdentityChanged)
        XCTAssertEqual(update.audio.outputKind, .bluetoothAudio)
        changed.kind = .headphones
        XCTAssertEqual(coordinator.updateBluetooth(state([changed])).audio.outputKind, .bluetoothHeadphones)
    }

    func testRapidOutputSwitchesProduceExactlyOneIdentityChangeEach() {
        var coordinator = AudioBluetoothCoordinator(audio: route(first), bluetooth: state([first, second]))
        let builtIn = AudioState(outputName: "Mac Speakers", outputDeviceID: 10,
                                 outputUID: "built-in", outputIdentifier: "route:builtin", outputKind: .builtInSpeaker)
        let outputs = [route(second, halID: 43), builtIn, route(first)]
        for output in outputs {
            let changed = coordinator.updateAudio(output)
            XCTAssertTrue(changed.outputIdentityChanged)
            XCTAssertEqual(changed.audio.outputUID, output.outputUID)
            XCTAssertFalse(coordinator.updateBluetooth(state([first, second])).requiresAudioRefresh)
            XCTAssertFalse(coordinator.updateAudio(output).outputIdentityChanged)
        }
        XCTAssertEqual(coordinator.audio.outputKind, .bluetoothHeadphones)
    }

    func testDisconnectAndAToBReconnectNeverRestoreAnObsoleteSameNameMatch() {
        var coordinator = AudioBluetoothCoordinator(audio: route(first), bluetooth: state([first, second]))
        let disconnected = coordinator.updateBluetooth(state([second]))
        XCTAssertTrue(disconnected.requiresAudioRefresh)
        XCTAssertFalse(disconnected.outputIdentityChanged)
        XCTAssertEqual(disconnected.audio.outputKind, .bluetoothAudio)
        XCTAssertNil(BluetoothOutputMatcher.currentDevice(audio: disconnected.audio, devices: [second]))
        let switched = coordinator.updateAudio(route(second, halID: 43))
        XCTAssertTrue(switched.outputIdentityChanged)
        XCTAssertEqual(switched.audio.outputKind, .bluetoothAudio)
        let reconnected = coordinator.updateBluetooth(state([first, second]))
        XCTAssertTrue(reconnected.requiresAudioRefresh)
        XCTAssertEqual(BluetoothOutputMatcher.currentDevice(audio: reconnected.audio, devices: [first, second])?.id, second.id)
        XCTAssertFalse(coordinator.updateAudio(route(second, halID: 43)).outputIdentityChanged)
        let restored = coordinator.updateAudio(route(first))
        XCTAssertTrue(restored.outputIdentityChanged)
        XCTAssertEqual(restored.audio.outputKind, .bluetoothHeadphones)
    }

    func testSleepAndStopSuppressHALRequestsAndOutputChanges() {
        var coordinator = AudioBluetoothCoordinator(audio: route(first), bluetooth: state([first]))
        coordinator.setSleeping(true)
        XCTAssertFalse(coordinator.updateBluetooth(state([second])).requiresAudioRefresh)
        XCTAssertFalse(coordinator.updateAudio(route(second, halID: 43)).outputIdentityChanged)
        coordinator.setSleeping(false)
        XCTAssertTrue(coordinator.updateAudio(route(second, halID: 43)).outputIdentityChanged)
        coordinator.stop()
        XCTAssertFalse(coordinator.updateBluetooth(state([first])).requiresAudioRefresh)
        let ignored = coordinator.updateAudio(route(first))
        XCTAssertFalse(ignored.outputIdentityChanged)
        XCTAssertEqual(ignored.audio.outputUID, route(second, halID: 43).outputUID)
    }

    func testAddressFormattingChangeIsNotAConnectionChange() {
        var coordinator = AudioBluetoothCoordinator(audio: route(first), bluetooth: state([first]))
        var equivalent = first
        equivalent.id = "aa-bb-cc-dd-ee-ff"
        XCTAssertFalse(coordinator.updateBluetooth(state([equivalent])).requiresAudioRefresh)
        XCTAssertEqual(coordinator.audio.outputKind, .bluetoothHeadphones)
    }

    func testExplicitDisconnectDisablesStaleHALRouteUntilItActuallySwitches() {
        let raw = route(first)
        var coordinator = AudioBluetoothCoordinator(audio: raw, bluetooth: state([first]))
        let disconnected = BluetoothState(authorization: .allowed, power: .on, devices: [],
                                          disconnectedDeviceIDs: [first.id])
        let update = coordinator.updateBluetooth(disconnected)
        XCTAssertTrue(update.requiresAudioRefresh)
        XCTAssertTrue(update.connectionMembershipChanged)
        XCTAssertEqual(update.audio.outputKind, .unavailable)
        XCTAssertEqual(update.audio.volume, 0)
        XCTAssertFalse(update.audio.canSetVolume)
        XCTAssertFalse(update.audio.canSetMute)
        XCTAssertEqual(update.audio.outputUID, raw.outputUID)
        XCTAssertEqual(update.audio.outputIdentifier, raw.outputIdentifier)
        XCTAssertEqual(update.audio.outputDeviceID, raw.outputDeviceID)
        XCTAssertFalse(update.outputIdentityChanged)
        let staleHAL = coordinator.updateAudio(raw)
        XCTAssertEqual(staleHAL.audio.outputKind, .unavailable)
        XCTAssertFalse(staleHAL.outputIdentityChanged)
        let builtIn = AudioState(volume: 0.7, canSetVolume: true, outputName: "Mac Speakers", outputDeviceID: 10,
                                 outputUID: "built-in", outputIdentifier: "route:builtin", outputKind: .builtInSpeaker)
        let settled = coordinator.updateAudio(builtIn)
        XCTAssertTrue(settled.outputIdentityChanged)
        XCTAssertEqual(settled.audio.outputKind, .builtInSpeaker)
        XCTAssertTrue(settled.audio.canSetVolume)
    }

    func testMissingConnectedMembershipDoesNotInventADisconnect() {
        let raw = route(first)
        var coordinator = AudioBluetoothCoordinator(audio: raw, bluetooth: state([first]))
        let noListYet = coordinator.updateBluetooth(state([]))
        XCTAssertEqual(noListYet.audio.outputKind, .bluetoothAudio)
        XCTAssertEqual(noListYet.audio.volume, raw.volume)
        XCTAssertTrue(noListYet.audio.canSetVolume)
        XCTAssertTrue(noListYet.audio.canSetMute)
    }

    func testPowerOffDisablesBluetoothControlsButPermissionDenialDoesNotClaimRadioOff() {
        var coordinator = AudioBluetoothCoordinator(audio: route(first), bluetooth: state([first]))
        let off = coordinator.updateBluetooth(BluetoothState(authorization: .allowed, power: .off))
        XCTAssertEqual(off.audio.outputKind, .unavailable)
        XCTAssertFalse(off.audio.canSetVolume)
        XCTAssertFalse(off.audio.canSetMute)
        let denied = coordinator.updateBluetooth(BluetoothState(authorization: .denied, power: .unknown))
        XCTAssertEqual(denied.audio.outputKind, .bluetoothAudio)
        XCTAssertTrue(denied.audio.canSetVolume)
        XCTAssertTrue(denied.audio.canSetMute)
    }

    func testATombstoneDoesNotDisableBAndFreshAConnectRestoresControls() {
        var coordinator = AudioBluetoothCoordinator(audio: route(second, halID: 43), bluetooth: state([first, second]))
        let disconnectedA = BluetoothState(authorization: .allowed, power: .on, devices: [second],
                                           disconnectedDeviceIDs: [first.id])
        XCTAssertTrue(coordinator.updateBluetooth(disconnectedA).audio.canSetVolume)
        let staleA = coordinator.updateAudio(route(first))
        XCTAssertEqual(staleA.audio.outputKind, .unavailable)
        let reconnect = coordinator.updateBluetooth(state([first, second]))
        XCTAssertTrue(reconnect.connectionMembershipChanged)
        XCTAssertEqual(reconnect.audio.outputKind, .bluetoothHeadphones)
        XCTAssertTrue(reconnect.audio.canSetVolume)
        XCTAssertTrue(reconnect.audio.canSetMute)
        XCTAssertEqual(reconnect.audio.volume, route(first).volume)
    }

    func testNativeControlGuardRejectsDisconnectedUIDAndRestoresOnConnect() {
        let disconnected = BluetoothState(authorization: .allowed, power: .on, devices: [second],
                                          disconnectedDeviceIDs: [first.id])
        XCTAssertFalse(AudioBluetoothCoordinator.permitsControl(audio: route(first), bluetooth: disconnected))
        XCTAssertTrue(AudioBluetoothCoordinator.permitsControl(audio: route(second), bluetooth: disconnected))
        XCTAssertTrue(AudioBluetoothCoordinator.permitsControl(audio: route(first), bluetooth: state([first, second])))
        let off = BluetoothState(authorization: .allowed, power: .off)
        XCTAssertFalse(AudioBluetoothCoordinator.permitsControl(audio: route(first), bluetooth: off))
        let builtIn = AudioState(outputKind: .builtInSpeaker)
        XCTAssertTrue(AudioBluetoothCoordinator.permitsControl(audio: builtIn, bluetooth: off))
        XCTAssertTrue(AudioBluetoothCoordinator.permitsControl(audio: route(first), bluetooth: state([])))
        XCTAssertTrue(AudioBluetoothCoordinator.permitsControl(audio: route(first), bluetooth: BluetoothState(authorization: .denied)))
    }
}
