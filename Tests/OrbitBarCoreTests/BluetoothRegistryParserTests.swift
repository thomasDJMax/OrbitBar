import XCTest
@testable import OrbitBarCore

final class BluetoothRegistryParserTests: XCTestCase {
    private let firstAddress = "AA:BB:CC:DD:EE:01"
    private let secondAddress = "AA:BB:CC:DD:EE:02"

    private func node(_ id: UInt64, _ properties: [String: Any], device: Bool = true,
                      hid: Bool = false) -> BluetoothRegistryNode {
        BluetoothRegistryNode(serviceID: id, properties: properties, isDeviceProvider: device, isHIDDevice: hid)
    }

    func testBatteryZeroIsValidAndAbsenceRemainsUnknown() {
        let observation = BluetoothRegistryBatteryObservation(properties: ["BatteryPercentLeft": 0, "BatteryPercentCase": 0])
        XCTAssertEqual(observation.left, .percent(0))
        XCTAssertEqual(observation.caseLevel, .percent(0))
        XCTAssertEqual(observation.right, .absent)
        XCTAssertNil(observation.battery.overall)
        XCTAssertEqual(observation.battery.left, 0)
        XCTAssertEqual(observation.battery.summary, "左耳 0% · 盒 0%")
    }

    func testBatterySentinelsAndUnexpectedTypesAreExplicitInvalidObservations() {
        let values: [Any] = [-1, 255, UInt64.max, true, "85", Data([85]), Double.nan, Double.infinity, 100.01]
        for raw in values {
            let observation = BluetoothRegistryBatteryObservation(properties: ["BatteryPercent": raw])
            XCTAssertEqual(observation.overall, .invalid)
            XCTAssertTrue(observation.hasObservation)
            XCTAssertFalse(observation.battery.hasReading)
        }
        XCTAssertFalse(BluetoothRegistryBatteryObservation(properties: [:]).hasObservation)
        XCTAssertEqual(BluetoothRegistryBatteryObservation(properties: ["BatteryPercent": 49.7]).overall, .percent(50))
    }

