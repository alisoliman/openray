import AppKit
import Observation

/// Which support files the person ticked for an uninstall, by app path. Support files start
/// unticked: nothing beyond the app moves unless chosen. Observable, so the list redraws.
@MainActor
@Observable
final class UninstallSelection {
    var included: [String: Set<String>] = [:]
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
    /// Every installed copy of an app, by bundle id, from Launch Services. Tests replace it.
    var installedCopies: @MainActor (String) -> [URL] = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
    private let sideEffects: SideEffectGuard
    /// Plans by app path, made when a review opens, so typing doesn't rescan Library.
    private var plans: [String: UninstallPlan] = [:]
    /// The catalog's apps that can be uninstalled, kept until the catalog changes.
    private var uninstallable: (source: [InstalledApplication], apps: [InstalledApplication])?

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
        self.sideEffects = SideEffectGuard.atLeastCurrent(sideEffects)
        self.library = library
    }

    /// Opens the review list for an app, starting from a fresh plan with nothing ticked.
    func beginReview(of app: InstalledApplication, in model: LauncherModel) {
        selection.included[app.url.path] = nil
        plans[app.url.path] = nil
        model.navigate(to: .provided(Self.reviewScope(for: app)))
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
            beginReview(of: app, in: model)
        case "review.app":
            guard let app = application(atPath: ref.payload, in: model) else { return }
            askToUninstall(app, in: model)
        case "review.file":
            guard let file = ref.payload, let appPath = ref.arguments["app"] else { return }
            var included = selection.included[appPath] ?? []
            if included.contains(file) { included.remove(file) } else { included.insert(file) }
            selection.included[appPath] = included
        default: break
        }
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        switch ref.id {
        case "pick": "Review Files"
        case "review.app": "Uninstall…"
        case "review.file":
            selection.included[ref.arguments["app"] ?? ""]?.contains(ref.payload ?? "") == true ? "Leave Out" : "Include"
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
            return uninstallableApps(in: model).map { app in
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
            return reviewItems(for: plan(for: app, in: model), query: query)
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

    /// The catalog's apps that pass `UninstallPlan.refusal`, checked once per catalog.
    private func uninstallableApps(in model: LauncherModel) -> [InstalledApplication] {
        let source = model.applications.applications
        if let uninstallable, uninstallable.source == source { return uninstallable.apps }
        let apps = source.filter { UninstallPlan.refusal(for: $0, ownBundleID: running.ownBundleID) == nil }
        uninstallable = (source, apps)
        return apps
    }

    /// The app, then each support file it keeps, unticked until chosen.
    func reviewItems(for plan: UninstallPlan, query: String) -> [LauncherItem] {
        let appPath = plan.app.url.path
        let chosen = selection.included[appPath] ?? []
        let included = plan.supportFiles.filter { chosen.contains($0.path) }.count
        let summary =
            plan.supportFilesNote
            ?? (plan.supportFiles.isEmpty
                ? "No support files found"
                : "\(included) of \(plan.supportFiles.count) support files chosen · ↩ on a file to choose it")
        var rows = [
            LauncherItem(
                id: "applications.review.app", title: "Uninstall \(plan.app.name)", subtitle: summary, symbol: "trash",
                kind: .system, badge: "Application", iconURL: plan.app.url,
                action: .provided(
                    ProvidedRef(provider: id, id: "review.app", payload: appPath, primaryTitle: "Uninstall…", traits: [])))
        ]
        let library = self.library.path
        for file in plan.supportFiles {
            let isIncluded = chosen.contains(file.path)
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

    /// The plan for an app, made once per review. Copies the catalog or Launch Services know
    /// about share the support files, so their presence withholds them.
    func plan(for app: InstalledApplication, in model: LauncherModel? = nil) -> UninstallPlan {
        if let plan = plans[app.url.path] { return plan }
        let bundleID = UninstallPlan.bundleIdentifier(at: app.url) ?? app.bundleIdentifier
        let plan = UninstallPlan.make(for: app, library: library, otherCopies: copies(of: bundleID, in: model))
        plans[app.url.path] = plan
        return plan
    }

    /// Every known copy of a bundle id: Launch Services, every path the catalog's scan found,
    /// and the bundles of running processes. Any besides the app itself share its support files.
    func copies(of bundleID: String?, in model: LauncherModel?) -> [URL] {
        guard let bundleID else { return [] }
        var copies = installedCopies(bundleID)
        copies += model?.applications.copies[bundleID] ?? []
        copies += running.controller.runningApplications().filter { $0.bundleID == bundleID }.compactMap(\.bundleURL)
        return copies
    }
    /// The files an uninstall would move now: the app, then the support files ticked.
    func filesToTrash(for plan: UninstallPlan) -> [URL] {
        let chosen = selection.included[plan.app.url.path] ?? []
        return [plan.app.url] + plan.supportFiles.filter { chosen.contains($0.path) }
    }

    /// One file an uninstall will move, as it was when the review was built.
    struct ReviewedFile: Equatable {
        var url: URL
        var identity: FileIdentity
    }

    /// The app and the chosen support files, with the identities the review captured. Nil when
    /// a chosen file had no identity then.
    func reviewedFiles(for plan: UninstallPlan) -> [ReviewedFile]? {
        guard let appIdentity = plan.appIdentity else { return nil }
        var files = [ReviewedFile(url: plan.app.url, identity: appIdentity)]
        for url in filesToTrash(for: plan).dropFirst() {
            guard let identity = plan.supportIdentities[url.path] else { return nil }
            files.append(ReviewedFile(url: url, identity: identity))
        }
        return files
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
        let plan = plan(for: app, in: model)
        // What's moved is what the review showed, checked against disk before asking and again on approval.
        guard let reviewed = reviewedFiles(for: plan), revalidate(plan, reviewed: reviewed, in: model) == nil else {
            let problem =
                reviewedFiles(for: plan).flatMap { revalidate(plan, reviewed: $0, in: model) }
                ?? "\(app.name) changed since you opened its review."
            plans[app.url.path] = nil
            model.feedback = .warning(problem)
            return
        }
        let extra = reviewed.count - 1
        let question = CommandConfirmation(
            question: extra == 0
                ? "Move \(app.name) to the Trash?" : "Move \(app.name) and \(extra) support file\(extra == 1 ? "" : "s") to the Trash?",
            detail: "You can put them back from the Trash until you empty it.", confirmTitle: "Uninstall",
            symbol: "trash", isDestructive: true)
        model.askConfirmation(ProvidedConfirmation(id: "applications.uninstall.\(app.url.path)", question) {
            [weak self, weak model] in
            guard let self, let model else { return }
            self.uninstall(plan, reviewed: reviewed, in: model)
        })
    }

    /// Why the reviewed list can't be moved as reviewed, or nil when it still matches: the app
    /// isn't running, it's still the same app bundle with the same bundle id, every file is the
    /// one reviewed and still inside Library, and no other copy now shares the support files.
    func revalidate(_ plan: UninstallPlan, reviewed: [ReviewedFile], in model: LauncherModel?) -> String? {
        let app = plan.app
        let again = " Nothing was moved; review \(app.name) again."
        if running.isRunning(app)
            || running.controller.runningApplications().contains(where: {
                $0.bundleURL.map { RunningApplications.isSameBundle($0, app.url) } ?? false
            })
        {
            return "\(app.name) is running now. Quit it, then review it again."
        }
        if let refusal = UninstallPlan.refusal(for: app, ownBundleID: running.ownBundleID) { return refusal }
        guard let reviewedID = plan.bundleID, UninstallPlan.bundleIdentifier(at: app.url) == reviewedID else {
            return "\(app.name) was replaced since you reviewed it." + again
        }
        for file in reviewed where !file.identity.isSameItem(as: FileIdentity.of(file.url)) {
            return "“\(file.url.lastPathComponent)” changed since you reviewed it." + again
        }
        let support = reviewed.dropFirst()
        if !support.isEmpty {
            if !UninstallPlan.others(than: app.url, in: copies(of: reviewedID, in: model)).isEmpty {
                return "Another copy of \(app.name) is installed now, so its support files are shared." + again
            }
            for file in support where !UninstallPlan.isContained(file.url, in: library) {
                return "“\(file.url.lastPathComponent)” isn't inside your Library folder anymore." + again
            }
        }
        return nil
    }

    /// Moves the reviewed app and support files to the Trash after checking nothing changed,
    /// and checks each one again right before it moves.
    func uninstall(_ plan: UninstallPlan, reviewed: [ReviewedFile], in model: LauncherModel) {
        let app = plan.app
        plans[app.url.path] = nil
        if let problem = revalidate(plan, reviewed: reviewed, in: model) {
            model.feedback = .warning(problem)
            return
        }
        var failed: [String] = []
        var moved = 0
        for (index, file) in reviewed.enumerated() {
            do {
                guard file.identity.isSameItem(as: FileIdentity.of(file.url)) else {
                    throw FileWorkspaceError.refused("move a file that changed")
                }
                try workspace.trash(file.url)
                moved += 1
            } catch {
                // Without the app itself, the support files stay.
                if index == 0 {
                    model.feedback = .error("Couldn't move \(app.name) to the Trash. \(error.localizedDescription)")
                    return
                }
                failed.append(file.url.lastPathComponent)
            }
        }
        selection.included[app.url.path] = nil
        Task { await model.applications.refresh() }
        if case .provided(let scope) = model.section, scope.id == Self.reviewScopeID { model.leaveScope() }
        if failed.isEmpty {
            model.toast("Moved \(app.name)\(moved > 1 ? " and \(moved - 1) support files" : "") to the Trash")
        } else {
            model.feedback = .warning(
                "Moved \(app.name) to the Trash. \(failed.count) support file\(failed.count == 1 ? "" : "s") stayed: \(failed.prefix(3).joined(separator: ", ")).")
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
