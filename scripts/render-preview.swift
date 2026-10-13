import AppKit
import ImageIO
import OrbitBarCore
import UniformTypeIdentifiers

/// Development-only vector renders using the production menu-bar renderer.
@main
enum RenderPreview {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "com.thomas.OrbitBar.render-preview"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.useStatusColors = true
        let sheet = NSImage(size: NSSize(width: 860, height: 212))
        sheet.lockFocus()
        NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 860, height: 212).fill()
        for (index, percent) in [0, 25, 50, 75, 100].enumerated() {
            var snapshot = SystemSnapshot.preview
            snapshot.battery = .init(isPresent: true, percent: percent)
            snapshot.audio.volume = 1
            let icon = IconRenderer.image(snapshot: snapshot, settings: settings, dark: false, canvasSize: 120)
            icon.draw(in: NSRect(x: 24 + CGFloat(index) * 168, y: 58, width: 120, height: 120))
            let title = "\(percent)%" as NSString
            title.draw(at: NSPoint(x: 69 + CGFloat(index) * 168, y: 27), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.labelColor
            ])
        }
        sheet.unlockFocus()
        try png(sheet).write(to: output.appendingPathComponent("battery-colors.png"))

        var reference = SystemSnapshot.preview
        reference.battery = .init(isPresent: true, percent: 100)
        reference.audio.volume = 1
        settings.useStatusColors = false
        let icon = IconRenderer.image(snapshot: reference, settings: settings, dark: false, canvasSize: 260)
        let referenceImage = NSImage(size: NSSize(width: 300, height: 300))
        referenceImage.lockFocus()
        NSColor(srgbRed: 0.87, green: 0.87, blue: 0.89, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 300, height: 300).fill()
        icon.draw(in: NSRect(x: 20, y: 20, width: 260, height: 260))
        referenceImage.unlockFocus()
        try png(referenceImage).write(to: output.appendingPathComponent("reference-glyph.png"))

        let sizeSheet = NSImage(size: NSSize(width: 660, height: 196))
        sizeSheet.lockFocus()
        NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 660, height: 196).fill()
        let nativeImage = IconRenderer.image(snapshot: reference, settings: settings, dark: false, canvasSize: 64,
                                             drawVolumeDots: false).copy() as! NSImage
        nativeImage.size = NSSize(width: 32, height: 32)
        for (index, scale) in [1.0, 1.4, 1.6].enumerated() {
            let width = MenuBarIconView.requiredWidth(buttonHeight: 22, scale: scale, percentage: nil)
            let view = MenuBarIconView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
            view.image = nativeImage
            view.iconScale = scale
            view.volume = 1
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 25 + CGFloat(index) * 210, yBy: 60)
            transform.scale(by: 4)
            transform.concat()
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let title = "\(Int((scale * 100).rounded()))%" as NSString
            title.draw(at: NSPoint(x: 85 + CGFloat(index) * 210, y: 28), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.labelColor
            ])
        }
        sizeSheet.unlockFocus()
        try png(sizeSheet).write(to: output.appendingPathComponent("menu-bar-size.png"))

        let connections = NSImage(size: NSSize(width: 1240, height: 210))
        connections.lockFocus()
        NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1240, height: 210).fill()
        settings.useStatusColors = true
        for (index, title) in ["内置扬声器", "蓝牙设备已连接", "蓝牙耳机输出"].enumerated() {
            var snapshot = SystemSnapshot.preview
            if index > 0 {
                snapshot.bluetooth = .init(authorization: .allowed, power: .on, devices: [
                    .init(id: "AA:BB:CC:DD:EE:FF", name: "示例设备", kind: index == 2 ? .headphones : .keyboard)
                ])
            }
            if index == 2 { snapshot.audio.outputKind = .bluetoothHeadphones }
            let accessory = StatusAccessory(snapshot: snapshot)
            let image = IconRenderer.image(snapshot: snapshot, settings: settings, dark: false,
                                           canvasSize: 64, drawVolumeDots: false).copy() as! NSImage
            image.size = NSSize(width: 32, height: 32)
            let width = MenuBarIconView.requiredWidth(buttonHeight: 22, scale: 1.6,
                                                       percentage: "78%", accessory: accessory)
            let view = MenuBarIconView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
            view.image = image
            view.iconScale = 1.6
            view.percentage = "78%"
            view.accessory = accessory
            view.volume = 0.6
            view.foregroundColor = NSColor(white: 0.12, alpha: 1)
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 30 + CGFloat(index) * 410, yBy: 85)
            transform.scale(by: 3)
            transform.concat()
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            (title as NSString).draw(at: NSPoint(x: 50 + CGFloat(index) * 410, y: 30), withAttributes: [
                .font: NSFont.systemFont(ofSize: 19, weight: .medium), .foregroundColor: NSColor.labelColor
            ])
        }
        connections.unlockFocus()
        try png(connections).write(to: output.appendingPathComponent("connected-icons.png"))

        let animationURL = output.appendingPathComponent("volume-animation.gif")
        let frames = 80
        guard let destination = CGImageDestinationCreateWithURL(animationURL as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw NSError(domain: "OrbitBarPreview", code: 2)
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var motion = VolumeMotion(value: 0)
        let changes: [Int: Double] = [4: 0.25, 10: 0.5, 16: 0.75, 22: 1, 40: 0.35, 44: 0.8, 49: 0]
        for index in 0..<frames {
            // Sample the same transition used by the app, including a quick reversal.
            let time = Double(index) / 30
            if let target = changes[index] { motion.retarget(to: target, at: time) }
            let presentation = motion.sample(at: time)
            let frame = NSImage(size: NSSize(width: 260, height: 260))
            frame.lockFocus()
            NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 260, height: 260).fill()
            IconRenderer.image(snapshot: reference, settings: settings, dark: false, canvasSize: 220,
                               animatedVolume: presentation.volume, volumeEmphasis: presentation.emphasis)
                .draw(in: NSRect(x: 20, y: 20, width: 220, height: 220))
            frame.unlockFocus()
            guard let cgImage = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "OrbitBarPreview", code: 3) }
    }

    private static func png(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "OrbitBarPreview", code: 1)
        }
        return data
    }
}
