import AppKit
import Foundation
import Testing

@testable import OpenRay

// MARK: - Fakes

@MainActor
final class FakeFocusApps: FocusAppControlling {
    var onActivate: ((FocusRunningApp) -> Void)?
    var running: [FocusRunningApp] = []
    /// Models an app that refuses to hide.
    var failsToHide = false
    private(set) var isObserving = false
    private(set) var hidden: [String] = []

    func startObserving() { isObserving = true }
    func stopObserving() { isObserving = false }
    func runningApplications() -> [FocusRunningApp] { running }
    func hide(_ app: FocusRunningApp) throws {
        if failsToHide { throw FocusAppError.couldNotHide(app.name) }
        hidden.append(app.bundleID ?? app.name)
    }

    /// Brings an app forward, as NSWorkspace would report.
    func activate(_ app: FocusRunningApp) { onActivate?(app) }
}

@MainActor
final class FakeFocusNotices: FocusNoticePresenting {
    private(set) var blocked: [String] = []
    private(set) var started: [FocusConfiguration] = []
    private(set) var summaries: [FocusSummary] = []

    func showBlocked(appName: String, goal: String) { blocked.append(appName) }
    func showStarted(_ configuration: FocusConfiguration) { started.append(configuration) }
    func showSummary(_ summary: FocusSummary) { summaries.append(summary) }
}

enum FocusFixture {
    static let slack = FocusRunningApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", processIdentifier: 101)
    static let xcode = FocusRunningApp(bundleID: "com.apple.dt.Xcode", name: "Xcode", processIdentifier: 102)
    static let finder = FocusRunningApp(bundleID: "com.apple.finder", name: "Finder", processIdentifier: 103)

    static func configuration(minutes: Int? = 25, mode: FocusMode = .block, apps: Set<String> = [slack.bundleID!]) -> FocusConfiguration {
        FocusConfiguration(
            goal: "Write the report", duration: minutes.map { TimeInterval($0 * 60) }, mode: mode, categoryIDs: ["builtin.messaging"],
            bundleIDs: apps, categoryNames: ["Messaging"])
    }
}

// MARK: - State machine

