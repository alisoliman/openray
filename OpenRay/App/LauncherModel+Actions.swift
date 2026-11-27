import AppKit
import SwiftUI

/// One row in the ⌘K action panel. Entries carry their shortcut, so the panel
/// teaches you to skip it next time, and the same shortcut works without it.
struct ActionEntry: Identifiable {
    enum Group: Int { case item, organize, panel }
    var id: String
    var title: String
    var symbol: String
    var shortcut: KeyShortcut?
    var key: KeyEquivalent?
    var modifiers: EventModifiers = []
    var group: Group
    var isDestructive = false
    /// A titled section the entry belongs to, such as “Paste As”. Nil keeps it in its group's
    /// untitled run. The panel doesn't draw section titles yet (Slice 1 does).
    var section: String? = nil
    /// A submenu. An entry with children opens them rather than performing; until the panel
    /// draws submenus (Slice 1), it performs `perform`, so give such entries a sensible one.
    var children: [ActionEntry] = []
    var perform: @MainActor () -> Void
}

extension LauncherModel {
    // MARK: - Perform

    func performSelected() {
        if confirmation != nil {
            // Return itself is answered by the panel, from its own key event, before any field
            // sees it. A field's submit (insertNewline: from a key binding, an accessibility
            // action) carries no key evidence, so it answers nothing; tests stand in for the
            // panel's fresh press with `currentKeyPressIsFresh`.
            _ = confirmFromReturn(isRepeat: !currentKeyPressIsFresh())
            return
        }
        guard !showActions else { return }
        if onboarding != nil {
            advanceOnboarding()
            return
        }
        if showsClipboardOptIn {
            enableClipboardHistory()
            return
        }
        // The collapsed bar hides the results, so ↩ has nothing visible to act on.
        guard !isCollapsedToBar else { return }
        if let selectedItem { perform(selectedItem) }
    }

    func perform(_ item: LauncherItem) {
        showActions = false
        confirmation = nil
        feedback = nil
        // With argument fields open, running their command means running the form.
        if let session = argumentSession {
            if item.id == session.item.id { submitArguments() }
            return
        }
        // A command that still needs an argument opens its fields instead of failing.
        if needsArguments(item) {
            beginArguments(for: item)
            return
        }
        noteQueryPick(for: item)
        switch item.action {
        case .application(let app):
            guard allowsSideEffect("opening apps") else { return }
            Task {
                do {
                    try await openApplication(app)
                    store.recordUse(of: item.id)
                    panel?.dismiss(restoreFocus: false)
                } catch {
                    feedback = .error("Couldn't open \(app.name). \(error.localizedDescription)")
                }
            }
        case .file(let url): open(url, itemID: item.id)
        case .section(let section):
            store.recordUse(of: item.id)
            navigate(to: section)
        case .ai(let action):
            store.recordUse(of: item.id)
            openAI(action)
        case .askAI(let prompt):
            openAI(.chat, prompt: prompt)
        case .settings:
            store.recordUse(of: item.id)
            openSettings()
        case .quicklink(let link, let argument):
            performQuicklink(link, argument: argument)
        case .clipboard, .snippet:
            performContent(item)
        case .calculation(let calculation): copy(calculation.value, label: calculation.value)
        case .note(let note):
            editor = .note(note)
            store.recordUse(of: item.id)
        case .window(let layout):
            guard allowsSideEffect("arranging other apps' windows") else { return }
            guard accessibilityAllowed || windows.hasPermission else {
                windows.requestPermission()
                SystemSettingsLink.open(.accessibility)
                feedback = .info("Allow OpenRay in Accessibility, then try again.")
                return
            }
            do {
                if let target = targetWindow {
                    try windows.arrange(layout, window: target.element, pid: target.pid)
                } else {
                    try windows.arrange(layout, application: previousApplication)
                }
                store.recordUse(of: item.id)
                panel?.dismiss(restoreFocus: false)
            } catch {
                // A chosen window that has closed stops being the target.
                if let target = targetWindow, !windows.listWindows().contains(where: { $0.id == target.id }) {
                    targetWindow = nil
                    refreshTargetWindow()
                }
                feedback = .error(error.localizedDescription)
            }
        case .provided(let ref):
            registry.perform(item, ref: ref, in: self)
        }
    }

    /// ⌘1–⌘8: favorites, or retargeting a quicklink argument. An AI entry bound to a ⌘-number
    /// would take that number there.
    func performNumber(_ number: Int) {
        guard !showActions, confirmation == nil, editor == nil, onboarding == nil else { return }
        if destination == .ai, (1...9).contains(number), let key = String(number).first,
            let entry = aiActions().first(where: { $0.key?.character == key && $0.modifiers == .command })
        {
            entry.perform()
            return
        }
        if argumentLink != nil {
            let items = orderedResults
            guard number >= 1, number <= min(8, items.count) else { return }
            perform(items[number - 1])
            return
        }
        let favorites = favoriteItems
        guard number >= 1, number <= min(8, favorites.count) else { return }
        selectedID = favorites[number - 1].id
        perform(favorites[number - 1])
    }

    /// One typed term fills the first argument; placeholder values are read now.
    @discardableResult
    func openQuicklink(_ link: Quicklink, query: String) -> Task<Void, Never>? {
        openQuicklink(link) { try link.resolution(query: query, values: $0) }
    }

    /// Checks the launch's side-effect rule before an executor runs. Inert launches (the test host,
    /// verification mode) say why instead of acting.
    func allowsSideEffect(_ what: String) -> Bool {
        do {
            try sideEffects.check(what)
            return true
        } catch {
            feedback = .error(error.localizedDescription)
            return false
        }
    }

    /// Inert launches never write the system clipboard, even when handed it.
    var mayWriteClipboard: Bool {
        guard sideEffects.isInert, clipboard.usesGeneralPasteboard else { return true }
        feedback = .error(SideEffectGuard.Blocked(what: "writing to the system clipboard", mode: sideEffects.mode).localizedDescription)
        return false
    }

    @discardableResult
    func copy(_ text: String, label: String? = nil) -> Bool {
        guard mayWriteClipboard else { return false }
        if clipboard.copy(text) {
            toast("Copied “\((label ?? text).truncatedForFeedback)”")
            return true
        }
        feedback = .error("Couldn't write to the clipboard. Try again.")
        return false
    }

    @discardableResult
    func copy(_ entry: ClipboardEntry) -> Bool {
        guard mayWriteClipboard else { return false }
        if clipboard.copy(entry) {
            toast("Copied “\(entry.title.truncatedForFeedback)”")
            return true
        }
        feedback = .error(clipboard.lastCopyError ?? "Couldn't write to the clipboard. Try again.")
        return false
    }

