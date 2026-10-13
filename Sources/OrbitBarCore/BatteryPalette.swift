public struct RGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum BatteryPalette {
    public static func color(for percent: Int) -> RGBColor {
        switch min(100, max(0, percent)) {
        case 0..<25:
            RGBColor(red: 255.0 / 255, green: 69.0 / 255, blue: 58.0 / 255)
        case 25..<50:
            RGBColor(red: 247.0 / 255, green: 223.0 / 255, blue: 142.0 / 255)
        case 50..<75:
            RGBColor(red: 255.0 / 255, green: 214.0 / 255, blue: 10.0 / 255)
        default:
            RGBColor(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255)
        }
    }
}
