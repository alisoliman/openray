import AppKit
import Testing

@testable import OpenRay

/// A provider whose live search builds an ordinary row for its destructive command, then waits
/// until the test lets it finish, as a slow search would.
@MainActor
final class SuspendedLiveProvider: CommandProvider {
    let id = "test.suspended"
    var withdrawn = false
    var performed: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { gate != nil }
    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        guard !withdrawn else { return [] }
        var confirmation = CommandConfirmation(question: "Empty the Trash?", detail: "", confirmTitle: "Empty")
        confirmation.isDestructive = true
        return [
            CommandDescriptor(
                id: "test.suspended.empty", title: "Numbat Empty Trash", subtitle: "", kind: .command, symbol: "trash",
                mode: .noView, confirmation: confirmation)
        ]
    }

    var providesLiveItems: Bool { true }

    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] {
        let row = LauncherItem(
            id: "test.suspended.row", title: "Numbat Empty Trash Now", subtitle: "", symbol: "trash", badge: "Live",
            action: .provided(ProvidedRef(provider: id, id: "test.suspended.empty")))
        await withCheckedContinuation { gate = $0 }
        return [row]
    }

    func finish() {
        gate?.resume()
        gate = nil
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) { performed.append(ref.id) }
}

@MainActor
struct LauncherFollowupTests {
    private func model(_ providers: [any CommandProvider]? = nil) -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: providers.map { CommandRegistry(providers: $0) } ?? CommandRegistry())
    }

    // MARK: (b) The press must come after presentation

    @Test func aReturnPressedBeforeThePromptWasPresentedNeverAnswersIt() throws {
        let fake = FakeCommandProvider()
        fake.confirmDestructive = true
        let model = model([fake])
        defer { model.stop() }
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        model.promptClock = { now }
        let revealed = now
        model.confirmationSurfaceVisibleSince = { revealed }
        let command = try #require(model.commandItems.first { $0.id == "test.confirm" })
        model.perform(command)
        let instance = try #require(model.confirmationInstanceID)
        // Pressed as the prompt appeared, before its fade-in finished.
        let early = now
        now += 0.12
        model.confirmationDidAppear(instance)
        let presented = now
        // Handled long after: the press's own time still says it came too early.
        now += 5
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: early))
        #expect(fake.performed.isEmpty)
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: presented.addingTimeInterval(0.1)))
        #expect(fake.performed.isEmpty)
        #expect(model.confirmFromReturn(
            isRepeat: false, pressedAt: presented.addingTimeInterval(LauncherModel.minimumPromptExposure)))
        #expect(fake.performed == ["test.confirm"])
    }

    @Test func aPanelThatHasntFinishedRevealingCountsFromItsEnd() throws {
        let fake = FakeCommandProvider()
        fake.confirmDestructive = true
        let model = model([fake])
        defer { model.stop() }
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        model.promptClock = { now }
        var revealed: Date?
        model.confirmationSurfaceVisibleSince = { revealed }
        let command = try #require(model.commandItems.first { $0.id == "test.confirm" })
        model.perform(command)
        model.confirmationDidAppear(try #require(model.confirmationInstanceID))
        // Drawn in a panel still revealing: nothing counts yet.
        now += 2
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: now))
        #expect(fake.performed.isEmpty)
        // The reveal finishes now; a press must follow it.
        revealed = now
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: now.addingTimeInterval(-1)))
        #expect(fake.performed.isEmpty)
        now += LauncherModel.minimumPromptExposure
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: now))
        #expect(fake.performed == ["test.confirm"])
    }

    @Test func eventTimestampsMapOntoThePromptClock() {
        let model = model()
        defer { model.stop() }
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        model.promptClock = { now }
        let twoSecondsAgo = model.promptDate(forEventTimestamp: ProcessInfo.processInfo.systemUptime - 2)
        #expect(abs(now.timeIntervalSince(twoSecondsAgo) - 2) < 0.5)
    }

    // MARK: (a) A field's submit is no key evidence

    @Test func aFieldsSubmitNeverAnswersAPromptInTheApp() throws {
        let fake = FakeCommandProvider()
        let model = model([fake])
        defer { model.stop() }
        #expect(!model.currentKeyPressIsFresh())
        let command = try #require(model.commandItems.first { $0.id == "test.confirm" })
        model.perform(command)
        // Not destructive, yet a submit (insertNewline:, an accessibility action) still doesn't answer.
        model.performSelected()
        #expect(fake.performed.isEmpty)
        #expect(model.confirmation != nil)
        // The panel's own fresh Return does.
        #expect(model.confirmFromReturn(isRepeat: false, pressedAt: model.promptClock()))
        #expect(fake.performed == ["test.confirm"])
    }

    // MARK: (c) Identity across the live search's await

    @Test func aCommandWithdrawnDuringALiveSearchNeverArrivesAsAPlainRow() async throws {
        let provider = SuspendedLiveProvider()
        let model = model([provider])
        defer { model.stop() }
        model.query = "numbat"
        for _ in 0..<200 where !provider.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(provider.isWaiting)
        // Withdrawn, and announced, while the search is suspended with its row already built.
        provider.withdrawn = true
        model.commandCatalogDidChange()
        provider.finish()
        for _ in 0..<200 where model.isLoadingProvidedItems { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.providedLiveItems[provider.id]?.isEmpty ?? true)
        #expect(!model.results.contains { $0.id == "test.suspended.row" })
        #expect(provider.performed.isEmpty)
    }

    @Test func aLateRowForAStillPresentCommandIsMarkedAndAsksFirst() async throws {
        let provider = SuspendedLiveProvider()
        let model = model([provider])
        defer { model.stop() }
        model.query = "numbat"
        for _ in 0..<200 where !provider.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        provider.finish()
        for _ in 0..<200 where model.isLoadingProvidedItems { try await Task.sleep(for: .milliseconds(5)) }
        let row = try #require(model.providedLiveItems[provider.id]?.first)
        guard case .provided(let ref) = row.action else {
            Issue.record("Expected a provided row")
            return
        }
        #expect(ref.has(.descriptor))
        model.perform(row)
        #expect(model.confirmation?.requiresVisibleApproval == true)
        #expect(provider.performed.isEmpty)
        // Withdrawn later without an announcement: the marked row is refused.
        model.confirmation = nil
        provider.withdrawn = true
        model.perform(row)
        #expect(provider.performed.isEmpty)
        #expect(model.confirmation == nil)
    }

    // MARK: Blank Home's cap

    @Test func favoritesAndPinnedRowsSurviveTheBlankHomeCap() {
        let commands = (0..<80).map { index in
            LauncherItem(id: "command.\(index)", title: "Command \(index)", subtitle: "", symbol: "bolt", badge: "Command",
                action: .settings)
        }
        let favorite = LauncherItem(id: "favorite.row", title: "Favorite", subtitle: "", symbol: "star", badge: "", action: .settings)
        let capped = LauncherModel.capped(commands + [favorite], in: .home, keeping: [favorite.id])
        #expect(capped.contains { $0.id == favorite.id })
        #expect(capped.count == 46)
        // Without the exemption the cap still holds at 45, in order.
        #expect(LauncherModel.capped(commands + [favorite], in: .home).map(\.id) == commands.prefix(45).map(\.id))
    }

    @Test func blankHomeKeepsFavoritesAndPinnedEntriesHoweverManyCommandsComeFirst() {
        let model = model()
        defer { model.stop() }
        var pinned = ClipboardEntry(text: "Pinned text", sourceName: "Test")
        pinned.isPinned = true
        let favorite = ClipboardEntry(text: "Favorite text", sourceName: "Test")
        model.store.update {
            $0.preferences.clipboardEnabled = true
            $0.preferences.clipboardInRootSearch = true
            $0.clipboard = [favorite, pinned]
                + (0..<60).map { ClipboardEntry(text: "Filler \($0)", sourceName: "Test") }
        }
        model.store.toggleFavorite("clipboard.\(favorite.id)")
        let ids = Set(model.results.map(\.id))
        #expect(ids.contains("clipboard.\(favorite.id)"))
        #expect(ids.contains("clipboard.\(pinned.id)"))
        // Every other row is still capped.
        let exempt = model.store.database.favoriteIDs.union(["clipboard.\(pinned.id)"])
        #expect(model.results.filter { !$0.isLiveResult && !exempt.contains($0.id) }.count == 45)
    }
}
