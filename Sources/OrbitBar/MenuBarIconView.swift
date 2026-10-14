import AppKit
import OrbitBarCore
import SwiftUI

/// Draws directly inside the native status button, whose image cell otherwise
/// shrinks every large square image to the same 16-point box.
@MainActor
final class MenuBarIconView: NSView {
    var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    var iconScale: Double = 1 { didSet { if iconScale != oldValue { needsDisplay = true } } }
    var percentage: String? { didSet { if percentage != oldValue { needsDisplay = true } } }
    var foregroundColor: NSColor = .labelColor { didSet { if foregroundColor != oldValue { needsDisplay = true } } }
    var volume: Double = 0 { didSet { if volume != oldValue { invalidateVolumeDots() } } }
    var volumeEmphasis: Double = 0 { didSet { if volumeEmphasis != oldValue { invalidateVolumeDots() } } }
    var accessory: StatusAccessory = .none { didSet { if accessory != oldValue { needsDisplay = true } } }
    var backgroundKey: IconRenderer.BackgroundKey?

    // Includes the thickest ring, charging marker, and animated volume dots.
    static let sourceBounds = NSRect(x: 1, y: 3, width: 30, height: 29)
    private static let textFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func glyphSize(buttonHeight: CGFloat, scale: Double) -> NSSize {
        let clamped = CGFloat(min(1.6, max(0.65, scale)))
        let availableHeight = max(1, buttonHeight - 0.5)
        let height = availableHeight * min(1, clamped)
        let width = availableHeight * clamped * sourceBounds.width / sourceBounds.height
        return NSSize(width: width, height: height)
    }

    static func requiredWidth(buttonHeight: CGFloat, scale: Double, percentage: String?,
                              accessory: StatusAccessory = .none) -> CGFloat {
        let glyph = glyphSize(buttonHeight: buttonHeight, scale: scale)
        let textWidth = percentage.map { ($0 as NSString).size(withAttributes: [.font: textFont]).width + 6 } ?? 0
        return ceil(8 + glyph.width + accessory.width + textWidth)
    }

    private var glyphRect: NSRect {
        let glyph = Self.glyphSize(buttonHeight: bounds.height, scale: iconScale)
        return NSRect(x: 4, y: (bounds.height - glyph.height) / 2,
                      width: glyph.width, height: glyph.height)
    }

    private var volumeDotsRect: NSRect {
        let glyph = glyphRect
        // Invalidate the maximum pulse extent, including the previous frame.
        let radius = IconGeometry.dotRadius * glyph.height / Self.sourceBounds.height * 1.11 + 1
        return (0..<4).reduce(NSRect.null) { rect, index in
            let point = IconGeometry.dotCenter(index: index)
            let x = glyph.minX + (point.x - Self.sourceBounds.minX) / Self.sourceBounds.width * glyph.width
            let y = glyph.minY + (point.y - Self.sourceBounds.minY) / Self.sourceBounds.height * glyph.height
            return rect.union(NSRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
        }.intersection(bounds)
    }

    private func invalidateVolumeDots() { setNeedsDisplay(volumeDotsRect) }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let glyphRect = glyphRect
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: glyphRect, from: Self.sourceBounds, operation: .sourceOver, fraction: 1)
        // Keep the volume dots circular even in the wider menu-bar presentation.
        if dirtyRect.intersects(volumeDotsRect) {
            for index in 0..<4 {
                let point = IconGeometry.dotCenter(index: index)
                let intensity = IconGeometry.dotIntensity(index: index, volume: volume)
                let radius = IconGeometry.dotRadius * glyphRect.height / Self.sourceBounds.height
                    * (0.86 + 0.14 * intensity + 0.11 * volumeEmphasis * intensity)
                let x = glyphRect.minX + (point.x - Self.sourceBounds.minX) / Self.sourceBounds.width * glyphRect.width
                let y = glyphRect.minY + (point.y - Self.sourceBounds.minY) / Self.sourceBounds.height * glyphRect.height
                foregroundColor.withAlphaComponent(0.22 + 0.78 * intensity).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
            }
        }
        let accessoryOrigin = glyphRect.maxX + 5
        let accessoryRect = NSRect(x: accessoryOrigin, y: (bounds.height - 14) / 2,
                                   width: max(0, accessory.width - 5), height: 14)
        if accessory != .none && dirtyRect.intersects(accessoryRect.insetBy(dx: -1, dy: -1)) {
            accessory.draw(in: accessoryRect, color: foregroundColor)
        }
        if let percentage, dirtyRect.maxX >= glyphRect.maxX + accessory.width + 6 {
            let text = percentage as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.textFont, .foregroundColor: foregroundColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: glyphRect.maxX + accessory.width + 6, y: (bounds.height - size.height) / 2),
                      withAttributes: attributes)
        }
    }
}

@MainActor
struct MenuBarGlyphPreview: NSViewRepresentable {
    let snapshot: SystemSnapshot
    @ObservedObject var settings: AppSettings
    let dark: Bool
    @ObservedObject var animator: VolumeAnimator

    func makeNSView(context: Context) -> MenuBarIconView { MenuBarIconView(frame: .zero) }

    func updateNSView(_ view: MenuBarIconView, context: Context) {
        let key = IconRenderer.backgroundKey(snapshot: snapshot, settings: settings, dark: dark, canvasSize: 64)
        if view.backgroundKey != key {
            let image = IconRenderer.image(snapshot: snapshot, settings: settings, dark: dark,
                                           canvasSize: 64, drawVolumeDots: false).copy() as! NSImage
            image.size = NSSize(width: 32, height: 32)
            view.image = image
            view.backgroundKey = key
        }
        view.iconScale = settings.iconScale
        view.accessory = StatusAccessory(snapshot: snapshot)
        view.volume = animator.frame.volume
        view.volumeEmphasis = animator.frame.emphasis
        view.foregroundColor = dark ? .white : NSColor(white: 0.12, alpha: 1)
    }
}
