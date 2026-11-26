import AppKit
import Foundation
import Observation

// MARK: - Categories

enum FocusMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Listed apps are hidden when they come forward.
    case block
    /// Only listed apps (and the system's own) may come forward.
    case allow

    var id: String { rawValue }
    var title: String { self == .block ? "Block List" : "Allow List" }
    var verb: String { self == .block ? "Blocking" : "Allowing only" }
}

/// A named group of apps a session blocks or allows.
struct FocusCategory: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var bundleIDs: [String]
    var isBuiltIn: Bool

    /// Starting points. They can be edited, which stores an override with the same id, or hidden.
    static let builtIns: [FocusCategory] = [
        FocusCategory(
            id: "builtin.messaging", name: "Messaging", symbol: "bubble.left.and.bubble.right",
            bundleIDs: [
                "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram",
                "org.telegram.desktop", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "org.whispersystems.signal-desktop",
                "com.facebook.archon", "com.microsoft.teams2", "com.microsoft.teams",
            ], isBuiltIn: true),
        FocusCategory(
            id: "builtin.email", name: "Email", symbol: "envelope",
            bundleIDs: ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.mimestream.Mimestream"],
            isBuiltIn: true),
        FocusCategory(
            id: "builtin.entertainment", name: "Entertainment", symbol: "play.tv",
            bundleIDs: ["com.apple.Music", "com.apple.TV", "com.spotify.client", "com.apple.podcasts"], isBuiltIn: true),
        FocusCategory(
            id: "builtin.news", name: "News", symbol: "newspaper",
            bundleIDs: ["com.apple.news", "com.apple.stocks", "com.ranchero.NetNewsWire-Evergreen"], isBuiltIn: true),
        FocusCategory(
            id: "builtin.games", name: "Games", symbol: "gamecontroller",
            bundleIDs: ["com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher", "com.apple.Chess"], isBuiltIn: true),
    ]

    /// The built-ins with the person's edits applied, then their own categories, in that order.
    static func resolve(_ records: [FocusCategoryRecord]) -> [FocusCategory] {
        var byID: [String: FocusCategoryRecord] = [:]
        for record in records where byID[record.id] == nil { byID[record.id] = record }
        let builtIns: [FocusCategory] = Self.builtIns.compactMap { builtIn in
            guard let record = byID[builtIn.id] else { return builtIn }
            guard record.isHidden != true else { return nil }
            var category = builtIn
            if let name = record.name, !name.isEmpty { category.name = name }
            if let symbol = record.symbol { category.symbol = symbol }
            if let bundleIDs = record.bundleIDs { category.bundleIDs = bundleIDs }
            return category
        }
        let builtInIDs = Set(Self.builtIns.map(\.id))
        var custom: [FocusCategory] = []
        for record in records where !builtInIDs.contains(record.id) && record.isHidden != true {
            let name: String = record.name ?? "Untitled"
            let symbol: String = record.symbol ?? "square.grid.2x2"
            custom.append(
                FocusCategory(id: record.id, name: name, symbol: symbol, bundleIDs: record.bundleIDs ?? [], isBuiltIn: false))
        }
        return builtIns + custom
    }

    /// The record that stores this category's current state.
    var record: FocusCategoryRecord {
        FocusCategoryRecord(id: id, name: name, symbol: symbol, bundleIDs: bundleIDs)
    }
}

/// Whether an app is held back during a session.
enum FocusBlockPolicy {
    /// Never hidden, whatever the lists say: OpenRay itself and the system pieces you need to get around.
    static let alwaysAllowed: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.Spotlight", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter", "com.apple.ActivityMonitor", "com.apple.screencaptureui",
        "com.apple.WindowManager", "com.apple.coreservices.uiagent",
    ]

    static func shouldBlock(bundleID: String?, mode: FocusMode, listed: Set<String>, ownBundleID: String? = Bundle.main.bundleIdentifier)
        -> Bool
    {
        guard let bundleID, !bundleID.isEmpty, !alwaysAllowed.contains(bundleID), bundleID != ownBundleID else { return false }
        switch mode {
        case .block: return listed.contains(bundleID)
        case .allow: return !listed.contains(bundleID)
        }
    }
}

