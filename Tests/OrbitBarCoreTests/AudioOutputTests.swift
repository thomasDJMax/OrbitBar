import XCTest
@testable import OrbitBarCore

final class AudioOutputTests: XCTestCase {
    func testPublicHardwareEvidenceIdentifiesHeadphonesAndBuiltinSpeakers() {
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .builtIn, terminals: [.speaker]), .builtInSpeaker)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .builtIn, terminals: [.headphones]), .wiredHeadphones)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .builtIn, dataSourceName: "External Headphones"), .wiredHeadphones)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .builtIn, dataSourceName: "外接耳机"), .wiredHeadphones)
    }

    func testBluetoothSpeakersAreNotAssumedToBeHeadphones() {
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .bluetooth, deviceName: "JBL Flip 6"), .bluetoothAudio)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .bluetooth, terminals: [.speaker], deviceName: "AirPods speaker"), .bluetoothAudio)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .bluetooth, terminals: [.headphones], deviceName: "Studio Output"), .bluetoothHeadphones)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .bluetooth, deviceName: "Thomas’s AirPods Pro"), .bluetoothHeadphones)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .bluetooth, deviceName: "Headphones"), .bluetoothHeadphones)
    }

    func testNameFallbackRequiresAnExplicitHeadphoneWord() {
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .bluetooth, deviceName: "Wireless Sound"), .bluetoothAudio)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .bluetooth, deviceName: "MyAirPodsClone"), .bluetoothAudio)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .unknown, deviceName: "USB Headset"), .wiredHeadphones)
    }

    func testDigitalAndDisconnectedOutputsKeepTheirActualKinds() {
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .usb, terminals: [.speaker]), .usb)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .hdmi, terminals: [.headphones], deviceName: "Headphones monitor"), .hdmi)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .other, terminals: [.hdmi]), .hdmi)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .other), .other)
        XCTAssertEqual(AudioOutputClassifier.classify(transport: .bluetooth, terminals: [.headphones], isAlive: false), .unavailable)
    }

    func testADeviceSwitchRejectsTheRestOfAnOldSliderDrag() {
        let original = AudioOutputIdentity.identifier(deviceID: 42, uid: "headphones")
        let switched = AudioOutputIdentity.identifier(deviceID: 43, uid: "speaker")
        XCTAssertTrue(AudioOutputIdentity.permitsWrite(expectedDeviceID: 42, expectedIdentifier: original,
                                                      currentDeviceID: 42, currentIdentifier: original))
        XCTAssertFalse(AudioOutputIdentity.permitsWrite(expectedDeviceID: 42, expectedIdentifier: original,
                                                       currentDeviceID: 43, currentIdentifier: switched))
    }

    func testJackRouteChangeAndReusedDeviceIDRejectStaleWrites() {
        let original = AudioOutputIdentity.identifier(deviceID: 42, uid: "builtin", dataSources: [1], terminalTypes: [10])
        let unplugged = AudioOutputIdentity.identifier(deviceID: 42, uid: "builtin", dataSources: [2], terminalTypes: [20])
        let reused = AudioOutputIdentity.identifier(deviceID: 42, uid: "new-device", dataSources: [1], terminalTypes: [10])
        for changed in [unplugged, reused] {
            XCTAssertFalse(AudioOutputIdentity.permitsWrite(expectedDeviceID: 42, expectedIdentifier: original,
                                                           currentDeviceID: 42, currentIdentifier: changed))
        }
        XCTAssertFalse(AudioOutputIdentity.permitsWrite(expectedDeviceID: nil, expectedIdentifier: nil,
                                                       currentDeviceID: 42, currentIdentifier: original))
    }

    func testIdentityIsStableAcrossPropertyOrderingAndDeviceIDRenumbering() {
        let original = AudioOutputIdentity.identifier(deviceID: 42, uid: "speaker", dataSources: [2, 1], terminalTypes: [20, 10])
        XCTAssertEqual(original, AudioOutputIdentity.identifier(deviceID: 100, uid: "speaker", dataSources: [1, 2, 2], terminalTypes: [10, 20]))
        XCTAssertNotEqual(AudioOutputIdentity.identifier(deviceID: 42, uid: nil), AudioOutputIdentity.identifier(deviceID: 100, uid: nil))
    }

    func testMuteCapabilityDoesNotDependOnAVolumeSlider() {
        let hardwareMuteOnly = AudioState(canSetMute: true, outputKind: .hdmi)
        XCTAssertTrue(hardwareMuteOnly.canSetMute)
        XCTAssertFalse(hardwareMuteOnly.canSetVolume)
        XCTAssertTrue(AudioState(canSetVolume: true).canSetMute)
        XCTAssertTrue(AudioOutputKind.bluetoothAudio.isBluetooth)
        XCTAssertFalse(AudioOutputKind.bluetoothAudio.isHeadphones)
        XCTAssertTrue(AudioOutputKind.bluetoothHeadphones.isHeadphones)
    }
}
