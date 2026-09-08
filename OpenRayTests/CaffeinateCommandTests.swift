import AppKit
import Testing

@testable import OpenRay

@MainActor
struct CaffeinateCommandTests {
    private let commands = [
        (id: "caffeinate.open", title: "Caffeinate"),
        (id: "caffeinate.start", title: "Start Caffeinate"),
        (id: "caffeinate.stop", title: "Stop Caffeinate"),
        (id: "caffeinate.toggle", title: "Toggle Caffeinate"),
    ]

    private func model(assertions: CaffeinateCommandAssertions) -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(),
            caffeinate: CaffeinateService(assertions: assertions, automaticallyMonitors: false),
            aiFactory: { AIChatModel(engine: TestAIEngine()) })
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
            #expect(model.results.contains { $0.id == fileID })
            #expect(model.bindableCommands.contains { $0.id == command.id })
            #expect(CuratedCommand.supports(command.id))
        }
        #expect(assertions.createAttempts == 0)
        #expect(assertions.releaseAttempts.isEmpty)
    }

    @Test func openingTheDashboardDoesNotStartASession() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        model.query = "Caffeinate"
        model.showActions = true
        model.message = "Old message"

        model.perform(try #require(model.results.first { $0.id == "caffeinate.open" }))

        #expect(model.destination == .caffeinate)
        #expect(!model.showActions)
        #expect(model.message == nil)
        #expect(!model.files.isSearching)
        #expect(!model.caffeinate.isActive)
        #expect(assertions.createAttempts == 0)
        #expect(model.store.database.usage.first?.id == "caffeinate.open")
    }

    @Test(arguments: ["Caffeinate", "Start Caffeinate", "Stop Caffeinate", "Toggle Caffeinate"])
    func commandSearchesAreNotImportedIntoTheAIWorkspace(query: String) {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        model.query = query

        #expect(model.quickAI())

        #expect(model.destination == .ai)
        #expect(model.ai.draft.isEmpty)
        #expect(model.ai.messages.isEmpty)
        #expect(!model.caffeinate.isActive)
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
        #expect(model.destination == .caffeinate)
        #expect(!model.caffeinate.isActive)

        model.navigate(to: .calculator)
        model.query = "AWAKE"
        #expect(model.results.map(\.id) == ["caffeinate.start"])
        model.performSelected()
        #expect(model.destination == .search)
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
        #expect(model.destination == .search)
        #expect(model.section == .snippets)
        #expect(model.query == "flip")

        model.navigate(to: .clipboard)
        model.query = "rest"
        #expect(model.results.map(\.id) == ["caffeinate.stop"])
        model.performSelected()
        #expect(!model.caffeinate.isActive)
        #expect(model.destination == .search)
        #expect(model.section == .clipboard)
        #expect(model.query == "rest")
        #expect(assertions.createAttempts == 2)
        #expect(assertions.releasedIDs.count == 2)
        #expect(Set(model.store.database.usage.map(\.id)) == Set(commands.map(\.id)))
    }

    @Test func boundQuickCommandsPreserveNavigationWhileOpenRevealsTheDashboard() {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        for (index, command) in commands.enumerated() {
            #expect(
                model.store.saveCommandBinding(
                    CommandBinding(
                        targetID: command.id,
                        shortcut: CommandShortcut(keyCode: UInt32(index), modifiers: [.control, .option]))))
        }

        model.showActions = true
        model.performBoundCommand(targetID: "caffeinate.open")
        #expect(model.destination == .caffeinate)
        #expect(!model.showActions)
        #expect(!model.caffeinate.isActive)

        model.navigate(to: .notes)
        model.query = "A note in progress"
        model.performBoundCommand(targetID: "caffeinate.start")
        #expect(model.caffeinate.isActive)
        #expect(model.destination == .search)
        #expect(model.section == .notes)
        #expect(model.query == "A note in progress")

        model.openAI()
        model.performBoundCommand(targetID: "caffeinate.stop")
        #expect(model.destination == .ai)
        #expect(!model.caffeinate.isActive)

        model.openPomodoro()
        model.performBoundCommand(targetID: "caffeinate.toggle")
        #expect(model.caffeinate.isActive)
        #expect(model.destination == .pomodoro)
        model.performBoundCommand(targetID: "caffeinate.toggle")
        #expect(!model.caffeinate.isActive)
        #expect(model.destination == .pomodoro)
        #expect(model.section == .notes)
        #expect(model.query == "A note in progress")
        #expect(assertions.createAttempts == 2)
        #expect(assertions.releasedIDs.count == 2)
        #expect(Set(model.store.database.usage.map(\.id)) == Set(commands.map(\.id)))
    }

    @Test func removedAndSuppressedShortcutsCannotStartASession() {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let binding = CommandBinding(
            targetID: "caffeinate.start", alias: "awake",
            shortcut: CommandShortcut(keyCode: 8, modifiers: [.control, .option]))
        #expect(model.store.saveCommandBinding(binding))

        model.beginShortcutRecording()
        model.performBoundCommand(targetID: binding.targetID)
        model.endShortcutRecording()
        model.beginCommandBindingEditing()
        model.performBoundCommand(targetID: binding.targetID)
        model.endCommandBindingEditing()
        let note = QuickNote(title: "Draft", content: "Keep editing")
        model.editor = .note(note)
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.editor?.id == "note.\(note.id)")
        #expect(model.message?.contains("Save or cancel") == true)
        model.editor = nil

        #expect(model.removeCommandBinding(for: binding.targetID))
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.store.database.aliasTarget(for: "awake") == nil)
        #expect(model.destination == .search)
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

        model.openCaffeinate()
        model.goBack()
        #expect(model.destination == .search)
        #expect(model.section == .home)
        model.navigate(to: .notes)
        model.openAI()
        model.openPomodoro()
        model.openCaffeinate()
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

    @Test func dashboardIgnoresWorkspaceNumbersAndSessionSurvivesAIReturnTransitions() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let panel = LauncherPanel()
        panel.workspaceShortcutAction = model.selectWorkspaceShortcut
        #expect(model.caffeinate.start(minutes: 30))
        let deadline = try #require(model.caffeinate.deadline)
        let activeIDs = assertions.activeIDs
        model.openCaffeinate()
        let focus = model.focusRequest

        for index in 0..<6 {
            #expect(!model.selectWorkspaceShortcut(index))
            #expect(!panel.handleWorkspaceShortcut(try workspaceKeyEvent(String(index + 1))))
        }
        #expect(!model.quickAI())
        #expect(!model.cycleAIAction(1))
        #expect(model.destination == .caffeinate)
        #expect(model.focusRequest == focus)
        #expect(model.caffeinate.deadline == deadline)

        model.goBack()
        #expect(model.destination == .search)
        #expect(panel.handleWorkspaceShortcut(try workspaceKeyEvent("6")))
        #expect(model.destination == .ai)
        #expect(panel.handleWorkspaceShortcut(try workspaceKeyEvent("2")))
        #expect(model.ai.action == .rewrite)
        model.goBack()

        let query = "Help me describe this idea clearly."
        model.query = query
        #expect(model.quickAI())
        #expect(model.ai.action == .chat)
        #expect(model.ai.draft == query)
        model.goBack()
        #expect(model.destination == .search)
        #expect(model.section == .home)
        #expect(model.query == query)
        #expect(model.caffeinate.isActive)
        #expect(model.caffeinate.deadline == deadline)
        #expect(assertions.activeIDs == activeIDs)
        #expect(assertions.createAttempts == 1)
        #expect(assertions.releaseAttempts.isEmpty)
    }

    @Test(arguments: [false, true])
    func failedOperationsRevealTheDashboardWithoutRecordingUsage(bound: Bool) throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let start = try #require(model.bindableCommands.first { $0.id == "caffeinate.start" })
        let stop = try #require(model.bindableCommands.first { $0.id == "caffeinate.stop" })
        let toggle = try #require(model.bindableCommands.first { $0.id == "caffeinate.toggle" })
        if bound {
            for (index, command) in [start, stop, toggle].enumerated() {
                #expect(
                    model.store.saveCommandBinding(
                        CommandBinding(
                            targetID: command.id,
                            shortcut: CommandShortcut(keyCode: UInt32(index), modifiers: [.control, .option]))))
            }
        }
        func perform(_ command: LauncherItem) {
            if bound { model.performBoundCommand(targetID: command.id) } else { model.perform(command) }
        }
        assertions.failCreation = true

        model.navigate(to: .notes)
        perform(start)
        #expect(model.destination == .caffeinate)
        #expect(!model.caffeinate.isActive)
        #expect(model.caffeinate.errorMessage?.contains("Simulated sleep assertion failure") == true)
        #expect(model.store.database.usage.isEmpty)

        model.openAI()
        perform(toggle)
        #expect(model.destination == .caffeinate)
        #expect(!model.caffeinate.isActive)
        #expect(model.caffeinate.errorMessage?.contains("Simulated sleep assertion failure") == true)
        #expect(model.store.database.usage.isEmpty)

        assertions.failCreation = false
        model.openPomodoro()
        perform(start)
        #expect(model.caffeinate.isActive)
        #expect(model.caffeinate.errorMessage == nil)
        #expect(model.destination == .pomodoro)
        let usage = model.store.database.usage
        let activeIDs = assertions.activeIDs
        assertions.failRelease = true

        perform(stop)
        #expect(model.destination == .caffeinate)
        #expect(model.caffeinate.isActive)
        #expect(model.caffeinate.errorMessage?.contains("Simulated assertion release failure") == true)
        #expect(model.store.database.usage == usage)

        model.navigate(to: .clipboard)
        perform(toggle)
        #expect(model.destination == .caffeinate)
        #expect(model.caffeinate.isActive)
        #expect(model.caffeinate.errorMessage?.contains("Simulated assertion release failure") == true)
        #expect(assertions.activeIDs == activeIDs)
        #expect(model.store.database.usage == usage)

        assertions.failRelease = false
        model.navigate(to: .notes)
        perform(stop)
        #expect(model.destination == .search)
        #expect(model.section == .notes)
        #expect(!model.caffeinate.isActive)
        #expect(model.caffeinate.errorMessage == nil)
        #expect(model.store.database.usage.first?.id == "caffeinate.stop")
    }

    @Test func stoppingAnInactiveSessionIsIdempotent() throws {
        let assertions = CaffeinateCommandAssertions()
        let model = model(assertions: assertions)
        defer { model.stop() }
        let command = try #require(model.bindableCommands.first { $0.id == "caffeinate.stop" })
        model.navigate(to: .notes)
        model.query = "Keep my place"

        model.perform(command)
        model.perform(command)

        #expect(model.destination == .search)
        #expect(model.section == .notes)
        #expect(model.query == "Keep my place")
        #expect(!model.caffeinate.isActive)
        #expect(model.caffeinate.errorMessage == nil)
        #expect(assertions.createAttempts == 0)
        #expect(assertions.releaseAttempts.isEmpty)
    }

    private func workspaceKeyEvent(_ characters: String) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0))
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
