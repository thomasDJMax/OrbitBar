import XCTest
@testable import OrbitBarCore

final class VolumeAnimationPolicyTests: XCTestCase {
    private func output(id: UInt32 = 7, uid: String = "headphones", route: String = "headphones:output") -> AudioState {
        AudioState(volume: 0.4, outputName: "耳机", outputDeviceID: id, outputUID: uid,
                   outputIdentifier: route, outputKind: .bluetoothHeadphones)
    }

    func testInitialReadingSettlesAndVolumeChangesOnSameOutputAnimate() {
        var policy = VolumeAnimationPolicy()
        var audio = output()
        XCTAssertFalse(policy.shouldAnimate(audio))
        audio.volume = 0.8
        XCTAssertTrue(policy.shouldAnimate(audio))
        audio.isMuted = true
        XCTAssertTrue(policy.shouldAnimate(audio))
    }

    func testReconnectWithNewHALIDSettlesEvenWhenUIDAndRouteStayTheSame() {
        var policy = VolumeAnimationPolicy()
        _ = policy.shouldAnimate(output())
        XCTAssertFalse(policy.shouldAnimate(output(id: 18)))
        XCTAssertTrue(policy.shouldAnimate(output(id: 18)))
    }

    func testReusedHALIDWithNewUIDSettles() {
        var policy = VolumeAnimationPolicy()
        _ = policy.shouldAnimate(output())
        XCTAssertFalse(policy.shouldAnimate(output(uid: "other-headphones")))
    }

    func testRouteChangeOnSamePhysicalDeviceSettles() {
        var policy = VolumeAnimationPolicy()
        _ = policy.shouldAnimate(output())
        XCTAssertFalse(policy.shouldAnimate(output(route: "headphones:other-stream")))
    }

    func testUnavailableOutputClearsHistoryBeforeSameRouteReturns() {
        var policy = VolumeAnimationPolicy()
        var audio = output()
        _ = policy.shouldAnimate(audio)
        audio.outputKind = .unavailable
        XCTAssertFalse(policy.shouldAnimate(audio))
        XCTAssertFalse(policy.shouldAnimate(output()))
        XCTAssertTrue(policy.shouldAnimate(output()))
    }

    func testMetadataUpdatesDoNotInterruptAnUnchangedActualRoute() {
        var policy = VolumeAnimationPolicy()
        var audio = output()
        _ = policy.shouldAnimate(audio)
        audio.outputName = "重命名耳机"
        audio.outputKind = .bluetoothAudio
        audio.bluetoothDeviceID = "AA:BB:CC:DD:EE:FF"
        XCTAssertTrue(policy.shouldAnimate(audio))
    }

    func testMissingOrInvalidRouteCannotAnimateRepeatedReadings() {
        for audio in [AudioState(outputKind: .builtInSpeaker), output(id: 0),
                      AudioState(outputDeviceID: 7, outputKind: .builtInSpeaker)] {
            var policy = VolumeAnimationPolicy()
            XCTAssertFalse(policy.shouldAnimate(audio))
            XCTAssertFalse(policy.shouldAnimate(audio))
        }
    }
}
