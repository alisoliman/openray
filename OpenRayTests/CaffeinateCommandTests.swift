import AppKit
import Testing

@testable import OpenRay

/// main #11's Caffeinate commands, ported to `CaffeinateCommandProvider`. The dashboard became the
/// Caffeinate scope; main's tests of the feature bar and ⌘1–⌘6 are superseded (see the merge report).
@MainActor
struct CaffeinateCommandTests {
    private let commands = [
        (id: "caffeinate.open", title: "Caffeinate"),
        (id: "caffeinate.start", title: "Start Caffeinate"),
        (id: "caffeinate.stop", title: "Stop Caffeinate"),
        (id: "caffeinate.toggle", title: "Toggle Caffeinate"),
    ]

    private func model(
        assertions: CaffeinateCommandAssertions, now: @escaping () -> Date = { .now }
    ) -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(),
            caffeinate: CaffeinateService(assertions: assertions, now: now, automaticallyMonitors: false))
    }

    private func command(_ id: String, in model: LauncherModel) throws -> LauncherItem {
        try #require(model.bindableCommands.first { $0.id == id })
    }

    private func isInScope(_ model: LauncherModel) -> Bool {
        model.destination == .search && model.section.providedScope?.id == CaffeinateCommandProvider.scope.id
    }

    @Test func exactCommandTitlesOutrankFavoriteAndRecentContent() {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        for command in commands {
            let fileID = "file./Users/example/Documents/\(command.title)"
            model.store.toggleFavorite(fileID)
            model.store.recordUse(of: fileID)
            model.query = command.title
            model.files.stop()
            #expect(model.results.first?.id == command.id)
            #expect(model.bindableCommands.contains { $0.id == command.id })
            #expect(CuratedCommand.supports(command.id))
        }
        #expect(assertions.createAttempts == 0)
        #expect(assertions.releaseAttempts.isEmpty)
    }

    @Test func openingTheScopeDoesNotStartASession() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        model.query = "Caffeinate"
        model.showActions = true
        model.perform(try #require(model.results.first { $0.id == "caffeinate.open" }))
        #expect(isInScope(model))
        #expect(!model.showActions)
        #expect(!model.caffeinate.isActive)
        #expect(assertions.createAttempts == 0)
        #expect(model.store.database.usage.first?.id == "caffeinate.open")
        // Every duration is listed, indefinitely first, and nothing claims the Mac is awake.
        let ids = model.results.map(\.id)
        #expect(ids.first == CaffeinateCommandProvider.durationRowID(.indefinitely))
        #expect(CaffeinateDuration.allCases.allSatisfy { ids.contains(CaffeinateCommandProvider.durationRowID($0)) })
        #expect(!ids.contains(CaffeinateCommandProvider.stopRowID))
    }

    @Test func scopeRowsStartUpdateAndStopWithoutLeavingTheScope() throws {
        let assertions = CaffeinateCommandAssertions()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = model(assertions: assertions, now: { now })
        defer { model.stop() }
        model.perform(try command("caffeinate.open", in: model))

        model.perform(try #require(model.results.first { $0.id == CaffeinateCommandProvider.durationRowID(.oneHour) }))
        #expect(model.caffeinate.deadline == now.addingTimeInterval(3_600))
        #expect(isInScope(model))
        #expect(model.feedback?.text.contains("1 hour") == true)
        // Active: Stop leads the list, and a new length reuses the same assertion.
        #expect(model.results.first?.id == CaffeinateCommandProvider.stopRowID)
        #expect(model.results.first?.subtitle.contains("Remaining") == true)

        model.query = "90"
        let custom = try #require(model.results.first)
        #expect(custom.id == CaffeinateCommandProvider.customRowID)
        #expect(custom.title == "Keep Awake for 90 Minutes")
        model.perform(custom)
        #expect(model.caffeinate.deadline == now.addingTimeInterval(5_400))
        #expect(assertions.createAttempts == 1)

        model.query = ""
        model.perform(try #require(model.results.first { $0.id == CaffeinateCommandProvider.stopRowID }))
        #expect(!model.caffeinate.isActive)
        #expect(assertions.releasedIDs.count == 1)
        #expect(isInScope(model))
    }

    @Test(arguments: ["0", "1441", "99999"])
    func typedMinutesOutsideTheRangeAreRefused(query: String) throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        model.perform(try command("caffeinate.open", in: model))
        model.query = query
        let row = try #require(model.results.first)
        #expect(row.id == CaffeinateCommandProvider.customRowID)
        #expect(row.title == "Enter 1–1,440 minutes")
        if case .provided(let ref) = row.action { #expect(ref.has(.unavailable)) } else { Issue.record("Not a provided row") }
        #expect(CaffeinateCommandProvider.typedMinutes("45 min") == 45)
        #expect(CaffeinateCommandProvider.typedMinutes("forty") == nil)
        #expect(assertions.createAttempts == 0)
    }

    @Test func exactAliasesDispatchAllFourCommandsFromOtherSections() {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let bindings = [
            CommandBinding(targetID: "caffeinate.open", alias: "coffee"),
            CommandBinding(targetID: "caffeinate.start", alias: "awake"),
            CommandBinding(targetID: "caffeinate.stop", alias: "rest"),
            CommandBinding(targetID: "caffeinate.toggle", alias: "flip"),
        ]
        for binding in bindings { #expect(model.store.saveCommandBinding(binding)) }

        model.navigate(to: .notes)
        model.query = "  CoFfEe  "
        #expect(model.results.map(\.id) == ["caffeinate.open"])
        model.performSelected()
        #expect(isInScope(model))
        #expect(!model.caffeinate.isActive)

        model.navigate(to: .calculator)
        model.query = "AWAKE"
        #expect(model.results.map(\.id) == ["caffeinate.start"])
        model.performSelected()
        // The quick commands leave the launcher where it was (it hides on success).
        #expect(model.section == .calculator)
        #expect(model.query == "AWAKE")
        #expect(model.caffeinate.isActive)
        #expect(model.caffeinate.deadline == nil)

        model.navigate(to: .snippets)
        model.query = "flip"
        #expect(model.results.map(\.id) == ["caffeinate.toggle"])
        model.performSelected()
        #expect(!model.caffeinate.isActive)
        model.performSelected()
        #expect(model.caffeinate.isActive)
        #expect(model.section == .snippets)

        model.navigate(to: .quicklinks)
        model.query = "rest"
        #expect(model.results.map(\.id) == ["caffeinate.stop"])
        model.performSelected()
        #expect(!model.caffeinate.isActive)
        #expect(model.section == .quicklinks)
        #expect(assertions.createAttempts == 2)
        #expect(assertions.releasedIDs.count == 2)
        #expect(Set(model.store.database.usage.map(\.id)) == Set(commands.map(\.id)))
    }

    @Test func boundQuickCommandsPreserveNavigationWhileOpenShowsTheScope() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        for (index, command) in commands.enumerated() {
            #expect(
                model.store.saveCommandBinding(
                    CommandBinding(
                        targetID: command.id, shortcut: CommandShortcut(keyCode: UInt32(index), modifiers: [.control, .option]))))
        }
        model.showActions = true
        model.performBoundCommand(targetID: "caffeinate.open")
        #expect(isInScope(model))
        #expect(!model.showActions)
        #expect(!model.caffeinate.isActive)

        model.navigate(to: .notes)
        model.query = "A note in progress"
        model.performBoundCommand(targetID: "caffeinate.start")
        #expect(model.caffeinate.isActive)
        #expect(model.section == .notes)
        #expect(model.query == "A note in progress")

        model.openAI()
        model.performBoundCommand(targetID: "caffeinate.stop")
        #expect(model.destination == .ai)
        #expect(!model.caffeinate.isActive)

        model.performBoundCommand(targetID: "caffeinate.toggle")
        #expect(model.caffeinate.isActive)
        #expect(model.destination == .ai)
        model.performBoundCommand(targetID: "caffeinate.toggle")
        #expect(!model.caffeinate.isActive)
        #expect(assertions.createAttempts == 2)
        #expect(assertions.releasedIDs.count == 2)
        #expect(Set(model.store.database.usage.map(\.id)) == Set(commands.map(\.id)))
    }

    @Test func removedAndSuppressedShortcutsCannotStartASession() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let binding = CommandBinding(
            targetID: "caffeinate.start", alias: "awake", shortcut: CommandShortcut(keyCode: 8, modifiers: [.control, .option]))
        #expect(model.store.saveCommandBinding(binding))

        model.beginShortcutRecording()
        model.performBoundCommand(targetID: binding.targetID)
        model.endShortcutRecording()
        model.beginCommandBindingEditing()
        model.performBoundCommand(targetID: binding.targetID)
        model.endCommandBindingEditing()
        #expect(!model.caffeinate.isActive)

        #expect(model.removeCommandBinding(for: binding.targetID))
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.store.database.aliasTarget(for: "awake") == nil)
        #expect(!model.caffeinate.isActive)
        #expect(assertions.createAttempts == 0)
        #expect(model.store.database.usage.isEmpty)
    }

    @Test func sessionSurvivesNavigationUntilTheModelStops() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        #expect(model.caffeinate.start(minutes: 30))
        let deadline = try #require(model.caffeinate.deadline)
        let activeIDs = assertions.activeIDs

        model.perform(try command("caffeinate.open", in: model))
        model.goBack()
        #expect(model.section == .home)
        model.navigate(to: .notes)
        model.openAI()
        model.leaveAI()
        model.panelDidHide()
        model.panelWillShow()
        #expect(model.caffeinate.isActive)
        #expect(model.caffeinate.deadline == deadline)
        #expect(assertions.activeIDs == activeIDs)
        #expect(assertions.releaseAttempts.isEmpty)

        model.stop()
        model.stop()
        #expect(!model.caffeinate.isActive)
        #expect(model.caffeinate.deadline == nil)
        #expect(assertions.activeIDs.isEmpty)
        #expect(Set(assertions.releasedIDs) == activeIDs)
        #expect(assertions.releaseAttempts.count == 1)
    }

    @Test func pendingCustomDurationSurvivesNavigationAndHideWithoutStarting() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        model.caffeinateDraft.refresh(from: model.caffeinate)
        model.caffeinateDraft.duration = nil
        model.caffeinateDraft.customMinutes = "90"

        model.perform(try command("caffeinate.open", in: model))
        model.goBack()
        model.panelDidHide()
        model.panelWillShow()
        // The Settings pane runs this same synchronization when it appears.
        model.caffeinate.refresh()
        model.caffeinateDraft.refresh(from: model.caffeinate)
        #expect(model.caffeinateDraft.duration == nil)
        #expect(model.caffeinateDraft.customMinutes == "90")
        #expect(model.caffeinateDraft.hasPendingChanges)
        #expect(!model.caffeinate.isActive)
        #expect(assertions.createAttempts == 0)
    }

    @Test func pendingDurationIsIndependentOfActiveChangesUntilExplicitlyApplied() {
        let assertions = CaffeinateCommandAssertions()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = model(assertions: assertions, now: { now })
        defer { model.stop() }
        model.caffeinateDraft.refresh(from: model.caffeinate)
        model.caffeinateDraft.duration = nil
        model.caffeinateDraft.customMinutes = "90"

        #expect(model.caffeinate.start(minutes: 30))
        model.caffeinateDraft.refresh(from: model.caffeinate)
        #expect(model.caffeinateDraft.customMinutes == "90")
        #expect(model.caffeinateDraft.duration == nil)
        #expect(model.caffeinateDraft.hasPendingChanges)
        #expect(model.caffeinate.deadline == now.addingTimeInterval(1_800))

        #expect(model.caffeinateDraft.start(using: model.caffeinate))
        #expect(model.caffeinate.deadline == now.addingTimeInterval(5_400))
        #expect(!model.caffeinateDraft.hasPendingChanges)
        #expect(assertions.createAttempts == 1)
        #expect(assertions.releaseAttempts.isEmpty)
    }

    @Test func untouchedControlsFollowExternalDurationBeforeSubmission() {
        let assertions = CaffeinateCommandAssertions()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = model(assertions: assertions, now: { now })
        defer { model.stop() }
        #expect(model.caffeinate.start(minutes: 30))
        model.caffeinateDraft.refresh(from: model.caffeinate)
        #expect(model.caffeinateDraft.duration?.seconds == 1_800)
        #expect(!model.caffeinateDraft.hasPendingChanges)

        #expect(model.caffeinate.start(minutes: 60))
        // Submit before the pane has seen the changed deadline.
        #expect(model.caffeinateDraft.start(using: model.caffeinate))
        #expect(model.caffeinateDraft.duration?.seconds == 3_600)
        #expect(model.caffeinate.deadline == now.addingTimeInterval(3_600))
        #expect(model.caffeinate.start())
        model.caffeinateDraft.refresh(from: model.caffeinate)
        #expect(model.caffeinateDraft.duration == .indefinitely)
        #expect(assertions.createAttempts == 1)
    }

    @Test func invalidAndFailedSubmissionsKeepThePendingDurationForCorrectionAndRetry() {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let draft = model.caffeinateDraft
        draft.duration = nil
        draft.customMinutes = "0"
        #expect(!draft.start(using: model.caffeinate))
        #expect(draft.validationMessage != nil)
        #expect(draft.hasPendingChanges)
        #expect(assertions.createAttempts == 0)

        draft.customMinutes = "90"
        #expect(draft.validationMessage == nil)
        assertions.failCreation = true
        #expect(!draft.start(using: model.caffeinate))
        draft.refresh(from: model.caffeinate)
        #expect(draft.duration == nil)
        #expect(draft.customMinutes == "90")
        #expect(draft.hasPendingChanges)
        #expect(!model.caffeinate.isActive)

        assertions.failCreation = false
        #expect(draft.start(using: model.caffeinate))
        #expect(model.caffeinate.remainingSeconds == 5_400)
        #expect(!draft.hasPendingChanges)
    }

    @Test(arguments: [false, true])
    func failedOperationsExplainThemselvesWithoutRecordingUsage(bound: Bool) throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let start = try command("caffeinate.start", in: model)
        let stop = try command("caffeinate.stop", in: model)
        let toggle = try command("caffeinate.toggle", in: model)
        if bound {
            for (index, command) in [start, stop, toggle].enumerated() {
                #expect(
                    model.store.saveCommandBinding(
                        CommandBinding(
                            targetID: command.id, shortcut: CommandShortcut(keyCode: UInt32(index), modifiers: [.control, .option]))))
            }
        }
        func perform(_ command: LauncherItem) {
            if bound { model.performBoundCommand(targetID: command.id) } else { model.perform(command) }
        }
        assertions.failCreation = true
        model.navigate(to: .notes)
        perform(start)
        #expect(!model.caffeinate.isActive)
        #expect(model.feedback?.text.contains("Simulated sleep assertion failure") == true)
        #expect(model.section == .notes)
        #expect(model.store.database.usage.isEmpty)

        perform(toggle)
        #expect(!model.caffeinate.isActive)
        #expect(model.feedback?.text.contains("Simulated sleep assertion failure") == true)
        #expect(model.store.database.usage.isEmpty)

        assertions.failCreation = false
        perform(start)
        #expect(model.caffeinate.isActive)
        let usage = model.store.database.usage
        let activeIDs = assertions.activeIDs
        assertions.failRelease = true
        perform(stop)
        #expect(model.caffeinate.isActive)
        #expect(model.feedback?.text.contains("Simulated assertion release failure") == true)
        #expect(model.store.database.usage == usage)
        #expect(assertions.activeIDs == activeIDs)

        assertions.failRelease = false
        perform(stop)
        #expect(!model.caffeinate.isActive)
        #expect(model.caffeinate.errorMessage == nil)
        #expect(model.store.database.usage.first?.id == "caffeinate.stop")
    }

    @Test func stoppingAnInactiveSessionIsIdempotent() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let command = try command("caffeinate.stop", in: model)
        model.navigate(to: .notes)
        model.query = "Keep my place"
        model.perform(command)
        model.perform(command)
        #expect(model.section == .notes)
        #expect(model.query == "Keep my place")
        #expect(!model.caffeinate.isActive)
        #expect(model.caffeinate.errorMessage == nil)
        #expect(assertions.createAttempts == 0)
        #expect(assertions.releaseAttempts.isEmpty)
    }

    @Test func menuBarCupShowsOnlyWhileActiveAndOpenRaysMenuStartsASession() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let provider = CaffeinateCommandProvider()
        let extra = try #require(provider.commands(in: model).first { $0.id == CaffeinateCommandProvider.menuBarID })
        #expect(extra.mode == .menuBar)
        #expect(provider.menuBarExtraIsShownByDefault(extra))
        #expect(provider.menuBarExtra(for: extra, in: model) == nil)
        #expect(!MenuBarExtrasModel.snapshots(in: model).contains { $0.id == CaffeinateCommandProvider.menuBarID })

        // OpenRay's own menu offers every duration while it's off.
        let items = CaffeinateCommandProvider.menuItems(in: model)
        let durations = try #require(items.first { $0.id == "durations" })
        #expect(durations.children.count == CaffeinateDuration.allCases.count)
        durations.children.first { $0.id == "duration.thirtyMinutes" }?.perform?()
        #expect(model.caffeinate.remainingSeconds == 1_800)

        let content = try #require(provider.menuBarExtra(for: extra, in: model))
        #expect(content.symbol == "cup.and.saucer.fill")
        #expect(content.accessibilityLabel.contains("Caffeinate active"))
        #expect(MenuBarExtrasModel.snapshots(in: model).contains { $0.id == CaffeinateCommandProvider.menuBarID })
        content.items.first { $0.id == "stop" }?.perform?()
        #expect(!model.caffeinate.isActive)
    }
}

@MainActor
private final class CaffeinateCommandAssertions: CaffeinatePowerAssertions {
    var createAttempts = 0
    var releaseAttempts: [UInt32] = []
    var releasedIDs: [UInt32] = []
    var activeIDs: Set<UInt32> = []
    var failCreation = false
    var failRelease = false
    private var nextID: UInt32 = 1

    func create() throws -> UInt32 {
        createAttempts += 1
        guard !failCreation else { throw LibraryValidationError("Simulated sleep assertion failure.") }
        let id = nextID
        nextID += 1
        activeIDs.insert(id)
        return id
    }

    func release(_ id: UInt32) throws {
        releaseAttempts.append(id)
        guard !failRelease else { throw LibraryValidationError("Simulated assertion release failure.") }
        guard activeIDs.remove(id) != nil else { throw LibraryValidationError("Assertion was already released.") }
        releasedIDs.append(id)
    }
}