    func testConflictingAddressAliasesAreRejectedAndCaseEquivalentAliasesAgree() {
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["DeviceAddress": firstAddress, "BluetoothAddress": secondAddress]), .conflicting)
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["DeviceAddress": firstAddress.lowercased(),
            "BluetoothAddress": firstAddress.replacingOccurrences(of: ":", with: "-")]), .address(firstAddress))
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["BD_ADDR": Data([0, 1, 2, 3, 4, 5])]), .invalid,
                       "A registry blob without a connected-address match must not become an invented MAC.")
    }

    func testRegistryBytesRequireOneConfirmedConnectedAddressInEitherOrder() {
        let bytes = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01])
        let reverse = "01:EE:DD:CC:BB:AA"
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["BD_ADDR": bytes],
            knownConnectedAddresses: [firstAddress]), .address(firstAddress))
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["BD_ADDR": bytes as NSData],
            knownConnectedAddresses: [reverse]), .address(reverse))
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["BD_ADDR": bytes],
            knownConnectedAddresses: [firstAddress.lowercased().replacingOccurrences(of: ":", with: "-")]), .address(firstAddress))
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["BD_ADDR": bytes],
            knownConnectedAddresses: [secondAddress]), .invalid)
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["BD_ADDR": bytes],
            knownConnectedAddresses: [firstAddress, reverse]), .invalid,
            "Two different connected matches leave the vendor byte order ambiguous.")
    }

    func testRegistryBytesRejectInvalidLengthPlaceholdersAndUnvalidatedPropertyTypes() {
        for bytes in [Data([1, 2, 3, 4, 5]), Data([1, 2, 3, 4, 5, 6, 7]),
                      Data(repeating: 0, count: 6), Data(repeating: 0xFF, count: 6)] {
            XCTAssertEqual(BluetoothRegistryParser.address(properties: ["BD_ADDR": bytes],
                knownConnectedAddresses: [firstAddress, "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF"]), .invalid)
        }
        let bytes = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01])
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["DeviceAddress": bytes],
            knownConnectedAddresses: [firstAddress]), .invalid,
            "Only the observed BD_ADDR blob property is cross-validated.")
    }

    func testStringAddressRemainsIndependentAndConflictingConfirmedBlobIsRejected() {
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["DeviceAddress": firstAddress],
            knownConnectedAddresses: [secondAddress]), .address(firstAddress))
        let bytes = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x02])
        XCTAssertEqual(BluetoothRegistryParser.address(properties: ["DeviceAddress": firstAddress, "BD_ADDR": bytes],
            knownConnectedAddresses: [secondAddress]), .conflicting)
    }

    func testConfirmedProviderBlobCarriesIdentityAndWholeBatteryWithoutNativeDeviceAccess() throws {
        let leaf = node(10, ["Transport": "BluetoothLowEnergy"], hid: true)
        let properties: [String: Any] = ["BD_ADDR": Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01]),
                                       "BatteryPercentLeft": 0, "BatteryPercentCase": 42]
        XCTAssertNil(BluetoothRegistryParser.parse(nodes: [leaf, node(20, properties)]))
        let confirmedProvider = BluetoothRegistryNode(serviceID: 20, properties: properties,
            isDeviceProvider: true, knownConnectedAddresses: [firstAddress])
        let record = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [leaf, confirmedProvider]))
        XCTAssertEqual(record.address, firstAddress)
        XCTAssertEqual(record.addressEvidence, .provider)
        XCTAssertEqual(record.battery, BluetoothBatteryState(left: 0, caseLevel: 42))
        XCTAssertEqual(record.batteryServiceID, 20)
    }

    func testControllerParentCannotSupplyAddressBatteryOrDeviceClass() {
        let leaf = node(1, ["Transport": "Bluetooth", "PrimaryUsagePage": 1, "PrimaryUsage": 6], hid: true)
        let controller = node(2, ["DeviceAddress": firstAddress, "BatteryPercent": 87, "Product": "Other device"], device: false)
        XCTAssertNil(BluetoothRegistryParser.parse(nodes: [leaf, controller]))
    }

    func testDifferentParentAddressCannotLeakItsBatteryNameOrKind() throws {
        let leaf = node(1, ["DeviceAddress": firstAddress, "Transport": "Bluetooth",
                            "PrimaryUsagePage": 1, "PrimaryUsage": 6], hid: true)
        let otherDevice = node(2, ["DeviceAddress": secondAddress, "BatteryPercent": 87,
                                   "Product": "Wrong mouse", "PrimaryUsagePage": 1, "PrimaryUsage": 2])
        let record = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [leaf, otherDevice]))
        XCTAssertEqual(record.address, firstAddress)
        XCTAssertEqual(record.kind, .keyboard)
        XCTAssertNil(record.name)
        XCTAssertFalse(record.battery.hasReading)
        XCTAssertEqual(record.observedServiceIDs, [1])
    }

    func testUSBOrInvalidIdentityDoesNotInheritABluetoothProvider() {
        let provider = node(2, ["DeviceAddress": firstAddress, "BatteryPercent": 87])
        XCTAssertNil(BluetoothRegistryParser.parse(nodes: [node(1, ["Transport": "USB"], hid: true), provider]))
        XCTAssertNil(BluetoothRegistryParser.parse(nodes: [node(1, ["Transport": "Bluetooth", "DeviceAddress": "invalid"], hid: true), provider]))
        XCTAssertNil(BluetoothRegistryParser.parse(nodes: [node(1, ["Transport": "Bluetooth"], hid: true),
            node(2, ["Transport": "USB", "DeviceAddress": firstAddress])]))
    }

    func testKnownBluetoothLeafCanBindToASingleDeviceProvider() throws {
        let leaf = node(10, ["Transport": "BluetoothLowEnergy", "BatteryPercent": 45, "PrimaryUsagePage": 1, "PrimaryUsage": 2], hid: true)
        let provider = node(20, ["DeviceAddress": firstAddress, "Product": "Mouse"])
        let record = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [leaf, provider]))
        XCTAssertEqual(record.address, firstAddress)
        XCTAssertEqual(record.addressEvidence, .provider)
        XCTAssertEqual(record.batteryServiceID, 10)
        XCTAssertEqual(record.observedServiceIDs, [10, 20])
        XCTAssertEqual(record.kind, .mouse)
        XCTAssertTrue(record.isLiveHID)
    }

    func testPartialLeafReadingIsNeverFilledWithAnotherNodesEarOrCase() throws {
        let leaf = node(10, ["DeviceAddress": firstAddress, "BatteryPercentLeft": 62, "Transport": "Bluetooth"], hid: true)
        let provider = node(20, ["DeviceAddress": firstAddress, "BatteryPercentRight": 77, "BatteryPercentCase": 48])
        let record = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [leaf, provider]))
        XCTAssertEqual(record.battery.left, 62)
        XCTAssertNil(record.battery.right)
        XCTAssertNil(record.battery.caseLevel)
        XCTAssertEqual(record.batteryServiceID, 10)
    }

    func testInvalidLeafUpdateDoesNotFallBackToAnotherNodesCachedValue() throws {
        let leaf = node(10, ["DeviceAddress": firstAddress, "BatteryPercentLeft": 255, "Transport": "Bluetooth"], hid: true)
        let provider = node(20, ["DeviceAddress": firstAddress, "BatteryPercentLeft": 86, "BatteryPercentCase": 48])
        let record = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [leaf, provider]))
        XCTAssertFalse(record.battery.hasReading)
        XCTAssertEqual(record.batteryObservation.left, .invalid)
        XCTAssertEqual(record.batteryServiceID, 10)
    }

    func testWholeProviderReadingIsUsedOnlyWhenLeafHasNoBatteryProperties() throws {
        let leaf = node(10, ["DeviceAddress": firstAddress, "Transport": "Bluetooth"], hid: true)
        let provider = node(20, ["DeviceAddress": firstAddress, "BatteryPercentLeft": 62, "BatteryPercentRight": 77, "BatteryPercentCase": 0])
        let record = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [leaf, provider]))
        XCTAssertEqual(record.battery, BluetoothBatteryState(left: 62, right: 77, caseLevel: 0))
        XCTAssertEqual(record.batteryServiceID, 20)
    }

    func testUnaddressedIntermediateProviderCannotDonateItsBatteryOrName() throws {
        let leaf = node(10, ["DeviceAddress": firstAddress, "Transport": "Bluetooth"], hid: true)
        let intermediate = node(20, ["BatteryPercent": 99, "Product": "Wrong provider"])
        let provider = node(30, ["DeviceAddress": firstAddress, "BatteryPercent": 25, "Product": "Correct device"])
        let record = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [leaf, intermediate, provider]))
        XCTAssertEqual(record.battery.overall, 25)
        XCTAssertEqual(record.name, "Correct device")
        XCTAssertEqual(record.batteryServiceID, 30)
    }

    func testRecordSelectionIsOrderIndependentAndNeverCombinesComponents() throws {
        let earlier = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [node(10,
            ["DeviceAddress": firstAddress, "BatteryPercentLeft": 62, "Transport": "Bluetooth"], hid: true)]))
        let later = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [node(20,
            ["DeviceAddress": firstAddress, "BatteryPercentRight": 77, "Transport": "Bluetooth"], hid: true)]))
        for records in [[earlier, later], [later, earlier]] {
            let selected = try XCTUnwrap(BluetoothRegistryParser.preferredRecord(for: firstAddress.lowercased(), in: records))
            XCTAssertEqual(selected.serviceID, 20)
            XCTAssertNil(selected.battery.left)
            XCTAssertEqual(selected.battery.right, 77)
        }
    }

    func testAnEmptyLiveNodeDoesNotHideAVendorBatteryAndInvalidUpdatesStayUnknown() throws {
        let empty = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [node(30,
            ["DeviceAddress": firstAddress, "Transport": "Bluetooth"], hid: true)]))
        let vendor = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [node(10,
            ["DeviceAddress": firstAddress, "BatteryPercentCase": 42])]))
        XCTAssertEqual(BluetoothRegistryParser.preferredRecord(for: firstAddress, in: [empty, vendor])?.serviceID, 10)
        let valid = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [node(40,
            ["DeviceAddress": firstAddress, "BatteryPercent": 60, "Transport": "Bluetooth"], hid: true)]))
        let invalid = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [node(50,
            ["DeviceAddress": firstAddress, "BatteryPercent": 255, "Transport": "Bluetooth"], hid: true)]))
        for records in [[valid, invalid], [invalid, valid]] {
            XCTAssertFalse(try XCTUnwrap(BluetoothRegistryParser.preferredRecord(for: firstAddress, in: records)).battery.hasReading)
        }
    }

    func testSameDeviceNameNeverAssociatesAnotherAddress() throws {
        let other = try XCTUnwrap(BluetoothRegistryParser.parse(nodes: [node(10,
            ["DeviceAddress": secondAddress, "Product": "Headphones", "BatteryPercent": 80])]))
        XCTAssertNil(BluetoothRegistryParser.preferredRecord(for: firstAddress, in: [other]))
        XCTAssertEqual(BluetoothRegistryParser.preferredRecords([other]).map(\.address), [secondAddress])
    }
}
