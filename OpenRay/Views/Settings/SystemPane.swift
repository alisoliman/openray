import AppKit
import SwiftUI

extension SettingsPane {
    static let system = SettingsPane(
        id: "system", title: "System",
        subtitle: "Confirmations, Quit All Apps and permissions for system commands.",
        kind: .system, symbol: "power",
        keywords:
            "system commands quit all apps exclusions keep running confirm empty trash restart shut down log out automation apple events sound"
    ) { model, navigation in AnyView(SystemPane(model: model, navigation: navigation)) }
}

struct SystemPane: View {
    @Bindable var model: LauncherModel
    var navigation: SettingsNavigation? = nil

    private var settings: SystemCommandSettings { model.store.database.systemCommandSettings }

    var body: some View {
        SettingsPaneScaffold(pane: .system) {
            Section {
                Toggle(isOn: binding(\.confirmsEmptyingTrash)) {
                    SettingRowLabel(title: "Confirm before emptying the Trash", detail: "Empty Trash asks in the action bar first.")
                }
                .settingsSwitch()
                Toggle(isOn: binding(\.confirmsHidingOtherApps)) {
                    SettingRowLabel(title: "Confirm before hiding other apps", detail: "Hide Others asks in the action bar first.")
                }
                .settingsSwitch()
            } header: {
                Text("Confirmations")
            } footer: {
                Text("Restart, Shut Down and Log Out always ask. Quit All and Quit Others always name the apps they'll quit and ask.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Open Applications Settings") { navigation?.pane = .applications }
                        .disabled(navigation == nil)
                } label: {
                    SettingRowLabel(
                        title: Self.keepRunningSummary(model.store.database.keepRunningBundleIDs),
                        detail: "Quit All, Quit Others, Hide Others and Hide All leave these apps alone. Edit the list in Settings › Applications.")
                }
            } header: {
                Text("Keep running")
            }
            Section("Permissions") {
                IconRow(
                    "Lock Screen, the media keys, Dismiss Notifications and Search Menu Bar Items use Accessibility.",
                    symbol: "accessibility")
                IconRow(
                    "Toggle System Appearance, Empty Trash, Restart, Shut Down and Log Out ask once to control System Events, Finder or the login window.",
                    symbol: "gearshape.2")
                IconRow("Toggle Wi-Fi needs an administrator when Wi-Fi settings require one.", symbol: "wifi")
                LabeledContent {
                    Button("Open Automation Settings") { Self.openAutomationSettings() }
                } label: {
                    SettingRowLabel(title: "Automation", detail: "Review which apps OpenRay may control.")
                }
            }
        }
    }

    /// Through the shared guard: inert launches never open System Settings.
    @discardableResult
    static func openAutomationSettings(opener: ExternalOpener = .live()) -> Bool {
        opener.open(ExternalOpener.automationSettings)
    }

    static func keepRunningSummary(_ ids: [String]) -> String {
        switch ids.count {
        case 0: "No apps kept running"
        case 1: "1 app kept running"
        default: "\(ids.count) apps kept running"
        }
    }

    private func binding(_ path: WritableKeyPath<SystemCommandSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: path] }, set: { value in save { $0[keyPath: path] = value } })
    }

    private func save(_ change: (inout SystemCommandSettings) -> Void) {
        var next = settings
        change(&next)
        if model.store.update({ $0.systemCommandSettings = next }) { model.commandCatalogDidChange() }
    }
}
