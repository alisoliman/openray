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

/// Auto Quit: the default idle time, and each chosen copy of an app with its own time or the
/// default. A rule saved with a bundle id alone is shown as inactive until a copy is chosen.
private struct AutoQuitSection: View {
    let model: LauncherModel

    var body: some View {
        let settings = model.applicationSettings
        let targets = settings.autoQuit.keys.sorted { Self.label(for: $0) < Self.label(for: $1) }
        Section {
            Picker(
                "Quit after", selection: Binding(
                    get: { model.applicationSettings.autoQuitDefaultMinutes },
                    set: { minutes in model.updateApplicationSettings { $0.autoQuitDefaultMinutes = minutes } })
            ) {
                ForEach(ApplicationSettings.autoQuitChoices, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .neutralMenus()
            ForEach(targets, id: \.self) { target in
                HStack(spacing: 10) {
                    if let path = target.path {
                        WorkspaceIcon(url: URL(fileURLWithPath: path), size: 20)
                    } else {
                        AppListSection.icon(for: target.bundleID)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.label(for: target))
                        Text(target.path.map { LauncherModel.shortenedPath(URL(fileURLWithPath: $0)) } ?? "Inactive: choose which copy")
                            .font(.system(size: 11)).foregroundStyle(target.path == nil ? OR.Color.warning : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if target.path == nil {
                        Button("Choose…") { choose(replacing: target) }
                    } else {
                        Picker(
                            "Idle time for \(Self.label(for: target))",
                            selection: Binding(
                                get: { model.applicationSettings.autoQuit[target] ?? nil },
                                set: { minutes in model.updateApplicationSettings { $0.autoQuit[target] = .some(minutes) } })
                        ) {
                            Text("Default").tag(Int?.none)
                            ForEach(ApplicationSettings.autoQuitChoices, id: \.self) { Text(Self.title($0)).tag(Int?.some($0)) }
                        }
                        .labelsHidden().neutralMenus().fixedSize()
                    }
                    Button("Remove") { model.updateApplicationSettings { $0.autoQuit[target] = nil } }
                        .accessibilityLabel("Stop auto quitting \(Self.label(for: target))")
                }
            }
            Button { choose(replacing: nil) } label: { Label("Add App…", systemImage: "plus") }
                .buttonStyle(.borderless)
        } header: {
            Text("Auto Quit")
        } footer: {
            Text(
                "Chosen apps quit once they've been in the background this long. Being frontmost restarts the clock. Only the copy you choose is quit, never another copy with the same name. Apps can still ask to save first."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// Picks app copies to auto quit, replacing an inactive rule when one is given.
    private func choose(replacing old: AutoQuitTarget?) {
        let chosen = AppListSection.chooseAppCopies(title: "Choose apps to auto quit", prompt: "Add")
            .filter { $0.bundleID != Bundle.main.bundleIdentifier && !AutoQuit.excluded.contains($0.bundleID) }
        guard !chosen.isEmpty else { return }
        model.updateApplicationSettings { settings in
            let minutes = old.flatMap { settings.autoQuit[$0] } ?? nil
            if let old { settings.autoQuit[old] = nil }
            for target in chosen where settings.autoQuit[target] == nil {
                settings.autoQuit[target] = .some(minutes)
                // A copy chosen for an id settles that id's inactive rule too.
                settings.autoQuit[AutoQuitTarget(bundleID: target.bundleID, path: nil)] = nil
            }
        }
    }

    static func label(for target: AutoQuitTarget) -> String {
        if let path = target.path {
            return FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        }
        return AppListSection.name(for: target.bundleID)
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

    /// Chosen app bundles as Auto Quit targets: the bundle id and the canonical path of that copy.
    static func chooseAppCopies(title: String, prompt: String) -> [AutoQuitTarget] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { url in
            Bundle(url: url)?.bundleIdentifier.map { AutoQuitTarget(bundleID: $0, url: url) }
        }
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
