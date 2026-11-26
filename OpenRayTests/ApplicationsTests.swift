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
        provider.installedCopies = { _ in [] }
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

    /// A real, minimal app bundle: an APPL Info.plist and an executable.
    @discardableResult
    private func makeApp(_ url: URL, bundleID: String, name: String) throws -> InstalledApplication {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundlePackageType": "APPL",
            "CFBundleExecutable": name,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let executable = contents.appending(path: "MacOS/\(name)")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return InstalledApplication(name: name, url: url, bundleIdentifier: bundleID)
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

    @Test func forceQuitAsksFirstAndActsOnlyOnTheProcessItNamed() throws {
        let (model, controller, _, _) = setUp([running(10, "com.apple.Safari", "Safari")])
        let safari = InstalledApplication(name: "Safari", url: safariURL, bundleIdentifier: "com.apple.Safari")
        let forceQuit = try #require(model.actions(for: appItem(safari)).first { $0.id == "forceQuitApp" })
        forceQuit.perform()
        #expect(controller.forceQuit.isEmpty)
        guard case .provided(let question)? = model.confirmation else {
            Issue.record("Force Quit didn't ask")
            return
        }
        #expect(question.question == "Force quit Safari?")
        model.performSelected()
        #expect(controller.forceQuit == [10])

        // Relaunched while the prompt was up: the new process isn't the one that was named.
        controller.apps = [running(11, "com.apple.Safari", "Safari")]
        forceQuit.perform()
        controller.apps = [
            RunningApp(
                pid: 12, bundleID: "com.apple.Safari", name: "Safari", bundleURL: safariURL,
                launchDate: Date(timeIntervalSince1970: 2_000))
        ]
        model.performSelected()
        #expect(controller.forceQuit == [10])
        #expect(model.feedback?.text == "Safari had already quit. Nothing else was touched.")
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

    @Test func hideAllAndQuitAllAskAndActOnlyOnTheListedApps() throws {
        let apps = [
            running(1, "com.apple.Safari", "Safari"), running(2, "com.apple.mail", "Mail"),
            running(3, "com.apple.finder", "Finder"), running(4, own, "OpenRay"),
            running(5, "com.example.helper", "Helper", regular: false), running(6, "com.apple.Music", "Music"),
        ]
        let (model, controller, _, provider) = setUp(apps)
        #expect(provider.running.batchTargets(keeping: ["com.apple.Music"], quitting: true).map(\.pid) == [1, 2])
        #expect(provider.running.batchTargets(keeping: ["com.apple.Music"], quitting: false).map(\.pid) == [1, 2, 3])

        model.updateApplicationSettings { $0.keepRunningBundleIDs = ["com.apple.Music"] }
        model.navigate(to: .applications)

        // Hide All asks first too.
        try #require(model.actions(for: nil).first { $0.id == "apps.hideAll" }).perform()
        #expect(controller.hidden.isEmpty)
        guard case .provided(let hideQuestion)? = model.confirmation else {
            Issue.record("Hide All didn't ask")
            return
        }
        #expect(hideQuestion.question == "Hide 3 apps?")
        model.performSelected()
        #expect(controller.hidden == [1, 2, 3])

        // Quit All names its apps; one opened while it asks, and one kept meanwhile, are left alone.
        try #require(model.actions(for: nil).first { $0.id == "apps.quitAll" }).perform()
        #expect(controller.quit.isEmpty)
        guard case .provided(let question)? = model.confirmation else {
            Issue.record("Quit All didn't ask")
            return
        }
        #expect(question.question == "Quit 2 apps?")
        #expect(question.detail.hasPrefix("Safari, Mail."))
        controller.apps.append(running(7, "com.example.new", "New"))
        model.updateApplicationSettings { $0.keepRunningBundleIDs = ["com.apple.Music", "com.apple.mail"] }
        model.performSelected()
        #expect(controller.quit == [1])
        #expect(model.feedback?.text == "Asked 1 app to quit")
    }

    @Test func liveAdaptersStayInertEvenWithALiveRuleInjected() throws {
        // Every target below is a path or process that doesn't exist, so even a broken guard
        // could change nothing on this Mac. The assertions check that the guard refused first.
        let nowhere = URL(fileURLWithPath: "/OpenRayTestsNoSuchFolder-\(UUID())/none")
        let app = RunningApp(pid: 999_999, bundleID: "com.example.none", name: "None", bundleURL: nil, launchDate: nil)
        for mode in [SideEffectGuard.Mode.testHost, .verification, .live] {
            let live = LiveRunningApplications(sideEffects: SideEffectGuard(mode: mode))
            #expect(throws: SideEffectGuard.Blocked.self) { try live.hide(app) }
            #expect(throws: SideEffectGuard.Blocked.self) { try live.quit(app) }
            #expect(throws: SideEffectGuard.Blocked.self) { try live.forceQuit(app) }
            let workspace = LiveFileWorkspace(sideEffects: SideEffectGuard(mode: mode))
            #expect(throws: SideEffectGuard.Blocked.self) { try workspace.trash(nowhere) }
            #expect(throws: SideEffectGuard.Blocked.self) { try workspace.showFolder(nowhere) }
            #expect(throws: SideEffectGuard.Blocked.self) { try workspace.share(nowhere, via: ShareTarget(id: "none", title: "None", symbol: "")) }
            // Listing a folder outside the fixtures is refused before it's opened.
            let reader = LiveFolderReader(sideEffects: SideEffectGuard(mode: mode))
            #expect(throws: SideEffectGuard.Blocked.self) {
                try reader.contents(of: nowhere.deletingLastPathComponent(), includingHidden: false, limit: 10)
            }
            let autoQuit = AutoQuit(running: RunningApplications(controller: FakeRunningApplications([])), settings: { ApplicationSettings() })
            autoQuit.start(sideEffects: SideEffectGuard(mode: mode))
            #expect(!autoQuit.isRunning)
            let index = ScreenshotIndex(recognizer: FakeScreenshotRecognizer(), sideEffects: SideEffectGuard(mode: mode))
            #expect(index.folders(ScreenshotSettings()).isEmpty)
        }
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        #expect(try LiveFolderReader().contents(of: fixture, includingHidden: false, limit: 10).isEmpty)
        #expect(SideEffectGuard.atLeastCurrent(SideEffectGuard(mode: .live)).isInert)
        #expect(SideEffectGuard.atLeastCurrent(SideEffectGuard(mode: .verification)).mode == .verification)
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

    @Test func optingInStartsAFreshClock() {
        var clock = Date(timeIntervalSince1970: 0)
        let (model, controller, _, provider) = setUp(
            [running(1, "com.example.chat", "Chat"), running(2, "com.example.mail", "Mail", active: true)], now: { clock })
        // Another app's rule keeps Auto Quit checking while Chat isn't opted in.
        model.updateApplicationSettings { $0.autoQuit = ["com.example.mail": 15] }
        provider.autoQuit.noteDeactivated(1)
        provider.autoQuit.check()
        clock += 3_600
        provider.autoQuit.check()
        // Opting in now must not count the hour Chat already spent in the background.
        model.updateApplicationSettings { $0.autoQuit["com.example.chat"] = 1 }
        #expect(provider.autoQuit.check().isEmpty)
        clock += 59
        #expect(provider.autoQuit.check().isEmpty)
        clock += 1
        #expect(provider.autoQuit.check().map(\.name) == ["Chat"])
        #expect(controller.quit == [1])
    }

    // MARK: Uninstall

    @Test func uninstallOffersOnlyFilesProvenToBelongToTheApp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "Library")
        let manager = FileManager.default
        func make(_ path: String, directory: Bool = true) throws {
            let url = library.appending(path: path)
            try manager.createDirectory(at: directory ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !directory { try Data().write(to: url) }
        }
        try make("Application Support/com.example.x")
        try make("Application Support/XApp")
        try make("Caches/com.example.x")
        try make("Preferences/com.example.x.plist", directory: false)
        try make("Preferences/com.example.xy.plist", directory: false)
        try make("Preferences/ByHost/com.example.x.ABC123.plist", directory: false)
        try make("Containers/com.example.x")
        try make("Group Containers/TEAM42.com.example.x")
        try make("Saved Application State/com.example.x.savedState")
        // A Logs folder that's really a link elsewhere doesn't count as inside Library.
        let outside = root.appending(path: "Elsewhere/com.example.x")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: library.appending(path: "Logs"), withDestinationURL: root.appending(path: "Elsewhere"))
        let files = UninstallPlan.supportFiles(bundleID: "com.example.x", library: library)
        let relative = Set(files.map { String($0.path.dropFirst(library.path.count + 1)) })
        // Named only by the app (XApp) or shared (group containers): never offered.
        #expect(
            relative == [
                "Application Support/com.example.x", "Caches/com.example.x", "Preferences/com.example.x.plist",
                "Preferences/ByHost/com.example.x.ABC123.plist", "Containers/com.example.x",
                "Saved Application State/com.example.x.savedState",
            ])
        // Bundle ids that could climb out of Library are refused.
        for id in ["../Documents", "com.example/../../x", "..", "nodots", "com.example.x/"] {
            #expect(UninstallPlan.supportFiles(bundleID: id, library: library).isEmpty)
        }
        #expect(UninstallPlan.supportFiles(bundleID: nil, library: library).isEmpty)

        // Another installed copy shares the files, so none are offered.
        let app = InstalledApplication(name: "XApp", url: root.appending(path: "XApp.app"), bundleIdentifier: "com.example.x")
        let shared = UninstallPlan.make(for: app, library: library, otherCopies: [app.url, root.appending(path: "Copy/XApp.app")])
        #expect(shared.supportFiles.isEmpty)
        #expect(shared.supportFilesNote?.contains("Another copy") == true)
        #expect(UninstallPlan.make(for: app, library: library, otherCopies: [app.url]).supportFiles.count == 6)
    }

    @Test func onlyRealAppBundlesCanBeUninstalled() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = try makeApp(root.appending(path: "Real.app"), bundleID: "com.example.real", name: "Real")
        let folder = root.appending(path: "Archive.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(UninstallPlan.refusal(for: real, ownBundleID: own) == nil)
        #expect(UninstallPlan.refusal(for: InstalledApplication(name: "Archive", url: folder, bundleIdentifier: nil)) != nil)
        #expect(UninstallPlan.refusal(for: InstalledApplication(name: "Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app"), bundleIdentifier: "com.apple.Notes")) != nil)
        #expect(UninstallPlan.refusal(for: InstalledApplication(name: "Pages", url: URL(fileURLWithPath: "/Applications/Pages.app"), bundleIdentifier: "com.apple.iWork.Pages")) != nil)
        #expect(UninstallPlan.refusal(for: InstalledApplication(name: "Me", url: real.url, bundleIdentifier: own), ownBundleID: own) != nil)
    }

    private func uninstallFixture() throws -> (
        root: URL, model: LauncherModel, controller: FakeRunningApplications, workspace: FakeFileWorkspace,
        provider: ApplicationsCommandProvider, app: InstalledApplication
    ) {
        let root = try temporaryDirectory()
        let library = root.appending(path: "Library")
        let app = try makeApp(root.appending(path: "XApp.app"), bundleID: "com.example.x", name: "XApp")
        for path in ["Caches/com.example.x", "Containers/com.example.x"] {
            try FileManager.default.createDirectory(at: library.appending(path: path), withIntermediateDirectories: true)
        }
        let controller = FakeRunningApplications([])
        let workspace = FakeFileWorkspace()
        let provider = ApplicationsCommandProvider(
            controller: controller, workspace: workspace, sideEffects: SideEffectGuard(mode: .testHost), library: library,
            ownBundleID: own)
        provider.installedCopies = { _ in [app.url] }
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), registry: CommandRegistry(providers: [provider]))
        model.applications.standardRoots = []
        model.applications.includesFinder = false
        return (root, model, controller, workspace, provider, app)
    }

    @Test func uninstallMovesOnlyWhatWasChosenAfterAsking() throws {
        let (root, model, _, workspace, _, app) = try uninstallFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        // ⌘K › Uninstall Application… opens the review list, with support files unticked.
        try #require(model.actions(for: appItem(app)).first { $0.id == "uninstall" }).perform()
        #expect(model.section.providedScope?.id == ApplicationsCommandProvider.reviewScopeID)
        let rows = model.orderedResults
        #expect(rows.first?.title == "Uninstall XApp")
        #expect(rows.first?.subtitle.hasPrefix("0 of 2 support files chosen") == true)
        #expect(rows.dropFirst().allSatisfy { $0.badge == "Left Out" })

        // ↩ on a file chooses it.
        let caches = try #require(rows.first { $0.subtitle == "~/Library/Caches" })
        model.perform(caches)
        #expect(model.orderedResults.first?.subtitle.hasPrefix("1 of 2 support files chosen") == true)
        #expect(model.orderedResults.first { $0.subtitle == "~/Library/Caches" }?.badge == "Moves to Trash")

        // ↩ on the app asks, then moves the app and the chosen file only.
        model.perform(try #require(model.orderedResults.first))
        #expect(workspace.trashed.isEmpty)
        guard case .provided(let question)? = model.confirmation else {
            Issue.record("Uninstall didn't ask")
            return
        }
        #expect(question.question == "Move XApp and 1 support file to the Trash?")
        model.performSelected()
        #expect(workspace.trashed.map(\.lastPathComponent) == ["XApp.app", "com.example.x"])
        #expect(workspace.trashed.last?.path.contains("Caches") == true)
        #expect(model.section == .home)
    }

    @Test func uninstallStopsWhenWhatWasReviewedChanged() throws {
        let (root, model, controller, workspace, provider, app) = try uninstallFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = provider.library.appending(path: "Caches/com.example.x")

        // A support file replaced while the prompt shows: nothing moves.
        provider.beginReview(of: app, in: model)
        provider.selection.included[app.url.path] = [caches.path]
        provider.askToUninstall(app, in: model)
        try FileManager.default.removeItem(at: caches)
        try Data("not the reviewed folder".utf8).write(to: caches)
        model.performSelected()
        #expect(workspace.trashed.isEmpty)
        #expect(model.feedback?.text.contains("changed since you reviewed it") == true)

        // The app launched while the prompt shows: nothing moves.
        provider.beginReview(of: app, in: model)
        provider.askToUninstall(app, in: model)
        controller.apps = [
            RunningApp(pid: 40, bundleID: "com.example.x", name: "XApp", bundleURL: app.url, launchDate: .now)
        ]
        model.performSelected()
        #expect(workspace.trashed.isEmpty)
        #expect(model.feedback?.text == "XApp is running now. Quit it, then review it again.")
    }

    @Test func uninstallRefusesARunningApp() throws {
        let (root, model, controller, workspace, provider, app) = try uninstallFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.apps = [RunningApp(pid: 7, bundleID: "com.example.x", name: "XApp", bundleURL: app.url, launchDate: nil)]
        provider.askToUninstall(app, in: model)
        #expect(model.confirmation == nil)
        #expect(model.feedback?.text == "Quit XApp before uninstalling it.")
        #expect(workspace.trashed.isEmpty)
    }

    @Test func anotherCopyOfTheSameAppIsNeverTouched() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, controller, _, provider) = setUp([])
        let mine = try makeApp(root.appending(path: "A/Tool.app"), bundleID: "com.example.tool", name: "Tool")
        let other = root.appending(path: "B/Tool.app")
        controller.apps = [RunningApp(pid: 9, bundleID: "com.example.tool", name: "Tool", bundleURL: other, launchDate: nil)]
        // The running copy is the other one, so this one offers no running actions.
        #expect(!provider.running.isRunning(mine))
        #expect(!model.actions(for: appItem(mine)).contains { $0.id == "forceQuitApp" })
        #expect(throws: RunningApplicationError.notRunning("Tool")) { try provider.running.quit(mine) }
        #expect(controller.quit.isEmpty)
    }

    // MARK: Catalog

    @Test func extraFoldersAreSearchedToTheChosenDepth() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ path: String, _ bundleID: String) throws {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            try makeApp(root.appending(path: path), bundleID: bundleID, name: name)
        }
        try app("Alpha.app", "com.example.alpha")
        try app("Tools/Beta.app", "com.example.beta")
        try app("Tools/More/Gamma.app", "com.example.gamma")
        try app("Tools/More/Deeper/Delta.app", "com.example.delta")
        // A plain folder named like an app isn't one.
        try FileManager.default.createDirectory(at: root.appending(path: "Archive.app"), withIntermediateDirectories: true)
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
