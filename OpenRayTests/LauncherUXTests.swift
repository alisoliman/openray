import AppKit
import SwiftUI
import Testing

@testable import OpenRay

@MainActor
struct LauncherUXTests {
    private func model() -> LauncherModel {
        LauncherModel(store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()))
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

    @Test func nativeMenuExecutesTheActionPresentedWhenItOpened() {
        var performed: [String] = []
        let presenter = NativeActionsMenu(
            isPresented: .constant(true), title: "A note",
            entries: [
                .init(title: "Open Note", symbol: "note") { performed.append("open") },
                .init(title: "Copy", symbol: "doc.on.doc") { performed.append("copy") },
            ], didClose: {})
        let coordinator = presenter.makeCoordinator()
        let menu = coordinator.makeMenu()
        #expect(menu.items.filter { !$0.isHidden }.map(\.title) == ["A note", "", "Open Note", "Copy"])
        #expect(menu.items.last?.keyEquivalent == "k")
        #expect(menu.items.last?.allowsKeyEquivalentWhenHidden == true)
        #expect(menu.items.first?.isEnabled == false)
        coordinator.parent.entries = [.init(title: "Different result", symbol: "app") { performed.append("wrong") }]
        menu.performActionForItem(at: 3)
        #expect(performed == ["copy"])
    }
}
