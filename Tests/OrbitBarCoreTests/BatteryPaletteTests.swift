import XCTest
@testable import OrbitBarCore

final class BatteryPaletteTests: XCTestCase {
    func testRequestedMilestoneColors() {
        XCTAssertEqual(BatteryPalette.color(for: 0), RGBColor(red: 1, green: 69.0 / 255, blue: 58.0 / 255))
        XCTAssertEqual(BatteryPalette.color(for: 25), RGBColor(red: 247.0 / 255, green: 223.0 / 255, blue: 142.0 / 255))
        XCTAssertEqual(BatteryPalette.color(for: 50), RGBColor(red: 1, green: 214.0 / 255, blue: 10.0 / 255))
        XCTAssertEqual(BatteryPalette.color(for: 75), RGBColor(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255))
        XCTAssertEqual(BatteryPalette.color(for: 100), RGBColor(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255))
    }

    func testColorChangesAtTheRequestedBoundaries() {
        let red = RGBColor(red: 1, green: 69.0 / 255, blue: 58.0 / 255)
        let paleYellow = RGBColor(red: 247.0 / 255, green: 223.0 / 255, blue: 142.0 / 255)
        let yellow = RGBColor(red: 1, green: 214.0 / 255, blue: 10.0 / 255)
        let green = RGBColor(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255)

        XCTAssertEqual(BatteryPalette.color(for: 24), red)
        XCTAssertEqual(BatteryPalette.color(for: 26), paleYellow)
        XCTAssertEqual(BatteryPalette.color(for: 49), paleYellow)
        XCTAssertEqual(BatteryPalette.color(for: 51), yellow)
        XCTAssertEqual(BatteryPalette.color(for: 74), yellow)
        XCTAssertEqual(BatteryPalette.color(for: 76), green)
        XCTAssertEqual(BatteryPalette.color(for: 99), green)
    }

    func testUnexpectedPercentagesUseTheNearestEndpointColor() {
        let red = RGBColor(red: 1, green: 69.0 / 255, blue: 58.0 / 255)
        let green = RGBColor(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255)

        XCTAssertEqual(BatteryPalette.color(for: -1), red)
        XCTAssertEqual(BatteryPalette.color(for: .min), red)
        XCTAssertEqual(BatteryPalette.color(for: 101), green)
        XCTAssertEqual(BatteryPalette.color(for: .max), green)
    }
}
