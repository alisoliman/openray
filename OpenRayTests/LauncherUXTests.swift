import AppKit
import SwiftUI
import Testing

@testable import OpenRay

@MainActor
struct LauncherUXTests {
    private func model(engine: TestAIEngine = TestAIEngine()) -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName())
    }

    @Test func openActionsKeepTheUnderlyingResultSelected() {
        let model = model()
        model.navigate(to: .windows)
        let selection = model.selectedID
        model.showActions = true
        model.moveSelection(1)
        #expect(model.selectedID == selection)
        model.goBack()
        #expect(!model.showActions)
        model.moveSelection(1)
        #expect(model.selectedID != selection)
    }

    @Test func returnDoesNotExecuteAResultBehindActions() {
        let model = model()
        model.query = "Snippets"
        model.files.stop()
        model.synchronizeSelection()
        model.showActions = true
        model.performSelected()
        #expect(model.section == .home)
        #expect(model.showActions)
    }

    @Test func exactCommandsOutrankEvenFavoriteFilesWithTheSameName() {
        let model = model()
        for name in ["Snippets", "Notes", "Settings"] {
            model.store.toggleFavorite("file./Users/example/Documents/\(name)")
            model.query = name
            model.files.stop()
            #expect(model.results.first?.id == (name == "Settings" ? "settings" : "section.\(name.lowercased())"))
            #expect(model.results.contains { $0.id == "file./Users/example/Documents/\(name)" })
        }
    }

    @Test func fileLabelsDistinguishIdenticalNamesInDifferentFolders() {
        let model = model()
        model.store.toggleFavorite("file./Users/example/Documents/snippets")
        model.store.toggleFavorite("file./Users/example/Projects/snippets")
        model.query = "snippets"
        model.files.stop()
        let files = model.results.filter { $0.id.hasPrefix("file.") }
        #expect(files.count == 2)
        #expect(Set(files.map(\.accessibilityDescription)).count == 2)
        #expect(files.contains { $0.accessibilityDescription.contains("/Users/example/Documents") })
        #expect(files.contains { $0.accessibilityDescription.contains("/Users/example/Projects") })
    }

    @Test func actionPanelRunsTheActionPresentedWhenItOpened() {
        let model = model()
        let note = QuickNote(title: "A note", content: "Body")
        #expect(model.store.save(note))
        model.navigate(to: .notes)
        model.showActions = true
        let snapshot = model.actionEntries.map(\.id)
        #expect(snapshot.first == "primary")
        // Results changing behind the panel must not change what it runs.
        model.store.update { $0.notes.append(QuickNote(title: "Another", content: "")) }
        #expect(model.actionEntries.map(\.id) == snapshot)
        model.actionSelection = model.filteredActionEntries.firstIndex { $0.id == "copyNote" } ?? 0
        model.performActionSelection()
        #expect(!model.showActions)
        #expect(model.feedback?.text.contains("A note") == true)
        model.files.stop()
    }

    // MARK: Bound commands

    @Test func boundCommandsRunWhenShowingThePanelClosesACleanEditor() {
        let model = model()
        let panel = LauncherPanelController(model: model)
        model.panel = panel
        defer {
            panel.dismiss(restoreFocus: false)
            model.stop()
        }
        model.store.update { $0.preferences.rememberLastQuery = false }
        let binding = CommandBinding(
            targetID: "section.notes", shortcut: CommandShortcut(keyCode: 45, modifiers: [.control, .option]))
        #expect(model.store.saveCommandBinding(binding))
        // Showing resets to Home, which closes an untouched editor, so nothing blocks the command.
        model.editor = .note(QuickNote(title: "", content: ""))
        model.performBoundCommand(targetID: binding.targetID)
        #expect(model.editor == nil)
        #expect(model.section == .notes)
        model.files.stop()
    }

    @Test func reservedLauncherShortcutsFallBackWithoutChangingTheSavedOne() {
        let control = LauncherHotKey.controlSpace.shortcut
        let option = LauncherHotKey.optionSpace.shortcut
        let every = Set(LauncherHotKey.allCases.map(\.shortcut))
        #expect(LauncherModel.launcherHotKey(for: .controlSpace, reserved: [], boundShortcuts: []) == .controlSpace)
        #expect(
            LauncherModel.launcherHotKey(for: .controlSpace, reserved: [control], boundShortcuts: []) == .optionSpace)
        #expect(
            LauncherModel.launcherHotKey(for: .controlSpace, reserved: [control], boundShortcuts: [option])
                == .controlOptionSpace)
        #expect(LauncherModel.launcherHotKey(for: .optionSpace, reserved: every, boundShortcuts: []) == nil)
    }

    @Test func launcherShortcutChoicesThatMacOSReservesAreRefused() {
        let model = model()
        defer { model.stop() }
        let reserved = CommandShortcutPolicy.systemReservedShortcuts()
        for value in LauncherHotKey.allCases {
            let before = model.store.database.preferences.hotKey
            let saved = model.setLauncherHotKey(value)
            #expect(saved == !reserved.contains(value.shortcut))
            #expect(model.store.database.preferences.hotKey == (saved ? value : before))
            #expect((model.launcherHotKeyRefusal == nil) == saved)
            // A refused choice says why without marking the working shortcut inactive.
            #expect(model.shortcutError == nil)
        }
    }

    // MARK: Actions

    @Test func argumentRowsCopyTheirResolvedLinkAndCannotBeFavoritedOrDeleted() throws {
        let model = model()
        defer { model.stop() }
        model.query = "web "
        let link = try #require(model.argumentLink)
        model.query = "swift testing"
        model.files.stop()
        let row = try #require(model.selectedItem)
        #expect(row.id == "argument.\(link.id)")
        #expect(!row.canFavorite && !row.canDelete)
        #expect(model.secondaryTitle(for: row) == nil)
        #expect(model.aliasChip(for: row) == nil)
        let ids = model.actions(for: row).map(\.id)
        #expect(!ids.contains("favorite") && !ids.contains("delete"))
        let resolved = try link.resolvedURL(query: "swift testing").absoluteString
        model.actions(for: row).first { $0.id == "copyLink" }?.perform()
        #expect(model.clipboard.readText() == resolved)
        // Retargets keep their keyword chip and take ⌘2 onward.
        let retarget = try #require(model.orderedResults.dropFirst().first)
        #expect(model.aliasChip(for: retarget) == "gh")
        #expect(model.numberShortcut(for: retarget) == 2)
        #expect(model.numberShortcut(for: row) == nil)
    }

    @Test func snapshottedPasteActsOnTheItemItWasOpenedFor() throws {
        let model = model()
        defer { model.stop() }
        let alpha = Snippet(name: "Alpha", keyword: "", content: "First body")
        #expect(model.store.save(alpha))
        #expect(model.store.save(Snippet(name: "Beta", keyword: "", content: "Second body")))
        model.navigate(to: .snippets)
        model.selectedID = "snippet.\(alpha.id)"
        model.showActions = true
        let paste = try #require(model.actionEntries.first { $0.id == "paste" })
        model.showActions = false
        model.query = "Beta"
        model.performAction(paste)
        #expect(model.clipboard.readText() == "First body")
        model.files.stop()
    }

    @Test func editingAnotherItemAsksBeforeDroppingADirtyDraft() throws {
        let model = model()
        defer { model.stop() }
        let alpha = Snippet(name: "Alpha", keyword: "", content: "First body")
        let beta = Snippet(name: "Beta", keyword: "", content: "Second body")
        #expect(model.store.save(alpha))
        #expect(model.store.save(beta))
        model.navigate(to: .snippets)
        let items = model.orderedResults
        let alphaItem = try #require(items.first { $0.id == "snippet.\(alpha.id)" })
        let betaItem = try #require(items.first { $0.id == "snippet.\(beta.id)" })
        model.edit(alphaItem)
        model.draft?.content = "Changed"
        model.edit(betaItem)
        #expect(model.editor?.id == "snippet.\(alpha.id)")
        #expect(model.confirmation?.id == "discard")
        model.files.stop()
    }

    @Test func failedLibraryWritesReportErrorsInsteadOfSuccessToasts() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayReadOnly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "library.json")
        try Data("damaged metadata".utf8).write(to: url)
        let model = LauncherModel(
            store: LibraryStore(fileURL: url), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        #expect(model.store.isReadOnly)
        model.navigate(to: .quicklinks)
        let item = try #require(model.selectedItem)
        model.toggleFavorite(item)
        #expect(model.feedback?.style == .error)
        model.requestDelete(item)
        model.confirm(try #require(model.confirmation))
        #expect(model.feedback?.style == .error)
        #expect(model.orderedResults.contains { $0.id == item.id })
        model.navigate(to: .clipboard)
        #expect(model.showsClipboardOptIn)
        model.performSelected()
        #expect(model.feedback?.style == .error)
        model.files.stop()
    }

    @Test func pausedCaptureIsRememberedWithoutHistory() {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .clipboard)
        #expect(model.showsClipboardOptIn)
        model.performSelected()
        #expect(model.store.database.preferences.clipboardEnabled)
        model.setClipboardCapture(false)
        #expect(model.store.database.clipboardIsPaused)
        #expect(!model.showsClipboardOptIn)
        #expect(model.feedback?.text == "Capture paused")
        model.showActions = true
        #expect(model.actionEntries.contains { $0.id == "capture" && $0.title == "Resume Capture" })
        model.showActions = false
        model.files.stop()
    }

    @Test func theFirstRunSwitchTurnsCaptureOffNotPaused() {
        let model = model()
        defer { model.stop() }
        model.enableClipboardHistory()
        #expect(model.store.database.preferences.clipboardEnabled)
        model.turnOffClipboardHistory()
        #expect(!model.store.database.preferences.clipboardEnabled)
        #expect(!model.store.database.clipboardIsPaused)
        model.navigate(to: .clipboard)
        #expect(model.showsClipboardOptIn)
        model.files.stop()
    }

    @Test func deleteAllNamesThePinnedEntriesItRemoves() {
        let detail = { (pinned: Int) in ActionConfirmation.clearClipboardHistory(pinnedCount: pinned).detail }
        #expect(detail(2).hasPrefix("This also deletes 2 pinned entries."))
        #expect(detail(1).hasPrefix("This also deletes 1 pinned entry."))
        #expect(detail(0) == "Your current clipboard stays as it is.")
    }

    @Test func conversionsOfferUnitAndRelatedCopiesButPlainMathDoesNot() throws {
        let model = model()
        defer { model.stop() }
        model.query = "10 km in mi"
        model.files.stop()
        let conversion = try #require(model.selectedItem)
        let ids = model.actions(for: conversion).map(\.id)
        #expect(ids.contains("copyUnit") && ids.contains("copyExpression"))
        #expect(ids.contains("copyRelated.ft"))
        model.query = "6 * 7"
        model.files.stop()
        let math = try #require(model.selectedItem)
        let mathIDs = model.actions(for: math).map(\.id)
        #expect(!mathIDs.contains("copyUnit") && mathIDs.contains("copyExpression"))
        model.files.stop()
    }

    // MARK: Rows

    @Test func windowLayoutsFollowTheSpecGridOrder() {
        let model = model()
        defer { model.stop() }
        #expect(
            model.windowItems.map(\.id) == [
                "window.leftHalf", "window.rightHalf", "window.topHalf", "window.bottomHalf", "window.topLeft",
                "window.topRight", "window.bottomLeft", "window.bottomRight", "window.maximize", "window.center",
                "window.nextDisplay", "window.restore",
            ])
    }

    @Test func notesAndSnippetsFoundByTheirTextSayWhy() {
        let model = model()
        defer { model.stop() }
        #expect(model.store.save(QuickNote(title: "Groceries", content: "Groceries\nmilk\nAsk Sam about the invoice")))
        #expect(model.store.save(Snippet(name: "Signature", keyword: ";sig", content: "Best regards,\nAli")))
        model.query = "invoice"
        model.files.stop()
        #expect(model.results.first { $0.id.hasPrefix("note.") }?.subtitle == "Ask Sam about the invoice")
        model.query = ";sig"
        model.files.stop()
        #expect(model.results.first { $0.id.hasPrefix("snippet.") }?.subtitle == "Keyword match · Best regards,")
        let long = String(repeating: "lorem ", count: 30) + "needle" + String(repeating: " ipsum", count: 30)
        let excerpt = LauncherModel.matchingExcerpt(of: long, query: "needle")
        #expect(excerpt?.contains("needle") == true)
        #expect(excerpt?.hasPrefix("…") == true && excerpt?.hasSuffix("…") == true)
        model.files.stop()
    }

    @Test func quicklinksNameTheAppTheyOpenIn() {
        let model = model()
        defer { model.stop() }
        #expect(model.openerName(for: Quicklink(name: "Home", template: "~/", keyword: "")) == "Finder")
        #expect(
            model.openerName(for: Quicklink(name: "Apple", template: "https://www.apple.com", keyword: ""))
                == model.defaultBrowserName)
        #expect(
            model.openerName(for: Quicklink(name: "Search", template: "https://duckduckgo.com/?q={query}", keyword: ""))
                == model.defaultBrowserName)
        // A {query} link that isn't a web link names the app that handles it, not the browser.
        #expect(
            model.openerName(for: Quicklink(name: "Email", template: "mailto:{query}", keyword: ""))
                == model.defaultAppName(for: URL(string: "mailto:x")!))
    }

    // MARK: AI

    @Test func emptyActionItemsOfferNothingToPasteOrSave() async {
        let engine = TestAIEngine()
        engine.snapshots = ["No action items found."]
        let model = model(engine: engine)
        defer { model.stop() }
        model.openAI(.actionItems, attachment: AIAttachment(source: .clipboard, text: "The room is bright."))
        await model.ai.waitForResponse()
        #expect(model.aiResultIsUnchanged)
        var ids = model.actions(for: nil).map(\.id)
        #expect(!ids.contains("accept") && !ids.contains("secondary") && !ids.contains("note"))
        engine.snapshots = ["- Lee: Book the room"]
        model.ai.retry()
        await model.ai.waitForResponse()
        #expect(!model.aiResultIsUnchanged)
        ids = model.actions(for: nil).map(\.id)
        #expect(ids.contains("accept") && ids.contains("secondary") && ids.contains("note"))
    }

    @Test func writingResultsSwitchViewsInCommandKAndContinueInChatCarriesTheResult() async throws {
        let engine = TestAIEngine()
        engine.snapshots = ["They were late."]
        let model = model(engine: engine)
        defer { model.stop() }
        model.openAI(.proofread, attachment: AIAttachment(source: .clipboard, text: "They was late."))
        await model.ai.waitForResponse()
        // Fix Spelling & Grammar opens on its marked changes; the other views are in ⌘K.
        #expect(model.ai.diffMode == .changes)
        let entries = model.actions(for: nil)
        let views = entries.filter { $0.id.hasPrefix("view.") }
        #expect(views.map(\.title) == ["Show Response", "Show Changes", "Show Original"])
        #expect(views.allSatisfy { $0.key == nil })
        views.first { $0.title == "Show Original" }?.perform()
        #expect(model.ai.diffMode == .original)
        views.first { $0.title == "Show Response" }?.perform()
        #expect(model.ai.diffMode == .result)
        let chat = try #require(model.actions(for: nil).first { $0.id == "chat" })
        chat.perform()
        #expect(model.ai.action == .chat)
        #expect(model.ai.attachments.map(\.source) == [.response])
        #expect(model.ai.attachments.first?.text == "They were late.")
    }

    @Test func savingAReplyAsANoteSavesItAtOnceUnderItsQuestion() async {
        let model = model()
        defer { model.stop() }
        model.openAI(.chat)
        model.ai.draft = "Plan the launch"
        model.ai.send()
        await model.ai.waitForResponse()
        model.ai.draft = "Now the follow-up"
        model.ai.send()
        await model.ai.waitForResponse()
        let first = model.ai.messages[1]
        model.saveResponseAsNote(first)
        #expect(model.draft?.savedAt != nil)
        #expect(model.store.database.notes.contains { $0.title == "Plan the launch" && $0.content == first.text })
        model.saveResponseAsNote()
        #expect(model.store.database.notes.contains { $0.title == "Now the follow-up" })
    }

    @Test func aReplyAboutAnAttachmentAloneIsNotTitledByThePromptMarkup() async {
        let model = model()
        defer { model.stop() }
        model.openAI(.chat, attachment: AIAttachment(source: .clipboard, text: "Quarterly numbers"))
        model.ai.send()
        await model.ai.waitForResponse()
        model.saveResponseAsNote()
        #expect(model.store.database.notes.contains { $0.title == "AI response" })
        #expect(!model.store.database.notes.contains { $0.title.contains("<attachment") })
    }
}
