import Foundation

struct LauncherItem: Identifiable, Sendable {
    enum Action: Sendable {
        case application(InstalledApplication)
        case file(URL)
        case section(LauncherSection)
        case clipboard(ClipboardEntry)
        case snippet(Snippet)
        case quicklink(Quicklink, String)
        case note(QuickNote)
        case window(WindowLayout)
        case ai(AIAction)
        case calculation(Calculation)
        case settings
        case pomodoro
        case startPomodoro
    }
    enum Tint: Sendable { case blue, green, orange, purple, coral, neutral }
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Tint = .neutral
    var badge: String
    var keywords = ""
    var iconURL: URL?
    var clipboardImage: ClipboardImageResource?
    var action: Action

    var copyText: String? {
        switch action {
        case .clipboard(let entry): entry.plainText
        case .snippet(let snippet): snippet.expanded()
        case .calculation(let calculation): calculation.result
        case .note(let note): note.content
        case .file(let url): url.path
        case .application(let app): app.url.path
        case .quicklink(let link, _): link.template
        default: nil
        }
    }

    var primaryActionTitle: String {
        switch action {
        case .clipboard, .snippet, .calculation: "Copy to Clipboard"
        case .window: "Apply Layout"
        case .note: "Open Note"
        case .ai: "Open AI"
        case .startPomodoro: "Start Timer"
        default: "Open"
        }
    }

    var supportsPaste: Bool {
        switch action {
        case .clipboard, .snippet, .calculation, .note: true
        default: false
        }
    }

    var canFavorite: Bool {
        if case .calculation = action { false } else { true }
    }

    var isBuiltInCommand: Bool {
        switch action {
        case .section, .ai, .settings, .window, .pomodoro, .startPomodoro: true
        default: false
        }
    }

    var accessibilityDescription: String {
        switch action {
        case .file(let url):
            "\(title), \(badge), in \(url.deletingLastPathComponent().path)"
        case .application(let app):
            "\(title), \(badge), in \(app.url.deletingLastPathComponent().path)"
        default:
            "\(title), \(badge)"
        }
    }
}

struct LauncherResultGroup: Identifiable {
    var title: String
    var items: [LauncherItem]
    var id: String { title }
}

enum LibraryEditor: Identifiable {
    case quicklink(Quicklink)
    case snippet(Snippet)
    case note(QuickNote)
    case quicklinkQuery(Quicklink, String)
    var id: String {
        switch self {
        case .quicklink(let item): "quicklink.\(item.id)"
        case .snippet(let item): "snippet.\(item.id)"
        case .note(let item): "note.\(item.id)"
        case .quicklinkQuery(let item, _): "query.\(item.id)"
        }
    }
}