    // MARK: - ⌘↩

    var canPasteDirectly: Bool {
        guard clipboard.usesGeneralPasteboard, windows.hasPermission, let target = previousApplication else {
            return false
        }
        return !target.isTerminated
    }

    var targetAppName: String { previousApplicationName ?? "Your App" }

    func pasteSelected() {
        if confirmation != nil || showActions || isCollapsedToBar || argumentSession != nil { return }
        if destination == .ai {
            if ai.action == .chat { pasteAIResponse() } else { performAISecondary() }
            return
        }
        // ⌘↩ only does something when the bar names it.
        guard let item = selectedItem, secondaryTitle(for: item) != nil else { return }
        paste(item)
    }

    /// Pastes an item into the app you came from, or copies it when that can't work.
    /// A provided row runs its provider's secondary action, which is text paste by default.
    func paste(_ item: LauncherItem) {
        if case .provided(let ref) = item.action {
            registry.performSecondary(item, ref: ref, in: self)
            return
        }
        guard item.supportsPaste, mayWriteClipboard else { return }
        switch item.action {
        case .clipboard, .snippet:
            // ⌘↩ does what ↩ doesn't, so the two keys never both copy.
            performSecondaryContent(item)
            return
        case .file(let url):
            let entry = ClipboardEntry(content: .files([url]), sourceName: "OpenRay")
            finishPaste(copied: clipboard.copy(entry), label: url.lastPathComponent)
        default:
            if let text = item.copyText { paste(text, label: item.title) }
        }
    }

    func paste(_ text: String, label: String? = nil) {
        guard mayWriteClipboard else { return }
        finishPaste(copied: clipboard.copy(text), label: label ?? text)
    }

    /// Pastes a row's `copyText`: the default ⌘↩ for provided rows with the `.paste` trait.
    func pasteText(of item: LauncherItem) {
        guard item.supportsPaste, let text = item.copyText else { return }
        paste(text, label: item.title)
    }

    func finishPaste(copied: Bool, label: String) {
        guard copied else {
            feedback = .error(clipboard.lastCopyError ?? "Couldn't copy the content.")
            return
        }
        guard clipboard.usesGeneralPasteboard, !sideEffects.isInert else {
            feedback = .info("Copied to the isolated verification pasteboard. Cross-app paste is disabled in this mode.")
            return
        }
        guard let target = previousApplication, !target.isTerminated, windows.hasPermission else {
            toast("Copied “\(label.truncatedForFeedback)”. Press ⌘V in \(previousApplicationName ?? "your app")")
            return
        }
        let changeCount = clipboard.changeCount
        panel?.dismiss(restoreFocus: false)
        Task {
            do { try await SyntheticInput.paste(into: target, expectedChangeCount: changeCount) } catch {
                // Show first: showing can reset to Home, which clears feedback. ⌘V is offered only
                // while the copy still owns the clipboard.
                panel?.show()
                let owned = clipboard.changeCount == changeCount
                feedback = .error(owned ? "\(error.localizedDescription) \(Self.pasteItYourself)" : error.localizedDescription)
            }
        }
    }

    /// Pastes the latest chat reply into the app OpenRay was opened from (⌘K "Paste to …").
    func pasteAIResponse() {
        guard let response = ai.latestResponse, !ai.isGenerating, !aiResultIsUnchanged else { return }
        paste(response.text)
    }

    /// Paste into the app in front, which may not be where the passage came from.
    var aiPasteTitle: String {
        canPasteDirectly || !clipboard.usesGeneralPasteboard
            ? "Paste to \(targetAppName)" : "Copy · ⌘V in \(targetAppName)"
    }

    // MARK: - AI keys (work item 5: ↵ pastes, ⌘↵ copies, ⌥↵ pastes formatted)

    /// Whether ↵ on an empty field can use the latest writing result: finished, not stopped or
    /// failed, and with something to give back.
    var canAcceptAIResponse: Bool {
        guard ai.action != .chat, !ai.isGenerating, !isPastingAIResponse, ai.errorMessage == nil,
            ai.failedRevision == nil, ai.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let last = ai.messages.last, last.role == .assistant, !last.isPartial, !last.text.isEmpty,
            !aiResultIsUnchanged
        else { return false }
        return true
    }

    /// ↵ in the AI view's fields. Chat and the passage composer send. In a writing command's
    /// field, typed text revises the result; an empty field uses it (Paste Response, or Copy
    /// Response with Primary Action set to copy). Held keys never get here twice (see
    /// `AIComposerInput`).
    func submitAI() {
        guard !ai.isGenerating else { return }
        if ai.action == .chat || ai.isRevising || ai.messages.last?.role != .assistant {
            ai.send()
        } else if canAcceptAIResponse {
            acceptAIResponse()
        } else if aiResultIsUnchanged {
            leaveAI()
        } else if ai.latestResponse == nil {
            // A stopped result: ↩ runs the command again, as Try Again does.
            ai.retry()
        }
        focusRequest += 1
    }

    /// Starts a fresh writing run on the latest result, keeping where it goes back to (main #13's
    /// Use Last Result), and runs it at once, as any chosen passage does. The model starts from a
    /// clean context; the run before stays in history.
    func continueAIFromResult() {
        guard ai.action != .chat, ai.command == nil, !ai.isGenerating, let result = ai.lastCompletedResult else { return }
        let target = aiReplaceTarget
        let destination = aiRunDestination
        let action = ai.action
        let appName = ai.lastAttachment?.appName
        startWritingRun(action)
        // The new run goes back where this one does.
        aiDestination = destination.map { RunDestination(
            conversation: ai.conversationToken, application: $0.application, name: $0.name,
            focusIsOriginal: $0.focusIsOriginal) }
        ai.attach(AIAttachment(source: target == nil ? .response : .selection, text: result, appName: appName))
        // The target is carried forward explicitly, bound to the new passage.
        if let target, let attached = ai.attachments.first, attached.text == result {
            aiSelectionTarget = PinnedSelection(context: target, conversation: ai.conversationToken, attachmentID: attached.id)
        }
        if ai.canSend { ai.send() }
        focusRequest += 1
    }

    /// A result with nothing to paste back is a state, not something to paste:
    /// proofreading that changed nothing, or action items that found none.
    var aiResultIsUnchanged: Bool { ai.resultIsUnchanged }

