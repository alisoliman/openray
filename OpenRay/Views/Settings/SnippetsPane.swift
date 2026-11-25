import AppKit
import SwiftUI

extension SettingsPane {
    static let snippets = SettingsPane(
        id: "snippets", title: "Snippets",
        subtitle: "Text that expands from a keyword as you type.",
        kind: .snippet, symbol: "curlybraces",
        keywords: "keyword expand expansion type"
    ) { model, _ in AnyView(SnippetsPane(model: model)) }
}

struct SnippetsPane: View {
    @Bindable var model: LauncherModel

    var body: some View {
        SettingsPaneScaffold(pane: .snippets) {
            Section {
                Toggle(isOn: model.preference(\.snippetExpansionEnabled)) {
                    SettingRowLabel(
                        title: "Expand keywords as I type",
                        detail: "Only a short keyword buffer is held in memory. Typing is never saved. Skipped during Secure Input and in excluded apps.")
                }
                .settingsSwitch()
                .disabled(!model.accessibilityAllowed)
                if !model.accessibilityAllowed {
                    LabeledContent {
                        Button("Enable…") {
                            model.windows.requestPermission()
                            SystemSettingsLink.open(.accessibility)
                        }
                    } label: {
                        Label("Needs Accessibility, which is off.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(OR.Color.warning).font(.system(size: 12))
                    }
                }
            }
            Section("Snippets with keywords") {
                let snippets = model.store.database.snippets.filter { !$0.keyword.isEmpty }
                if snippets.isEmpty {
                    Text("Snippets you give a keyword appear here. Create them from the Snippets command.")
                        .foregroundStyle(.secondary).font(.system(size: 12.5))
                }
                ForEach(snippets) { snippet in
                    Toggle(isOn: Binding(
                        get: { snippet.expandsAsYouType },
                        set: { value in
                            var updated = snippet
                            updated.expandsKeyword = value ? nil : false
                            model.store.save(updated)
                        })
                    ) {
                        HStack(spacing: 8) {
                            KindTile(kind: .snippet, size: 18)
                            Text(snippet.name)
                            AliasChip(text: snippet.keyword)
                        }
                    }
                    .settingsSwitch()
                    .disabled(!model.store.database.preferences.snippetExpansionEnabled)
                }
            }
        }
    }
}
