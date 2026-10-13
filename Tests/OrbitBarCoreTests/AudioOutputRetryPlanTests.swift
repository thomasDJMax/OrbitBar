import XCTest
@testable import OrbitBarCore

final class AudioOutputRetryPlanTests: XCTestCase {
    func testSlowHALSettlementGetsOnlyThreeAbsoluteDeadlines() {
        var plan = AudioOutputRetryPlan()
        plan.schedule(at: 10)
        let generation = plan.generation
        XCTAssertEqual(plan.nextDelay(at: 10, for: generation)!, 0.15, accuracy: 0.000_001)
        // A read taking time must not shift the following retries later.
        XCTAssertEqual(plan.nextDelay(at: 10.3, for: generation)!, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(plan.nextDelay(at: 10.7, for: generation)!, 0.5, accuracy: 0.000_001)
        XCTAssertNil(plan.nextDelay(at: 11.2, for: generation))
        XCTAssertFalse(plan.hasPendingRetries)
    }

    func testRapidNewConnectionEventSupersedesOldRetryGeneration() {
        var plan = AudioOutputRetryPlan()
        plan.schedule(at: 0)
        let old = plan.generation
        _ = plan.nextDelay(at: 0, for: old)
        plan.schedule(at: 0.1)
        XCTAssertNil(plan.nextDelay(at: 0.15, for: old))
        XCTAssertEqual(plan.nextDelay(at: 0.15, for: plan.generation)!, 0.1, accuracy: 0.000_001)
        XCTAssertTrue(plan.hasPendingRetries)
    }

    func testSleepOrStopCancellationInvalidatesTicketsAndCanStartFreshAfterWake() {
        var plan = AudioOutputRetryPlan()
        plan.schedule(at: 1)
        let sleeping = plan.generation
        plan.cancel()
        XCTAssertFalse(plan.hasPendingRetries)
        XCTAssertNil(plan.nextDelay(at: 2, for: sleeping))
        plan.schedule(at: 3)
        let awake = plan.generation
        XCTAssertEqual(plan.nextDelay(at: 3, for: awake)!, 0.15, accuracy: 0.000_001)
        plan.cancel()
        XCTAssertNil(plan.nextDelay(at: 4, for: awake))
    }
}
