import AppKit
@preconcurrency import ApplicationServices
import CoreWLAN
import IOKit
import IOKit.pwr_mgt

// MARK: - Catalog

/// A command that runs at once with no view, such as Lock Screen or Empty Trash.
struct SystemCommand: Identifiable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case lockScreen, sleep, sleepDisplays, restart, shutDown, logOut, startScreenSaver
        case playPause, nextTrack, previousTrack
        case volumeUp, volumeDown, toggleMute, setVolume
        case setVolume0, setVolume25, setVolume50, setVolume75, setVolume100
        case toggleMicrophoneMute
        case showDesktop, toggleAppearance
        case openTrash, emptyTrash, ejectAllDisks, toggleHiddenFiles
        case hideOtherApps, unhideAllApps, quitAllApps, quitAllAppsExceptFrontmost, restartFrontmostApp
        case dismissNotifications
        case toggleWiFi

        /// The launcher item ID, e.g. "system.lockScreen".
        var itemID: String { "system.\(rawValue)" }
    }

    enum Group: String, CaseIterable, Sendable {
        case power, media, display, files, apps, connectivity

        var title: String {
            switch self {
            case .power: "Power"
            case .media: "Sound and Media"
            case .display: "Display"
            case .files: "Files"
            case .apps: "Apps"
            case .connectivity: "Connectivity"
            }
        }
    }

    /// What the command needs beyond running.
    enum Permission: Equatable, Sendable {
        case none
        /// Posts system keys or reads other apps through Accessibility.
        case accessibility
        /// Sends Apple events to the app with this bundle identifier. Needs the
        /// Apple Events entitlement and NSAppleEventsUsageDescription in the app,
        /// then the person's consent under Privacy & Security → Automation.
        case automation(String)
    }

    /// The inline confirmation the action bar shows before a destructive command runs.
    struct Confirmation: Equatable, Sendable {
        var title: String
        var button: String
    }

    let id: ID
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: String
    let group: Group
    let permission: Permission
    let confirmation: Confirmation?
    /// Set Volume takes a percentage typed after its name.
    let argumentPlaceholder: String?
    /// Why the command may not work everywhere, for its details.
    let limitation: String?

    var needsConfirmation: Bool { confirmation != nil }
    var takesArgument: Bool { argumentPlaceholder != nil }

    private init(
        _ id: ID, _ title: String, _ subtitle: String, symbol: String, keywords: String, group: Group,
        permission: Permission = .none, confirmation: Confirmation? = nil, argumentPlaceholder: String? = nil,
        limitation: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.keywords = keywords
        self.group = group
        self.permission = permission
        self.confirmation = confirmation
        self.argumentPlaceholder = argumentPlaceholder
        self.limitation = limitation
    }

    static func command(_ id: ID) -> SystemCommand {
        // The catalog lists every ID; a test holds it to that.
        all.first { $0.id == id }!
    }

    static let all: [SystemCommand] = [
        .init(
            .lockScreen, "Lock Screen", "Lock this Mac and show the login window", symbol: "lock.fill",
            keywords: "lock secure away login", group: .power, permission: .accessibility,
            limitation: "Sends the system Lock Screen shortcut (⌃⌘Q), so it won't work if that shortcut is turned off."),
        .init(
            .sleep, "Sleep", "Put this Mac to sleep", symbol: "moon.fill", keywords: "sleep suspend rest",
            group: .power),
        .init(
            .sleepDisplays, "Sleep Displays", "Turn the displays off and keep the Mac awake", symbol: "display",
            keywords: "sleep displays screen monitor off", group: .power),
        .init(
            .restart, "Restart", "Restart this Mac. Apps can ask to save first", symbol: "restart",
            keywords: "restart reboot", group: .power, permission: .automation(loginWindow),
            confirmation: .init(title: "Restart this Mac?", button: "Restart")),
        .init(
            .shutDown, "Shut Down", "Shut down this Mac. Apps can ask to save first", symbol: "power",
            keywords: "shut down power off turn off", group: .power, permission: .automation(loginWindow),
            confirmation: .init(title: "Shut down this Mac?", button: "Shut Down")),
        .init(
            .logOut, "Log Out", "Log out of your account. Apps can ask to save first",
            symbol: "rectangle.portrait.and.arrow.right", keywords: "log out sign out logout", group: .power,
            permission: .automation(loginWindow), confirmation: .init(title: "Log out of this Mac?", button: "Log Out")),
        .init(
            .startScreenSaver, "Start Screen Saver", "Show the screen saver now", symbol: "sparkles.tv",
            keywords: "screen saver screensaver", group: .power),
        .init(
            .playPause, "Play/Pause", "Play or pause what's playing", symbol: "playpause.fill",
            keywords: "play pause music media resume", group: .media, permission: .accessibility),
        .init(
            .nextTrack, "Next Track", "Skip to the next track", symbol: "forward.fill",
            keywords: "next track skip song music media", group: .media, permission: .accessibility),
        .init(
            .previousTrack, "Previous Track", "Go back to the previous track", symbol: "backward.fill",
            keywords: "previous track back song music media", group: .media, permission: .accessibility),
        .init(
            .volumeUp, "Turn Volume Up", "Raise the output volume one step", symbol: "speaker.wave.3.fill",
            keywords: "volume up louder sound", group: .media),
        .init(
            .volumeDown, "Turn Volume Down", "Lower the output volume one step", symbol: "speaker.wave.1.fill",
            keywords: "volume down quieter sound", group: .media),
        .init(
            .toggleMute, "Toggle Mute", "Mute or unmute the sound output", symbol: "speaker.slash.fill",
            keywords: "mute unmute silence sound volume", group: .media),
        .init(
            .setVolume, "Set Volume", "Set the output volume to a percentage", symbol: "speaker.wave.2.fill",
            keywords: "set volume level sound percent", group: .media, argumentPlaceholder: "Percent"),
        .init(
            .setVolume0, "Set Volume to 0%", "Silence the output", symbol: "speaker.fill",
            keywords: "volume zero silent sound", group: .media),
        .init(
            .setVolume25, "Set Volume to 25%", "Set the output volume to 25%", symbol: "speaker.wave.1.fill",
            keywords: "volume quarter sound", group: .media),
        .init(
            .setVolume50, "Set Volume to 50%", "Set the output volume to 50%", symbol: "speaker.wave.2.fill",
            keywords: "volume half sound", group: .media),
        .init(
            .setVolume75, "Set Volume to 75%", "Set the output volume to 75%", symbol: "speaker.wave.2.fill",
            keywords: "volume sound", group: .media),
        .init(
            .setVolume100, "Set Volume to 100%", "Set the output volume to full", symbol: "speaker.wave.3.fill",
            keywords: "volume full max sound", group: .media),
        .init(
            .toggleMicrophoneMute, "Toggle Microphone Mute", "Mute or unmute every microphone",
            symbol: "mic.slash.fill", keywords: "microphone mic mute unmute input", group: .media),
        .init(
            .showDesktop, "Show Desktop", "Move windows aside to show the desktop", symbol: "menubar.dock.rectangle",
            keywords: "show desktop hide windows", group: .display,
            limitation: "Uses Mission Control's Show Desktop. macOS has no public API for it, so an update may break it."),
        .init(
            .toggleAppearance, "Toggle System Appearance", "Switch between Light and Dark",
            symbol: "circle.lefthalf.filled", keywords: "dark mode light mode appearance theme", group: .display,
            permission: .automation(systemEvents)),
        .init(
            .openTrash, "Open Trash", "Show the Trash in Finder", symbol: "trash", keywords: "trash bin finder",
            group: .files),
        .init(
            .emptyTrash, "Empty Trash", "Permanently erase the items in the Trash", symbol: "trash.slash",
            keywords: "empty trash delete erase bin", group: .files, permission: .automation(finder),
            confirmation: .init(title: "Permanently erase the items in the Trash?", button: "Empty Trash")),
        .init(
            .ejectAllDisks, "Eject All Disks", "Eject external drives, disk images and network volumes",
            symbol: "eject.fill", keywords: "eject unmount disks drives volumes usb", group: .files),
        .init(
            .toggleHiddenFiles, "Toggle Hidden Files", "Show or hide hidden files in Finder", symbol: "eye.slash",
            keywords: "hidden files dotfiles finder show", group: .files,
            limitation: "Restarts Finder to apply the change."),
        .init(
            .hideOtherApps, "Hide Other Apps", "Hide every app except the one you were using",
            symbol: "eye.slash.fill", keywords: "hide all apps except frontmost others", group: .apps),
        .init(
            .unhideAllApps, "Unhide All Apps", "Show every hidden app again", symbol: "eye",
            keywords: "unhide show hidden apps", group: .apps),
        .init(
            .quitAllApps, "Quit All Apps", "Quit every open app. Apps can ask to save first",
            symbol: "xmark.circle", keywords: "quit all apps close", group: .apps,
            confirmation: .init(title: "Quit every open app?", button: "Quit All")),
        .init(
            .quitAllAppsExceptFrontmost, "Quit All Apps Except Frontmost",
            "Quit every app except the one you were using", symbol: "xmark.circle.fill",
            keywords: "quit other apps close except frontmost", group: .apps,
            confirmation: .init(title: "Quit every app except the one you were using?", button: "Quit Others")),
        .init(
            .restartFrontmostApp, "Restart Frontmost App", "Quit and reopen the app you were using",
            symbol: "arrow.clockwise", keywords: "restart relaunch reopen app", group: .apps),
        .init(
            .dismissNotifications, "Dismiss Notifications", "Close the notifications on screen",
            symbol: "bell.slash", keywords: "dismiss clear notifications banners alerts", group: .apps,
            permission: .accessibility,
            limitation:
                "Best effort: closes notifications through Accessibility. It relies on English action names, and macOS updates may change Notification Center."
        ),
        .init(
            .toggleWiFi, "Toggle Wi-Fi", "Turn Wi-Fi on or off", symbol: "wifi", keywords: "wifi wi-fi wireless network",
            group: .connectivity,
            limitation:
                "Needs an administrator when Wi-Fi settings require one to turn Wi-Fi on or off (System Settings → Wi-Fi → Advanced)."
        ),
    ]

    static let loginWindow = "com.apple.loginwindow"
    static let systemEvents = "com.apple.systemevents"
    static let finder = "com.apple.finder"

    // MARK: Running

    /// The confirmation to show for this run. Quit Others names the app it keeps.
    func confirmation(for context: SystemCommandContext) -> Confirmation? {
        guard var confirmation else { return nil }
        if id == .quitAllAppsExceptFrontmost, let keep = context.foregroundApplication {
            confirmation.title = "Quit every app except \(keep.name)?"
        }
        return confirmation
    }

    /// The action to perform, given the typed argument and the app you came from.
    /// Commands that keep or restart "the app you were using" need a live,
    /// external foreground app; they never fall back to acting on every app.
    func action(argument: String? = nil, context: SystemCommandContext = .init()) throws -> SystemAction {
        switch id {
        case .lockScreen: return .lockScreen
        case .sleep: return .sleep
        case .sleepDisplays: return .sleepDisplays
        case .restart: return .restart
        case .shutDown: return .shutDown
        case .logOut: return .logOut
        case .startScreenSaver: return .startScreenSaver
        case .playPause: return .media(.playPause)
        case .nextTrack: return .media(.next)
        case .previousTrack: return .media(.previous)
        case .volumeUp: return .volume(.up)
        case .volumeDown: return .volume(.down)
        case .toggleMute: return .volume(.toggleMute)
        case .setVolume: return .volume(.set(try VolumeArgument.parse(argument)))
        case .setVolume0: return .volume(.set(0))
        case .setVolume25: return .volume(.set(0.25))
        case .setVolume50: return .volume(.set(0.5))
        case .setVolume75: return .volume(.set(0.75))
        case .setVolume100: return .volume(.set(1))
        case .toggleMicrophoneMute: return .toggleMicrophoneMute
        case .showDesktop: return .showDesktop
        case .toggleAppearance: return .toggleAppearance
        case .openTrash: return .openTrash
        case .emptyTrash: return .emptyTrash
        case .ejectAllDisks: return .ejectAllDisks
        case .toggleHiddenFiles: return .toggleHiddenFiles
        case .hideOtherApps:
            return .hideOtherApps(keeping: try context.requireForeground("the app you want to keep"))
        case .unhideAllApps: return .unhideApps
        case .quitAllApps: return .quitAllApps(excluded: context.excludedBundleIdentifiers)
        case .quitAllAppsExceptFrontmost:
            return .quitOtherApps(
                keeping: try context.requireForeground("the app you want to keep"),
                excluded: context.excludedBundleIdentifiers)
        case .restartFrontmostApp:
            return .restartApp(try context.requireForeground("the app you want to restart"))
        case .dismissNotifications: return .dismissNotifications
        case .toggleWiFi: return .toggleWiFi
        }
    }

    /// The confirmation shown after the launcher closes. Nil when the result
    /// speaks for itself: the screen locks, the Mac sleeps, Finder opens.
    func hud(for result: SystemActionResult) -> HUDMessage? {
        switch result {
        case .done:
            switch id {
            case .emptyTrash: return HUDMessage("Trash emptied", symbol: "trash")
            default: return nil
            }
        case .volume(let level, let muted):
            if muted { return HUDMessage("Muted", symbol: "speaker.slash.fill") }
            return HUDMessage("Volume \(Self.percent(level))", symbol: Self.volumeSymbol(level))
        case .muted(let muted):
            return muted
                ? HUDMessage("Muted", symbol: "speaker.slash.fill") : HUDMessage("Unmuted", symbol: "speaker.wave.2.fill")
        case .microphones(let muted, let changed, let unchanged):
            let symbol = muted ? "mic.slash.fill" : "mic.fill"
            if unchanged.isEmpty {
                if changed == 1 { return HUDMessage(muted ? "Microphone muted" : "Microphone on", symbol: symbol) }
                return HUDMessage(muted ? "\(changed) microphones muted" : "\(changed) microphones on", symbol: symbol)
            }
            let names = unchanged.joined(separator: ", ")
            return HUDMessage(
                muted ? "Muted \(changed) of \(changed + unchanged.count) microphones. \(names) is still on"
                    : "Turned on \(changed) of \(changed + unchanged.count) microphones. \(names) is still off",
                symbol: "exclamationmark.triangle.fill", style: .warning)
        case .appearance(let dark):
            return dark
                ? HUDMessage("Dark appearance", symbol: "moon.fill") : HUDMessage("Light appearance", symbol: "sun.max.fill")
        case .hiddenFiles(let visible):
            return visible
                ? HUDMessage("Showing hidden files", symbol: "eye") : HUDMessage("Hiding hidden files", symbol: "eye.slash")
        case .ejected(let count, let failed):
            if !failed.isEmpty {
                return HUDMessage(
                    "Couldn't eject \(failed.joined(separator: ", "))", symbol: "exclamationmark.triangle.fill",
                    style: .warning)
            }
            if count == 0 { return HUDMessage("No disks to eject", symbol: "eject", style: .info) }
            return HUDMessage(count == 1 ? "Ejected 1 disk" : "Ejected \(count) disks", symbol: "eject.fill")
        case .apps(let count):
            let noun = count == 1 ? "1 app" : "\(count) apps"
            switch id {
            case .hideOtherApps:
                return count == 0
                    ? HUDMessage("No other apps to hide", symbol: "eye.slash", style: .info)
                    : HUDMessage("Hid \(noun)", symbol: "eye.slash.fill")
            case .unhideAllApps:
                return count == 0
                    ? HUDMessage("No hidden apps", symbol: "eye", style: .info)
                    : HUDMessage("Unhid \(noun)", symbol: "eye")
            default:
                return count == 0
                    ? HUDMessage("No apps to quit", symbol: "xmark.circle", style: .info)
                    : HUDMessage("Quitting \(noun)", symbol: "xmark.circle")
            }
        case .app(let name):
            return HUDMessage("Restarted \(name)", symbol: "arrow.clockwise")
        case .notifications(let count):
            return count == 0
                ? HUDMessage("No notifications to dismiss", symbol: "bell", style: .info)
                : HUDMessage("Notifications dismissed", symbol: "bell.slash")
        case .wifi(let on):
            return on ? HUDMessage("Wi-Fi on", symbol: "wifi") : HUDMessage("Wi-Fi off", symbol: "wifi.slash")
        }
    }

    /// The executor: works out the action, has `performer` carry it out, and returns the HUD to show.
    @MainActor
    func run(
        with performer: any SystemActionPerforming, argument: String? = nil,
        context: SystemCommandContext = .init()
    ) async throws -> HUDMessage? {
        let action = try action(argument: argument, context: context)
        return hud(for: try await performer.perform(action))
    }

    static func percent(_ level: Double) -> String { "\(Int((min(max(level, 0), 1) * 100).rounded()))%" }

    static func volumeSymbol(_ level: Double) -> String {
        switch level {
        case ..<0.005: "speaker.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// A running app, pinned by more than its process ID so a reused PID never
/// stands in for the app the person meant.
struct AppIdentity: Equatable, Sendable {
    var pid: pid_t
    var bundleIdentifier: String?
    var name: String
    var launchDate: Date?

    init(pid: pid_t, bundleIdentifier: String?, name: String, launchDate: Date?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.launchDate = launchDate
    }

    @MainActor
    init(_ application: NSRunningApplication) {
        self.init(
            pid: application.processIdentifier, bundleIdentifier: application.bundleIdentifier,
            name: application.localizedName ?? "the app", launchDate: application.launchDate)
    }

    /// The same app is still running under this PID.
    func matches(_ app: RunningAppInfo) -> Bool {
        app.pid == pid && app.bundleIdentifier == bundleIdentifier && (launchDate == nil || app.launchDate == launchDate)
    }
}

/// What a system command knows about where it was run from.
struct SystemCommandContext: Equatable, Sendable {
    /// The app that was frontmost when the launcher opened. Capture it when the
    /// launcher opens; a window chosen with the target chip must never replace it.
    var foregroundApplication: AppIdentity?
    /// Apps that Quit All Apps leaves running.
    var excludedBundleIdentifiers: Set<String> = []

    /// The foreground app, which must be another app than OpenRay.
    func requireForeground(_ role: String, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) throws
        -> AppIdentity
    {
        guard let app = foregroundApplication, app.pid != ownPID, app.pid > 0 else {
            throw LibraryValidationError("Open OpenRay from \(role), then try again.")
        }
        return app
    }
}

// MARK: - Actions

enum MediaKey: Int32, Sendable {
    // NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT and NX_KEYTYPE_PREVIOUS from ev_keymap.h.
    case playPause = 16
    case next = 17
    case previous = 18
}

enum VolumeChange: Equatable, Sendable {
    case up, down, toggleMute
    /// 0...1.
    case set(Double)
}

enum SystemAction: Equatable, Sendable {
    case lockScreen, sleep, sleepDisplays, restart, shutDown, logOut, startScreenSaver
    case showDesktop, toggleAppearance
    case openTrash, emptyTrash, ejectAllDisks, toggleHiddenFiles
    case media(MediaKey)
    case volume(VolumeChange)
    case toggleMicrophoneMute
    case hideOtherApps(keeping: AppIdentity)
    case unhideApps
    case quitAllApps(excluded: Set<String>)
    case quitOtherApps(keeping: AppIdentity, excluded: Set<String>)
    case restartApp(AppIdentity)
    case dismissNotifications
    case toggleWiFi
}

enum SystemActionResult: Equatable, Sendable {
    case done
    case volume(Double, muted: Bool)
    case muted(Bool)
    /// Every input was asked to change; `unchanged` names the ones that couldn't.
    case microphones(muted: Bool, changed: Int, unchanged: [String])
    case appearance(dark: Bool)
    case hiddenFiles(visible: Bool)
    case ejected(count: Int, failed: [String])
    case apps(count: Int)
    case app(String)
    case notifications(count: Int)
    case wifi(on: Bool)
}

/// Carries out system actions. `LiveSystemActions` is the real one; tests use a
/// recording fake, and inert launches get `InertSystemActions`.
@MainActor
protocol SystemActionPerforming: AnyObject {
    func perform(_ action: SystemAction) async throws -> SystemActionResult
}

enum SystemActionEnvironment {
    /// The live executor in a normal launch; an inert one in the test host and in
    /// isolated verification mode.
    @MainActor
    static func makeDefault(sideEffects: SideEffectGuard = .current) -> any SystemActionPerforming {
        sideEffects.isInert ? InertSystemActions(sideEffects: sideEffects) : LiveSystemActions(sideEffects: sideEffects)
    }
}

/// Refuses every action. The default executor in inert launches.
@MainActor
final class InertSystemActions: SystemActionPerforming {
    let sideEffects: SideEffectGuard

    init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    func perform(_ action: SystemAction) async throws -> SystemActionResult {
        throw SideEffectGuard.Blocked(what: "system commands", mode: sideEffects.mode)
    }
}

// MARK: - Pure helpers

enum VolumeArgument {
    /// "50", "50%" or " 75 % " as a 0...1 level.
    static func parse(_ text: String?) throws -> Double {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasSuffix("%") ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) : trimmed
        guard let value = Double(digits), value.isFinite, (0...100).contains(value) else {
            throw LibraryValidationError("Type a volume from 0 to 100.")
        }
        return value / 100
    }
}

struct RunningAppInfo: Equatable, Sendable {
    var pid: pid_t
    var bundleIdentifier: String?
    var name: String
    /// A regular app with a Dock icon, not an agent or a background helper.
    var isRegular: Bool
    var isHidden: Bool
    var launchDate: Date? = nil
}

enum AppSelection {
    /// Finder relaunches itself; quitting it only flashes the desktop.
    static let neverQuit: Set<String> = [SystemCommand.finder]

    /// Confirms the app to keep is still the same running app. Throws when it
    /// has quit, when its PID now belongs to another app, or when it is OpenRay.
    static func verify(_ keep: AppIdentity, in apps: [RunningAppInfo], ownPID: pid_t) throws {
        guard keep.pid != ownPID, apps.contains(where: keep.matches) else {
            throw LibraryValidationError("\(keep.name) has quit, so OpenRay didn't change any other app.")
        }
    }

    static func hideTargets(_ apps: [RunningAppInfo], keeping: AppIdentity, ownPID: pid_t) throws -> [RunningAppInfo] {
        try verify(keeping, in: apps, ownPID: ownPID)
        return apps.filter { $0.isRegular && !$0.isHidden && $0.pid != ownPID && $0.pid != keeping.pid }
    }

    static func unhideTargets(_ apps: [RunningAppInfo], ownPID: pid_t) -> [RunningAppInfo] {
        apps.filter { $0.isRegular && $0.isHidden && $0.pid != ownPID }
    }

    /// Quit All passes no app to keep; Quit Others passes the verified foreground app.
    static func quitTargets(
        _ apps: [RunningAppInfo], keeping: AppIdentity?, excluded: Set<String>, ownPID: pid_t
    ) throws -> [RunningAppInfo] {
        if let keeping { try verify(keeping, in: apps, ownPID: ownPID) }
        return apps.filter { app in
            guard app.isRegular, app.pid != ownPID, app.pid != keeping?.pid else { return false }
            guard let bundleIdentifier = app.bundleIdentifier else { return true }
            return !excluded.contains(bundleIdentifier) && !neverQuit.contains(bundleIdentifier)
        }
    }
}

struct MountedVolume: Equatable, Sendable {
    var url: URL
    var name: String
    var isEjectable: Bool
    var isRemovable: Bool
    var isLocal: Bool
    var isRootFileSystem: Bool
    var isBrowsable: Bool
}

enum EjectableVolumes {
    /// External drives, disk images and network shares; never the startup disk or system volumes.
    static func select(_ volumes: [MountedVolume]) -> [MountedVolume] {
        volumes.filter { volume in
            let path = volume.url.standardizedFileURL.path
            return !volume.isRootFileSystem && volume.isBrowsable && path != "/" && !path.hasPrefix("/System/")
                && (volume.isEjectable || volume.isRemovable || !volume.isLocal)
        }
    }
}

enum FinderHiddenFiles {
    static let key = "AppleShowAllFiles"

    /// Finder accepts a Boolean, a number or "YES"/"TRUE"/"1" here.
    static func isOn(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: ["1", "yes", "true"].contains(value.lowercased())
        default: false
        }
    }
}

