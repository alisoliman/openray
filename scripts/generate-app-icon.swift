import AppKit

// Deterministic vector app icon drawn from the OpenRay mark: a graphite
// squircle with a single coral ray. Matches ORMark in OpenRay/Design/Mark.swift.
// Usage: swift scripts/generate-app-icon.swift
let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "OpenRay/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws into a 1024 canvas using the 64-unit master, on the macOS icon grid (824 pt body).
func drawIcon(in context: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let scale = body.width / 64
    let radius = 15 * scale

    // Drop shadow under the body, as on the macOS icon grid.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(color(0x141418).cgColor)
    context.fillPath()
    context.restoreGState()

    // Work in the SVG's top-down, 64-unit space.
    context.saveGState()
    context.translateBy(x: body.minX, y: body.maxY)
    context.scaleBy(x: scale, y: -scale)
    let squircle = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 64, height: 64), cornerWidth: 15, cornerHeight: 15, transform: nil)
    context.addPath(squircle)
    context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let background = CGGradient(colorsSpace: space, colors: [color(0x3B3B44).cgColor, color(0x141418).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 32, y: 0), end: CGPoint(x: 32, y: 64), options: [])

    let glow = CGGradient(
        colorsSpace: space, colors: [color(0xFF8F80, 0.55).cgColor, color(0xFF8F80, 0).cgColor] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(
        glow, startCenter: CGPoint(x: 45, y: 19), startRadius: 0, endCenter: CGPoint(x: 45, y: 19), endRadius: 17, options: [])

    let ray = CGMutablePath()
    ray.move(to: CGPoint(x: 9, y: 57))
    ray.addLine(to: CGPoint(x: 42.5, y: 15.5))
    ray.addLine(to: CGPoint(x: 48.5, y: 21.5))
    ray.closeSubpath()
    context.saveGState()
    context.addPath(ray)
    context.clip()
    let rayGradient = CGGradient(
        colorsSpace: space,
        colors: [color(0xFF6F63, 0).cgColor, color(0xFF6F63).cgColor, color(0xFFC9B8).cgColor] as CFArray,
        locations: [0, 0.6, 1])!
    context.drawLinearGradient(rayGradient, start: CGPoint(x: 9, y: 57), end: CGPoint(x: 48.5, y: 15.5), options: [])
    context.restoreGState()

    context.setFillColor(color(0xFFF4EF).cgColor)
    context.fillEllipse(in: CGRect(x: 40, y: 13, width: 11, height: 11))

    // A hairline top highlight, like light catching the edge.
    context.addPath(squircle)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    context.setLineWidth(0.5)
    context.strokePath()
    context.restoreGState()
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon(in: context)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: destination.appending(path: "icon_\(points)\(suffix).png"), options: .atomic)
    }
}
print("Generated 10 app icon representations.")
