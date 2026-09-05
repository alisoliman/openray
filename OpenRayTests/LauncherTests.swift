import Foundation
import Testing

@testable import OpenRay

@MainActor
struct LauncherTests {
    private func makeModel() -> LauncherModel {
        LauncherModel(store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()))
    }

    @Test func rootExposesEveryCoreFeatureAndSettings() {
        let model = makeModel()
        for section in LauncherSection.allCases where section != .home {
            model.query = section.title
            #expect(model.results.contains { $0.id == "section.\(section.id)" })
        }
        model.query = "settings"
        #expect(model.results.contains { $0.id == "settings" })
        model.query = "summarize"
        #expect(model.results.contains { $0.id == "ai.summarize" })
        model.files.stop()
    }

    @Test func calculatorAndQuicklinkArgumentsAppearInRoot() {
        let model = makeModel()
        model.query = "6 * 7"
        #expect(model.results.first?.id == "calculation")
        #expect(model.results.first?.copyText == "42")
        model.query = "web swift concurrency"
        if case .quicklink(_, let argument) = model.results.first?.action {
            #expect(argument == "swift concurrency")
        } else {
            Issue.record("Expected a parameterized quicklink as the first result")
        }
        model.files.stop()
    }

    @Test func keyboardSelectionWrapsAndEmptyResultsAreSafe() {
        let model = makeModel()
        model.synchronizeSelection()
        let first = model.selectedID
        model.moveSelection(-1)
        #expect(model.selectedID == model.orderedResults.last?.id)
        model.moveSelection(1)
        #expect(model.selectedID == first)
        model.query = "zzzzzzzzzzzzzzzz"
        model.synchronizeSelection()
        model.moveSelection(1)
        model.performSelected()
        #expect(model.selectedID == nil)
        model.files.stop()
    }

    @Test func committingUnchangedQueryKeepsKeyboardSelection() {
        let model = makeModel()
        model.synchronizeSelection()
        model.moveSelection(1)
        let selected = model.selectedID
        let committedText = model.query
        model.query = committedText
        #expect(model.selectedID == selected)
        model.performSelected()
        #expect(model.section == .clipboard)
    }

    @Test func editingAndDeletionStayInLocalLibrary() {
        let model = makeModel()
        let snippet = Snippet(name: "Test", keyword: ";test", content: "Fixture")
        #expect(model.store.save(snippet))
        model.navigate(to: .snippets)
        let item = model.results.first
        #expect(item?.title == "Test")
        model.editSelected()
        #expect(model.editor?.id == "snippet.\(snippet.id)")
        if let item { model.delete(item) }
        #expect(model.store.database.snippets.isEmpty)
    }

    @Test func pinnedFilesAndClipboardEntriesRemainInRootWithoutLiveSearchResults() {
        let model = makeModel()
        model.store.update {
            $0.preferences.clipboardEnabled = true
            $0.clipboard = [ClipboardEntry(text: "Pinned text", sourceName: "Test")]
        }
        let clipboardID = "clipboard.\(model.store.database.clipboard[0].id)"
        model.store.toggleFavorite(clipboardID)
        model.store.toggleFavorite("file./Users/example/Documents/note.txt")
        #expect(model.results.contains { $0.id == clipboardID })
        #expect(model.results.contains { $0.id == "file./Users/example/Documents/note.txt" })
        #expect(Set(model.results.map(\.id)).count == model.results.count)
        model.query = "zzzzzzzzzzzzzzzzz"
        #expect(model.results.isEmpty)
        model.files.stop()
    }

    @Test func escapeReturnsToRootThenClearsQuery() {
        let model = makeModel()
        model.navigate(to: .snippets)
        model.goBack()
        #expect(model.section == .home)
        model.query = "calculator"
        model.goBack()
        #expect(model.query.isEmpty)
    }

    @Test func applicationDiscoveryFindsRealMacApplicationsWithoutDuplicates() async {
        let catalog = ApplicationCatalog()
        await catalog.refresh()
        #expect(!catalog.isLoading)
        #expect(!catalog.applications.isEmpty)
        #expect(Set(catalog.applications.map(\.id)).count == catalog.applications.count)
        #expect(catalog.applications.allSatisfy { $0.url.pathExtension == "app" })
        #expect(catalog.applications.contains { $0.bundleIdentifier == "com.apple.finder" })
    }

    @Test func oversizedSearchDoesNotStartWork() {
        let model = makeModel()
        model.query = String(repeating: "a", count: 20_000)
        #expect(model.results.isEmpty)
        #expect(!model.files.isSearching)
        #expect(model.message?.contains("512") == true)
    }
}
