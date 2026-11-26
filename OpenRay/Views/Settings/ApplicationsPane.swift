import AppKit
import SwiftUI

extension SettingsPane {
    static let applications = SettingsPane(
        id: "applications", title: "Applications",
        subtitle: "Where apps are found, which ones show, and Auto Quit.",
        kind: .system, symbol: "square.grid.2x2",
        keywords: "apps folders deep search hide auto quit idle quit all hide all keep running uninstall refresh"
    ) { model, _ in AnyView(ApplicationsPane(model: model)) }
}

struct ApplicationsPane: View {
    let model: LauncherModel

    var body: some View {
        let settings = model.applicationSettings
        SettingsPaneScaffold(pane: .applications) {
            FolderListSection(
                title: "App folders", emptyText: "Only the standard Applications folders",
                footer: "OpenRay always searches /Applications, ~/Applications and the system's apps. Add folders kept elsewhere.",
                folders: settings.extraFolders, prompt: "Add Folder"
            ) { folders in model.updateApplicationSettings { $0.extraFolders = folders } }
            Section {
                Toggle(isOn: binding(\.deepSearch)) {
                    SettingRowLabel(
                        title: "Deep search", detail: "Find apps up to three levels inside the folders you added.")
                }
                .settingsSwitch()
                LabeledContent {
                    Button("Refresh") { Task { await model.applications.refresh() } }
                        .disabled(model.applications.isLoading)
                } label: {
                    SettingRowLabel(
                        title: model.applications.isLoading
                            ? "Looking for apps…" : "\(model.applications.applications.count.formatted()) apps found",
                        detail: "New apps appear after a refresh or the next launch.")
                }
            }
            AppListSection(
                model: model, title: "Hidden from search", emptyText: "Every app shows in search",
                footer: "Use Hide from Search in ⌘K on an app, or add one here.",
                ids: settings.hiddenAppIDs.compactMap(bundleID(fromItemID:)), addTitle: "Hide App"
            ) { ids in model.updateApplicationSettings { $0.hiddenAppIDs = ids.map { "app.\($0)" } } }
            AutoQuitSection(model: model)
            AppListSection(
                model: model, title: "Keep running", emptyText: "No apps kept running",
                footer: "Hide All Apps and Quit All Apps, in the Applications scope's ⌘K, leave these apps alone. OpenRay and the Finder are never quit.",
                ids: settings.keepRunningBundleIDs, addTitle: "Add App"
            ) { ids in model.updateApplicationSettings { $0.keepRunningBundleIDs = ids } }
        }
    }

    /// `app.<bundle id>` → bundle id. Path-based ids (apps without a bundle id) are listed as paths.
    private func bundleID(fromItemID id: String) -> String? {
        id.hasPrefix("app.") ? String(id.dropFirst(4)) : nil
    }

    private func binding<Value>(_ path: WritableKeyPath<ApplicationSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.applicationSettings[keyPath: path] },
            set: { value in model.updateApplicationSettings { $0[keyPath: path] = value } })
    }
}

/// Auto Quit: the default idle time, and each chosen app with its own time or the default.
private struct AutoQuitSection: View {
    let model: LauncherModel

    var body: some View {
        let settings = model.applicationSettings
        let ids = settings.autoQuit.keys.sorted { AppListSection.name(for: $0) < AppListSection.name(for: $1) }
        Section {
            Picker(
                "Quit after", selection: Binding(
                    get: { model.applicationSettings.autoQuitDefaultMinutes },
                    set: { minutes in model.updateApplicationSettings { $0.autoQuitDefaultMinutes = minutes } })
            ) {
                ForEach(ApplicationSettings.autoQuitChoices, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .neutralMenus()
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 10) {
                    AppListSection.icon(for: id)
                    Text(AppListSection.name(for: id))
                    Spacer()
                    Picker(
                        "Idle time for \(AppListSection.name(for: id))",
                        selection: Binding(
                            get: { model.applicationSettings.autoQuit[id] ?? nil },
                            set: { minutes in model.updateApplicationSettings { $0.autoQuit[id] = .some(minutes) } })
                    ) {
                        Text("Default").tag(Int?.none)
                        ForEach(ApplicationSettings.autoQuitChoices, id: \.self) { Text(Self.title($0)).tag(Int?.some($0)) }
                    }
                    .labelsHidden().neutralMenus().fixedSize()
                    Button("Remove") { model.updateApplicationSettings { $0.autoQuit[id] = nil } }
                        .accessibilityLabel("Stop auto quitting \(AppListSection.name(for: id))")
                }
            }
            Button {
                let added = AppListSection.chooseApps(title: "Choose apps to auto quit", prompt: "Add")
                    .filter { $0 != Bundle.main.bundleIdentifier && !AutoQuit.excluded.contains($0) }
                guard !added.isEmpty else { return }
                model.updateApplicationSettings { settings in
                    for id in added where settings.autoQuit[id] == nil { settings.autoQuit[id] = .some(nil) }
                }
            } label: {
                Label("Add App…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Auto Quit")
        } footer: {
            Text(
                "Chosen apps quit once they've been in the background this long. Being frontmost restarts the clock. Apps can still ask to save first. Turn it on for an app from ⌘K too."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    static func title(_ minutes: Int) -> String { minutes == 1 ? "1 minute" : "\(minutes) minutes" }
}

/// A list of apps by bundle id, with Remove and an Add App… picker.
struct AppListSection: View {
    let model: LauncherModel
    var title: String
    var emptyText: String
    var footer: String
    var ids: [String]
    var addTitle: String
    var save: ([String]) -> Void

    var body: some View {
        Section {
            if ids.isEmpty { Text(emptyText).foregroundStyle(.secondary) }
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 10) {
                    Self.icon(for: id)
                    Text(Self.name(for: id))
                    Spacer()
                    Button("Remove") { save(ids.filter { $0 != id }) }
                        .accessibilityLabel("Remove \(Self.name(for: id))")
                }
            }
            Button {
                let added = Self.chooseApps(title: title, prompt: "Add")
                guard !added.isEmpty else { return }
                save(ids + added.filter { !ids.contains($0) })
            } label: {
                Label("\(addTitle)…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(title)
        } footer: {
            Text(footer).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder static func icon(for id: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            WorkspaceIcon(url: url, size: 20)
        } else {
            Image(systemName: "app.dashed").frame(width: 20, height: 20)
        }
    }

    static func name(for id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func chooseApps(title: String, prompt: String) -> [String] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
}
