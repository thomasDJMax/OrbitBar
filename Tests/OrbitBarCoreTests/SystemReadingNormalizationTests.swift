import XCTest
@testable import OrbitBarCore

final class SystemReadingNormalizationTests: XCTestCase {
    func testUnknownAndMalformedBatteryValuesStayUnknown() {
        let invalidCurrent: [Double?] = [nil, -1, .nan, .infinity]
        for current in invalidCurrent {
            XCTAssertNil(SystemReadingNormalization.batteryPercent(current: current, maximum: 100))
        }
        let invalidMaximum: [Double?] = [nil, 0, -1, .nan, .infinity]
        for maximum in invalidMaximum {
            XCTAssertNil(SystemReadingNormalization.batteryPercent(current: 50, maximum: maximum))
        }
        XCTAssertEqual(SystemReadingNormalization.batteryPercent(current: 50, maximum: 100), 50)
        XCTAssertEqual(SystemReadingNormalization.batteryPercent(current: 0, maximum: 100), 0)
        XCTAssertEqual(SystemReadingNormalization.batteryPercent(current: .greatestFiniteMagnitude, maximum: .leastNonzeroMagnitude), 100)
    }

    func testInvalidNominalCapacityFallsBackToRawCapacity() {
        XCTAssertEqual(SystemReadingNormalization.healthPercent(design: 5_000, nominal: 0, raw: 4_500, legacy: 90), 90)
        XCTAssertEqual(SystemReadingNormalization.healthPercent(design: 5_000, nominal: .nan, raw: nil, legacy: 4_000), 80)
        XCTAssertEqual(SystemReadingNormalization.healthPercent(design: 5_000, nominal: 5_100, raw: nil, legacy: nil), 100)
        // Apple's percentage-valued legacy MaxCapacity must not be divided by mAh.
        XCTAssertNil(SystemReadingNormalization.healthPercent(design: 5_000, nominal: nil, raw: nil, legacy: 100))
    }

    func testTimeToEmptyRequiresAnActualDischargingBattery() {
        XCTAssertEqual(SystemReadingNormalization.minutesRemaining(120, onBattery: true, charging: false), 120)
        XCTAssertNil(SystemReadingNormalization.minutesRemaining(120, onBattery: false, charging: false))
        XCTAssertNil(SystemReadingNormalization.minutesRemaining(120, onBattery: true, charging: true))
        XCTAssertNil(SystemReadingNormalization.minutesRemaining(-1, onBattery: true, charging: false))
        XCTAssertNil(SystemReadingNormalization.minutesRemaining(0, onBattery: true, charging: false))
    }
}
