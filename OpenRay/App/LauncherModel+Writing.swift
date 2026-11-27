import AppKit
import SwiftUI

// The writing flow (Improve Writing and the other writing commands, the Slice 7 built-ins and the
// person's AI Commands): runs kept in a history, ↵ pasting a result back into its app, and the
// runs that replace text in place with no window.

/// Where ↵ pastes a writing result: the app its selection came from, with that selection's
/// focus check, or the app the launcher was opened from.
@MainActor
struct AIPasteTarget {
    var application: NSRunningApplication
    var name: String
    /// Whether the element focused at capture still is; nil when there's nothing to check.
    var focusIsOriginal: (@MainActor () -> Bool?)?
}

/// What an in-place run (Replace Selection, Quick Fix) replaces.
@MainActor
enum InPlaceTarget {
    case selection(SelectedTextContext)
    /// Quick Fix's whole focused field, when nothing is selected or Prefer Selection is off.
    case field(FocusedFieldContext)

    var text: String {
        switch self {
        case .selection(let selection): selection.text
        case .field(let field): field.text
        }
    }

    var application: NSRunningApplication? {
        switch self {
        case .selection(let selection): selection.application
        case .field(let field): field.application
        }
    }

    var sourceName: String {
        switch self {
        case .selection(let selection): selection.sourceName
        case .field(let field): field.sourceName
        }
    }
}

extension LauncherModel {
    // MARK: - History (⌘[ / ⌘])

    /// Puts the writing run on screen into the history, or updates it there. A run that was
    /// emptied leaves it. Nothing happens for chat or while a reply is written.
    func commitWritingRun() {
        guard let snapshot = ai.writingSnapshot() else { return }
        let pin = aiSelectionTarget.flatMap { $0.conversation == snapshot.conversationToken ? $0 : nil }
        let run = StashedWriting(snapshot: snapshot, pin: pin)
        if let index = writingRuns.firstIndex(where: { $0.snapshot.conversationToken == snapshot.conversationToken }) {
            if snapshot.hasWork { writingRuns[index] = run } else { writingRuns.remove(at: index) }
        } else if snapshot.hasWork {
            writingRuns.append(run)
            if writingRuns.count > Self.writingHistoryLimit { writingRuns.removeFirst(writingRuns.count - Self.writingHistoryLimit) }
        }
    }

    /// The run on screen's place in the history: its index, or past the end for a new run.
    private var writingRunPosition: Int {
        writingRuns.firstIndex { $0.snapshot.conversationToken == ai.conversationToken } ?? writingRuns.count
    }

    private var showsWritingRun: Bool { destination == .ai && ai.action != .chat && !ai.isGenerating }
    var canShowPreviousRun: Bool { showsWritingRun && writingRunPosition > 0 }
    var canShowNextRun: Bool { showsWritingRun && writingRunPosition < writingRuns.count - 1 }

    /// ⌘[ (-1) and ⌘] (+1): the run before or after the one on screen, which is kept first.
    func showWritingRun(_ offset: Int) {
        guard showsWritingRun else { return }
        let token = ai.conversationToken
        commitWritingRun()
        let position = writingRuns.firstIndex { $0.snapshot.conversationToken == token } ?? writingRuns.count
        let target = position + offset
        guard writingRuns.indices.contains(target) else { return }
        cancelSelectionCapture()
        let run = writingRuns[target]
        ai.restoreWriting(run.snapshot)
        aiSelectionTarget = run.pin
        selectionNotice = nil
        feedback = nil
        focusRequest += 1
    }

    /// ⌘N: the run on screen goes into the history. A writing command opens an empty run for a
    /// typed passage; an AI Command's run, which needs its selection, makes way for a new chat.
    func newAIConversation() {
        guard !ai.isGenerating else { return }
        if ai.action == .chat {
            ai.newConversation()
        } else if ai.command != nil {
            cancelSelectionCapture()
            commitWritingRun()
            ai.newConversation(action: .chat)
            ai.open(.chat)
        } else {
            startWritingRun(ai.action)
        }
        focusRequest += 1
    }

    // MARK: - Using a result (work items 5 and 6)

    /// Whether ↵ pastes a writing result (the default, as in Raycast) or copies it: Settings ›
    /// Apple Intelligence › Primary Action. General's Primary Action is for launcher rows only.
    var aiPrimaryPastes: Bool { aiHub.settings.primaryAction == .paste }