    func saveResponseAsNote() {
        guard let response = ai.latestResponse else { return }
        saveResponseAsNote(response)
    }

    /// Saves a reply as a note right away, titled by the message that asked
    /// for it, or by the writing command that produced it.
    func saveResponseAsNote(_ message: ChatMessage) {
        let title: String
        if ai.action == .chat {
            let index = ai.messages.firstIndex { $0.id == message.id } ?? ai.messages.endIndex
            let prompt = ai.messages[..<index].last(where: { $0.role == .user })
            // With attachments, text is the wrapped prompt and displayText is what was typed.
            let typed = prompt.map { $0.displayText ?? $0.text } ?? ""
            title = QuickNote.derivedTitle(from: typed.isEmpty ? "AI response" : typed)
        } else {
            title = ai.title
        }
        editor = .note(QuickNote(title: title, content: message.text))
        draft?.saveNote()
    }

    // MARK: - Labels

    /// Names what Return does for the selection.
    func primaryTitle(for item: LauncherItem) -> String {
        switch item.action {
        case .application: "Open Application"
        case .file(let url): "Open in \(defaultAppName(for: url))"
        case .section(let section): "Open \(section.title)"
        case .quicklink(let link, let argument):
            link.needsQuery && argument.isEmpty ? "Enter Search Term" : "Open in \(openerName(for: link))"
        case .window(let layout):
            accessibilityAllowed ? "Apply \(layout.title)" : "Enable Accessibility"
        case .provided(let ref): registry.primaryTitle(for: item, ref: ref, in: self)
        case .clipboard, .snippet: contentPrimaryAction == .paste ? pasteTitle("Paste to") : item.primaryActionTitle
        default: item.primaryActionTitle
        }
    }

    /// The ⌘↩ label, when it applies. It says “Copy · ⌘V in …” when direct paste can't work.
    /// A provided row asks its provider, which offers text paste by default.
    func secondaryTitle(for item: LauncherItem) -> String? {
        guard !item.id.hasPrefix("argument."), !item.id.hasPrefix("fallback.") else { return nil }
        if case .provided(let ref) = item.action { return registry.secondaryTitle(for: item, ref: ref, in: self) }
        guard item.supportsPaste else { return nil }
        if case .quicklink(let link, let argument) = item.action, link.needsQuery && argument.isEmpty { return nil }
        switch item.action {
        case .clipboard, .snippet: if contentPrimaryAction == .paste { return "Copy" }
        default: break
        }
        let noun: String
        switch item.action {
        case .file: noun = "Paste File to"
        case .quicklink: noun = "Paste Link to"
        default: noun = "Paste to"
        }
        return pasteTitle(noun)
    }

    /// The generic ⌘↩ label for pasting a row's text, or nil when it has none to paste.
    func textPasteTitle(for item: LauncherItem) -> String? {
        item.supportsPaste ? pasteTitle("Paste to") : nil
    }

    /// “<noun> <app>” when the paste can reach the app, otherwise “Copy · ⌘V in <app>”.
    func pasteTitle(_ noun: String) -> String {
        if canPasteDirectly || !clipboard.usesGeneralPasteboard { return "\(noun) \(targetAppName)" }
        return "Copy · ⌘V in \(targetAppName)"
    }

