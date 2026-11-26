import AppKit
import Testing

@testable import OpenRay

/// main #10's Pomodoro: the service it shipped, and its provider, scope, Settings validation and
/// menu bar extra on the 2.0 architecture.
@MainActor
struct PomodoroTests {
    @MainActor
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    private func service(
        store: LibraryStore = LibraryStore(fileURL: nil), clock: Clock, sounds: Counter = Counter()
    ) -> PomodoroService {
        PomodoroService(store: store, now: { clock.date }, playCompletionSound: { sounds.count += 1 })
    }

    private func model() -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), pomodoroSound: {})
    }

    // MARK: Service

    @Test func defaultsMatchMainAndAFocusSessionCompletesFromItsDeadline() {
        let clock = Clock()
        let pomodoro = service(clock: clock)
        #expect(pomodoro.configuration == PomodoroConfiguration())
        #expect(pomodoro.configuration.focusMinutes == 25)
        #expect(pomodoro.configuration.dailyGoal == 8)
        #expect(pomodoro.state.phase == .focus)
        #expect(pomodoro.state.status == .ready)

        pomodoro.start()
        #expect(pomodoro.state.status == .running)
        clock.date += 10 * 60
        pomodoro.refresh()
        #expect(pomodoro.remainingSeconds == 15 * 60)
        // A Mac asleep past the deadline completes the phase on the next check.
        clock.date += 60 * 60
        pomodoro.refresh()
        #expect(pomodoro.state.phase == .shortBreak)
        #expect(pomodoro.state.status == .ready)
        #expect(pomodoro.state.completedInCycle == 1)
        #expect(pomodoro.completedToday == 1)
        #expect(pomodoro.focusMinutesToday == 25)
        #expect(pomodoro.recentSessions.first?.completedAt == Date(timeIntervalSince1970: 1_800_000_000 + 25 * 60))
    }

    @Test func pauseKeepsTheRemainingTimeAndOnlyCompletedFocusCounts() {
        let clock = Clock()
        let pomodoro = service(clock: clock)
        pomodoro.start()
        clock.date += 5 * 60
        pomodoro.pause()
        #expect(pomodoro.state.status == .paused)
        clock.date += 60 * 60
        pomodoro.refresh()
        #expect(pomodoro.remainingSeconds == 20 * 60)
        pomodoro.start()
        clock.date += 20 * 60
        pomodoro.refresh()
        #expect(pomodoro.completedToday == 1)
        // Skipping the break and resetting add nothing.
        pomodoro.skipBreak()
        #expect(pomodoro.state.phase == .focus)
        pomodoro.start()
        clock.date += 60
        pomodoro.reset()
        #expect(pomodoro.state == .ready(phase: .focus, configuration: pomodoro.configuration, completedInCycle: 0))
        #expect(pomodoro.completedToday == 1)
    }

    @Test func automaticBreaksStartAtTheCheckAndALongBreakEndsTheCycle() {
        let clock = Clock()
        let pomodoro = service(clock: clock)
        var configuration = pomodoro.configuration
        configuration.sessionsBeforeLongBreak = 2
        configuration.automaticallyStartBreaks = true
        configuration.focusMinutes = 1
        #expect(pomodoro.saveConfiguration(configuration))
        for expected in [PomodoroPhase.shortBreak, .longBreak] {
            pomodoro.start()
            clock.date += 60
            pomodoro.refresh()
            #expect(pomodoro.state.phase == expected)
            #expect(pomodoro.state.status == .running)
            clock.date += 60 * 60
            pomodoro.refresh()
            #expect(pomodoro.state.phase == .focus)
            // Focus never starts on its own.
            #expect(pomodoro.state.status == .ready)
        }
        #expect(pomodoro.state.completedInCycle == 0)
        #expect(pomodoro.completedToday == 2)
    }

    @Test func invalidSettingsAreRefusedAndValidOnesApplyToTheNextPhase() {
        let clock = Clock()
        let pomodoro = service(clock: clock)
        var invalid = pomodoro.configuration
        invalid.focusMinutes = 181
        #expect(!pomodoro.saveConfiguration(invalid))
        #expect(pomodoro.errorMessage?.contains("1–180") == true)
        #expect(pomodoro.configuration.focusMinutes == 25)

        pomodoro.start()
        var valid = pomodoro.configuration
        valid.focusMinutes = 50
        #expect(pomodoro.saveConfiguration(valid))
        #expect(pomodoro.errorMessage == nil)
        // The running phase keeps its length.
        #expect(pomodoro.state.durationSeconds == 25 * 60)
        pomodoro.reset()
        #expect(pomodoro.state.durationSeconds == 50 * 60)
    }

    @Test func timerStateSurvivesARelaunchAndAnOverdueBreakCompletes() throws {
        let clock = Clock()
        let store = LibraryStore(fileURL: nil)
        let first = service(store: store, clock: clock)
        first.start()
        clock.date += 25 * 60
        first.refresh()
        first.start()
        // A fresh service on the same library, as after a relaunch, picks the break up.
        let second = service(store: store, clock: clock)
        #expect(second.state.phase == .shortBreak)
        #expect(second.state.status == .running)
        clock.date += 6 * 60
        second.refresh()
        #expect(second.state.phase == .focus)
        #expect(second.state.status == .ready)
        #expect(second.completedToday == 1)
        try store.database.validate()
    }

    @Test func theChimeIsTheOnlySoundAndOnlyWhenItsOn() {
        let clock = Clock()
        let sounds = Counter()
        let pomodoro = service(clock: clock, sounds: sounds)
        pomodoro.start()
        clock.date += 25 * 60
        pomodoro.refresh()
        #expect(sounds.count == 1)
        var quiet = pomodoro.configuration
        quiet.playSound = false
        #expect(pomodoro.saveConfiguration(quiet))
        pomodoro.start()
        clock.date += 5 * 60
        pomodoro.refresh()
        #expect(sounds.count == 1)
        // The default chime checks the side-effect guard, so the test host stays silent.
        #expect(SideEffectGuard.isTestHost)
        PomodoroService.playSystemSound()
    }

    // MARK: Commands, scope and menu bar

    @Test func commandsKeepMainsIDsAndStartFromTheLauncherShowsTheTimer() throws {
        let model = model()
        defer { model.stop() }
        let ids = model.bindableCommands.map(\.id)
        #expect(ids.contains(PomodoroCommandProvider.openID))
        #expect(ids.contains(PomodoroCommandProvider.startID))
        model.query = "Start Pomodoro"
        #expect(model.results.first?.id == PomodoroCommandProvider.startID)
        model.query = "Pomodoro"
        #expect(model.results.first?.id == PomodoroCommandProvider.openID)

        // Run from a hotkey (no panel): the timer starts and the launcher stays where it was.
        let start = try #require(model.bindableCommands.first { $0.id == PomodoroCommandProvider.startID })
        model.navigate(to: .notes)
        model.perform(start)
        #expect(model.pomodoro.state.status == .running)
        #expect(model.section == .notes)
        #expect(model.store.database.usage.contains { $0.id == PomodoroCommandProvider.startID })
    }

    @Test func theScopeOffersWhatTheTimerCanDoNow() throws {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .provided(PomodoroCommandProvider.scope))
        var rows = model.results
        #expect(rows.first?.id == PomodoroCommandProvider.primaryRowID)
        #expect(rows.first?.title == "Start Focus")
        #expect(!rows.contains { $0.id == PomodoroCommandProvider.resetRowID })
        #expect(!rows.contains { $0.id == PomodoroCommandProvider.skipRowID })

        model.perform(try #require(rows.first))
        #expect(model.pomodoro.state.status == .running)
        rows = model.results
        #expect(rows.first?.title == "Pause")
        #expect(rows.contains { $0.id == PomodoroCommandProvider.resetRowID })
        model.perform(try #require(rows.first))
        #expect(model.pomodoro.state.status == .paused)
        #expect(model.results.first?.title == "Resume")

        // The preview carries the dashboard and the rhythm.
        let ref = ProvidedRef(provider: "pomodoro", id: PomodoroCommandProvider.primaryRowID)
        let first = try #require(model.results.first)
        let preview = try #require(PomodoroCommandProvider().preview(for: first, ref: ref, in: model))
        #expect(preview.content != nil)
        #expect(preview.metadata.contains { $0.label == "Focus" && $0.value == "25 min" })

        model.query = "reset"
        #expect(model.results.map(\.id) == [PomodoroCommandProvider.resetRowID])
        model.perform(try #require(model.results.first))
        #expect(model.pomodoro.state.status == .ready)
    }

    @Test func menuBarTimerShowsWhileAPhaseRunsAndHidesWhenIdle() throws {
        let model = model()
        defer { model.stop() }
        let provider = PomodoroCommandProvider()
        let extra = try #require(provider.commands(in: model).first { $0.id == PomodoroCommandProvider.menuBarID })
        #expect(extra.mode == .menuBar)
        #expect(provider.menuBarExtraIsShownByDefault(extra))
        #expect(provider.menuBarExtra(for: extra, in: model) == nil)

        model.pomodoro.start()
        let running = try #require(provider.menuBarExtra(for: extra, in: model))
        #expect(running.title?.contains(":") == true)
        #expect(running.refresh == .seconds(1))
        #expect(running.items.contains { $0.id == "primary" && $0.title == "Pause" })
        running.items.first { $0.id == "primary" }?.perform?()
        #expect(model.pomodoro.state.status == .paused)
        let paused = try #require(provider.menuBarExtra(for: extra, in: model))
        #expect(paused.symbol == "pause.circle")
        #expect(paused.refresh == nil)
        #expect(MenuBarExtrasModel.snapshots(in: model).contains { $0.id == PomodoroCommandProvider.menuBarID })
    }

    @Test func pomodoroAndFocusShareNoIDsShortcutsOrMenuBarItems() {
        let model = model()
        defer { model.stop() }
        let pomodoro = Set(PomodoroCommandProvider().commands(in: model).map(\.id))
        let focus = Set(FocusCommandProvider().commands(in: model).map(\.id))
        #expect(pomodoro.isDisjoint(with: focus))
        #expect(pomodoro.allSatisfy { $0.hasPrefix("pomodoro.") })
        #expect(!PomodoroCommandProvider.registration.acceptsBinding("focus.start"))
        #expect(!FocusCommandProvider.registration.acceptsBinding("pomodoro.start"))
        #expect(PomodoroCommandProvider.menuBarID != FocusCommandProvider.menuBarID)
        let caffeinate = Set(CaffeinateCommandProvider().commands(in: model).map(\.id))
        let system = Set(SystemCommandProvider().commands(in: model).map(\.id))
        #expect(caffeinate.isDisjoint(with: system))
    }
}
