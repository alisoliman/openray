import AppKit
import Foundation
import Testing

@testable import OpenRay

/// The ⌘/ overlay lists only shortcuts that work in the current context.
@MainActor
struct ShortcutsOverlayTests {
    private func model() -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
    }

    private func keys(_ rows: [(String, [String])], for title: String) -> [String]? {
        rows.first { $0.0 == title }?.1
    }

    @Test func editorLeavesOutActionsAndTheShortcutsItTurnsOff() {
        let model = model()
        defer { model.stop() }
        model.editor = .note(QuickNote(title: "", content: ""))
        let overlay = ShortcutsOverlay(model: model, selected: nil)
        #expect(overlay.localRows.map { $0.0 } == ["Save", "Cancel or Done", "Next Field"])
        #expect(overlay.everywhereRows.map { $0.0 } == ["Settings"])
    }

    @Test func calculatorHasNoCommandKRowAndCantBeFavorited() {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .calculator)
        model.query = "2+2"
        let rows = ShortcutsOverlay(model: model, selected: model.selectedItem).localRows
        #expect(model.selectedItem?.id == "calculation")
        #expect(!rows.contains { $0.1 == ["⌘", "K"] })
        #expect(!rows.contains { $0.1 == ["⇧", "⌘", "F"] })
        #expect(keys(rows, for: "Ask AI") == ["Tab"])
    }

    @Test func favoriteRowNamesTheToggleInModifierOrder() throws {
        let model = model()
        defer { model.stop() }
        let favorite = try #require(model.favoriteItems.first)
        let overlay = ShortcutsOverlay(model: model, selected: favorite)
        #expect(keys(overlay.localRows, for: "Remove from Favorites") == ["⇧", "⌘", "F"])
        #expect(!ShortcutsOverlay(model: model, selected: nil).localRows.contains { $0.1 == ["⇧", "⌘", "F"] })

        model.navigate(to: .clipboard)
        // Before history is on, the opt-in's two choices are all that apply.
        #expect(ShortcutsOverlay(model: model, selected: nil).localRows.map(\.0) == ["Turn On", "Not Now"])
        #expect(model.actions(for: nil).map(\.id) == ["turnOn", "notNow", "shortcuts"])
        model.store.update { $0.preferences.clipboardEnabled = true }
        #expect(keys(ShortcutsOverlay(model: model, selected: nil).localRows, for: "Pin to Top") == ["⇧", "⌘", "P"])
        #expect(keys(ShortcutsOverlay(model: model, selected: nil).localRows, for: "Show Text") == ["⌘", "P"])
    }

    @Test func filesListQuickLook() {
        let model = model()
        defer { model.stop() }
        model.navigate(to: .files)
        model.files.stop()
        var rows = ShortcutsOverlay(model: model, selected: nil).localRows
        #expect(keys(rows, for: "Quick Look") == ["⌘", "Y"])
        #expect(keys(rows, for: "Reveal in Finder") == ["⇧", "⌘", "R"])
        // Tab does nothing in a scope with a blank query, so it isn't listed.
        #expect(keys(rows, for: "Ask AI") == nil)
        model.query = "report"
        model.files.stop()
        rows = ShortcutsOverlay(model: model, selected: nil).localRows
        #expect(keys(rows, for: "Ask AI") == ["Tab"])
    }

    @Test func aiShowsLeaveAIOnceAndTheRunKeysForTheAttachment() {
        let model = model()
        defer { model.stop() }
        model.openAI(.proofread)
        var overlay = ShortcutsOverlay(model: model, selected: nil)
        #expect(keys(overlay.everywhereRows, for: "Leave AI") == ["esc"])
        #expect(!overlay.everywhereRows.contains { $0.0 == "Clear Search" || $0.0 == "Leave Scope" })
        #expect(!overlay.localRows.contains { $0.0 == "Leave" })
        // Owner decision (main #12/#13 inside AI): ↩ runs, ⇧↩ and ⌘↩ add a line.
        #expect(keys(overlay.localRows, for: AIAction.proofread.runTitle) == ["↩"])
        #expect(overlay.localRows.filter { $0.0 == "New Line" }.map(\.1) == [["⇧", "↩"], ["⌘", "↩"]])

        // Nothing has run yet, so there's nothing to try again.
        #expect(keys(overlay.localRows, for: "Try Again") == nil)

        model.openAI(.proofread, attachment: AIAttachment(source: .clipboard, text: "Teh cat sat."))
        overlay = ShortcutsOverlay(model: model, selected: nil)
        #expect(keys(overlay.localRows, for: AIAction.proofread.runTitle) == ["↩"])
        #expect(keys(overlay.localRows, for: "New Line") == nil)
    }

    @Test func aStoppedWritingResultCanStillBeTriedAgain() async {
        let engine = TestAIEngine()
        engine.snapshots = ["The cat", "The cat sat."]
        engine.delay = .milliseconds(200)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: engine),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        model.openAI(.proofread, attachment: AIAttachment(source: .clipboard, text: "Teh cat sat."))
        model.ai.send()
        var spins = 0
        while model.ai.messages.last?.text.isEmpty != false, spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        // While it runs, the overlay lists only what works: Stop.
        #expect(ShortcutsOverlay(model: model, selected: nil).localRows.map(\.0) == ["Stop"])
        model.ai.cancel()
        await model.ai.waitForResponse()
        #expect(model.ai.latestResponse == nil)
        // ⌘R is bound through the AI's action entries.
        #expect(ActionShortcutButtons.entries(for: model, selected: nil).contains { $0.id == "retry" })
        #expect(keys(ShortcutsOverlay(model: model, selected: nil).localRows, for: "Try Again") == ["⌘", "R"])
    }

    @Test func hiddenShortcutButtonsBindNothingWhileActionsOrAConfirmationAreOpen() throws {
        let model = model()
        defer { model.stop() }
        let favorite = try #require(model.favoriteItems.first)
        #expect(!ActionShortcutButtons.entries(for: model, selected: favorite).isEmpty)
        model.showActions = true
        #expect(ActionShortcutButtons.entries(for: model, selected: favorite).isEmpty)
        model.showActions = false
        model.confirmation = .clearClipboardHistory(pinnedCount: 0)
        #expect(ActionShortcutButtons.entries(for: model, selected: favorite).isEmpty)
    }
}
