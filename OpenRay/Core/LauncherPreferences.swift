import Foundation

// Launcher preferences added by Slice 1. Each `AppPreferences` field is optional, so earlier
// libraries keep decoding; nil means the default named here.

/// How long the launcher keeps its place after it hides. Reopening within the delay shows the
/// same search; after it, Everything with an empty field.
enum PopToRootDelay: String, Codable, CaseIterable, Identifiable, Sendable {
    case immediately, seconds90, minutes3, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediately: "Immediately"
        case .seconds90: "After 90 seconds"
        case .minutes3: "After 3 minutes"
        case .never: "Never"
        }
    }

    /// Seconds the place is kept, or nil to keep it forever.
    var interval: TimeInterval? {
        switch self {
        case .immediately: 0
        case .seconds90: 90
        case .minutes3: 180
        case .never: nil
        }
    }
}

/// What Esc does.
enum EscapeBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Closes one layer, as before: a prompt, a panel, an editor, a scope, the query, then the window.
    case navigateBack
    /// Closes the window at once. ⌫ on an empty field and ⌘Esc still navigate.
    case closeWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .navigateBack: "Go back one step, then close"
        case .closeWindow: "Close the window"
        }
    }
}

/// The screen the launcher opens on.
enum LauncherScreen: String, Codable, CaseIterable, Identifiable, Sendable {
    case mouse, focusedWindow, primary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mouse: "Screen with the pointer"
        case .focusedWindow: "Screen with the active window"
        case .primary: "Primary screen"
        }
    }
}

/// The launcher's text and row size.
enum InterfaceSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, standard, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Default"
        case .large: "Large"
        }
    }

    /// The design tokens' scale (`OR.interfaceScale`): fonts and the launcher's lengths.
    var scale: CGFloat {
        switch self {
        case .compact: 0.92
        case .standard: 1
        case .large: 1.12
        }
    }
}

/// What ↩ does for rows whose content can be copied or pasted: clipboard entries, snippets,
/// calculator answers and provided rows with the `.paste` trait. ⌘↩ does the other.
enum PrimaryAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case copy, paste

    var id: String { rawValue }
    var title: String { self == .copy ? "Copy to Clipboard" : "Paste to Active App" }
}

/// A right-side modifier as ⌃⌥⌘ (and optionally ⇧) while it's held. Off unless turned on.
/// Every field decodes with a default, so settings saved by another build always load.
struct HyperKeySettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var includesShift = true
    var trigger: HyperKeyTrigger = .rightCommand

    /// The modifiers the Hyper key holds down.
    var modifiers: ShortcutModifiers { includesShift ? .all : [.command, .control, .option] }

    init(isEnabled: Bool = false, includesShift: Bool = true, trigger: HyperKeyTrigger = .rightCommand) {
        self.isEnabled = isEnabled
        self.includesShift = includesShift
        self.trigger = trigger
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, includesShift, trigger }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        includesShift = (try? container.decodeIfPresent(Bool.self, forKey: .includesShift)) ?? true
        trigger = (try? container.decodeIfPresent(HyperKeyTrigger.self, forKey: .trigger)) ?? .rightCommand
    }
}
