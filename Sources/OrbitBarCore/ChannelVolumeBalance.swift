/// Retains channel proportions when an output device has no master volume control.
/// Ratios remain available while all channels are zero, so unmuting preserves balance.
public struct ChannelVolumeBalance {
    private var ratiosByDevice: [UInt32: [UInt32: Float]] = [:]

    public init() {}

    /// A newly selected output can reuse a HAL device ID. Do not carry a muted
    /// channel ratio across an output switch.
    public mutating func reset() {
        ratiosByDevice.removeAll(keepingCapacity: true)
    }

    public mutating func scaledVolumes(device: UInt32, current: [UInt32: Float], target: Float) -> [UInt32: Float] {
        let clamped = current.mapValues { $0.isFinite ? min(1, max(0, $0)) : 0 }
        let maximum = clamped.values.max() ?? 0
        if let cached = ratiosByDevice[device], Set(cached.keys) != Set(clamped.keys) {
            // The stream layout can change without the HAL device ID changing.
            // Ratios from another layout must not silence a newly added channel.
            ratiosByDevice[device] = nil
        }
        if maximum > 0 {
            ratiosByDevice[device] = clamped.mapValues { $0 / maximum }
        }
        let ratios = ratiosByDevice[device] ?? [:]
        let level = target.isFinite ? min(1, max(0, target)) : 0
        return clamped.reduce(into: [:]) { result, channel in
            result[channel.key] = level * (ratios[channel.key] ?? 1)
        }
    }
}