// MARK: - Session

/// What a session was started with.
struct FocusConfiguration: Equatable, Sendable {
    var goal: String
    /// Nil runs until completed.
    var duration: TimeInterval?
    var mode: FocusMode
    var categoryIDs: [String]
    /// The categories' apps, resolved when the session starts.
    var bundleIDs: Set<String>
    /// Category names, for the summary and the menu.
    var categoryNames: [String] = []

    var displayGoal: String {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? "Focus" : goal
    }
}

struct FocusSessionState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case running
        /// Blocking and the clock are stopped.
        case paused
        /// Blocking is lifted until `until`; the clock keeps running.
        case snoozed(until: Date)
    }

    var configuration: FocusConfiguration
    var startedAt: Date
    var phase: Phase = .running
    /// Focused time before the current running stretch.
    var focusedBefore: TimeInterval = 0
    /// When the current running (or snoozed) stretch began. Nil while paused.
    var stretchStart: Date?
    /// Apps that were held back, by bundle id, with how often.
    var blockedAttempts: [String: Int] = [:]
    /// Display names for `blockedAttempts`.
    var blockedNames: [String: String] = [:]

    /// Time spent focused: running and snoozed count, paused doesn't.
    func focused(at now: Date) -> TimeInterval {
        focusedBefore + (stretchStart.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Time left, or nil for a session without a limit.
    func remaining(at now: Date) -> TimeInterval? {
        configuration.duration.map { max(0, $0 - focused(at: now)) }
    }

    var isPaused: Bool { phase == .paused }

    func isSnoozed(at now: Date) -> Bool {
        if case .snoozed(let until) = phase { return now < until }
        return false
    }
}

/// How a session went, shown when it ends.
struct FocusSummary: Equatable, Sendable {
    var goal: String
    var focused: TimeInterval
    var planned: TimeInterval?
    var endedAt: Date
    /// True when the timer ran out, false when completed by hand.
    var finishedOnTime: Bool
    var blockedAttempts: Int
    var blockedApps: [String]

    /// “Focused 25 min on Write the report. Held back Slack and Mail 4 times.”
    var text: String {
        let minutes = max(1, Int((focused / 60).rounded()))
        var text = "Focused \(FocusFormat.duration(minutes: minutes)) on \(goal)."
        if blockedAttempts > 0 {
            let apps = ListFormatter.localizedString(byJoining: blockedApps.sorted())
            text += " Held back \(apps) \(blockedAttempts) time\(blockedAttempts == 1 ? "" : "s")."
        }
        return text
    }
}

/// The Focus state machine. Pure: every transition takes the time, so tests drive it with a clock.
struct FocusMachine: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case snoozeEnded
        case finished(FocusSummary)
    }

    enum Failure: LocalizedError, Equatable {
        case alreadyRunning, notRunning, invalidDuration
        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "A focus session is already running."
            case .notRunning: "There's no focus session running."
            case .invalidDuration: "Choose a duration from 1 minute to 24 hours."
            }
        }
    }

    static let maximumDuration: TimeInterval = 24 * 3_600
    static let snoozeDuration: TimeInterval = 5 * 60

    private(set) var session: FocusSessionState?
    private(set) var lastSummary: FocusSummary?

    var isActive: Bool { session != nil }

    mutating func start(_ configuration: FocusConfiguration, at now: Date) throws {
        guard session == nil else { throw Failure.alreadyRunning }
        if let duration = configuration.duration, !(60...Self.maximumDuration).contains(duration) {
            throw Failure.invalidDuration
        }
        session = FocusSessionState(configuration: configuration, startedAt: now, stretchStart: now)
    }

    mutating func pause(at now: Date) throws {
        guard var session else { throw Failure.notRunning }
        guard session.phase != .paused else { return }
        session.focusedBefore = session.focused(at: now)
        session.stretchStart = nil
        session.phase = .paused
        self.session = session
    }

    mutating func resume(at now: Date) throws {
        guard var session else { throw Failure.notRunning }
        guard session.phase == .paused else { return }
        session.stretchStart = now
        session.phase = .running
        self.session = session
    }

    /// Lifts blocking for five minutes (or `duration`) while the clock keeps running. A paused
    /// session resumes first, since pausing already lifts blocking.
    mutating func snooze(for duration: TimeInterval = snoozeDuration, at now: Date) throws {
        if session?.phase == .paused { try resume(at: now) }
        guard var session else { throw Failure.notRunning }
        session.phase = .snoozed(until: now.addingTimeInterval(duration))
        self.session = session
    }

    /// Ends the session and returns its summary.
    @discardableResult
    mutating func complete(at now: Date, finishedOnTime: Bool = false) throws -> FocusSummary {
        guard let session else { throw Failure.notRunning }
        let focused = session.configuration.duration.map { min($0, session.focused(at: now)) } ?? session.focused(at: now)
        let summary = FocusSummary(
            goal: session.configuration.displayGoal, focused: focused, planned: session.configuration.duration,
            endedAt: now, finishedOnTime: finishedOnTime,
            blockedAttempts: session.blockedAttempts.values.reduce(0, +),
            blockedApps: session.blockedAttempts.keys.map { session.blockedNames[$0] ?? $0 })
        self.session = nil
        lastSummary = summary
        return summary
    }

    /// Advances time: a snooze that ran out goes back to blocking, and a session out of time completes.
    mutating func tick(at now: Date) -> Event? {
        guard var session else { return nil }
        if let remaining = session.remaining(at: now), remaining <= 0 {
            return (try? complete(at: now, finishedOnTime: true)).map(Event.finished)
        }
        if case .snoozed(let until) = session.phase, now >= until {
            session.phase = .running
            self.session = session
            return .snoozeEnded
        }
        return nil
    }

    /// Whether an app coming forward is held back right now.
    func shouldBlock(bundleID: String?, at now: Date, ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let session, session.phase != .paused, !session.isSnoozed(at: now) else { return false }
        return FocusBlockPolicy.shouldBlock(
            bundleID: bundleID, mode: session.configuration.mode, listed: session.configuration.bundleIDs,
            ownBundleID: ownBundleID)
    }

    mutating func recordBlocked(bundleID: String, name: String) {
        guard var session else { return }
        session.blockedAttempts[bundleID, default: 0] += 1
        session.blockedNames[bundleID] = name
        self.session = session
    }
}

