import SwiftUI

/// A Settings pane: its sidebar row, the words search matches, and the view it shows.
///
/// Each pane declares itself next to its view, as `extension SettingsPane { static let … }`
/// (see `GeneralPane.swift`). Adding a pane takes that declaration plus one line in
/// `primary` or `secondary` below, inserted under your slice's comment, which set the sidebar order.
struct SettingsPane: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// The toolbar subtitle under the pane's title.
    let subtitle: String
    let kind: Kind
    let symbol: String
    /// Words the sidebar search matches, so search finds settings, not just pane names.
    let keywords: String
    private let makeContent: @MainActor @Sendable (LauncherModel, SettingsNavigation) -> AnyView

    init(
        id: String, title: String, subtitle: String, kind: Kind, symbol: String, keywords: String,
        content: @escaping @MainActor @Sendable (LauncherModel, SettingsNavigation) -> AnyView
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.symbol = symbol
        self.keywords = keywords
        makeContent = content
    }

    /// The pane `--open-settings <id>` and accessibility identifiers use.
    var rawValue: String { id }

    init?(rawValue: String) {
        guard let pane = Self.allCases.first(where: { $0.id == rawValue }) else { return nil }
        self = pane
    }

    @MainActor func content(model: LauncherModel, navigation: SettingsNavigation) -> AnyView {
        makeContent(model, navigation)
    }

    static func == (lhs: SettingsPane, rhs: SettingsPane) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension SettingsPane {
    // One pane per line, in sidebar order. To add a pane, insert its line directly below your
    // slice's comment. Keep the comment; never replace it. The retained comment lines separate
    // the slots, so additions from parallel branches merge without conflicts.
    static let primary: [SettingsPane] = [
        .general,
        // Slice 1: keyboard
        .shortcuts,
        // Slice 2: clipboard, snippets
        .clipboard,
        .snippets,
        // Slice 3: calculator, emoji, translator
        .files,
        // Slice 4: applications
        .ai,
        // Slice 5: windows, system
        // Slice 6: notes, calendar, focus
        // Slice 8: scripts
    ]

    static let secondary: [SettingsPane] = [.permissions, .library, .about]

    static var allCases: [SettingsPane] { primary + secondary }
}
