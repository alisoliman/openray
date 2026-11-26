import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .general
    var search = ""
    /// A command row to scroll to and focus when the Shortcuts pane shows. Cleared once handled.
    var focusCommandID: String?
}

struct SettingsWindowView: View {
    @Bindable var model: LauncherModel
    @Bindable var navigation: SettingsNavigation
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })) {
                Section {
                    ForEach(filtered(SettingsPane.primary)) { sidebarRow($0) }
                }
                Section {
                    ForEach(filtered(SettingsPane.secondary)) { sidebarRow($0) }
                }
            }
            .searchable(text: $navigation.search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 200, ideal: 212, max: 260)
        } detail: {
            if !query.isEmpty, filtered(SettingsPane.allCases).isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                // Panes are tinted with Ray rather than the system accent. The text token, not the
                // fill token, because the tint also colors button titles and pop-up values. The
                // sidebar keeps native selection: neutral, and Ray only while it has keyboard focus.
                pane
                    .tint(OR.Color.accent)
                    .navigationTitle(navigation.pane.title)
                    .navigationSubtitle(paneSubtitle)
            }
        }
        .environment(\.settingsStoreError, storeError)
        .appAppearance(model.store.database.preferences.appearance)
        .onChange(of: activeState) { if activeState == .key { model.refreshPermissions() } }
        .onChange(of: navigation.search) {
            guard !query.isEmpty,
                let best = SettingsSearch.bestPane(for: query, commands: commandSearchTexts, catalog: catalogSearchTexts)
            else { return }
            navigation.pane = best
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    private var query: String { navigation.search.trimmingCharacters(in: .whitespaces) }

    /// What Shortcuts lists: commands that can hold a binding, with bound apps, quicklinks and snippets.
    private var commandSearchTexts: [String] {
        model.bindingRows(focusing: nil).map { model.settingsSearchText(for: $0) }
    }

    /// What Commands lists: every command, disabled ones and binding opt-outs included.
    private var catalogSearchTexts: [String] {
        model.commandCatalog.flatMap(\.commands).map { model.settingsSearchText(for: $0) }
    }

    /// A library that failed to load can't save anything, so every pane says so once, at the top.
    private var storeError: String? {
        guard model.store.isReadOnly else { return nil }
        return model.store.errorMessage ?? "Your library couldn't be loaded, so changes here aren't saved."
    }

    private var paneSubtitle: String {
        guard navigation.pane == .clipboard, !model.store.database.clipboard.isEmpty else { return navigation.pane.subtitle }
        let entries = model.store.database.clipboard
        let bytes = entries.reduce(0) { $0 + $1.byteCount }
        return "\(entries.count.formatted()) entr\(entries.count == 1 ? "y" : "ies") · "
            + "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of "
            + ByteCountFormatter.string(fromByteCount: Int64(ClipboardLimits.historyBytes), countStyle: .file)
    }

    private func filtered(_ panes: [SettingsPane]) -> [SettingsPane] {
        guard !query.isEmpty else { return panes }
        let commands = commandSearchTexts
        let catalog = catalogSearchTexts
        return panes.filter { SettingsSearch.score($0, query: query, commands: commands, catalog: catalog) != nil }
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            KindTile(kind: pane.kind, symbol: pane.symbol, size: 20)
        }
        .tag(pane)
        .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
    }

    @ViewBuilder private var pane: some View {
        navigation.pane.content(model: model, navigation: navigation)
    }
}

/// Sidebar search. Pane titles use the launcher's matcher. Keywords and command names must match
/// whole-word prefixes, so a scattered run of letters can't jump to an unrelated pane.
enum SettingsSearch {
    /// How well a pane matches, or nil when it doesn't. `commands` are the bindable commands'
    /// titles and aliases; a match there keeps Shortcuts in the results.
    /// `commands` are the rows Shortcuts lists, `catalog` the rows Commands lists (all commands);
    /// each pane matches only rows it can show. A catalog match ranks just below a Shortcuts one,
    /// so a bindable command still opens Shortcuts and a catalog-only one opens Commands.
    static func score(_ pane: SettingsPane, query: String, commands: [String] = [], catalog: [String]? = nil) -> Int? {
        let title = SearchMatcher.score(query, in: pane.title)
        // Keyword and command matches rank below the same kind of match on a pane title.
        let keywords = wordPrefixScore(query, in: pane.title + " " + pane.keywords).map { $0 - 50 }
        let rows: [String]? = pane == .shortcuts ? commands : pane == .commands ? (catalog ?? commands) : nil
        let command = rows?.compactMap { wordPrefixScore(query, in: $0) }.max().map { $0 - 150 }
        return [title, keywords, command].compactMap { $0 }.max()
    }

    /// The best-scoring pane. Ties keep sidebar order.
    static func bestPane(for query: String, commands: [String] = [], catalog: [String]? = nil) -> SettingsPane? {
        var best: (pane: SettingsPane, score: Int)?
        for pane in SettingsPane.primary + SettingsPane.secondary {
            guard let paneScore = Self.score(pane, query: query, commands: commands, catalog: catalog),
                paneScore > (best?.score ?? .min)
            else { continue }
            best = (pane, paneScore)
        }
        return best?.pane
    }

    /// Every query term must be a whole word (700) or start a word (600) in `text`, averaged.
    /// Folded case- and diacritic-insensitively.
    static func wordPrefixScore(_ query: String, in text: String) -> Int? {
        let terms = Self.words(in: query)
        guard !terms.isEmpty else { return nil }
        let candidates = Self.words(in: text)
        var total = 0
        for term in terms {
            if candidates.contains(term) {
                total += 700
            } else if candidates.contains(where: { $0.hasPrefix(term) }) {
                total += 600
            } else {
                return nil
            }
        }
        return total / terms.count
    }

    private static let locale = Locale(identifier: "en_US_POSIX")

    private static func words(in value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
