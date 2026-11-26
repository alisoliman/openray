import AppKit
import SwiftUI

// Slice 4's part of the launcher: settings access, path browsing, the Files scope's ranking
// and groups, and the ⌘K entries for file and application rows. The shared launcher files
// call into here with one-line hooks, so this file holds the behavior.

extension LauncherModel {
    // MARK: - Wiring

    /// Called once from `init`: points the file search and the app catalog at Settings, and
    /// starts Auto Quit and the screenshot watcher (both inert in tests and verification).
    func connectFilesAndApplications() {
        files.options = { [weak self] in self?.filesSettings.options ?? FileSearchOptions() }
        applications.configuration = { [weak self] in
            self?.applicationSettings.scanConfiguration ?? ApplicationScanConfiguration()
        }
        applicationsProvider?.attach(to: self)
        screenshotsProvider?.attach(to: self)
    }

    var filesProvider: FilesCommandProvider? {
        registry.provider(id: FilesCommandProvider.registration.id) as? FilesCommandProvider
    }

    var applicationsProvider: ApplicationsCommandProvider? {
        registry.provider(id: ApplicationsCommandProvider.registration.id) as? ApplicationsCommandProvider
    }

    var screenshotsProvider: ScreenshotsCommandProvider? {
        registry.provider(id: ScreenshotsCommandProvider.registration.id) as? ScreenshotsCommandProvider
    }

    var filesSettings: FilesSettings { FilesSettings(store.database.commandPreferences[FilesSettings.key]) }
    var applicationSettings: ApplicationSettings {
        ApplicationSettings(store.database.commandPreferences[ApplicationSettings.key])
    }
    var screenshotSettings: ScreenshotSettings {
        ScreenshotSettings(store.database.commandPreferences[ScreenshotSettings.key])
    }

    @discardableResult
    func updateFilesSettings(_ change: (inout FilesSettings) -> Void) -> Bool {
        var settings = filesSettings
        change(&settings)
        let saved = savePreferences(settings.values, key: FilesSettings.key)
        // The current search follows the new settings.
        if saved, destination == .search {
            files.invalidateListing()
            resumeSearch()
        }
        return saved
    }

    @discardableResult
    func updateApplicationSettings(_ change: (inout ApplicationSettings) -> Void) -> Bool {
        let before = applicationSettings
        var settings = before
        change(&settings)
        let saved = savePreferences(settings.values, key: ApplicationSettings.key)
        if saved, settings.scanConfiguration != before.scanConfiguration {
            Task { await applications.refresh() }
        }
        return saved
    }

    @discardableResult
    func updateScreenshotSettings(_ change: (inout ScreenshotSettings) -> Void) -> Bool {
        let before = screenshotSettings
        var settings = before
        change(&settings)
        let saved = savePreferences(settings.values, key: ScreenshotSettings.key)
        if saved, let index = screenshotsProvider?.index {
            if settings.extraFolders != before.extraFolders || settings.includesAllImages != before.includesAllImages
                || settings.watchesDesktop != before.watchesDesktop || settings.retentionDays != before.retentionDays
            {
                index.startWatching()
                Task { await index.refresh() }
            }
            if settings.accurateRecognition != before.accurateRecognition, settings.recognizesText {
                Task { await index.reindex() }
            } else if settings.recognizesText != before.recognizesText {
                if settings.recognizesText {
                    index.recognizePending(accurate: settings.accurateRecognition)
                } else {
                    index.stopRecognition()
                }
            }
        }
        return saved
    }

    func setScreenshotColumns(_ columns: Int) {
        let clamped = min(max(columns, ScreenshotSettings.columnRange.lowerBound), ScreenshotSettings.columnRange.upperBound)
        updateScreenshotSettings { $0.columns = clamped }
    }

    private func savePreferences(_ values: [String: String], key: String) -> Bool {
        let saved = store.update { $0.commandPreferences[key] = values.isEmpty ? nil : values }
        if !saved { feedback = .error(store.errorMessage ?? "Settings couldn't be saved.") }
        return saved
    }

    // MARK: - Files results

    /// The typed path, when the query browses folders in Everything or Files.
    var filePathQuery: FilePathQuery? {
        guard destination == .search, argumentLink == nil, section == .home || section == .files else { return nil }
        return FilePathQuery.parse(query, home: files.home)
    }

