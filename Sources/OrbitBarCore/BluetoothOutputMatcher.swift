import Foundation

/// A connected accessory is active only when it can be matched to the HAL route.
public enum BluetoothOutputMatcher {
    public static func isCurrent(_ device: BluetoothDeviceState, audio: AudioState,
                                 devices: [BluetoothDeviceState]) -> Bool {
        guard let current = currentDevice(audio: audio, devices: devices) else { return false }
        if let address = BluetoothAddress.normalize(device.id), let currentAddress = BluetoothAddress.normalize(current.id) {
            return address == currentAddress
        }
        return current.id == device.id
    }

    /// Explicit UID address evidence wins even when it names a device absent
    /// from the connected list. Never replace a failed address match with a name.
    public static func currentDevice(audio: AudioState, devices: [BluetoothDeviceState]) -> BluetoothDeviceState? {
        guard audio.outputKind.isBluetooth else { return nil }
        let addresses = BluetoothAudioUIDAddress.extract(from: audio.outputUID)
        if !addresses.isEmpty {
            guard addresses.count == 1, let address = addresses.first else { return nil }
            let candidates = devices.filter { BluetoothAddress.normalize($0.id) == address }
            return candidates.count == 1 ? candidates.first : nil
        }

        // Names are a fallback only when exact, nonempty, and unique among
        // connected devices. Substrings and same-name accessories are ambiguous.
        let name = normalizedName(audio.outputName)
        guard !name.isEmpty else { return nil }
        let candidates = devices.filter { normalizedName($0.name) == name }
        guard candidates.count == 1, let candidate = candidates.first,
              candidate.kind == .headphones || candidate.kind == .speaker || candidate.kind == .other else { return nil }
        return candidate
    }

    private static func normalizedName(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
