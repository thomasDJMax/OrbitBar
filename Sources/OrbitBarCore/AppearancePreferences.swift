import Foundation
import CoreFoundation

/// Keeps persisted appearance values safe before they become drawing dimensions.
public enum AppearancePreferences {
    public static let iconScaleRange = 0.65...1.6
    public static let ringThicknessRange = 1.5...4.2
    public static let defaultIconScale = 1.6
    public static let defaultRingThickness = 3.3

    public static func normalizedIconScale(_ value: Double?, fallback: Double = defaultIconScale) -> Double {
        normalized(value, range: iconScaleRange, fallback: fallback, defaultValue: defaultIconScale)
    }

    public static func normalizedRingThickness(_ value: Double?, fallback: Double = defaultRingThickness) -> Double {
        normalized(value, range: ringThicknessRange, fallback: fallback, defaultValue: defaultRingThickness)
    }

    /// Strings and booleans are not valid numeric preferences, even when bridged.
    public static func storedNumber(_ object: Any?) -> Double? {
        guard let number = object as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func normalized(_ value: Double?, range: ClosedRange<Double>,
                                   fallback: Double, defaultValue: Double) -> Double {
        let safeFallback = fallback.isFinite ? fallback : defaultValue
        let candidate = value.flatMap { $0.isFinite ? $0 : nil } ?? safeFallback
        return min(range.upperBound, max(range.lowerBound, candidate))
    }
}
