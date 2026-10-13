import AppKit
import OrbitBarCore
import SwiftUI

/// Separate from the Wi-Fi/battery glyph so its meaning stays visible.
enum StatusAccessory: Equatable {
    case none, headphones, bluetooth

    init(snapshot: SystemSnapshot) {
        if snapshot.audio.outputKind.isHeadphones { self = .headphones }
        else if snapshot.audio.outputKind.isBluetooth || !snapshot.bluetooth.devices.isEmpty
            || snapshot.bluetooth.authorization == .allowed && snapshot.bluetooth.power == .on { self = .bluetooth }
        else { self = .none }
    }

    var width: CGFloat {
        switch self {
        case .none: return 0
        case .headphones: return 21
        case .bluetooth: return 15
        }
    }

    @MainActor
    func draw(in rect: NSRect, color: NSColor) {
        switch self {
        case .none: break
        case .headphones:
            color.setStroke()
            let band = NSBezierPath()
            band.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.4),
                           radius: rect.width * 0.4, startAngle: 0, endAngle: 180)
            band.lineWidth = 1.6
            band.lineCapStyle = .round
            band.stroke()
            color.setFill()
            for x in [rect.minX + rect.width * 0.1, rect.maxX - rect.width * 0.1 - 3] {
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY + 1, width: 3, height: 6),
                             xRadius: 1.2, yRadius: 1.2).fill()
            }
        case .bluetooth:
            let path = NSBezierPath()
            // The Bluetooth rune, drawn within a small dedicated slot.
            let points: [NSPoint] = [NSPoint(x: 0.1, y: 0.25), NSPoint(x: 0.9, y: 0.75),
                                    NSPoint(x: 0.5, y: 1), NSPoint(x: 0.5, y: 0),
                                    NSPoint(x: 0.9, y: 0.25), NSPoint(x: 0.1, y: 0.75)]
            for (index, point) in points.enumerated() {
                let point = NSPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
    }
}

struct BluetoothSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points: [CGPoint] = [CGPoint(x: 0.1, y: 0.75), CGPoint(x: 0.9, y: 0.25),
                                 CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1),
                                 CGPoint(x: 0.9, y: 0.75), CGPoint(x: 0.1, y: 0.25)]
        for (index, point) in points.enumerated() {
            let point = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
