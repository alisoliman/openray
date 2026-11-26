import AppKit
import SwiftUI

extension SettingsPane {
    static let files = SettingsPane(
        id: "files", title: "Files",
        subtitle: "Where Files looks, what it skips, and how it sorts.",
        kind: .file, symbol: "folder",
        keywords:
            "spotlight folder search home documents downloads desktop developer scopes ignore gitignore hidden content sort terminal exclude"
    ) { model, _ in AnyView(FilesPane(model: model)) }
}

struct FilesPane: View {
    @Bindable var model: LauncherModel
    @State private var patterns = ""

    var body: some View {
        let settings = model.filesSettings
        SettingsPaneScaffold(pane: .files) {
            Section {
                Picker("Search in", selection: $model.fileScope) {
                    ForEach(FileSearchScope.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .neutralMenus()
                Picker("Sort results by", selection: binding(\.sort)) {
                    ForEach(FileSortOrder.allCases) { Text($0.title).tag($0) }
                }
                .neutralMenus()
                Toggle(isOn: binding(\.matchesContent)) {
                    SettingRowLabel(
                        title: "Search file contents",
                        detail: "Files also finds documents by the words inside them. Type content: to search contents only.")
                }
                .settingsSwitch()
            } footer: {
                Text("You can change the folder in the Files scope too. Type ~/ or / to browse folders: Tab opens one, ⇧Tab goes up.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            FolderListSection(
                title: "More places to search", emptyText: "Only your home folder",
                footer: "Home searches also cover these folders, such as an external drive or iCloud Drive.",
                folders: settings.extraScopes, prompt: "Add Folder"
            ) { folders in model.updateFilesSettings { $0.extraScopes = folders } }
            Section {
                Toggle(isOn: binding(\.includesHiddenFiles)) {
                    SettingRowLabel(title: "Include hidden files", detail: "Dotfiles and hidden folders. .git and the Trash stay out.")
                }
                .settingsSwitch()
                Toggle(isOn: binding(\.usesIgnoreFiles)) {
                    SettingRowLabel(
                        title: "Use ignore files",
                        detail: "Skip what .gitignore, .ignore and .openrayignore files in your folders leave out.")
                }
                .settingsSwitch()
                LabeledContent {
                    TextField("Ignore patterns", text: $patterns, prompt: Text("*.log, build/**"))
                        .labelsHidden()
                        .onSubmit(savePatterns)
                        .frame(minWidth: 220)
                } label: {
                    SettingRowLabel(
                        title: "Ignore patterns",
                        detail: "Comma-separated, in .gitignore syntax. They match at any depth; start one with / to anchor it.")
                }
            } header: {
                Text("Skipped")
            } footer: {
                Text("Your Library folder, node_modules, DerivedData and app bundles are always skipped.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            FolderListSection(
                title: "Excluded from search", emptyText: "Nothing excluded",
                footer: "Use Exclude from Search in ⌘K on a file or folder to add it here.",
                folders: settings.excludedPaths, prompt: nil
            ) { folders in model.updateFilesSettings { $0.excludedPaths = folders } }
            TerminalSection(model: model)
            Section {
                LabeledContent {
                    Button("Open Spotlight Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!)
                    }
                } label: {
                    SettingRowLabel(title: "Missing files?", detail: "Files uses your existing Spotlight index. Check that your home folder isn't excluded.")
                }
            }
        }
        .onAppear { patterns = settings.ignorePatterns.joined(separator: ", ") }
        .onDisappear(perform: savePatterns)
    }

    private func savePatterns() {
        let parsed = FilesSettings.patterns(patterns)
        guard parsed != model.filesSettings.ignorePatterns else { return }
        model.updateFilesSettings { $0.ignorePatterns = parsed }
    }

    private func binding<Value>(_ path: WritableKeyPath<FilesSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.filesSettings[keyPath: path] },
            set: { value in model.updateFilesSettings { $0[keyPath: path] = value } })
    }
}

/// The terminal Open in Terminal uses, from the ones installed.
private struct TerminalSection: View {
    let model: LauncherModel

    var body: some View {
        let terminals = model.filesProvider?.workspace.installedTerminals() ?? []
        if terminals.count > 1 {
            Section {
                Picker(
                    "Open in Terminal uses",
                    selection: Binding(
                        get: { model.filesSettings.terminalBundleID },
                        set: { id in model.updateFilesSettings { $0.terminalBundleID = id } })
                ) {
                    ForEach(terminals, id: \.url) { Text($0.name).tag($0.bundleID ?? "") }
                }
                .neutralMenus()
            }
        }
    }
}

/// A list of folders with Add and Remove, as rows of the group.
struct FolderListSection: View {
    var title: String
    var emptyText: String
    var footer: String
    var folders: [String]
    /// The Add button's title, or nil when folders are added elsewhere.
    var prompt: String?
    var save: ([String]) -> Void

    var body: some View {
        Section {
            if folders.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.self) { path in
                HStack(spacing: 10) {
                    WorkspaceIcon(url: URL(fileURLWithPath: path), size: 20)
                    Text(LauncherModel.shortenedPath(URL(fileURLWithPath: path))).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { save(folders.filter { $0 != path }) }
                        .accessibilityLabel("Remove \(URL(fileURLWithPath: path).lastPathComponent)")
                }
            }
            if let prompt {
                Button { addFolders() } label: { Label("\(prompt)…", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map { $0.standardizedFileURL.path }
        guard !added.isEmpty else { return }
        save(folders + added.filter { !folders.contains($0) })
    }
}