enum NotificationDismissal {
    /// Accessibility names custom actions "Name:Close\nTarget:0x0\nSelector:(null)".
    static func title(ofAction raw: String) -> String {
        guard raw.hasPrefix("Name:") else { return raw }
        let name = raw.dropFirst("Name:".count)
        return String(name.prefix { $0 != "\n" })
    }

    /// The action that clears a notification: Clear All on a stack, else Close.
    static func dismissAction(in actions: [String]) -> String? {
        actions.first { title(ofAction: $0) == "Clear All" } ?? actions.first { title(ofAction: $0) == "Close" }
    }
}

/// How a helper tool (pmset, Mission Control) finished.
enum HelperExit: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    /// Still running when the wait ended.
    case timedOut

    /// Success only when the tool exited with status 0, or when it is allowed to keep running.
    func check(tool: String, acceptsTimeout: Bool) throws {
        switch self {
        case .exited(0): return
        case .timedOut where acceptsTimeout: return
        case .exited(let status):
            throw LibraryValidationError("macOS refused the request (\(tool) exited with status \(status)).")
        case .signaled:
            throw LibraryValidationError("\(tool) stopped before finishing the request.")
        case .timedOut:
            throw LibraryValidationError("\(tool) didn't respond. Try again.")
        }
    }
}

