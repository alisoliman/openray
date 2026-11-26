import AppKit
import Observation

/// Which support files the person left out of an uninstall, by app path. Observable, so the
/// review list redraws as rows are ticked.
@MainActor
@Observable
final class UninstallSelection {
    var excluded: [String: Set<String>] = [:]
}

/// Applications: Uninstall and Manage Auto Quit commands, the uninstall review lists, the
/// running-app controller behind Hide, Quit, Force Quit and Restart, and Auto Quit.
///
/// App rows stay the launcher's own `.application` rows; `LauncherModel.applicationActions`
/// builds their ⌘K entries through this provider. The registration accepts `app.` ids, so
/// apps can hold aliases and hotkeys (Slice 1 owns the binding UI).
@MainActor
final class ApplicationsCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(
        id: "applications", bindablePrefixes: ["app.", "applications."]
    ) { ApplicationsCommandProvider() }

    nonisolated static let uninstallID = "applications.uninstall"
    nonisolated static let autoQuitID = "applications.autoQuit"
    nonisolated static let reviewScopeID = "applications.uninstall.review"

    static let pickScope = ProvidedScope(
        id: "applications.uninstall", provider: "applications", title: "Uninstall Application", symbol: "trash",
        kind: .system, placeholder: "Search applications to uninstall",
        summary: "Move an app and its support files to the Trash", shortTitle: "Uninstall", itemNoun: "application")

    static func reviewScope(for app: InstalledApplication) -> ProvidedScope {
        ProvidedScope(
            id: reviewScopeID, provider: "applications", title: "Uninstall \(app.name)", symbol: "trash", kind: .system,
            placeholder: "Filter files", summary: "Review what moves to the Trash", itemNoun: "file",
            ranksItems: false, arguments: ["path": app.url.path])
    }

    var id: String { Self.registration.id }
    let running: RunningApplications
    let autoQuit: AutoQuit
    let workspace: any FileWorkspace
    let selection = UninstallSelection()
    /// `~/Library`, where support files are looked for.
    let library: URL
    private let sideEffects: SideEffectGuard

    convenience init() {
        self.init(controller: LiveRunningApplications(), workspace: LiveFileWorkspace())
    }

    init(
        controller: any RunningApplicationControlling, workspace: any FileWorkspace,
        sideEffects: SideEffectGuard = .current,
        library: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library"),
        ownBundleID: String? = Bundle.main.bundleIdentifier, now: @escaping @MainActor () -> Date = { .now }
    ) {
        running = RunningApplications(controller: controller, ownBundleID: ownBundleID)
        autoQuit = AutoQuit(running: running, settings: { ApplicationSettings() }, now: now)
        self.workspace = workspace
        self.sideEffects = sideEffects
        self.library = library
    }

    /// Reads settings from the model and starts Auto Quit, in a normal launch only.
    func attach(to model: LauncherModel) {
        autoQuit.settings = { [weak model] in model?.applicationSettings ?? ApplicationSettings() }
        autoQuit.start(sideEffects: sideEffects)
    }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.uninstallID, title: "Uninstall Application", subtitle: Self.pickScope.summary, kind: .system,
                symbol: "trash", keywords: ["remove", "delete", "app", "uninstaller", "clean up"],
                mode: .view(.provided(Self.pickScope))),
            CommandDescriptor(
                id: Self.autoQuitID, title: "Manage Auto Quit", subtitle: "Quit chosen apps after they sit idle",
                kind: .system, symbol: "timer", keywords: ["auto quit", "idle", "close apps", "memory"],
                mode: .noView),
        ]
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case Self.autoQuitID:
            model.store.recordUse(of: item.id)
            model.openSettings(.applications)
        case "pick":
            guard let app = application(atPath: ref.payload, in: model) else { return }
            selection.excluded[app.url.path] = nil
            model.navigate(to: .provided(Self.reviewScope(for: app)))
        case "review.app":
            guard let app = application(atPath: ref.payload, in: model) else { return }
            askToUninstall(app, in: model)
        case "review.file":
            guard let file = ref.payload, let appPath = ref.arguments["app"] else { return }
            var excluded = selection.excluded[appPath] ?? []
            if excluded.contains(file) { excluded.remove(file) } else { excluded.insert(file) }
            selection.excluded[appPath] = excluded
        default: break
        }
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        switch ref.id {
        case "pick": "Review Files"
        case "review.app": "Uninstall…"
        case "review.file":
            selection.excluded[ref.arguments["app"] ?? ""]?.contains(ref.payload ?? "") == true ? "Include" : "Leave Out"
        default: nil
        }
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        switch ref.id {
        case "pick": "list.bullet"
        case "review.app": "trash"
        case "review.file": "checkmark.circle"
        default: nil
        }
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { nil }
    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {}

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        guard ref.id == "review.file" || ref.id == "review.app" || ref.id == "pick", let path = ref.payload else {
            return []
        }
        let url = URL(fileURLWithPath: path)
        return [
            ActionEntry(
                id: "reveal", title: "Reveal in Finder", symbol: "folder", shortcut: .command("R", shift: true),
                key: "r", modifiers: [.command, .shift], group: .item
            ) { [weak model] in model?.revealInFinder(url) }
        ]
    }

    // MARK: Scopes

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        switch scope.id {
        case Self.pickScope.id:
            return model.applications.applications.filter { UninstallPlan.refusal(for: $0) == nil }.map { app in
                LauncherItem(
                    id: "applications.uninstall.\(app.bundleIdentifier ?? app.url.path)", title: app.name,
                    subtitle: LauncherModel.shortenedPath(app.url.deletingLastPathComponent()), symbol: "app",
                    kind: .system, badge: "Application", keywords: app.bundleIdentifier ?? "", iconURL: app.url,
                    action: .provided(
                        ProvidedRef(
                            provider: id, id: "pick", payload: app.url.path, primaryTitle: "Review Files", traits: [])))
            }
        case Self.reviewScopeID:
            guard let app = application(atPath: scope.arguments["path"], in: model) else { return [] }
            return reviewItems(for: plan(for: app), query: query)
        default:
            return []
        }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        guard scope.id == Self.reviewScopeID else { return nil }
        return ProvidedEmptyState(
            title: "This app is gone", detail: "It may have been moved or uninstalled already.", symbol: "questionmark.app")
    }

    /// The app, then each support file it keeps, ticked unless left out.
    func reviewItems(for plan: UninstallPlan, query: String) -> [LauncherItem] {
        let appPath = plan.app.url.path
        let excluded = selection.excluded[appPath] ?? []
        let included = plan.supportFiles.filter { !excluded.contains($0.path) }.count
        let summary =
            plan.supportFiles.isEmpty
            ? "No support files found" : "\(included) of \(plan.supportFiles.count) support files included"
        var rows = [
            LauncherItem(
                id: "applications.review.app", title: "Uninstall \(plan.app.name)", subtitle: summary, symbol: "trash",
                kind: .system, badge: "Application", iconURL: plan.app.url,
                action: .provided(
                    ProvidedRef(provider: id, id: "review.app", payload: appPath, primaryTitle: "Uninstall…", traits: [])))
        ]
        let library = self.library.path
        for file in plan.supportFiles {
            let isIncluded = !excluded.contains(file.path)
            let folder = file.deletingLastPathComponent().path
            let location = folder.hasPrefix(library) ? "~/Library" + folder.dropFirst(library.count) : folder
            rows.append(
                LauncherItem(
                    id: "applications.review.\(file.path)", title: file.lastPathComponent, subtitle: location,
                    symbol: isIncluded ? "checkmark.circle.fill" : "circle", kind: .file,
                    badge: isIncluded ? "Moves to Trash" : "Left Out",
                    action: .provided(
                        ProvidedRef(
                            provider: id, id: "review.file", payload: file.path, arguments: ["app": appPath],
                            primaryTitle: isIncluded ? "Leave Out" : "Include", traits: []))))
        }
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return rows }
        return [rows[0]] + rows.dropFirst().filter { SearchMatcher.score(term, in: $0.title + " " + $0.subtitle) != nil }
    }

    // MARK: Uninstall

    func plan(for app: InstalledApplication) -> UninstallPlan {
        UninstallPlan(
            app: app,
            supportFiles: UninstallPlan.supportFiles(bundleID: app.bundleIdentifier, appName: app.name, library: library))
    }

    /// The files an uninstall would move now: the app, then the support files still included.
    func filesToTrash(for plan: UninstallPlan) -> [URL] {
        let excluded = selection.excluded[plan.app.url.path] ?? []
        return [plan.app.url] + plan.supportFiles.filter { !excluded.contains($0.path) }
    }

    func askToUninstall(_ app: InstalledApplication, in model: LauncherModel) {
        if let refusal = UninstallPlan.refusal(for: app, ownBundleID: running.ownBundleID) {
            model.feedback = .warning(refusal)
            return
        }
        if running.isRunning(app) {
            model.feedback = .warning("Quit \(app.name) before uninstalling it.")
            return
        }
        let plan = plan(for: app)
        let files = filesToTrash(for: plan)
        let extra = files.count - 1
        let question = CommandConfirmation(
            question: extra == 0
                ? "Move \(app.name) to the Trash?" : "Move \(app.name) and \(extra) support file\(extra == 1 ? "" : "s") to the Trash?",
            detail: "You can put them back from the Trash until you empty it.", confirmTitle: "Uninstall",
            symbol: "trash")
        model.askConfirmation(ProvidedConfirmation(id: "applications.uninstall.\(app.url.path)", question) {
            [weak self, weak model] in
            guard let self, let model else { return }
            self.uninstall(plan, in: model)
        })
    }

    /// Moves the app and the included support files to the Trash, then rescans apps.
    func uninstall(_ plan: UninstallPlan, in model: LauncherModel) {
        var failed: [String] = []
        var moved = 0
        for (index, url) in filesToTrash(for: plan).enumerated() {
            do {
                try workspace.trash(url)
                moved += 1
            } catch {
                // Without the app itself, the support files stay.
                if index == 0 {
                    model.feedback = .error("Couldn't move \(plan.app.name) to the Trash. \(error.localizedDescription)")
                    return
                }
                failed.append(url.lastPathComponent)
            }
        }
        selection.excluded[plan.app.url.path] = nil
        Task { await model.applications.refresh() }
        if case .provided(let scope) = model.section, scope.id == Self.reviewScopeID { model.leaveScope() }
        if failed.isEmpty {
            model.toast("Moved \(plan.app.name)\(moved > 1 ? " and \(moved - 1) support files" : "") to the Trash")
        } else {
            model.feedback = .warning(
                "Moved \(plan.app.name) to the Trash. \(failed.count) support file\(failed.count == 1 ? "" : "s") stayed: \(failed.prefix(3).joined(separator: ", ")).")
        }
    }

    private func application(atPath path: String?, in model: LauncherModel) -> InstalledApplication? {
        guard let path else { return nil }
        if let app = model.applications.applications.first(where: { $0.url.path == path }) { return app }
        // An app outside the catalog's folders, reached through a favorite or a test.
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        let bundle = Bundle(url: url)
        let name =
            (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        return InstalledApplication(name: name, url: url, bundleIdentifier: bundle?.bundleIdentifier)
    }
}
