import AppKit
import SwiftUI
import Testing

@testable import OpenRay

@MainActor
struct NativeInputTests {
    @Test(arguments: [false, true]) func navigationClearsTheNativeEditorBeforeTheNextKeystroke(submitting: Bool) {
        var query = "previous query"
        let input = LauncherSearchInput(
            text: Binding(get: { query }, set: { query = $0 }), placeholder: "Search", focusRequest: 0,
            submit: { query = "" }, move: { _ in }, cancel: { query = "" }, paste: {})
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        coordinator.attach(to: field)
        field.stringValue = query
        let editor = NSTextView()
        editor.string = query
        let command = submitting ? #selector(NSResponder.insertNewline(_:)) : #selector(NSResponder.cancelOperation(_:))
        #expect(coordinator.control(field, textView: editor, doCommandBy: command))
        #expect(query.isEmpty)
        #expect(field.stringValue.isEmpty)
        #expect(editor.string.isEmpty)
    }

    @Test func emptySearchHasANativeReturnActionWithoutRequiringTextEditing() {
        var submissions = 0
        let input = LauncherSearchInput(
            text: .constant(""), placeholder: "Search", focusRequest: 0,
            submit: { submissions += 1 }, move: { _ in }, cancel: {}, paste: {})
        let coordinator = input.makeCoordinator()
        let field = FocusedSearchField()
        coordinator.attach(to: field)
        field.stringValue = "a previous search"
        field.stringValue = ""
        #expect(field.action != nil)
        #expect(field.target === coordinator)
        #expect(field.cell?.sendsActionOnEndEditing == false)
        #expect(!field.isContinuous)
        #expect(field.sendAction(field.action, to: field.target))
        #expect(submissions == 1)
    }
}
