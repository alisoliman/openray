import SwiftUI

extension SettingsPane {
    static let emoji = SettingsPane(
        id: "emoji", title: "Emoji & Symbols",
        subtitle: "Skin tone, tile size and ranking for Search Emoji & Symbols.",
        kind: .command, symbol: "face.smiling",
        keywords: "emoji symbols skin tone columns grid size pinned frequently used keywords unicode"
    ) { model, _ in AnyView(EmojiPane(model: model)) }
}

struct EmojiPane: View {
    let model: LauncherModel

    private var provider: EmojiProvider? {
        model.registry.provider(id: EmojiProvider.registration.id) as? EmojiProvider
    }

    var body: some View {
        SettingsPaneScaffold(pane: .emoji) {
            if let provider {
                let preferences = provider.preferences(in: model)
                Section {
                    Picker(
                        selection: Binding(
                            get: { preferences.defaultSkinTone },
                            set: { tone in provider.update(in: model) { $0.defaultSkinTone = tone } })
                    ) {
                        ForEach(SkinTone.allCases) { tone in Text("\(tone.sample)  \(tone.title)").tag(tone) }
                    } label: {
                        SettingRowLabel(
                            title: "Default skin tone",
                            detail: "For emoji that support one. ⌥⌘C and ⌥⌘V pick another tone for a single emoji.")
                    }
                    .neutralMenus()
                    Picker(
                        selection: Binding(
                            get: { preferences.columns },
                            set: { columns in provider.update(in: model) { $0.columns = columns } })
                    ) {
                        ForEach(GridColumns.range, id: \.self) { Text("\($0) columns").tag($0) }
                    } label: {
                        SettingRowLabel(title: "Grid size", detail: "⌘+ and ⌘− change it while you browse.")
                    }
                    .neutralMenus()
                }
                Section("Ranking") {
                    LabeledContent {
                        Button("Reset Ranking") {
                            provider.update(in: model) { $0.usage = EmojiUsage() }
                        }
                        .disabled(preferences.usage.records.isEmpty)
                    } label: {
                        SettingRowLabel(
                            title: "\(preferences.pinned.count) pinned, \(preferences.usage.records.count) recently used",
                            detail: "Pinned emoji come first. Frequently used ones follow, and fade when you stop using them.")
                    }
                }
                Section {
                    IconRow("Search by name, keyword or category, such as “thumbs up” or “arrow”", symbol: "magnifyingglass")
                    IconRow("⌘E adds your own keywords; ⌘. pins an emoji", symbol: "tag")
                    IconRow("Names and keywords come from Unicode's CLDR data", symbol: "character.book.closed")
                }
            }
        }
    }
}
