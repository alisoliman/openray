import AppKit
import Foundation
import Testing

@testable import OpenRay

/// Menu bar extras: which show, what they say as state and time change, and the preferences
/// behind them. Only the model is exercised; the status-item controller never runs in tests.
@MainActor
struct MenuBarExtrasTests {
    private struct Harness {
        let model: LauncherModel
        let focus: FocusController
        let apps: FakeFocusApps
        let clock: MutableClock
        let calendar: CalendarService
        let calendarSource: FakeCalendarSource
        let notesPresenter: FakeNotesPresenter
        let notesCenter: NotesCenter
    }

    private func make(calendarAccess: CalendarAccess = .fullAccess, events: [CalendarEvent] = []) -> Harness {
        let clock = MutableClock(CalendarFixture.date(10, 7))
        let apps = FakeFocusApps()
        let focus = FocusController(apps: apps, notices: FakeFocusNotices(), now: { clock.now }, runsTicker: false)
        let source = FakeCalendarSource(access: calendarAccess)
        source.stored = events
        let calendar = CalendarService(
            source: source, opener: FakeURLOpener(), now: { clock.now }, calendar: CalendarFixture.calendar)
        calendar.refresh()
        let presenter = FakeNotesPresenter()
        let center = NotesCenter(makePresenter: { _ in presenter })
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: [
                NotesCommandProvider(center: center), CalendarCommandProvider(service: calendar),
                FocusCommandProvider(controller: focus), MenuBarCommandProvider(),
            ]))
        return Harness(
            model: model, focus: focus, apps: apps, clock: clock, calendar: calendar, calendarSource: source,
            notesPresenter: presenter, notesCenter: center)
    }

    private func snapshot(_ id: String, in model: LauncherModel) -> MenuBarExtraSnapshot? {
        MenuBarExtrasModel.snapshots(in: model).first { $0.id == id }
    }

    @Test func theFocusTimerShowsOnlyDuringASessionAndCountsDown() throws {
        let harness = make()
        #expect(snapshot(FocusCommandProvider.menuBarID, in: harness.model) == nil)
        try harness.focus.start(FocusFixture.configuration(minutes: 25))
        var timer = try #require(snapshot(FocusCommandProvider.menuBarID, in: harness.model))
        #expect(timer.content.title == "25:00")
        #expect(timer.content.symbol == "scope")
        #expect(timer.content.refresh == .seconds(1))
        #expect(timer.content.usesMonospacedDigits)
        harness.clock.now = harness.clock.now.addingTimeInterval(61)
        harness.focus.tick()
        timer = try #require(snapshot(FocusCommandProvider.menuBarID, in: harness.model))
        #expect(timer.content.title == "23:59")
        // Its menu pauses; the title and symbol follow.
        let pause = try #require(timer.content.items.first { $0.id == "pause" })
        pause.perform?()
        timer = try #require(snapshot(FocusCommandProvider.menuBarID, in: harness.model))
        #expect(timer.content.title == "Paused")
        #expect(timer.content.symbol == "pause.circle")
        #expect(timer.content.items.first { $0.id == "pause" }?.title == "Resume")
        try #require(timer.content.items.first { $0.id == "complete" }).perform?()
        #expect(snapshot(FocusCommandProvider.menuBarID, in: harness.model) == nil)
    }

    @Test func theFocusTimerRedrawsThroughObservationEveryTick() throws {
        let harness = make()
        try harness.focus.start(FocusFixture.configuration(minutes: 5))
        final class Flag: @unchecked Sendable { var raised = false }
        let changed = Flag()
        withObservationTracking {
            _ = MenuBarExtrasModel.snapshots(in: harness.model)
        } onChange: {
            changed.raised = true
        }
        harness.focus.tick()
        #expect(changed.raised)
    }

    @Test func extrasRespectTheirShownPreferenceAndDisabledCommands() throws {
        let harness = make()
        try harness.focus.start(FocusFixture.configuration())
        #expect(snapshot(FocusCommandProvider.menuBarID, in: harness.model) != nil)
        #expect(MenuBarExtras.setShown(false, commandID: FocusCommandProvider.menuBarID, in: harness.model.store))
        #expect(snapshot(FocusCommandProvider.menuBarID, in: harness.model) == nil)
        MenuBarExtras.setShown(true, commandID: FocusCommandProvider.menuBarID, in: harness.model.store)
        harness.model.store.update { $0.disabledCommandIDs.insert(FocusCommandProvider.menuBarID) }
        #expect(snapshot(FocusCommandProvider.menuBarID, in: harness.model) == nil)
    }

    @Test func theNotesToggleIsOffByDefaultAndAClickTogglesTheWindow() throws {
        let harness = make()
        #expect(snapshot(NotesCommandProvider.menuBarID, in: harness.model) == nil)
        // Running the command from the launcher adds it, and says so.
        let command = try #require(harness.model.commandItems.first { $0.id == NotesCommandProvider.menuBarID })
        #expect(harness.model.primaryTitle(for: command) == "Open Command")
        harness.model.perform(command)
        #expect(harness.model.feedback?.text.contains("Added") == true)
        let notes = try #require(snapshot(NotesCommandProvider.menuBarID, in: harness.model))
        #expect(notes.content.symbol == "note.text" && notes.content.title == nil)
        let click = try #require(notes.content.click)
        click()
        #expect(harness.notesPresenter.isVisible)
        click()
        #expect(!harness.notesPresenter.isVisible)
        // ⌘K offers the way back out.
        let actions = harness.model.actions(for: command)
        #expect(actions.contains { $0.title == "Remove from Menu Bar" })
    }

    @Test func theNextEventCountsDownWhenItIsSoon() throws {
        let standup = CalendarFixture.event("Standup", from: (10, 20), to: (10, 35), location: "https://zoom.us/j/42")
        let lunch = CalendarFixture.event("Lunch", from: (13, 0), to: (14, 0))
        let harness = make(events: [standup, lunch])
        // Off by default.
        #expect(snapshot(CalendarCommandProvider.menuBarID, in: harness.model) == nil)
        MenuBarExtras.setShown(true, commandID: CalendarCommandProvider.menuBarID, in: harness.model.store)
        var next = try #require(snapshot(CalendarCommandProvider.menuBarID, in: harness.model))
        #expect(next.content.title == "Standup · in 13 min")
        #expect(next.content.items.contains { $0.id == "join" })
        #expect(next.content.refresh == .seconds(30))
        harness.clock.now = CalendarFixture.date(10, 21)
        next = try #require(snapshot(CalendarCommandProvider.menuBarID, in: harness.model))
        #expect(next.content.title == "Standup · started 1 min ago")
        // After it ends, only meetings with a link count by default: Lunch has none.
        harness.clock.now = CalendarFixture.date(12, 30)
        #expect(snapshot(CalendarCommandProvider.menuBarID, in: harness.model) == nil)
        var preferences = CalendarPreferences.load(from: harness.model.store)
        preferences.menuBarOnlyMeetings = false
        preferences.save(to: harness.model.store)
        #expect(snapshot(CalendarCommandProvider.menuBarID, in: harness.model)?.content.title == "Lunch · in 30 min")
    }

    @Test func aHiddenCountdownWakesWhenTheNextMeetingEntersItsLeadTime() throws {
        // 11:09, with a 60-minute lead: the countdown starts at 10:09. It's 10:07 and nothing
        // else in the menu bar runs a timer.
        let review = CalendarFixture.event("Review", from: (11, 9), to: (11, 30), location: "https://zoom.us/j/7")
        let harness = make(events: [review])
        MenuBarExtras.setShown(true, commandID: CalendarCommandProvider.menuBarID, in: harness.model.store)
        var state = MenuBarExtrasModel.state(in: harness.model)
        #expect(state.snapshots.isEmpty)
        #expect(state.nextRefresh == .seconds(120))
        harness.clock.now = CalendarFixture.date(10, 9)
        state = MenuBarExtrasModel.state(in: harness.model)
        #expect(state.snapshots.first?.content.title == "Review · in 1 h")
        #expect(state.nextRefresh == .seconds(30))
        // With nothing coming up, it still looks again every five minutes for new events.
        harness.clock.now = CalendarFixture.date(12, 0)
        #expect(MenuBarExtrasModel.state(in: harness.model).nextRefresh == .seconds(300))
        // Turned off, it doesn't wake anything.
        MenuBarExtras.setShown(false, commandID: CalendarCommandProvider.menuBarID, in: harness.model.store)
        #expect(MenuBarExtrasModel.state(in: harness.model).nextRefresh == nil)
    }

    @Test func noCalendarAccessMeansNoEventItem() {
        let harness = make(calendarAccess: .denied)
        MenuBarExtras.setShown(true, commandID: CalendarCommandProvider.menuBarID, in: harness.model.store)
        #expect(snapshot(CalendarCommandProvider.menuBarID, in: harness.model) == nil)
    }

    @Test func theSoonestRefreshWins() {
        let snapshots = [
            MenuBarExtraSnapshot(id: "a", content: MenuBarExtraContent(title: "a", symbol: nil, accessibilityLabel: "a", refresh: .seconds(30))),
            MenuBarExtraSnapshot(id: "b", content: MenuBarExtraContent(title: "b", symbol: nil, accessibilityLabel: "b", refresh: .seconds(1))),
            MenuBarExtraSnapshot(id: "c", content: MenuBarExtraContent(title: "c", symbol: nil, accessibilityLabel: "c")),
        ]
        #expect(MenuBarExtrasModel.nextRefresh(snapshots) == .seconds(1))
        #expect(MenuBarExtrasModel.nextRefresh([snapshots[2]]) == nil)
    }

    @Test func openRaysOwnIconCanBeHiddenAndBroughtBackFromTheLauncher() throws {
        let harness = make()
        #expect(!MenuBarExtras.hidesOpenRayIcon(in: harness.model.store.database))
        let hide = try #require(harness.model.commandItems.first { $0.id == MenuBarCommandProvider.toggleIconID })
        #expect(hide.title == "Hide OpenRay from Menu Bar")
        harness.model.perform(hide)
        #expect(MenuBarExtras.hidesOpenRayIcon(in: harness.model.store.database))
        let show = try #require(harness.model.commandItems.first { $0.id == MenuBarCommandProvider.toggleIconID })
        #expect(show.title == "Show OpenRay in Menu Bar")
        harness.model.perform(show)
        #expect(!MenuBarExtras.hidesOpenRayIcon(in: harness.model.store.database))
        // The choice lives in commandPreferences, so the schema doesn't change.
        #expect(harness.model.store.database.commandPreferences[MenuBarExtras.storageKey]?[MenuBarExtras.openRayIconKey] == "shown")
    }

    @Test func theControllerDoesNothingInAnInertLaunch() {
        let harness = make()
        let controller = MenuBarExtrasController(guardrail: SideEffectGuard(mode: .testHost))
        controller.start(model: harness.model)
        // Nothing to observe from outside but its silence: stopping is safe and leaves nothing behind.
        controller.stop()
        #expect(SideEffectGuard(mode: .testHost).isInert)
    }
}
