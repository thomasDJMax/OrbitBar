#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate-icon.swift /path/to/OrbitBar.iconset\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int, filename: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "OrbitBarIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixelSize) / 1024)
    scale.concat()

    let background = NSBezierPath(roundedRect: NSRect(x: 46, y: 46, width: 932, height: 932), xRadius: 218, yRadius: 218)
    let colors = [
        NSColor(srgbRed: 0.13, green: 0.18, blue: 0.24, alpha: 1),
        NSColor(srgbRed: 0.045, green: 0.075, blue: 0.12, alpha: 1)
    ]
    NSGradient(colors: colors)!.draw(in: background, angle: -90)

    // Use the menu-bar glyph's 32-point geometry inside the app icon.
    let glyphScale: CGFloat = 24
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: 128 + x * glyphScale, y: 140 + y * glyphScale)
    }
    let center = point(16, 17.25)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: 12 * glyphScale, startAngle: 210, endAngle: -30, clockwise: true)
    ring.lineWidth = (2.35 * 32 / 26) * glyphScale
    ring.lineCapStyle = .round
    NSColor(srgbRed: 0.47, green: 0.93, blue: 0.75, alpha: 1).setStroke()
    ring.stroke()

    NSColor(srgbRed: 0.90, green: 0.97, blue: 1, alpha: 1).setStroke()
    let wifiAnchor = point(16, 13.1)
    for radius: CGFloat in [4.2, 7.4] {
        let wifi = NSBezierPath()
        wifi.appendArc(withCenter: wifiAnchor, radius: radius * glyphScale, startAngle: 48, endAngle: 132)
        wifi.lineWidth = 1.9 * glyphScale
        wifi.lineCapStyle = .round
        wifi.stroke()
    }
    NSColor(srgbRed: 0.90, green: 0.97, blue: 1, alpha: 1).setFill()
    let wifiTip = point(16, 11.3)
    let wifiFan = NSBezierPath()
    wifiFan.move(to: wifiTip)
    wifiFan.appendArc(withCenter: wifiTip, radius: 1.6 * glyphScale, startAngle: 48, endAngle: 132)
    wifiFan.close()
    wifiFan.fill()

    for (index, angle) in [240.0, 260.0, 280.0, 300.0].enumerated() {
        let radians = angle * .pi / 180
        let dotCenter = NSPoint(
            x: center.x + 12 * glyphScale * cos(radians),
            y: center.y + 12 * glyphScale * sin(radians)
        )
        let dotRadius = 1.4 * glyphScale
        let alpha: CGFloat = index < 3 ? 1 : 0.25
        NSColor(srgbRed: 0.47, green: 0.93, blue: 0.75, alpha: alpha).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: dotCenter.x - dotRadius,
            y: dotCenter.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OrbitBarIcon", code: 2)
    }
    try png.write(to: outputDirectory.appendingPathComponent(filename))
}

for baseSize in [16, 32, 128, 256, 512] {
    try renderIcon(pixelSize: baseSize, filename: "icon_\(baseSize)x\(baseSize).png")
    try renderIcon(pixelSize: baseSize * 2, filename: "icon_\(baseSize)x\(baseSize)@2x.png")
}
