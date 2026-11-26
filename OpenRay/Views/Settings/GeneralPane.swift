import AppKit
import SwiftUI

extension SettingsPane {
    static let general = SettingsPane(
        id: "general", title: "General",
        subtitle: "How OpenRay looks and opens.",
        kind: .system, symbol: "slider.horizontal.3",
        keywords: "appearance light dark theme bar mode compact remember last query search applications index refresh pop root screen display monitor return copy paste primary action history ranking reset interface size text larger smaller"
    ) { model, _ in AnyView(GeneralPane(model: model)) }
}

struct GeneralPane: View {
    @Bindable var model: LauncherModel

    private var popToRoot: Binding<PopToRootDelay> {
        Binding(
            get: { model.store.database.preferences.popToRootDelay },
            set: { value in model.store.update { $0.preferences.popToRoot = value } })
    }

    var body: some View {
        SettingsPaneScaffold(pane: .general) {
            Section("Appearance") {
                // The design's neutral segmented control: a selected segment isn't a red alert. An
                // HStack, because a form's LabeledContent ignores the control's text baseline.
                HStack(alignment: .firstTextBaseline) {
                    Text("Appearance")
                    Spacer()
                    SegmentedPicker(
                        options: AppAppearance.allCases.map { ($0, $0.title) }, selection: model.preference(\.appearance),
                        accessibilityLabel: "Appearance")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Interface size")
                    Spacer()
                    SegmentedPicker(
                        options: InterfaceSize.allCases.map { ($0, $0.title) },
                        selection: model.optionalPreference(\.interfaceSize, default: .standard),
                        accessibilityLabel: "Interface size")
                }
                Toggle(isOn: model.optionalPreference(\.barMode)) {
                    SettingRowLabel(title: "Start as a search bar", detail: "Show only the field until you type, like Spotlight.")
                }
                .settingsSwitch()
            }
            Section("Search") {
                Picker(selection: popToRoot) {
                    ForEach(PopToRootDelay.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingRowLabel(
                        title: "Back to Everything",
                        detail: "Until then, reopening OpenRay shows your last search, selected so typing replaces it.")
                }
                .neutralMenus()
                Picker("Open on", selection: model.optionalPreference(\.launcherScreen, default: .mouse)) {
                    ForEach(LauncherScreen.allCases) { Text($0.title).tag($0) }
                }
                .neutralMenus()
                Picker(selection: model.optionalPreference(\.primaryAction, default: .copy)) {
                    ForEach(PrimaryAction.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingRowLabel(
                        title: "Return on clipboard items, snippets and results",
                        detail: "⌘↩ does the other.")
                }
                .neutralMenus()
                Toggle(isOn: model.optionalPreference(\.searchHistory, default: true)) {
                    SettingRowLabel(
                        title: "Remember searches",
                        detail: "↑ in an empty field brings back earlier searches.")
                }
                .settingsSwitch()
                LabeledContent {
                    HStack {
                        Button("Clear History") { model.clearSearchHistory() }
                            .disabled(model.memory.memory.history.isEmpty)
                        Button("Reset Ranking") { model.resetAllRanking() }
                    }
                } label: {
                    SettingRowLabel(
                        title: "Learned ranking",
                        detail: "OpenRay ranks what you pick for a search higher the next time.")
                }
                LabeledContent {
                    Button(model.applications.isLoading ? "Refreshing…" : "Refresh") {
                        Task { await model.refreshApplications() }
                    }
                    .disabled(model.applications.isLoading)
                } label: {
                    SettingRowLabel(
                        title: "Applications",
                        detail: "\(model.applications.applications.count.formatted()) apps indexed from your Applications folders")
                }
            }
            Section("Getting started") {
                LabeledContent {
                    Button("Show Again") {
                        model.store.update { $0.preferences.firstRunCompleted = false }
                        model.panel?.show()
                    }
                } label: {
                    SettingRowLabel(title: "First-run guide", detail: "The three-step introduction to OpenRay.")
                }
            }
        }
    }
}

extension LauncherModel {
    /// A binding to an optional preference that reads `fallback` while it's unset.
    func optionalPreference<Value>(_ path: WritableKeyPath<AppPreferences, Value?>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.store.database.preferences[keyPath: path] ?? fallback },
            set: { value in
                if self.store.update({ $0.preferences[keyPath: path] = value }) { self.applyPreferences() }
            })
    }
}
