import Foundation
import CoreFoundation

public enum BluetoothRegistryAddressObservation: Equatable, Sendable {
    case absent, invalid, conflicting, address(String)

    public var value: String? {
        if case .address(let value) = self { return value }
        return nil
    }
}

public enum BluetoothRegistryAddressEvidence: Int, Equatable, Sendable {
    case provider = 0, direct = 1
}

public enum BluetoothBatteryObservationValue: Equatable, Sendable {
    case absent, invalid, percent(Int)

    public var percent: Int? {
        if case .percent(let value) = self { return value }
        return nil
    }
    public var isObserved: Bool { self != .absent }
}

public struct BluetoothRegistryBatteryObservation: Equatable, Sendable {
    public var overall: BluetoothBatteryObservationValue
    public var left: BluetoothBatteryObservationValue
    public var right: BluetoothBatteryObservationValue
    public var caseLevel: BluetoothBatteryObservationValue

    public init(overall: BluetoothBatteryObservationValue = .absent,
                left: BluetoothBatteryObservationValue = .absent,
                right: BluetoothBatteryObservationValue = .absent,
                caseLevel: BluetoothBatteryObservationValue = .absent) {
        self.overall = overall; self.left = left; self.right = right; self.caseLevel = caseLevel
    }

    public init(properties: [String: Any]) {
        overall = Self.parse(properties, key: "BatteryPercent")
        left = Self.parse(properties, key: "BatteryPercentLeft")
        right = Self.parse(properties, key: "BatteryPercentRight")
        caseLevel = Self.parse(properties, key: "BatteryPercentCase")
    }

    public var hasObservation: Bool { [overall, left, right, caseLevel].contains(where: \.isObserved) }
    public var componentObservationCount: Int { [left, right, caseLevel].filter(\.isObserved).count }
    public var battery: BluetoothBatteryState {
        BluetoothBatteryState(overall: overall.percent, left: left.percent,
                              right: right.percent, caseLevel: caseLevel.percent)
    }

    private static func parse(_ properties: [String: Any], key: String) -> BluetoothBatteryObservationValue {
        guard let raw = properties[key] else { return .absent }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return .invalid }
        let value = number.doubleValue
        guard value.isFinite, (0...100).contains(value) else { return .invalid }
        return .percent(Int(value.rounded()))
    }
}

public struct BluetoothRegistryNode: Equatable, Sendable {
    public var serviceID: UInt64
    public var address: BluetoothRegistryAddressObservation
    public var battery: BluetoothRegistryBatteryObservation
    public var name: String?
    public var kind: BluetoothDeviceKind
    public var isBluetoothTransport: Bool
    public var hasOtherTransport: Bool
    public var isDeviceProvider: Bool
    public var isHIDDevice: Bool

    public init(serviceID: UInt64, properties: [String: Any], isDeviceProvider: Bool,
                isHIDDevice: Bool = false, knownConnectedAddresses: Set<String> = []) {
        self.serviceID = serviceID
        address = BluetoothRegistryParser.address(properties: properties, knownConnectedAddresses: knownConnectedAddresses)
        battery = BluetoothRegistryBatteryObservation(properties: properties)
        name = [properties["Product"], properties["DeviceName"]].compactMap { raw -> String? in
            guard let text = raw as? String else { return nil }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.first
        let transport = properties["Transport"] as? String
        isBluetoothTransport = transport == "Bluetooth" || transport == "BluetoothLowEnergy"
        hasOtherTransport = transport != nil && !isBluetoothTransport
        self.isDeviceProvider = isDeviceProvider
        self.isHIDDevice = isHIDDevice
        let page = AppearancePreferences.storedNumber(properties["PrimaryUsagePage"])
        let usage = AppearancePreferences.storedNumber(properties["PrimaryUsage"])
        if page == 1, usage == 6 { kind = .keyboard }
        else if page == 1, usage == 2 { kind = .mouse }
        else if page == 1, usage == 4 || usage == 5 { kind = .gameController }
        else { kind = .other }
    }
}

public struct BluetoothRegistryRecord: Equatable, Sendable {
    /// Registry IDs are stable for this boot, never a persistent Bluetooth ID.
    public var serviceID: UInt64
    public var observedServiceIDs: [UInt64]
    public var batteryServiceID: UInt64?
    public var address: String?
    public var addressEvidence: BluetoothRegistryAddressEvidence
    public var name: String?
    public var kind: BluetoothDeviceKind
    public var battery: BluetoothBatteryState
    public var batteryObservation: BluetoothRegistryBatteryObservation
    public var isLiveHID: Bool

