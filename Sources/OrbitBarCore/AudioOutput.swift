import Foundation

public enum AudioOutputKind: String, Sendable, CaseIterable {
    case builtInSpeaker, wiredHeadphones, bluetoothHeadphones, bluetoothAudio
    case usb, hdmi, other, unavailable

    public var isBluetooth: Bool { self == .bluetoothHeadphones || self == .bluetoothAudio }
    public var isHeadphones: Bool { self == .wiredHeadphones || self == .bluetoothHeadphones }

    public var displayName: String {
        switch self {
        case .builtInSpeaker: "内置扬声器"
        case .wiredHeadphones: "有线耳机"
        case .bluetoothHeadphones: "蓝牙耳机"
        case .bluetoothAudio: "蓝牙音频"
        case .usb: "USB 音频"
        case .hdmi: "显示器音频"
        case .other: "音频输出"
        case .unavailable: "未检测到输出设备"
        }
    }

    public var symbolName: String {
        switch self {
        case .wiredHeadphones, .bluetoothHeadphones: "headphones"
        case .usb: "cable.connector"
        case .hdmi: "display"
        case .unavailable: "speaker.slash.fill"
        default: "speaker.wave.2.fill"
        }
    }
}

/// Evidence from public HAL transport and output stream properties. Kept free
/// of CoreAudio so classification can be verified without connected hardware.
public enum AudioOutputTransport: Sendable {
    case builtIn, bluetooth, usb, hdmi, other, unknown
}

public enum AudioOutputTerminal: Sendable {
    case headphones, speaker, hdmi, other
}

public enum AudioOutputClassifier {
    public static func classify(transport: AudioOutputTransport,
                                terminals: [AudioOutputTerminal] = [],
                                dataSourceName: String? = nil,
                                deviceName: String? = nil,
                                isAlive: Bool = true) -> AudioOutputKind {
        guard isAlive else { return .unavailable }
        let terminalHeadphones = terminals.contains(.headphones)
        let sourceHeadphones = explicitlyNamesHeadphones(dataSourceName)
        // A speaker terminal is positive evidence. A user-renamed Bluetooth
        // speaker must not become "headphones" because of a suggestive name.
        let nameHeadphones = !terminals.contains(.speaker) && explicitlyNamesHeadphones(deviceName)
        let headphones = terminalHeadphones || sourceHeadphones || nameHeadphones
        if transport == .bluetooth { return headphones ? .bluetoothHeadphones : .bluetoothAudio }
        if transport == .hdmi || terminals.contains(.hdmi) { return .hdmi }
        if headphones { return .wiredHeadphones }
        if transport == .usb { return .usb }
        if transport == .builtIn { return .builtInSpeaker }
        return .other
    }

    private static func explicitlyNamesHeadphones(_ name: String?) -> Bool {
        guard let name else { return false }
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if normalized.contains("耳机") { return true }
        let words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let headphoneWords: Set<String> = ["airpods", "headphone", "headphones", "headset", "headsets", "earphone", "earphones", "earbud", "earbuds"]
        return words.contains { headphoneWords.contains($0) }
    }
}

/// A route can change while its HAL device ID stays the same, for example when
/// headphones are unplugged from a built-in audio device. Capture this identity
/// at the start of a drag and reject writes if the route changes during it.
public enum AudioOutputIdentity {
    public static func identifier(deviceID: UInt32, uid: String?,
                                  dataSources: [UInt32] = [], terminalTypes: [UInt32] = []) -> String {
        let device = uid.map { "uid:\($0.count):\($0)" } ?? "hal:\(deviceID)"
        let sources = Set(dataSources).sorted().map(String.init).joined(separator: ",")
        let terminals = Set(terminalTypes).sorted().map(String.init).joined(separator: ",")
        return "\(device)|source:\(sources)|terminal:\(terminals)"
    }

    public static func permitsWrite(expectedDeviceID: UInt32?, expectedIdentifier: String?,
                                    currentDeviceID: UInt32?, currentIdentifier: String?) -> Bool {
        guard let expectedDeviceID, expectedDeviceID != 0,
              expectedDeviceID == currentDeviceID else { return false }
        return expectedIdentifier == nil || expectedIdentifier == currentIdentifier
    }
}