enum WiFiPowerError {
    /// CoreWLAN's kCWOperationNotPermittedErr: Wi-Fi settings require an administrator.
    static let notPermitted = -3_930

    static func message(for error: NSError, turningOn: Bool) -> String {
        if error.code == notPermitted {
            return "Turning Wi-Fi \(turningOn ? "on" : "off") needs an administrator on this Mac. Change it in System Settings → Wi-Fi."
        }
        return "macOS didn't allow OpenRay to turn Wi-Fi \(turningOn ? "on" : "off")."
    }
}

// MARK: - Live executor

/// Runs system actions for real. Public APIs first (NSWorkspace, CoreAudio, IOKit,
/// CoreWLAN, CGEvent), Apple events only where nothing else exists. Never
/// constructed by tests; every action also checks its `SideEffectGuard` first.
@MainActor
final class LiveSystemActions: SystemActionPerforming {
    /// Tests assert this stays zero.
    private(set) static var instanceCount = 0

    let sideEffects: SideEffectGuard
    private let volume: VolumeControl
    private let microphone: MicrophoneMuteControl

    init(sideEffects: SideEffectGuard = .current, audio: (any AudioDeviceControlling)? = nil) {
        Self.instanceCount += 1
        self.sideEffects = sideEffects
        let audio = audio ?? CoreAudioDevices(sideEffects: sideEffects)
        volume = VolumeControl(audio: audio)
        microphone = MicrophoneMuteControl(audio: audio)
    }

