import Foundation
import Testing

@testable import OpenRay

@MainActor
struct SystemCommandsTests {
    private let mail = AppIdentity(
        pid: 4242, bundleIdentifier: "com.example.mail", name: "Mail", launchDate: Date(timeIntervalSince1970: 1_000))

    private var context: SystemCommandContext {
        SystemCommandContext(foregroundApplication: mail, excludedBundleIdentifiers: ["com.example.music"])
    }

    // MARK: Safety

    @Test func theTestHostNeverGetsALiveExecutor() async {
        #expect(SideEffectGuard.isTestHost)
        #expect(SideEffectGuard.isInert)
        let executor = SystemActionEnvironment.makeDefault()
        #expect(executor is InertSystemActions)
        #expect(!(executor is LiveSystemActions))
        #expect(LiveSystemActions.instanceCount == 0)
        await #expect(throws: SideEffectGuard.Blocked.self) { try await executor.perform(.lockScreen) }
        #expect(throws: SideEffectGuard.Blocked.self) { try SideEffectGuard.check("anything") }
        #expect(LiveSystemActions.instanceCount == 0)
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func everyValidCommandIsBlockedInInertLaunches(_ mode: SideEffectGuard.Mode) async {
        let executor = SystemActionEnvironment.makeDefault(sideEffects: SideEffectGuard(mode: mode))
        #expect(executor is InertSystemActions)
        for command in SystemCommand.all {
            await #expect(throws: SideEffectGuard.Blocked(what: "system commands", mode: mode), "\(command.id)") {
                _ = try await command.run(with: executor, argument: "50", context: context)
            }
        }
        #expect(LiveSystemActions.instanceCount == 0)
    }

    // MARK: Catalog

    @Test func theCatalogListsEveryCommandOnceWithMetadata() {
        let ids = SystemCommand.all.map(\.id)
        #expect(ids == SystemCommand.ID.allCases)
        #expect(Set(SystemCommand.all.map(\.title)).count == ids.count)
        for command in SystemCommand.all {
            #expect(!command.title.isEmpty && !command.subtitle.isEmpty && !command.symbol.isEmpty)
            #expect(!command.keywords.isEmpty)
            #expect(SystemCommand.command(command.id).title == command.title)
        }
        #expect(SystemCommand.ID.lockScreen.itemID == "system.lockScreen")
        for group in SystemCommand.Group.allCases {
            #expect(SystemCommand.all.contains { $0.group == group }, "\(group) is empty")
        }
    }