    /// What ↵ does with a finished result.
    var aiAcceptTitle: String { aiPrimaryPastes ? "Paste Response" : "Copy Response" }
    /// What ⌘↵ does: the other one, so the two keys never do the same thing.
    var aiSecondaryTitle: String { aiPrimaryPastes ? "Copy Response" : "Paste Response" }

    /// The result ↵ uses: the latest finished reply of a writing run.
    private var usableAIResult: String? {
        guard ai.action != .chat, !ai.isGenerating, let response = ai.latestResponse, !response.isPartial else {
            return nil
        }
        return response.text
    }

    /// The selection the result on screen goes back over, while it's the passage on screen.
    var aiReplaceTarget: SelectedTextContext? {
        guard ai.action != .chat, let pin = aiSelectionTarget, pin.conversation == ai.conversationToken else {
            return nil
        }
        if ai.command != nil { return pin.context }
        guard let attachmentID = pin.attachmentID, ai.attachments.first?.id == attachmentID else { return nil }
        if ai.lastSource != nil, ai.lastAttachment?.id != attachmentID { return nil }
        return pin.context
    }

    /// Where ↵ pastes: the selection's app, or the app the launcher was opened from.
    var aiPasteTarget: AIPasteTarget? {
        if let selection = aiReplaceTarget, let application = selection.application, !application.isTerminated {
            return AIPasteTarget(application: application, name: selection.sourceName, focusIsOriginal: selection.focusIsOriginal)
        }
        guard let application = previousApplication, !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return AIPasteTarget(application: application, name: previousApplicationName ?? "your app", focusIsOriginal: nil)
    }

    /// ↵ on a finished result with an empty field.
    func acceptAIResponse() {
        guard canAcceptAIResponse else { return }
        if aiPrimaryPastes { pasteWritingResult() } else { copyWritingResult() }
    }

    /// ⌘↵ on a finished result.
    func performAISecondary() {
        guard canAcceptAIResponse else { return }
        if aiPrimaryPastes { copyWritingResult() } else { pasteWritingResult() }
    }

    /// Copy Response: the panel stays, and the toast shows the start of what was copied.
    func copyWritingResult() {
        guard let text = usableAIResult else { return }
        copy(text)
    }

