import XCTest
@testable import OrbitBarCore

final class ObserverLifecycleTests: XCTestCase {
    func testAQueuedPayloadFromAnOldSubscriptionIsRejectedAfterTheBoundary() {
        var lifecycle = ObserverLifecycle()
        let beforeSleep = lifecycle.token
        lifecycle.invalidate()
        let afterWake = lifecycle.token
        XCTAssertFalse(lifecycle.accepts(beforeSleep))
        XCTAssertTrue(lifecycle.accepts(afterWake))
    }

    func testOlderSleepTaskCannotOverrideAnAlreadyHandledWake() {
        var lifecycle = ObserverLifecycle()
        XCTAssertTrue(lifecycle.acceptsEvent(at: 10))
        XCTAssertTrue(lifecycle.acceptsEvent(at: 20))
        XCTAssertFalse(lifecycle.acceptsEvent(at: 15))
        XCTAssertFalse(lifecycle.acceptsEvent(at: .nan))
        XCTAssertFalse(lifecycle.acceptsEvent(at: .infinity))
        XCTAssertTrue(lifecycle.acceptsEvent(at: 21))
    }

    func testClockAdmissionDoesNotRevokeTheActiveNativeSubscription() {
        var lifecycle = ObserverLifecycle()
        let subscription = lifecycle.token
        XCTAssertTrue(lifecycle.acceptsEvent(at: 10))
        XCTAssertTrue(lifecycle.accepts(subscription))
        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.accepts(subscription))
    }

    func testPowerOnHandledBeforeQueuedOffStillRevokesOldDevicePayloads() {
        var manager = ObserverLifecycle()
        var devices = ObserverLifecycle()
        let centralRegistration = manager.token
        let beforePowerTransition = devices.token
        // Native's accepted state callback revokes device observations before
        // reading current power, including when on's task is handled first.
        XCTAssertTrue(manager.accepts(centralRegistration))
        XCTAssertTrue(manager.acceptsEvent(at: 20))
        devices.invalidate()
        XCTAssertFalse(manager.acceptsEvent(at: 10))
        XCTAssertFalse(devices.accepts(beforePowerTransition))
        XCTAssertTrue(manager.accepts(centralRegistration), "The same manager must keep watching power/auth transitions.")
        // A later sleep/stop replaces the manager itself as well.
        manager.invalidate()
        XCTAssertFalse(manager.accepts(centralRegistration))
    }
}
