import AppKit
import SwiftUI

extension SettingsPane {
    static let snippets = SettingsPane(
        id: "snippets", title: "Snippets",
        subtitle: "Text that expands from a keyword as you type.",
        kind: .snippet, symbol: "curlybraces",
        keywords: "keyword expand expansion type delimiter within words text replacements"
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
                LabeledContent {
                    Picker("Expand", selection: expansionBinding(\.mode)) {
                        ForEach(SnippetExpansionMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize().neutralMenus()
                    .accessibilityIdentifier("settings.snippets.mode")
                } label: {
                    SettingRowLabel(
                        title: "Expand", detail: "A delimiter is a space, punctuation, a quote or a bracket. Return and Tab never expand.")
                }
                .disabled(!model.store.database.preferences.snippetExpansionEnabled)
                Toggle(isOn: expansionBinding(\.expandsWithinWords)) {
                    SettingRowLabel(title: "Expand inside words", detail: "Off: a keyword expands only at the start of a word.")
                }
                .settingsSwitch()
                .disabled(!model.store.database.preferences.snippetExpansionEnabled)
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
            LibraryTransferSection(model: model, kinds: [.snippets])
        }
    }

    private func expansionBinding<Value>(_ path: WritableKeyPath<SnippetExpansionSettings, Value>) -> Binding<Value> {
        Binding(
            get: { (model.store.database.preferences.snippetExpansion ?? SnippetExpansionSettings())[keyPath: path] },
            set: { value in
                if model.store.update({
                    var settings = $0.preferences.snippetExpansion ?? SnippetExpansionSettings()
                    settings[keyPath: path] = value
                    $0.preferences.snippetExpansion = settings
                }) {
                    model.applyPreferences()
                }
            })
    }
}

/// Import and export buttons for snippets and quicklinks. Imports accept the plain
/// JSON other launchers export and, for snippets, macOS Text Replacements.
struct LibraryTransferSection: View {
    let model: LauncherModel
    var kinds: [LibraryTransferKind] = LibraryTransferKind.allCases

    var body: some View {
        Section {
            ForEach(kinds, id: \.self) { kind in
                LabeledContent {
                    HStack {
                        Button("Import…") { model.runImport(kind, files: PanelLibraryFileAccess()) }
                            .accessibilityIdentifier("settings.import.\(kind.rawValue)")
                        Button("Export…") { model.runExport(kind, files: PanelLibraryFileAccess()) }
                            .accessibilityIdentifier("settings.export.\(kind.rawValue)")
                    }
                } label: {
                    SettingRowLabel(
                        title: kind.title,
                        detail: kind == .snippets
                            ? "JSON with name, text and keyword, or a Text Replacements property list."
                            : "JSON with name, link and openWith.")
                }
            }
        } header: {
            Text("Import and Export")
        } footer: {
            Text("Duplicates are skipped. A keyword that's already taken is dropped, and the snippet is imported without it. Encrypted settings archives can't be imported.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
