import AppKit

/// One running app, identified well enough to refuse acting on a process that quit and was
/// relaunched, or whose PID was reused, since the row was built.
struct RunningApp: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String?
    var name: String
    var bundleURL: URL?
    var launchDate: Date?
    var isActive = false
    var isHidden = false
    /// Has a Dock icon and menu bar, unlike agents and background helpers.
    var isRegular = true
}

/// The OS calls behind every running-app action, so tests run against a fake. The live
/// controller checks `SideEffectGuard` before each one; reading the list is not an effect.
@MainActor
protocol RunningApplicationControlling: AnyObject {
    func runningApplications() -> [RunningApp]
    func hide(_ app: RunningApp) throws
    func quit(_ app: RunningApp) throws
    func forceQuit(_ app: RunningApp) throws
    func open(_ url: URL) async throws
}

enum RunningApplicationError: LocalizedError, Equatable {
    case notRunning(String)
    case refused(String, action: String)
    case protected(String)
    case stillRunning(String)

    var errorDescription: String? {
        switch self {
        case .notRunning(let name): "\(name) isn't running."
        case .refused(let name, let action): "\(name) didn't \(action)."
        case .protected(let name): "OpenRay doesn't quit \(name)."
        case .stillRunning(let name): "\(name) didn't quit. It may be asking to save a document."
        }
    }
}

@MainActor
final class LiveRunningApplications: RunningApplicationControlling {
    private let sideEffects: SideEffectGuard

    init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    func runningApplications() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map { app in
            RunningApp(
                pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName ?? "App",
                bundleURL: app.bundleURL, launchDate: app.launchDate, isActive: app.isActive, isHidden: app.isHidden,
                isRegular: app.activationPolicy == .regular)
        }
    }

    func hide(_ app: RunningApp) throws {
        try sideEffects.check("hiding \(app.name)")
        guard try resolve(app).hide() else { throw RunningApplicationError.refused(app.name, action: "hide") }
    }

    func quit(_ app: RunningApp) throws {
        try sideEffects.check("quitting \(app.name)")
        guard try resolve(app).terminate() else { throw RunningApplicationError.refused(app.name, action: "quit") }
    }

    func forceQuit(_ app: RunningApp) throws {
        try sideEffects.check("force quitting \(app.name)")
        guard try resolve(app).forceTerminate() else {
            throw RunningApplicationError.refused(app.name, action: "force quit")
        }
    }

    func open(_ url: URL) async throws {
        try sideEffects.check("opening \(url.lastPathComponent)")
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The same process the row described: same PID, bundle and launch time.
    private func resolve(_ app: RunningApp) throws -> NSRunningApplication {
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated,
            running.bundleIdentifier == app.bundleID, running.launchDate == app.launchDate
        else { throw RunningApplicationError.notRunning(app.name) }
        return running
    }
}

/// The Applications actions on top of a controller: Hide, Quit, Force Quit, Restart, and
/// Hide All / Quit All with an exclusion list. OpenRay itself is never quit or hidden.
@MainActor
final class RunningApplications {
    let controller: any RunningApplicationControlling
    /// OpenRay's own bundle id, never acted on.
    let ownBundleID: String?
    /// How long Restart waits for the app to quit before giving up.
    var restartTimeout: Duration = .seconds(10)
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// Apps Quit All leaves alone even without an exclusion: the Finder and the system's own.
    nonisolated static let neverQuit: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
    ]

    init(controller: any RunningApplicationControlling, ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.controller = controller
        self.ownBundleID = ownBundleID
    }

    /// The running processes of an installed app, matched by bundle id, or by path without one.
    func instances(of app: InstalledApplication) -> [RunningApp] {
        controller.runningApplications().filter { running in
            if let bundleID = app.bundleIdentifier { return running.bundleID == bundleID }
            return running.bundleURL?.standardizedFileURL.path == app.url.standardizedFileURL.path
        }
    }

    func isRunning(_ app: InstalledApplication) -> Bool { !instances(of: app).isEmpty }

    func hide(_ app: InstalledApplication) throws {
        try each(app) { try controller.hide($0) }
    }

    func quit(_ app: InstalledApplication) throws {
        try refuseOwn(app)
        try each(app) { try controller.quit($0) }
    }

    func forceQuit(_ app: InstalledApplication) throws {
        try refuseOwn(app)
        try each(app) { try controller.forceQuit($0) }
    }

    /// Quits the app, waits for it to go, then opens it again.
    func restart(_ app: InstalledApplication) async throws {
        try refuseOwn(app)
        let pids = Set(instances(of: app).map(\.pid))
        guard !pids.isEmpty else { throw RunningApplicationError.notRunning(app.name) }
        try quit(app)
        let step = Duration.milliseconds(100)
        var waited = Duration.zero
        while controller.runningApplications().contains(where: { pids.contains($0.pid) }) {
            guard waited < restartTimeout else { throw RunningApplicationError.stillRunning(app.name) }
            try await sleep(step)
            waited += step
        }
        try await controller.open(app.url)
    }

    struct BatchResult: Equatable {
        var acted: [String] = []
        var failed: [String] = []
    }

    /// The regular apps Hide All or Quit All would act on, by the rules above.
    func batchTargets(keeping: Set<String>, quitting: Bool) -> [RunningApp] {
        var seen = Set<pid_t>()
        return controller.runningApplications().filter { app in
            guard app.isRegular, seen.insert(app.pid).inserted else { return false }
            guard let bundleID = app.bundleID else { return !quitting }
            if bundleID == ownBundleID || keeping.contains(bundleID) { return false }
            return !quitting || !Self.neverQuit.contains(bundleID)
        }
    }

    func hideAll(keeping: Set<String>) -> BatchResult {
        batch(batchTargets(keeping: keeping, quitting: false).filter { !$0.isHidden }) { try controller.hide($0) }
    }

    func quitAll(keeping: Set<String>) -> BatchResult {
        batch(batchTargets(keeping: keeping, quitting: true)) { try controller.quit($0) }
    }

    private func batch(_ apps: [RunningApp], _ act: (RunningApp) throws -> Void) -> BatchResult {
        var result = BatchResult()
        for app in apps {
            do {
                try act(app)
                result.acted.append(app.name)
            } catch {
                result.failed.append(app.name)
            }
        }
        return result
    }

    private func each(_ app: InstalledApplication, _ act: (RunningApp) throws -> Void) throws {
        let running = instances(of: app)
        guard !running.isEmpty else { throw RunningApplicationError.notRunning(app.name) }
        for instance in running { try act(instance) }
    }

    private func refuseOwn(_ app: InstalledApplication) throws {
        if let ownBundleID, app.bundleIdentifier == ownBundleID { throw RunningApplicationError.protected(app.name) }
    }
}
