import AppKit
import SwiftUI

/// The launcher's glass. A behind-window blur tinted with the panel token,
/// a hairline edge, a top highlight and a two-layer shadow drawn outside the
/// shape only. Reduce Transparency makes it solid.
struct PanelSurface<Content: View>: View {
    var cornerRadius: CGFloat = OR.Radius.panel
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    OR.Color.panelSolid
                } else {
                    ZStack {
                        VisualEffectBackground(material: .popover, blending: .behindWindow)
                        OR.Color.panelTint
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(OR.Color.panelHighlight, lineWidth: 0.5)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .white, location: 0), .init(color: .clear, location: 0.12)],
                            startPoint: .top, endPoint: .bottom))
            }
            .overlay { shape.stroke(OR.Color.panelEdge, lineWidth: 0.5) }
            .background { PanelShadow(cornerRadius: cornerRadius, dark: colorScheme == .dark) }
    }
}

/// Shadow layers, masked so nothing renders beneath the translucent glass.
private struct PanelShadow: View {
    var cornerRadius: CGFloat
    var dark: Bool

    var body: some View {
        GeometryReader { _ in
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.black)
                    .padding(dark ? 16 : 18)
                    .shadow(color: OR.Color.shadowStrong, radius: dark ? 40 : 35, y: 30)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.black)
                    .padding(10)
                    .shadow(color: OR.Color.shadowSoft, radius: 12, y: 10)
            }
            .mask {
                Canvas { context, size in
                    var path = Path(CGRect(origin: .zero, size: size))
                    let panel = CGRect(x: 200, y: 200, width: size.width - 400, height: size.height - 400)
                    path.addPath(Path(roundedRect: panel, cornerRadius: cornerRadius, style: .continuous))
                    context.fill(path, with: .color(.black), style: FillStyle(eoFill: true))
                }
                .padding(-200)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The thicker glass used for popovers inside the panel: the action panel and the shortcuts overlay.
struct PopoverSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: OR.Radius.popover, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    OR.Color.popoverSolid
                } else {
                    ZStack {
                        Rectangle().fill(.regularMaterial)
                        OR.Color.popover
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(OR.Color.panelHighlight, lineWidth: 0.5)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.1)))
            }
            .overlay { shape.stroke(OR.Color.popoverEdge, lineWidth: 0.5) }
            .shadow(color: OR.Color.popoverShadow, radius: 20, y: 14)
    }
}

extension View {
    func popoverSurface() -> some View { modifier(PopoverSurface()) }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