    /// Paste Response (↵) and Paste Formatted Response (⌥↵), as Raycast does it: the result goes on
    /// the clipboard marked transient, the panel closes, the app comes forward, and, if it's
    /// still the app with the same field focused and Secure Input off, ⌘V; then the person's
    /// clipboard comes back and a HUD says it's done. If it can't paste, the result stays copied.
    func pasteWritingResult(formatted: Bool = false) {
        guard canAcceptAIResponse, let text = usableAIResult else { return }
        let richText = formatted ? AIFormattedText.richText(fromMarkdown: text) : nil
        let environment: PasteBack.Environment
        if let pasteBackEnvironment {
            environment = pasteBackEnvironment
        } else {
            guard mayWriteClipboard else { return }
            guard clipboard.usesGeneralPasteboard, !sideEffects.isInert else {
                _ = richText.map { clipboard.copy(text, richText: $0) } ?? clipboard.copy(text)
                feedback = .info("Copied to the isolated verification pasteboard. Cross-app paste is disabled in this mode.")
                return
            }
            environment = .live
        }
        guard let target = aiPasteTarget else {
            copy(text)
            return
        }
        let label = Self.pastTense(forCommandID: ai.commandID, inPlace: false)
        // Without Accessibility no key can be sent: copy, go back to the app and say so.
        guard pasteBackEnvironment != nil || windows.hasPermission else {
            guard clipboard.copy(text, richText: richText) else {
                feedback = .error(clipboard.lastCopyError ?? "Couldn't write to the clipboard. Try again.")
                return
            }
            panel?.dismiss(restoreFocus: false)
            target.application.activate()
            hud.show(Self.copiedHUD)
            return
        }
        isPastingAIResponse = true
        pasteBackTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isPastingAIResponse = false }
            let outcome = await PasteBack.run(
                text, richText: richText, into: target.application, clipboard: self.clipboard,
                validate: { try SelectedTextContext.verifyFocus(target.focusIsOriginal?(), sourceName: target.name) },
                environment: environment, willPaste: { [weak self] in self?.panel?.dismiss(restoreFocus: false) })
            self.finish(outcome, success: label)
        }
    }

    /// The HUD after a paste back, or the reason in the panel when nothing reached the clipboard.
    private func finish(_ outcome: PasteBack.Outcome, success label: String) {
        switch outcome {
        case .pasted:
            hud.show(HUDMessage(label, symbol: "checkmark.circle.fill"))
        case .copied(let reason):
            hud.show(Self.copiedHUD)
            // Reopening shows why.
            feedback = .warning(reason)
        case .failed(let reason):
            panel?.show()
            feedback = .error(reason)
        }
    }

    static let copiedHUD = HUDMessage("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", style: .warning)

    /// The HUD's word for a result put back: “Improved”, “Fixed”, “Shortened”…
    static func pastTense(forCommandID id: String, inPlace: Bool) -> String {
        switch id {
        case "ai.rewrite": "Improved"
        case "ai.proofread": "Fixed"
        case "ai.shorten": "Shortened"
        case "ai.summarize": "Summarized"
        case AICommand.changeTone.id: "Rewritten"
        case AICommand.translate.id: "Translated"
        default: inPlace ? "Replaced" : "Pasted"
        }
    }

    // MARK: - Regenerate

    /// ⌘R (another wording) and ⇧⌘R (freer, there being one model): the latest result again on a
    /// fresh session, sampled rather than greedy.
    func regenerateAIResult(creative: Bool = false) {
        guard ai.canRetry else { return }
        if ai.action == .chat {
            ai.retry()
        } else {
            ai.regenerate(creative ? .creative : .varied)
        }
        focusRequest += 1
    }

    // MARK: - In place (Replace Selection, Quick Fix)

    /// The conversation an in-place run uses: its own, so the panel's run is never touched.
    func makeUnattendedChat() -> AIChatModel {
        if let unattendedChatFactory { return unattendedChatFactory() }
        let chat = AIChatModel(engine: ai.engine.makeSibling(), hub: ai.hub)
        chat.environment = ai.environment
        // In-place runs call no tools; the panel chat's broker and its approvals stay its own.
        chat.environment.toolBroker = nil
        return chat
    }

    /// Runs a writing command or AI Command with no window and replaces `target` with its result,
    /// after the strict checks (work items 7 and 8). A HUD says how it went; when the text can't
    /// be replaced, the result stays on the clipboard.
    func runInPlace(action: AIAction? = nil, command: AICommandRun? = nil, on target: InPlaceTarget, title: String) {
        let commandID = command?.commandID ?? action.map(AIWritingCommandProvider.commandID(for:)) ?? ""
        if panel?.isVisible == true { panel?.dismiss() }
        hud.show(HUDMessage("\(title)…", symbol: "sparkles", style: .info))
        inPlaceTask = Task { [weak self] in
            guard let self else { return }
            let chat = self.makeUnattendedChat()
            if let command {
                chat.start(command)
            } else if let action {
                chat.open(action)
                chat.attach(AIAttachment(source: .selection, text: target.text, appName: target.sourceName))
                if chat.canSend { chat.send() }
            }
            await chat.waitForResponse()
            guard let result = chat.lastCompletedResult else {
                self.hud.show(
                    HUDMessage(
                        chat.errorMessage ?? chat.availability.detail, symbol: "exclamationmark.triangle.fill", style: .error))
                return
            }
            if result == target.text {
                self.hud.show(HUDMessage(action == .proofread ? "No corrections needed" : "No changes", symbol: "checkmark.circle.fill"))
                return
            }
            await self.place(result, at: target, label: Self.pastTense(forCommandID: commandID, inPlace: true))
        }
    }

    /// Replaces the target's text: a field through Accessibility where it allows it, otherwise a
    /// paste over the selection, after the strict checks.
    private func place(_ result: String, at target: InPlaceTarget, label: String) async {
        guard let application = target.application else {
            _ = clipboard.copy(result)
            hud.show(Self.copiedHUD)
            return
        }
        let environment: PasteBack.Environment
        if let pasteBackEnvironment {
            environment = pasteBackEnvironment
        } else {
            guard clipboard.usesGeneralPasteboard, !sideEffects.isInert else {
                _ = clipboard.copy(result)
                hud.show(Self.copiedHUD)
                return
            }
            environment = .live
        }
        let validate: () throws -> Void
        switch target {
        case .selection(let selection):
            validate = selection.validateForPaste
        case .field(let field):
            do {
                try field.validate()
                if field.replaceValue(result) {
                    hud.show(HUDMessage(label, symbol: "checkmark.circle.fill"))
                    return
                }
                guard field.selectAll() else { throw LibraryValidationError("\(field.sourceName) can't replace its text.") }
            } catch {
                _ = clipboard.copy(result)
                hud.show(Self.copiedHUD)
                return
            }
            validate = field.validate
        }
        let outcome = await PasteBack.run(
            result, into: application, clipboard: clipboard, validate: validate, environment: environment)
        finish(outcome, success: label)
    }

    /// Quick Fix (work item 8): its command, run in place on the selection, or with Prefer
    /// Selection off or nothing selected, on the whole focused field.
    func runQuickFix() {
        let hub = aiHub
        let settings = hub.settings
        let commandID = settings.quickFixCommandID
        let action = AIWritingCommandProvider.writingActions.first { AIWritingCommandProvider.commandID(for: $0) == commandID }
        let command = hub.aiCommands.first { $0.id == commandID }
        guard action != nil || command != nil else {
            feedback = .error("That AI Command no longer exists. Choose another in Settings › Apple Intelligence.")
            panel?.show()
            return
        }
        let isTranslation = command.map { $0.performer != .model } ?? false
        ai.refreshAvailability()
        guard ai.availability.isAvailable || isTranslation else {
            hud.show(HUDMessage(ai.availability.headline, symbol: "exclamationmark.triangle.fill", style: .warning))
            return
        }
        let target: InPlaceTarget
        do {
            var selection: SelectedTextContext?
            if settings.quickFixPrefersSelection {
                do {
                    selection = try captureSelection()
                } catch SelectionReadError.nothingSelected, SelectionReadError.notExposed {
                    // The whole field, unless it has a selection it doesn't share.
                    selection = nil
                }
            }
            target = try selection.map(InPlaceTarget.selection)
                ?? .field(captureFocusedField(selectionHidden: settings.quickFixPrefersSelection))
        } catch {
            hud.show(HUDMessage(error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .warning))
            return
        }
        guard target.text.count <= AIChatModel.inputLimit else {
            hud.show(HUDMessage(Self.passageTooLong, symbol: "exclamationmark.triangle.fill", style: .warning))
            return
        }
        if let action {
            runInPlace(action: action, on: target, title: action.title)
            return
        }
        guard let command else { return }
        let plan = command.template.plan(snippets: PlaceholderValues.snippetLookup(store.database))
        var selection: SelectedTextContext?
        if case .selection(let captured) = target { selection = captured }
        do {
            let resolved = try plan.resolveArguments([:])
            var values = placeholderValues(for: plan, selection: selection)
            values.selection = target.text
            values.arguments = resolved
            let run = try AICommandRenderer.render(
                command, plan: plan, values: values, capabilities: ai.capabilities, sourceAppName: target.sourceName)
            runInPlace(command: run, on: target, title: command.name)
        } catch {
            hud.show(HUDMessage(error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .warning))
        }
    }

    /// Quick Fix's whole-field read; see `FocusedFieldContext.capture`.
    func captureFocusedField(selectionHidden refuses: Bool) throws -> FocusedFieldContext {
        if let focusedFieldReader { return try focusedFieldReader() }
        try sideEffects.check("reading the focused field in another app")
        guard windows.hasPermission else { throw SelectionReadError.accessibilityOff }
        return try FocusedFieldContext.capture(from: previousApplication, selectionHidden: refuses)
    }

    // MARK: - Shortcuts overlay

    /// The ⌘/ rows for a writing run, as the action bar and ⌘K name them.
    var aiWritingShortcutRows: [(String, [String])] {
        if ai.isGenerating { return [("Stop", ["⌘", "."])] }
        var rows: [(String, [String])] = []
        if ai.messages.last?.role == .assistant {
            if ai.isRevising {
                rows.append(("Ask for Changes", ["↩"]))
            } else if canAcceptAIResponse {
                rows += [(aiAcceptTitle, ["↩"]), (aiSecondaryTitle, ["⌘", "↩"]), ("Paste Formatted Response", ["⌥", "↩"])]
            } else if aiResultIsUnchanged {
                rows.append(("Done", ["↩"]))
            }
        } else {
            rows.append((ai.runTitle, ["↩"]))
            if ai.attachments.isEmpty { rows += [("New Line", ["⇧", "↩"]), ("New Line", ["⌘", "↩"])] }
        }
        if ai.canRetry { rows += [("Regenerate", ["⌘", "R"]), ("Regenerate, More Creative", ["⇧", "⌘", "R"])] }
        if ai.messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) {
            rows.append(("Continue in Chat", ["⌘", "J"]))
        }
        rows.append((ai.command == nil ? "New" : "New Chat", ["⌘", "N"]))
        if canShowPreviousRun || canShowNextRun { rows += [("Previous Run", ["⌘", "["]), ("Next Run", ["⌘", "]"])] }
        return rows
    }
}