// MARK: - Formatting and parsing

enum FocusFormat {
    /// “25 min”, “1 h”, “1 h 30 min”.
    static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The menu bar's countdown: “24:59”, “1:04:59”.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// A duration typed with the goal: “40m”, “1h”, “1h30”, “1.5 h”, “90 min”. Returns the minutes
    /// and the rest of the text as the goal.
    static func parse(_ text: String) -> (minutes: Int?, goal: String) {
        let pattern = #"(?i)(?:^|\s)(?:for\s+)?(\d{1,2}(?:[.,]\d)?)\s*(h|hr|hrs|hours?)(?:\s*(\d{1,2})\s*(?:m|min|mins|minutes?)?)?(?=\s|$)|(?:^|\s)(?:for\s+)?(\d{1,4})\s*(m|min|mins|minutes?)(?=\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return (nil, text.trimmingCharacters(in: .whitespaces)) }
        let ns = text as NSString
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        var minutes: Int?
        if let hours = group(1).flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }) {
            minutes = Int((hours * 60).rounded()) + (group(3).flatMap(Int.init) ?? 0)
        } else if let value = group(4).flatMap(Int.init) {
            minutes = value
        }
        let goal = ns.replacingCharacters(in: match.range, with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let minutes, (1...1_440).contains(minutes) else { return (nil, text.trimmingCharacters(in: .whitespaces)) }
        return (minutes, goal)
    }
}