    func defaultAppName(for url: URL) -> String {
        if url.hasDirectoryPath { return "Finder" }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "Default App" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The app a quicklink opens in: the browser for web links, Finder for
    /// folders, and the default app for files and other links such as mailto.
    /// A {query} link is resolved with a sample term, so mailto:{query} names Mail too.
    func openerName(for link: Quicklink) -> String {
        if let application = link.openWith { return application.name }
        guard let url = try? link.resolvedURL(query: link.needsQuery ? "x" : "") else { return defaultBrowserName }
        switch url.scheme?.lowercased() {
        case "http", "https": return defaultBrowserName
        default: return defaultAppName(for: url)
        }
    }

    // MARK: - Delete & confirm

    func requestDelete(_ item: LauncherItem) {
        guard item.canDelete else { return }
        showActions = false
        selectedID = item.id
        confirmation = .delete(item)
    }

    /// Asks a question in the action bar. Every screen that can hold one shows it (search,
    /// scopes, the clipboard opt-in, onboarding, editors and AI), so the overlays that would
    /// cover the bar close first.
    func presentConfirmation(_ confirmation: ActionConfirmation) {
        showActions = false
        showShortcuts = false
        showsAttachmentPreview = false
        self.confirmation = confirmation
    }

    /// The current prompt instance: its question and a token that changes every time a prompt
    /// is asked. Action bars report and approve by it, so a stale view or click can't answer a
    /// newer prompt, even one asking the same question.
    var confirmationInstanceID: String? {
        confirmation.map { "\($0.id)#\(confirmationToken.uuidString)" }
    }

    /// How long after its presentation completed (the panel's reveal finished and the prompt drawn
    /// at full opacity) a prompt that loses something can first be approved: about a reaction
    /// time, so a press or click aimed at what was there before can't answer it.
    static let minimumPromptExposure: TimeInterval = 0.3

    /// A key press while a question is pending. Only a fresh press approves it: a held Return's
    /// autorepeat, or a submission without a key behind it, is consumed, so the press that asked
    /// can't also answer. `pressedAt` is when the key went down: the panel passes its event's own
    /// time, so a press made before the prompt was on screen never answers it, however late it's
    /// handled. Nil means now, for tests. Returns whether the key was handled, which is whenever a
    /// question is pending.
    func confirmFromReturn(isRepeat: Bool, pressedAt: Date? = nil) -> Bool {
        guard let confirmation else { return false }
        if !isRepeat, canApprove(confirmation, at: pressedAt ?? promptClock()) { confirm(confirmation) }
        return true
    }

    /// A key event's timestamp (seconds since startup, as `NSEvent.timestamp`) on the prompt clock.
    func promptDate(forEventTimestamp timestamp: TimeInterval) -> Date {
        promptClock().addingTimeInterval(timestamp - ProcessInfo.processInfo.systemUptime)
    }

    /// The approve button: it answers only the prompt instance it showed, so a click landing as a
    /// new prompt replaces the old one approves neither.
    func approveConfirmation(id instance: String) {
        guard let confirmation, instance == confirmationInstanceID, canApprove(confirmation) else { return }
        confirm(confirmation)
    }

    /// An action bar reports the prompt instance it's showing, once it's drawn uncovered. The
    /// first report starts its exposure; later ones for the same instance don't restart it.
    func confirmationDidAppear(_ instance: String) {
        guard instance == confirmationInstanceID, confirmationShown?.instance != instance else { return }
        confirmationShown = (instance, promptClock())
    }

    /// Whether the pending prompt can be approved now. One that loses something must have been
    /// shown as this very instance, on a surface that is visible and key, for long enough.
    func canApprove(_ confirmation: ActionConfirmation) -> Bool {
        canApprove(confirmation, at: promptClock())
    }

    /// Whether an approval made at `time` (a key press's own time) counts. For a prompt that loses
    /// something, presentation is complete once the panel's reveal has finished and the bar has
    /// drawn this instance at full opacity; the approval must come `minimumPromptExposure` after
    /// that, and the prompt must still be on screen now.
    func canApprove(_ confirmation: ActionConfirmation, at time: Date) -> Bool {
        guard confirmation.requiresVisibleApproval else { return true }
        guard let shown = confirmationShown, shown.instance == confirmationInstanceID,
            let visibleSince = confirmationVisibleSince
        else { return false }
        let presented = max(shown.at, visibleSince)
        // A millisecond's grace for clock arithmetic, far below anything a person can press in.
        return time.timeIntervalSince(presented) >= Self.minimumPromptExposure - 0.001
    }

    /// Since when prompts have been on screen: the panel visible, revealed, opaque and key, with
    /// nothing covering its action bar. Nil while they aren't.
    var confirmationVisibleSince: Date? {
        guard confirmation != nil, !showActions else { return nil }
        if let check = confirmationSurfaceVisibleSince { return check() }
        guard let panel, isPresented else { return nil }
        return panel.surfaceVisibleSince
    }

    func confirm(_ confirmation: ActionConfirmation) {
        self.confirmation = nil
        switch confirmation {
        case .delete(let item):
            // A provider may explain a failure, or a partial success, itself; keep its words.
            feedback = nil
            if delete(item) {
                if feedback == nil { toast("Deleted “\(item.title.truncatedForFeedback)”") }
            } else if feedback == nil {
                feedback = .error(store.errorMessage ?? "Couldn't delete the item.")
            }
        case .discardChanges:
            closeEditor(force: true)
        case .clearClipboardHistory:
            if clipboard.clearHistory() { toast("Clipboard history deleted") }
        case .provided(let confirmation):
            confirmation.perform()
        }
    }

    /// Removes an item from the library. Returns false, with the selection
    /// unchanged, when the library couldn't be saved.
    @discardableResult
    func delete(_ item: LauncherItem) -> Bool {
        let ordered = orderedResults
        let next = ordered.firstIndex(where: { $0.id == item.id }).flatMap { index in
            ordered.indices.contains(index + 1) ? ordered[index + 1].id : index > 0 ? ordered[index - 1].id : nil
        }
        if case .provided(let ref) = item.action {
            guard let deletion = registry.deletion(for: item, ref: ref, in: self) else { return false }
            switch deletion {
            case .library(let remove):
                // One save: the row goes with its favorite and usage, or nothing changes.
                let deleted = store.update { database in
                    try remove(&database)
                    database.favoriteIDs.remove(item.id)
                    database.usage.removeAll { $0.id == item.id }
                }
                guard deleted else { return false }
            case .store(let remove):
                // Record the cleanup first, so neither a failed save nor a quit after the
                // deletion can leave Favorites and Recent pointing at the removed row.
                let referenced =
                    store.database.favoriteIDs.contains(item.id) || store.database.usage.contains { $0.id == item.id }
                // A retry of a row whose earlier deletion was already recorded keeps that record
                // whatever happens now: the earlier deletion may have succeeded.
                let wasJournaled = store.journaledCleanup[item.id] != nil
                if referenced, !wasJournaled {
                    do {
                        try store.journalCleanup(of: item.id, provider: ref.provider)
                    } catch {
                        feedback = .error(
                            "“\(item.title.truncatedForFeedback)” wasn't deleted: OpenRay couldn't record the change. \(error.localizedDescription)"
                        )
                        return false
                    }
                }
                guard remove() else {
                    if !wasJournaled { store.unjournalCleanup(of: item.id) }
                    return false
                }
                if referenced, !store.forget(itemIDs: [item.id]) {
                    feedback = .warning(
                        "Deleted “\(item.title.truncatedForFeedback)”, but Favorites and Recent couldn't be updated. "
                            + "OpenRay tries again with the next change it saves.")
                }
            }
            selectedID = next
            // The deleted row may have been a command with a hotkey; release it now.
            commandCatalogDidChange()
            return true
        }
        let deleted = store.update { database in
            switch item.action {
            case .quicklink(let link, _): database.quicklinks.removeAll { $0.id == link.id }
            case .snippet(let snippet): database.snippets.removeAll { $0.id == snippet.id }
            case .note(let note): database.moveNoteToRecentlyDeleted(note.id)
            case .clipboard(let entry): database.clipboard.removeAll { $0.id == entry.id }
            default: return
            }
            database.favoriteIDs.remove(item.id)
            database.usage.removeAll { $0.id == item.id }
            // A deleted quicklink or snippet won't come back, so its alias and hotkey go with it.
            database.commandBindings.removeAll { $0.targetID == item.id }
        }
        guard deleted else { return false }
        selectedID = next
        synchronizeSelection()
        return true
    }

    /// Opens the inline editor for a quicklink, snippet or note.
    func edit(_ item: LauncherItem) {
        if case .provided(let ref) = item.action {
            guard item.canEdit else { return }
            showActions = false
            registry.edit(item, ref: ref, in: self)
            return
        }
        let target: LibraryEditor
        switch item.action {
        case .quicklink(let link, _): target = .quicklink(link)
        case .snippet(let snippet): target = .snippet(snippet)
        case .note(let note): target = .note(note)
        default: return
        }
        showActions = false
        guard editor?.id != target.id else { return }
        // Opening another item mustn't drop unsaved edits; notes save themselves.
        if let draft, !draft.isNote, draft.isDirty {
            confirmation = .discardChanges
            return
        }
        editor = target
    }

    func togglePin(_ item: LauncherItem) {
        guard case .clipboard(let entry) = item.action else { return }
        if store.setPinned(!entry.isPinned, clipboardEntry: entry.id) {
            toast(entry.isPinned ? "Unpinned" : "Pinned to top")
        }
    }

    func toggleFavorite(_ item: LauncherItem) {
        guard item.canFavorite else { return }
        let adding = !isFavorite(item)
        // Home shows sixteen favorites, so a seventeenth is saved but not shown.
        let hidden = adding && favoriteItems.count >= 16
        guard store.toggleFavorite(item.id) else {
            feedback = .error(store.errorMessage ?? "Favorites couldn't be saved.")
            return
        }
        if adding {
            toast(hidden ? "Added to Favorites · Home shows the first 16" : "Added to Favorites")
        } else {
            toast("Removed from Favorites")
        }
    }

    func setClipboardCapture(_ enabled: Bool) {
        if store.update({
            $0.preferences.clipboardEnabled = enabled
            $0.preferences.clipboardPaused = !enabled
        }) {
            applyPreferences()
            if enabled {
                toast("Capture resumed")
            } else if store.database.clipboard.isEmpty {
                toast("Capture paused")
            } else {
                toast("Capture paused. Saved history is still here.")
            }
        }
    }

    /// Turns capture Off rather than Paused, as the first-run switch means it.
    func turnOffClipboardHistory() {
        if store.update({
            $0.preferences.clipboardEnabled = false
            $0.preferences.clipboardPaused = false
        }) {
            applyPreferences()
        } else {
            feedback = .error(store.errorMessage ?? "Clipboard history couldn't be turned off.")
        }
    }

    /// Turns on clipboard history with the choices from the opt-in screen.
    func enableClipboardHistory() {
        // The Turn On button can be clicked under ⌘K, whose opt-in entries would then be stale.
        showActions = false
        confirmation = nil
        let choices = clipboardOptIn
        if store.update({
            $0.preferences.clipboardEnabled = true
            $0.preferences.clipboardPaused = false
            $0.preferences.clipboardImagesEnabled = choices.images
            $0.preferences.clipboardFilesEnabled = choices.files
            $0.preferences.setClipboardRetention(days: choices.days)
            $0.preferences.clipboardLimit = choices.limit
        }) {
            applyPreferences()
            toast("Clipboard history is on")
        } else {
            feedback = .error(store.errorMessage ?? "Clipboard history couldn't be turned on.")
        }
    }

    private func open(_ url: URL, itemID: String) {
        guard allowsSideEffect("opening files and links"), mayOpenFile(url) else { return }
        if openFileThroughWorkspace(url) {
            store.recordUse(of: itemID)
            panel?.dismiss(restoreFocus: false)
        } else {
            let name = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
            feedback = .error("Couldn't open “\(name)”. It may have moved.")
        }
    }

    // MARK: - Action panel

    func actionsDidToggle() {
        actionPath = []
        if showActions {
            actionEntries = actions(for: selectedItem)
            actionFilter = ""
            actionSelection = 0
            confirmation = nil
            if let first = actionEntries.first { announceAction(first) }
        } else {
            actionEntries = []
            requestFocus()
        }
    }

    /// The current level's entries, or every match including submenu entries while filtering.
    var filteredActionEntries: [ActionEntry] { actionEntriesMatching(actionFilter) }

    /// Arrow keys in ⌘K. VoiceOver hears each action as the keyboard reaches it;
    /// hover moves the highlight too, so the announcement lives here, not in the view.
    func moveActionSelection(_ offset: Int) {
        let entries = filteredActionEntries
        let count = entries.count
        guard count > 0 else { return }
        let previous = actionSelection
        actionSelection = (actionSelection + offset + count) % count
        if actionSelection != previous { announceAction(entries[actionSelection]) }
    }

    private func announceAction(_ entry: ActionEntry) {
        announceForVoiceOver([entry.title, entry.shortcut?.spoken].compactMap { $0 }.joined(separator: ", "))
    }

    /// ⌘↩ in ⌘K runs the entry bound to ⌘↩ where you are, whatever row is highlighted or
    /// filtered. On a writing result that's the action ↩ doesn't do; in chat nothing is, as ⌘↩
    /// adds a line there and pasting into another app takes choosing Paste explicitly.
    func performCommandReturnAction() {
        guard let entry = actionEntries.first(where: { $0.shortcut == .commandReturn }) else { return }
        performAction(entry)
    }

    func performActionSelection() {
        let entries = filteredActionEntries
        guard entries.indices.contains(actionSelection) else { return }
        performAction(entries[actionSelection])
    }

    /// Runs an entry, or opens it when it's a submenu.
    func performAction(_ entry: ActionEntry) {
        if !entry.children.isEmpty, showActions {
            openActionSubmenu(entry)
            return
        }
        showActions = false
        entry.perform()
    }

    /// Item actions first, then organisation, then panel-level actions.
    func actions(for item: LauncherItem?) -> [ActionEntry] {
        // Entries outlive this call (⌘K snapshots them), so a command row keeps its identity.
        let item = item.map(markingCommandIdentity)
        var entries: [ActionEntry] = []
        if destination == .ai { return aiActions() }
        if argumentSession != nil {
            return [
                ActionEntry(id: "primary", title: "Run", symbol: "play", shortcut: .return, group: .item) { [weak self] in
                    self?.submitArguments()
                },
                ActionEntry(id: "cancelArguments", title: "Close Arguments", symbol: "xmark", shortcut: .escape, group: .item)
                { [weak self] in self?.cancelArguments() },
            ]
        }
        // Before history exists, the opt-in's two choices are the only actions.
        if showsClipboardOptIn {
            return [
                ActionEntry(id: "turnOn", title: "Turn On Clipboard History", symbol: "power", shortcut: .return, group: .item)
                { [weak self] in self?.enableClipboardHistory() },
                ActionEntry(id: "notNow", title: "Not Now", symbol: "xmark", shortcut: .escape, group: .item)
                { [weak self] in self?.goBack() },
                ActionEntry(id: "shortcuts", title: "Show Shortcuts", symbol: "keyboard", shortcut: .command("/"), group: .panel)
                { [weak self] in self?.showShortcuts = true },
            ]
        }
        if let item, !returnIsInert(for: item) {
            entries.append(
                ActionEntry(
                    id: "primary", title: primaryTitle(for: item), symbol: primarySymbol(for: item),
                    shortcut: .return, group: .item) { [weak self] in self?.perform(item) })
        }
        if let item {
            if let secondary = secondaryTitle(for: item) {
                entries.append(
                    ActionEntry(
                        id: "paste", title: secondary, symbol: "arrow.down.doc", shortcut: .commandReturn, group: .item
                    ) { [weak self] in
                        self?.selectedID = item.id
                        self?.paste(item)
                    })
            }
            switch item.action {
            case .clipboard(let entry):
                if let text = entry.plainText {
                    entries.append(
                        ActionEntry(id: "askAI", title: "Ask AI About This", symbol: "sparkles", shortcut: .tab, group: .item)
                        { [weak self] in
                            self?.selectedID = item.id
                            let attachment = AIAttachment(source: .clipboard, text: text, appName: entry.sourceName)
                            self?.openAI(.chat, attachment: attachment)
                        })
                }
                entries += clipboardEntryActions(for: item, entry: entry)
                entries.append(
                    ActionEntry(
                        id: "pin", title: entry.isPinned ? "Unpin" : "Pin to Top", symbol: entry.isPinned ? "pin.slash" : "pin",
                        shortcut: .command("P", shift: true), key: "p", modifiers: [.command, .shift], group: .organize
                    ) { [weak self] in self?.togglePin(item) })
            case .quicklink(let link, let argument):
                // Argument rows copy the link with their search term filled in. Other
                // links copy the template as written, so ~/ paths stay readable.
                let url =
                    link.needsQuery && !argument.isEmpty
                    ? ((try? link.resolvedURL(query: argument).absoluteString) ?? link.template) : link.template
                entries.append(
                    ActionEntry(
                        id: "copyLink", title: "Copy Link", symbol: "link", shortcut: .command("C", shift: true),
                        key: "c", modifiers: [.command, .shift], group: .item
                    ) { [weak self] in self?.copy(url, label: link.name) })
            case .note(let note):
                entries.append(
                    ActionEntry(
                        id: "copyNote", title: "Copy Text", symbol: "doc.on.doc", shortcut: .command("C", shift: true),
                        key: "c", modifiers: [.command, .shift], group: .item
                    ) { [weak self] in self?.copy(note.content, label: note.title) })
            case .calculation(let calculation):
                if calculation.conversion != nil {
                    entries.append(
                        ActionEntry(id: "copyUnit", title: "Copy with Unit", symbol: "doc.on.doc", group: .item) {
                            [weak self] in
                            // Full precision, as ↩ copies, with the unit the card shows.
                            let symbol = calculation.conversion?.target.symbol ?? ""
                            self?.copy("\(calculation.value) \(symbol)")
                        })
                }
                entries.append(
                    ActionEntry(id: "copyExpression", title: "Copy Expression", symbol: "function", group: .item) {
                        [weak self] in self?.copy(calculation.expression)
                    })
                // The related-unit chips, one entry each, copying the plain value as ↩ does.
                for quantity in calculation.conversion?.related ?? [] {
                    let label = "\(quantity.value) \(quantity.symbol)"
                    entries.append(
                        ActionEntry(
                            id: "copyRelated.\(quantity.symbol)", title: "Copy \(label)", symbol: "doc.on.doc",
                            group: .item
                        ) { [weak self] in self?.copy(quantity.copyValue) })
                }
            case .provided(let ref):
                entries += registry.actions(for: item, ref: ref, in: self)
            case .snippet(let snippet):
                entries.append(
                    ActionEntry(
                        id: "duplicate", title: "Duplicate", symbol: "plus.square.on.square",
                        shortcut: .command("D"), key: "d", modifiers: .command, group: .item
                    ) { [weak self] in
                        if let copy = self?.store.duplicate(snippet) {
                            self?.selectedID = "snippet.\(copy.id)"
                            self?.toast("Duplicated “\(snippet.name.truncatedForFeedback)”")
                        }
                    })
            default: break
            }
            if let url = item.fileURL {
                if case .file = item.action {
                    entries.append(
                        ActionEntry(
                            id: "quickLook", title: "Quick Look", symbol: "eye", shortcut: .command("Y"), key: "y",
                            modifiers: .command, group: .item
                        ) { [weak self] in self?.panel?.toggleQuickLook(url) })
                }
                entries.append(
                    ActionEntry(
                        id: "reveal", title: "Reveal in Finder", symbol: "folder", shortcut: .command("R", shift: true),
                        key: "r", modifiers: [.command, .shift], group: .item
                    ) { [weak self] in
                        guard self?.allowsSideEffect("revealing files in Finder") == true else { return }
                        self?.revealInFinder(url)
                    })
                entries.append(
                    ActionEntry(
                        id: "copyPath", title: "Copy Path", symbol: "doc.on.doc", shortcut: .command("C", shift: true),
                        key: "c", modifiers: [.command, .shift], group: .item
                    ) { [weak self] in self?.copy(url.path, label: Self.shortenedPath(url)) })
            }
            addFileAndApplicationActions(to: &entries, for: item)
            entries += deepLinkActions(for: item)
            if item.canEdit {
                entries.append(
                    ActionEntry(
                        id: "edit", title: "Edit", symbol: "pencil", shortcut: .command("E"), key: "e", modifiers: .command,
                        group: .item
                    ) { [weak self] in
                        self?.selectedID = item.id
                        self?.edit(item)
                    })
            }
            if canBind(item) {
                entries.append(
                    ActionEntry(
                        id: "assign", title: "Assign Alias or Shortcut…", symbol: "keyboard", group: .organize
                    ) { [weak self] in self?.openSettings(.shortcuts, focusing: item.id) })
            }
            if item.canFavorite {
                let favorite = isFavorite(item)
                entries.append(
                    ActionEntry(
                        id: "favorite", title: favorite ? "Remove from Favorites" : "Add to Favorites",
                        symbol: favorite ? "star.slash" : "star", shortcut: .command("F", shift: true), key: "f",
                        modifiers: [.command, .shift], group: .organize
                    ) { [weak self] in self?.toggleFavorite(item) })
                if favorite {
                    if canMoveFavorite(item, by: -1) {
                        entries.append(
                            ActionEntry(
                                id: "favoriteUp", title: "Move Favorite Up", symbol: "arrow.up",
                                shortcut: KeyShortcut(["⌥", "⌘", "↑"]), key: .upArrow, modifiers: [.command, .option],
                                group: .organize, section: "Favorites"
                            ) { [weak self] in self?.moveFavorite(item, by: -1) })
                    }
                    if canMoveFavorite(item, by: 1) {
                        entries.append(
                            ActionEntry(
                                id: "favoriteDown", title: "Move Favorite Down", symbol: "arrow.down",
                                shortcut: KeyShortcut(["⌥", "⌘", "↓"]), key: .downArrow, modifiers: [.command, .option],
                                group: .organize, section: "Favorites"
                            ) { [weak self] in self?.moveFavorite(item, by: 1) })
                    }
                }
            }
            entries += fallbackActions(for: item)
            if canResetRanking(item) {
                entries.append(
                    ActionEntry(id: "resetRanking", title: "Reset Ranking", symbol: "arrow.counterclockwise", group: .organize)
                    { [weak self] in self?.resetRanking(for: item) })
            }
            if isDisableable(item) {
                entries.append(
                    ActionEntry(
                        id: "configure", title: "Configure Command", symbol: "slider.horizontal.3",
                        shortcut: KeyShortcut(["⇧", "⌘", ","]), key: ",", modifiers: [.command, .shift],
                        group: .organize, section: "Command"
                    ) { [weak self] in self?.openSettings(.commands, focusing: item.id) })
                entries.append(
                    ActionEntry(
                        id: "disable", title: "Disable Command", symbol: "nosign", group: .organize, section: "Command"
                    ) { [weak self] in self?.disableCommand(item) })
            }
            if item.canDelete {
                let noun: String =
                    switch item.action {
                    case .clipboard: "Entry"
                    case .snippet: "Snippet"
                    case .quicklink: "Quicklink"
                    case .provided(let ref): registry.itemNoun(for: ref)
                    default: "Note"
                    }
                entries.append(
                    ActionEntry(
                        id: "delete", title: "Delete \(noun)…", symbol: "trash", shortcut: KeyShortcut(["⌘", "⌫"]),
                        key: .delete, modifiers: .command, group: .organize, isDestructive: true
                    ) { [weak self] in self?.requestDelete(item) })
            }
        }
        if section.createsItems {
            entries.append(
                ActionEntry(
                    id: "create", title: "New \(section.itemNoun.capitalized)", symbol: "plus", shortcut: .command("N"),
                    group: .panel
                ) { [weak self] in self?.createItem() })
        }
        if section == .clipboard {
            let enabled = store.database.preferences.clipboardEnabled
            if enabled || store.database.clipboardIsPaused {
                entries.append(
                    ActionEntry(
                        id: "capture", title: enabled ? "Pause Capture" : "Resume Capture",
                        symbol: enabled ? "pause" : "play", group: .panel
                    ) { [weak self] in self?.setClipboardCapture(!enabled) })
            }
            entries.append(
                ActionEntry(
                    id: "filter", title: "Show \(clipboardFilter.next.title)", symbol: "line.3.horizontal.decrease",
                    shortcut: .command("P"), group: .panel
                ) { [weak self] in self?.cycleClipboardFilter() })
            if !store.database.clipboard.isEmpty {
                entries.append(
                    ActionEntry(
                        id: "clear", title: "Delete All History…", symbol: "trash", group: .panel, isDestructive: true
                    ) { [weak self] in
                        guard let self else { return }
                        self.confirmation = .clearClipboardHistory(
                            pinnedCount: self.store.database.clipboard.filter(\.isPinned).count)
                    })
            }
        }
        entries += filesAndApplicationsPanelActions()
        entries.append(
            ActionEntry(id: "shortcuts", title: "Show Shortcuts", symbol: "keyboard", shortcut: .command("/"), group: .panel)
            { [weak self] in self?.showShortcuts = true })
        return markingTertiary(entries)
    }

    private func aiActions() -> [ActionEntry] {
        var entries: [ActionEntry] = []
        let response = ai.isGenerating ? nil : ai.latestResponse
        let isWriting = ai.action != .chat
        if ai.isGenerating {
            entries.append(
                ActionEntry(
                    // ⌘. is bound by the launcher itself while a reply is written.
                    id: "stop", title: "Stop Response", symbol: "stop.fill", shortcut: .command("."), group: .item
                ) { [weak self] in self?.ai.cancel() })
        }
        // Work item 5: ↵ pastes (or copies), ⌘↵ always copies, ⌥↵ pastes with formatting. ⌘↵ is
        // registered in both modes, so it works where no field takes it (an AI Command's result)
        // and from ⌘K. With Copy as the primary action, the paste is here by name, with no key.
        if canAcceptAIResponse {
            entries.append(
                ActionEntry(
                    id: "accept", title: aiAcceptTitle, symbol: aiPrimaryPastes ? "arrow.down.doc" : "doc.on.doc",
                    shortcut: .return, group: .item
                ) { [weak self] in self?.acceptAIResponse() })
            entries.append(
                ActionEntry(
                    id: "secondary", title: aiSecondaryTitle, symbol: "doc.on.doc",
                    shortcut: .commandReturn, key: .return, modifiers: .command, group: .item
                ) { [weak self] in self?.performAISecondary() })
            if !aiPrimaryPastes {
                entries.append(
                    ActionEntry(id: "pasteResponse", title: aiPasteResponseTitle, symbol: "arrow.down.doc", group: .item) {
                        [weak self] in self?.pasteWritingResult()
                    })
            }
            entries.append(
                ActionEntry(
                    id: "pasteFormatted", title: "Paste Formatted Response", symbol: "doc.richtext",
                    shortcut: KeyShortcut(["⌥", "↩"]), key: .return, modifiers: .option, group: .item
                ) { [weak self] in self?.pasteWritingResult(formatted: true) })
        }
        if !isWriting, response != nil {
            entries.append(
                ActionEntry(id: "copy", title: "Copy Response", symbol: "doc.on.doc", shortcut: .command("C", shift: true),
                            key: "c", modifiers: [.command, .shift], group: .item)
                { [weak self] in
                    if let text = self?.ai.latestResponse?.text { self?.copy(text) }
                })
            if !aiResultIsUnchanged {
                // ⌘↩ inserts a new line in chat, so pasting into the app in front is in ⌘K only.
                entries.append(
                    ActionEntry(id: "paste", title: aiPasteTitle, symbol: "arrow.down.doc", group: .item) { [weak self] in
                        self?.pasteAIResponse()
                    })
            }
        }
        // “No action items found.” isn't worth keeping as a note.
        if response != nil, !(ai.action == .actionItems && aiResultIsUnchanged) {
            entries.append(
                ActionEntry(
                    id: "note", title: "Save as Note", symbol: "note.text.badge.plus", shortcut: .command("S"),
                    key: "s", modifiers: .command, group: .item
                ) { [weak self] in self?.saveResponseAsNote() })
        }
        // A stopped writing result can't be pasted, but it can be generated again.
        if ai.canRetry {
            if isWriting {
                entries.append(
                    ActionEntry(
                        id: "retry", title: "Regenerate", symbol: "arrow.clockwise", shortcut: .command("R"), key: "r",
                        modifiers: .command, group: .item
                    ) { [weak self] in self?.regenerateAIResult() })
                entries.append(
                    ActionEntry(
                        id: "retryCreative", title: "Regenerate, More Creative", symbol: "wand.and.sparkles",
                        shortcut: .command("R", shift: true), key: "r", modifiers: [.command, .shift], group: .item
                    ) { [weak self] in self?.regenerateAIResult(creative: true) })
            } else {
                entries.append(
                    ActionEntry(
                        id: "retry", title: "Try Again", symbol: "arrow.clockwise", shortcut: .command("R"), key: "r",
                        modifiers: .command, group: .item
                    ) { [weak self] in self?.ai.retry() })
            }
        }
        // The attachment controls, for the keyboard. Writing commands take their passage when
        // there's none, as the Use Clipboard and Use Selection buttons do.
        if ai.availability.isAvailable, !ai.isGenerating {
            if !isWriting || (ai.messages.isEmpty && ai.attachments.isEmpty) {
                if !ai.attachments.contains(where: { $0.source == .clipboard }) {
                    entries.append(
                        ActionEntry(
                            id: "attachClipboard", title: isWriting ? "Use Clipboard" : "Attach Clipboard",
                            symbol: "list.clipboard", group: .organize
                        ) { [weak self] in self?.attachClipboardToAI() })
                }
                if !ai.attachments.contains(where: { $0.source == .selection }) {
                    entries.append(
                        ActionEntry(
                            id: "attachSelection", title: isWriting ? "Use Selection" : "Attach Selection",
                            symbol: "character.cursor.ibeam", group: .organize
                        ) { [weak self] in
                            self?.attachSelectionFromPreviousApp(reportErrors: true)
                            self?.focusRequest += 1
                        })
                }
            }
            if !isWriting, let attachment = ai.attachments.last {
                entries.append(
                    ActionEntry(
                        id: "removeAttachment", title: "Remove Attachment", symbol: "xmark.circle", group: .organize
                    ) { [weak self] in self?.ai.removeAttachment(attachment.id) })
            }
        }
        if isWriting, ai.command == nil, !ai.isGenerating, ai.lastCompletedResult != nil {
            entries.append(
                ActionEntry(
                    id: "continueResult", title: "Use Result as New Passage", symbol: "arrow.triangle.2.circlepath",
                    group: .organize
                ) { [weak self] in self?.continueAIFromResult() })
        }
        if isWriting, response != nil {
            entries.append(
                ActionEntry(
                    id: "chat", title: "Ask About It in Chat", symbol: "bubble.left.and.text.bubble.right", group: .organize
                ) { [weak self] in
                    guard let self, !self.ai.isGenerating, let text = self.ai.latestResponse?.text else { return }
                    // The writing run stays in the history.
                    self.commitWritingRun()
                    self.ai.newConversation(action: .chat)
                    self.ai.open(.chat)
                    self.ai.attach(AIAttachment(source: .response, text: text))
                    self.focusRequest += 1
                })
        }
        entries += slice7AIActions()
        if !ai.isGenerating {
            entries.append(
                ActionEntry(
                    id: "new", title: isWriting && ai.command == nil ? "New" : "New Chat", symbol: "square.and.pencil",
                    shortcut: .command("N"), group: .organize
                ) { [weak self] in self?.newAIConversation() })
        }
        // ⌘[ and ⌘] are the launcher's own keys (see `handle(_:)`).
        if canShowPreviousRun {
            entries.append(
                ActionEntry(
                    id: "previousRun", title: "Previous Run", symbol: "chevron.backward", shortcut: .command("["),
                    group: .organize
                ) { [weak self] in self?.showWritingRun(-1) })
        }
        if canShowNextRun {
            entries.append(
                ActionEntry(
                    id: "nextRun", title: "Next Run", symbol: "chevron.forward", shortcut: .command("]"), group: .organize
                ) { [weak self] in self?.showWritingRun(1) })
        }
        // The original passage, and the result with its changes marked, are a ⌘K away.
        if isWriting, let response, !response.isPartial, !aiResultIsUnchanged, ai.lastSource != nil,
            ai.command == nil || ai.command?.source != nil
        {
            var modes: [(mode: AIDiffMode, title: String, symbol: String)] = [(.result, "Show Response", "doc.text")]
            if ai.lastDiff != nil { modes.append((.changes, "Show Changes", "plus.forwardslash.minus")) }
            modes.append((.original, "Show Original", "doc.plaintext"))
            for option in modes {
                entries.append(
                    ActionEntry(
                        id: "view.\(option.title)", title: option.title,
                        symbol: ai.diffMode == option.mode ? "checkmark" : option.symbol, group: .panel
                    ) { [weak self] in self?.ai.diffMode = option.mode })
            }
        }
        entries.append(
            ActionEntry(id: "shortcuts", title: "Show Shortcuts", symbol: "keyboard", shortcut: .command("/"), group: .panel)
            { [weak self] in self?.showShortcuts = true })
        return entries
    }

    private func primarySymbol(for item: LauncherItem) -> String {
        switch item.action {
        case .clipboard, .snippet, .calculation: "doc.on.doc"
        case .window: "macwindow"
        case .ai, .askAI: "sparkles"
        case .note: "note.text"
        case .section: "arrow.right.circle"
        case .provided(let ref): registry.primarySymbol(for: item, ref: ref, in: self)
        default: "arrow.up.forward.app"
        }
    }

    /// ↩ on the active token's own row before a term is typed would only restart the
    /// same token, so the bar, ⌘K and ⌘/ don't offer it.
    func returnIsInert(for item: LauncherItem) -> Bool {
        guard let link = argumentLink, item.id == "argument.\(link.id)", case .quicklink(_, let argument) = item.action
        else { return false }
        // A blank term runs with the field's default; only a required field waits for one.
        return argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quicklinkArgumentIsRequired(link)
    }

    /// A source is still streaming, so an empty list isn't the final answer yet.
    var isAwaitingResults: Bool {
        let filesPending = argumentLink == nil && files.isSearching && (section == .files || section == .home && query.count >= 2)
        return filesPending || section == .applications && applications.isLoading
            || section.providedScope != nil && isLoadingProvidedItems
    }

    /// Clipboard History shows the opt-in screen until capture is on, paused, or history exists.
    var showsClipboardOptIn: Bool {
        destination == .search && section == .clipboard && !store.database.preferences.clipboardEnabled
            && !store.database.clipboardIsPaused && store.database.clipboard.isEmpty
    }

    func cycleClipboardFilter() {
        // The opt-in has no list to filter, so ⌘P does nothing there.
        guard section == .clipboard, !showsClipboardOptIn else { return }
        clipboardFilter = clipboardFilter.next
    }
}
