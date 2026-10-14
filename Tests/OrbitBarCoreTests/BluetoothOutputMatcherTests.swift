import XCTest
@testable import OrbitBarCore

final class BluetoothOutputMatcherTests: XCTestCase {
    func testStableAddressWinsWhenNamesAreDifferent() {
        let device = BluetoothDeviceState(id: "aa-bb-cc-dd-ee-ff", name: "Custom Name", kind: .headphones)
        var audio = AudioState(outputName: "AirPods")
        audio.outputKind = .bluetoothHeadphones
        audio.outputUID = "AA:BB:CC:DD:EE:FF:output"
        XCTAssertTrue(BluetoothOutputMatcher.isCurrent(device, audio: audio, devices: [device]))
    }

    func testNamesMustMatchExactlyAndBeUnique() {
        let first = BluetoothDeviceState(id: "one", name: "Headphones", kind: .headphones)
        let second = BluetoothDeviceState(id: "two", name: "Headphones Pro", kind: .headphones)
        var audio = AudioState(outputName: " headphones ")
        audio.outputKind = .bluetoothHeadphones
        XCTAssertTrue(BluetoothOutputMatcher.isCurrent(first, audio: audio, devices: [first, second]))
        XCTAssertFalse(BluetoothOutputMatcher.isCurrent(second, audio: audio, devices: [first, second]))
        let duplicate = BluetoothDeviceState(id: "three", name: "HEADPHONES", kind: .headphones)
        XCTAssertFalse(BluetoothOutputMatcher.isCurrent(first, audio: audio, devices: [first, duplicate]))
    }

    func testBuiltInOutputNeverHighlightsAConnectedHeadset() {
        let device = BluetoothDeviceState(id: "one", name: "Speaker", kind: .headphones)
        var audio = AudioState(outputName: "Speaker")
        audio.outputKind = .builtInSpeaker
        XCTAssertFalse(BluetoothOutputMatcher.isCurrent(device, audio: audio, devices: [device]))
    }

    func testUIDDoesNotJoinHexCharactersAcrossArbitraryText() {
        let device = BluetoothDeviceState(id: "AA:BB:CC:DD:EE:FF", name: "Headphones", kind: .headphones)
        let audio = AudioState(outputName: "Other Output", outputUID: "AAxBB!CC?DD#EE@FF", outputKind: .bluetoothAudio)
        XCTAssertTrue(BluetoothAudioUIDAddress.extract(from: audio.outputUID).isEmpty)
        XCTAssertFalse(BluetoothOutputMatcher.isCurrent(device, audio: audio, devices: [device]))
    }

    func testExplicitDifferentUIDAddressPreventsSameNameFallback() {
        let connected = BluetoothDeviceState(id: "AA:BB:CC:DD:EE:FF", name: "Headphones", kind: .headphones)
        let audio = AudioState(outputName: "Headphones", outputUID: "11-22-33-44-55-66:output", outputKind: .bluetoothAudio)
        XCTAssertFalse(BluetoothOutputMatcher.isCurrent(connected, audio: audio, devices: [connected]))
    }

    func testUIDRecognizesCompleteAddressFormatsWithoutSubstringMatching() {
        let address = "AA:BB:CC:DD:EE:FF"
        for uid in ["AA:BB:CC:DD:EE:FF:output", "Bluetooth_AA-BB-CC-DD-EE-FF-output", "device:AABBCCDDEEFF:output", "0xAABBCCDDEEFF"] {
            XCTAssertEqual(BluetoothAudioUIDAddress.extract(from: uid), [address], uid)
        }
        for uid in ["prefixAABBCCDDEEFFsuffix", "0AABBCCDDEEFF0", "AA:BB:CC:DD:EE:FF:11", "00-AA-BB-CC-DD-EE-FF", "8ae6f304-9122-4be3-a289-aabbccddeeff"] {
            XCTAssertTrue(BluetoothAudioUIDAddress.extract(from: uid).isEmpty, uid)
        }
    }

    func testMultipleUIDAddressesAreAmbiguousEvenWithOneConnectedCandidate() {
        let first = BluetoothDeviceState(id: "AA:BB:CC:DD:EE:FF", name: "Headphones", kind: .headphones)
        let audio = AudioState(outputName: "Headphones", outputUID: "AA:BB:CC:DD:EE:FF/11:22:33:44:55:66", outputKind: .bluetoothAudio)
        XCTAssertEqual(BluetoothAudioUIDAddress.extract(from: audio.outputUID).count, 2)
        XCTAssertFalse(BluetoothOutputMatcher.isCurrent(first, audio: audio, devices: [first]))
    }

    func testCanonicalAddressMatchesWhenNamesAreDuplicatedAndDeviceOrderChanges() {
        let first = BluetoothDeviceState(id: "AA:BB:CC:DD:EE:FF", name: "Headphones", kind: .headphones)
        let second = BluetoothDeviceState(id: "11:22:33:44:55:66", name: "Headphones", kind: .headphones)
        let audio = AudioState(outputName: "Headphones", outputUID: "11-22-33-44-55-66:output", outputKind: .bluetoothAudio)
        for devices in [[first, second], [second, first]] {
            XCTAssertFalse(BluetoothOutputMatcher.isCurrent(first, audio: audio, devices: devices))
            XCTAssertTrue(BluetoothOutputMatcher.isCurrent(second, audio: audio, devices: devices))
        }
    }

    func testNameFallbackRequiresConnectedMembershipAndDoesNotMatchAKeyboard() {
        let absent = BluetoothDeviceState(id: "absent", name: "Headphones", kind: .headphones)
        let audio = AudioState(outputName: "Headphones", outputKind: .bluetoothAudio)
        XCTAssertFalse(BluetoothOutputMatcher.isCurrent(absent, audio: audio, devices: []))
        let keyboard = BluetoothDeviceState(id: "keyboard", name: "Headphones", kind: .keyboard)
        XCTAssertFalse(BluetoothOutputMatcher.isCurrent(keyboard, audio: audio, devices: [keyboard]))
    }

    func testStoredOpaqueAssociationDoesNotFallBackToAnotherSameNameDevice() {
        let first = BluetoothDeviceState(id: "AA:BB:CC:DD:EE:FF", name: "Headphones", kind: .headphones)
        let second = BluetoothDeviceState(id: "11:22:33:44:55:66", name: "Headphones", kind: .headphones)
        let audio = AudioState(outputName: "Headphones", outputUID: "opaque", outputKind: .bluetoothAudio,
                               bluetoothDeviceID: first.id)
        XCTAssertNil(BluetoothOutputMatcher.currentDevice(audio: audio, devices: [second]))
        XCTAssertEqual(BluetoothOutputMatcher.currentDevice(audio: audio, devices: [second, first])?.id, first.id)
        var withAddress = audio
        withAddress.outputUID = "11:22:33:44:55:66:output"
        XCTAssertEqual(BluetoothOutputMatcher.currentDevice(audio: withAddress, devices: [first, second])?.id, second.id)
    }
}
