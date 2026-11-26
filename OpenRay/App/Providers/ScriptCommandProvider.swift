import AppKit
import SwiftUI

/// Shows a short message after the panel closes, for silent scripts.
@MainActor
protocol ScriptResultPresenting: AnyObject {
    func showHUD(_ text: String, isError: Bool, in model: LauncherModel)
}

/// Silent scripts' last line, in Slice 5's HUD: a small window that appears after the panel
/// closes. Failures use its error style. (Compact scripts that finish after the panel closed
/// report here too.)
@MainActor
final class HUDScriptResultPresenter: ScriptResultPresenting {
    let hud: HUDController

    init(hud: HUDController = .shared) {
        self.hud = hud
    }

    func showHUD(_ text: String, isError: Bool, in model: LauncherModel) {
        hud.show(
            HUDMessage(
                text, symbol: isError ? "exclamationmark.triangle.fill" : "terminal", style: isError ? .error : .success))
    }
}

/// An inline script's latest answer: its first output line, or why it failed.
struct ScriptInlineResult: Equatable, Sendable {
    var text: String
    var isError: Bool
    var date: Date
}

/// What inline scripts last said, and when they last ran. Rows read it, so they update in place.
@MainActor
@Observable
final class ScriptInlineState {
    var results: [String: ScriptInlineResult] = [:]
    var lastRun: [String: Date] = [:]

    init() {}
}

