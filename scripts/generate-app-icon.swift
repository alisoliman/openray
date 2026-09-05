import AppKit

// Deterministic vector-derived app icon matching the command mark used in SwiftUI.
// Usage: swift scripts/generate-app-icon.swift
let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "OpenRay/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(
            roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
        let gradient = NSGradient(
            starting: NSColor(red: 1, green: 0.43, blue: 0.38, alpha: 1),
            ending: NSColor(red: 0.82, green: 0.18, blue: 0.34, alpha: 1))!
        gradient.draw(in: background, angle: -70)
        NSColor.white.withAlphaComponent(0.22).setStroke()
        background.lineWidth = 3
        background.stroke()
        let glyph = NSAttributedString(
            string: "⌘",
            attributes: [
                .font: NSFont.systemFont(ofSize: 590, weight: .semibold), .foregroundColor: NSColor.white,
            ])
        let glyphSize = glyph.size()
        glyph.draw(at: NSPoint(x: (1024 - glyphSize.width) / 2, y: (1024 - glyphSize.height) / 2 + 8))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: destination.appending(path: "icon_\(points)\(suffix).png"), options: .atomic)
    }
}
print("Generated 10 app icon representations.")
