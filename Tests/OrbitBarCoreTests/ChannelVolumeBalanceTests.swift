import XCTest
@testable import OrbitBarCore

final class ChannelVolumeBalanceTests: XCTestCase {
    func testAdjustingVolumePreservesBalanceAndSilentChannels() {
        var balance = ChannelVolumeBalance()
        let adjusted = balance.scaledVolumes(device: 1, current: [1: 0.8, 2: 0.4, 3: 0], target: 1)
        XCTAssertEqual(adjusted, [1: 1, 2: 0.5, 3: 0])
    }

    func testRepeatedMuteAndRestoreKeepsOriginalBalance() {
        var balance = ChannelVolumeBalance()
        let muted = balance.scaledVolumes(device: 1, current: [1: 0.8, 2: 0.4], target: 0)
        let stillMuted = balance.scaledVolumes(device: 1, current: muted, target: 0)
        let restored = balance.scaledVolumes(device: 1, current: stillMuted, target: 0.8)
        XCTAssertEqual(restored[1] ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(restored[2] ?? -1, 0.4, accuracy: 0.0001)
    }

    func testDeviceChangesAndExternalBalanceChangesAreRespected() {
        var balance = ChannelVolumeBalance()
        _ = balance.scaledVolumes(device: 1, current: [1: 1, 2: 0.5], target: 0)
        let other = balance.scaledVolumes(device: 2, current: [1: 0, 2: 0], target: 0.6)
        XCTAssertEqual(other, [1: 0.6, 2: 0.6])
        let changed = balance.scaledVolumes(device: 1, current: [1: 0.2, 2: 0.8], target: 1)
        XCTAssertEqual(changed, [1: 0.25, 2: 1])
    }

    func testMutedLayoutChangeDoesNotReuseRatiosFromPreviousLayout() {
        var balance = ChannelVolumeBalance()
        _ = balance.scaledVolumes(device: 1, current: [1: 1, 2: 0], target: 0)
        let expanded = balance.scaledVolumes(device: 1, current: [1: 0, 2: 0, 3: 0], target: 0.5)
        XCTAssertEqual(expanded, [1: 0.5, 2: 0.5, 3: 0.5])
    }

    func testOutputSwitchClearsSavedMutedBalance() {
        var balance = ChannelVolumeBalance()
        _ = balance.scaledVolumes(device: 1, current: [1: 1, 2: 0], target: 0)
        balance.reset()
        let restored = balance.scaledVolumes(device: 1, current: [1: 0, 2: 0], target: 0.5)
        XCTAssertEqual(restored, [1: 0.5, 2: 0.5])
    }
}
