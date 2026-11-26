import AppKit
import SwiftUI

extension SettingsPane {
    static let scripts = SettingsPane(
        id: "scripts", title: "Scripts",
        subtitle: "Script commands from folders on this Mac, run from the launcher.",
        kind: .command, symbol: "terminal",
        keywords: "script commands folder directory bash python applescript shell inline refresh fallback create template package"
    ) { model, _ in AnyView(ScriptsPane(model: model)) }
}

struct ScriptsPane: View {
    let model: LauncherModel
    @State private var showsCreate = false

    private var provider: ScriptCommandProvider? {
        model.registry.provider(id: ScriptCommandProvider.registration.id) as? ScriptCommandProvider
    }

    var body: some View {
        SettingsPaneScaffold(pane: .scripts) {
            if let provider {
                foldersSection(provider)
                commandSections(provider)
                issuesSection(provider)
            } else {
                Label("Script commands aren't available in this build.", systemImage: "terminal")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { provider?.synchronize(with: model) }
        .sheet(isPresented: $showsCreate) {
            if let provider {
                CreateScriptSheet(model: model, provider: provider) { showsCreate = false }
            }
        }
    }

    @ViewBuilder private func foldersSection(_ provider: ScriptCommandProvider) -> some View {
        let directories = model.store.database.scriptDirectories
        Section {
            ForEach(directories) { record in
                let count = provider.catalog.commands.filter { $0.directoryID == record.id }.count
                let problem = provider.catalog.scan.unreadable[record.id]
                LabeledContent {
                    HStack(spacing: 8) {
                        Toggle(
                            "Use \(record.url?.lastPathComponent ?? "folder")",
                            isOn: Binding(
                                get: { record.isEnabled },
                                set: { provider.setDirectory(record.id, enabled: $0, in: model) })
                        )
                        .labelsHidden().toggleStyle(.switch).settingsSwitch()
                        Button("Reveal") { reveal(record.url) }.disabled(record.url == nil)
                        Button("Remove") { provider.removeDirectory(record.id, in: model) }
                    }
                } label: {
                    SettingRowLabel(
                        title: record.url?.lastPathComponent ?? "Folder without a path",
                        detail: problem.map { "Can't read this folder. \($0)" }
                            ?? "\(record.url.map(LauncherModel.shortenedPath) ?? "") · \(count) \(count == 1 ? "command" : "commands")")
                }
            }
            HStack {
                Button("Add Script Folder…") { addFolders(provider) }
                Button("Create Script Command…") { showsCreate = true }
                    .disabled(directories.isEmpty)
                Spacer()
                if provider.catalog.isScanning { ProgressView().controlSize(.small) }
                Button("Reload") { provider.catalog.reload() }.disabled(directories.isEmpty)
            }
        } header: {
            Text("Script Folders")
        } footer: {
            Text(
                "OpenRay reads the files at the top of each folder whose comment header has a schema version, title and mode, and watches for changes. Files with .template. in their name are skipped. Scripts run as you, in a non-login shell with /usr/local/bin and /opt/homebrew/bin on the PATH."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func commandSections(_ provider: ScriptCommandProvider) -> some View {
        let commands = provider.catalog.commands
        let packages = commands.reduce(into: [String]()) { order, command in
            if !order.contains(command.packageName) { order.append(command.packageName) }
        }
        ForEach(packages, id: \.self) { package in
            Section(package) {
                ForEach(commands.filter { $0.packageName == package }) { command in
                    ScriptCommandRow(model: model, provider: provider, command: command)
                }
            }
        }
    }

    @ViewBuilder private func issuesSection(_ provider: ScriptCommandProvider) -> some View {
        let issues = provider.catalog.issues
        if !issues.isEmpty {
            Section {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(OR.Color.warning)
                            Text(issue.title ?? issue.url.lastPathComponent).font(.system(size: 13, weight: .medium))
                            if issue.title != nil {
                                Text(issue.url.lastPathComponent).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reveal") { reveal(issue.url) }
                        }
                        ForEach(issue.problems, id: \.self) { problem in
                            Text(problem).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Scripts with Problems")
            } footer: {
                Text("Fix the header and save; the list updates on its own.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func addFolders(_ provider: ScriptCommandProvider) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders that contain script commands."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { provider.addDirectory(url, in: model) }
    }

    private func reveal(_ url: URL?) {
        guard let url, (try? SideEffectGuard.check("revealing files in Finder")) != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// One script: its icon, title, mode and file, and whether it's a fallback.
private struct ScriptCommandRow: View {
    let model: LauncherModel
    let provider: ScriptCommandProvider
    let command: ScriptCommand

    var body: some View {
        LabeledContent {
            Toggle(
                "Fallback",
                isOn: Binding(
                    get: { provider.isFallback(command.id, in: model) },
                    set: { provider.setFallback($0, for: command.id, in: model) })
            )
            .toggleStyle(.checkbox)
            .help("Offer this script under “Use … with” in search; the query becomes its first argument.")
        } label: {
            HStack(spacing: 10) {
                ScriptIconView(icon: command.metadata.icon, darkIcon: command.metadata.iconDark)
                SettingRowLabel(title: command.title, detail: detail)
            }
        }
    }

    private var detail: String {
        var parts = [command.mode.title, command.url.lastPathComponent]
        if let refresh = command.metadata.refreshTime { parts.append("every \(Int(refresh.timeInterval))s") }
        if !command.metadata.arguments.isEmpty {
            parts.append("\(command.metadata.arguments.count) argument\(command.metadata.arguments.count == 1 ? "" : "s")")
        }
        if command.metadata.needsConfirmation { parts.append("asks first") }
        var text = parts.joined(separator: " · ")
        if !command.metadata.warnings.isEmpty { text += "\n" + command.metadata.warnings.joined(separator: " ") }
        return text
    }
}

/// A script's header icon: an emoji, or a local image. Remote icons aren't fetched.
struct ScriptIconView: View {
    var icon: ScriptIcon?
    var darkIcon: ScriptIcon?
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let chosen = colorScheme == .dark ? (darkIcon ?? icon) : icon
        Group {
            switch chosen {
            case .emoji(let emoji)?:
                Text(emoji).font(.system(size: size * 0.8))
            case .file(let url)?:
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    KindTile(kind: .command, symbol: "terminal", size: size)
                }
            default:
                KindTile(kind: .command, symbol: "terminal", size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The new-script form: a title, mode, language and folder, written from a template.
private struct CreateScriptSheet: View {
    let model: LauncherModel
    let provider: ScriptCommandProvider
    let dismiss: () -> Void
    @State private var draft = ScriptTemplate.Draft()
    @State private var folderID: UUID?
    @State private var error: String?

    var body: some View {
        let folders = model.store.database.scriptDirectories.filter { $0.url != nil }
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Title", text: $draft.title, prompt: Text("Open Project"))
                Picker("Mode", selection: $draft.mode) {
                    ForEach(ScriptOutputMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if draft.mode == .inline {
                    TextField("Refresh every", text: $draft.refreshTime, prompt: Text("1m"))
                }
                Picker("Language", selection: $draft.language) {
                    ForEach(ScriptTemplate.Language.allCases) { Text($0.title).tag($0) }
                }
                TextField("Package", text: $draft.packageName, prompt: Text("Optional"))
                TextField("Icon", text: $draft.icon, prompt: Text("An emoji, optional"))
                TextField("Argument", text: $draft.argumentPlaceholder, prompt: Text("Placeholder, optional"))
                Toggle("Ask before running", isOn: $draft.needsConfirmation)
                Picker("Folder", selection: $folderID) {
                    ForEach(folders) { folder in
                        Text(folder.url?.lastPathComponent ?? "Folder").tag(Optional(folder.id))
                    }
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(OR.Color.danger)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || folderID == nil)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear { folderID = folderID ?? folders.first?.id }
    }

    private func create() {
        guard let folderID else { return }
        do {
            let url = try provider.createScript(draft, in: folderID, model: model)
            dismiss()
            if (try? SideEffectGuard.check("opening scripts in an editor")) != nil { NSWorkspace.shared.open(url) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
