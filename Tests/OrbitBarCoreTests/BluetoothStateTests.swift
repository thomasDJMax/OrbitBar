import XCTest
@testable import OrbitBarCore

final class BluetoothStateTests: XCTestCase {
    func testExplicitDisconnectWinsOverALaggingDeviceListAcrossAddressFormats() {
        let device = BluetoothDeviceState(id: "aa-bb-cc-dd-ee-ff", name: "Headphones", kind: .headphones)
        let state = BluetoothState(authorization: .allowed, power: .on, devices: [device],
                                   disconnectedDeviceIDs: ["AA:BB:CC:DD:EE:FF"])
        XCTAssertTrue(state.devices.isEmpty)
        XCTAssertEqual(state.disconnectedDeviceIDs, ["AA:BB:CC:DD:EE:FF"])
    }

    func testBatteryUpdatingAndHistoricalReadingHaveDistinctLabels() {
        let reading = BluetoothDeviceState(id: "a", name: "Headphones", isBatteryUpdating: true)
        XCTAssertEqual(reading.batteryStatusText, "正在读取电量")
        let cached = BluetoothDeviceState(id: "a", name: "Headphones", battery: .init(overall: 0), isBatteryStale: true)
        XCTAssertEqual(cached.batteryStatusText, "上次报告 · 电量 0%")
        let fresh = BluetoothDeviceState(id: "a", name: "Headphones", battery: .init(left: 51, right: 63))
        XCTAssertEqual(fresh.batteryStatusText, "左耳 51% · 右耳 63%")
        XCTAssertEqual(BluetoothDeviceState(id: "a", name: "Headphones").batteryStatusText, "电量未提供")
    }

    func testUnavailableAndDeniedStatesCannotRetainConnectedDevices() {
        let device = BluetoothDeviceState(id: "a", name: "Headset", kind: .headphones)
        for authorization in [BluetoothAuthorization.notDetermined, .denied, .restricted, .unknown] {
            XCTAssertTrue(BluetoothState(authorization: authorization, power: .on, devices: [device]).devices.isEmpty)
        }
        for power in [BluetoothPowerState.off, .unknown, .unavailable] {
            XCTAssertTrue(BluetoothState(authorization: .allowed, power: power, devices: [device]).devices.isEmpty)
        }
    }

    func testBatteryUnknownIsNotZeroAndInvalidReadingsAreRejected() {
        let battery = BluetoothBatteryState(overall: -1, left: 0, right: 100, caseLevel: 255)
        XCTAssertNil(battery.overall)
        XCTAssertNil(battery.caseLevel)
        XCTAssertEqual(battery.left, 0)
        XCTAssertEqual(battery.right, 100)
        XCTAssertEqual(battery.summary, "左耳 0% · 右耳 100%")
        XCTAssertFalse(BluetoothBatteryState().hasReading)
        XCTAssertNil(BluetoothBatteryState().summary)
    }

    func testBatterySummaryIncludesOnlyReportedComponents() {
        XCTAssertEqual(BluetoothBatteryState(overall: 80, caseLevel: 42).summary, "电量 80% · 盒 42%")
        XCTAssertEqual(BluetoothBatteryState(overall: 80, left: 62, right: 77).summary, "左耳 62% · 右耳 77%")
        XCTAssertEqual(BluetoothBatteryState(caseLevel: 0).summary, "盒 0%")
    }

    func testDeviceListIsUniqueStableAndHeadphonesAppearFirst() {
        let keyboard = BluetoothDeviceState(id: "k", name: "Keyboard", kind: .keyboard)
        let headphones = BluetoothDeviceState(id: "h", name: "Zulu", kind: .headphones)
        let state = BluetoothState(authorization: .allowed, power: .on, devices: [keyboard, headphones, keyboard])
        XCTAssertEqual(state.devices.map(\.id), ["h", "k"])
        XCTAssertEqual(state.connectedCount, 2)
        XCTAssertTrue(state.hasHeadphones)
        XCTAssertEqual(state.summary, "已连接 2 个设备")
    }
}
