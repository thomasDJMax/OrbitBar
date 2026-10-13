import XCTest
@testable import OrbitBarCore

final class SystemSnapshotTests: XCTestCase {
    func testBatteryReadingsStayInsideDrawableRange() {
        XCTAssertEqual(BatteryState(isPresent: true, percent: -8).fraction, 0)
        XCTAssertEqual(BatteryState(isPresent: true, percent: 140).fraction, 1)
        XCTAssertNil(BatteryState().percent)
        XCTAssertEqual(BatteryState().fraction, 1)
    }

    func testVolumeDotsRespectMuteAndBoundaries() {
        let samples: [(Double, Int)] = [(0, 0), (0.01, 1), (0.25, 1), (0.26, 2), (0.5, 2), (0.75, 3), (1, 4)]
        for (volume, dots) in samples {
            XCTAssertEqual(AudioState(volume: volume).litDots, dots, "volume \(volume)")
            XCTAssertEqual(AudioState(volume: volume, isMuted: true).litDots, 0)
        }
        XCTAssertEqual(AudioState(volume: .nan).volume, 0)
        XCTAssertEqual(AudioState(volume: .infinity).volume, 0)
        XCTAssertEqual(AudioState(volume: -1).litDots, 0)
        XCTAssertEqual(AudioState(volume: 2).litDots, 4)
    }

    func testNetworkSignalClampsUnexpectedReadings() {
        XCTAssertEqual(NetworkState(signalLevel: -1).signalLevel, 0)
        XCTAssertEqual(NetworkState(signalLevel: 7).signalLevel, 3)
    }
}