    @Test func onlyDestructiveCommandsAskForConfirmation() {
        let confirming = Set(SystemCommand.all.filter(\.needsConfirmation).map(\.id))
        #expect(
            confirming == [
                .restart, .shutDown, .logOut, .emptyTrash, .quitAllApps, .quitAllAppsExceptFrontmost, .hideOtherApps,
            ])
        for command in SystemCommand.all where command.needsConfirmation {
            #expect(command.confirmation?.title.hasSuffix("?") == true)
            #expect(command.confirmation?.button.isEmpty == false)
        }
        // Quit Others names the app it keeps.
        #expect(
            SystemCommand.command(.quitAllAppsExceptFrontmost).confirmation(for: context)?.title
                == "Quit every app except Mail?")
        #expect(SystemCommand.command(.lockScreen).confirmation(for: context) == nil)
    }

    @Test func permissionsAndLimitsAreDeclared() {
        func permission(_ id: SystemCommand.ID) -> SystemCommand.Permission { SystemCommand.command(id).permission }
        #expect(permission(.lockScreen) == .accessibility)
        #expect(permission(.playPause) == .accessibility)
        #expect(permission(.dismissNotifications) == .accessibility)
        #expect(permission(.toggleAppearance) == .automation("com.apple.systemevents"))
        #expect(permission(.emptyTrash) == .automation("com.apple.finder"))
        #expect(permission(.restart) == .automation("com.apple.loginwindow"))
        #expect(permission(.sleep) == SystemCommand.Permission.none)
        #expect(permission(.volumeUp) == SystemCommand.Permission.none)
        #expect(SystemCommand.command(.dismissNotifications).limitation != nil)
        #expect(SystemCommand.command(.showDesktop).limitation != nil)
        #expect(SystemCommand.command(.toggleWiFi).limitation?.contains("administrator") == true)
        #expect(SystemCommand.all.filter(\.takesArgument).map(\.id) == [.setVolume])
    }

    // MARK: Actions

    @Test func everyCommandMapsToItsAction() throws {
        let expected: [SystemCommand.ID: SystemAction] = [
            .lockScreen: .lockScreen, .sleep: .sleep, .sleepDisplays: .sleepDisplays, .restart: .restart,
            .shutDown: .shutDown, .logOut: .logOut, .startScreenSaver: .startScreenSaver,
            .playPause: .media(.playPause), .nextTrack: .media(.next), .previousTrack: .media(.previous),
            .volumeUp: .volume(.up), .volumeDown: .volume(.down), .toggleMute: .volume(.toggleMute),
            .setVolume: .volume(.set(0.4)), .setVolume0: .volume(.set(0)), .setVolume25: .volume(.set(0.25)),
            .setVolume50: .volume(.set(0.5)), .setVolume75: .volume(.set(0.75)), .setVolume100: .volume(.set(1)),
            .toggleMicrophoneMute: .toggleMicrophoneMute, .showDesktop: .showDesktop,
            .toggleAppearance: .toggleAppearance, .openTrash: .openTrash, .emptyTrash: .emptyTrash,
            .ejectAllDisks: .ejectAllDisks, .toggleHiddenFiles: .toggleHiddenFiles,
            .hideOtherApps: .hideOtherApps(keeping: mail), .unhideAllApps: .unhideApps,
            .quitAllApps: .quitAllApps(excluded: ["com.example.music"]),
            .quitAllAppsExceptFrontmost: .quitOtherApps(keeping: mail, excluded: ["com.example.music"]),
            .restartFrontmostApp: .restartApp(mail), .dismissNotifications: .dismissNotifications,
            .toggleWiFi: .toggleWiFi,
        ]
        #expect(Set(expected.keys) == Set(SystemCommand.ID.allCases))
        for command in SystemCommand.all {
            #expect(try command.action(argument: "40", context: context) == expected[command.id], "\(command.id)")
        }
    }

    @Test(arguments: [SystemCommand.ID.hideOtherApps, .quitAllAppsExceptFrontmost, .restartFrontmostApp])
    func commandsAboutTheFrontmostAppNeedOneThatIsNotOpenRay(_ id: SystemCommand.ID) {
        let command = SystemCommand.command(id)
        // No foreground app: never widened to every app.
        #expect(throws: LibraryValidationError.self) { try command.action(context: .init()) }
        let openRay = AppIdentity(
            pid: ProcessInfo.processInfo.processIdentifier, bundleIdentifier: Bundle.main.bundleIdentifier,
            name: "OpenRay", launchDate: nil)
        #expect(throws: LibraryValidationError.self) {
            try command.action(context: SystemCommandContext(foregroundApplication: openRay))
        }
    }

    @Test(arguments: [("50", 0.5), ("50%", 0.5), (" 75 % ", 0.75), ("0", 0.0), ("100", 1.0), ("12.5", 0.125)])
    func volumeArgumentsParse(_ text: String, _ level: Double) throws {
        #expect(try VolumeArgument.parse(text) == level)
    }

    @Test(arguments: ["101", "-1", "loud", "", "50%%", "nan"])
    func invalidVolumeArgumentsAreRejected(_ text: String) {
        #expect(throws: LibraryValidationError.self) { try VolumeArgument.parse(text) }
    }

    @Test func theExecutorRunsTheActionAndReturnsItsHUD() async throws {
        let performer = RecordingSystemActions()
        performer.result = .volume(0.5, muted: false)
        let hud = try await SystemCommand.command(.setVolume).run(with: performer, argument: "50%")
        #expect(performer.actions == [.volume(.set(0.5))])
        #expect(hud == HUDMessage("Volume 50%", symbol: "speaker.wave.2.fill"))
        performer.result = .done
        #expect(try await SystemCommand.command(.lockScreen).run(with: performer) == nil)
        #expect(performer.actions.last == .lockScreen)
        // A bad argument or a missing foreground app never reaches the executor.
        await #expect(throws: LibraryValidationError.self) {
            _ = try await SystemCommand.command(.setVolume).run(with: performer, argument: "200")
        }
        await #expect(throws: LibraryValidationError.self) {
            _ = try await SystemCommand.command(.quitAllAppsExceptFrontmost).run(with: performer)
        }
        #expect(performer.actions.count == 2)
    }

    // MARK: HUD

    @Test func hudMessagesDescribeTheResult() {
        func hud(_ id: SystemCommand.ID, _ result: SystemActionResult) -> String? {
            SystemCommand.command(id).hud(for: result)?.text
        }
        #expect(hud(.lockScreen, .done) == nil)
        #expect(hud(.sleep, .done) == nil)
        #expect(hud(.openTrash, .done) == nil)
        #expect(hud(.emptyTrash, .done) == "Trash emptied")
        #expect(hud(.volumeUp, .volume(0.5625, muted: false)) == "Volume 56%")
        #expect(hud(.volumeDown, .volume(0.2, muted: true)) == "Muted")
        #expect(hud(.toggleMute, .muted(true)) == "Muted")
        #expect(hud(.toggleMute, .muted(false)) == "Unmuted")
        #expect(hud(.toggleMicrophoneMute, .microphones(muted: true, changed: 1, unchanged: [])) == "Microphone muted")
        #expect(hud(.toggleMicrophoneMute, .microphones(muted: false, changed: 1, unchanged: [])) == "Microphone on")
        #expect(hud(.toggleMicrophoneMute, .microphones(muted: true, changed: 2, unchanged: [])) == "2 microphones muted")
        #expect(
            hud(.toggleMicrophoneMute, .microphones(muted: true, changed: 1, unchanged: ["USB Microphone"]))
                == "Muted 1 of 2 microphones. USB Microphone is still on")
        #expect(
            SystemCommand.command(.toggleMicrophoneMute).hud(
                for: .microphones(muted: true, changed: 1, unchanged: ["USB Microphone"]))?.style == .warning)
        #expect(hud(.toggleAppearance, .appearance(dark: true)) == "Dark appearance")
        #expect(hud(.toggleAppearance, .appearance(dark: false)) == "Light appearance")
        #expect(hud(.toggleHiddenFiles, .hiddenFiles(visible: true)) == "Showing hidden files")
        #expect(hud(.ejectAllDisks, .ejected(count: 0, failed: [])) == "No disks to eject")
        #expect(hud(.ejectAllDisks, .ejected(count: 1, failed: [])) == "Ejected 1 disk")
        #expect(hud(.ejectAllDisks, .ejected(count: 2, failed: [])) == "Ejected 2 disks")
        #expect(hud(.ejectAllDisks, .ejected(count: 1, failed: ["Backup"])) == "Couldn't eject Backup")
        #expect(hud(.hideOtherApps, .apps(count: 3)) == "Hid 3 apps")
        #expect(hud(.hideOtherApps, .apps(count: 0)) == "No other apps to hide")
        #expect(hud(.unhideAllApps, .apps(count: 1)) == "Unhid 1 app")
        #expect(hud(.quitAllApps, .apps(count: 4)) == "Quitting 4 apps")
        #expect(hud(.quitAllAppsExceptFrontmost, .apps(count: 0)) == "No apps to quit")
        #expect(hud(.restartFrontmostApp, .app("Mail")) == "Restarted Mail")
        #expect(hud(.dismissNotifications, .notifications(count: 0)) == "No notifications to dismiss")
        #expect(hud(.dismissNotifications, .notifications(count: 2)) == "Notifications dismissed")
        #expect(hud(.toggleWiFi, .wifi(on: false)) == "Wi-Fi off")
        #expect(SystemCommand.command(.ejectAllDisks).hud(for: .ejected(count: 0, failed: ["A"]))?.style == .warning)
        #expect(SystemCommand.command(.ejectAllDisks).hud(for: .ejected(count: 0, failed: []))?.style == .info)
    }

    @Test func volumeFormattingClampsAndPicksASymbol() {
        #expect(SystemCommand.percent(0.004) == "0%")
        #expect(SystemCommand.percent(1.4) == "100%")
        #expect(SystemCommand.volumeSymbol(0) == "speaker.fill")
        #expect(SystemCommand.volumeSymbol(0.2) == "speaker.wave.1.fill")
        #expect(SystemCommand.volumeSymbol(0.5) == "speaker.wave.2.fill")
        #expect(SystemCommand.volumeSymbol(0.9) == "speaker.wave.3.fill")
    }

    // MARK: Which apps change

    private var apps: [RunningAppInfo] {
        [
            RunningAppInfo(pid: 1, bundleIdentifier: "com.example.openray", name: "OpenRay", isRegular: true, isHidden: false),
            RunningAppInfo(pid: 2, bundleIdentifier: "com.apple.finder", name: "Finder", isRegular: true, isHidden: false),
            RunningAppInfo(
                pid: 4242, bundleIdentifier: "com.example.mail", name: "Mail", isRegular: true, isHidden: false,
                launchDate: Date(timeIntervalSince1970: 1_000)),
            RunningAppInfo(pid: 4, bundleIdentifier: "com.example.music", name: "Music", isRegular: true, isHidden: true),
            RunningAppInfo(pid: 5, bundleIdentifier: "com.example.helper", name: "Helper", isRegular: false, isHidden: false),
            RunningAppInfo(pid: 6, bundleIdentifier: nil, name: "Tool", isRegular: true, isHidden: false),
        ]
    }

    @Test func hideAndUnhideSkipOpenRayHelpersAndTheKeptApp() throws {
        #expect(try AppSelection.hideTargets(apps, keeping: mail, ownPID: 1).map(\.pid) == [2, 6])
        #expect(AppSelection.unhideTargets(apps, ownPID: 1).map(\.pid) == [4])
    }

    @Test func quitSkipsOpenRayFinderExclusionsAndTheKeptApp() throws {
        #expect(try AppSelection.quitTargets(apps, keeping: nil, excluded: [], ownPID: 1).map(\.pid) == [4242, 4, 6])
        #expect(
            try AppSelection.quitTargets(apps, keeping: mail, excluded: ["com.example.music"], ownPID: 1).map(\.pid)
                == [6])
    }

    @Test func aStaleOrReusedTargetChangesNothing() {
        // Mail quit and its PID now belongs to another app.
        var reused = apps
        reused[2] = RunningAppInfo(
            pid: 4242, bundleIdentifier: "com.example.other", name: "Other", isRegular: true, isHidden: false)
        #expect(throws: LibraryValidationError.self) {
            try AppSelection.quitTargets(reused, keeping: mail, excluded: [], ownPID: 1)
        }
        #expect(throws: LibraryValidationError.self) { try AppSelection.hideTargets(reused, keeping: mail, ownPID: 1) }
        // Mail quit and relaunched: same bundle, new launch.
        var relaunched = apps
        relaunched[2].launchDate = Date(timeIntervalSince1970: 2_000)
        #expect(throws: LibraryValidationError.self) {
            try AppSelection.quitTargets(relaunched, keeping: mail, excluded: [], ownPID: 1)
        }
        // Mail is gone entirely.
        #expect(throws: LibraryValidationError.self) {
            try AppSelection.hideTargets(apps.filter { $0.pid != 4242 }, keeping: mail, ownPID: 1)
        }
        // OpenRay itself can't be the app to keep.
        let openRay = AppIdentity(pid: 1, bundleIdentifier: "com.example.openray", name: "OpenRay", launchDate: nil)
        #expect(throws: LibraryValidationError.self) { try AppSelection.hideTargets(apps, keeping: openRay, ownPID: 1) }
    }

    @Test func aWindowTargetNeverReplacesTheForegroundApp() throws {
        // The window chip may point at another app's window; the context only carries
        // the app that was frontmost when the launcher opened.
        let foreground = SystemCommandContext(foregroundApplication: mail)
        let action = try SystemCommand.command(.quitAllAppsExceptFrontmost).action(context: foreground)
        #expect(action == .quitOtherApps(keeping: mail, excluded: []))
        #expect(try AppSelection.quitTargets(apps, keeping: mail, excluded: [], ownPID: 1).map(\.pid) == [4, 6])
    }

    // MARK: Pure helpers

    @Test func ejectingSelectsExternalImagesAndNetworkVolumesOnly() {
        func volume(
            _ path: String, ejectable: Bool = false, removable: Bool = false, local: Bool = true, root: Bool = false,
            browsable: Bool = true
        ) -> MountedVolume {
            MountedVolume(
                url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, isEjectable: ejectable,
                isRemovable: removable, isLocal: local, isRootFileSystem: root, isBrowsable: browsable)
        }
        let volumes = [
            volume("/", root: true),
            volume("/System/Volumes/Data", ejectable: true),
            volume("/Volumes/Backup", ejectable: true, removable: true),
            volume("/Volumes/Installer", ejectable: true),
            volume("/Volumes/Share", local: false),
            volume("/Volumes/Windows"),
            volume("/Volumes/Hidden", ejectable: true, browsable: false),
        ]
        #expect(EjectableVolumes.select(volumes).map(\.name) == ["Backup", "Installer", "Share"])
    }

    @Test func finderHiddenFilesPreferenceAcceptsEveryFinderSpelling() {
        #expect(FinderHiddenFiles.isOn(true))
        #expect(FinderHiddenFiles.isOn(NSNumber(value: 1)))
        #expect(FinderHiddenFiles.isOn("YES"))
        #expect(FinderHiddenFiles.isOn("true"))
        #expect(FinderHiddenFiles.isOn("1"))
        #expect(!FinderHiddenFiles.isOn("NO"))
        #expect(!FinderHiddenFiles.isOn(false))
        #expect(!FinderHiddenFiles.isOn(nil))
    }

    @Test func notificationDismissalPrefersClearAllThenClose() {
        let close = "Name:Close\nTarget:0x0\nSelector:(null)"
        let clearAll = "Name:Clear All\nTarget:0x0\nSelector:(null)"
        #expect(NotificationDismissal.title(ofAction: close) == "Close")
        #expect(NotificationDismissal.title(ofAction: "AXPress") == "AXPress")
        #expect(NotificationDismissal.dismissAction(in: ["AXPress", close, clearAll]) == clearAll)
        #expect(NotificationDismissal.dismissAction(in: ["AXPress", close]) == close)
        #expect(NotificationDismissal.dismissAction(in: ["AXPress", "Name:Show\nTarget:0x0"]) == nil)
    }

    @Test func helpersOnlySucceedWhenTheyExitCleanly() throws {
        try HelperExit.exited(0).check(tool: "pmset", acceptsTimeout: false)
        #expect(throws: LibraryValidationError.self) { try HelperExit.exited(1).check(tool: "pmset", acceptsTimeout: false) }
        #expect(throws: LibraryValidationError.self) { try HelperExit.signaled(9).check(tool: "pmset", acceptsTimeout: true) }
        #expect(throws: LibraryValidationError.self) { try HelperExit.timedOut.check(tool: "pmset", acceptsTimeout: false) }
        // Mission Control may keep running while the desktop shows.
        try HelperExit.timedOut.check(tool: "Mission Control", acceptsTimeout: true)
        #expect(throws: LibraryValidationError.self) {
            try HelperExit.exited(2).check(tool: "Mission Control", acceptsTimeout: true)
        }
    }

    @Test func wiFiPermissionErrorsSayAnAdministratorIsNeeded() {
        let denied = NSError(domain: "com.apple.coreWLAN.error", code: WiFiPowerError.notPermitted)
        #expect(WiFiPowerError.message(for: denied, turningOn: false).contains("administrator"))
        let other = NSError(domain: "com.apple.coreWLAN.error", code: -3_931)
        #expect(WiFiPowerError.message(for: other, turningOn: true) == "macOS didn't allow OpenRay to turn Wi-Fi on.")
    }
}
