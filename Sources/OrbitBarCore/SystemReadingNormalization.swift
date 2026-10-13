/// Normalizes numeric system readings before they reach the display. Missing
/// or invalid values remain unknown instead of appearing as an empty battery.
public enum SystemReadingNormalization {
    public static func batteryPercent(current: Double?, maximum: Double?) -> Int? {
        guard let current, current.isFinite, current >= 0,
              let maximum, maximum.isFinite, maximum > 0 else { return nil }
        // Clamp before converting to Int, including very large capacity ratios.
        return Int((min(1, current / maximum) * 100).rounded())
    }

    public static func healthPercent(design: Double?, nominal: Double?, raw: Double?, legacy: Double?) -> Int? {
        guard let design, design.isFinite, design > 0 else { return nil }
        let capacities = [nominal, raw, legacy.flatMap { $0 > 100 ? $0 : nil }]
        guard let maximum = capacities.compactMap({ $0 }).first(where: { $0.isFinite && $0 > 0 }) else { return nil }
        return batteryPercent(current: maximum, maximum: design)
    }

    /// IOKit time to empty is valid only while discharging. -1 means that the
    /// estimate is still being calculated; zero has no useful display estimate.
    public static func minutesRemaining(_ value: Int?, onBattery: Bool, charging: Bool) -> Int? {
        guard onBattery, !charging, let value, value > 0 else { return nil }
        return value
    }
}
