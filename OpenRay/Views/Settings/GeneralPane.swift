import AppKit
import SwiftUI

extension SettingsPane {
    static let general = SettingsPane(
        id: "general", title: "General",
        subtitle: "How OpenRay looks and opens.",
        kind: .system, symbol: "slider.horizontal.3",
        keywords: "appearance light dark theme bar mode compact remember last query search applications index refresh"
    ) { model, _ in AnyView(GeneralPane(model: model)) }
}

struct GeneralPane: View {
    @Bindable var model: LauncherModel

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
                Toggle(isOn: model.optionalPreference(\.barMode)) {
                    SettingRowLabel(title: "Start as a search bar", detail: "Show only the field until you type, like Spotlight.")
                }
                .settingsSwitch()
            }
            Section("Search") {
                Toggle(isOn: model.optionalPreference(\.rememberLastQuery, default: true)) {
                    SettingRowLabel(
                        title: "Remember the last search for 90 seconds",
                        detail: "Reopening OpenRay shows it selected, so typing replaces it.")
                }
                .settingsSwitch()
                LabeledContent {
                    Button(model.applications.isLoading ? "Refreshing…" : "Refresh") {
                        Task { await model.applications.refresh() }
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
