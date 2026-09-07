import AppKit
import SwiftUI
import Testing

@testable import OpenRay

@MainActor
struct SettingsWindowTests {
    @Test func panelRoutesUnclaimedEscapeToSettingsAndRestoresSearchFocusRequest() throws {
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
        let panel = LauncherPanel()
        panel.escapeAction = {
            guard model.destination == .settings, model.editor == nil else { return false }
            model.goBack()
            return true
        }
        model.openSettings()
        let previousFocusRequest = model.focusRequest
        #expect(panel.handleEscapeKey(try keyEvent(code: 53)))
        #expect(model.destination == .search)
        #expect(model.section == .home)
        #expect(model.focusRequest > previousFocusRequest)
        #expect(!panel.handleEscapeKey(try keyEvent(code: 53)))
        model.files.stop()
    }

    @Test func panelLeavesTextEditingAndModifiedEscapeToNativeResponders() throws {
        let panel = LauncherPanel()
        var navigations = 0
        panel.escapeAction = {
            navigations += 1
            return true
        }
        #expect(!panel.handleEscapeKey(try keyEvent(code: 53, modifiers: .command)))
        #expect(!panel.handleEscapeKey(try keyEvent(code: 125)))
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        panel.contentView = editor
        #expect(panel.makeFirstResponder(editor))
        #expect(!panel.handleEscapeKey(try keyEvent(code: 53)))
        #expect(navigations == 0)
    }

    @Test func sharedAppearancePolicySupportsBothExplicitModesAndSystemFallback() {
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
        #expect(AppAppearance.system.colorScheme == nil)
    }

    private func keyEvent(code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
    }
}
