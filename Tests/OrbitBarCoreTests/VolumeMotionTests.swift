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

    func testSixtyAndThirtyFPSAgreeAcrossInterleavedDirectionChanges() {
        var sixty = VolumeMotion(value: 0.5)
        var thirty = sixty
        // Input arrives between render ticks, including full-range reversals,
        // small changes within one dot, mute, and immediate restoration.
        let inputs: [Int: Double] = [42: 0.3, 246: 0.9, 378: 0.2, 546: 0.8,
                                     780: 0.1, 1104: 0.5, 1242: 0.501,
                                     1464: 0.499, 2400: 0, 2550: 1]
        for tick in 0...9600 {
            let time = Double(tick) / 6000
            if let target = inputs[tick] {
                sixty.retarget(to: target, at: time)
                thirty.retarget(to: target, at: time)
            }
            if tick.isMultiple(of: 100) { _ = sixty.sample(at: time) }
            if tick.isMultiple(of: 200) {
                let frequent = sixty.sample(at: time)
                let sparse = thirty.sample(at: time)
                XCTAssertEqual(frequent.volume, sparse.volume, accuracy: 0.000_000_001, "volume at \(time)")
                XCTAssertEqual(frequent.emphasis, sparse.emphasis, accuracy: 0.000_000_001, "pulse at \(time)")
                XCTAssertTrue((0...1).contains(frequent.volume))
                XCTAssertTrue((0...1).contains(frequent.emphasis))
                XCTAssertEqual(sixty.isActive, thirty.isActive)
            }
        }
        XCTAssertEqual(sixty.sample(at: 1.6), VolumeMotionFrame(volume: 1, emphasis: 0))
        XCTAssertFalse(sixty.isActive)
        XCTAssertFalse(thirty.isActive)
    }

    func testPausedRenderingCatchesUpWithoutReplayingAnExpiredPulse() {
        var rendering = VolumeMotion(value: 0.7)
        var paused = rendering
        for (time, target) in [(0.0, 0.1), (0.08, 0.9)] {
            rendering.retarget(to: target, at: time)
            paused.retarget(to: target, at: time)
        }
        for tick in 6...24 { _ = rendering.sample(at: Double(tick) / 60) }
        let runningFrame = rendering.sample(at: 0.4)
        let resumedFrame = paused.sample(at: 0.4)
        XCTAssertEqual(runningFrame.volume, resumedFrame.volume, accuracy: 0.000_000_001)
        XCTAssertEqual(runningFrame.emphasis, resumedFrame.emphasis, accuracy: 0.000_000_001)
        // A stalled main loop must not replay the original rise on its first
        // tick, nor leave a timer alive for a pulse that expired while paused.
        XCTAssertEqual(paused.sample(at: 10_000), VolumeMotionFrame(volume: 0.9, emphasis: 0))
        XCTAssertFalse(paused.isActive)
        paused.retarget(to: 0.3, at: 10_000)
        XCTAssertEqual(paused.sample(at: 10_000).emphasis, 0)
        XCTAssertGreaterThan(paused.sample(at: 10_000.04).emphasis, 0)
        XCTAssertEqual(paused.sample(at: 10_001), VolumeMotionFrame(volume: 0.3, emphasis: 0))
        XCTAssertFalse(paused.isActive)
    }

    func testPulseRetriggerAndRiseToDecayBoundaryStayContinuous() {
        var motion = VolumeMotion(value: 0.5)
        motion.retarget(to: 0.6, at: 0)
        let before = motion.sample(at: 0.06)
        motion.retarget(to: 0.61, at: 0.06)
        XCTAssertEqual(motion.sample(at: 0.06), before)
        let rising = motion.sample(at: 0.139_999)
        let falling = motion.sample(at: 0.140_001)
        XCTAssertEqual(rising.volume, falling.volume, accuracy: 0.000_01)
        XCTAssertEqual(rising.emphasis, falling.emphasis, accuracy: 0.000_01)
        XCTAssertGreaterThan(falling.emphasis, 0.5)
        XCTAssertEqual(motion.sample(at: 1), VolumeMotionFrame(volume: 0.61, emphasis: 0))
        XCTAssertFalse(motion.isActive)
    }

    func testRetargetWithRegressingTimestampPreservesCurrentFrameAndStillFinishes() {
        var motion = VolumeMotion(value: 0.3)
        motion.retarget(to: 0.8, at: 10)
        let displayed = motion.sample(at: 10.08)
        motion.retarget(to: 0.1, at: 9)
        XCTAssertEqual(motion.sample(at: 9), displayed)
        XCTAssertGreaterThan(motion.sample(at: 10.080_01).volume, displayed.volume)
        XCTAssertEqual(motion.sample(at: 11), VolumeMotionFrame(volume: 0.1, emphasis: 0))
        XCTAssertFalse(motion.isActive)
    }
}