/// Script commands in root search: each valid script in the person's script folders is a
/// command that runs in its header's output mode. Commands are bindable under `script.`.
@MainActor
final class ScriptCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(
        id: "script", bindablePrefixes: [ScriptCommand.idPrefix]
    ) { ScriptCommandProvider() }

    /// Opens the list of every script command, grouped by package.
    nonisolated static let browseID = "script.browse"
    /// Opens Settings › Scripts at the new-script form.
    nonisolated static let createID = "script.create"
    /// The `commandPreferences` key that makes a script a fallback command.
    nonisolated static let fallbackKey = "fallback"
    /// The `commandPreferences` key that overrides a script's timeout, in seconds.
    nonisolated static let timeoutKey = "timeout"

    static let browseScope = ProvidedScope(
        id: "script.commands", provider: "script", title: "Script Commands", symbol: "terminal", kind: .command,
        placeholder: "Search script commands", summary: "Run scripts from your script folders",
        shortTitle: "Scripts", itemNoun: "script command")

    static let outputScope = ProvidedScope(
        id: "script.output", provider: "script", title: "Script Output", symbol: "terminal", kind: .command,
        placeholder: "Script output", itemNoun: "output", ranksItems: false)

    /// The output row's ref id.
    static let outputRowID = "output"

    let catalog: ScriptCatalog
    let runner: ScriptRunner
    let inline = ScriptInlineState()
    let presenter: any ScriptResultPresenting
    /// Inline scripts refresh on their own only when this is true: never while OpenRay is inert.
    let refreshesAutomatically: Bool
    /// The run the output view shows.
    private(set) var presentedJobID: UUID?
    private var schedulerTask: Task<Void, Never>?
    private var pendingDirectorySync = false

    var id: String { Self.registration.id }
    var title: String { "Script Commands" }

    convenience init() {
        let inert = SideEffectGuard.current.isInert
        self.init(
            catalog: ScriptCatalog(watcher: inert ? nil : FSEventsDirectoryWatcher()), runner: ScriptRunner(),
            presenter: HUDScriptResultPresenter(), refreshesAutomatically: !inert)
    }

    init(
        catalog: ScriptCatalog, runner: ScriptRunner, presenter: any ScriptResultPresenting,
        refreshesAutomatically: Bool
    ) {
        self.catalog = catalog
        self.runner = runner
        self.presenter = presenter
        self.refreshesAutomatically = refreshesAutomatically
    }

    // MARK: Catalog

    /// Brings the catalog to the library's folders. Settings calls it after a change; search
    /// calls it lazily, on the next run loop turn, so a view update never mutates state.
    func synchronize(with model: LauncherModel, synchronously: Bool = false) {
        if catalog.didChange == nil {
            catalog.didChange = { [weak self, weak model] in
                guard let self, let model else { return }
                model.commandCatalogDidChange()
                self.startSchedulerIfNeeded(model)
            }
        }
        catalog.setDirectories(
            model.store.database.scriptDirectories, approvals: approvals(for: model).approvals.scriptFolders,
            synchronously: synchronously)
        startSchedulerIfNeeded(model)
    }

    /// This Mac's approvals for the launcher's library.
    func approvals(for model: LauncherModel) -> LocalApprovalStore { LocalApprovalStore.for(model.store) }

    private func scheduleSynchronization(_ model: LauncherModel) {
        guard !pendingDirectorySync,
            model.store.database.scriptDirectories != catalog.directories
                || approvals(for: model).approvals.scriptFolders != catalog.approvals
        else { return }
        pendingDirectorySync = true
        DispatchQueue.main.async { [weak self, weak model] in
            guard let self, let model else { return }
            self.pendingDirectorySync = false
            self.synchronize(with: model)
        }
    }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        scheduleSynchronization(model)
        let browse = CommandDescriptor(
            id: Self.browseID, title: "Search Script Commands", subtitle: Self.browseScope.summary, kind: .command,
            symbol: "terminal", keywords: ["scripts", "script commands", "shell", "automation"],
            mode: .view(.provided(Self.browseScope)))
        let create = CommandDescriptor(
            id: Self.createID, title: "Create Script Command", subtitle: "Start a new script from a template",
            kind: .command, symbol: "plus.rectangle.on.folder", keywords: ["new script", "script directory", "add"],
            mode: .noView)
        return [browse, create] + catalog.commands.map { descriptor(for: $0, in: model) }
    }

    func descriptor(for script: ScriptCommand, in model: LauncherModel) -> CommandDescriptor {
        let running = runner.runningJob(for: script.id) != nil
        var subtitle = script.packageName
        var mode = CommandMode.noView
        if script.mode == .inline {
            mode = .inline(refresh: script.metadata.refreshTime)
            if let result = inline.results[script.id], !result.text.isEmpty {
                subtitle = result.isError ? "Failed: \(result.text)" : result.text
            }
        } else if running {
            subtitle = "Running… \(script.packageName)"
        }
        var keywords = [script.packageName, "script", script.url.lastPathComponent]
        if let author = script.metadata.author { keywords.append(author) }
        return CommandDescriptor(
            id: script.id, title: script.title, subtitle: subtitle, kind: .command, symbol: "terminal",
            keywords: keywords, arguments: script.metadata.arguments.map(\.spec), mode: mode,
            badge: running ? "Running" : script.mode == .inline ? "Inline Script" : "Script",
            detail: script.metadata.description,
            confirmation: script.metadata.needsConfirmation
                // The format's needsConfirmation is for scripts like Quit All Apps or Empty Trash, so
                // the question is destructive: Return answers it only while it's on screen.
                ? CommandConfirmation(
                    question: "Run “\(script.title.truncatedForFeedback)”?",
                    detail: "This script asks for confirmation before it runs.", confirmTitle: "Run Script",
                    symbol: "terminal", isDestructive: true)
                : nil)
    }

    func item(withID id: String, in model: LauncherModel) -> LauncherItem? { nil }

    // MARK: Scopes

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        switch scope.id {
        case Self.outputScope.id:
            return presentedJob.map { [outputRow(for: $0)] } ?? []
        case Self.browseScope.id:
            return catalog.commands.map { item(for: descriptor(for: $0, in: model)) }
        default:
            return []
        }
    }

    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        guard scope.id == Self.browseScope.id else { return nil }
        var order: [String] = []
        var rows: [String: [LauncherItem]] = [:]
        for item in items {
            let package = catalog.command(withID: item.id)?.packageName ?? "Scripts"
            if rows[package] == nil { order.append(package) }
            rows[package, default: []].append(item)
        }
        return order.map { LauncherResultGroup(id: "script.package.\($0)", title: $0, items: rows[$0] ?? []) }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        guard scope.id == Self.browseScope.id, query.isEmpty else { return nil }
        if catalog.directories.isEmpty {
            return ProvidedEmptyState(
                title: "No script folders yet",
                detail: "Add a folder of script commands in Settings › Scripts, or create a new script there.",
                symbol: "folder.badge.plus")
        }
        return ProvidedEmptyState(
            title: "No script commands found",
            detail: "Scripts need a header with a schema version, title and mode. Settings › Scripts lists any with problems.")
    }

    // MARK: Fallbacks

    func isFallback(_ scriptID: String, in model: LauncherModel) -> Bool {
        model.store.database.commandPreferences[scriptID]?[Self.fallbackKey] == "true"
    }

    @discardableResult
    func setFallback(_ enabled: Bool, for scriptID: String, in model: LauncherModel) -> Bool {
        model.store.update { database in
            var preferences = database.commandPreferences[scriptID] ?? [:]
            preferences[Self.fallbackKey] = enabled ? "true" : nil
            database.commandPreferences[scriptID] = preferences.isEmpty ? nil : preferences
        }
    }

    /// Scripts marked as fallbacks, offered under “Use … with”. The query becomes the first
    /// argument; scripts without arguments just run.
    func fallbackItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        return catalog.commands.filter { isFallback($0.id, in: model) }.map { script in
            var arguments: [String: String] = [:]
            if let first = script.metadata.arguments.first { arguments[first.name] = query }
            return LauncherItem(
                id: "fallback.\(script.id)", title: script.title,
                subtitle: script.metadata.arguments.isEmpty ? script.packageName : "Run with “\(query.truncatedForFeedback)”",
                symbol: "terminal", kind: .command, badge: "Script",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: script.id, arguments: arguments, primaryTitle: "Run Script", traits: [])))
        }
    }

    // MARK: Running

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case Self.createID:
            model.store.recordUse(of: item.id)
            model.panel?.dismiss(restoreFocus: false)
            model.openSettings(.scripts)
        case Self.outputRowID:
            guard let job = ref.payload.flatMap(UUID.init(uuidString:)).flatMap(runner.job(withID:)) else { return }
            model.copy(job.plainOutput, label: "output of \(job.command.title)")
        default:
            guard let script = catalog.command(withID: ref.id) else {
                model.feedback = .error("“\(item.title.truncatedForFeedback)” is no longer available.")
                return
            }
            model.store.recordUse(of: script.id)
            run(script, values: ref.arguments, in: model)
        }
    }

    /// The script as it is now, when it may run; nil otherwise, after saying why (unless `quietly`)
    /// and rescanning. Every way of running a script (search, fallbacks, links, hotkeys, Run Again
    /// and inline refresh) passes here at the moment of launch, so a stale scan never decides:
    /// - its folder is still listed and turned on, and is still the folder this Mac allowed
    ///   (resolved path, device and inode);
    /// - the file, with links resolved, is a regular file inside that folder;
    /// - its header, read again now, is the one the launcher showed: same title, mode,
    ///   confirmation and arguments.
    /// The result launches the resolved file itself, not the path a link took to reach it.
    func authorize(_ script: ScriptCommand, in model: LauncherModel, quietly: Bool) -> ScriptCommand? {
        func refuse(_ message: String) -> ScriptCommand? {
            if !quietly { model.feedback = .error(message) }
            catalog.reload()
            return nil
        }
        let title = script.title.truncatedForFeedback
        guard let record = model.store.database.scriptDirectories.first(where: { $0.id == script.directoryID }),
            record.isEnabled, let folder = record.url
        else { return refuse("“\(title)” is in a script folder that's turned off or removed.") }
        guard let approved = approvals(for: model).approvals.scriptFolders[record.id],
            FolderIdentity.current(of: folder) == approved
        else { return refuse("“\(title)”'s folder changed since you allowed it. Turn it on again in Settings › Scripts.") }
        guard let real = ScriptScanner.realPath(script.url), real.hasPrefix(approved.resolvedPath + "/"),
            LibraryArchive.fileKind(real) == S_IFREG
        else { return refuse("“\(title)” isn't a file inside its allowed folder anymore.") }
        guard case .command(var current)? = ScriptScanner.inspect(script.url, directory: record, root: approved.resolvedPath),
            current.metadata == script.metadata, current.id == script.id
        else { return refuse("“\(title)” changed since OpenRay read it. Try again.") }
        // Launch the file that was checked: the resolved path in place of a link's.
        if current.launch.last == script.url.path { current.launch[current.launch.count - 1] = real }
        current.url = URL(fileURLWithPath: real)
        return current
    }

    /// The timeout for a script: its `commandPreferences` override, else its mode's default.
    func timeout(for script: ScriptCommand, in model: LauncherModel) -> Duration {
        if let raw = model.store.database.commandPreferences[script.id]?[Self.timeoutKey], let seconds = Int(raw),
            (1...86_400).contains(seconds)
        {
            return .seconds(seconds)
        }
        return ScriptRunner.defaultTimeout(for: script.mode)
    }

    /// Runs a script in its output mode. A script that's already running isn't started twice.
    @discardableResult
    func run(_ script: ScriptCommand, values: [String: String], in model: LauncherModel) -> ScriptJob? {
        guard !model.store.database.disabledCommandIDs.contains(script.id) else {
            model.feedback = .warning("“\(script.title.truncatedForFeedback)” is turned off.")
            return nil
        }
        guard !values.values.contains(where: { $0.contains("\0") }) else {
            model.feedback = .error("An argument contains a NUL character, so the script wasn't run.")
            return nil
        }
        guard let script = authorize(script, in: model, quietly: false) else { return nil }
        if let running = runner.runningJob(for: script.id) {
            if script.mode == .fullOutput {
                present(running, in: model)
            } else {
                model.feedback = .info("“\(script.title.truncatedForFeedback)” is already running.")
            }
            return nil
        }
        let timeout = timeout(for: script, in: model)
        let title = script.title
        switch script.mode {
        case .silent:
            model.panel?.dismiss()
            return runner.run(script, values: values, timeout: timeout) { [weak self, weak model] _, execution in
                guard let self, let model else { return }
                if execution.succeeded {
                    if let line = execution.lastLine { self.presenter.showHUD(line, isError: false, in: model) }
                } else {
                    self.presenter.showHUD(execution.failureMessage(title: title), isError: true, in: model)
                }
            }
        case .compact:
            model.feedback = .working("Running “\(title.truncatedForFeedback)”…")
            return runner.run(script, values: values, timeout: timeout) { [weak self, weak model] _, execution in
                guard let self, let model else { return }
                let visible = model.panel?.isVisible != false
                if execution.succeeded {
                    let line = execution.lastLine ?? "Ran “\(title.truncatedForFeedback)”"
                    if visible { model.toast(line) } else { self.presenter.showHUD(line, isError: false, in: model) }
                } else if visible {
                    model.feedback = .error(execution.failureMessage(title: title))
                } else {
                    self.presenter.showHUD(execution.failureMessage(title: title), isError: true, in: model)
                }
            }
        case .fullOutput:
            let job = runner.run(script, values: values, timeout: timeout) { [weak model] job, execution in
                guard let model, !execution.succeeded else { return }
                model.feedback = .error(execution.failureMessage(title: title))
            }
            present(job, in: model)
            return job
        case .inline:
            return runInline(script, values: values, in: model, reportsFailure: true)
        }
    }

    /// Refreshes an inline script. Background refreshes put failures in the row, not a toast.
    @discardableResult
    func runInline(
        _ script: ScriptCommand, values: [String: String] = [:], in model: LauncherModel, reportsFailure: Bool,
        now: Date = .now
    ) -> ScriptJob? {
        guard runner.runningJob(for: script.id) == nil else { return nil }
        inline.lastRun[script.id] = now
        guard let script = authorize(script, in: model, quietly: !reportsFailure) else { return nil }
        let title = script.title
        return runner.run(script, values: values, timeout: min(timeout(for: script, in: model), .seconds(60))) {
            [weak self, weak model] _, execution in
            guard let self else { return }
            if execution.succeeded {
                self.inline.results[script.id] = ScriptInlineResult(
                    text: execution.firstLine ?? "", isError: false, date: .now)
            } else {
                let message = execution.failureMessage(title: title)
                self.inline.results[script.id] = ScriptInlineResult(text: message, isError: true, date: .now)
                if reportsFailure { model?.feedback = .error(message) }
            }
        }
    }

    /// Runs every auto-refreshing inline script that's due. Scripts that ask for confirmation,
    /// or whose command is turned off, never run on their own; ↩ runs them through the usual checks.
    func refreshDueInlineScripts(in model: LauncherModel, now: Date = .now) {
        let running = Set(runner.runningJobs.map(\.command.id))
        let eligible = Self.automaticallyRefreshable(catalog.commands, disabled: model.store.database.disabledCommandIDs)
        for script in ScriptInlineSchedule.due(eligible, lastRun: inline.lastRun, running: running, now: now) {
            runInline(script, in: model, reportsFailure: false, now: now)
        }
    }

    /// The scripts the timer may run without anyone asking.
    nonisolated static func automaticallyRefreshable(_ commands: [ScriptCommand], disabled: Set<String>) -> [ScriptCommand] {
        commands.filter { !$0.metadata.needsConfirmation && !disabled.contains($0.id) }
    }

    private func startSchedulerIfNeeded(_ model: LauncherModel) {
        guard refreshesAutomatically, schedulerTask == nil,
            !ScriptInlineSchedule.autoRefreshing(
                Self.automaticallyRefreshable(catalog.commands, disabled: model.store.database.disabledCommandIDs)
            ).isEmpty
        else { return }
        schedulerTask = Task { [weak self, weak model] in
            while !Task.isCancelled {
                guard let self, let model else { return }
                self.refreshDueInlineScripts(in: model)
                let next = ScriptInlineSchedule.nextDue(self.catalog.commands, lastRun: self.inline.lastRun, now: .now)
                let delay = max(1, min(60, (next ?? .now.addingTimeInterval(60)).timeIntervalSinceNow))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    // MARK: Output view

    var presentedJob: ScriptJob? { presentedJobID.flatMap(runner.job(withID:)) }

    /// Shows a run in the output view, bringing the panel up when a hotkey started it.
    func present(_ job: ScriptJob, in model: LauncherModel) {
        presentedJobID = job.id
        var scope = Self.outputScope
        scope.title = job.command.title
        if let panel = model.panel, !panel.isVisible {
            panel.show(section: .provided(scope))
        } else {
            model.navigate(to: .provided(scope))
        }
    }

    func outputRow(for job: ScriptJob) -> LauncherItem {
        LauncherItem(
            id: "scriptoutput.\(job.id.uuidString)", title: job.command.title, subtitle: Self.status(of: job),
            symbol: "terminal", kind: .command, badge: job.isRunning ? "Running" : "Output",
            action: .provided(
                ProvidedRef(
                    provider: id, id: Self.outputRowID, payload: job.id.uuidString,
                    copyText: job.plainOutput, primaryTitle: "Copy Output", traits: [.paste])))
    }

    static func status(of job: ScriptJob) -> String {
        guard let execution = job.execution else { return "Running…" }
        let seconds = execution.duration.timeInterval.formatted(.number.precision(.fractionLength(1)))
        switch execution.termination {
        case .exited(0): return "Finished in \(seconds) s"
        case .exited(let code): return "Failed with exit code \(code)"
        case .signaled(let signal): return "Ended by signal \(signal)"
        case .timedOut: return "Stopped after \(seconds) s: it took too long"
        case .cancelled: return "Stopped"
        case .failedToLaunch(let reason): return "Couldn't run. \(reason)"
        }
    }

    // MARK: Action bar and ⌘K

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        if ref.id == Self.outputRowID { return "Copy Output" }
        if ref.id == Self.createID { return "Create Script Command" }
        guard let script = catalog.command(withID: ref.id) else { return nil }
        if script.mode == .inline { return "Refresh" }
        if script.mode == .fullOutput, runner.runningJob(for: script.id) != nil { return "Show Output" }
        return "Run Script"
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        if ref.id == Self.outputRowID { return "doc.on.doc" }
        guard let script = catalog.command(withID: ref.id) else { return nil }
        return script.mode == .inline ? "arrow.clockwise" : "play"
    }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        if ref.id == Self.outputRowID {
            guard let job = ref.payload.flatMap(UUID.init(uuidString:)).flatMap(runner.job(withID:)) else { return [] }
            return outputActions(for: job, in: model)
        }
        guard let script = catalog.command(withID: ref.id) else { return [] }
        var entries: [ActionEntry] = []
        if let running = runner.runningJob(for: script.id) {
            entries.append(stopEntry(for: running))
        }
        if script.mode != .inline, let job = runner.latestJob(for: script.id), script.mode == .fullOutput {
            entries.append(
                ActionEntry(
                    id: "script.showOutput", title: "Show Last Output", symbol: "text.alignleft",
                    shortcut: .command("O"), key: "o", modifiers: .command, group: .item
                ) { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.present(job, in: model)
                })
        }
        entries += fileActions(for: script, in: model)
        if !item.id.hasPrefix("fallback.") {
            let fallback = isFallback(script.id, in: model)
            entries.append(
                ActionEntry(
                    id: "script.fallback", title: fallback ? "Stop Using as Fallback" : "Use as Fallback",
                    symbol: fallback ? "arrow.uturn.backward.circle" : "arrow.turn.down.right", group: .organize
                ) { [weak self, weak model] in
                    guard let self, let model else { return }
                    if self.setFallback(!fallback, for: script.id, in: model) {
                        model.toast(fallback ? "“\(script.title.truncatedForFeedback)” is no longer a fallback"
                            : "“\(script.title.truncatedForFeedback)” is now a fallback")
                    } else {
                        model.feedback = .error(model.store.errorMessage ?? "Couldn't save the change.")
                    }
                })
        }
        return entries
    }

    private func outputActions(for job: ScriptJob, in model: LauncherModel) -> [ActionEntry] {
        var entries: [ActionEntry] = []
        if job.isRunning {
            entries.append(stopEntry(for: job))
        } else {
            entries.append(
                ActionEntry(
                    id: "script.runAgain", title: "Run Again", symbol: "arrow.clockwise", shortcut: .command("R"),
                    key: "r", modifiers: .command, group: .item
                ) { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.runAgain(job, in: model)
                })
        }
        if let last = job.execution?.lastLine {
            entries.append(
                ActionEntry(id: "script.copyLastLine", title: "Copy Last Line", symbol: "text.line.last.and.arrowtriangle.forward", group: .item) {
                    [weak model] in model?.copy(last)
                })
        }
        entries += fileActions(for: job.command, in: model)
        return entries
    }

    /// Runs a finished run's script again, as ↩ on its row would: through the registry, with
    /// the current command, so a removed or turned-off script, a confirmation and the arguments'
    /// checks all apply again.
    func runAgain(_ job: ScriptJob, in model: LauncherModel) {
        guard var item = model.commandItems.first(where: { $0.id == job.command.id }),
            case .provided(var ref) = item.action, catalog.command(withID: job.command.id) != nil
        else {
            model.feedback = .error("“\(job.command.title.truncatedForFeedback)” is no longer available.")
            return
        }
        ref.arguments = job.values
        item.action = .provided(ref)
        model.selectedID = item.id
        model.perform(item)
    }

    private func stopEntry(for job: ScriptJob) -> ActionEntry {
        ActionEntry(
            id: "script.stop", title: "Stop Script", symbol: "stop.circle", shortcut: KeyShortcut(["⌃", "C"]),
            key: "c", modifiers: .control, group: .item, isDestructive: true
        ) { job.cancel() }
    }

    private func fileActions(for script: ScriptCommand, in model: LauncherModel) -> [ActionEntry] {
        [
            ActionEntry(
                id: "script.edit", title: "Open Script in Editor", symbol: "pencil", shortcut: .command("E"), key: "e",
                modifiers: .command, group: .item
            ) { [weak model] in
                do {
                    try Self.openInEditor(script.url)
                    model?.panel?.dismiss(restoreFocus: false)
                } catch {
                    model?.feedback = .error(error.localizedDescription)
                }
            },
            ActionEntry(
                id: "script.reveal", title: "Reveal Script in Finder", symbol: "folder",
                shortcut: .command("R", shift: true), key: "r", modifiers: [.command, .shift], group: .item
            ) { [weak model] in
                do {
                    try SideEffectGuard.check("revealing files in Finder")
                    NSWorkspace.shared.activateFileViewerSelecting([script.url])
                } catch {
                    model?.feedback = .error(error.localizedDescription)
                }
            },
            ActionEntry(
                id: "script.copyPath", title: "Copy Script Path", symbol: "doc.on.doc",
                shortcut: .command("C", shift: true), key: "c", modifiers: [.command, .shift], group: .item
            ) { [weak model] in model?.copy(script.url.path, label: script.url.lastPathComponent) },
        ]
    }

    /// Opens a script in the person's source code editor. Never `NSWorkspace.open(url)` alone:
    /// an executable script's default app can be Terminal, which would run it.
    static func openInEditor(_ url: URL) throws {
        try SideEffectGuard.check("opening scripts in an editor")
        let workspace = NSWorkspace.shared
        guard
            let editor = workspace.urlForApplication(toOpen: .sourceCode)
                ?? workspace.urlForApplication(toOpen: .plainText)
                ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        else { throw LibraryValidationError("No text editor was found to open the script.") }
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Folders and new scripts (Settings › Scripts)

    /// Adds a folder of scripts. False when it's already listed or the library can't be saved.
    @discardableResult
    func addDirectory(_ url: URL, in model: LauncherModel) -> Bool {
        let path = url.standardizedFileURL.path
        guard !model.store.database.scriptDirectories.contains(where: { $0.url?.path == path }) else {
            model.feedback = .info("That folder is already in the list.")
            return false
        }
        let record = ScriptDirectoryRecord(path: path, addedAt: .now)
        let saved = model.store.update { database in database.scriptDirectories.append(record) }
        // Chosen here, on this Mac, so it's allowed as it is now.
        if saved { approvals(for: model).approve(record) }
        if saved { synchronize(with: model) }
        return saved
    }

    @discardableResult
    func removeDirectory(_ id: UUID, in model: LauncherModel) -> Bool {
        let saved = model.store.update { $0.scriptDirectories.removeAll { $0.id == id } }
        if saved { approvals(for: model).revoke(id) }
        if saved { synchronize(with: model) }
        return saved
    }

    /// Whether a folder's scripts run: turned on, and allowed on this Mac as the folder is now.
    func isActive(_ record: ScriptDirectoryRecord, in model: LauncherModel) -> Bool {
        record.isEnabled && approvals(for: model).isApproved(record)
    }

    /// Turns a folder on or off. Turning it on is the person's approval, on this Mac, of the
    /// folder Settings showed them (`shown`: its resolved path, device and inode); if the folder
    /// changed while they decided, nothing is approved. Off forgets the approval.
    @discardableResult
    func setDirectory(_ id: UUID, enabled: Bool, approving shown: FolderIdentity? = nil, in model: LauncherModel) -> Bool {
        guard let record = model.store.database.scriptDirectories.first(where: { $0.id == id }) else { return false }
        if enabled {
            guard approvals(for: model).approve(record, as: shown) else {
                model.feedback = .error("That folder changed or isn't there anymore. Review it again before allowing it.")
                return false
            }
        } else {
            approvals(for: model).revoke(id)
        }
        let saved = model.store.update { database in
            guard let index = database.scriptDirectories.firstIndex(where: { $0.id == id }) else { return }
            database.scriptDirectories[index].isEnabled = enabled
        }
        synchronize(with: model)
        return saved
    }

    /// Writes a new script from the template into a listed folder and rescans.
    func createScript(_ draft: ScriptTemplate.Draft, in directoryID: UUID, model: LauncherModel) throws -> URL {
        guard let folder = model.store.database.scriptDirectories.first(where: { $0.id == directoryID })?.url else {
            throw LibraryValidationError("Choose a script folder first.")
        }
        let url = try ScriptTemplate.create(draft, in: folder)
        catalog.reload()
        return url
    }
}

extension ScriptCommandProvider: DetailProviding {
    /// The output view: the presented run's output with ANSI colors, following new output while it runs.
    func detail(for scope: ProvidedScope, in model: LauncherModel) -> DetailContent? {
        guard scope.id == Self.outputScope.id, let job = presentedJob else { return nil }
        let status: DetailContent.Status
        switch job.execution?.termination {
        case nil: status = .running(since: job.startedAt)
        case .exited(0)?: status = .succeeded(Self.status(of: job))
        case .cancelled?: status = .info("Stopped")
        default: status = .failed(Self.status(of: job))
        }
        var emoji: String?
        if case .emoji(let value)? = job.command.metadata.icon { emoji = value }
        var metadata: [(label: String, value: String)] = [
            ("Package", job.command.packageName), ("File", job.command.url.lastPathComponent),
        ]
        if job.execution?.isTruncated == true { metadata.append(("Output", "Only the newest 1 MB was kept")) }
        return DetailContent(
            title: job.command.title, subtitle: job.command.metadata.description, symbol: "terminal", kind: .command,
            emoji: emoji, status: status, body: .ansi(job.output), metadata: metadata,
            emptyText: job.isRunning ? "Waiting for output…" : "The script printed nothing.",
            followsEnd: job.isRunning)
    }
}
