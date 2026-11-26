import AppKit
import Foundation
import Testing

@testable import OpenRay

/// Running apps that live in a list, and record every action instead of performing it.
@MainActor
final class FakeRunningApplications: RunningApplicationControlling {
    var apps: [RunningApp]
    private(set) var hidden: [pid_t] = []
    private(set) var quit: [pid_t] = []
    private(set) var forceQuit: [pid_t] = []
    private(set) var opened: [URL] = []
    /// Quitting removes the app from the list, as a real quit eventually does.
    var quitRemoves = true
    var failing: Set<pid_t> = []

    init(_ apps: [RunningApp]) { self.apps = apps }

    func runningApplications() -> [RunningApp] { apps }

    func hide(_ app: RunningApp) throws {
        if failing.contains(app.pid) { throw RunningApplicationError.refused(app.name, action: "hide") }
        hidden.append(app.pid)
    }

    func quit(_ app: RunningApp) throws {
        if failing.contains(app.pid) { throw RunningApplicationError.refused(app.name, action: "quit") }
        quit.append(app.pid)
        if quitRemoves { apps.removeAll { $0.pid == app.pid } }
    }

    func forceQuit(_ app: RunningApp) throws {
        forceQuit.append(app.pid)
        apps.removeAll { $0.pid == app.pid }
    }

    func open(_ url: URL) async throws { opened.append(url) }
}

@MainActor
struct ApplicationsTests {
    private let own = "com.example.OpenRayTests"
    private let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")

    private func running(_ pid: pid_t, _ bundleID: String, _ name: String, active: Bool = false, regular: Bool = true)
        -> RunningApp
    {
        RunningApp(
            pid: pid, bundleID: bundleID, name: name, bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            launchDate: Date(timeIntervalSince1970: 1_000), isActive: active, isRegular: regular)
    }

