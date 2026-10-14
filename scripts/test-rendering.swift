import AppKit
import ObjectiveC.runtime
import OrbitBarCore

/// Capture the production view's public invalidation call, without reproducing
/// its geometry. The hook exists only in this isolated regression executable.
@MainActor
private final class InvalidationRecorder {
    static let shared = InvalidationRecorder()
    private var rectangles: [ObjectIdentifier: [NSRect]] = [:]

    func record(_ view: NSView, rect: NSRect) {
        rectangles[ObjectIdentifier(view), default: []].append(rect)
    }

    func take(_ view: NSView) -> [NSRect] {
        rectangles.removeValue(forKey: ObjectIdentifier(view)) ?? []
    }

    func install() {
        let selector = #selector(NSView.setNeedsDisplay(_:))
        guard let original = class_getInstanceMethod(NSView.self, selector) else {
            preconditionFailure("NSView's public invalidation method is unavailable.")
        }
        typealias Setter = @convention(c) (AnyObject, Selector, NSRect) -> Void
        let forward = unsafeBitCast(method_getImplementation(original), to: Setter.self)
        let block: @convention(block) (NSView, NSRect) -> Void = { view, rect in
            MainActor.assumeIsolated {
                InvalidationRecorder.shared.record(view, rect: rect)
                forward(view, selector, rect)
            }
        }
        let replacement = imp_implementationWithBlock(block)
        precondition(class_addMethod(MenuBarIconView.self, selector, replacement,
                                     method_getTypeEncoding(original)), "Install the capture hook once.")
    }
}

/// AppKit traverses this opaque parent and the real transparent MenuBarIconView
/// when restoring a dirty region. No window, display server capture, or audio
/// control is involved. This tests redraw pixels, not compositor scheduling.
@MainActor
private final class BackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

@MainActor
private final class RenderSurface {
    let parent: BackgroundView
    let view: MenuBarIconView
    let bitmap: NSBitmapImageRep
    let context: NSGraphicsContext

    init(image: NSImage, scale: Double, percentage: String?, accessory: StatusAccessory) {
        let width = MenuBarIconView.requiredWidth(buttonHeight: 22, scale: scale,
                                                 percentage: percentage, accessory: accessory)
        let bounds = NSRect(x: 0, y: 0, width: width, height: 22)
        parent = BackgroundView(frame: bounds)
        view = MenuBarIconView(frame: bounds)
        parent.addSubview(view)
        view.image = image
        view.iconScale = scale
        view.percentage = percentage
        view.accessory = accessory
        view.foregroundColor = NSColor(white: 0.12, alpha: 1)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(width) * 2, pixelsHigh: 44, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: Int(width) * 8, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            preconditionFailure("Cannot create the isolated Retina render target.")
        }
        self.bitmap = bitmap
        self.context = context
        context.cgContext.scaleBy(x: 2, y: 2)
        _ = InvalidationRecorder.shared.take(view)
    }

    func render(_ rect: NSRect? = nil) {
        // Cover whole backing pixels, just as a raster damage region does. A
        // windowless bitmap has no convertToBacking/NSWindow scale metadata.
        let transform = context.cgContext.ctm
        let aligned = (rect ?? parent.bounds).applying(transform).integral.applying(transform.inverted())
        parent.displayIgnoringOpacity(aligned, in: context)
    }

    var pixels: [UInt8] {
        guard let data = bitmap.bitmapData else { preconditionFailure("Missing bitmap pixels.") }
        return Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }
}

@main
private enum RenderingRegressions {
    @MainActor
    static func main() {
        InvalidationRecorder.shared.install()
        let domain = "com.thomas.OrbitBar.rendering-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults, loginService: .init(
            status: { .notRegistered }, register: {}, unregister: {}))
        let image = IconRenderer.image(snapshot: .preview, settings: settings, dark: false,
                                       canvasSize: 64, drawVolumeDots: false).copy() as! NSImage
        image.size = NSSize(width: 32, height: 32)
        var cases = 0
        for scale in [0.65, 1.6] {
            for percentage: String? in [nil, "100%"] {
                for accessory in [StatusAccessory.none, .bluetooth] {
                    let updated = RenderSurface(image: image, scale: scale,
                        percentage: percentage, accessory: accessory)
                    updated.view.volume = 1
                    updated.view.volumeEmphasis = 1
                    updated.render()
                    let maximum = updated.pixels
                    _ = InvalidationRecorder.shared.take(updated.view)
                    updated.view.volume = 0.08
                    updated.view.volumeEmphasis = 0
                    let dirties = InvalidationRecorder.shared.take(updated.view)
                    precondition(!dirties.isEmpty, "A changed frame must invalidate the real view.")
                    let dirty = dirties.reduce(NSRect.null) { $0.union($1) }
                    precondition(dirty.width < updated.parent.bounds.width,
                                 "Animation must invalidate a smaller region than the whole icon.")
                    updated.render(dirty)
                    let fresh = RenderSurface(image: image, scale: scale,
                        percentage: percentage, accessory: accessory)
                    fresh.view.volume = 0.08
                    fresh.view.volumeEmphasis = 0
                    fresh.render()
                    precondition(maximum != fresh.pixels, "The maximum pulse fixture must differ from the final frame.")
                    compare(updated, fresh, label: "pulse shrink scale=\(scale), percent=\(percentage ?? "none"), accessory=\(accessory)")
                    cases += 1

                    if accessory == .bluetooth {
                        // These pixel-aligned exposure strips touch only the
                        // Bluetooth round stroke outside its 14-point container.
                        for y in [3.5, 18.0] {
                            let strip = NSRect(x: 0, y: y, width: updated.parent.bounds.width, height: 0.5)
                            // Repaint from the opaque ancestor, as AppKit does
                            // for a nonopaque child's newly exposed region.
                            updated.render(strip)
                            compare(updated, fresh, label: "Bluetooth outer stroke y=\(y), scale=\(scale)")
                            cases += 1
                        }
                    }
                }
            }
        }
        print("Passed \(cases) actual MenuBarIconView partial/full pixel comparisons (Retina, no window or system audio).")
    }

    @MainActor
    private static func compare(_ updated: RenderSurface, _ fresh: RenderSurface, label: String) {
        let actual = updated.pixels
        let expected = fresh.pixels
        precondition(actual.count == expected.count)
        let different = actual.indices.filter { abs(Int(actual[$0]) - Int(expected[$0])) > 1 }
        let mismatches = different.count
        if mismatches > 0 {
            for index in different.prefix(12) {
                fputs("\(label): pixel(\((index % updated.bitmap.bytesPerRow) / 4),\(index / updated.bitmap.bytesPerRow)) channel \(index % 4): \(actual[index]) vs \(expected[index])\n", stderr)
            }
        }
        precondition(mismatches == 0, "\(label): \(mismatches) bitmap channels differ from a complete redraw.")
    }
}
