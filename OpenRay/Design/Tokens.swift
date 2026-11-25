import AppKit
import SwiftUI

/// OpenRay 2.0 design tokens. Views use these instead of raw colors, sizes or
/// opacities, so every surface stays correct in light, dark, Increase Contrast
/// and Reduce Transparency. See design/design-system.html §03.
enum OR {
    enum Ray {
        static let r50 = NSColor(hex: 0xFFF2F0)
        static let r100 = NSColor(hex: 0xFFDDD8)
        static let r200 = NSColor(hex: 0xFFBAB1)
        static let r300 = NSColor(hex: 0xFF9488)
        static let r400 = NSColor(hex: 0xFF6F63)
        static let r500 = NSColor(hex: 0xF0483C)
        static let r600 = NSColor(hex: 0xD2362B)
        static let r700 = NSColor(hex: 0xB02A21)
        static let r800 = NSColor(hex: 0x8A2119)
        static let r900 = NSColor(hex: 0x5E160F)
    }

    /// AppKit values, for native fields, materials and drawing code.
    enum NS {
        static let accent = dynamic(light: Ray.r700, dark: Ray.r400)
        static let accentFill = dynamic(light: Ray.r600, dark: Ray.r500)
        /// Fills behind white text, such as primary buttons: 600 in both appearances (4.9 : 1).
        static let accentButton = Ray.r600
        static let text = overlay(light: 0.88, dark: 0.93)
        static let text2 = overlay(light: 0.60, dark: 0.63)
        static let text3 = overlay(light: 0.38, dark: 0.40)
        static let panelTint = dynamic(
            light: NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 252 / 255, alpha: 0.80),
            dark: NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 36 / 255, alpha: 0.76))
        static let panelSolid = dynamic(light: NSColor(hex: 0xF7F7F9), dark: NSColor(hex: 0x1E1E24))
        static let popover = dynamic(
            light: NSColor(srgbRed: 253 / 255, green: 253 / 255, blue: 254 / 255, alpha: 0.92),
            dark: NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 47 / 255, alpha: 0.92))
        static let popoverSolid = dynamic(light: NSColor(hex: 0xFDFDFE), dark: NSColor(hex: 0x28282F))

        static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in appearance.isDark ? dark : light }
        }

        /// Alpha over the material, so text stays correct over any wallpaper.
        static func overlay(light: CGFloat, dark: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
            }
        }

        /// Increase Contrast raises separators to 16% and fills by four points.
        static func fill(light: CGFloat, dark: CGFloat, contrastBoost: CGFloat = 0.04) -> NSColor {
            NSColor(name: nil) { appearance in
                let boost = appearance.isHighContrast ? contrastBoost : 0
                return appearance.isDark
                    ? NSColor(white: 1, alpha: dark + boost) : NSColor(white: 0, alpha: light + boost)
            }
        }
    }

    enum Color {
        static let accent = SwiftUI.Color(nsColor: NS.accent)
        static let accentFill = SwiftUI.Color(nsColor: NS.accentFill)
        static let accentButton = SwiftUI.Color(nsColor: NS.accentButton)
        static let accentSoft = SwiftUI.Color(
            nsColor: NS.dynamic(
                light: NSColor(srgbRed: 210 / 255, green: 54 / 255, blue: 43 / 255, alpha: 0.10),
                dark: NSColor(srgbRed: 1, green: 111 / 255, blue: 99 / 255, alpha: 0.14)))
        static let onAccent = SwiftUI.Color.white

        static let text = SwiftUI.Color(nsColor: NS.text)
        static let text2 = SwiftUI.Color(nsColor: NS.text2)
        static let text3 = SwiftUI.Color(nsColor: NS.text3)

        static let fill1 = SwiftUI.Color(nsColor: NS.fill(light: 0.035, dark: 0.045))
        static let fill2 = SwiftUI.Color(nsColor: NS.fill(light: 0.07, dark: 0.095))
        static let fill3 = SwiftUI.Color(nsColor: NS.fill(light: 0.11, dark: 0.14))
        static let separator = SwiftUI.Color(
            nsColor: NSColor(name: nil) { appearance in
                let alpha: CGFloat = appearance.isHighContrast ? 0.16 : 0.085
                return appearance.isDark ? NSColor(white: 1, alpha: alpha) : NSColor(white: 0, alpha: alpha)
            })

        static let panelTint = SwiftUI.Color(nsColor: NS.panelTint)
        static let panelSolid = SwiftUI.Color(nsColor: NS.panelSolid)
        static let panelHighlight = SwiftUI.Color(
            nsColor: NS.dynamic(light: NSColor(white: 1, alpha: 0.85), dark: NSColor(white: 1, alpha: 0.10)))
        static let panelEdge = SwiftUI.Color(
            nsColor: NS.dynamic(light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 0, alpha: 0.70)))
        static let popover = SwiftUI.Color(nsColor: NS.popover)
        static let popoverSolid = SwiftUI.Color(nsColor: NS.popoverSolid)
        /// The popover's hairline and drop, from --or-pop-shadow.
        static let popoverEdge = SwiftUI.Color(
            nsColor: NS.dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 0, alpha: 0.60)))
        static let popoverShadow = SwiftUI.Color(
            nsColor: NS.dynamic(
                light: NSColor(srgbRed: 40 / 255, green: 20 / 255, blue: 50 / 255, alpha: 0.35),
                dark: NSColor(white: 0, alpha: 0.65)))

        static let success = pair(0x1C7C36, 0x4CD964)
        static let successSoft = pair(0x1C7C36, 0x4CD964, light: 0.11, dark: 0.14)
        static let warning = pair(0x955000, 0xFFB547)
        static let warningSoft = pair(0xD67800, 0xFFB547, light: 0.13, dark: 0.14)
        static let danger = pair(0xC02A1C, 0xFF6B5E)
        static let dangerSoft = pair(0xC02A1C, 0xFF6B5E, light: 0.10, dark: 0.14)
        static let info = pair(0x005FC4, 0x6AAEFF)
        static let infoSoft = pair(0x005FC4, 0x6AAEFF, light: 0.10, dark: 0.14)
        static let diffAdd = pair(0x1C7C36, 0x4CD964, light: 0.16, dark: 0.20)
        static let diffDelete = pair(0xC02A1C, 0xFF6B5E, light: 0.13, dark: 0.20)

        static let shadowStrong = SwiftUI.Color(
            nsColor: NS.dynamic(
                light: NSColor(srgbRed: 40 / 255, green: 20 / 255, blue: 50 / 255, alpha: 0.40),
                dark: NSColor(white: 0, alpha: 0.70)))
        static let shadowSoft = SwiftUI.Color(
            nsColor: NS.dynamic(
                light: NSColor(srgbRed: 40 / 255, green: 20 / 255, blue: 50 / 255, alpha: 0.25),
                dark: NSColor(white: 0, alpha: 0.55)))

        private static func pair(_ light: UInt32, _ dark: UInt32, light lightAlpha: CGFloat = 1, dark darkAlpha: CGFloat = 1)
            -> SwiftUI.Color
        {
            SwiftUI.Color(
                nsColor: NS.dynamic(
                    light: NSColor(hex: light).withAlphaComponent(lightAlpha),
                    dark: NSColor(hex: dark).withAlphaComponent(darkAlpha)))
        }
    }

    /// Concentric radii: an inner radius equals the outer radius minus the inset.
    enum Radius {
        static let panel: CGFloat = 22
        static let popover: CGFloat = 16
        static let card: CGFloat = 14
        static let row: CGFloat = 12
        static let control: CGFloat = 8
        static let chip: CGFloat = 7
        static let key: CGFloat = 5
    }

    /// A 4 pt grid.
    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
    }

    enum Metric {
        static let field: CGFloat = 60
        static let row: CGFloat = 44
        static let tallRow: CGFloat = 56
        static let actionBar: CGFloat = 44
        static let panelWidth: CGFloat = 760
        static let onboardingSize: CGFloat = 470
        static let preview: CGFloat = 300
        static let listInset: CGFloat = 10
    }

    enum Detent {
        static let bar: CGFloat = 60
        static let list: CGFloat = 480
        static let full: CGFloat = 560
    }

    /// SF Pro at macOS sizes. 11 pt is the floor; 550 sits between Medium and Semibold.
    enum Font {
        static let search = SwiftUI.Font(NSFont.systemFont(ofSize: 20, weight: .regular))
        static let display = SwiftUI.Font(NSFont.systemFont(ofSize: 22, weight: .w650))
        static let title = SwiftUI.Font(NSFont.systemFont(ofSize: 15, weight: .w650))
        static let headline = SwiftUI.Font(NSFont.systemFont(ofSize: 13, weight: .w650))
        static let rowTitle = SwiftUI.Font(NSFont.systemFont(ofSize: 13, weight: .w550))
        static let body = SwiftUI.Font(NSFont.systemFont(ofSize: 13, weight: .regular))
        static let bodyEmphasis = SwiftUI.Font(NSFont.systemFont(ofSize: 13, weight: .w550))
        static let callout = SwiftUI.Font(NSFont.systemFont(ofSize: 12, weight: .regular))
        static let calloutEmphasis = SwiftUI.Font(NSFont.systemFont(ofSize: 12, weight: .w550))
        static let button = SwiftUI.Font(NSFont.systemFont(ofSize: 12.5, weight: .w550))
        static let buttonLarge = SwiftUI.Font(NSFont.systemFont(ofSize: 13, weight: .w550))
        static let token = SwiftUI.Font(NSFont.systemFont(ofSize: 14, weight: .w550))
        static let sectionHeader = SwiftUI.Font(NSFont.systemFont(ofSize: 12, weight: .semibold))
        static let caption = SwiftUI.Font(NSFont.systemFont(ofSize: 11, weight: .w550))
        static let key = SwiftUI.Font(NSFont.systemFont(ofSize: 11, weight: .w550))
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
        static let monoSmall = SwiftUI.Font.system(size: 11, weight: .medium, design: .monospaced)
        static let result = SwiftUI.Font(NSFont.systemFont(ofSize: 28, weight: .semibold)).monospacedDigit()
        static let resultInput = SwiftUI.Font(NSFont.systemFont(ofSize: 28, weight: .medium)).monospacedDigit()
        static let reading = SwiftUI.Font(NSFont.systemFont(ofSize: 14, weight: .regular))
    }

    /// Keyboard interactions are instant; only layout changes animate.
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.12)
        static let standard = Animation.easeOut(duration: 0.22)
        static let panel = Animation.spring(response: 0.32, dampingFraction: 0.82)
        static let reduced = Animation.easeInOut(duration: 0.12)

        /// Reduce Motion turns every animation into a 120 ms crossfade.
        static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? reduced : animation
        }
    }

    enum Timing {
        static let toast: Duration = .milliseconds(2_400)
        static let rememberQuery: TimeInterval = 90
    }
}

extension NSFont.Weight {
    static let w550 = NSFont.Weight(rawValue: 0.265)
    static let w650 = NSFont.Weight(rawValue: 0.35)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension SwiftUI.Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }

    var isHighContrast: Bool {
        bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
            .map { $0 == .accessibilityHighContrastAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}
