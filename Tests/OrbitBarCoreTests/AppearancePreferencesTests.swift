import XCTest
@testable import OrbitBarCore

final class AppearancePreferencesTests: XCTestCase {
    func testExistingInRangeCustomizationIsPreserved() {
        XCTAssertEqual(AppearancePreferences.normalizedIconScale(0.85), 0.85)
        XCTAssertEqual(AppearancePreferences.normalizedRingThickness(2.15), 2.15)
    }

    func testMissingAndCorruptValuesUseDefaults() {
        let invalidValues: [Double?] = [nil, .nan, .infinity, -.infinity]
        for value in invalidValues {
            XCTAssertEqual(AppearancePreferences.normalizedIconScale(value), 1.6)
            XCTAssertEqual(AppearancePreferences.normalizedRingThickness(value), 3.3)
        }
    }

    func testInvalidLiveValueKeepsPreviousSafeValue() {
        XCTAssertEqual(AppearancePreferences.normalizedIconScale(.nan, fallback: 1.25), 1.25)
        XCTAssertEqual(AppearancePreferences.normalizedRingThickness(.infinity, fallback: 2.4), 2.4)
        XCTAssertEqual(AppearancePreferences.normalizedIconScale(.nan, fallback: .nan), 1.6)
    }

    func testOutOfRangeValuesClampToSupportedDrawingBounds() {
        XCTAssertEqual(AppearancePreferences.normalizedIconScale(-10), 0.65)
        XCTAssertEqual(AppearancePreferences.normalizedIconScale(100), 1.6)
        XCTAssertEqual(AppearancePreferences.normalizedRingThickness(-10), 1.5)
        XCTAssertEqual(AppearancePreferences.normalizedRingThickness(100), 4.2)
    }

    func testStoredNumbersRejectUnexpectedPreferenceTypes() {
        XCTAssertNil(AppearancePreferences.storedNumber(nil))
        XCTAssertNil(AppearancePreferences.storedNumber("1.25"))
        XCTAssertNil(AppearancePreferences.storedNumber(true))
        XCTAssertNil(AppearancePreferences.storedNumber([1.25]))
        XCTAssertEqual(AppearancePreferences.storedNumber(NSNumber(value: 1.25)), 1.25)
        XCTAssertEqual(AppearancePreferences.storedNumber(NSNumber(value: 2)), 2)
    }
}
