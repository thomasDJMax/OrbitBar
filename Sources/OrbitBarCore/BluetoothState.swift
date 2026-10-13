import Foundation

public enum BluetoothAuthorization: String, Sendable { case notDetermined, allowed, denied, restricted, unknown }
public enum BluetoothPowerState: String, Sendable { case on, off, unavailable, unknown }
public enum BluetoothDeviceKind: String, Sendable {
    case headphones, speaker, keyboard, mouse, gameController, phone, other

    public var symbolName: String {
        switch self {
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker.fill"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse.fill"
        case .gameController: return "gamecontroller.fill"
        case .phone: return "iphone"
        case .other: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// Only reported readings are present. Missing or malformed values stay unknown.
public struct BluetoothBatteryState: Equatable, Sendable {
    public var overall: Int?
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?

    public init(overall: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.overall = Self.valid(overall)
        self.left = Self.valid(left)
        self.right = Self.valid(right)
        self.caseLevel = Self.valid(caseLevel)
    }

    public var hasReading: Bool { overall != nil || left != nil || right != nil || caseLevel != nil }
    public var summary: String? {
        var parts: [String] = []
        if let left { parts.append("左耳 \(left)%") }
        if let right { parts.append("右耳 \(right)%") }
        if let caseLevel { parts.append("盒 \(caseLevel)%") }
        if let overall, left == nil && right == nil { parts.insert("电量 \(overall)%", at: 0) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func valid(_ value: Int?) -> Int? {
        value.flatMap { (0...100).contains($0) ? $0 : nil }
    }
}

public struct BluetoothDeviceState: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: BluetoothDeviceKind
    public var battery: BluetoothBatteryState
    public var isBatteryUpdating: Bool
    public var isBatteryStale: Bool
    public init(id: String, name: String, kind: BluetoothDeviceKind = .other,
                battery: BluetoothBatteryState = .init(), isBatteryUpdating: Bool = false, isBatteryStale: Bool = false) {
        self.id = BluetoothAddress.normalize(id) ?? id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "蓝牙设备" : name
        self.kind = kind
        self.battery = battery
        self.isBatteryUpdating = isBatteryUpdating
        self.isBatteryStale = isBatteryStale
    }

    public var batteryStatusText: String {
        if let summary = battery.summary { return isBatteryStale ? "上次报告 · \(summary)" : summary }
        return isBatteryUpdating ? "正在读取电量" : "电量未提供"
    }
}

public struct BluetoothState: Equatable, Sendable {
    public var authorization: BluetoothAuthorization
    public var power: BluetoothPowerState
    public var devices: [BluetoothDeviceState]
    /// Explicit disconnect events can precede HAL and registry removal.
    public var disconnectedDeviceIDs: Set<String>
    public init(authorization: BluetoothAuthorization = .unknown, power: BluetoothPowerState = .unknown,
                devices: [BluetoothDeviceState] = [], disconnectedDeviceIDs: Set<String> = []) {
        self.authorization = authorization
        self.power = power
        let blocked = authorization == .allowed && power == .on
            ? Set(disconnectedDeviceIDs.map { BluetoothAddress.normalize($0) ?? $0 }) : []
        self.disconnectedDeviceIDs = blocked
        // Permission and radio state must not leave an obsolete connected list.
        self.devices = authorization == .allowed && power == .on
            ? Self.unique(devices.filter { !blocked.contains($0.id) }) : []
    }

    public var connectedCount: Int { devices.count }
    public var hasHeadphones: Bool { devices.contains { $0.kind == .headphones } }
    public var summary: String {
        switch authorization {
        case .notDetermined: return "允许访问后显示连接设备"
        case .denied: return "蓝牙访问未允许"
        case .restricted: return "蓝牙访问受限"
        case .unknown: return "蓝牙状态暂不可用"
        case .allowed:
            switch power {
            case .on: return devices.isEmpty ? "已开启 · 无连接设备" : "已连接 \(devices.count) 个设备"
            case .off: return "蓝牙已关闭"
            case .unavailable: return "此 Mac 不支持蓝牙"
            case .unknown: return "正在读取蓝牙状态"
            }
        }
    }

    private static func unique(_ devices: [BluetoothDeviceState]) -> [BluetoothDeviceState] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.kind == .headphones && rhs.kind != .headphones { return true }
                if rhs.kind == .headphones && lhs.kind != .headphones { return false }
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
            }
    }
}
