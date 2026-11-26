import AppKit

// Slice 2 in the launcher: clipboard entries, snippets and quicklinks. Values for
// placeholders are read when an item runs, never while building rows.

/// What ↩ does on clipboard entries and snippets. ⌘↩ does the other.
enum ContentPrimaryAction: Sendable {
    case copy, paste
}

/// The kind of library item an import or export handles.
enum LibraryTransferKind: String, CaseIterable, Sendable {
    case snippets, quicklinks

    var title: String { self == .snippets ? "Snippets" : "Quicklinks" }
    var exportFileName: String { self == .snippets ? "OpenRay Snippets.json" : "OpenRay Quicklinks.json" }
}

/// Chooses files for import and export. The live version shows OpenRay's own open
/// and save panels; tests inject files directly.
@MainActor
protocol LibraryFileAccess {
    func chooseImportFile(for kind: LibraryTransferKind) -> URL?
    func chooseExportDestination(for kind: LibraryTransferKind) -> URL?
}

/// Open and save panels. They never appear in the test host, where nothing can answer them.
struct PanelLibraryFileAccess: LibraryFileAccess {
    func chooseImportFile(for kind: LibraryTransferKind) -> URL? {
        guard !SideEffectGuard.isTestHost else { return nil }
        let panel = NSOpenPanel()
        panel.title = "Import \(kind.title)"
        panel.message =
            kind == .snippets
            ? "Choose a snippet JSON export or a Text Replacements property list."
            : "Choose a quicklink JSON export."
        panel.allowedContentTypes = kind == .snippets ? [.json, .propertyList] : [.json]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseExportDestination(for kind: LibraryTransferKind) -> URL? {
        guard !SideEffectGuard.isTestHost else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = kind.exportFileName
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension LauncherModel {
    // MARK: Primary action

    /// What ↩ does on clipboard entries and snippets; ⌘↩ always does the other, so the
    /// two keys never do the same thing. This is the one plug-in point for Slice 1's
    /// preference: on merging, return `.paste` when `preferences.primaryActionPastes`
    /// is true. `primaryActionOverride` lets tests drive both modes.
    var contentPrimaryAction: ContentPrimaryAction { primaryActionOverride ?? .copy }

    /// ↩ on a clipboard entry or snippet.
    func performContent(_ item: LauncherItem) {
        contentPrimaryAction == .paste ? pasteContent(item) : copyContent(item)
    }

    /// ⌘↩ on a clipboard entry or snippet: the action ↩ doesn't do.
    func performSecondaryContent(_ item: LauncherItem) {
        contentPrimaryAction == .paste ? copyContent(item) : pasteContent(item)
    }

    /// Copies a clipboard entry or a rendered snippet.
    func copyContent(_ item: LauncherItem) {
        switch item.action {
        case .clipboard(let entry): if copy(entry) { store.recordUse(of: item.id) }
        case .snippet(let snippet): runSnippet(snippet, itemID: item.id, action: .copy)
        default: break
        }
    }

    /// Pastes a clipboard entry or a rendered snippet into the app you came from.
    func pasteContent(_ item: LauncherItem) {
        switch item.action {
        case .clipboard(let entry):
            finishPaste(copied: clipboard.copy(entry), label: entry.title)
            store.recordUse(of: item.id)
        case .snippet(let snippet): runSnippet(snippet, itemID: item.id, action: .paste)
        default: break
        }
    }

    // MARK: Placeholder values

    /// The values one run of `plan` needs, read now: the current clipboard through
    /// the capture privacy checks, history while capture is on, the selection in the
    /// app you came from when the plan uses it, snippets and the calculator.
    func placeholderValues(for plan: PlaceholderPlan) -> PlaceholderValues {
        let database = store.database
        // A quicklink sends the clipboard elsewhere, so a copy not yet attributed to an app counts as excluded.
        let strict = plan.context == .quicklink
        var values = PlaceholderValues.snapshot(library: database, requirements: plan.requirements) { [clipboard] in
            clipboard.placeholderText(unattributedIsExcluded: strict)
        }
        if !plan.requirements.snippets.isEmpty {
            values.snippets = Dictionary(
                database.snippets.map { ($0.name, $0.referenceSource()) }, uniquingKeysWith: { first, _ in first })
        }
        if plan.requirements.selection, clipboard.usesGeneralPasteboard || selectionReader != nil {
            values.selection = try? selectionReader?() ?? windows.selectedText(in: previousApplication)
        }
        return values
    }

    // MARK: Snippets

    /// The one plan for a snippet's fields, value conversion and rendering; nil for a
    /// snippet from before dynamic placeholders.
    func snippetPlan(_ snippet: Snippet) -> PlaceholderPlan? {
        snippet.dynamicTemplate?.plan(snippets: PlaceholderValues.snippetLookup(store.database))
    }

    /// Copies or pastes a snippet. One that needs a typed value runs as its command,
    /// whose fields ask for every argument (Slice 1); until those fields exist, the
    /// registry says which value is missing.
    func runSnippet(_ snippet: Snippet, itemID: String, action: ContentPrimaryAction) {
        guard let plan = snippetPlan(snippet) else {
            // Old snippets run exactly as they always did.
            deliver(snippet.legacyExpanded(), snippet: snippet, itemID: itemID, action: action)
            return
        }
        if plan.arguments.contains(where: \.isRequired),
            let command = registry.item(withID: LibraryCommandProvider.commandID(for: snippet, action: action), in: self)
        {
            perform(command)
            return
        }
        runSnippet(snippet, plan: plan, arguments: [:], itemID: itemID, action: action)
    }

    /// Runs a snippet with values by `ArgumentSpec.name`, as `ProvidedRef.arguments` carries them.
    func runSnippet(_ snippet: Snippet, arguments: [String: String], action: ContentPrimaryAction) {
        let itemID = "snippet.\(snippet.id)"
        guard let plan = snippetPlan(snippet) else {
            deliver(snippet.legacyExpanded(), snippet: snippet, itemID: itemID, action: action)
            return
        }
        runSnippet(snippet, plan: plan, arguments: arguments, itemID: itemID, action: action)
    }

    private func deliver(_ text: String, snippet: Snippet, itemID: String, action: ContentPrimaryAction) {
        switch action {
        case .copy: if copy(text, label: snippet.name) { store.recordUse(of: itemID) }
        case .paste: paste(text, label: snippet.name)
        }
    }

    private func runSnippet(
        _ snippet: Snippet, plan: PlaceholderPlan, arguments: [String: String], itemID: String, action: ContentPrimaryAction
    ) {
        // Nothing is read for a snippet that can't run.
        if let issue = plan.blockingIssues.first {
            feedback = .warning(issue.message)
            return
        }
        var values: PlaceholderValues
        do {
            let resolved = try plan.resolveArguments(arguments)
            values = placeholderValues(for: plan)
            values.arguments = resolved
        } catch {
            feedback = .warning(error.localizedDescription)
            return
        }
        let rendering = plan.render(values)
        if let issue = rendering.blockingIssues.first {
            feedback = .warning(issue.message)
            return
        }
        deliver(rendering.text, snippet: snippet, itemID: itemID, action: action)
    }

    // MARK: Quicklinks

    /// The one plan for a quicklink's fields, value conversion and rendering.
    func quicklinkPlan(_ link: Quicklink) -> PlaceholderPlan {
        link.plan(snippets: PlaceholderValues.snippetLookup(store.database))
    }

    /// Opens a quicklink with values by `ArgumentSpec.name`, as `ProvidedRef.arguments` carries them.
    @discardableResult
    func openQuicklink(_ link: Quicklink, arguments: [String: String]) -> Task<Void, Never>? {
        openQuicklink(link) { try link.resolution(arguments: arguments, values: $0) }
    }

    /// The editor's Test: opens exactly the URL its preview shows, which reads nothing
    /// live, in the draft's Open With app, through the guarded opener. Nothing is
    /// recorded and the editor stays open.
    @discardableResult
    func testQuicklink(_ url: URL, openWith: QuicklinkApplication?) -> Task<Void, Never> {
        let application = openWith.flatMap { applicationResolver.application(bundleIdentifier: $0.bundleIdentifier) }
        if let openWith, application == nil { toast("\(openWith.name) isn't installed. Opening in the default app.") }
        let opener = quicklinkOpener
        return Task { [weak self] in
            do { try await opener.open(url, with: application) } catch {
                self?.feedback = .error("Couldn't open the link. \(error.localizedDescription)")
            }
        }
    }

    /// Resolves the link with the values its placeholders need right now, then opens it
    /// in its Open With app or the default one, through the guarded opener.
    func openQuicklink(_ link: Quicklink, resolve: (PlaceholderValues) throws -> QuicklinkResolution)
        -> Task<Void, Never>?
    {
        let plan = quicklinkPlan(link)
        if let issue = plan.blockingIssues.first {
            feedback = .error(issue.message)
            return nil
        }
        let resolution: QuicklinkResolution
        do { resolution = try resolve(placeholderValues(for: plan)) } catch {
            feedback = .error(error.localizedDescription)
            return nil
        }
        var application: ResolvedApplication?
        if let preferred = link.openWith {
            application = applicationResolver.application(bundleIdentifier: preferred.bundleIdentifier)
            if application == nil { toast("\(preferred.name) isn't installed. Opening in the default app.") }
        }
        let opener = quicklinkOpener
        let itemID = "quicklink.\(link.id)"
        return Task { [weak self] in
            do {
                try await opener.open(resolution.url, with: application)
                self?.store.recordUse(of: itemID)
                self?.panel?.dismiss(restoreFocus: false)
            } catch {
                self?.feedback = .error("Couldn't open “\(link.name.truncatedForFeedback)”. \(error.localizedDescription)")
            }
        }
    }

    /// Links that need several values run as their command, which asks for each one.
    func quicklinkCommand(for link: Quicklink) -> LauncherItem? {
        registry.item(withID: LibraryCommandProvider.commandID(for: link), in: self)
    }

    /// ↩ on a quicklink row. A link with one field takes the typed term (a blank term
    /// takes its default); a link with more runs as its command, with the term in the first field.
    func performQuicklink(_ link: Quicklink, argument: String) {
        let fields = quicklinkPlan(link).arguments
        if fields.count > 1, var command = quicklinkCommand(for: link) {
            if !argument.isEmpty, case .provided(var ref) = command.action {
                ref.arguments[fields[0].id.specName] = argument
                command.action = .provided(ref)
            }
            perform(command)
        } else if fields.count == 1, argument.isEmpty, argumentLink?.id != link.id {
            beginArgument(link)
        } else {
            openQuicklink(link, query: argument)
        }
    }

    /// ↩ does nothing on a blank argument row only when the link's field is required.
    func quicklinkArgumentIsRequired(_ link: Quicklink) -> Bool {
        quicklinkPlan(link).arguments.first?.isRequired ?? false
    }

    // MARK: Clipboard

    /// Paste As: every format the entry has, under one entry that pastes plain text.
    /// The action panel shows the parent until it draws submenus.
    func pasteAsActions(for item: LauncherItem, entry: ClipboardEntry) -> [ActionEntry] {
        let formats = ClipboardPayload.formats(for: entry).filter { $0 != .original }
        guard formats.contains(.plainText) else { return [] }
        let children = ClipboardPayload.formats(for: entry).map { format in
            ActionEntry(id: "pasteAs.\(format.rawValue)", title: format.title, symbol: "doc.on.clipboard", group: .item) {
                [weak self] in self?.paste(entry, as: format, itemID: item.id)
            }
        }
        var parent = ActionEntry(
            id: "pasteAs", title: ClipboardPasteFormat.plainText.title, symbol: "doc.plaintext", group: .item
        ) { [weak self] in self?.paste(entry, as: .plainText, itemID: item.id) }
        parent.section = "Paste As"
        parent.children = children
        return [parent]
    }

    func paste(_ entry: ClipboardEntry, as format: ClipboardPasteFormat, itemID: String) {
        finishPaste(copied: clipboard.copy(entry, as: format), label: entry.title)
        store.recordUse(of: itemID)
    }

    /// Save as Snippet, Copy Text from Image and Copy Text from QR Code.
    func clipboardEntryActions(for item: LauncherItem, entry: ClipboardEntry) -> [ActionEntry] {
        var entries = pasteAsActions(for: item, entry: entry)
        if let text = entry.plainText {
            entries.append(
                ActionEntry(id: "saveAsSnippet", title: "Save as Snippet", symbol: "curlybraces", group: .item) {
                    [weak self] in self?.saveAsSnippet(text, title: entry.title)
                })
        }
        if entry.image != nil {
            entries.append(
                ActionEntry(id: "copyImageText", title: "Copy Text from Image", symbol: "text.viewfinder", group: .item) {
                    [weak self] in self?.copyRecognizedText(of: entry)
                })
            entries.append(
                ActionEntry(id: "copyQRCode", title: "Copy Text from QR Code", symbol: "qrcode.viewfinder", group: .item) {
                    [weak self] in self?.copyBarcode(of: entry)
                })
        }
        return entries
    }

    /// Opens a new snippet with the text, for a name and keyword before saving. Copied
    /// text is literal: anything in it that looks like a placeholder is escaped, so the
    /// snippet pastes exactly what was copied and never reads private values.
    func saveAsSnippet(_ text: String, title: String) {
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let content = PlaceholderParser.escaping(text, context: .snippet) { _ in false }
        editor = .snippet(Snippet(name: name.isEmpty ? "Clipboard Text" : name, keyword: "", content: content))
    }

    @discardableResult
    func copyRecognizedText(of entry: ClipboardEntry) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            if let text = entry.recognizedText, !text.isEmpty {
                copy(text, label: "Text from image")
                return
            }
            feedback = .working("Finding text…")
            switch await clipboard.recognizedText(of: entry) {
            case .some(let text): copy(text, label: "Text from image")
            case .none: feedback = .info("No text was found in this image.")
            }
        }
    }

    @discardableResult
    func copyBarcode(of entry: ClipboardEntry) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            if let payload = await clipboard.barcodePayloads(of: entry).first {
                copy(payload, label: "QR code")
            } else {
                feedback = .info("No QR code was found in this image.")
            }
        }
    }

    // MARK: Import and export

    /// Plans an import of `data` without changing the library, for a preview.
    func planImport(_ data: Data, fileName: String?, kind: LibraryTransferKind, policy: ImportKeywordConflictPolicy)
        throws -> LibraryImportPreview
    {
        let database = store.database
        switch kind {
        case .snippets:
            let file = try LibraryImport.snippets(from: data, fileName: fileName)
            // Keywords can't match an alias or a quicklink keyword: those import without one.
            let reserved = Set(
                (database.commandBindings.map(\.alias) + database.quicklinks.map(\.keyword))
                    .compactMap(CommandBinding.normalizedAlias))
            let plan = LibraryImport.plan(
                snippets: file.items, existing: database.snippets, policy: policy, maximumTextLength: Snippet.maximumLength,
                isValidKeyword: { keyword in
                    keyword.count >= 2 && SnippetKeywordRules.isValid(keyword)
                        && !reserved.contains(CommandBinding.normalizedAlias(keyword) ?? keyword)
                })
            return .snippets(plan, unreadable: file.invalidCount)
        case .quicklinks:
            let file = try LibraryImport.quicklinks(from: data, fileName: fileName)
            return .quicklinks(LibraryImport.plan(quicklinks: file.items, existing: database.quicklinks), unreadable: file.invalidCount)
        }
    }

    /// Imports in one save, and reports what happened. False, with the reason shown, on failure.
    @discardableResult
    func importLibrary(
        _ data: Data, fileName: String?, kind: LibraryTransferKind, policy: ImportKeywordConflictPolicy = .dropKeyword
    ) -> Bool {
        let preview: LibraryImportPreview
        do { preview = try planImport(data, fileName: fileName, kind: kind, policy: policy) } catch {
            feedback = .error(error.localizedDescription)
            return false
        }
        let resolveApplication = { (imported: ImportedQuicklink) in self.importedApplication(imported) }
        let saved = store.update { database in
            switch preview {
            case .snippets(let plan, _):
                database.snippets += plan.additions.map {
                    Snippet(name: $0.name, keyword: $0.keyword ?? "", content: $0.text)
                }
                for replacement in plan.replacements {
                    guard let index = database.snippets.firstIndex(where: { $0.id == replacement.existingID }) else { continue }
                    database.snippets[index].name = replacement.snippet.name
                    database.snippets[index].content = replacement.snippet.text
                }
            case .quicklinks(let plan, _):
                database.quicklinks += plan.additions.map { imported in
                    Quicklink(name: imported.name, template: imported.link, keyword: "", openWith: resolveApplication(imported))
                }
            }
        }
        guard saved else {
            feedback = .error(store.errorMessage ?? "The import couldn't be saved. Your library is unchanged.")
            return false
        }
        toast("Imported \(kind.title.lowercased()): \(preview.summary)")
        return true
    }

    func exportLibrary(_ kind: LibraryTransferKind) throws -> Data {
        let database = store.database
        switch kind {
        case .snippets: return try LibraryImport.exportSnippets(database.snippets.map(ImportedSnippet.init))
        case .quicklinks: return try LibraryImport.exportQuicklinks(database.quicklinks.map { ImportedQuicklink($0) })
        }
    }

    /// Writes an export, never over the library itself or its clipboard data, whatever
    /// the path, link or letter case that leads there.
    func exportLibrary(_ kind: LibraryTransferKind, to url: URL) throws {
        guard !isLibraryData(url) else {
            throw LibraryValidationError("Choose another file. Exporting there would replace your library.")
        }
        try exportLibrary(kind).write(to: url, options: .atomic)
    }

    /// True for `library.json`, a link to it, the same file by another name, or anything
    /// in the clipboard data folder. That folder sits beside the library's configured
    /// path, which is the one the store uses even when `library.json` is a link, and
    /// beside the file the link points to; both are resolved on their own.
    func isLibraryData(_ url: URL) -> Bool {
        guard let library = store.fileURL else { return false }
        let destination = url.standardizedFileURL.resolvingSymlinksInPath()
        let source = library.standardizedFileURL.resolvingSymlinksInPath()
        if destination.path.lowercased() == source.path.lowercased() { return true }
        let dataFolders = [library.standardizedFileURL.deletingLastPathComponent(), source.deletingLastPathComponent()].map {
            $0.appending(path: "ClipboardImages").resolvingSymlinksInPath().path.lowercased() + "/"
        }
        if dataFolders.contains(where: destination.path.lowercased().hasPrefix) { return true }
        // Hard links and other names for the same file.
        if let a = try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
            let b = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        {
            return a.isEqual(b)
        }
        return false
    }

    /// An imported link's Open With app. OpenRay's own exports carry the bundle
    /// identifier, kept even if that app isn't installed right now. A name, as other
    /// launchers export, is matched against installed apps, nested bundles included.
    func importedApplication(_ imported: ImportedQuicklink) -> QuicklinkApplication? {
        if let identifier = imported.openWithBundleIdentifier, QuicklinkOpenWith.isBundleIdentifier(identifier) {
            return applicationResolver.application(bundleIdentifier: identifier)?.quicklinkApplication
                ?? QuicklinkApplication(bundleIdentifier: identifier, name: imported.openWith ?? identifier)
        }
        guard let value = imported.openWith else { return nil }
        if let app = applications.applications.first(where: {
            $0.name.caseInsensitiveCompare(value) == .orderedSame || $0.bundleIdentifier == value
        }), let identifier = app.bundleIdentifier {
            return QuicklinkApplication(bundleIdentifier: identifier, name: app.name)
        }
        return QuicklinkOpenWith.resolve(value, using: applicationResolver)?.quicklinkApplication
    }

    /// Asks for a file, then imports it. `.rayconfig` archives are refused before reading.
    func runImport(_ kind: LibraryTransferKind, files: any LibraryFileAccess) {
        guard let url = files.chooseImportFile(for: kind) else { return }
        do {
            try LibraryImport.checkFileName(url.lastPathComponent)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= LibraryImport.maximumBytes else { throw LibraryImportError.fileTooLarge }
            importLibrary(try Data(contentsOf: url), fileName: url.lastPathComponent, kind: kind)
        } catch {
            feedback = .error(error.localizedDescription)
        }
    }

    func runExport(_ kind: LibraryTransferKind, files: any LibraryFileAccess) {
        guard let url = files.chooseExportDestination(for: kind) else { return }
        do {
            try exportLibrary(kind, to: url)
            toast("Exported \(kind.title.lowercased()) to \(url.lastPathComponent)")
        } catch {
            feedback = .error(error.localizedDescription)
        }
    }
}

/// What an import would do, shown before or after it runs.
enum LibraryImportPreview: Equatable, Sendable {
    case snippets(SnippetImportPlan, unreadable: Int)
    case quicklinks(QuicklinkImportPlan, unreadable: Int)

    var summary: String {
        switch self {
        case .snippets(let plan, let unreadable): plan.summary + Self.unreadableNote(unreadable)
        case .quicklinks(let plan, let unreadable): plan.summary + Self.unreadableNote(unreadable)
        }
    }

    private static func unreadableNote(_ count: Int) -> String {
        count == 0 ? "" : ", \(count) unreadable"
    }
}