// MARK: - Preferences

/// The next session's defaults, kept in `commandPreferences["pref.focus"]`.
struct FocusPreferences: Equatable, Sendable {
    static let storageKey = "pref.focus"
    static let presets = [15, 25, 30, 45, 60, 90, 120]

    var minutes = 25
    var mode = FocusMode.block
    var categoryIDs = ["builtin.messaging", "builtin.entertainment"]
    var lastGoal = ""

    init() {}

    init(_ values: [String: String]) {
        if let value = values["minutes"].flatMap(Int.init), (0...1_440).contains(value) { minutes = value }
        if let value = values["mode"].flatMap(FocusMode.init(rawValue:)) { mode = value }
        if let value = values["categories"] { categoryIDs = value.split(separator: "\n").map(String.init) }
        if let value = values["lastGoal"] { lastGoal = value }
    }

    var values: [String: String] {
        ["minutes": String(minutes), "mode": mode.rawValue, "categories": categoryIDs.joined(separator: "\n"), "lastGoal": lastGoal]
    }

    @MainActor static func load(from store: LibraryStore) -> FocusPreferences {
        FocusPreferences(store.database.commandPreferences[storageKey] ?? [:])
    }

    @MainActor @discardableResult
    func save(to store: LibraryStore) -> Bool {
        store.update { $0.commandPreferences[Self.storageKey] = values }
    }

    /// A configuration from these defaults, resolving categories against the library's.
    func configuration(goal: String, minutes: Int?, categories: [FocusCategory]) -> FocusConfiguration {
        let chosen = categories.filter { categoryIDs.contains($0.id) }
        return FocusConfiguration(
            goal: goal, duration: minutes.flatMap { $0 > 0 ? TimeInterval($0 * 60) : nil }, mode: mode,
            categoryIDs: chosen.map(\.id), bundleIDs: Set(chosen.flatMap(\.bundleIDs)), categoryNames: chosen.map(\.name))
    }
}

// MARK: - Side effects

/// A running app, as Focus sees it.
struct FocusRunningApp: Equatable, Sendable {
    var bundleID: String?
    var name: String
    var processIdentifier: pid_t
}

/// Watching and hiding other apps. The live one uses NSWorkspace behind the guard; tests use a fake.
@MainActor
protocol FocusAppControlling: AnyObject {
    /// Called when an app comes to the front, while observing.
    var onActivate: ((FocusRunningApp) -> Void)? { get set }
    func startObserving()
    func stopObserving()
    func runningApplications() -> [FocusRunningApp]
    func hide(_ app: FocusRunningApp) throws
}

/// The small notices Focus shows over other apps.
@MainActor
protocol FocusNoticePresenting: AnyObject {
    func showBlocked(appName: String, goal: String)
    func showStarted(_ configuration: FocusConfiguration)
    func showSummary(_ summary: FocusSummary)
}

@MainActor
final class WorkspaceFocusAppControl: FocusAppControlling {
    let guardrail: SideEffectGuard
    var onActivate: ((FocusRunningApp) -> Void)?
    private var observer: NSObjectProtocol?

    init(guardrail: SideEffectGuard = .current) {
        self.guardrail = guardrail
    }

    func startObserving() {
        guard observer == nil, !guardrail.isInert else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let running = FocusRunningApp(
                bundleID: app.bundleIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "This app",
                processIdentifier: app.processIdentifier)
            MainActor.assumeIsolated { self?.onActivate?(running) }
        }
    }

    func stopObserving() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    func runningApplications() -> [FocusRunningApp] {
        guard !guardrail.isInert else { return [] }
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isHidden }.map {
            FocusRunningApp(bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "", processIdentifier: $0.processIdentifier)
        }
    }

    func hide(_ app: FocusRunningApp) throws {
        try guardrail.check("hiding \(app.name)")
        guard NSRunningApplication(processIdentifier: app.processIdentifier)?.hide() == true else {
            throw FocusAppError.couldNotHide(app.name)
        }
    }
}