    func perform(_ action: SystemAction) async throws -> SystemActionResult {
        try sideEffects.check("system commands")
        switch action {
        case .lockScreen:
            // ⌃⌘Q, the system Lock Screen shortcut. kVK_ANSI_Q is 12.
            try postKey(12, flags: [.maskControl, .maskCommand])
            return .done
        case .sleep:
            let port = IOPMFindPowerManagement(kIOMainPortDefault)
            guard port != 0 else { throw LibraryValidationError("This Mac didn't accept the sleep request.") }
            defer { IOServiceClose(port) }
            guard IOPMSleepSystem(port) == 0 else {
                throw LibraryValidationError("This Mac didn't accept the sleep request.")
            }
            return .done
        case .sleepDisplays:
            try await runTool("/usr/bin/pmset", ["displaysleepnow"], name: "pmset", acceptsTimeout: false)
            return .done
        case .restart:
            try sendLoginWindowEvent("rest")
            return .done
        case .shutDown:
            try sendLoginWindowEvent("shut")
            return .done
        case .logOut:
            // kAEReallyLogOut: the launcher already confirmed, so skip the system dialog.
            try sendLoginWindowEvent("rlgo")
            return .done
        case .startScreenSaver:
            try await openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
            return .done
        case .showDesktop:
            // Mission Control's executable shows the desktop when passed "1". It may
            // stay running while the desktop shows, so only an error exit fails.
            try await runTool(
                "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", ["1"],
                name: "Mission Control", acceptsTimeout: true)
            return .done
        case .toggleAppearance:
            let result = try runAppleScript(
                """
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to not dark mode
                        return dark mode
                    end tell
                end tell
                """, appName: "System Events")
            return .appearance(dark: result.booleanValue)
        case .openTrash:
            let trash = try FileManager.default.url(
                for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            guard NSWorkspace.shared.open(trash) else { throw LibraryValidationError("Finder didn't open the Trash.") }
            return .done
        case .emptyTrash:
            _ = try runAppleScript("tell application \"Finder\" to empty trash", appName: "Finder")
            return .done
        case .ejectAllDisks:
            return ejectAllDisks()
        case .toggleHiddenFiles:
            return try await toggleHiddenFiles()
        case .media(let key):
            try postMediaKey(key)
            return .done
        case .volume(let change):
            return try volume.apply(change)
        case .toggleMicrophoneMute:
            let outcome = try microphone.toggle()
            return .microphones(muted: outcome.muted, changed: outcome.changed.count, unchanged: outcome.unchanged)
        case .hideOtherApps(let keeping):
            let targets = try AppSelection.hideTargets(runningApps(), keeping: keeping, ownPID: ownPID)
            var count = 0
            for app in targets where NSRunningApplication(processIdentifier: app.pid)?.hide() == true { count += 1 }
            return .apps(count: count)
        case .unhideApps:
            let targets = AppSelection.unhideTargets(runningApps(), ownPID: ownPID)
            var count = 0
            for app in targets where NSRunningApplication(processIdentifier: app.pid)?.unhide() == true { count += 1 }
            return .apps(count: count)
        case .quitAllApps(let excluded):
            return .apps(count: quit(try AppSelection.quitTargets(
                runningApps(), keeping: nil, excluded: excluded, ownPID: ownPID)))
        case .quitOtherApps(let keeping, let excluded):
            return .apps(count: quit(try AppSelection.quitTargets(
                runningApps(), keeping: keeping, excluded: excluded, ownPID: ownPID)))
        case .restartApp(let identity):
            return try await restartApp(identity)
        case .dismissNotifications:
            return .notifications(count: try dismissNotifications())
        case .toggleWiFi:
            guard let interface = CWWiFiClient.shared().interface() else {
                throw LibraryValidationError("This Mac has no Wi-Fi.")
            }
            let on = !interface.powerOn()
            do { try interface.setPower(on) } catch {
                throw LibraryValidationError(WiFiPowerError.message(for: error as NSError, turningOn: on))
            }
            return .wifi(on: on)
        }
    }

    private var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    private func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map {
            RunningAppInfo(
                pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName ?? "App",
                isRegular: $0.activationPolicy == .regular, isHidden: $0.isHidden, launchDate: $0.launchDate)
        }
    }

