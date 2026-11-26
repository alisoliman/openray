import AppKit
import SwiftUI

/// The OpenRay mark: a graphite squircle with a single coral ray.
/// Drawn from the 64-unit master in design/design-system.html.
struct ORMark: View {
    var size: CGFloat = 18

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 64
            context.scaleBy(x: scale, y: scale)
            let squircle = Path(roundedRect: CGRect(x: 0, y: 0, width: 64, height: 64), cornerRadius: 15, style: .continuous)
            context.fill(
                squircle,
                with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x3B3B44), Color(hex: 0x141418)]),
                    startPoint: CGPoint(x: 32, y: 0), endPoint: CGPoint(x: 32, y: 64)))
            context.fill(
                Path(ellipseIn: CGRect(x: 28, y: 2, width: 34, height: 34)),
                with: .radialGradient(
                    Gradient(colors: [Color(hex: 0xFF8F80, alpha: 0.55), Color(hex: 0xFF8F80, alpha: 0)]),
                    center: CGPoint(x: 45, y: 19), startRadius: 0, endRadius: 17))
            var ray = Path()
            ray.move(to: CGPoint(x: 9, y: 57))
            ray.addLine(to: CGPoint(x: 42.5, y: 15.5))
            ray.addLine(to: CGPoint(x: 48.5, y: 21.5))
            ray.closeSubpath()
            context.fill(
                ray,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(hex: 0xFF6F63, alpha: 0), location: 0),
                        .init(color: Color(hex: 0xFF6F63), location: 0.6),
                        .init(color: Color(hex: 0xFFC9B8), location: 1),
                    ]), startPoint: CGPoint(x: 9, y: 57), endPoint: CGPoint(x: 48.5, y: 15.5)))
            context.fill(Path(ellipseIn: CGRect(x: 40, y: 13, width: 11, height: 11)), with: .color(Color(hex: 0xFFF4EF)))
            context.stroke(
                squircle, with: .color(.white.opacity(0.10)), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum ORMarkImage {
    /// The menu bar icon: a template version of the mark that follows the
    /// menu bar tint. When capture is paused, an amber dot carries the state.
    static func menuBar(paused: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            let unit = 16.0 / 24.0
            let transform = NSAffineTransform()
            transform.translateX(by: 1, yBy: 0)
            transform.scale(by: unit)
            transform.concat()
            let color = paused ? NSColor.labelColor : NSColor.black
            color.setStroke()
            color.setFill()
            let frame = NSBezierPath(
                roundedRect: NSRect(x: 2.5, y: 2.5, width: 19, height: 19), xRadius: 5.5, yRadius: 5.5)
            frame.lineWidth = 1.7
            frame.stroke()
            let ray = NSBezierPath()
            ray.move(to: NSPoint(x: 5.6, y: 19))
            ray.line(to: NSPoint(x: 15.4, y: 7.8))
            ray.line(to: NSPoint(x: 17, y: 9.4))
            ray.close()
            ray.fill()
            NSBezierPath(ovalIn: NSRect(x: 14.1, y: 5.3, width: 4.6, height: 4.6)).fill()
            if paused {
                let dot = NSBezierPath(ovalIn: NSRect(x: 15, y: 15, width: 8.5, height: 8.5))
                NSColor.black.withAlphaComponent(0.25).setStroke()
                dot.lineWidth = 1.5
                dot.stroke()
                NSColor(hex: 0xFFB547).setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = !paused
        image.accessibilityDescription = paused ? "OpenRay, clipboard capture paused" : "OpenRay"
        return image
    }
}
