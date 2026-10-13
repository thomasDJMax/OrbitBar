import XCTest
@testable import OrbitBarCore

final class BluetoothConnectionSessionTests: XCTestCase {
    private let headphones = "AA:BB:CC:DD:EE:01"

    func testDisconnectWinsOverDelayedClassicAndCachedHIDReadback() {
        var session = BluetoothConnectionSession()
        let oldRead = session.beginRead()
        session.didDisconnect(headphones, serviceIDs: [10, 11])
        XCTAssertFalse(session.accepts(oldRead))
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: true))
        XCTAssertFalse(session.acceptsRegistryConnection(headphones, serviceIDs: [10, 11]))
        XCTAssertFalse(session.acceptsBattery(headphones, serviceIDs: [10]))
    }

    func testConnectEventWinsOverALaggingFalseReadbackUntilConfirmed() {
        var session = BluetoothConnectionSession()
        session.didConnect(headphones, at: 10)
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: false, now: 10.3))
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: true, now: 10.8))
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false))
        session.didConnect(headphones, at: 20)
        session.didDisconnect(headphones, at: 21)
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false))
    }

    func testUnconfirmedConnectExpiresAndCachedTrueCannotImmediatelyResurrectIt() {
        var session = BluetoothConnectionSession()
        session.didConnect(headphones, at: 10)
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: false, now: 10.3))
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false, now: 15.2,
            serviceIDs: [10], batteryServiceIDs: [11]))
        XCTAssertTrue(session.disconnectedDeviceIDs.contains(headphones))
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: true, now: 15.3))
        XCTAssertFalse(session.acceptsRegistryConnection(headphones, serviceIDs: [10]))
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false, now: 15.4))
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: true, now: 16))
        XCTAssertFalse(session.acceptsBattery(headphones, serviceIDs: [11]))
    }

    func testUntimedInferredConnectDoesNotGrantAnOptimisticConfirmationWindow() {
        var session = BluetoothConnectionSession()
        session.didConnect(headphones)
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false, now: 10.3))
    }

    func testConfirmedClassicFalseBlocksCachedHIDWhenDisconnectNotificationIsLost() {
        var session = BluetoothConnectionSession()
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: true, now: 1))
        session.observeBattery(headphones, serviceID: 11, observation: .init(overall: .percent(90)))
        let oldRead = session.beginRead()
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false, now: 2,
            serviceIDs: [10], batteryServiceIDs: [11]))
        XCTAssertTrue(session.disconnectedDeviceIDs.contains(headphones))
        XCTAssertFalse(session.accepts(oldRead))
        XCTAssertFalse(session.acceptsRegistryConnection(headphones, serviceIDs: [10]))
        XCTAssertFalse(session.acceptsBattery(headphones, serviceIDs: [11]))
        // The actual false -> true sequence can recover a missed connect event.
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: true, now: 3))
        XCTAssertFalse(session.disconnectedDeviceIDs.contains(headphones))
        XCTAssertFalse(session.acceptsBattery(headphones, serviceIDs: [11]))
    }

    func testAnInitialClassicFalseDoesNotDisconnectAnExistingBLEHIDConnection() {
        var session = BluetoothConnectionSession()
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false, now: 1))
        XCTAssertTrue(session.disconnectedDeviceIDs.isEmpty)
        XCTAssertTrue(session.acceptsRegistryConnection(headphones, serviceIDs: [10]))
    }

    func testExplicitDisconnectStillBlocksTheFirstCachedTrueAfterConfirmation() {
        var session = BluetoothConnectionSession()
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: true, now: 1))
        session.didDisconnect(headphones, serviceIDs: [10], at: 2)
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: true, now: 2.1))
        XCTAssertFalse(session.acceptsRegistryConnection(headphones, serviceIDs: [10]))
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false, now: 2.2))
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: true, now: 3))
    }

    func testClassicRecoveryRejectsAnOldDisconnectDeliveredAfterTheNewSession() {
        var session = BluetoothConnectionSession()
        session.didDisconnect(headphones, serviceIDs: [10], at: 10)
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false, now: 11))
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: true, now: 12))
        let newSessionRead = session.beginRead()
        XCTAssertFalse(session.didDisconnect(headphones, serviceIDs: [10], at: 10.5))
        XCTAssertFalse(session.isBlocked(headphones))
        XCTAssertTrue(session.accepts(newSessionRead))
        // Observed recovery is confirmed, so another false has no five-second grace.
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false, now: 12.1))
        XCTAssertTrue(session.isBlocked(headphones))
    }

    func testNewHIDServiceRecoveryRejectsALateOldDisconnectWithoutGrantingGrace() {
        var session = BluetoothConnectionSession()
        session.didDisconnect(headphones, serviceIDs: [10], at: 10)
        XCTAssertTrue(session.acceptsRegistryConnection(headphones, serviceIDs: [20], now: 12))
        let newSessionRead = session.beginRead()
        XCTAssertFalse(session.didDisconnect(headphones, serviceIDs: [10], at: 10.5))
        XCTAssertFalse(session.isBlocked(headphones))
        XCTAssertTrue(session.accepts(newSessionRead))
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false, now: 12.1))
        // No classic true confirmation means BLE HID remains a valid connection.
        XCTAssertTrue(session.acceptsRegistryConnection(headphones, serviceIDs: [20], now: 12.1))
    }

    func testRoutineTrueObservationsDoNotSwallowAGenuineDisconnectInTransit() {
        var classic = BluetoothConnectionSession()
        classic.didConnect(headphones, at: 10)
        XCTAssertTrue(classic.acceptsClassicConnection(headphones, isConnected: true, now: 12))
        XCTAssertTrue(classic.acceptsClassicConnection(headphones, isConnected: true, now: 13))
        XCTAssertTrue(classic.didDisconnect(headphones, at: 11))

        var hid = BluetoothConnectionSession()
        hid.didDisconnect(headphones, serviceIDs: [10], at: 10)
        XCTAssertTrue(hid.acceptsRegistryConnection(headphones, serviceIDs: [20], now: 12))
        XCTAssertTrue(hid.acceptsRegistryConnection(headphones, serviceIDs: [20], now: 15))
        XCTAssertTrue(hid.didDisconnect(headphones, serviceIDs: [20], at: 13))
    }

    func testSameAddressReconnectRequiresFreshBatteryObservation() {
        var session = BluetoothConnectionSession()
        session.observeBattery(headphones, serviceID: 10, observation: .init(overall: .percent(90)))
        session.didDisconnect(headphones, serviceIDs: [10])
        session.didConnect(headphones)
        session.observeBattery(headphones, serviceID: 10, observation: .init(overall: .percent(90)))
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: true))
        XCTAssertFalse(session.acceptsBattery(headphones, serviceIDs: [10]))
        session.batteryPropertiesChanged(serviceID: 10)
        session.observeBattery(headphones, serviceID: 10, observation: .init(overall: .percent(89)))
        XCTAssertTrue(session.acceptsBattery(headphones, serviceIDs: [10]))
    }

    func testMissedConnectRecoversOnlyAfterARealDisconnectedObservation() {
        var session = BluetoothConnectionSession()
        session.didDisconnect(headphones, serviceIDs: [10])
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: true))
        XCTAssertFalse(session.acceptsClassicConnection(headphones, isConnected: false))
        XCTAssertTrue(session.acceptsClassicConnection(headphones, isConnected: true))
        XCTAssertFalse(session.acceptsBattery(headphones, serviceIDs: [10]))
        XCTAssertTrue(session.acceptsBattery(headphones, serviceIDs: [20]))
    }

    func testRegistryReconnectCannotBeInferredFromAnUnchangedProvider() {
        var session = BluetoothConnectionSession()
        session.didDisconnect(headphones, serviceIDs: [10, 11])
        XCTAssertFalse(session.acceptsRegistryConnection(headphones, serviceIDs: [20, 11]))
        XCTAssertTrue(session.acceptsRegistryConnection(headphones, serviceIDs: [20, 21]))
    }

    func testASecondReadSupersedesTheFirstEvenWithoutANewConnectionEvent() {
        var session = BluetoothConnectionSession()
        let first = session.beginRead()
        let second = session.beginRead()
        XCTAssertFalse(session.accepts(first))
        XCTAssertTrue(session.accepts(second))
        session.batteryPropertiesChanged(serviceID: 10)
        XCTAssertFalse(session.accepts(second))
    }

    func testDelayedConnectCallbackCannotOverrideANewerDisconnect() {
        var session = BluetoothConnectionSession()
        XCTAssertTrue(session.didDisconnect(headphones, serviceIDs: [10], at: 10))
        XCTAssertFalse(session.didConnect(headphones, at: 5))
        XCTAssertTrue(session.isBlocked(headphones))
        XCTAssertTrue(session.didConnect(headphones, at: 11))
        XCTAssertFalse(session.isBlocked(headphones))
    }

    func testPropertyEventFromBeforeReconnectCannotMakeOldBatteryFresh() {
        var session = BluetoothConnectionSession()
        session.observeBattery(headphones, serviceID: 10, observation: .init(overall: .percent(90)))
        session.didDisconnect(headphones, serviceIDs: [10], at: 10)
        session.didConnect(headphones, at: 20)
        session.batteryPropertiesChanged(serviceID: 10, at: 15)
        session.observeBattery(headphones, serviceID: 10, observation: .init(overall: .percent(89)))
        XCTAssertFalse(session.acceptsBattery(headphones, serviceIDs: [10]))
        session.batteryPropertiesChanged(serviceID: 10, at: 21)
        session.observeBattery(headphones, serviceID: 10, observation: .init(overall: .percent(88)))
        XCTAssertTrue(session.acceptsBattery(headphones, serviceIDs: [10]))
    }

    func testSleepInvalidatesReadsAndOldBatteryUntilADevicePropertyUpdate() {
        var session = BluetoothConnectionSession()
        session.observeBattery(headphones, serviceID: 10, observation: .init(overall: .percent(90)))
        let pending = session.beginRead()
        session.suspend(serviceIDsByDevice: [headphones: [10]])
        session.observeBattery(headphones, serviceID: 10, observation: .init(overall: .percent(90)))
        XCTAssertFalse(session.accepts(pending))
        XCTAssertFalse(session.acceptsBattery(headphones, serviceIDs: [10]))
        session.batteryPropertiesChanged(serviceID: 10)
        session.observeBattery(headphones, serviceID: 10, observation: .init(overall: .percent(89)))
        XCTAssertTrue(session.acceptsBattery(headphones, serviceIDs: [10]))
    }

    func testNameOnlyPropertyEventDoesNotValidateAnUnchangedOldBattery() {
        var session = BluetoothConnectionSession()
        let battery = BluetoothRegistryBatteryObservation(left: .percent(90), right: .percent(89), caseLevel: .percent(95))
        session.observeBattery(headphones, serviceID: 10, observation: battery)
        session.didDisconnect(headphones, serviceIDs: [10], at: 10)
        session.didConnect(headphones, at: 20)
        session.observeBattery(headphones, serviceID: 10, observation: battery)
        session.batteryPropertiesChanged(serviceID: 10, at: 21)
        session.observeBattery(headphones, serviceID: 10, observation: battery)
        XCTAssertFalse(session.acceptsBattery(headphones, serviceIDs: [10]))
        session.batteryPropertiesChanged(serviceID: 10, at: 22)
        session.observeBattery(headphones, serviceID: 10, observation: .init(left: .percent(89), right: .percent(88), caseLevel: .percent(95)))
        XCTAssertTrue(session.acceptsBattery(headphones, serviceIDs: [10]))
    }

    @MainActor
    func testOutOfOrderAsyncReadCompletionCannotReplaceTheNewSession() async {
        let playback = BluetoothReadPlayback(deviceID: headphones)
        let older = BluetoothReadGate()
        let newer = BluetoothReadGate()
        await playback.connect()
        let oldTask = await playback.read(from: older)
        await older.waitUntilStarted()
        await playback.disconnect()
        let disconnected = await playback.displayedBattery()
        XCTAssertNil(disconnected)
        await playback.connect()
        let newTask = await playback.read(from: newer)
        await newer.waitUntilStarted()
        await newer.finish(42)
        await newTask.value
        // A cancelled HAL/registry request may still complete after a newer read.
        await older.finish(91)
        await oldTask.value
        let result = await playback.displayedBattery()
        XCTAssertEqual(result, 42)
    }
}

/// Hardware-free timing playback of the same session tokens used by the real
/// monitor. Continuations control completion order without sleeps or Bluetooth.
private actor BluetoothReadPlayback {
    private let deviceID: String
    private var session = BluetoothConnectionSession()
    private var battery: Int?

    init(deviceID: String) { self.deviceID = deviceID }

    func connect() { session.didConnect(deviceID); battery = nil }
    func disconnect() { session.didDisconnect(deviceID); battery = nil }
    func displayedBattery() -> Int? { battery }

    func read(from gate: BluetoothReadGate) -> Task<Void, Never> {
        let token = session.beginRead()
        return Task {
            let value = await gate.value()
            if session.accepts(token), !session.isBlocked(deviceID) { battery = value }
        }
    }
}

private actor BluetoothReadGate {
    private var started = false
    private var onStarted: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Int, Never>?

    func value() async -> Int {
        started = true
        onStarted?.resume()
        onStarted = nil
        return await withCheckedContinuation { result = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { onStarted = $0 }
    }

    func finish(_ value: Int) { result?.resume(returning: value); result = nil }
}