    private func quit(_ targets: [RunningAppInfo]) -> Int {
        var count = 0
        for app in targets where NSRunningApplication(processIdentifier: app.pid)?.terminate() == true { count += 1 }
        return count
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw LibraryValidationError(
                "Allow OpenRay in System Settings → Privacy & Security → Accessibility to use this command.")
        }
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) throws {
        try requireAccessibility()
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
                throw LibraryValidationError("The key press couldn't be created.")
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private func postMediaKey(_ key: MediaKey) throws {
        try requireAccessibility()
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            guard
                let event = NSEvent.otherEvent(
                    with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                    timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                    data1: (Int(key.rawValue) << 16) | (state << 8), data2: -1),
                let cgEvent = event.cgEvent
            else { throw LibraryValidationError("The media key couldn't be created.") }
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    /// Runs a helper and waits for it, so a refused request fails instead of looking done.
    private func runTool(
        _ path: String, _ arguments: [String], name: String, acceptsTimeout: Bool, timeout: Duration = .seconds(5)
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw LibraryValidationError("This version of macOS doesn't support this command.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var waited = Duration.zero
        while process.isRunning && waited < timeout {
            try await Task.sleep(for: .milliseconds(50))
            waited += .milliseconds(50)
        }
        let exit: HelperExit =
            process.isRunning
            ? .timedOut
            : process.terminationReason == .uncaughtSignal
                ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
        try exit.check(tool: name, acceptsTimeout: acceptsTimeout)
    }

    private func sendLoginWindowEvent(_ eventID: String) throws {
        let event = NSAppleEventDescriptor(
            eventClass: Self.fourCharCode("aevt"), eventID: Self.fourCharCode(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: SystemCommand.loginWindow),
            returnID: -1, transactionID: 0)
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
        } catch {
            throw LibraryValidationError(
                "macOS didn't let OpenRay do this. Check System Settings → Privacy & Security → Automation.")
        }
    }

    private static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    private func runAppleScript(_ source: String, appName: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw LibraryValidationError("The command couldn't be prepared.")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if code == -1743 || code == -10004 {
                throw LibraryValidationError(
                    "Allow OpenRay to control \(appName) in System Settings → Privacy & Security → Automation.")
            }
            throw LibraryValidationError(
                (error[NSAppleScript.errorMessage] as? String) ?? "\(appName) didn't finish the command.")
        }
        return result
    }

    private func openApplication(at url: URL, activates: Bool = false) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func ejectAllDisks() -> SystemActionResult {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
            .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
        ]
        let urls =
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
            ?? []
        let volumes = urls.compactMap { url -> MountedVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return MountedVolume(
                url: url, name: values.volumeName ?? url.lastPathComponent,
                isEjectable: values.volumeIsEjectable ?? false, isRemovable: values.volumeIsRemovable ?? false,
                isLocal: values.volumeIsLocal ?? true, isRootFileSystem: values.volumeIsRootFileSystem ?? false,
                isBrowsable: values.volumeIsBrowsable ?? true)
        }
        var ejected = 0
        var failed: [String] = []
        for volume in EjectableVolumes.select(volumes) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                ejected += 1
            } catch {
                failed.append(volume.name)
            }
        }
        return .ejected(count: ejected, failed: failed)
    }

    private func toggleHiddenFiles() async throws -> SystemActionResult {
        let key = FinderHiddenFiles.key as CFString
        let domain = SystemCommand.finder as CFString
        let visible = !FinderHiddenFiles.isOn(CFPreferencesCopyAppValue(key, domain))
        CFPreferencesSetAppValue(key, visible ? kCFBooleanTrue : kCFBooleanFalse, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw LibraryValidationError("Finder's settings couldn't be changed.")
        }
        let finders = NSRunningApplication.runningApplications(withBundleIdentifier: SystemCommand.finder)
        for finder in finders { finder.terminate() }
        try await waitUntilTerminated(finders, timeout: .seconds(5), failure: "Finder didn't restart. Hidden files change after it does.")
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SystemCommand.finder) {
            try? await openApplication(at: url)
        }
        return .hiddenFiles(visible: visible)
    }

    private func restartApp(_ identity: AppIdentity) async throws -> SystemActionResult {
        try AppSelection.verify(identity, in: runningApps(), ownPID: ownPID)
        guard let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated,
            let url = app.bundleURL
        else { throw LibraryValidationError("\(identity.name) has already quit.") }
        let name = app.localizedName ?? identity.name
        guard app.terminate() else { throw LibraryValidationError("\(name) didn't quit.") }
        try await waitUntilTerminated(
            [app], timeout: .seconds(10), failure: "\(name) didn't quit. It may be waiting for you to save changes.")
        try await openApplication(at: url, activates: true)
        return .app(name)
    }

    private func waitUntilTerminated(
        _ apps: [NSRunningApplication], timeout: Duration, failure: String
    ) async throws {
        var waited = Duration.zero
        while apps.contains(where: { !$0.isTerminated }) {
            guard waited < timeout else { throw LibraryValidationError(failure) }
            try await Task.sleep(for: .milliseconds(100))
            waited += .milliseconds(100)
        }
    }

    private func dismissNotifications() throws -> Int {
        try requireAccessibility()
        guard
            let center = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.notificationcenterui"
            ).first
        else { return 0 }
        let application = AXUIElementCreateApplication(center.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var count = 0
        func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
            return value as? [AXUIElement] ?? []
        }
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 12, count < 64 else { return }
            var names: CFArray?
            if AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String],
                let action = NotificationDismissal.dismissAction(in: actions)
            {
                if AXUIElementPerformAction(element, action as CFString) == .success { count += 1 }
                return
            }
            for child in children(element, kAXChildrenAttribute) { visit(child, depth: depth + 1) }
        }
        for window in children(application, kAXWindowsAttribute) { visit(window, depth: 0) }
        return count
    }
}