enum FocusAppError: LocalizedError, Equatable {
    case couldNotHide(String)
    var errorDescription: String? {
        switch self {
        case .couldNotHide(let name): "OpenRay couldn't hide \(name)."
        }
    }
}

// MARK: - Controller

/// Runs focus sessions: the state machine, a once-a-second tick, and app blocking.
@MainActor
@Observable
final class FocusController {
    static let shared = FocusController(apps: WorkspaceFocusAppControl(), notices: FocusNoticeCenter())

    private(set) var machine = FocusMachine()
    @ObservationIgnored let apps: any FocusAppControlling
    @ObservationIgnored let notices: any FocusNoticePresenting
    @ObservationIgnored var now: () -> Date
    /// Whether to run the live once-a-second tick. Tests tick by hand.
    @ObservationIgnored var runsTicker: Bool
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Bumped every tick, so the menu bar countdown and the launcher redraw.
    private(set) var clock = 0

    init(
        apps: any FocusAppControlling, notices: any FocusNoticePresenting, now: @escaping () -> Date = { .now },
        runsTicker: Bool = !SideEffectGuard.isInert
    ) {
        self.apps = apps
        self.notices = notices
        self.now = now
        self.runsTicker = runsTicker
        apps.onActivate = { [weak self] app in self?.applicationActivated(app) }
    }

    var session: FocusSessionState? { machine.session }
    var lastSummary: FocusSummary? { machine.lastSummary }
    var isActive: Bool { machine.isActive }

    /// Time left or elapsed, as the menu bar shows it. Reads `clock` so views update every second.
    var timerText: String? {
        _ = clock
        guard let session else { return nil }
        if session.isPaused { return "Paused" }
        let now = now()
        return FocusFormat.clock(session.remaining(at: now) ?? session.focused(at: now))
    }

    // MARK: Transitions

    func start(_ configuration: FocusConfiguration) throws {
        try machine.start(configuration, at: now())
        apps.startObserving()
        startTicker()
        // Apps already open in front of you that the session blocks are hidden now.
        for app in apps.runningApplications() where machine.shouldBlock(bundleID: app.bundleID, at: now()) {
            try? apps.hide(app)
        }
        notices.showStarted(configuration)
    }

    func pause() throws { try machine.pause(at: now()) }
    func resume() throws { try machine.resume(at: now()) }
    func snooze() throws { try machine.snooze(at: now()) }

    @discardableResult
    func complete() throws -> FocusSummary {
        let summary = try machine.complete(at: now())
        finish(summary)
        return summary
    }

    func togglePause() throws {
        if session?.isPaused == true { try resume() } else { try pause() }
    }

    private func finish(_ summary: FocusSummary) {
        apps.stopObserving()
        ticker?.cancel()
        ticker = nil
        notices.showSummary(summary)
    }

    /// One second passed.
    func tick() {
        clock &+= 1
        switch machine.tick(at: now()) {
        case .finished(let summary)?: finish(summary)
        case .snoozeEnded?, nil: break
        }
    }

    private func startTicker() {
        guard runsTicker, ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.machine.isActive else { return }
                self.tick()
            }
        }
    }

    /// An app came forward. A blocked one is hidden, with a notice.
    func applicationActivated(_ app: FocusRunningApp) {
        guard machine.shouldBlock(bundleID: app.bundleID, at: now()), let bundleID = app.bundleID else { return }
        do {
            try apps.hide(app)
            machine.recordBlocked(bundleID: bundleID, name: app.name)
            notices.showBlocked(appName: app.name, goal: session?.configuration.displayGoal ?? "Focus")
        } catch {
            // Refused by the guard, or the app didn't hide: it wasn't held back, so it isn't
            // counted or announced as blocked.
        }
    }
}
