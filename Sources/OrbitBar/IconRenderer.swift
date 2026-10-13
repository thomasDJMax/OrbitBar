import AppKit
import OrbitBarCore

@MainActor
enum IconRenderer {
    struct BackgroundKey: Hashable {
        let size: Double
        let ringThickness: Double
        let colored: Bool
        let dark: Bool
        let batteryPresent: Bool
        let percent: Int?
        let charging: Bool
        let networkKind: String
        let signal: Int
    }

    private static var backgrounds: [BackgroundKey: NSImage] = [:]
    private static var backgroundOrder: [BackgroundKey] = []

    static func backgroundKey(snapshot: SystemSnapshot, settings: AppSettings,
                              dark: Bool, canvasSize: CGFloat) -> BackgroundKey {
        BackgroundKey(size: Double(canvasSize), ringThickness: settings.ringThickness,
                      colored: settings.useStatusColors, dark: dark,
                      batteryPresent: snapshot.battery.isPresent, percent: snapshot.battery.percent,
                      charging: snapshot.battery.isCharging, networkKind: snapshot.network.kind.rawValue,
                      signal: snapshot.network.signalLevel)
    }

    static func image(snapshot: SystemSnapshot, settings: AppSettings,
                      dark: Bool, canvasSize: CGFloat? = nil,
                      animatedVolume: Double? = nil, volumeEmphasis: Double = 0,
                      drawVolumeDots: Bool = true) -> NSImage {
        let size = canvasSize ?? CGFloat(32 * settings.iconScale)
        let key = backgroundKey(snapshot: snapshot, settings: settings, dark: dark, canvasSize: size)
        if !drawVolumeDots, let cached = backgrounds[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
        context.saveGState()
        context.scaleBy(x: size / 32, y: size / 32)
        let foreground: NSColor = dark ? .white : NSColor(white: 0.12, alpha: 1)
        let battery = snapshot.battery
        var ringColor = foreground
        if settings.useStatusColors, let percent = battery.percent {
            let color = BatteryPalette.color(for: percent)
            ringColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        }
        let center = IconGeometry.center
        let radius = IconGeometry.radius
        let thickness = CGFloat(settings.ringThickness) * 32 / 26
        let hasReading = battery.isPresent && battery.percent != nil
        let trackColor = settings.useStatusColors && hasReading ? ringColor.withAlphaComponent(0.20)
            : foreground.withAlphaComponent(0.20)
        strokeArc(center: center, radius: radius, start: 210, end: -30,
                  thickness: thickness, color: trackColor)
        if battery.isPresent, battery.percent != nil, battery.fraction > 0 {
            strokeArc(center: center, radius: radius, start: 210,
                      end: 210 - 240 * battery.fraction, thickness: thickness, color: ringColor)
        } else if hasReading, battery.percent == 0 {
            // Keep an empty battery visibly red without drawing a misleading full arc.
            let angle = CGFloat(210) * .pi / 180
            let point = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            ringColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - thickness / 2, y: point.y - thickness / 2,
                                      width: thickness, height: thickness)).fill()
        }

        drawNetwork(snapshot.network, color: foreground)
        if drawVolumeDots {
            let volume = animatedVolume ?? (snapshot.audio.isMuted ? 0 : snapshot.audio.volume)
            for index in 0..<4 {
                let intensity = IconGeometry.dotIntensity(index: index, volume: volume)
                let point = IconGeometry.dotCenter(index: index)
                let dotRadius = IconGeometry.dotRadius * (0.86 + 0.14 * intensity + 0.11 * volumeEmphasis * intensity)
                foreground.withAlphaComponent(0.22 + intensity * 0.78).setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - dotRadius, y: point.y - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2)).fill()
            }
        }
        if battery.isPresent, battery.isCharging {
            drawSymbol("bolt.fill", in: NSRect(x: 22, y: 20.4, width: 8.3, height: 10.3), color: ringColor,
                       backing: dark ? NSColor(white: 0.12, alpha: 0.94) : NSColor(white: 0.97, alpha: 0.94))
        }
        context.restoreGState()
        image.unlockFocus()
        image.isTemplate = false
        if !drawVolumeDots {
            if backgroundOrder.count >= 16 {
                backgrounds.removeValue(forKey: backgroundOrder.removeFirst())
            }
            backgrounds[key] = image
            backgroundOrder.append(key)
        }
        return image
    }

    private static func strokeArc(center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat,
                                  thickness: CGFloat, color: NSColor) {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        arc.lineWidth = thickness
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    private static func drawNetwork(_ network: NetworkState, color: NSColor) {
        switch network.kind {
        case .wifi:
            let origin = NSPoint(x: 16, y: 13.3)
            // The reference uses two round strokes and a filled fan-shaped tip.
            for (index, radius) in [CGFloat(4.8), CGFloat(8.5)].enumerated() {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: origin, radius: radius, startAngle: 48, endAngle: 132, clockwise: false)
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                (network.signalLevel >= index + 2 ? color : color.withAlphaComponent(0.22)).setStroke()
                arc.stroke()
            }
            (network.signalLevel > 0 ? color : color.withAlphaComponent(0.22)).setFill()
            let tip = NSBezierPath()
            tip.move(to: NSPoint(x: 16, y: 11.3))
            tip.curve(to: NSPoint(x: 14.45, y: 12.8),
                      controlPoint1: NSPoint(x: 15.6, y: 11.55), controlPoint2: NSPoint(x: 14.45, y: 12.35))
            tip.curve(to: NSPoint(x: 17.55, y: 12.8),
                      controlPoint1: NSPoint(x: 14.45, y: 14.3), controlPoint2: NSPoint(x: 17.55, y: 14.3))
            tip.curve(to: NSPoint(x: 16, y: 11.3),
                      controlPoint1: NSPoint(x: 17.55, y: 12.35), controlPoint2: NSPoint(x: 16.4, y: 11.55))
            tip.close()
            tip.fill()
        case .ethernet:
            drawSymbol("cable.connector", in: NSRect(x: 9, y: 11, width: 14, height: 14), color: color)
        case .offline:
            drawSymbol("wifi.slash", in: NSRect(x: 7.6, y: 10, width: 16.8, height: 15), color: color.withAlphaComponent(0.68))
        case .other:
            drawSymbol("network", in: NSRect(x: 9, y: 11, width: 14, height: 14), color: color)
        }
    }

    private static func drawSymbol(_ name: String, in rect: NSRect, color: NSColor, backing: NSColor? = nil) {
        if let backing {
            backing.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -0.4, dy: -0.4), xRadius: 3, yRadius: 3).fill()
        }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: rect.height, weight: .semibold)) else { return }
        let tinted = NSImage(size: rect.size)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: rect.size))
        color.setFill()
        NSRect(origin: .zero, size: rect.size).fill(using: .sourceIn)
        tinted.unlockFocus()
        tinted.draw(in: rect)
    }
}

enum IconGeometry {
    static let center = NSPoint(x: 16, y: 17.25)
    static let radius: CGFloat = 12
    static let dotRadius: CGFloat = 1.7

    static func dotCenter(index: Int) -> NSPoint {
        let angle = CGFloat(240 + index * 20) * .pi / 180
        return NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    static func dotIntensity(index: Int, volume: Double) -> Double {
        let progress = min(1, max(0, (volume * 4 - Double(index)) * 6))
        return progress * progress * (3 - 2 * progress)
    }
}
