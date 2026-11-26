import AppKit
import SwiftUI

extension SettingsPane {
    static let system = SettingsPane(
        id: "system", title: "System",
        subtitle: "Confirmations, Quit All Apps and permissions for system commands.",
        kind: .system, symbol: "power",
        keywords:
            "system commands quit all apps exclusions keep running confirm empty trash restart shut down log out automation apple events sound"
    ) { model, _ in AnyView(SystemPane(model: model)) }
}

struct SystemPane: View {
    @Bindable var model: LauncherModel

    private var settings: SystemCommandSettings { model.store.database.systemCommandSettings }

    var body: some View {
        SettingsPaneScaffold(pane: .system) {
            Section {
                Toggle(isOn: binding(\.confirmsEmptyingTrash)) {
                    SettingRowLabel(title: "Confirm before emptying the Trash", detail: "Empty Trash asks in the action bar first.")
                }
                .settingsSwitch()
                Toggle(isOn: binding(\.confirmsQuittingApps)) {
                    SettingRowLabel(
                        title: "Confirm before quitting apps", detail: "Quit All Apps and Quit Others ask in the action bar first.")
                }
                .settingsSwitch()
            } header: {
                Text("Confirmations")
            } footer: {
                Text("Restart, Shut Down and Log Out always ask.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section {
                if settings.quitExclusions.isEmpty {
                    Text("Every app quits. Add apps that should keep running, such as a music player.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.quitExclusions, id: \.self) { bundleIdentifier in
                    HStack {
                        Text(Self.appName(for: bundleIdentifier))
                        Spacer()
                        Button(role: .destructive) {
                            save { $0.quitExclusions.removeAll { $0 == bundleIdentifier } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop keeping \(Self.appName(for: bundleIdentifier)) running")
                        .accessibilityLabel("Remove \(Self.appName(for: bundleIdentifier))")
                    }
                }
                Menu("Add App…") {
                    ForEach(addableApps) { app in
                        Button(app.name) { save { $0.quitExclusions.append(app.bundleIdentifier) } }
                    }
                }
                .disabled(addableApps.isEmpty)
                .fixedSize()
            } header: {
                Text("Quit All Apps keeps running")
            } footer: {
                Text("OpenRay and Finder always keep running.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
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

    struct AddableApp: Identifiable, Hashable {
        var name: String
        var bundleIdentifier: String
        var id: String { bundleIdentifier }
    }

    /// Running apps with a Dock icon that aren't excluded yet, by name.
    private var addableApps: [AddableApp] {
        let excluded = Set(settings.quitExclusions).union(AppSelection.neverQuit)
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> AddableApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own, !excluded.contains(id),
                seen.insert(id).inserted
            else { return nil }
            return AddableApp(name: app.localizedName ?? id, bundleIdentifier: id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func appName(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
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
