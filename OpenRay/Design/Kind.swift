import SwiftUI

/// Every result kind has one hue, drawn as a tile with a white glyph.
/// Real app and file icons always take priority over kind tiles.
enum Kind: String, Sendable, CaseIterable {
    case command, clipboard, snippet, quicklink, note, ai, window, calculator, file, system, permission, about

    var title: String {
        switch self {
        case .command: "Command"
        case .clipboard: "Clipboard"
        case .snippet: "Snippet"
        case .quicklink: "Quicklink"
        case .note: "Note"
        case .ai: "AI"
        case .window: "Window"
        case .calculator: "Calculator"
        case .file: "File"
        case .system: "System"
        case .permission: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .command: "command"
        case .clipboard: "list.clipboard"
        case .snippet: "curlybraces"
        case .quicklink: "link"
        case .note: "note.text"
        case .ai: "sparkles"
        case .window: "rectangle.split.2x1"
        case .calculator: "plus.forwardslash.minus"
        case .file: "doc"
        case .system: "slider.horizontal.3"
        case .permission: "checkmark.shield"
        case .about: "info"
        }
    }

    var gradient: Gradient {
        switch self {
        case .command: Gradient(colors: [Color(hex: 0xFF877B), Color(hex: 0xE2443A)])
        case .clipboard: Gradient(colors: [Color(hex: 0xFFC34F), Color(hex: 0xEE960B)])
        case .snippet: Gradient(colors: [Color(hex: 0x4ED6DC), Color(hex: 0x11A0B2)])
        case .quicklink: Gradient(colors: [Color(hex: 0x62AEFF), Color(hex: 0x1C6FE6)])
        case .note: Gradient(colors: [Color(hex: 0x74DE84), Color(hex: 0x28A946)])
        case .ai:
            Gradient(stops: [
                .init(color: Color(hex: 0xF08BD6), location: 0), .init(color: Color(hex: 0xA66BFF), location: 0.45),
                .init(color: Color(hex: 0x5B7BFF), location: 1),
            ])
        case .window: Gradient(colors: [Color(hex: 0x908EFF), Color(hex: 0x5653D6)])
        case .calculator: Gradient(colors: [Color(hex: 0x8C8C93), Color(hex: 0x55555B)])
        case .file: Gradient(colors: [Color(hex: 0x78C2F7), Color(hex: 0x3D8FD8)])
        case .system: Gradient(colors: [Color(hex: 0xA2A2A8), Color(hex: 0x6A6A70)])
        case .permission: Gradient(colors: [Color(hex: 0x5AC37A), Color(hex: 0x2E9A50)])
        case .about: Gradient(colors: [Color(hex: 0x3B3B44), Color(hex: 0x141418)])
        }
    }

    var linearGradient: LinearGradient {
        self == .ai
            ? LinearGradient(gradient: gradient, startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1))
            : LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom)
    }

    /// The flat midpoint color, for tinting glyphs that sit outside a tile.
    var tint: Color {
        switch self {
        case .command: Color(hex: 0xEC5C50)
        case .clipboard: Color(hex: 0xF4AB2C)
        case .snippet: Color(hex: 0x2FBBC7)
        case .quicklink: Color(hex: 0x3F8FF3)
        case .note: Color(hex: 0x4EC465)
        case .ai: Color(hex: 0xA66BFF)
        case .window: Color(hex: 0x7370EB)
        case .calculator: Color(hex: 0x717177)
        case .file: Color(hex: 0x5AA9E8)
        case .system, .about: Color(hex: 0x86868C)
        case .permission: Color(hex: 0x44AF65)
        }
    }
}

/// A kind tile: gradient squircle, white glyph, hairline inner edge and top highlight.
struct KindTile: View {
    var kind: Kind
    var symbol: String?
    var size: CGFloat = 24
    var dimmed = false

    var body: some View {
        let radius = size * 0.25
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(kind.linearGradient)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.black.opacity(0.10), lineWidth: 0.5)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
                    .mask(alignment: .top) { Rectangle().frame(height: 1.5) }
            }
            .overlay {
                Image(systemName: symbol ?? kind.symbol)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            }
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.55 : 1)
            .accessibilityHidden(true)
    }

    private var glyphSize: CGFloat {
        switch size {
        case ..<20: size * 0.58
        case ..<28: size * 0.56
        default: size * 0.54
        }
    }
}

/// The application or file icon from NSWorkspace, at row size.
struct WorkspaceIcon: View {
    var url: URL
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: FileIconCache.shared.icon(for: url))
            .resizable().interpolation(.high).scaledToFit()
            // Icons include their own transparent margin; scale slightly to match tile bounds.
            .frame(width: size * 1.18, height: size * 1.18)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