    private func setUp(_ apps: [RunningApp], now: @escaping @MainActor () -> Date = { .now }) -> (
        LauncherModel, FakeRunningApplications, FakeFileWorkspace, ApplicationsCommandProvider
    ) {
        let controller = FakeRunningApplications(apps)
        let workspace = FakeFileWorkspace()
        let provider = ApplicationsCommandProvider(
            controller: controller, workspace: workspace, sideEffects: SideEffectGuard(mode: .testHost),
            library: FileManager.default.temporaryDirectory.appending(path: "NoLibrary-\(UUID())"), ownBundleID: own,
            now: now)
        provider.running.sleep = { _ in await Task.yield() }
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), registry: CommandRegistry(providers: [provider]))
        return (model, controller, workspace, provider)
    }

    private func appItem(_ app: InstalledApplication) -> LauncherItem {
        LauncherItem(
            id: app.id, title: app.name, subtitle: "", symbol: "app", kind: .system, badge: "Application",
            iconURL: app.url, action: .application(app))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayApps-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Running-app actions

    @Test func runningAppsOfferHideQuitForceQuitAndRestartWithRaycastKeys() throws {
        let (model, controller, _, _) = setUp([running(10, "com.apple.Safari", "Safari")])
        let safari = InstalledApplication(name: "Safari", url: safariURL, bundleIdentifier: "com.apple.Safari")
        let entries = model.actions(for: appItem(safari))
        func entry(_ id: String) throws -> ActionEntry { try #require(entries.first { $0.id == id }) }
        #expect(try entry("hideApp").modifiers == [.command, .shift])
        #expect(try entry("hideApp").key == "h")
        #expect(try entry("quitApp").modifiers == [.control, .shift])
        #expect(try entry("forceQuitApp").modifiers == [.control, .option, .shift])
        #expect(try entry("restartApp").modifiers == .command)
        #expect(try entry("packageContents").modifiers == [.command, .option])
        // ⇧⌘C copies the bundle id, so Copy Path moves to ⌥⌘C.
        #expect(try entry("copyBundleID").modifiers == [.command, .shift])
        #expect(try entry("copyPath").modifiers == [.command, .option])
        #expect(entries.filter { $0.key == "c" && $0.modifiers == [.command, .shift] }.count == 1)

        try entry("hideApp").perform()
        #expect(controller.hidden == [10])
        try entry("quitApp").perform()
        #expect(controller.quit == [10])
        #expect(model.feedback?.text == "Quit Safari")
    }

    @Test func forceQuitAsksFirst() throws {
        let (model, controller, _, _) = setUp([running(10, "com.apple.Safari", "Safari")])
        let safari = InstalledApplication(name: "Safari", url: safariURL, bundleIdentifier: "com.apple.Safari")
        try #require(model.actions(for: appItem(safari)).first { $0.id == "forceQuitApp" }).perform()
        #expect(controller.forceQuit.isEmpty)
        guard case .provided(let question)? = model.confirmation else {
            Issue.record("Force Quit didn't ask")
            return
        }
        #expect(question.question == "Force quit Safari?")
        model.performSelected()
        #expect(controller.forceQuit == [10])
    }

    @Test func appsThatArentRunningOfferNoRunningActions() {
        let (model, _, _, _) = setUp([])
        let notes = InstalledApplication(name: "Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app"), bundleIdentifier: "com.apple.Notes")
        let ids = model.actions(for: appItem(notes)).map(\.id)
        #expect(!ids.contains("quitApp") && !ids.contains("hideApp") && !ids.contains("restartApp"))
        #expect(ids.contains("packageContents") && ids.contains("hideFromSearch") && ids.contains("autoQuit"))
        // System apps can't be uninstalled.
        #expect(!ids.contains("uninstall"))
    }

    @Test func showPackageContentsOpensTheContentsFolder() throws {
        let (model, _, workspace, _) = setUp([])
        let app = InstalledApplication(name: "Tool", url: URL(fileURLWithPath: "/Applications/Tool.app"), bundleIdentifier: "com.example.tool")
        try #require(model.actions(for: appItem(app)).first { $0.id == "packageContents" }).perform()
        #expect(workspace.shownFolders.map(\.path) == ["/Applications/Tool.app/Contents"])
    }

    @Test func restartWaitsForTheAppToQuitThenOpensIt() async throws {
        let (_, controller, _, provider) = setUp([running(10, "com.apple.Safari", "Safari")])
        let safari = InstalledApplication(name: "Safari", url: safariURL, bundleIdentifier: "com.apple.Safari")
        try await provider.running.restart(safari)
        #expect(controller.quit == [10])
        #expect(controller.opened == [safariURL])

        // An app that won't quit (it's asking to save) isn't opened twice.
        controller.apps = [running(11, "com.apple.Safari", "Safari")]
        controller.quitRemoves = false
        provider.running.restartTimeout = .milliseconds(300)
        await #expect(throws: RunningApplicationError.stillRunning("Safari")) { try await provider.running.restart(safari) }
        #expect(controller.opened == [safariURL])
    }

    @Test func openRayNeverQuitsItself() {
        let (_, controller, _, provider) = setUp([running(5, own, "OpenRay")])
        let me = InstalledApplication(name: "OpenRay", url: URL(fileURLWithPath: "/Applications/OpenRay.app"), bundleIdentifier: own)
        #expect(throws: RunningApplicationError.protected("OpenRay")) { try provider.running.quit(me) }
        #expect(throws: RunningApplicationError.protected("OpenRay")) { try provider.running.forceQuit(me) }
        #expect(controller.quit.isEmpty && controller.forceQuit.isEmpty)
    }

    @Test func hideAllAndQuitAllSkipExclusionsOpenRayFinderAndHelpers() throws {
        let apps = [
            running(1, "com.apple.Safari", "Safari"), running(2, "com.apple.mail", "Mail"),
            running(3, "com.apple.finder", "Finder"), running(4, own, "OpenRay"),
            running(5, "com.example.helper", "Helper", regular: false), running(6, "com.apple.Music", "Music"),
        ]
        let (model, controller, _, provider) = setUp(apps)
        #expect(provider.running.batchTargets(keeping: ["com.apple.Music"], quitting: true).map(\.pid) == [1, 2])
        #expect(provider.running.batchTargets(keeping: ["com.apple.Music"], quitting: false).map(\.pid) == [1, 2, 3])
        #expect(provider.running.hideAll(keeping: ["com.apple.Music"]).acted == ["Safari", "Mail", "Finder"])
        #expect(controller.hidden == [1, 2, 3])

        // Quit All from the Applications scope asks first and keeps the apps chosen in Settings.
        model.updateApplicationSettings { $0.keepRunningBundleIDs = ["com.apple.Music"] }
        model.navigate(to: .applications)
        let quitAll = try #require(model.actions(for: nil).first { $0.id == "apps.quitAll" })
        quitAll.perform()
        #expect(controller.quit.isEmpty)
        guard case .provided(let question)? = model.confirmation else {
            Issue.record("Quit All didn't ask")
            return
        }
        #expect(question.question == "Quit 2 apps?")
        #expect(question.detail.hasPrefix("Safari, Mail."))
        model.performSelected()
        #expect(controller.quit == [1, 2])
        #expect(model.feedback?.text == "Asked 2 apps to quit")
    }

    @Test func liveControllerIsInertInTestsAndVerification() {
        let app = RunningApp(pid: 999_999, bundleID: "com.example.none", name: "None", bundleURL: nil, launchDate: nil)
        for mode in [SideEffectGuard.Mode.testHost, .verification] {
            let live = LiveRunningApplications(sideEffects: SideEffectGuard(mode: mode))
            #expect(throws: SideEffectGuard.Blocked.self) { try live.hide(app) }
            #expect(throws: SideEffectGuard.Blocked.self) { try live.quit(app) }
            #expect(throws: SideEffectGuard.Blocked.self) { try live.forceQuit(app) }
            let workspace = LiveFileWorkspace(sideEffects: SideEffectGuard(mode: mode))
            #expect(throws: SideEffectGuard.Blocked.self) { try workspace.trash(URL(fileURLWithPath: "/tmp/none")) }
            #expect(throws: SideEffectGuard.Blocked.self) { try workspace.showFolder(URL(fileURLWithPath: "/tmp")) }
        }
    }

    // MARK: Auto Quit

    @Test func autoQuitQuitsIdleAppsAfterTheirTime() {
        var clock = Date(timeIntervalSince1970: 10_000)
        let apps = [
            running(1, "com.example.chat", "Chat"), running(2, "com.example.editor", "Editor", active: true),
            running(3, "com.apple.finder", "Finder"), running(4, own, "OpenRay"), running(5, "com.example.other", "Other"),
        ]
        let (model, controller, _, provider) = setUp(apps, now: { clock })
        model.updateApplicationSettings { settings in
            settings.autoQuit = [
                "com.example.chat": Int?.none, "com.example.editor": 1, "com.apple.finder": 1,
                own: 1,
            ]
        }
        let autoQuit = provider.autoQuit
        #expect(model.applicationSettings.autoQuitMinutes(for: "com.example.chat") == 3)

        // The first check starts each clock.
        #expect(autoQuit.check().isEmpty)
        clock += 2 * 60 + 59
        #expect(autoQuit.check().isEmpty)
        // Chat follows the 3-minute default; Editor stays while it's frontmost.
        clock += 1
        #expect(autoQuit.check().map(\.name) == ["Chat"])
        #expect(controller.quit == [1])

        // Leaving the front starts Editor's 1-minute clock.
        controller.apps = controller.apps.map { app in
            var app = app
            if app.pid == 2 { app.isActive = false }
            return app
        }
        autoQuit.noteDeactivated(2)
        clock += 59
        #expect(autoQuit.check().isEmpty)
        clock += 1
        #expect(autoQuit.check().map(\.name) == ["Editor"])
        // The Finder, OpenRay and apps without Auto Quit never quit.
        clock += 3_600
        #expect(autoQuit.check().isEmpty)
        #expect(controller.quit == [1, 2])
        #expect(!autoQuit.canAutoQuit("com.apple.finder") && !autoQuit.canAutoQuit(own))
    }

    @Test func autoQuitRetriesLaterWhenAnAppDoesntQuit() {
        var clock = Date(timeIntervalSince1970: 0)
        let (model, controller, _, provider) = setUp([running(1, "com.example.chat", "Chat")], now: { clock })
        model.updateApplicationSettings { $0.autoQuit = ["com.example.chat": .some(1)] }
        controller.quitRemoves = false
        provider.autoQuit.check()
        clock += 60
        #expect(provider.autoQuit.check().count == 1)
        // Asked once; the clock starts again rather than asking every check.
        clock += 30
        #expect(provider.autoQuit.check().isEmpty)
        clock += 30
        #expect(provider.autoQuit.check().count == 1)
    }

    @Test func autoQuitDoesntRunInTheTestHost() {
        let (_, _, _, provider) = setUp([])
        provider.autoQuit.start(sideEffects: SideEffectGuard(mode: .testHost))
        #expect(!provider.autoQuit.isRunning)
        provider.autoQuit.start(sideEffects: SideEffectGuard(mode: .verification))
        #expect(!provider.autoQuit.isRunning)
    }

    @Test func autoQuitToggleFromTheActionPanel() throws {
        let (model, _, _, _) = setUp([])
        let app = InstalledApplication(name: "Chat", url: URL(fileURLWithPath: "/Applications/Chat.app"), bundleIdentifier: "com.example.chat")
        let enable = try #require(model.actions(for: appItem(app)).first { $0.id == "autoQuit" })
        #expect(enable.title == "Enable Auto Quit")
        enable.perform()
        #expect(model.applicationSettings.autoQuitMinutes(for: "com.example.chat") == 3)
        let disable = try #require(model.actions(for: appItem(app)).first { $0.id == "autoQuit" })
        #expect(disable.title == "Disable Auto Quit")
        disable.perform()
        #expect(model.applicationSettings.autoQuitMinutes(for: "com.example.chat") == nil)
    }

    // MARK: Uninstall

    @Test func uninstallListsOnlyTheAppsOwnSupportFiles() throws {
        let library = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let manager = FileManager.default
        func make(_ path: String, directory: Bool = true) throws {
            let url = library.appending(path: path)
            try manager.createDirectory(at: directory ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !directory { try Data().write(to: url) }
        }
        try make("Application Support/com.example.x")
        try make("Application Support/XApp")
        try make("Application Support/Other")
        try make("Caches/com.example.x")
        try make("Preferences/com.example.x.plist", directory: false)
        try make("Preferences/com.example.xy.plist", directory: false)
        try make("Preferences/ByHost/com.example.x.ABC123.plist", directory: false)
        try make("Containers/com.example.x")
        try make("Group Containers/TEAM42.com.example.x")
        try make("Group Containers/TEAM42.com.example.xy")
        try make("Saved Application State/com.example.x.savedState")
        try make("Logs/Unrelated")
        let files = UninstallPlan.supportFiles(bundleID: "com.example.x", appName: "XApp", library: library)
        let relative = Set(files.map { String($0.path.dropFirst(library.path.count + 1)) })
        #expect(
            relative == [
                "Application Support/com.example.x", "Application Support/XApp", "Caches/com.example.x",
                "Preferences/com.example.x.plist", "Preferences/ByHost/com.example.x.ABC123.plist",
                "Containers/com.example.x", "Group Containers/TEAM42.com.example.x",
                "Saved Application State/com.example.x.savedState",
            ])
        // A short name never matches folders by name.
        #expect(UninstallPlan.supportFiles(bundleID: nil, appName: "X", library: library).isEmpty)

        #expect(UninstallPlan.refusal(for: InstalledApplication(name: "Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app"), bundleIdentifier: "com.apple.Notes")) != nil)
        #expect(UninstallPlan.refusal(for: InstalledApplication(name: "Pages", url: URL(fileURLWithPath: "/Applications/Pages.app"), bundleIdentifier: "com.apple.iWork.Pages")) != nil)
        #expect(UninstallPlan.refusal(for: InstalledApplication(name: "Me", url: URL(fileURLWithPath: "/Applications/Me.app"), bundleIdentifier: own), ownBundleID: own) != nil)
        #expect(UninstallPlan.refusal(for: InstalledApplication(name: "X", url: URL(fileURLWithPath: "/Applications/X.app"), bundleIdentifier: "com.example.x")) == nil)
    }

    @Test func uninstallReviewsFilesThenTrashesTheIncludedOnes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "Library")
        let appURL = root.appending(path: "XApp.app")
        try FileManager.default.createDirectory(at: appURL.appending(path: "Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.x", "CFBundleName": "XApp"], format: .xml, options: 0
        ).write(to: appURL.appending(path: "Contents/Info.plist"))
        for path in ["Caches/com.example.x", "Containers/com.example.x"] {
            try FileManager.default.createDirectory(at: library.appending(path: path), withIntermediateDirectories: true)
        }
        let controller = FakeRunningApplications([])
        let workspace = FakeFileWorkspace()
        let provider = ApplicationsCommandProvider(
            controller: controller, workspace: workspace, sideEffects: SideEffectGuard(mode: .testHost), library: library,
            ownBundleID: own)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), registry: CommandRegistry(providers: [provider]))
        model.applications.standardRoots = []
        model.applications.includesFinder = false
        let app = InstalledApplication(name: "XApp", url: appURL, bundleIdentifier: "com.example.x")

        // ⌘K › Uninstall Application… opens the review list.
        try #require(model.actions(for: appItem(app)).first { $0.id == "uninstall" }).perform()
        #expect(model.section.providedScope?.id == ApplicationsCommandProvider.reviewScopeID)
        let rows = model.orderedResults
        #expect(rows.first?.title == "Uninstall XApp")
        #expect(rows.first?.subtitle == "2 of 2 support files included")
        #expect(Set(rows.dropFirst().map(\.title)) == ["com.example.x"])
        #expect(rows.dropFirst().allSatisfy { $0.badge == "Moves to Trash" })

        // ↩ on a file leaves it out.
        let caches = try #require(rows.first { $0.subtitle == "~/Library/Caches" })
        model.perform(caches)
        #expect(model.orderedResults.first?.subtitle == "1 of 2 support files included")
        #expect(model.orderedResults.first { $0.subtitle == "~/Library/Caches" }?.badge == "Left Out")

        // ↩ on the app asks, then moves the app and the included file.
        model.perform(try #require(model.orderedResults.first))
        #expect(workspace.trashed.isEmpty)
        guard case .provided(let question)? = model.confirmation else {
            Issue.record("Uninstall didn't ask")
            return
        }
        #expect(question.question == "Move XApp and 1 support file to the Trash?")
        model.performSelected()
        #expect(workspace.trashed.map(\.lastPathComponent) == ["XApp.app", "com.example.x"])
        #expect(workspace.trashed.last?.path.contains("Containers") == true)
        #expect(model.section == .home)
    }

    @Test func uninstallRefusesARunningApp() throws {
        let (model, controller, workspace, provider) = setUp([running(7, "com.example.x", "XApp")])
        _ = controller
        let app = InstalledApplication(name: "XApp", url: URL(fileURLWithPath: "/Applications/XApp.app"), bundleIdentifier: "com.example.x")
        provider.askToUninstall(app, in: model)
        #expect(model.confirmation == nil)
        #expect(model.feedback?.text == "Quit XApp before uninstalling it.")
        #expect(workspace.trashed.isEmpty)
    }

    // MARK: Catalog

    @Test func extraFoldersAreSearchedToTheChosenDepth() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ path: String, _ bundleID: String) throws {
            let contents = root.appending(path: path).appending(path: "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
        }
        try app("Alpha.app", "com.example.alpha")
        try app("Tools/Beta.app", "com.example.beta")
        try app("Tools/More/Gamma.app", "com.example.gamma")
        try app("Tools/More/Deeper/Delta.app", "com.example.delta")
        let shallow = ApplicationCatalog.scan(
            ApplicationScanConfiguration(extraFolders: [root], deepSearch: false), standardRoots: [], includesFinder: false)
        #expect(shallow.map(\.name) == ["Alpha"])
        let deep = ApplicationCatalog.scan(
            ApplicationScanConfiguration(extraFolders: [root], deepSearch: true), standardRoots: [], includesFinder: false)
        #expect(deep.map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(deep.first?.id == "app.com.example.alpha")

        // The model reads its folders from Settings, and hidden apps leave search.
        let (model, _, _, _) = setUp([])
        model.applications.standardRoots = []
        model.applications.includesFinder = false
        model.updateApplicationSettings {
            $0.extraFolders = [root.path]
            $0.deepSearch = true
        }
        await model.applications.refresh()
        #expect(model.applicationItems.map(\.title) == ["Alpha", "Beta", "Gamma"])
        let beta = try #require(model.applications.applications.first { $0.name == "Beta" })
        try #require(model.actions(for: appItem(beta)).first { $0.id == "hideFromSearch" }).perform()
        #expect(model.applicationSettings.hiddenAppIDs == ["app.com.example.beta"])
        #expect(model.applicationItems.map(\.title) == ["Alpha", "Gamma"])
        model.query = "beta"
        #expect(!model.results.contains { $0.id == "app.com.example.beta" })
    }

    @Test func applicationSettingsRoundTrip() {
        var settings = ApplicationSettings()
        #expect(settings.values.isEmpty)
        settings.extraFolders = ["/Volumes/Apps"]
        settings.deepSearch = true
        settings.hiddenAppIDs = ["app.com.example.a"]
        settings.autoQuit = ["com.example.a": Int?.none, "com.example.b": 10]
        settings.autoQuitDefaultMinutes = 5
        settings.keepRunningBundleIDs = ["com.apple.Music"]
        let decoded = ApplicationSettings(settings.values)
        #expect(decoded == settings)
        #expect(decoded.autoQuitMinutes(for: "com.example.a") == 5)
        #expect(decoded.autoQuitMinutes(for: "com.example.b") == 10)
        #expect(decoded.autoQuitMinutes(for: "com.example.c") == nil)
        // Out-of-range minutes fall back to the default.
        #expect(ApplicationSettings(["autoQuit": "com.example.a=7", "autoQuitMinutes": "4"]).autoQuitMinutes(for: "com.example.a") == 3)
    }

    @Test func registrationsAcceptAppAndCommandBindings() {
        let registration = ApplicationsCommandProvider.registration
        #expect(registration.acceptsBinding("app.com.apple.Safari"))
        #expect(registration.acceptsBinding(ApplicationsCommandProvider.uninstallID))
        #expect(!registration.acceptsBinding("apple.thing"))
        #expect(ScreenshotsCommandProvider.registration.acceptsBinding(ScreenshotsCommandProvider.pasteLatestID))
        #expect(CommandProviders.all.map(\.id).contains("applications"))
    }

    @Test func manageAutoQuitOpensTheApplicationsPane() throws {
        let (model, _, _, _) = setUp([])
        var opened: SettingsPane?
        model.presentSettings = { pane, _ in opened = pane }
        let command = try #require(model.commandItems.first { $0.id == ApplicationsCommandProvider.autoQuitID })
        model.perform(command)
        #expect(opened == .applications)
        #expect(SettingsPane.primary.contains(.applications) && SettingsPane.primary.contains(.screenshots))
    }
}
