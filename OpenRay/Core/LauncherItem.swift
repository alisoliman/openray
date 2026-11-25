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
        /// The “Ask AI” fallback: sends the query as the first message.
        case askAI(String)
        case calculation(Calculation)
        case settings
        /// A row a registered `CommandProvider` built. Perform, titles, actions and the preview
        /// dispatch through `LauncherModel.registry`; the flags below read the ref's traits.
        case provided(ProvidedRef)
    }
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var kind: Kind = .command
    var badge: String
    var keywords = ""
    var iconURL: URL?
    var clipboardImage: ClipboardImageResource?
    var action: Action
    /// Spotlight results arrive late and never become the Top Hit.
    var isLiveResult = false

    var copyText: String? {
        switch action {
        case .clipboard(let entry): entry.plainText
        case .snippet(let snippet): snippet.expanded()
        case .calculation(let calculation): calculation.value
        case .note(let note): note.content
        case .file(let url): url.path
        case .application(let app): app.url.path
        case .quicklink(let link, let argument):
            (try? link.resolvedURL(query: argument).absoluteString) ?? link.template
        case .provided(let ref): ref.copyText
        default: nil
        }
    }

    /// The context-free primary action, used for VoiceOver hints. The action bar
    /// names the target app as well; see `LauncherModel.primaryTitle(for:)`.
    var primaryActionTitle: String {
        switch action {
        case .clipboard, .snippet: "Copy"
        // Names the number only when it's exactly what's copied and short enough for the
        // action bar's button, which can't truncate. A rounded conversion says Copy Result.
        case .calculation(let calculation):
            calculation.shownValue == calculation.value && calculation.value.count <= 16
                ? "Copy \(calculation.value)" : "Copy Result"
        case .window(let layout): "Apply \(layout.title)"
        case .note: "Open Note"
        case .ai(let action): action == .chat ? "Ask AI" : "Run Command"
        case .askAI: "Ask AI"
        case .section: "Open Command"
        case .settings: "Open Settings"
        case .application: "Open Application"
        case .quicklink(let link, let argument): link.needsQuery && argument.isEmpty ? "Enter Search Term" : "Open Link"
        case .file: "Open"
        case .provided(let ref): ref.primaryTitle ?? "Open Command"
        }
    }

    var supportsPaste: Bool {
        switch action {
        case .clipboard, .snippet, .calculation, .note, .quicklink, .file: true
        case .provided(let ref): ref.has(.paste) && ref.copyText != nil
        default: false
        }
    }

    /// Fallback and quicklink-argument rows stand in for a stored item for one
    /// query, so favoriting or deleting them would act on something unexpected.
    private var isSynthetic: Bool { id.hasPrefix("fallback.") || id.hasPrefix("argument.") }

    var canFavorite: Bool {
        switch action {
        case .calculation, .askAI: false
        case .provided(let ref): ref.has(.favorite) && !isSynthetic
        default: !isSynthetic
        }
    }

    var canDelete: Bool {
        switch action {
        case .clipboard, .snippet, .quicklink, .note: !isSynthetic
        case .provided(let ref): ref.has(.delete) && !isSynthetic
        default: false
        }
    }

    var canEdit: Bool {
        switch action {
        case .snippet, .quicklink, .note: !id.hasPrefix("fallback.")
        case .provided(let ref): ref.has(.edit) && !id.hasPrefix("fallback.")
        default: false
        }
    }

    var isBuiltInCommand: Bool {
        switch action {
        case .section, .ai, .settings, .window: true
        case .provided(let ref): ref.has(.command)
        default: false
        }
    }

    var fileURL: URL? {
        switch action {
        case .file(let url): url
        case .application(let app): app.url
        default: nil
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
    enum Style { case list, favorites, grid, calculator, fallback }
    var id: String
    var title: String?
    var trailing: String? = nil
    var isLoading = false
    var style: Style = .list
    var items: [LauncherItem]

    init(
        id: String? = nil, title: String?, trailing: String? = nil, isLoading: Bool = false, style: Style = .list,
        items: [LauncherItem]
    ) {
        self.id = id ?? title ?? "results"
        self.title = title
        self.trailing = trailing
        self.isLoading = isLoading
        self.style = style
        self.items = items
    }
}

enum LibraryEditor: Identifiable {
    case quicklink(Quicklink)
    case snippet(Snippet)
    case note(QuickNote)
    var id: String {
        switch self {
        case .quicklink(let item): "quicklink.\(item.id)"
        case .snippet(let item): "snippet.\(item.id)"
        case .note(let item): "note.\(item.id)"
        }
    }

    var section: LauncherSection {
        switch self {
        case .quicklink: .quicklinks
        case .snippet: .snippets
        case .note: .notes
        }
    }
}
