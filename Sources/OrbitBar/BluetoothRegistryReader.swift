import Foundation
import IOKit
import IOKit.hid
import OrbitBarCore

typealias RegistryBluetoothRecord = BluetoothRegistryRecord

/// Optional vendor properties vary by device and OS. Public IOKit reads do not
/// scan, connect or invoke private Bluetooth getters. Missing data stays unknown.
enum RegistryBluetoothReader {
    static let matchingClasses = ["IOHIDDevice", "AppleHSBluetoothDevice",
                                  "AppleDeviceManagementHIDEventService", "IOBluetoothDevice"]

    static func read(knownConnectedAddresses: Set<String> = []) -> [RegistryBluetoothRecord] {
        var records: [RegistryBluetoothRecord] = []
        var visited = Set<UInt64>()
        for className in matchingClasses {
            guard !Task.isCancelled else { break }
            var iterator: io_iterator_t = IO_OBJECT_NULL
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while true {
                guard !Task.isCancelled else { break }
                let service = IOIteratorNext(iterator)
                guard service != IO_OBJECT_NULL else { break }
                defer { IOObjectRelease(service) }
                guard let identifier = serviceID(service), visited.insert(identifier).inserted,
                      let record = readRecord(service, identifier: identifier,
                                              knownConnectedAddresses: knownConnectedAddresses) else { continue }
                records.append(record)
            }
        }
        return records.sorted { $0.serviceID < $1.serviceID }
    }

    static func normalizedAddress(_ value: String) -> String? { BluetoothAddress.normalize(value) }

    static func preferredRecord(for address: String, in records: [RegistryBluetoothRecord]) -> RegistryBluetoothRecord? {
        BluetoothRegistryParser.preferredRecord(for: address, in: records)
    }

    static func preferredRecords(_ records: [RegistryBluetoothRecord]) -> [RegistryBluetoothRecord] {
        BluetoothRegistryParser.preferredRecords(records)
    }

    private static func readRecord(_ service: io_service_t, identifier: UInt64,
                                   knownConnectedAddresses: Set<String>) -> RegistryBluetoothRecord? {
        guard let leaf = node(service, identifier: identifier, knownConnectedAddresses: knownConnectedAddresses) else { return nil }
        var nodes = [leaf]
        // Read bounded, direct providers. Keep each node's identity and properties
        // separate so controllers and other devices cannot supply false battery.
        var parent = service
        defer { if parent != service { IOObjectRelease(parent) } }
        for _ in 0..<3 {
            guard !Task.isCancelled else { return nil }
            var next: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(parent, kIOServicePlane, &next) == KERN_SUCCESS else { break }
            if parent != service { IOObjectRelease(parent) }
            parent = next
            guard let id = serviceID(parent), let provider = node(parent, identifier: id,
                                                                 knownConnectedAddresses: knownConnectedAddresses),
                  provider.isDeviceProvider, !provider.hasOtherTransport else { break }
            nodes.append(provider)
            if provider.address == .invalid || provider.address == .conflicting { break }
        }
        return BluetoothRegistryParser.parse(nodes: nodes)
    }

    private static func node(_ service: io_registry_entry_t, identifier: UInt64,
                             knownConnectedAddresses: Set<String>) -> BluetoothRegistryNode? {
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = raw?.takeRetainedValue() as? [String: Any] else { return nil }
        return BluetoothRegistryNode(serviceID: identifier, properties: properties,
            isDeviceProvider: matchingClasses.contains { IOObjectConformsTo(service, $0) != 0 },
            isHIDDevice: IOObjectConformsTo(service, "IOHIDDevice") != 0,
            knownConnectedAddresses: knownConnectedAddresses)
    }

    private static func serviceID(_ service: io_registry_entry_t) -> UInt64? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { return nil }
        return identifier
    }
}
