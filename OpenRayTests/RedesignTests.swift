import AppKit
import Foundation
import Testing

@testable import OpenRay

@MainActor
struct RedesignTests {
    private func model() -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
    }

    /// A library from a newer OpenRay, which loads read-only.
    private func readOnlyModel(in directory: URL) throws -> LauncherModel {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "library.json")
        var future = LibraryDatabase()
        future.schemaVersion = LibraryDatabase.currentSchemaVersion + 1
        try JSONEncoder().encode(future).write(to: url)
        return LauncherModel(
            store: LibraryStore(fileURL: url), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
    }

    // MARK: Search groups

    @Test func topHitComesFromInstantSourcesAndFallbacksComeLast() {
        let model = model()
        defer { model.stop() }
        model.store.toggleFavorite("file./Users/example/Documents/Snippets")
        model.query = "Snippets"
        model.files.stop()
        let groups = model.groups
        #expect(groups.first?.id == "top")
        #expect(groups.first?.items.first?.id == "section.snippets")
        #expect(groups.last?.id == "fallbacks")
        #expect(groups.last?.items.map(\.id) == ["fallback.ai", "fallback.web"])
        #expect(model.selectedItem?.id == "section.snippets")
    }

    @Test func homeShowsOrderedFavoritesAndFourRecentsWithoutSuggestions() {
        let model = model()
        defer { model.stop() }
        for id in ["section.windows", "section.calculator", "section.quicklinks", "section.applications", "settings"] {
            model.store.recordUse(of: id)
        }
        let groups = model.groups
        #expect(groups.map(\.id) == ["favorites", "recent"])
        #expect(groups[0].items.map(\.id) == LibraryDatabase.defaultFavorites)
        #expect(groups[1].items.count == 4)
        #expect(groups[1].items.first?.id == "settings")
        // Favorite tiles number themselves by position; ⌘2 opens the second one.
        #expect(groups[0].trailing == "⌘1 – ⌘\(min(8, groups[0].items.count))")
        #expect(model.numberShortcut(for: groups[0].items[1]) == nil)
    }

    @Test func commandNumberOpensTheFavoriteInThatPosition() {
        let model = model()
        defer { model.stop() }
        model.performNumber(2)
        #expect(model.section == .clipboard)
        model.navigate(to: .home)
        model.store.toggleFavorite("section.windows")
        #expect(model.store.database.orderedFavoriteIDs.last == "section.windows")
        model.performNumber(LibraryDatabase.defaultFavorites.count + 1)
        #expect(model.section == .windows)
        model.files.stop()
    }

    @Test func lateFilesNeverPushTheTopHitOutOfHome() {
        let model = model()
        defer { model.stop() }
        let snippet = Snippet(name: "Invoice footer", keyword: ";pdf", content: "Attached as a PDF.")
        #expect(model.store.save(snippet))
        model.query = "pdf"
        model.files.stop()
        model.synchronizeSelection()
        #expect(model.groups.first?.id == "top")
        #expect(model.groups.first?.items.first?.id == "snippet.\(snippet.id)")
        #expect(model.selectedItem?.id == "snippet.\(snippet.id)")
        // Spotlight rows that outscore every instant row still can't evict one.
        let instant = model.results
        let lateFiles = (0..<60).map { index in
            LauncherItem(
                id: "file./tmp/pdf-\(index).pdf", title: "pdf-\(index).pdf", subtitle: "/tmp", symbol: "doc",
                kind: .file, badge: "PDF", action: .file(URL(fileURLWithPath: "/tmp/pdf-\(index).pdf")),
                isLiveResult: true)
        }
        let capped = LauncherModel.capped(lateFiles + instant, in: .home)
        #expect(capped.first?.id == "snippet.\(snippet.id)")
        #expect(capped.filter { !$0.isLiveResult }.map(\.id) == instant.map(\.id))
        #expect(capped.filter(\.isLiveResult).count == 20)
        #expect(LauncherModel.capped(lateFiles, in: .files).count == 60)
    }

    @Test func usageBreaksNearTiesButNeverBeatsAnExactMatch() {
        let model = model()
        defer { model.stop() }
        let zephyr = Snippet(name: "Zephyr notes", keyword: "", content: "Light wind")
        let zesty = Snippet(name: "Zesty recipe", keyword: "", content: "Lemon")
        #expect(model.store.save(zephyr))
        #expect(model.store.save(zesty))
        model.query = "ze"
        model.files.stop()
        #expect(model.results.first?.id == "snippet.\(zephyr.id)")
        for _ in 0..<3 { model.store.recordUse(of: "snippet.\(zesty.id)") }
        #expect(model.results.first?.id == "snippet.\(zesty.id)")
        let exact = Snippet(name: "Ze", keyword: "", content: "Exact")
        #expect(model.store.save(exact))
        for _ in 0..<20 { model.store.recordUse(of: "snippet.\(zesty.id)") }
        #expect(model.results.first?.id == "snippet.\(exact.id)")
        model.files.stop()
    }

    @Test func whitespaceQueriesShowHomeAndBarModeExpandsForFeedback() {
        let model = model()
        defer { model.stop() }
        model.store.update { $0.preferences.barMode = true }
        #expect(model.isCollapsedToBar)
        model.query = "   "
        #expect(model.isQueryBlank)
        #expect(model.isCollapsedToBar)
        #expect(model.groups.map(\.id) == ["favorites"])
        #expect(model.arrowsMoveSelection)
        model.feedback = .error("Couldn't open Safari.")
        #expect(!model.isCollapsedToBar)
        model.feedback = nil
        model.confirmation = .discardChanges
        #expect(!model.isCollapsedToBar)
        model.confirmation = nil
        model.query = "notes"
        #expect(!model.isQueryBlank)
        #expect(!model.isCollapsedToBar)
        model.files.stop()
    }

    @Test func movingTheSelectionByHandClearsPromptsAndErrors() {
        let model = model()
        defer { model.stop() }
        model.synchronizeSelection()
        model.confirmation = .discardChanges
        model.feedback = .error("Couldn't open Safari.")
        #expect(model.moveSelectionHorizontally(1))
        #expect(model.confirmation == nil)
        #expect(model.feedback == nil)
        model.navigate(to: .clipboard)
        model.feedback = .warning("Clipboard access is off.")
        model.clipboardFilter = .links
        #expect(model.feedback == nil)
        // A hidden panel doesn't start Spotlight when the scope changes.
        model.navigate(to: .files)
        model.files.stop()
        model.fileScope = .documents
        #expect(!model.files.isSearching)
        model.files.stop()
    }

    // MARK: Tokens

    @Test func quicklinkKeywordAndSpaceBecomeAnArgumentTokenThatDeleteRestores() {
        let model = model()
        defer { model.stop() }
        model.query = "web "
        #expect(model.argumentLink?.keyword == "web")
        #expect(model.query.isEmpty)
        model.query = "swift concurrency"
        if case .quicklink(_, let argument) = model.selectedItem?.action {
            #expect(argument == "swift concurrency")
        } else {
            Issue.record("Expected the argument row to be selected")
        }
        #expect(model.groups.map(\.id) == ["argument", "elsewhere"])
        model.query = ""
        #expect(model.deleteBackwardOnEmptyField())
        #expect(model.argumentLink == nil)
        #expect(model.query == "web")
        model.files.stop()
    }

    @Test func argumentSubtitleShowsHowTheTermIsEncoded() {
        let model = model()
        defer { model.stop() }
        model.query = "web swift concurrency"
        #expect(model.argumentLink?.keyword == "web")
        #expect(model.groups.first?.items.first?.subtitle.contains("swift%20concurrency") == true)
        model.files.stop()
    }

    @Test func deleteOnAnEmptyScopeReturnsToEverythingWithThePreviousQuery() {
        let model = model()
        defer { model.stop() }
        model.query = "clip"
        model.files.stop()
        model.synchronizeSelection()
        model.handleTab()
        #expect(model.section == .clipboard)
        #expect(model.query.isEmpty)
        #expect(model.deleteBackwardOnEmptyField())
        #expect(model.section == .home)
        #expect(model.query == "clip")
        #expect(!model.deleteBackwardOnEmptyField())
        model.files.stop()
    }

    @Test func tabOnAQueryAsksAIWithTheQueryAsTheFirstMessage() async {
        let engine = TestAIEngine()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        model.query = "zzzz explain structured concurrency"
        model.files.stop()
        model.synchronizeSelection()
        model.handleTab()
        #expect(model.destination == .ai)
        await model.ai.waitForResponse()
        #expect(engine.prompts == ["zzzz explain structured concurrency"])
        model.goBack()
        #expect(model.destination == .search)
        #expect(model.query == "zzzz explain structured concurrency")
        model.files.stop()
    }

    @Test func escThenTabOnTheSameQueryReturnsToItsAnswer() async {
        let engine = TestAIEngine()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        model.query = "zzzz explain structured concurrency"
        model.files.stop()
        model.synchronizeSelection()
        model.handleTab()
        await model.ai.waitForResponse()
        model.goBack()
        model.files.stop()
        model.synchronizeSelection()
        model.handleTab()
        await model.ai.waitForResponse()
        #expect(model.destination == .ai)
        #expect(engine.prompts.count == 1)
        #expect(model.ai.latestResponse != nil)
        model.files.stop()
    }

    @Test func escThenTabAfterAFollowUpKeepsTheWholeChat() async {
        let engine = TestAIEngine()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        model.query = "zzzz explain structured concurrency"
        model.files.stop()
        model.synchronizeSelection()
        model.handleTab()
        await model.ai.waitForResponse()
        model.ai.draft = "and task groups?"
        model.ai.send()
        await model.ai.waitForResponse()
        model.goBack()
        #expect(model.query == "zzzz explain structured concurrency")
        model.files.stop()
        model.synchronizeSelection()
        model.handleTab()
        await model.ai.waitForResponse()
        #expect(model.destination == .ai)
        #expect(model.ai.messages.count == 4)
        #expect(engine.prompts == ["zzzz explain structured concurrency", "and task groups?"])
        model.files.stop()
    }

    @Test func tabWithANewQueryStartsANewChat() async {
        let engine = TestAIEngine()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        model.query = "zzzz first question"
        model.files.stop()
        model.synchronizeSelection()
        model.handleTab()
        await model.ai.waitForResponse()
        model.goBack()
        model.query = "zzzz second question"
        model.files.stop()
        model.synchronizeSelection()
        model.handleTab()
        await model.ai.waitForResponse()
        #expect(model.ai.messages.first?.text == "zzzz second question")
        #expect(engine.prompts == ["zzzz first question", "zzzz second question"])
        // Opening AI without a query resumes that chat.
        model.goBack()
        model.openAI()
        #expect(model.ai.messages.first?.text == "zzzz second question")
        model.files.stop()
    }

    @Test func tabWithAQueryAsksAIFromAnyScopeAndEscReturnsThere() async {
        let engine = TestAIEngine()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        model.navigate(to: .snippets)
        model.query = "explain x"
        model.synchronizeSelection()
        model.handleTab()
        #expect(model.destination == .ai)
        await model.ai.waitForResponse()
        #expect(engine.prompts == ["explain x"])
        model.goBack()
        #expect(model.section == .snippets)
        #expect(model.query == "explain x")
        model.files.stop()
    }

    @Test func tabKeepsTheQueryAsADraftWhenAIIsUnavailable() {
        let engine = TestAIEngine()
        engine.availability = .notEnabled
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        model.query = "zzzz explain structured concurrency"
        model.files.stop()
        model.synchronizeSelection()
        model.handleTab()
        #expect(model.destination == .ai)
        #expect(model.ai.draft == "zzzz explain structured concurrency")
        #expect(model.ai.messages.isEmpty)
        #expect(engine.prompts.isEmpty)
        model.files.stop()
    }

    /// Changed by the main merge review (finding 4): reopening a writing command keeps its
    /// finished result and offers a different selection, which replaces it only when chosen.
    @Test func writingCommandsKeepTheirResultAndOfferANewSelection() async {
        let model = model()
        defer { model.stop() }
        var selection = "Their are two things."
        model.selectionReader = { selection }
        model.openAI(.proofread)
        #expect(model.ai.attachments.first?.text == "Their are two things.")
        model.ai.send()
        await model.ai.waitForResponse()
        #expect(model.ai.lastSource == "Their are two things.")
        model.leaveAI()
        selection = "A different passage."
        model.openAI(.proofread)
        #expect(model.ai.lastSource == "Their are two things.")
        #expect(model.ai.messages.count == 2)
        #expect(model.pendingNewSelection?.text == "A different passage.")
        model.usePendingSelection()
        #expect(model.ai.attachments.first?.text == "A different passage.")
        #expect(model.ai.messages.isEmpty)
        #expect(model.ai.lastSource == nil)
        model.files.stop()
    }

    @Test func escapeClosesExactlyOneLayerInOrder() {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .clipboard)
        model.query = "invoice"
        model.showActions = true
        model.goBack()
        #expect(!model.showActions)
        #expect(model.section == .clipboard)
        model.goBack()
        #expect(model.section == .home)
        model.query = "left over"
        model.goBack()
        #expect(model.query.isEmpty)
        model.files.stop()
    }

    // MARK: Library

    @Test func pinnedClipboardEntriesSurviveRetentionAndTheEntryLimit() {
        let store = LibraryStore(fileURL: nil)
        store.update {
            $0.preferences.clipboardEnabled = true
            $0.preferences.clipboardLimit = 1
            $0.preferences.clipboardRetentionDays = 1
        }
        let old = Date().addingTimeInterval(-5 * 86_400)
        #expect(store.capture(ClipboardEntry(text: "Studio address", copiedAt: old, sourceName: "Notes"), now: old))
        let pinned = store.database.clipboard[0].id
        #expect(store.setPinned(true, clipboardEntry: pinned))
        #expect(store.capture(ClipboardEntry(text: "Newest", sourceName: "Mail")))
        #expect(store.capture(ClipboardEntry(text: "Even newer", sourceName: "Mail")))
        #expect(store.database.clipboard.map(\.text).sorted() == ["Even newer", "Studio address"])
        store.pruneClipboard()
        #expect(store.database.clipboard.contains { $0.id == pinned && $0.isPinned })
    }

    @Test func pinningRoundTripsAndOlderEntriesDecodeUnpinned() throws {
        var entry = ClipboardEntry(text: "Keep", sourceName: "Notes")
        entry.isPinned = true
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.isPinned)
        let legacy = Data(#"{"id":"\#(UUID())","text":"Old","copiedAt":0,"sourceName":"App"}"#.utf8)
        #expect(try JSONDecoder().decode(ClipboardEntry.self, from: legacy).isPinned == false)
    }

    @Test func notesTakeTheirTitleFromTheFirstLine() {
        let store = LibraryStore(fileURL: nil)
        #expect(store.save(QuickNote(title: "", content: "\n  Launch checklist  \nSign the build")))
        #expect(store.database.notes.first?.title == "Launch checklist")
        #expect(!store.save(QuickNote(title: " ", content: " \n ")))
    }

    @Test func linksAreTheirOwnClipboardType() {
        let link = ClipboardEntry(text: "https://developer.apple.com/documentation", sourceName: "Safari")
        let text = ClipboardEntry(text: "Not a link https://example.com", sourceName: "Notes")
        #expect(link.isLink && !text.isLink)
        #expect(ClipboardFilter.links.includes(link) && !ClipboardFilter.links.includes(text))
        #expect(ClipboardFilter.text.includes(text) && !ClipboardFilter.text.includes(link))
        #expect(ClipboardFilter.links.next == .all)
    }

    @Test func snippetsWithoutTheExpansionFlagKeepExpanding() throws {
        let snippet = Snippet(name: "Sig", keyword: ";sig", content: "Best")
        #expect(snippet.expandsAsYouType)
        var off = snippet
        off.expandsKeyword = false
        let decoded = try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(off))
        #expect(!decoded.expandsAsYouType)
    }

    @Test func editorDraftsValidateKeywordConflictsAsYouType() {
        let model = model()
        defer { model.stop() }
        #expect(model.store.save(Snippet(name: "Old signature", keyword: ";sig", content: "Hi")))
        model.navigate(to: .snippets)
        model.createItem()
        let draft = try! #require(model.draft)
        draft.keyword = ";sig"
        #expect(draft.keywordError?.contains("Old signature") == true)
        draft.keyword = "web"
        #expect(draft.keywordError?.contains("Search the Web") == true)
        draft.keyword = ";sig2"
        draft.name = "New"
        draft.content = "Body"
        #expect(draft.keywordError == nil)
        model.saveEditor()
        #expect(model.editor == nil)
        #expect(model.store.database.snippets.count == 2)
        model.files.stop()
    }

    @Test func legacyKeywordClashesDoNotBlockOtherEdits() throws {
        let model = model()
        defer { model.stop() }
        // Older libraries only rejected duplicate snippet keywords, so this clash with “Search the Web” can exist.
        let legacy = Snippet(name: "Web signature", keyword: "web", content: "Sent from the web")
        #expect(model.store.save(legacy))
        model.navigate(to: .snippets)
        model.editor = .snippet(legacy)
        let draft = try #require(model.draft)
        draft.name = "Web footer"
        #expect(draft.keywordError == nil)
        draft.keyword = "gh"
        #expect(draft.keywordError?.contains("Search GitHub") == true)
        draft.keyword = "web"
        model.saveEditor()
        #expect(model.editor == nil)
        #expect(model.store.database.snippets.first { $0.id == legacy.id }?.name == "Web footer")
        model.files.stop()
    }

    @Test func aFailedSaveAsksTheEditorToFocusTheInvalidField() throws {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .quicklinks)
        model.createItem()
        let draft = try #require(model.draft)
        #expect(draft.invalidFocusRequest == 0)
        model.saveEditor()
        #expect(model.editor != nil)
        #expect(draft.nameError != nil)
        #expect(draft.invalidFocusRequest == 1)
        model.saveEditor()
        #expect(draft.invalidFocusRequest == 2)
        model.files.stop()
    }

    @Test func editingAgainWithdrawsTheDiscardPrompt() throws {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .snippets)
        model.createItem()
        let draft = try #require(model.draft)
        draft.name = "Signature"
        model.goBack()
        #expect(model.confirmation?.id == "discard")
        draft.content = "Best, Ali"
        #expect(model.confirmation == nil)
        #expect(model.editor != nil)
        // ⌘N doesn't silently replace the edits either.
        model.createItem()
        #expect(model.confirmation?.id == "discard")
        #expect(model.draft === draft)
        model.files.stop()
    }

    @Test func notesSaveEditsBackToTheirOpeningText() throws {
        let model = model()
        defer { model.stop() }
        #expect(model.store.save(QuickNote(title: "", content: "Launch checklist\nSign the build")))
        let note = try #require(model.store.database.notes.first)
        model.editor = .note(note)
        let draft = try #require(model.draft)
        draft.content = "Launch checklist\nSign and notarize the build"
        #expect(draft.saveNote())
        #expect(model.store.database.notes.first?.content == "Launch checklist\nSign and notarize the build")
        #expect(!draft.isDirty)
        draft.content = "Launch checklist\nSign the build"
        #expect(draft.isDirty)
        #expect(draft.saveNote())
        #expect(model.store.database.notes.first?.content == "Launch checklist\nSign the build")
        model.files.stop()
    }

    @Test func anEmptiedNoteIsRemovedWhenItCloses() throws {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .notes)
        model.createItem()
        let draft = try #require(model.draft)
        draft.content = "Pick up the prints"
        #expect(draft.saveNote())
        let note = try #require(model.store.database.notes.first)
        let itemID = "note.\(note.id)"
        model.store.toggleFavorite(itemID)
        model.store.recordUse(of: itemID)
        draft.content = ""
        // Autosave skips an empty note, so clearing it mid-edit deletes nothing.
        #expect(draft.saveNote())
        #expect(model.store.database.notes.count == 1)
        // Hiding the panel leaves the editor open, so the note and its favorite stay too.
        model.panelDidHide()
        #expect(model.editor != nil)
        #expect(model.store.database.notes.count == 1)
        #expect(model.store.database.favoriteIDs.contains(itemID))
        model.goBack()
        #expect(model.editor == nil)
        // Closing moves it to Recently Deleted, recoverable for 60 days, not out of the library.
        #expect(model.store.database.liveNotes.isEmpty)
        #expect(model.store.database.notes.first?.isDeleted == true)
        #expect(!model.store.database.favoriteIDs.contains(itemID))
        #expect(!model.store.database.usage.contains { $0.id == itemID })
        model.files.stop()
    }

    @Test func aNoteThatCannotBeSavedStaysOpenUntilDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try readOnlyModel(in: directory)
        defer { model.stop() }
        #expect(model.store.isReadOnly)
        model.navigate(to: .notes)
        model.createItem()
        let draft = try #require(model.draft)
        draft.content = "Call the studio"
        model.goBack()
        #expect(model.editor != nil)
        #expect(model.confirmation?.id == "discard")
        #expect(draft.saveError != nil)
        model.confirm(.discardChanges)
        #expect(model.editor == nil)
        model.files.stop()
    }

    @Test func aLibraryThatFailedToLoadSkipsOnboarding() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let readOnly = try readOnlyModel(in: directory)
        defer { readOnly.stop() }
        #expect(readOnly.store.isReadOnly)
        #expect(readOnly.store.database.preferences.needsFirstRun)
        readOnly.beginOnboardingIfNeeded()
        #expect(readOnly.onboarding == nil)
        // A new library on disk still starts it.
        let fresh = LauncherModel(
            store: LibraryStore(fileURL: directory.appending(path: "new-library.json")),
            ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName())
        defer { fresh.stop() }
        fresh.beginOnboardingIfNeeded()
        #expect(fresh.onboarding == .shortcut)
    }

    @Test func settingsCanOpenAtACommandsRow() {
        let model = model()
        defer { model.stop() }
        var request: (pane: SettingsPane?, commandID: String?)?
        model.presentSettings = { pane, commandID in request = (pane: pane, commandID: commandID) }
        model.openSettings(.shortcuts, focusing: "ai.proofread")
        #expect(request?.pane == .shortcuts)
        #expect(request?.commandID == "ai.proofread")
        model.openSettings()
        #expect(request?.pane == nil)
        #expect(request?.commandID == nil)
    }

    // MARK: Calculator

    @Test func conversionsCarryUnitsRelatedValuesAndAUnitlessCopyValue() throws {
        let calculation = try #require(Calculator.evaluate("10 km in mi"))
        let conversion = try #require(calculation.conversion)
        #expect(conversion.source.name == "Kilometers")
        #expect(conversion.target.symbol == "mi")
        // Shown with six significant digits; ↩ copies the full value.
        #expect(calculation.value == "6.21371192237")
        #expect(calculation.result == "6.21371 mi")
        #expect(calculation.shownValue == "6.21371")
        #expect(conversion.target.copyValue == calculation.value)
        #expect(conversion.related.map(\.symbol) == ["ft", "m", "yd", "cm"])
        #expect(Calculator.evaluate("6 * 7")?.value == "42")
        #expect(Calculator.searchIssue(for: "1 / 0") == .divisionByZero)
        #expect(Calculator.searchIssue(for: "invoice") == nil)
        #expect(Calculator.searchIssue(for: "2 +") == nil)
    }

    // MARK: Text helpers

    @Test func wordDiffCountsEditsAndKeepsEveryCharacter() {
        let original = "Thanks for the report on monday. Their are two things."
        let revised = "Thanks for the report on Monday. There are two things."
        let diff = WordDiff(from: original, to: revised)
        #expect(diff.changeCount == 2)
        let rebuiltOriginal = diff.segments.map { segment -> String in
            switch segment {
            case .same(let text), .removed(let text): text
            case .added: ""
            }
        }.joined()
        let rebuiltRevised = diff.segments.map { segment -> String in
            switch segment {
            case .same(let text), .added(let text): text
            case .removed: ""
            }
        }.joined()
        #expect(rebuiltOriginal == original)
        #expect(rebuiltRevised == revised)
        #expect(WordDiff(from: "Same text.", to: "Same text.").isUnchanged)
    }

    @Test func matchedOffsetsPreferWordStartsAndFoldCase() {
        #expect(SearchMatcher.matchedOffsets("inv", in: "Invoice email") == Set(0..<3))
        #expect(SearchMatcher.matchedOffsets("mail", in: "Invoice email") == Set(9..<13))
        #expect(SearchMatcher.matchedOffsets("cafe", in: "Café") == Set(0..<4))
        #expect(SearchMatcher.matchedOffsets("zz", in: "Notes").isEmpty)
    }

    @Test func clipboardSearchKeepsScoreOrderAndHistoryHasOneHeaderPerDay() {
        let model = model()
        defer { model.stop() }
        let now = Date.now
        let entries = [
            ClipboardEntry(text: "Invoice draft", copiedAt: now, sourceName: "Mail"),
            ClipboardEntry(text: "Old invoice", copiedAt: now.addingTimeInterval(-3 * 86_400), sourceName: "Mail"),
            ClipboardEntry(text: "Invoice", copiedAt: now, sourceName: "Notes"),
        ]
        model.store.update {
            $0.preferences.clipboardEnabled = true
            $0.clipboard = entries
        }
        model.navigate(to: .clipboard)
        let history = model.groups
        #expect(history.count == 2)
        #expect(Set(history.map(\.id)).count == history.count)
        let today: Set = ["clipboard.\(entries[0].id)", "clipboard.\(entries[2].id)"]
        #expect(Set(history.first?.items.map(\.id) ?? []) == today)
        model.query = "invoice"
        let search = model.groups
        #expect(search.map(\.id) == ["clipboard.results"])
        #expect(search.first?.items.first?.id == "clipboard.\(entries[2].id)")
        #expect(model.selectedItem?.id == "clipboard.\(entries[2].id)")
        model.files.stop()
    }

    @Test func clipboardDaysReadAsTodayYesterdayThenWeekdays() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        #expect(LauncherModel.dayTitle(for: now, now: now, calendar: calendar) == "Today")
        #expect(LauncherModel.dayTitle(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Yesterday")
        #expect(LauncherModel.dayTitle(for: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar) != "Yesterday")
    }

    @Test func feedbackTruncatesLongTitlesForTheActionBar() {
        #expect("Invoice #2291 — Studio rent".truncatedForFeedback == "Invoice #2291 — Studio rent")
        #expect(String(repeating: "a", count: 60).truncatedForFeedback.count == 41)
        #expect("First line\nSecond".truncatedForFeedback == "First line")
    }
}
