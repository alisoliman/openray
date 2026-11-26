import SwiftUI

extension SettingsPane {
    static let translator = SettingsPane(
        id: "translator", title: "Translator",
        subtitle: "The language Translate uses, on this Mac with Apple Translation.",
        kind: .command, symbol: "character.bubble",
        keywords: "translate translation language target german french spanish apple offline download"
    ) { model, _ in AnyView(TranslatorPane(model: model)) }
}

struct TranslatorPane: View {
    let model: LauncherModel

    private var provider: TranslatorProvider? {
        model.registry.provider(id: TranslatorProvider.registration.id) as? TranslatorProvider
    }

    var body: some View {
        SettingsPaneScaffold(pane: .translator) {
            if let provider {
                Section {
                    Picker(
                        selection: Binding(
                            get: { provider.defaultTarget(in: model).id },
                            set: { id in
                                if let language = TranslationLanguages.all.first(where: { $0.id == id }) {
                                    provider.setDefaultTarget(language, in: model)
                                }
                            })
                    ) {
                        ForEach(TranslationLanguages.all) { Text($0.name).tag($0.id) }
                    } label: {
                        SettingRowLabel(
                            title: "Translate into",
                            detail: "Text already in this language goes to the language you last translated from.")
                    }
                    .neutralMenus()
                }
                Section("How it works") {
                    IconRow("Type “hello in german” in search, or open Translate", symbol: "character.bubble")
                    IconRow("OpenRay detects the source language on this Mac", symbol: "text.magnifyingglass")
                    IconRow("Each language downloads once, after macOS asks, then works offline", symbol: "arrow.down.circle")
                }
            }
        }
    }
}
