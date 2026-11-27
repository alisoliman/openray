import AppKit
import Testing

@testable import OpenRay

/// Records the sampling each writing run asks for, so Regenerate's variation is visible.
@MainActor
final class SamplingAIEngine: AIEngine {
    var availability: AIAvailability = .available
    var reply = "A helpful reply."
    var samplings: [AIWritingSampling] = []
    var prompts: [String] = []
    var resetCount = 0

    func prepare(for action: AIAction) {}
    func reset() { resetCount += 1 }

    func stream(_ prompt: String, action: AIAction, onSnapshot: @escaping @MainActor (String) -> Void) async throws {
        prompts.append(prompt)
        samplings.append(.standard)
        onSnapshot(reply)
    }

    func stream(
        _ prompt: String, action: AIAction, instruction: String, sampling: AIWritingSampling,
        onSnapshot: @escaping @MainActor (AIResponseSnapshot) -> Void
    ) async throws {
        prompts.append(prompt)
        samplings.append(sampling)
        onSnapshot(AIResponseSnapshot(text: reply))
    }
}

/// The Raycast-parity writing flow (work items 1 and 3–9): run on invoke, a new selection wins
/// with earlier runs in history, the result-first keys, paste back with a HUD, Output Behavior
/// and Quick Fix. Every paste goes through fakes; nothing reaches another app.
@MainActor
struct WritingFlowTests {
    private func model(engine: any AIEngine = TestAIEngine()) -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine), pasteboard: NSPasteboard.withUniqueName())
    }

    /// Another app's process, which the fakes never touch.
    private var otherApp: NSRunningApplication {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.first { $0.processIdentifier != me } ?? .current
    }

    /// A captured selection. Its strict check refuses unless `strict` passes, to show ↵ never uses it.
    private func selection(
        _ text: String, source: String = "Notes", application: NSRunningApplication? = nil,
        focus: @escaping @MainActor () -> Bool? = { true }, strictPasses: Bool = false
    ) -> SelectedTextContext {
        var context = SelectedTextContext(text: text, application: application, sourceName: source) {
            if !strictPasses { throw LibraryValidationError("The original selection in \(source) changed.") }
        }
        context.range = NSRange(location: 0, length: (text as NSString).length)
        context.focusIsOriginal = focus
        return context
    }

    private func installHUD(on model: LauncherModel) -> FakeHUDPresenter {
        let presenter = FakeHUDPresenter()
        model.hud = HUDController(
            presenter: presenter, screenFrame: { CGRect(x: 0, y: 0, width: 1_440, height: 900) }, schedule: { _, _ in })
        return presenter
    }

    @MainActor
    final class PasteLog {
        var posted: [pid_t] = []
        var activated: [pid_t] = []
        var pastedTypes: Set<String> = []
        var pastedText: String?
    }

    /// A paste back that records instead of posting keys. `front` is the app it reports in front.
    private func installPaste(on model: LauncherModel, front: NSRunningApplication) -> PasteLog {
        let log = PasteLog()
        var paste = SyntheticInput.PasteEnvironment()
        paste.checkAllowed = {}
        paste.isTrusted = { true }
        paste.activate = { log.activated.append($0.processIdentifier) }
        paste.frontmostProcess = { front.processIdentifier }
        paste.secureInput = { false }
        paste.pause = {}
        let clipboard = model.clipboard
        paste.postPaste = { pid in
            log.posted.append(pid)
            log.pastedText = clipboard.readText()
            log.pastedTypes = Set(clipboard.snapshot().items.first?.map(\.type) ?? [])
        }
        var environment = PasteBack.Environment()
        environment.paste = paste
        environment.restoreDelay = .zero
        environment.sleep = { _ in }
        model.pasteBackEnvironment = environment
        return log
    }

    // MARK: 1. Run on invoke

    @Test func everySurfaceRunsAWritingCommandAtOnceOnTheSelection() async throws {
        let engine = RecordingAIEngine()
        let model = Slice7Fixtures.launcher(engine: engine, selection: "We was ready.")
        defer { model.stop() }
        // Root search.
        model.query = "Improve Writing"
        let row = try #require(model.results.first { $0.id == "ai.rewrite" })
        model.perform(row)
        #expect(model.destination == .ai)
        #expect(model.ai.isGenerating)
        await model.ai.waitForResponse()
        #expect(engine.actionPrompts == ["We was ready."])

        // A favorite.
        model.leaveAI()
        #expect(model.store.toggleFavorite("ai.rewrite"))
        let number = try #require(model.favoriteItems.firstIndex { $0.id == "ai.rewrite" }) + 1
        model.performNumber(number)
        await model.ai.waitForResponse()
        #expect(engine.actionPrompts.count == 2)

        // An alias, and a hotkey.
        model.leaveAI()
        let binding = CommandBinding(
            targetID: "ai.rewrite", alias: "iw", shortcut: CommandShortcut(keyCode: 34, modifiers: [.control, .option]))
        #expect(model.store.saveCommandBinding(binding))
        model.query = "iw"
        model.performSelected()
        await model.ai.waitForResponse()
        #expect(engine.actionPrompts.count == 3)
        model.leaveAI()
        model.performBoundCommand(targetID: "ai.rewrite")
        await model.ai.waitForResponse()
        #expect(engine.actionPrompts == Array(repeating: "We was ready.", count: 4))
        // Each run is kept: three earlier ones in history and the one on screen.
        #expect(model.writingRuns.count == 3)
    }

    @Test func changeToneAsksForItsToneThenRunsOnTheSelection() async throws {
        let engine = RecordingAIEngine()
        engine.replies = ["We're sorry we can't make it."]
        let model = Slice7Fixtures.launcher(engine: engine, selection: "We can't make it.")
        defer { model.stop() }
        let row = try #require(model.commandItems.first { $0.id == AICommand.changeTone.id })
        model.perform(row)
        let session = try #require(model.argumentSession)
        #expect(session.specs.map(\.name) == ["tone"])
        #expect(session.values["tone"] == "Friendly")
        #expect(engine.requests.isEmpty)
        model.cycleArgumentOption(1)
        model.submitArguments()
        await model.ai.waitForResponse()
        #expect(model.destination == .ai)
        let prompt = try #require(engine.requests.last?.prompt)
        #expect(prompt.contains("Professional"))
        #expect(prompt.contains("We can't make it."))
        // Built-ins open in OpenRay, whatever their output.
        #expect(model.ai.command?.commandID == AICommand.changeTone.id)
        #expect(model.aiReplaceTarget?.text == "We can't make it.")
    }

    // MARK: 2. Selection capture with the clipboard fallback

    @Test func aSelectionAccessibilityCantSeeIsCopiedThenRun() async throws {
        let engine = TestAIEngine()
        let model = model(engine: engine)
        defer { model.stop() }
        model.selectionContextReader = { throw SelectionReadError.notExposed(app: "Slack") }
        model.selectionCopyReader = { _ in
            var copied = SelectedTextContext.copied("Copied words", from: nil, sourceName: "Slack")
            copied.focusIsOriginal = { true }
            return copied
        }
        model.openAI(.rewrite)
        #expect(model.readingSelectionFrom != nil)
        #expect(model.ai.messages.isEmpty)
        let task = try #require(model.selectionCaptureTask)
        await task.value
        #expect(model.readingSelectionFrom == nil)
        await model.ai.waitForResponse()
        #expect(engine.prompts == ["Copied words"])
        // A copied selection's place is unknown: ↵ pastes over it, nothing unattended replaces it.
        #expect(model.aiReplaceTarget?.text == "Copied words")
        #expect(model.aiReplaceTarget?.canReplace == false)
        #expect(throws: LibraryValidationError.self) { try model.aiReplaceTarget?.validateForPaste() }
    }

    @Test func nothingSelectedSaysWhyAndUseClipboardRunsOnTheClipboard() async throws {
        let engine = TestAIEngine()
        let model = model(engine: engine)
        defer { model.stop() }
        model.selectionContextReader = { throw SelectionReadError.nothingSelected(app: "Notes") }
        model.selectionCopyReader = { _ in throw SelectionReadError.nothingSelected(app: "Notes") }
        model.openAI(.rewrite)
        await model.selectionCaptureTask?.value
        #expect(model.selectionNotice == "Nothing selected in Notes.")
        #expect(model.ai.attachments.isEmpty)
        #expect(engine.prompts.isEmpty)
        let useClipboard = try #require(model.actions(for: nil).first { $0.id == "attachClipboard" })
        #expect(useClipboard.title == "Use Clipboard")
        _ = model.clipboard.copy("Clipboard words")
        useClipboard.perform()
        #expect(model.selectionNotice == nil)
        await model.ai.waitForResponse()
        #expect(engine.prompts == ["Clipboard words"])
        #expect(model.aiReplaceTarget == nil)
    }

    @Test func secureInputIsSaidPlainlyAndNeverTriesTheCopy() async {
        let model = model()
        defer { model.stop() }
        let copies = PasteLog()
        model.selectionContextReader = { throw SelectionReadError.secureInput }
        model.selectionCopyReader = { _ in
            copies.posted.append(0)
            throw SelectionReadError.secureInput
        }
        model.openAI(.rewrite)
        #expect(model.selectionCaptureTask == nil)
        #expect(copies.posted.isEmpty)
        #expect(model.selectionNotice?.contains("Secure Input") == true)
        #expect(model.selectionNotice?.contains("Accessibility") == false)
    }

    // MARK: 3. A new selection wins; history

    @Test func reopeningWithinThePopToRootDelayReturnsToTheLastResult() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("A passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        model.panelDidHide()
        model.panelWillShow()
        #expect(model.destination == .ai)
        #expect(model.ai.lastCompletedResult == "A helpful reply.")
        #expect(model.canAcceptAIResponse)
    }

    @Test func newKeepsTheRunInHistoryAndTheHistoryIsCapped() async {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("A passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        model.newAIConversation()
        #expect(model.ai.messages.isEmpty)
        #expect(model.ai.action == .rewrite)
        #expect(model.writingRuns.count == 1)
        #expect(model.canShowPreviousRun)
        for index in 0..<(LauncherModel.writingHistoryLimit + 3) {
            model.setCapturedSelection(selection("Passage \(index)"))
            model.openAI(.shorten)
            await model.ai.waitForResponse()
        }
        #expect(model.writingRuns.count == LauncherModel.writingHistoryLimit)
        #expect(model.writingRuns.first?.snapshot.lastSource == "Passage 2")
    }

    // MARK: 4–5. Result first, and its keys

    @Test func theResultIsCleanByDefaultAndFixSpellingMarksItsChanges() async {
        let engine = TestAIEngine()
        engine.snapshots = ["We were ready."]
        let model = model(engine: engine)
        defer { model.stop() }
        model.setCapturedSelection(selection("We was ready."))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        #expect(model.ai.diffMode == .result)
        #expect(model.ai.lastDiff != nil)
        model.openAI(.proofread)
        await model.ai.waitForResponse()
        #expect(model.ai.diffMode == .changes)
        // The setting is per command.
        #expect(model.aiHub.updateSettings {
            $0.setHighlightsChanges(true, for: "ai.rewrite")
            $0.setHighlightsChanges(false, for: "ai.proofread")
        })
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        #expect(model.ai.diffMode == .changes)
        model.openAI(.proofread)
        await model.ai.waitForResponse()
        #expect(model.ai.diffMode == .result)
        let pill = model.ai.messages.first
        #expect(pill?.role == .user)
        #expect(model.ai.title == "Fix Spelling & Grammar")
    }

    @Test func theKeysOnAResultFollowRaycast() async throws {
        let model = model()
        defer { model.stop() }
        model.setCapturedSelection(selection("A passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        let entries = model.actions(for: nil)
        func entry(_ id: String) throws -> ActionEntry { try #require(entries.first { $0.id == id }) }
        #expect(try entry("accept").title == "Paste Response")
        #expect(try entry("accept").shortcut == .return)
        #expect(try entry("secondary").title == "Copy Response")
        #expect(try entry("secondary").key == .return && entry("secondary").modifiers == .command)
        #expect(try entry("pasteFormatted").key == .return && entry("pasteFormatted").modifiers == .option)
        #expect(try entry("retry").title == "Regenerate")
        #expect(try entry("retryCreative").modifiers == [.command, .shift])
        #expect(try entry("chatWindow").title == "Continue in Chat")
        #expect(try entry("chatWindow").key == "j")
        #expect(try entry("new").title == "New")
        #expect(entries.contains { $0.title == "Show Original" })
        let rows = ShortcutsOverlay(model: model, selected: nil).localRows
        #expect(rows.first { $0.0 == "Paste Response" }?.1 == ["↩"])
        #expect(rows.first { $0.0 == "Copy Response" }?.1 == ["⌘", "↩"])
        #expect(rows.first { $0.0 == "Paste Formatted Response" }?.1 == ["⌥", "↩"])
        #expect(rows.first { $0.0 == "Regenerate, More Creative" }?.1 == ["⇧", "⌘", "R"])
        #expect(rows.first { $0.0 == "Continue in Chat" }?.1 == ["⌘", "J"])
        #expect(LauncherKeyCommand.command(keyCode: 30, modifiers: .command, vim: false) == .forward)
    }

    @Test func primaryActionCopySwapsReturnAndCommandReturnAndTheToastPreviewsTheResult() async {
        let model = model()
        defer { model.stop() }
        model.primaryActionOverride = .copy
        model.setCapturedSelection(selection("A passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        #expect(model.aiAcceptTitle == "Copy Response")
        #expect(model.aiSecondaryTitle == "Paste Response")
        model.submitAI()
        #expect(model.clipboard.readText() == "A helpful reply.")
        // The preview is the result, never the command's name.
        #expect(model.feedback?.text == "Copied “A helpful reply.”")
    }

    @Test func regenerateAsksForAnotherWordingOnAFreshSession() async throws {
        let engine = SamplingAIEngine()
        let model = model(engine: engine)
        defer { model.stop() }
        model.setCapturedSelection(selection("A passage"))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        let resets = engine.resetCount
        try #require(model.actions(for: nil).first { $0.id == "retry" }).perform()
        await model.ai.waitForResponse()
        try #require(model.actions(for: nil).first { $0.id == "retryCreative" }).perform()
        await model.ai.waitForResponse()
        #expect(engine.samplings == [.standard, .varied, .creative])
        #expect(engine.resetCount >= resets + 2)
        #expect(engine.prompts == ["A passage", "A passage", "A passage"])
        #expect(model.ai.messages.count == 2)
        #expect(AIWritingSampling.standard.temperature == nil)
        #expect((AIWritingSampling.creative.temperature ?? 0) > (AIWritingSampling.varied.temperature ?? 0))
    }

    @Test func regeneratingAnAICommandSamplesItFreely() async throws {
        let engine = RecordingAIEngine()
        let model = Slice7Fixtures.launcher(engine: engine, selection: "The Krebs cycle…")
        defer { model.stop() }
        AICommandProvider().run(commandID: AICommand.findBugs.id, arguments: [:], in: model)
        await model.ai.waitForResponse()
        #expect(engine.requests.last?.profile.greedy == true)
        model.regenerateAIResult()
        await model.ai.waitForResponse()
        let profile = try #require(engine.requests.last?.profile)
        #expect(!profile.greedy)
        #expect(profile.temperature == AIWritingSampling.varied.temperature)
    }

    // MARK: 6. Paste back

    @Test func returnPastesIntoTheSourceAppRestoresTheClipboardAndShowsAHUD() async throws {
        let model = model()
        defer { model.stop() }
        let app = otherApp
        let hud = installHUD(on: model)
        let log = installPaste(on: model, front: app)
        _ = model.clipboard.copy("Earlier copy")
        // The strict check would refuse: ↵ never asks it (owner decision).
        model.setCapturedSelection(selection("We was ready.", application: app))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        model.submitAI()
        #expect(model.isPastingAIResponse)
        await model.pasteBackTask?.value
        #expect(!model.isPastingAIResponse)
        #expect(log.activated == [app.processIdentifier])
        #expect(log.posted == [app.processIdentifier])
        #expect(log.pastedText == "A helpful reply.")
        #expect(log.pastedTypes.contains("org.nspasteboard.TransientType"))
        #expect(model.clipboard.readText() == "Earlier copy")
        #expect(hud.presented.last?.message == HUDMessage("Improved", symbol: "checkmark.circle.fill"))
    }

    @Test func anotherFocusedFieldIsRefusedAndTheResultStaysCopied() async throws {
        let model = model()
        defer { model.stop() }
        let app = otherApp
        let hud = installHUD(on: model)
        let log = installPaste(on: model, front: app)
        model.setCapturedSelection(selection("We was ready.", application: app, focus: { false }))
        model.openAI(.rewrite)
        await model.ai.waitForResponse()
        model.submitAI()
        await model.pasteBackTask?.value
        #expect(log.posted.isEmpty)
        #expect(model.clipboard.readText() == "A helpful reply.")
        #expect(hud.presented.last?.message == LauncherModel.copiedHUD)
        #expect(model.feedback?.text.contains("isn't focused") == true)
    }

    @Test func optionReturnPastesTheResultWithItsFormatting() async throws {
        let engine = TestAIEngine()
        engine.snapshots = ["Some **bold** words"]
        let model = model(engine: engine)
        defer { model.stop() }
        let app = otherApp
        _ = installHUD(on: model)
        let log = installPaste(on: model, front: app)
        model.setCapturedSelection(selection("Some bold words", application: app))
        model.openAI(.summarize)
        await model.ai.waitForResponse()
        try #require(model.actions(for: nil).first { $0.id == "pasteFormatted" }).perform()
        await model.pasteBackTask?.value
        #expect(log.posted == [app.processIdentifier])
        #expect(log.pastedTypes.contains(NSPasteboard.PasteboardType.rtf.rawValue))
        #expect(log.pastedText == "Some **bold** words")
    }

    // MARK: 7. Output Behavior

    @Test func outputBehaviorUsesRaycastsNamesAndKeepsStoredValues() {
        #expect(AICommandOutput.show.title == "Open in OpenRay")
        #expect(AICommandOutput.replace.title == "Replace Selection")
        #expect(AICommandOutput(rawValue: "show") == .show)
        #expect(AICommandOutput(rawValue: "replace") == .replace)
        let record = AICommandRecord(name: "Formal", prompt: "Formal: {selection}", output: "replace")
        #expect(AICommand(record: record).replacesInPlace)
        #expect(!AICommand.changeTone.replacesInPlace)
        #expect(!AICommand(record: AICommandRecord(name: "Ask", prompt: "{selection}", output: "show")).replacesInPlace)
    }

    @Test func aReplaceSelectionCommandRunsInPlaceWithNoWindowAndTheStrictCheck() async throws {
        let engine = RecordingAIEngine()
        engine.replies = ["Good morning, team."]
        let model = Slice7Fixtures.launcher(engine: engine)
        defer { model.stop() }
        let app = otherApp
        let hud = installHUD(on: model)
        let log = installPaste(on: model, front: app)
        model.unattendedChatFactory = { [unowned model] in AIChatModel(engine: engine, hub: model.ai.hub) }
        let record = AICommandRecord(name: "Formal", prompt: "Formal: {selection}", output: "replace")
        #expect(model.store.update { $0.aiCommands.append(record) })
        model.commandCatalogDidChange()
        model.setCapturedSelection(selection("morning team", application: app, strictPasses: true))
        let row = try #require(model.commandItems.first { $0.id == AICommand.id(for: record.id) })
        model.perform(row)
        await model.inPlaceTask?.value
        #expect(model.destination == .search)
        #expect(engine.requests.last?.prompt.contains("morning team") == true)
        #expect(log.posted == [app.processIdentifier])
        #expect(hud.presented.last?.message == HUDMessage("Replaced", symbol: "checkmark.circle.fill"))

        // A selection that changed is never replaced; the result is copied.
        model.setCapturedSelection(selection("morning team", application: app, strictPasses: false))
        model.perform(row)
        await model.inPlaceTask?.value
        #expect(log.posted.count == 1)
        #expect(hud.presented.last?.message == LauncherModel.copiedHUD)
        #expect(model.clipboard.readText() == "Good morning, team.")
    }

    // MARK: 8. Quick Fix

    private func quickFixModel(_ engine: RecordingAIEngine) -> LauncherModel {
        let model = Slice7Fixtures.launcher(engine: engine)
        model.selectionReader = nil
        model.unattendedChatFactory = { [unowned model] in AIChatModel(engine: engine, hub: model.ai.hub) }
        return model
    }

    @MainActor
    final class FieldLog {
        var replaced: [String] = []
        var selectedAll = 0
    }

    private func field(
        _ text: String, application: NSRunningApplication, log: FieldLog, settable: Bool = true,
        unchanged: Bool = true
    ) -> FocusedFieldContext {
        FocusedFieldContext(
            text: text, application: application, sourceName: "Mail",
            validate: { if !unchanged { throw LibraryValidationError("The text in Mail changed.") } },
            replaceValue: { value in
                guard settable else { return false }
                log.replaced.append(value)
                return true
            },
            selectAll: {
                log.selectedAll += 1
                return true
            })
    }

    @Test func quickFixFixesTheWholeFieldWhenNothingIsSelected() async throws {
        let engine = RecordingAIEngine()
        engine.replies = ["The whole field, fixed."]
        let model = quickFixModel(engine)
        defer { model.stop() }
        let app = otherApp
        let hud = installHUD(on: model)
        let paste = installPaste(on: model, front: app)
        let log = FieldLog()
        model.selectionContextReader = { throw SelectionReadError.nothingSelected(app: "Mail") }
        model.focusedFieldReader = { self.field("Teh whole feild.", application: app, log: log) }
        model.runQuickFix()
        await model.inPlaceTask?.value
        #expect(engine.actionPrompts == ["Teh whole feild."])
        // Accessibility sets the value: no clipboard, no key.
        #expect(log.replaced == ["The whole field, fixed."])
        #expect(paste.posted.isEmpty)
        #expect(hud.presented.last?.message == HUDMessage("Fixed", symbol: "checkmark.circle.fill"))

        // A field that can't be set is selected whole and pasted over, after the same check.
        model.focusedFieldReader = { self.field("Teh whole feild.", application: app, log: log, settable: false) }
        model.runQuickFix()
        await model.inPlaceTask?.value
        #expect(log.selectedAll == 1)
        #expect(paste.posted == [app.processIdentifier])

        // A field that changed while the model worked is left alone; the result is copied.
        model.focusedFieldReader = { self.field("Teh whole feild.", application: app, log: log, unchanged: false) }
        model.runQuickFix()
        await model.inPlaceTask?.value
        #expect(log.replaced.count == 1)
        #expect(paste.posted.count == 1)
        #expect(hud.presented.last?.message == LauncherModel.copiedHUD)
    }

    @Test func quickFixPrefersTheSelectionUnlessThatsTurnedOff() async throws {
        let engine = RecordingAIEngine()
        engine.replies = ["They were late."]
        let model = quickFixModel(engine)
        defer { model.stop() }
        let app = otherApp
        let hud = installHUD(on: model)
        let paste = installPaste(on: model, front: app)
        let log = FieldLog()
        model.focusedFieldReader = { self.field("Whole field text.", application: app, log: log) }
        model.setCapturedSelection(selection("They was late.", application: app, strictPasses: true))
        model.runQuickFix()
        await model.inPlaceTask?.value
        #expect(engine.actionPrompts == ["They was late."])
        #expect(paste.posted == [app.processIdentifier])
        #expect(log.replaced.isEmpty)
        #expect(hud.presented.last?.message == HUDMessage("Fixed", symbol: "checkmark.circle.fill"))

        // The strict check guards the selection: a changed one is never replaced.
        model.setCapturedSelection(selection("They was late.", application: app, strictPasses: false))
        model.runQuickFix()
        await model.inPlaceTask?.value
        #expect(paste.posted.count == 1)
        #expect(hud.presented.last?.message == LauncherModel.copiedHUD)

        #expect(model.aiHub.updateSettings { $0.quickFixPrefersSelection = false })
        #expect(!AISettings(database: model.store.database).quickFixPrefersSelection)
        model.runQuickFix()
        await model.inPlaceTask?.value
        #expect(engine.actionPrompts.last == "Whole field text.")
        #expect(log.replaced == ["They were late."])
    }

    @Test func aiSettingsKeepHighlightAndQuickFixChoicesAndDropDefaults() {
        var settings = AISettings()
        #expect(settings.highlightsChanges(for: "ai.proofread"))
        #expect(!settings.highlightsChanges(for: "ai.rewrite"))
        #expect(!settings.highlightsChanges(for: AICommand.changeTone.id))
        settings.setHighlightsChanges(true, for: "ai.rewrite")
        settings.setHighlightsChanges(false, for: "ai.proofread")
        settings.quickFixPrefersSelection = false
        var database = LibraryDatabase()
        settings.write(into: &database)
        #expect(database.commandPreferences["ai"]?["highlight.ai.rewrite"] == "true")
        #expect(database.commandPreferences["ai"]?["quickFixSelection"] == "false")
        #expect(AISettings(database: database) == settings)
        settings.setHighlightsChanges(false, for: "ai.rewrite")
        settings.setHighlightsChanges(true, for: "ai.proofread")
        settings.quickFixPrefersSelection = true
        settings.write(into: &database)
        #expect(database.commandPreferences["ai"] == nil)
    }
}
