import Foundation

public struct BatteryState: Equatable, Sendable {
    public var isPresent: Bool
    public var percent: Int?
    public var isCharging: Bool
    public var isExternalPower: Bool
    public var isLowPowerMode: Bool
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    public var healthPercent: Int?

    public init(isPresent: Bool = false, percent: Int? = nil, isCharging: Bool = false,
                isExternalPower: Bool = false, isLowPowerMode: Bool = false,
                minutesRemaining: Int? = nil, cycleCount: Int? = nil, healthPercent: Int? = nil) {
        self.isPresent = isPresent
        self.percent = percent.map { min(100, max(0, $0)) }
        self.isCharging = isCharging
        self.isExternalPower = isExternalPower
        self.isLowPowerMode = isLowPowerMode
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
    }

    public var fraction: Double { Double(percent ?? 100) / 100 }
}

public enum NetworkKind: String, Sendable { case wifi, ethernet, offline, other }

public struct NetworkState: Equatable, Sendable {
    public var kind: NetworkKind
    public var signalLevel: Int
    public var name: String?
    public init(kind: NetworkKind = .offline, signalLevel: Int = 0, name: String? = nil) {
        self.kind = kind
        self.signalLevel = min(3, max(0, signalLevel))
        self.name = name
    }
}

public struct AudioState: Equatable, Sendable {
    public var volume: Double
    public var isMuted: Bool
    public var canSetVolume: Bool
    public var canSetMute: Bool
    public var outputName: String
    public var outputDeviceID: UInt32?
    public var outputUID: String?
    public var outputIdentifier: String?
    public var outputKind: AudioOutputKind
    public init(volume: Double = 0, isMuted: Bool = false, canSetVolume: Bool = false,
                canSetMute: Bool? = nil, outputName: String = "未检测到输出设备",
                outputDeviceID: UInt32? = nil, outputUID: String? = nil,
                outputIdentifier: String? = nil, outputKind: AudioOutputKind = .unavailable) {
        self.volume = min(1, max(0, volume.isFinite ? volume : 0))
        self.isMuted = isMuted
        self.canSetVolume = canSetVolume
        self.canSetMute = canSetMute ?? canSetVolume
        self.outputName = outputName
        self.outputDeviceID = outputDeviceID
        self.outputUID = outputUID
        self.outputIdentifier = outputIdentifier
        self.outputKind = outputKind
    }
    public var litDots: Int {
        guard !isMuted, volume > 0 else { return 0 }
        return min(4, Int(ceil(volume * 4)))
    }
}

public struct SystemSnapshot: Equatable, Sendable {
    public var battery: BatteryState
    public var network: NetworkState
    public var audio: AudioState
    public var bluetooth: BluetoothState
    public init(battery: BatteryState = .init(), network: NetworkState = .init(), audio: AudioState = .init(),
                bluetooth: BluetoothState = .init()) {
        self.battery = battery; self.network = network; self.audio = audio; self.bluetooth = bluetooth
    }
    public static let preview = SystemSnapshot(
        battery: .init(isPresent: true, percent: 78, cycleCount: 126, healthPercent: 97),
        network: .init(kind: .wifi, signalLevel: 3, name: "Studio Wi-Fi"),
        audio: .init(volume: 0.6, canSetVolume: true, canSetMute: true, outputName: "MacBook 扬声器",
                     outputDeviceID: 1, outputKind: .builtInSpeaker)
    )
}