struct FocusMachineTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    @Test func startPauseResumeAndRemainingTime() throws {
        var machine = FocusMachine()
        try machine.start(FocusFixture.configuration(), at: start)
        #expect(machine.session?.remaining(at: at(10)) == TimeInterval(15 * 60))
        try machine.pause(at: at(10))
        // Paused: the clock stops.
        #expect(machine.session?.remaining(at: at(20)) == TimeInterval(15 * 60))
        #expect(machine.session?.isPaused == true)
        try machine.resume(at: at(20))
        #expect(machine.session?.remaining(at: at(25)) == TimeInterval(10 * 60))
        #expect(machine.session?.focused(at: at(25)) == TimeInterval(15 * 60))
        #expect(throws: FocusMachine.Failure.alreadyRunning) { try machine.start(FocusFixture.configuration(), at: at(25)) }
    }

    @Test func snoozeLiftsBlockingForFiveMinutesWhileTheClockRuns() throws {
        var machine = FocusMachine()
        try machine.start(FocusFixture.configuration(), at: start)
        let slack = FocusFixture.slack.bundleID
        #expect(machine.shouldBlock(bundleID: slack, at: at(1), ownBundleID: nil))
        try machine.snooze(at: at(2))
        #expect(!machine.shouldBlock(bundleID: slack, at: at(4), ownBundleID: nil))
        #expect(machine.session?.remaining(at: at(4)) == TimeInterval(21 * 60))
        #expect(machine.tick(at: at(6)) == nil)
        #expect(machine.tick(at: at(7)) == .snoozeEnded)
        #expect(machine.session?.phase == .running)
        #expect(machine.shouldBlock(bundleID: slack, at: at(7), ownBundleID: nil))
        // Snoozing a paused session resumes it first.
        try machine.pause(at: at(8))
        try machine.snooze(at: at(9))
        #expect(machine.session?.isPaused == false)
        #expect(machine.session?.remaining(at: at(9)) == TimeInterval(17 * 60))
    }

    @Test func timeUpCompletesWithASummary() throws {
        var machine = FocusMachine()
        try machine.start(FocusFixture.configuration(minutes: 25), at: start)
        machine.recordBlocked(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        machine.recordBlocked(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        #expect(machine.tick(at: at(24.9)) == nil)
        guard case .finished(let summary)? = machine.tick(at: at(25)) else {
            Issue.record("The session should finish when time is up")
            return
        }
        #expect(summary.focused == TimeInterval(25 * 60))
        #expect(summary.finishedOnTime)
        #expect(summary.blockedAttempts == 2 && summary.blockedApps == ["Slack"])
        #expect(summary.text == "Focused 25 min on Write the report. Held back Slack 2 times.")
        #expect(machine.session == nil)
        #expect(machine.lastSummary == summary)
    }

    @Test func completingByHandAndInvalidSessions() throws {
        var machine = FocusMachine()
        #expect(throws: FocusMachine.Failure.notRunning) { try machine.pause(at: start) }
        #expect(throws: FocusMachine.Failure.notRunning) { try machine.complete(at: start) }
        #expect(throws: FocusMachine.Failure.invalidDuration) {
            try machine.start(FocusFixture.configuration(minutes: 25 * 60), at: start)
        }
        try machine.start(FocusFixture.configuration(minutes: nil), at: start)
        // No limit: the session never runs out.
        #expect(machine.tick(at: at(600)) == nil)
        let summary = try machine.complete(at: at(42))
        #expect(summary.focused == 42 * 60 && !summary.finishedOnTime && summary.planned == nil)
        #expect(summary.text == "Focused 42 min on Write the report.")
    }

    @Test func blockAndAllowListsDecideWhichAppsAreHeldBack() {
        let listed: Set<String> = ["com.tinyspeck.slackmacgap"]
        #expect(FocusBlockPolicy.shouldBlock(bundleID: "com.tinyspeck.slackmacgap", mode: .block, listed: listed, ownBundleID: nil))
        #expect(!FocusBlockPolicy.shouldBlock(bundleID: "com.apple.dt.Xcode", mode: .block, listed: listed, ownBundleID: nil))
        #expect(!FocusBlockPolicy.shouldBlock(bundleID: "com.tinyspeck.slackmacgap", mode: .allow, listed: listed, ownBundleID: nil))
        #expect(FocusBlockPolicy.shouldBlock(bundleID: "com.apple.dt.Xcode", mode: .allow, listed: listed, ownBundleID: nil))
        // The system and OpenRay itself are never held back, even by an allow list.
        #expect(!FocusBlockPolicy.shouldBlock(bundleID: "com.apple.finder", mode: .allow, listed: [], ownBundleID: nil))
        #expect(!FocusBlockPolicy.shouldBlock(bundleID: "app.openray", mode: .allow, listed: [], ownBundleID: "app.openray"))
        #expect(!FocusBlockPolicy.shouldBlock(bundleID: nil, mode: .allow, listed: [], ownBundleID: nil))
    }

    @Test func categoriesApplyEditsHideBuiltInsAndAddCustomOnes() {
        let records = [
            FocusCategoryRecord(id: "builtin.email", name: "Mail apps", bundleIDs: ["com.apple.mail"]),
            FocusCategoryRecord(id: "builtin.games", isHidden: true),
            FocusCategoryRecord(id: "custom-1", name: "Shopping", symbol: "cart", bundleIDs: ["com.amazon.app"]),
        ]
        let categories = FocusCategory.resolve(records)
        #expect(categories.map(\.id) == ["builtin.messaging", "builtin.email", "builtin.entertainment", "builtin.news", "custom-1"])
        #expect(categories[1].name == "Mail apps" && categories[1].bundleIDs == ["com.apple.mail"] && categories[1].isBuiltIn)
        #expect(categories.last?.isBuiltIn == false)
        #expect(FocusCategory.resolve([]).count == FocusCategory.builtIns.count)
        // A category's record round-trips through the library as optional fields.
        #expect(FocusCategory.resolve([categories[4].record]).last == categories[4])
    }

    @Test func goalsAndLengthsAreReadFromWhatYouType() {
        #expect(FocusFormat.parse("Write report 40m") == (40, "Write report"))
        #expect(FocusFormat.parse("1h30 deep work") == (90, "deep work"))
        #expect(FocusFormat.parse("taxes for 1.5 hours") == (90, "taxes"))
        #expect(FocusFormat.parse("review for 25 min") == (25, "review"))
        #expect(FocusFormat.parse("2h").minutes == 120)
        #expect(FocusFormat.parse("plain goal") == (nil, "plain goal"))
        #expect(FocusFormat.parse("0m nap").minutes == nil)
        #expect(FocusFormat.parse("room 101").minutes == nil)
        #expect(FocusFormat.clock(25 * 60) == "25:00")
        #expect(FocusFormat.clock(1_499.2) == "25:00")
        #expect(FocusFormat.clock(3_900) == "1:05:00")
        #expect(FocusFormat.duration(minutes: 90) == "1 h 30 min")
    }

    @Test func preferencesRoundTrip() {
        var preferences = FocusPreferences()
        preferences.minutes = 50
        preferences.mode = .allow
        preferences.categoryIDs = ["builtin.news"]
        preferences.lastGoal = "Ship it"
        #expect(FocusPreferences(preferences.values) == preferences)
        let configuration = preferences.configuration(goal: "", minutes: 0, categories: FocusCategory.builtIns)
        #expect(configuration.duration == nil)
        #expect(configuration.categoryNames == ["News"])
        #expect(configuration.bundleIDs.contains("com.apple.news"))
        #expect(configuration.displayGoal == "Focus")
    }
}

