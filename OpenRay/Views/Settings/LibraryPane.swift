import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsPane {
    static let library = SettingsPane(
        id: "library", title: "Library",
        subtitle: "Your notes, snippets, quicklinks and history, stored on this Mac.",
        kind: .system, symbol: "books.vertical",
        keywords: "reveal finder export import data location backup json snippets quicklinks text replacements"
    ) { model, _ in AnyView(LibraryPane(model: model)) }
}

struct LibraryPane: View {
    let model: LauncherModel

    var body: some View {
        let database = model.store.database
        SettingsPaneScaffold(pane: .library) {
            Section("Contents") {
                LabeledContent("Notes", value: database.notes.count.formatted())
                LabeledContent("Snippets", value: database.snippets.count.formatted())
                LabeledContent("Quicklinks", value: database.quicklinks.count.formatted())
                LabeledContent("Favorites", value: database.favoriteIDs.count.formatted())
                LabeledContent("Clipboard entries", value: database.clipboard.count.formatted())
            }
            LibraryArchiveSections(model: model)
            Section {
                if let url = model.store.fileURL {
                    LabeledContent {
                        HStack {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .disabled(!FileManager.default.fileExists(atPath: url.path))
                        }
                    } label: {
                        SettingRowLabel(title: "Location", detail: LauncherModel.shortenedPath(url.deletingLastPathComponent()))
                    }
                } else {
                    Label("This instance uses a temporary, in-memory library.", systemImage: "memorychip")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Data")
            } footer: {
                Text("library.json and the ClipboardImages folder are readable only by your account, but OpenRay doesn't encrypt them. Export Archive saves both in one file, and can encrypt it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Archives and backups (Slice 8)

/// Export and import, in one place: whole-library archives, and snippets and quicklinks as
/// plain JSON (Raycast's documented export format) or Text Replacements (Slice 2's importers).
/// Then scheduled backups.
struct LibraryArchiveSections: View {
    let model: LauncherModel
    @State private var showsExport = false
    @State private var pendingImport: PendingArchive?
    @State private var alert: ArchiveAlert?

    private var scheduler: LibraryBackupScheduler? {
        (model.registry.provider(id: LibraryArchiveProvider.registration.id) as? LibraryArchiveProvider)?
            .scheduler(for: model)
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    Button("Export Archive…") { showsExport = true }
                        .sheet(isPresented: $showsExport) {
                            ExportArchiveSheet(model: model) { result in
                                showsExport = false
                                if let result { alert = result }
                            }
                        }
                    Button("Import Archive…") { chooseImport() }
                        .disabled(model.store.isReadOnly)
                        .sheet(item: $pendingImport) { pending in
                            ImportArchiveSheet(model: model, pending: pending) { result in
                                pendingImport = nil
                                if let result { alert = result }
                            }
                        }
                }
            } label: {
                SettingRowLabel(
                    title: "Archive",
                    detail: "One file with your library and clipboard images. Choose what goes in, and optionally encrypt it with a passphrase.")
            }
            .alert(item: $alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
            ForEach(LibraryTransferKind.allCases, id: \.self) { kind in
                LabeledContent {
                    HStack {
                        Button("Import…") { transfer(kind, importing: true) }
                            .accessibilityIdentifier("settings.import.\(kind.rawValue)")
                        Button("Export…") { transfer(kind, importing: false) }
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
            Text("Export and Import")
        } footer: {
            Text("Archive imports let you pick categories and merge them with what's here, or replace them; script folders arrive turned off. Snippet and quicklink imports skip duplicates and drop keywords that are already taken. Encrypted settings files from other apps can't be imported.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if let scheduler {
            BackupSection(model: model, scheduler: scheduler, settings: scheduler.settings) { alert = $0 }
        }
    }

    /// Slice 2's snippet and quicklink import and export. Its result, which it reports in the
    /// launcher's action bar, is shown here too.
    private func transfer(_ kind: LibraryTransferKind, importing: Bool) {
        model.feedback = nil
        if importing { model.runImport(kind, files: PanelLibraryFileAccess()) } else { model.runExport(kind, files: PanelLibraryFileAccess()) }
        guard let feedback = model.feedback else { return }
        let verb = importing ? "Import" : "Export"
        alert = ArchiveAlert(
            title: feedback.style == .error || feedback.style == .warning ? "The \(verb) Didn't Finish" : "\(verb) Finished",
            message: feedback.text)
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: LibraryArchive.fileExtension) { panel.allowedContentTypes = [type] }
        panel.message = "Choose an OpenRay archive to import."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Reading and checking every file's digest can take a moment for a large archive.
        Task {
            do {
                let opened = try await Task.detached(priority: .userInitiated) { () -> (Data, LibraryArchive.Contents?) in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= 2 * 1024 * 1024 * 1024 else { throw LibraryArchive.Failure("That archive is too large to import.") }
                    let data = try Data(contentsOf: url)
                    return (data, try LibraryArchive.isEncrypted(data) ? nil : try LibraryArchive.read(data))
                }.value
                pendingImport = PendingArchive(name: url.lastPathComponent, data: opened.0, contents: opened.1)
            } catch {
                alert = ArchiveAlert(title: "Couldn't Open the Archive", message: error.localizedDescription)
            }
        }
    }
}

struct ArchiveAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct PendingArchive: Identifiable {
    let id = UUID()
    var name: String
    var data: Data
    /// Nil until an encrypted archive's passphrase opens it.
    var contents: LibraryArchive.Contents?
}

/// Scheduled backups: on or off, the folder, how often and how many to keep.
private struct BackupSection: View {
    let model: LauncherModel
    let scheduler: LibraryBackupScheduler
    let settings: LibraryBackupSettingsStore
    let report: (ArchiveAlert) -> Void

    var body: some View {
        let current = settings.settings
        Section {
            Toggle(isOn: Binding(get: { current.isEnabled }, set: { value in settings.update { $0.isEnabled = value } })) {
                SettingRowLabel(title: "Back up automatically", detail: "While OpenRay is running.")
            }
            .settingsSwitch()
            .disabled(current.folder == nil && !current.isEnabled)
            LabeledContent {
                HStack {
                    Button("Choose…") { chooseFolder() }
                    if let folder = current.folder {
                        Button("Show") {
                            if (try? SideEffectGuard.check("revealing files in Finder")) != nil {
                                NSWorkspace.shared.activateFileViewerSelecting([folder])
                            }
                        }
                    }
                }
            } label: {
                SettingRowLabel(
                    title: "Folder",
                    detail: current.folder.map(LauncherModel.shortenedPath) ?? "Choose a folder, such as one in iCloud Drive")
            }
            Picker("How often", selection: Binding(get: { current.frequency }, set: { value in settings.update { $0.frequency = value } })) {
                ForEach(LibraryBackupSettings.Frequency.allCases) { Text($0.title).tag($0) }
            }
            .neutralMenus()
            Stepper(
                "Keep the last \(current.keep) backup\(current.keep == 1 ? "" : "s")",
                value: Binding(get: { current.keep }, set: { value in settings.update { $0.keep = value } }),
                in: LibraryBackupSettings.keepRange)
            LabeledContent {
                Button(scheduler.isBackingUp ? "Backing Up…" : "Back Up Now") { backUpNow() }
                    .disabled(current.folder == nil || scheduler.isBackingUp)
            } label: {
                SettingRowLabel(
                    title: "Last backup", detail: [lastBackup(current), current.lastNote].compactMap { $0 }.joined(separator: " "))
            }
        } header: {
            Text("Backups")
        } footer: {
            Text("Backups hold everything, unencrypted, as archives you can import. Older backups this Mac made beyond the number kept are deleted; other files in the folder, and other Macs' backups, are left alone.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func lastBackup(_ settings: LibraryBackupSettings) -> String {
        if let error = settings.lastError { return "The last backup failed: \(error)" }
        guard let date = settings.lastBackupAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = !SideEffectGuard.isInert
        panel.prompt = "Choose"
        panel.message = "Choose where OpenRay keeps backups."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.update { $0.folderPath = url.standardizedFileURL.path }
    }

    private func backUpNow() {
        Task {
            do {
                let url = try await scheduler.backUpNow()
                report(ArchiveAlert(title: "Backed Up", message: "Saved \(url.lastPathComponent)."))
            } catch {
                report(ArchiveAlert(title: "The Backup Failed", message: error.localizedDescription))
            }
        }
    }
}

/// Choose categories and an optional passphrase, then where to save.
private struct ExportArchiveSheet: View {
    let model: LauncherModel
    let finish: (ArchiveAlert?) -> Void
    @State private var categories = Set(LibraryArchive.exportableCategories)
    @State private var encrypts = false
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Include") {
                    ForEach(LibraryArchive.exportableCategories) { category in
                        Toggle(isOn: binding(category)) {
                            Label {
                                SettingRowLabel(title: title(category), detail: category.detail)
                            } icon: {
                                Image(systemName: category.symbol)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Encrypt with a passphrase", isOn: $encrypts)
                    if encrypts {
                        SecureField("Passphrase", text: $passphrase)
                        SecureField("Confirm passphrase", text: $confirmation)
                    }
                } footer: {
                    Text(encrypts ? passphraseHint : "Anyone with the file can read an unencrypted archive.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(categories.isEmpty || isWorking || (encrypts && !passphraseIsUsable))
            }
            .padding()
        }
        .frame(width: 520, height: 600)
    }

    private var passphraseIsUsable: Bool { passphrase.count >= 8 && passphrase == confirmation }

    private var passphraseHint: String {
        if passphrase.count < 8 { return "Use at least 8 characters. OpenRay can't recover a forgotten passphrase." }
        if passphrase != confirmation { return "The passphrases don't match." }
        return "The archive is encrypted with AES-256-GCM. OpenRay can't recover a forgotten passphrase."
    }

    private func title(_ category: LibraryArchiveCategory) -> String {
        guard let count = LibraryArchive.count(of: category, in: model.store.database) else { return category.title }
        return "\(category.title) (\(count.formatted()))"
    }

    private func binding(_ category: LibraryArchiveCategory) -> Binding<Bool> {
        Binding(
            get: { categories.contains(category) },
            set: { if $0 { categories.insert(category) } else { categories.remove(category) } })
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OpenRay Library.\(LibraryArchive.fileExtension)"
        if let type = UTType(filenameExtension: LibraryArchive.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isWorking = true
        let chosen = categories
        let secret = encrypts ? passphrase : nil
        Task {
            defer { isWorking = false }
            do {
                try InertWrites.check(destination.deletingLastPathComponent(), what: "exporting archives")
                let built = try await model.store.makeArchive(categories: chosen, passphrase: secret)
                try built.data.write(to: destination, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let left = built.omissions.isEmpty ? "" : " " + built.omissions.joined(separator: " ")
                finish(ArchiveAlert(title: "Exported", message: "Saved \(destination.lastPathComponent).\(left)"))
            } catch {
                finish(ArchiveAlert(title: "The Export Failed", message: error.localizedDescription))
            }
        }
    }
}

/// Unlock (when encrypted), preview, pick categories and merge or replace.
private struct ImportArchiveSheet: View {
    let model: LauncherModel
    @State var pending: PendingArchive
    let finish: (ArchiveAlert?) -> Void
    @State private var passphrase = ""
    @State private var unlockError: String?
    @State private var categories: Set<LibraryArchiveCategory> = []
    @State private var mode: LibraryImportMode = .merge
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if let contents = pending.contents {
                    Section {
                        ForEach(LibraryArchive.preview(contents, current: model.store.database)) { row in
                            Toggle(isOn: binding(row.category)) {
                                Label {
                                    SettingRowLabel(title: row.category.title, detail: detail(row))
                                } icon: {
                                    Image(systemName: row.category.symbol)
                                }
                            }
                        }
                    } header: {
                        Text("\(pending.name) · \(contents.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Section {
                        Picker("Import", selection: $mode) {
                            ForEach(LibraryImportMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(
                            mode == .merge
                                ? "Adds what's new. Items that are in both are updated from the archive; settings are taken from it."
                                : "The chosen categories become exactly what the archive has. Everything else stays as it is.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        SecureField("Passphrase", text: $passphrase).onSubmit { unlock() }
                        if let unlockError {
                            Text(unlockError).font(.system(size: 12)).foregroundStyle(OR.Color.danger)
                        }
                    } header: {
                        Text("\(pending.name) is encrypted")
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }.keyboardShortcut(.cancelAction)
                if pending.contents == nil {
                    Button("Unlock") { unlock() }.keyboardShortcut(.defaultAction).disabled(passphrase.isEmpty || isWorking)
                } else {
                    Button(mode == .merge ? "Import" : "Replace") { importArchive() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(categories.isEmpty || isWorking)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear { if let contents = pending.contents { categories = contents.categories } }
    }

    private func detail(_ row: LibraryArchive.CategoryPreview) -> String {
        if row.category == .scripts, let contents = pending.contents {
            let paths = contents.database.scriptDirectories.map(\.path).filter { !$0.isEmpty }
            return "\(paths.count) folder\(paths.count == 1 ? "" : "s"), added turned off: " + paths.joined(separator: ", ")
        }
        var parts: [String] = []
        if let archived = row.archived, let current = row.current {
            parts.append("\(archived.formatted()) in the archive, \(current.formatted()) here")
        } else {
            parts.append(row.category.detail)
        }
        if row.files > 0 { parts.append("\(row.files) file\(row.files == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func binding(_ category: LibraryArchiveCategory) -> Binding<Bool> {
        Binding(
            get: { categories.contains(category) },
            set: { if $0 { categories.insert(category) } else { categories.remove(category) } })
    }

    private func unlock() {
        guard !passphrase.isEmpty else { return }
        isWorking = true
        let data = pending.data
        let secret = passphrase
        Task {
            defer { isWorking = false }
            do {
                let contents = try await Task.detached { try LibraryArchive.read(data, passphrase: secret) }.value
                pending.contents = contents
                categories = contents.categories
                unlockError = nil
            } catch {
                unlockError = error.localizedDescription
            }
        }
    }

    private func importArchive() {
        guard let contents = pending.contents else { return }
        do {
            let report = try model.store.importArchive(contents, categories: categories, mode: mode)
            model.applyPreferences()
            var message = "Imported \(report.categories.count) categor\(report.categories.count == 1 ? "y" : "ies")."
            if !report.notes.isEmpty { message += " " + report.notes.joined(separator: " ") }
            if report.categories.contains(.otherData) { message += " Some data appears after OpenRay restarts." }
            finish(ArchiveAlert(title: "Imported", message: message))
        } catch {
            finish(ArchiveAlert(title: "The Import Failed", message: error.localizedDescription))
        }
    }
}