    public init(serviceID: UInt64, observedServiceIDs: [UInt64] = [], batteryServiceID: UInt64? = nil,
                address: String?, addressEvidence: BluetoothRegistryAddressEvidence = .direct,
                name: String? = nil, kind: BluetoothDeviceKind = .other,
                batteryObservation: BluetoothRegistryBatteryObservation = .init(), isLiveHID: Bool = false) {
        self.serviceID = serviceID
        self.observedServiceIDs = Array(Set(observedServiceIDs + [serviceID])).sorted()
        self.batteryServiceID = batteryServiceID
        self.address = address
        self.addressEvidence = addressEvidence
        self.name = name
        self.kind = kind
        self.batteryObservation = batteryObservation
        battery = batteryObservation.battery
        self.isLiveHID = isLiveHID
    }
}

public enum BluetoothRegistryParser {
    public static func address(properties: [String: Any], knownConnectedAddresses: Set<String> = []) -> BluetoothRegistryAddressObservation {
        let raw = ["DeviceAddress", "BluetoothAddress", "BD_ADDR"].compactMap { key -> (String, Any)? in
            properties[key].map { (key, $0) }
        }
        guard !raw.isEmpty else { return .absent }
        let addresses = Set(raw.compactMap { key, value -> String? in
            if let text = value as? String { return BluetoothAddress.normalize(text) }
            // BD_ADDR blobs have no assumed byte order. Only the public classic
            // connection list, captured by the caller, can confirm a candidate.
            guard key == "BD_ADDR", let bytes = value as? Data, bytes.count == 6 else { return nil }
            let forward = BluetoothAddress.normalize(bytes.map { String(format: "%02X", $0) }.joined())
            let backward = BluetoothAddress.normalize(bytes.reversed().map { String(format: "%02X", $0) }.joined())
            let candidates = Set([forward, backward].compactMap { $0 })
            let connected = Set(knownConnectedAddresses.compactMap(BluetoothAddress.normalize))
            let confirmed = candidates.intersection(connected)
            return confirmed.count == 1 ? confirmed.first : nil
        })
        guard addresses.count <= 1 else { return .conflicting }
        guard let value = addresses.first else { return .invalid }
        return .address(value)
    }

    /// Nodes must be ordered leaf first, followed only by its direct providers.
    /// Identity and battery are selected explicitly; dictionaries never merge.
    public static func parse(nodes: [BluetoothRegistryNode]) -> BluetoothRegistryRecord? {
        guard let leaf = nodes.first else { return nil }
        var deviceNodes = [leaf]
        var address = leaf.address.value
        let evidence: BluetoothRegistryAddressEvidence = address == nil ? .provider : .direct
        guard leaf.address != .invalid && leaf.address != .conflicting else { return nil }
        if address == nil && !leaf.isBluetoothTransport { return nil }

        for provider in nodes.dropFirst() {
            guard provider.isDeviceProvider, !provider.hasOtherTransport,
                  provider.address != .invalid && provider.address != .conflicting else { break }
            if let providerAddress = provider.address.value {
                if let address, address != providerAddress { break }
                address = providerAddress
            }
            deviceNodes.append(provider)
        }
        guard let address else { return nil }
        // An addressless intermediate provider is useful for establishing the
        // chain, but its own battery/name cannot be attributed by name or class.
        let identityNodes = deviceNodes.filter { $0.serviceID == leaf.serviceID || $0.address.value == address }
        let batteryNode = identityNodes.first(where: { $0.battery.hasObservation })
        let batteryObservation = batteryNode?.battery ?? .init()
        return BluetoothRegistryRecord(serviceID: leaf.serviceID,
            observedServiceIDs: deviceNodes.map(\.serviceID), batteryServiceID: batteryNode?.serviceID,
            address: address, addressEvidence: evidence,
            name: identityNodes.compactMap(\.name).first, kind: leaf.kind,
            batteryObservation: batteryObservation, isLiveHID: leaf.isHIDDevice && leaf.isBluetoothTransport)
    }

    public static func preferredRecord(for address: String, in records: [BluetoothRegistryRecord]) -> BluetoothRegistryRecord? {
        guard let canonical = BluetoothAddress.normalize(address) else { return nil }
        return records.filter { $0.address == canonical }.max { lhs, rhs in
            let left = [lhs.batteryObservation.hasObservation ? 1 : 0, lhs.isLiveHID ? 1 : 0,
                        lhs.addressEvidence.rawValue, lhs.batteryObservation.componentObservationCount]
            let right = [rhs.batteryObservation.hasObservation ? 1 : 0, rhs.isLiveHID ? 1 : 0,
                         rhs.addressEvidence.rawValue, rhs.batteryObservation.componentObservationCount]
            if left != right { return left.lexicographicallyPrecedes(right) }
            return lhs.serviceID < rhs.serviceID
        }
    }

    public static func preferredRecords(_ records: [BluetoothRegistryRecord]) -> [BluetoothRegistryRecord] {
        Set(records.compactMap(\.address)).sorted().compactMap { preferredRecord(for: $0, in: records) }
    }
}
