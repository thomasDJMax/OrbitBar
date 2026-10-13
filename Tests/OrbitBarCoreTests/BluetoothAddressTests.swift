import XCTest
@testable import OrbitBarCore

final class BluetoothAddressTests: XCTestCase {
    func testCanonicalizesCompactColonAndHyphenAddresses() {
        for text in ["aabbccddeeff", "aa:bb:cc:dd:ee:ff", "aa-bb-cc-dd-ee-ff", " \naa-bb-cc-dd-ee-ff\t"] {
            XCTAssertEqual(BluetoothAddress.normalize(text), "AA:BB:CC:DD:EE:FF")
        }
    }

    func testRejectsUnicodeAndEmbeddedText() {
        for text in ["ＡＡＢＢＣＣＤＤＥＥＦＦ", "aa bb cc dd ee ff", "headset-aa-bb-cc-dd-ee-ff", "aa:bb:cc:dd:ee:fg"] {
            XCTAssertNil(BluetoothAddress.normalize(text), text)
        }
    }

    func testOctetBoundariesAndAddressLengthMustBeValid() {
        for text in ["a:abbccddeef:f", "aa:bb-cc:dd:ee:ff", "aa::bb:cc:dd:ee:ff", "aabbccddeef", "aabbccddeeff00"] {
            XCTAssertNil(BluetoothAddress.normalize(text), text)
        }
    }

    func testPlaceholderAddressesAreNotDeviceIdentities() {
        XCTAssertNil(BluetoothAddress.normalize("00:00:00:00:00:00"))
        XCTAssertNil(BluetoothAddress.normalize("ff:ff:ff:ff:ff:ff"))
        XCTAssertEqual(BluetoothAddress.normalize("00:11:22:33:44:55"), "00:11:22:33:44:55")
    }
}
