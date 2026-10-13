import XCTest
@testable import OrbitBarCore

final class VolumeMotionTests: XCTestCase {
    func testRetargetStartsWithoutAJumpAndContinuesCurrentMomentum() {
        var motion = VolumeMotion(value: 0.2)
        motion.retarget(to: 0.9, at: 10)
        XCTAssertEqual(motion.sample(at: 10).volume, 0.2, accuracy: 0.000_000_1)
        XCTAssertTrue(motion.isActive)

        let beforeReversal = motion.sample(at: 10.08)
        XCTAssertGreaterThan(beforeReversal.volume, 0.2)
        XCTAssertLessThan(beforeReversal.volume, 0.9)
        motion.retarget(to: 0.1, at: 10.08)
        XCTAssertEqual(motion.sample(at: 10.08), beforeReversal)
        // A reversal first decelerates the existing movement, instead of
        // abruptly replacing an upward velocity with a downward one.
        XCTAssertGreaterThan(motion.sample(at: 10.080_01).volume, beforeReversal.volume)
        XCTAssertLessThan(motion.sample(at: 10.3).volume, beforeReversal.volume)
        XCTAssertEqual(motion.sample(at: 12).volume, 0.1)
        XCTAssertFalse(motion.isActive)
    }

    func testRapidAlternatingTargetsStayFiniteAndBoundedThenStop() {
        var motion = VolumeMotion(value: 0.01)
        var time = 0.0
        for index in 0..<100 {
            motion.retarget(to: index.isMultiple(of: 2) ? 1 : 0, at: time)
            time += 0.008
            let frame = motion.sample(at: time)
            XCTAssertTrue(frame.volume.isFinite)
            XCTAssertTrue(frame.emphasis.isFinite)
            XCTAssertTrue((0...1).contains(frame.volume))
            XCTAssertTrue((0...1).contains(frame.emphasis))
        }
        let final = motion.sample(at: time + 2)
        XCTAssertEqual(final, VolumeMotionFrame(volume: 0, emphasis: 0))
        XCTAssertFalse(motion.isActive)
    }

    func testMuteAndRestoreFinishAtTheirExactRequestedVolumes() {
        var motion = VolumeMotion(value: 0.76)
        motion.retarget(to: 0, at: 0)
        let muting = motion.sample(at: 0.1)
        XCTAssertGreaterThan(muting.volume, 0)
        XCTAssertLessThan(muting.volume, 0.76)
        XCTAssertEqual(motion.sample(at: 1), VolumeMotionFrame(volume: 0, emphasis: 0))
        XCTAssertFalse(motion.isActive)

        motion.retarget(to: 0.76, at: 1)
        XCTAssertEqual(motion.sample(at: 1).volume, 0)
        XCTAssertEqual(motion.sample(at: 2), VolumeMotionFrame(volume: 0.76, emphasis: 0))
        XCTAssertFalse(motion.isActive)
    }

    func testReducedMotionUpdatesImmediatelyAndCancelsAnExistingPulse() {
        var motion = VolumeMotion(value: 0.4)
        motion.retarget(to: 1, at: 1)
        XCTAssertGreaterThan(motion.sample(at: 1.05).emphasis, 0)
        motion.retarget(to: 0.3, at: 1.05, reducedMotion: true)
        XCTAssertEqual(motion.sample(at: 1.05), VolumeMotionFrame(volume: 0.3, emphasis: 0))
        XCTAssertFalse(motion.isActive)
        XCTAssertEqual(motion.sample(at: 2), VolumeMotionFrame(volume: 0.3, emphasis: 0))
    }

    func testSettleStopsAnInFlightTransitionAtTheLatestTarget() {
        var motion = VolumeMotion(value: 0)
        motion.retarget(to: 0.8, at: 3)
        _ = motion.sample(at: 3.04)
        motion.settle(at: 3.05)
        XCTAssertEqual(motion.sample(at: 3.05), VolumeMotionFrame(volume: 0.8, emphasis: 0))
        XCTAssertFalse(motion.isActive)
    }

    func testSmallChangesWithinOneDotPulseButRepeatedReadingsDoNot() {
        var motion = VolumeMotion(value: 0.55)
        motion.retarget(to: 0.56, at: 0)
        XCTAssertEqual(motion.sample(at: 0).emphasis, 0)
        XCTAssertGreaterThan(motion.sample(at: 0.08).emphasis, 0.5)
        XCTAssertEqual(motion.sample(at: 1), VolumeMotionFrame(volume: 0.56, emphasis: 0))
        XCTAssertFalse(motion.isActive)
        motion.retarget(to: 0.56, at: 1.1)
        XCTAssertEqual(motion.sample(at: 1.2).emphasis, 0)
        XCTAssertFalse(motion.isActive)
    }

    func testSamplingRateDoesNotChangeTheMotionAtTheSameTime() {
        var frequent = VolumeMotion(value: 0.2)
        var sparse = frequent
        frequent.retarget(to: 0.8, at: 0)
        sparse.retarget(to: 0.8, at: 0)
        for tick in 1...20 { _ = frequent.sample(at: Double(tick) / 100) }
        let frequentFrame = frequent.sample(at: 0.2)
        let sparseFrame = sparse.sample(at: 0.2)
        XCTAssertEqual(frequentFrame.volume, sparseFrame.volume, accuracy: 0.000_000_1)
        XCTAssertEqual(frequentFrame.emphasis, sparseFrame.emphasis, accuracy: 0.000_000_1)
    }

    func testInvalidInputAndRegressingClockDoNotCorruptState() {
        var motion = VolumeMotion(value: .nan)
        XCTAssertEqual(motion.sample(at: .nan), VolumeMotionFrame(volume: 0, emphasis: 0))
        motion.retarget(to: 2, at: 1)
        let frame = motion.sample(at: 1.1)
        XCTAssertEqual(motion.sample(at: 0), frame)
        XCTAssertEqual(motion.sample(at: .infinity), frame)
        motion.retarget(to: -.infinity, at: 1.1, reducedMotion: true)
        XCTAssertEqual(motion.sample(at: 2), VolumeMotionFrame(volume: 0, emphasis: 0))
        XCTAssertFalse(motion.isActive)
    }
}