// MARK: - Controller

@MainActor
struct FocusControllerTests {
    private func make() -> (FocusController, FakeFocusApps, FakeFocusNotices, MutableClock) {
        let apps = FakeFocusApps()
        let notices = FakeFocusNotices()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let controller = FocusController(apps: apps, notices: notices, now: { clock.now }, runsTicker: false)
        return (controller, apps, notices, clock)
    }

    @Test func startingHidesBlockedAppsAndWatchesForMore() throws {
        let (controller, apps, notices, _) = make()
        apps.running = [FocusFixture.slack, FocusFixture.xcode, FocusFixture.finder]
        try controller.start(FocusFixture.configuration())
        #expect(apps.hidden == ["com.tinyspeck.slackmacgap"])
        // Hidden at the start counts as held back.
        #expect(controller.session?.blockedAttempts["com.tinyspeck.slackmacgap"] == 1)
        #expect(apps.isObserving)
        #expect(notices.started.map(\.goal) == ["Write the report"])
        apps.activate(FocusFixture.xcode)
        apps.activate(FocusFixture.slack)
        #expect(apps.hidden == ["com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap"])
        #expect(notices.blocked == ["Slack"])
        #expect(controller.session?.blockedAttempts["com.tinyspeck.slackmacgap"] == 2)
    }

    @Test func pausedAndSnoozedSessionsLetAppsThrough() throws {
        let (controller, apps, notices, clock) = make()
        try controller.start(FocusFixture.configuration())
        try controller.pause()
        apps.activate(FocusFixture.slack)
        try controller.resume()
        try controller.snooze()
        apps.activate(FocusFixture.slack)
        #expect(apps.hidden.isEmpty && notices.blocked.isEmpty)
        clock.now = clock.now.addingTimeInterval(5 * 60)
        controller.tick()
        apps.activate(FocusFixture.slack)
        #expect(notices.blocked == ["Slack"])
    }

    @Test func theMenuBarTimerCountsDownAndTheSessionEndsOnItsOwn() throws {
        let (controller, apps, notices, clock) = make()
        try controller.start(FocusFixture.configuration(minutes: 1))
        #expect(controller.timerText == "1:00")
        clock.now = clock.now.addingTimeInterval(15)
        controller.tick()
        #expect(controller.timerText == "0:45")
        try controller.pause()
        #expect(controller.timerText == "Paused")
        try controller.resume()
        clock.now = clock.now.addingTimeInterval(45)
        controller.tick()
        #expect(controller.session == nil)
        #expect(controller.timerText == nil)
        #expect(!apps.isObserving)
        #expect(notices.summaries.first?.finishedOnTime == true)
    }

    @Test func anAppThatDoesntHideIsntCountedAsBlocked() throws {
        let (controller, apps, notices, _) = make()
        try controller.start(FocusFixture.configuration())
        apps.failsToHide = true
        apps.activate(FocusFixture.slack)
        #expect(notices.blocked.isEmpty)
        #expect(controller.session?.blockedAttempts.isEmpty == true)
    }

    @Test func theLiveAppControlIsInertInTests() {
        let live = WorkspaceFocusAppControl(guardrail: SideEffectGuard(mode: .testHost))
        live.startObserving()
        #expect(live.runningApplications().isEmpty)
        #expect(throws: SideEffectGuard.Blocked.self) { try live.hide(FocusFixture.slack) }
        let notices = FocusNoticeCenter(guardrail: SideEffectGuard(mode: .verification))
        notices.showBlocked(appName: "Slack", goal: "Write")
        #expect(notices.lastNotice?.title == "Slack is blocked")
    }
}