    /// Rows Files answers on its own, in its own order: always in the Files scope, and in
    /// Everything for a typed path or a `content:` search. Nil leaves results to the launcher.
    var fileSearchRows: [LauncherItem]? {
        guard destination == .search, argumentLink == nil, query.count <= 512 else { return nil }
        // A global alias wins everywhere, Files included, as `results` resolves it first.
        if let target = store.database.aliasTarget(for: query), bindableCommands.contains(where: { $0.id == target }) {
            return nil
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = filesSettings
        let excluded = settings.excludedPaths
        func isExcluded(_ url: URL) -> Bool {
            guard !excluded.isEmpty else { return false }
            // Listings can report /private/var for /var; the standardized path is what's saved.
            let path = url.standardizedFileURL.path
            return excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        if let path = filePathQuery {
            guard files.browsedFolder == path.directory else { return path.filter.isEmpty ? [folderRow(path.directory)] : [] }
            let rows = files.orderedListing(filter: path.filter, sort: settings.sort).lazy.filter { !isExcluded($0.url) }
                .prefix(100).map(fileRow)
            return Array(((path.filter.isEmpty ? [folderRow(path.directory)] : []) + rows).prefix(100))
        }
        let parsed = FileQuery.parse(trimmed)
        guard section == .files || section == .home && parsed.hasFilters else { return nil }
        // A folder listing still on screen belongs to the path just erased.
        guard files.browsedFolder == nil else { return [] }
        let results = files.results.filter { !isExcluded($0.url) }
        return Array(Self.rankedFileResults(results, query: parsed, sort: settings.sort).prefix(100).map(fileRow))
    }

    /// Name matches first, by how well they match, then files found only by their contents.
    /// A chosen sort order replaces relevance; an empty search keeps Spotlight's newest-first.
    nonisolated static func rankedFileResults(
        _ results: [FileSearchResult], query: FileQuery, sort: FileSortOrder
    ) -> [FileSearchResult] {
        let name = query.nameText
        var scored: [(result: FileSearchResult, score: Int, order: Int)] = []
        for (order, result) in results.enumerated() {
            if name.isEmpty {
                scored.append((result, 0, order))
            } else if let score = SearchMatcher.score(name, in: result.name) {
                scored.append((result, score + 100, order))
            } else if result.matchedContent {
                scored.append((result, 0, order))
            }
        }
        scored.sort { lhs, rhs in
            switch sort {
            case .relevance:
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.order < rhs.order
            case .dateModified:
                let left = lhs.result.modifiedAt ?? .distantPast
                let right = rhs.result.modifiedAt ?? .distantPast
                return left != right ? left > right : lhs.order < rhs.order
            case .name:
                let comparison = lhs.result.name.localizedStandardCompare(rhs.result.name)
                return comparison == .orderedSame ? lhs.order < rhs.order : comparison == .orderedAscending
            }
        }
        return scored.map(\.result)
    }

    /// Groups for `fileSearchRows`: the browsed folder, the Files scope, or a contents search.
    var fileSearchGroups: [LauncherResultGroup]? {
        guard let rows = fileSearchRows else { return nil }
        let sort = filesSettings.sort
        let sortNote = sort == .relevance ? nil : "By \(sort.title.lowercased()) · ⇧⌘P"
        if let path = filePathQuery {
            let loading = files.isSearching
            return [
                LauncherResultGroup(
                    id: "files.path", title: FilePathQuery.text(for: path.directory, home: files.home),
                    trailing: loading ? "Listing…" : sortNote, isLoading: loading && rows.isEmpty, items: rows)
            ].filter { !$0.items.isEmpty || $0.isLoading }
        }
        if section == .files {
            return [
                LauncherResultGroup(
                    id: "files", title: isQueryBlank ? "Recent in \(fileScope.title)" : nil, trailing: sortNote,
                    items: rows)
            ].filter { !$0.items.isEmpty }
        }
        let terms = FileQuery.parse(query).contentTerms.joined(separator: " ")
        let searching = files.isSearching
        return [
            LauncherResultGroup(
                id: "files", title: "Files containing “\(terms.truncatedForFeedback)”",
                trailing: searching ? "Searching contents" : sortNote, isLoading: searching, items: rows)
        ].filter { !$0.items.isEmpty || $0.isLoading }
    }

    func fileRow(_ result: FileSearchResult) -> LauncherItem {
        let folder = Self.shortenedPath(result.url.deletingLastPathComponent())
        return LauncherItem(
            id: result.id, title: result.name,
            subtitle: result.matchedContent ? "Contents match · \(folder)" : folder,
            symbol: result.isDirectory ? "folder" : "doc", kind: .file,
            badge: result.isDirectory ? "Folder" : Self.fileKind(result.url),
            iconURL: result.url, action: .file(result.url), isLiveResult: true)
    }

    /// The browsed folder itself, first in its listing: ↩ opens it in the Finder.
    private func folderRow(_ directory: URL) -> LauncherItem {
        var row = fileRow(FileSearchResult(url: directory, isDirectory: true))
        row.subtitle = directory.path == "/" ? "Open in Finder" : "Open in Finder · \(Self.shortenedPath(directory.deletingLastPathComponent()))"
        if row.title.isEmpty { row.title = "Macintosh HD" }
        return row
    }

    // MARK: - Path browsing keys

    /// Whether Tab on a file row browses: any row while a path is typed, or a folder in Files.
    func canEnterFilePath(_ url: URL) -> Bool {
        guard destination == .search, argumentLink == nil else { return false }
        if filePathQuery != nil { return true }
        return section == .files && isBrowsableFolder(url)
    }

    /// Tab: a folder opens its listing; a file completes its name in the field.
    func enterFilePath(_ url: URL) {
        let text = FilePathQuery.completion(for: url, isFolder: isBrowsableFolder(url), home: files.home)
        guard text != query else { return }
        query = text
        focusRequest += 1
    }

    /// ⇧Tab: the enclosing folder's listing. Returns false when no path is typed.
    @discardableResult
    func browseEnclosingFolder() -> Bool {
        guard let path = filePathQuery else { return false }
        let target: String
        if !path.filter.isEmpty {
            target = path.folderText(home: files.home)
        } else if let parent = path.parentText(home: files.home) {
            target = parent
        } else {
            return true
        }
        query = target
        focusRequest += 1
        return true
    }

    private func isBrowsableFolder(_ url: URL) -> Bool {
        if let result = files.results.first(where: { $0.url.path == url.path }) {
            return result.isDirectory
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    // MARK: - ⌘K entries

    /// Item entries for file and application rows, added after Quick Look, Reveal and Copy Path.
    /// For apps, Copy Path moves to ⌥⌘C so ⇧⌘C can copy the bundle id.
    func addFileAndApplicationActions(to entries: inout [ActionEntry], for item: LauncherItem) {
        switch item.action {
        case .file(let url): entries += fileActions(for: url)
        case .application(let app):
            if let index = entries.firstIndex(where: { $0.id == "copyPath" }) {
                entries[index].shortcut = KeyShortcut(["⌥", "⌘", "C"])
                entries[index].modifiers = [.command, .option]
            }
            entries += applicationActions(for: app)
        default: break
        }
    }

    /// Panel entries for the Files scope, path browsing and Applications.
    func filesAndApplicationsPanelActions() -> [ActionEntry] {
        guard destination == .search, editor == nil else { return [] }
        var entries: [ActionEntry] = []
        if section == .files || filePathQuery != nil {
            let settings = filesSettings
            entries.append(
                ActionEntry(
                    id: "files.sort", title: "Sort by \(settings.sort.next.title)", symbol: "arrow.up.arrow.down",
                    shortcut: .command("P", shift: true), key: "p", modifiers: [.command, .shift], group: .panel
                ) { [weak self] in self?.cycleFileSort() })
            entries.append(
                ActionEntry(
                    id: "files.hidden", title: settings.includesHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files",
                    symbol: settings.includesHiddenFiles ? "eye.slash" : "eye", shortcut: .command(".", shift: true),
                    key: ".", modifiers: [.command, .shift], group: .panel
                ) { [weak self] in self?.toggleHiddenFiles() })
        }
        if let path = filePathQuery, path.filter.isEmpty ? path.parentText(home: files.home) != nil : true {
            entries.append(
                ActionEntry(
                    id: "files.parent", title: "Enclosing Folder", symbol: "arrow.turn.left.up",
                    shortcut: KeyShortcut(["⇧", "Tab"]), key: .tab, modifiers: .shift, group: .panel
                ) { [weak self] in self?.browseEnclosingFolder() })
        }
        if section == .applications, let provider = applicationsProvider {
            let keeping = Set(applicationSettings.keepRunningBundleIDs)
            if !provider.running.batchTargets(keeping: keeping, quitting: false).isEmpty {
                entries.append(
                    ActionEntry(id: "apps.hideAll", title: "Hide All Apps…", symbol: "eye.slash", group: .panel) {
                        [weak self] in self?.askToBatch(quitting: false)
                    })
            }
            if !provider.running.batchTargets(keeping: keeping, quitting: true).isEmpty {
                entries.append(
                    ActionEntry(
                        id: "apps.quitAll", title: "Quit All Apps…", symbol: "xmark.circle", group: .panel,
                        isDestructive: true
                    ) { [weak self] in self?.askToBatch(quitting: true) })
            }
        }
        return entries
    }

    func fileActions(for url: URL) -> [ActionEntry] {
        guard let provider = filesProvider else { return [] }
        let workspace = provider.workspace
        let isFolder = isBrowsableFolder(url)
        var entries: [ActionEntry] = []
        let apps = workspace.applications(toOpen: url)
        if !apps.isEmpty {
            let children = apps.map { app in
                ActionEntry(
                    id: "openWith.\(app.url.path)", title: app.isDefault ? "\(app.name) (Default)" : app.name,
                    symbol: "app", group: .item
                ) { [weak self] in self?.open(url, with: app, workspace: workspace) }
            }
            entries.append(
                ActionEntry(
                    id: "openWith", title: "Open With", symbol: "arrow.up.forward.app", group: .item,
                    children: children
                ) { [weak self] in self?.openWithDefaultApp(url, workspace: workspace) })
        }
        if isFolder {
            entries.append(
                ActionEntry(id: "terminal", title: "Open in Terminal", symbol: "terminal", group: .item) {
                    [weak self] in self?.openInTerminal(url, workspace: workspace)
                })
        }
        let targets = workspace.shareTargets(for: url)
        if !targets.isEmpty {
            entries.append(
                ActionEntry(
                    id: "share", title: "Share", symbol: "square.and.arrow.up", group: .item,
                    children: targets.map { target in
                        ActionEntry(id: "share.\(target.id)", title: target.title, symbol: target.symbol, group: .item) {
                            [weak self] in self?.share(url, via: target, workspace: workspace)
                        }
                    }
                ) { [weak self] in
                    // Where a file goes is the person's choice; a surface without submenus only says how.
                    self?.feedback = .info("Choose \(targets.map(\.title).joined(separator: ", ")) under Share in ⌘K.")
                })
        }
        if !isFolder || filePathQuery == nil {
            entries.append(
                ActionEntry(id: "sendToAI", title: "Send to AI Chat", symbol: "sparkles", group: .item) {
                    [weak self] in self?.sendFileToAI(url)
                })
        }
        entries.append(
            ActionEntry(id: "saveQuicklink", title: "Save as Quicklink", symbol: "link.badge.plus", group: .item) {
                [weak self] in self?.saveFileAsQuicklink(url)
            })
        entries.append(
            ActionEntry(id: "excludeFile", title: "Exclude from Search", symbol: "eye.slash", group: .organize) {
                [weak self] in self?.excludeFromFileSearch(url)
            })
        entries.append(
            ActionEntry(
                id: "trash", title: "Move to Trash", symbol: "trash", shortcut: KeyShortcut(["⌘", "⌫"]), key: .delete,
                modifiers: .command, group: .organize, isDestructive: true
            ) { [weak self] in
                self?.askToTrash(url, workspace: workspace) { [weak self] in
                    self?.files.invalidateListing()
                    self?.resumeSearch()
                }
            })
        return entries
    }

    func applicationActions(for app: InstalledApplication) -> [ActionEntry] {
        guard let provider = applicationsProvider else { return [] }
        let running = provider.running
        var entries: [ActionEntry] = [
            ActionEntry(
                id: "packageContents", title: "Show Package Contents", symbol: "shippingbox",
                shortcut: KeyShortcut(["⌥", "⌘", "I"]), key: "i", modifiers: [.command, .option], group: .item
            ) { [weak self] in
                self?.showFolder(app.url.appending(path: "Contents", directoryHint: .isDirectory), workspace: provider.workspace)
            }
        ]
        if let bundleID = app.bundleIdentifier {
            entries.append(
                ActionEntry(
                    id: "copyBundleID", title: "Copy Bundle Identifier", symbol: "number",
                    shortcut: .command("C", shift: true), key: "c", modifiers: [.command, .shift], group: .item
                ) { [weak self] in self?.copy(bundleID, label: bundleID) })
        }
        if running.isRunning(app) {
            entries.append(
                ActionEntry(
                    id: "hideApp", title: "Hide Application", symbol: "eye.slash", shortcut: .command("H", shift: true),
                    key: "h", modifiers: [.command, .shift], group: .item, section: "Running"
                ) { [weak self] in self?.runApplicationAction(app, verb: "Hid") { try running.hide(app) } })
            entries.append(
                ActionEntry(
                    id: "quitApp", title: "Quit Application", symbol: "xmark.circle",
                    shortcut: KeyShortcut(["⌃", "⇧", "Q"]), key: "q", modifiers: [.control, .shift], group: .item,
                    section: "Running"
                ) { [weak self] in self?.runApplicationAction(app, verb: "Quit") { try running.quit(app) } })
            entries.append(
                ActionEntry(
                    id: "forceQuitApp", title: "Force Quit Application…", symbol: "exclamationmark.octagon",
                    shortcut: KeyShortcut(["⌃", "⌥", "⇧", "Q"]), key: "q", modifiers: [.control, .option, .shift],
                    group: .item, isDestructive: true, section: "Running"
                ) { [weak self] in self?.askToForceQuit(app) })
            entries.append(
                ActionEntry(
                    id: "restartApp", title: "Restart Application", symbol: "arrow.clockwise", shortcut: .command("R"),
                    key: "r", modifiers: .command, group: .item, section: "Running"
                ) { [weak self] in self?.restartApplication(app) })
        }
        let settings = applicationSettings
        if let bundleID = app.bundleIdentifier, provider.autoQuit.canAutoQuit(bundleID) {
            let enabled = settings.autoQuitMinutes(for: bundleID) != nil
            entries.append(
                ActionEntry(
                    id: "autoQuit", title: enabled ? "Disable Auto Quit" : "Enable Auto Quit",
                    symbol: enabled ? "timer.circle" : "timer", group: .organize
                ) { [weak self] in self?.setAutoQuit(!enabled, for: app) })
        }
        entries.append(
            ActionEntry(id: "hideFromSearch", title: "Hide from Search", symbol: "eye.slash", group: .organize) {
                [weak self] in self?.hideApplicationFromSearch(app)
            })
        if UninstallPlan.refusal(for: app, ownBundleID: running.ownBundleID) == nil {
            entries.append(
                ActionEntry(
                    id: "uninstall", title: "Uninstall Application…", symbol: "trash", group: .organize,
                    isDestructive: true
                ) { [weak self] in
                    guard let self else { return }
                    provider.beginReview(of: app, in: self)
                })
        }
        return entries
    }

    // MARK: - File effects

    /// Asks in the action bar before running a destructive step.
    func askConfirmation(_ confirmation: ProvidedConfirmation) {
        showActions = false
        self.confirmation = .provided(confirmation)
    }

    /// Asks before moving a file to the Trash. The file is frozen as it is now; if something else
    /// is at that path when ↩ approves, nothing moves.
    func askToTrash(_ url: URL, workspace: any FileWorkspace, then: @escaping @MainActor () -> Void = {}) {
        let name = url.lastPathComponent
        guard let identity = FileIdentity.of(url) else {
            feedback = .warning("“\(name.truncatedForFeedback)” is gone.")
            return
        }
        askConfirmation(
            ProvidedConfirmation(
                id: "files.trash.\(url.path)",
                CommandConfirmation(
                    question: "Move “\(name.truncatedForFeedback)” to the Trash?",
                    detail: "You can put it back from the Trash until you empty it.", confirmTitle: "Move to Trash",
                    symbol: "trash")
            ) { [weak self] in
                guard let self else { return }
                guard identity.isSameItem(as: FileIdentity.of(url)) else {
                    self.feedback = .warning("“\(name.truncatedForFeedback)” changed since you asked. Nothing was moved.")
                    return
                }
                do {
                    try workspace.trash(url)
                    self.toast("Moved “\(name.truncatedForFeedback)” to the Trash")
                    then()
                } catch {
                    self.feedback = .error("Couldn't move “\(name.truncatedForFeedback)” to the Trash. \(error.localizedDescription)")
                }
            })
    }

    func revealInFinder(_ url: URL) {
        do {
            try SideEffectGuard.check("showing \(url.lastPathComponent) in the Finder")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            feedback = .info(error.localizedDescription)
        }
    }

    func openWithDefaultApp(_ url: URL, workspace: any FileWorkspace) {
        guard let app = workspace.applications(toOpen: url).first(where: \.isDefault) else {
            do {
                try SideEffectGuard.check("opening \(url.lastPathComponent)")
                if NSWorkspace.shared.open(url) { panel?.dismiss(restoreFocus: false) }
            } catch {
                feedback = .info(error.localizedDescription)
            }
            return
        }
        open(url, with: app, workspace: workspace)
    }

    func open(_ url: URL, with app: OpenWithApp, workspace: any FileWorkspace) {
        Task {
            do {
                try await workspace.open(url, with: app.url)
                store.recordUse(of: "file.\(url.path)")
                panel?.dismiss(restoreFocus: false)
            } catch {
                feedback = .error("Couldn't open “\(url.lastPathComponent)” in \(app.name). \(error.localizedDescription)")
            }
        }
    }

    func openInTerminal(_ folder: URL, workspace: any FileWorkspace) {
        let terminal = filesSettings.terminalBundleID
        Task {
            do {
                try await workspace.openInTerminal(folder, terminalBundleID: terminal)
                panel?.dismiss(restoreFocus: false)
            } catch {
                feedback = .error(error.localizedDescription)
            }
        }
    }

    func share(_ url: URL, via target: ShareTarget, workspace: any FileWorkspace) {
        do {
            try workspace.share(url, via: target)
        } catch {
            feedback = .error(error.localizedDescription)
        }
    }

    func showFolder(_ folder: URL, workspace: any FileWorkspace) {
        do {
            try workspace.showFolder(folder)
            panel?.dismiss(restoreFocus: false)
        } catch {
            feedback = .error(error.localizedDescription)
        }
    }

    /// Starts a new chat about the file. The chat can't take file attachments yet, so the
    /// path goes into the message, ready to finish and send.
    func sendFileToAI(_ url: URL) {
        if !ai.isGenerating { ai.newConversation(action: .chat) }
        openAI(.chat)
        ai.draft = "About “\(url.lastPathComponent)” (\(Self.shortenedPath(url))): "
        focusRequest += 1
    }

    /// Opens the quicklink editor filled in with the file, ready to name and save.
    func saveFileAsQuicklink(_ url: URL) {
        let path = Self.shortenedPath(url)
        let name = url.deletingPathExtension().lastPathComponent
        editor = .quicklink(Quicklink(name: name.isEmpty ? url.lastPathComponent : name, template: path, keyword: ""))
    }

    func excludeFromFileSearch(_ url: URL) {
        let path = url.standardizedFileURL.path
        if updateFilesSettings({ $0.excludedPaths.append(path) }) {
            toast("“\(url.lastPathComponent.truncatedForFeedback)” won't appear in Files. Undo in Settings › Files.")
        }
    }

    func cycleFileSort() {
        let next = filesSettings.sort.next
        if updateFilesSettings({ $0.sort = next }) { toast("Sorted by \(next.title.lowercased())") }
    }

    func toggleHiddenFiles() {
        let showing = !filesSettings.includesHiddenFiles
        if updateFilesSettings({ $0.includesHiddenFiles = showing }) {
            toast(showing ? "Showing hidden files" : "Hiding hidden files")
        }
    }

    // MARK: - Application effects

    func runApplicationAction(_ app: InstalledApplication, verb: String, _ action: () throws -> Void) {
        do {
            try action()
            toast("\(verb) \(app.name)")
        } catch {
            feedback = .error(error.localizedDescription)
        }
    }

    /// Force Quit asks first and then acts on exactly the processes running when it asked.
    func askToForceQuit(_ app: InstalledApplication) {
        guard let running = applicationsProvider?.running else { return }
        let snapshot = running.instances(of: app)
        guard !snapshot.isEmpty else {
            feedback = .info("\(app.name) isn't running.")
            return
        }
        askConfirmation(
            ProvidedConfirmation(
                id: "applications.forceQuit.\(app.id)",
                CommandConfirmation(
                    question: "Force quit \(app.name)?", detail: "Unsaved changes in its documents will be lost.",
                    confirmTitle: "Force Quit", symbol: "exclamationmark.octagon")
            ) { [weak self] in
                guard let self else { return }
                let result = running.forceQuit(snapshot)
                if !result.failed.isEmpty {
                    self.feedback = .error("Couldn't force quit \(app.name).")
                } else if result.acted.isEmpty {
                    self.feedback = .info("\(app.name) had already quit. Nothing else was touched.")
                } else {
                    self.toast("Force quit \(app.name)")
                }
            })
    }

    func restartApplication(_ app: InstalledApplication) {
        guard let running = applicationsProvider?.running else { return }
        feedback = .working("Restarting \(app.name)…")
        Task {
            do {
                try await running.restart(app)
                toast("Restarted \(app.name)")
            } catch {
                feedback = .error(error.localizedDescription)
            }
        }
    }

    /// Hide All and Quit All name the apps they'll act on, then act on exactly those processes:
    /// apps opened while the prompt shows, and apps added to Keep running meanwhile, are left alone.
    func askToBatch(quitting: Bool) {
        guard let running = applicationsProvider?.running else { return }
        let keeping = Set(applicationSettings.keepRunningBundleIDs)
        let snapshot = running.batchTargets(keeping: keeping, quitting: quitting).filter { quitting || !$0.isHidden }
        guard !snapshot.isEmpty else {
            feedback = .info(quitting ? "No apps to quit." : "No apps to hide.")
            return
        }
        let names = snapshot.map(\.name)
        let listed = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
        let verb = quitting ? "Quit" : "Hide"
        askConfirmation(
            ProvidedConfirmation(
                id: quitting ? "applications.quitAll" : "applications.hideAll",
                CommandConfirmation(
                    question: "\(verb) \(names.count) app\(names.count == 1 ? "" : "s")?",
                    detail: "\(listed).\(quitting ? " Apps can ask to save first." : "") Apps you keep running in Settings › Applications stay as they are.",
                    confirmTitle: quitting ? "Quit All" : "Hide All", symbol: quitting ? "xmark.circle" : "eye.slash")
            ) { [weak self] in
                guard let self else { return }
                let keepingNow = Set(self.applicationSettings.keepRunningBundleIDs)
                let result = running.act(on: snapshot, quitting: quitting, keeping: keepingNow)
                self.reportBatch(result, verb: quitting ? "Asked" : "Hid", noun: quitting ? "quit" : "hide")
            })
    }

    private func reportBatch(_ result: RunningApplications.BatchResult, verb: String, noun: String) {
        if result.failed.isEmpty {
            let count = result.acted.count
            toast(verb == "Asked" ? "Asked \(count) app\(count == 1 ? "" : "s") to quit" : "\(verb) \(count) app\(count == 1 ? "" : "s")")
        } else {
            feedback = .warning("Couldn't \(noun) \(result.failed.prefix(3).joined(separator: ", ")).")
        }
    }

    func setAutoQuit(_ enabled: Bool, for app: InstalledApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        if updateApplicationSettings({ settings in
            if enabled { settings.autoQuit[bundleID] = .some(nil) } else { settings.autoQuit[bundleID] = nil }
        }) {
            let minutes = applicationSettings.autoQuitDefaultMinutes
            toast(enabled ? "\(app.name) quits after \(minutes) idle minute\(minutes == 1 ? "" : "s")" : "Auto Quit is off for \(app.name)")
        }
    }

    func hideApplicationFromSearch(_ app: InstalledApplication) {
        if updateApplicationSettings({ $0.hiddenAppIDs.append(app.id) }) {
            toast("\(app.name) is hidden from search. Show it again in Settings › Applications.")
            synchronizeSelection()
        }
    }
}
