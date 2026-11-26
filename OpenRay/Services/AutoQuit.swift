import AppKit

/// Quits chosen apps once they've sat in the background for their idle time (1–15 minutes).
///
/// An app's clock starts when it stops being frontmost, or when Auto Quit first sees it in the
/// background. Being frontmost resets it. OpenRay and the Finder are never quit, and every quit
/// goes through the running-app controller, whose live form checks `SideEffectGuard`.
@MainActor
final class AutoQuit {
    let running: RunningApplications
    /// Settings › Applications, read on every check.
    var settings: @MainActor () -> ApplicationSettings
    var now: @MainActor () -> Date
    /// When each running process was last frontmost, by PID.
    private(set) var lastActive: [pid_t: Date] = [:]
    /// Processes whose clock started while their app had Auto Quit on. An app opted in later
    /// starts a fresh clock, never one left from before.
    private var armed: Set<pid_t> = []
    /// The apps the last check quit, for the Settings pane and tests.
    private(set) var recentlyQuit: [String] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// How often the live timer checks.
    static let interval: TimeInterval = 20
    /// Never quit, even when chosen: OpenRay quits through its own menu, and the Finder is the desktop.
    nonisolated static let excluded: Set<String> = ["com.apple.finder"]

    init(
        running: RunningApplications, settings: @escaping @MainActor () -> ApplicationSettings,
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.running = running
        self.settings = settings
        self.now = now
    }

    /// Whether an app can be chosen for Auto Quit at all.
    func canAutoQuit(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID != running.ownBundleID && !Self.excluded.contains(bundleID)
    }

    /// An app left the front: its idle clock starts now.
    func noteDeactivated(_ pid: pid_t) { lastActive[pid] = now() }

    /// Checks every running app once and quits the ones idle for longer than their time.
    /// Returns the apps it asked to quit.
    @discardableResult
    func check() -> [RunningApp] {
        let now = now()
        let settings = settings()
        guard !settings.autoQuit.isEmpty else {
            lastActive = [:]
            armed = []
            return []
        }
        let apps = running.controller.runningApplications()
        let alive = Set(apps.map(\.pid))
        lastActive = lastActive.filter { alive.contains($0.key) }
        var stillArmed: Set<pid_t> = []
        var quit: [RunningApp] = []
        for app in apps where app.isRegular {
            guard canAutoQuit(app.bundleID), let bundleID = app.bundleID,
                // The rule's own copy only: same bundle id and the same bundle on disk.
                let minutes = settings.autoQuitMinutes(for: bundleID, at: app.bundleURL)
            else { continue }
            stillArmed.insert(app.pid)
            if app.isActive || !armed.contains(app.pid) {
                lastActive[app.pid] = now
                continue
            }
            guard let since = lastActive[app.pid] else {
                lastActive[app.pid] = now
                continue
            }
            guard now.timeIntervalSince(since) >= TimeInterval(minutes * 60) else { continue }
            // Start the clock again either way, so an app asking to save isn't asked every check.
            lastActive[app.pid] = now
            do {
                try running.controller.quit(app)
                quit.append(app)
            } catch {
                continue
            }
        }
        armed = stillArmed
        if !quit.isEmpty { recentlyQuit = quit.map(\.name) }
        return quit
    }

    /// Starts the live timer and activation tracking, in a normal launch only.
    func start(sideEffects: SideEffectGuard = .current) {
        guard !SideEffectGuard.atLeastCurrent(sideEffects).isInert, timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) {
                [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                MainActor.assumeIsolated { if let pid { self?.noteDeactivated(pid) } }
            })
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.check() }
        }
    }

    /// True while the live timer runs.
    var isRunning: Bool { timer != nil }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }
}