// MARK: - Provider

@MainActor
struct FocusProviderTests {
    private func make() -> (LauncherModel, FocusController, FakeFocusApps, MutableClock) {
        let apps = FakeFocusApps()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let controller = FocusController(apps: apps, notices: FakeFocusNotices(), now: { clock.now }, runsTicker: false)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: [FocusCommandProvider(controller: controller)]))
        return (model, controller, apps, clock)
    }

    @Test func startScopeOffersTheTypedLengthFirstThenTheUsualOnes() throws {
        let (model, controller, _, _) = make()
        model.navigate(to: .provided(FocusCommandProvider.startScope))
        model.query = "Draft chapter 40m"
        let rows = model.results
        #expect(rows.first?.title == "Focus for 40 min")
        #expect(rows.first?.subtitle.hasPrefix("Draft chapter · Blocking Messaging") == true)
        #expect(rows.dropFirst().first?.title == "Focus for 25 min")
        #expect(rows.last?.title == "Focus with No Time Limit")
        model.perform(try #require(rows.first))
        let session = try #require(controller.session)
        #expect(session.configuration.goal == "Draft chapter")
        #expect(session.configuration.duration == TimeInterval(40 * 60))
        #expect(session.configuration.bundleIDs.contains("com.tinyspeck.slackmacgap"))
        // The next session remembers the goal and length.
        #expect(FocusPreferences.load(from: model.store).minutes == 40)
        #expect(FocusPreferences.load(from: model.store).lastGoal == "Draft chapter")
    }

    @Test func noTimeLimitIsRememberedForTheNextToggle() throws {
        let (model, controller, _, _) = make()
        model.navigate(to: .provided(FocusCommandProvider.startScope))
        model.perform(try #require(model.results.first { $0.id == "focus.length.0" }))
        #expect(controller.session?.configuration.duration == nil)
        #expect(FocusPreferences.load(from: model.store).minutes == 0)
        try controller.complete()
        let toggle = try #require(model.commandItems.first { $0.id == FocusCommandProvider.toggleID })
        model.perform(toggle)
        #expect(controller.session?.configuration.duration == nil)
    }

    @Test func sessionCommandsAppearWhileASessionRuns() throws {
        let (model, controller, _, _) = make()
        let idle = Set(model.commandItems.map(\.id))
        #expect(idle.contains(FocusCommandProvider.startID) && !idle.contains(FocusCommandProvider.pauseID))
        let toggle = try #require(model.commandItems.first { $0.id == FocusCommandProvider.toggleID })
        model.perform(toggle)
        #expect(controller.isActive)
        let running = Set(model.commandItems.map(\.id))
        #expect(running.isSuperset(of: [FocusCommandProvider.pauseID, FocusCommandProvider.snoozeID, FocusCommandProvider.completeID]))
        #expect(!running.contains(FocusCommandProvider.startID))
        let pause = try #require(model.commandItems.first { $0.id == FocusCommandProvider.pauseID })
        model.perform(pause)
        #expect(controller.session?.isPaused == true)
        #expect(model.commandItems.contains { $0.id == FocusCommandProvider.resumeID })
        model.perform(toggle)
        #expect(!controller.isActive)
        #expect(controller.lastSummary != nil)
        // Every session command can take an alias or a hotkey, even while hidden from search.
        CuratedCommand.$registrations.withValue([FocusCommandProvider.registration]) {
            #expect(CuratedCommand.supports(FocusCommandProvider.pauseID))
        }
        #expect(model.registry.bindableCommandItems(in: model).contains { $0.id == FocusCommandProvider.resumeID })
    }

    @Test func actionsSwitchModeAndCategoriesForTheNextSession() throws {
        let (model, _, _, _) = make()
        model.navigate(to: .provided(FocusCommandProvider.startScope))
        let row = try #require(model.results.first)
        let actions = model.actions(for: row)
        try #require(actions.first { $0.id == "focus.mode" }).perform()
        #expect(FocusPreferences.load(from: model.store).mode == .allow)
        try #require(actions.first { $0.id == "focus.category.builtin.news" }).perform()
        #expect(FocusPreferences.load(from: model.store).categoryIDs.contains("builtin.news"))
        try #require(actions.first { $0.id == "focus.category.builtin.messaging" }).perform()
        #expect(!FocusPreferences.load(from: model.store).categoryIDs.contains("builtin.messaging"))
    }
}
