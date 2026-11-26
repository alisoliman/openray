import AppKit
import Testing

@testable import OpenRay

/// Phase B: system and window commands through the registry, with fake executors, windows,
/// sound devices, menus and HUD. Nothing here touches the real system.
@MainActor
struct SystemWindowProviderTests {
    /// The app OpenRay was opened over. Its windows are the fixture's default pid 100.
    static let notes = AppIdentity(pid: 100, bundleIdentifier: "com.example.notes", name: "Notes", launchDate: nil)

    static let menuBar = MenuSpec.bar([
        .menu("Apple", [.item("About This Mac")]),
        .menu(
            "File",
            [
                .item("New Note", character: "n"),
                .item("Export", submenu: [.item("PDF", character: "e", modifiers: MenuShortcutFormatter.shift)]),
                .item("Print", character: "p", enabled: false),
            ]),
    ])

    struct Harness {
        let model: LauncherModel
        let system: FakeWindowSystem
        let windows: WindowCommandProvider
        let systemCommands: SystemCommandProvider
        let actions: RecordingSystemActions
        let presenter: FakeHUDPresenter
        let audio: FakeAudioDevices
        let menus: FakeMenuTree
        let launcher: FakeApplicationLauncher

        @MainActor var hudTexts: [String] { presenter.presented.map { $0.message.text } }
    }

    private func harness(
        windows: [WindowSnapshot] = [
            WindowFixture.window(pid: 100, token: 1, title: "Groceries"),
            WindowFixture.window(
                pid: 200, token: 2, app: "Mail", bundle: "com.example.mail", title: "Inbox",
                frame: CGRect(x: 720, y: 76, width: 720, height: 800)),
        ],
        foreground: AppIdentity? = notes, store: LibraryStore = LibraryStore(fileURL: nil), hotKey: GlobalHotKey? = nil
    ) -> Harness {
        let system = FakeWindowSystem(displays: [WindowFixture.laptop], windows: windows)
        let listing = FakeWindowServerListing(WindowFixture.entries(for: windows.filter { !$0.isMinimized }))
        let presenter = FakeHUDPresenter()
        let hud = HUDController(presenter: presenter, screenFrame: { WindowFixture.laptop.visibleFrame }, schedule: { _, _ in })
        let launcher = FakeApplicationLauncher()
        let windowsProvider = WindowCommandProvider(
            windows: WindowManager(system: system, listing: listing), launcher: launcher, hud: hud,
            foregroundPID: { _ in foreground?.pid })
        let actions = RecordingSystemActions()
        let audio = FakeAudioDevices()
        let menus = FakeMenuTree(bars: [100: Self.menuBar])
        let systemProvider = SystemCommandProvider(
            executor: actions, audio: audio, menuSearch: MenuItemSearch(source: menus), hud: hud,
            foreground: { _ in foreground })
        let model = LauncherModel(
            store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: [AIWritingCommandProvider(), systemProvider, windowsProvider]),
            hotKey: hotKey)
        return Harness(
            model: model, system: system, windows: windowsProvider, systemCommands: systemProvider, actions: actions,
            presenter: presenter, audio: audio, menus: menus, launcher: launcher)
    }

    private func command(_ id: String, in model: LauncherModel) throws -> LauncherItem {
        try #require(model.commandItems.first { $0.id == id })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: One route per id

    @Test func everyCommandIDHasExactlyOneRoute() {
        // The app's real registry, with the test host's inert services.
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName())
        defer { model.stop() }
        let ids = model.commandItems.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ["window.leftHalf", "window.rightHalf", "window.maximize", "window.center", "window.restore"] {
            #expect(ids.filter { $0 == id }.count == 1, "\(id)")
            guard case .provided(let ref) = model.commandItems.first(where: { $0.id == id })?.action else {
                Issue.record("\(id) isn't served by a provider")
                continue
            }
            #expect(ref.provider == WindowCommandProvider.providerID)
        }
        for command in WindowCommand.allCases { #expect(ids.contains(WindowCommandProvider.commandID(command))) }
        for command in SystemCommand.all { #expect(ids.contains(command.id.itemID)) }
        // One catalog: the original twenty first, then everything else once.
        let bindable = model.bindableCommands.map(\.id)
        #expect(Set(bindable).count == bindable.count)
        #expect(Array(bindable.prefix(CuratedCommand.targetIDs.count)) == CuratedCommand.targetIDs)
        #expect(bindable.contains("window.firstThird") && bindable.contains("system.lockScreen"))
        #expect(LiveSystemActions.instanceCount == 0)
    }

    @Test func theWindowsGridKeepsItsTwelveTilesThroughTheProvider() throws {
        let h = harness()
        defer { h.model.stop() }
        h.model.navigate(to: .windows)
        let group = try #require(h.model.groups.first)
        #expect(group.style == .grid && group.tile == nil)
        #expect(
            group.items.map(\.id) == [
                "window.leftHalf", "window.rightHalf", "window.topHalf", "window.bottomHalf", "window.topLeft",
                "window.topRight", "window.bottomLeft", "window.bottomRight", "window.maximize", "window.center",
                "window.nextDisplay", "window.restore",
            ])
        #expect(group.items.map { WindowCommandProvider.gridLayout(for: $0) } == WindowCommandProvider.gridLayouts)
        #expect(group.items.first?.title == "Left Half" && group.items[4].title == "Top Left")
    }

    // MARK: Windows

    @Test func windowCommandsMoveTheForegroundWindowWithTheOriginalGeometry() throws {
        let h = harness()
        defer { h.model.stop() }
        h.model.perform(try command("window.leftHalf", in: h.model))
        #expect(h.system.events == [.setFrame(1, CGRect(x: 0, y: 76, width: 720, height: 800)), .focus(1)])
        #expect(h.model.store.database.usage.first?.id == "window.leftHalf")
        #expect(h.model.feedback == nil)
        // New commands too, through the same route.
        h.model.perform(try command("window.lastThird", in: h.model))
        #expect(h.system.frames.last == CGRect(x: 960, y: 76, width: 480, height: 800))
    }

    @Test func aWindowChosenWithTheTargetChipWins() throws {
        let element = AXUIElementCreateApplication(9_999)
        let chosen = WindowSnapshot(
            handle: WindowHandle(pid: 9_999, element: element), appName: "Docs", bundleIdentifier: "com.example.docs",
            bundleURL: nil, title: "Plan", frame: CGRect(x: 300, y: 300, width: 500, height: 400), isMinimized: false)
        let h = harness(windows: [WindowFixture.window(pid: 100, token: 1), chosen])
        defer { h.model.stop() }
        h.model.targetWindow = WindowManager.TargetWindow(
            pid: 9_999, appName: "Docs", bundleURL: nil, element: element, title: "Plan")
        h.model.perform(try command("window.rightHalf", in: h.model))
        #expect(h.system.frames == [CGRect(x: 720, y: 76, width: 720, height: 800)])
        #expect(h.system.windowList[0].frame == CGRect(x: 100, y: 200, width: 600, height: 400))
    }

    @Test func gapsAndCyclingFromSettingsApply() throws {
        let h = harness()
        defer { h.model.stop() }
        #expect(h.model.store.update {
            $0.windowManagementSettings = WindowManagementSettings(gaps: WindowGaps(uniform: 10), cyclesHalves: true)
        })
        h.model.perform(try command("window.maximize", in: h.model))
        #expect(h.system.frames.last == CGRect(x: 10, y: 86, width: 1420, height: 780))
        h.model.perform(try command("window.leftHalf", in: h.model))
        h.model.perform(try command("window.leftHalf", in: h.model))
        #expect(h.system.frames.suffix(2).map(\.minX) == [10, 10])
        #expect(h.system.frames.last.map { abs($0.width - (1420 * 2 / 3 - 5)) <= 1 } == true)
    }

    @Test func withoutAccessibilityWindowCommandsAskForItAndMoveNothing() throws {
        let h = harness()
        defer { h.model.stop() }
        h.system.isTrusted = false
        h.model.perform(try command("window.center", in: h.model))
        #expect(h.system.trustRequests == 1)
        #expect(h.model.feedback?.style == .info)
        #expect(h.system.events.isEmpty)
    }

    @Test func noViewCommandsRunFromHotkeysWithoutThePanel() throws {
        let h = harness()
        defer { h.model.stop() }
        #expect(h.model.runsWithoutPanel(try command("window.firstThird", in: h.model)))
        #expect(h.model.runsWithoutPanel(try command("system.lockScreen", in: h.model)))
        #expect(!h.model.runsWithoutPanel(try command("system.setVolume", in: h.model)))
        #expect(!h.model.runsWithoutPanel(try command("window.switch", in: h.model)))
    }

    @Test func exactResizeAndMoveTakeTypedValuesInTheirOwnLists() async throws {
        let h = harness()
        defer { h.model.stop() }
        h.model.perform(try command("window.resizeWindow", in: h.model))
        #expect(h.model.section == .provided(WindowCommandProvider.resizeScope))
        #expect(h.model.results.isEmpty)
        h.model.query = "1200 × 700"
        let resize = try #require(h.model.results.first)
        #expect(resize.title == "Resize to 1200 × 700")
        h.model.perform(resize)
        #expect(h.system.frames == [CGRect(x: 100, y: -100, width: 1200, height: 700)])
        // Too big for the display: said in the panel, nothing moves.
        h.model.navigate(to: .provided(WindowCommandProvider.resizeScope))
        h.model.query = "1920x1080"
        h.model.perform(try #require(h.model.results.first))
        #expect(h.model.feedback?.style == .error)
        #expect(h.system.frames.count == 1)
        // Typed arguments, once the launcher collects them, arrive as the scope's values.
        var moveCommand = try command("window.moveWindow", in: h.model)
        moveCommand.action = .provided(
            ProvidedRef(provider: WindowCommandProvider.providerID, id: "window.moveWindow", arguments: ["x": "40", "y": "30"]))
        h.model.perform(moveCommand)
        #expect(h.model.results.first?.title == "Move to 40, 30")
    }

    @Test func windowArgumentsParseCommonSpellings() {
        #expect(WindowArgumentParser.pair("1200x800").map { [$0.0, $0.1] } == [1200, 800])
        #expect(WindowArgumentParser.pair("1200 × 800").map { [$0.0, $0.1] } == [1200, 800])
        #expect(WindowArgumentParser.pair("100, 50").map { [$0.0, $0.1] } == [100, 50])
        #expect(WindowArgumentParser.pair("-20 15.5").map { [$0.0, $0.1] } == [-20, 15.5])
        #expect(WindowArgumentParser.pair("1200") == nil)
        #expect(WindowArgumentParser.pair("wide x tall") == nil)
        let resize = WindowCommandProvider.customCommand(from: "resize:800x600")
        #expect(resize?.width == .points(800) && resize?.height == .points(600) && resize?.anchor == .current)
        let move = WindowCommandProvider.customCommand(from: "move:10x20")
        #expect(move?.xOffset == .points(10) && move?.yOffset == .points(20) && move?.anchor == .topLeft)
        #expect(move?.width == nil && move?.height == nil)
        #expect(WindowCommandProvider.customCommand(from: "spin:1x2") == nil)
    }

    // MARK: Switch Windows

    @Test func switchWindowsListsEveryWindowAndFocusesTheChosenOne() async throws {
        let h = harness()
        defer { h.model.stop() }
        h.model.perform(try command("window.switch", in: h.model))
        #expect(h.model.section == .provided(WindowCommandProvider.switchScope))
        try await waitUntil { h.model.results.count == 2 }
        #expect(Set(h.model.results.map(\.title)) == ["Groceries", "Inbox"])
        let inbox = try #require(h.model.results.first { $0.title == "Inbox" })
        h.model.perform(inbox)
        #expect(h.system.events == [.focus(2)])
        // ⌘K: act on a window without switching to it.
        let actions = h.model.registry.actions(
            for: inbox, ref: try #require(Self.ref(of: inbox)), in: h.model)
        #expect(actions.map(\.title) == ["Minimize", "Toggle Full Screen", "Hide Mail", "Close Window"])
        actions[1].perform()
        #expect(h.system.events.last == .fullScreen(2, true))
        #expect(!h.system.events.dropFirst().contains(.focus(2)))
    }

    @Test func focusNextAppWindowCyclesTheForegroundAppsWindows() throws {
        let h = harness(windows: [
            WindowFixture.window(pid: 100, token: 1, title: "One", frame: CGRect(x: 0, y: 76, width: 700, height: 800)),
            WindowFixture.window(pid: 100, token: 2, title: "Two", frame: CGRect(x: 740, y: 76, width: 700, height: 800)),
        ])
        defer { h.model.stop() }
        h.system.focusedWindows[100] = WindowHandle(pid: 100, token: 1)
        h.model.perform(try command("window.focusNextAppWindow", in: h.model))
        #expect(h.system.events == [.focus(2)])
    }

    // MARK: Layouts

    @Test func saveCurrentLayoutPersistsARecordThatRunsAsACommand() async throws {
        let h = harness()
        defer { h.model.stop() }
        h.model.perform(try command("window.saveLayout", in: h.model))
        let record = try #require(h.model.store.database.windowLayouts.first)
        #expect(record.name == "Layout 1" && record.slots.count == 2)
        #expect(h.hudTexts == ["Saved “Layout 1” with 2 windows"])
        let layoutCommand = try command(WindowCommandProvider.layoutPrefix + record.id.uuidString, in: h.model)
        #expect(layoutCommand.title == "Layout 1")
        #expect(h.model.bindableCommands.contains { $0.id == layoutCommand.id })
        h.system.clearEvents()
        h.model.perform(layoutCommand)
        await h.windows.pendingTask?.value
        #expect(h.hudTexts.last == "Arranged 2 windows")
        #expect(h.system.frames.count == 2)
    }

    @Test func anEmptyOrUnnamedLayoutWarnsInsteadOfRunning() throws {
        let h = harness()
        defer { h.model.stop() }
        let empty = WindowLayoutRecord()
        #expect(h.model.store.update { $0.windowLayouts = [empty] })
        let row = try command(WindowCommandProvider.layoutPrefix + empty.id.uuidString, in: h.model)
        #expect(row.title == "Untitled Layout")
        h.model.perform(row)
        #expect(h.model.feedback?.style == .warning)
        #expect(h.system.events.isEmpty && h.windows.pendingTask == nil)
    }

    @Test func idOnlyLayoutRecordsFromStepZeroStillLoad() throws {
        let id = UUID()
        let record = try JSONDecoder().decode(WindowLayoutRecord.self, from: Data(#"{"id":"\#(id.uuidString)"}"#.utf8))
        #expect(record == WindowLayoutRecord(id: id))
        #expect(record.displayName == "Untitled Layout" && record.slots.isEmpty && record.otherWindows == .leave)
        // An Other Windows option this build doesn't know reads as Leave Open.
        let future = try JSONDecoder().decode(
            WindowLayoutRecord.self, from: Data(#"{"id":"\#(id.uuidString)","name":"Desk","otherWindows":"stack"}"#.utf8))
        #expect(future.name == "Desk" && future.otherWindows == .leave)
        // Inside a whole library.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryStore(fileURL: nil).database))
            as! [String: Any]
        json["windowLayouts"] = [["id": id.uuidString]]
        let database = try JSONDecoder().decode(LibraryDatabase.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(database.windowLayouts.map(\.id) == [id])
        // A full record round-trips.
        let layout = SavedWindowLayout(
            name: "Desk",
            slots: [
                .init(bundleIdentifier: "com.example.notes", appName: "Notes", displayIndex: 0, region: .full)
            ], otherWindows: .minimize)
        let full = WindowLayoutRecord(layout)
        #expect(try JSONDecoder().decode(WindowLayoutRecord.self, from: JSONEncoder().encode(full)) == full)
        #expect(full.layout == layout)
    }

    // MARK: System commands

    @Test func noViewSystemCommandsCloseRunAndShowTheHUD() async throws {
        let h = harness()
        defer { h.model.stop() }
        h.actions.result = .volume(0.5625, muted: false)
        h.model.perform(try command("system.volumeUp", in: h.model))
        await h.systemCommands.pendingTask?.value
        #expect(h.actions.actions == [.volume(.up)])
        #expect(h.hudTexts == ["Volume 56%"])
        #expect(h.model.store.database.usage.first?.id == "system.volumeUp")
    }

    @Test func confirmationsUseTheProviderPayloadAndCancelRunsNothing() async throws {
        let h = harness()
        defer { h.model.stop() }
        let emptyTrash = try command("system.emptyTrash", in: h.model)
        h.model.perform(emptyTrash)
        #expect(h.model.confirmation?.id == "provided.system.emptyTrash")
        #expect(h.model.confirmation?.question == "Permanently erase the items in the Trash?")
        #expect(h.model.confirmation?.confirmTitle == "Empty Trash")
        #expect(h.model.confirmation?.detail == "This can't be undone.")
        // Esc cancels.
        h.model.goBack()
        #expect(h.model.confirmation == nil)
        #expect(h.actions.actions.isEmpty && h.systemCommands.pendingTask == nil)
        // ↩ confirms.
        h.model.perform(emptyTrash)
        h.model.performSelected()
        await h.systemCommands.pendingTask?.value
        #expect(h.actions.actions == [.emptyTrash])
        #expect(h.hudTexts == ["Trash emptied"])
        // Quit Others names the app it keeps.
        h.model.perform(try command("system.quitAllAppsExceptFrontmost", in: h.model))
        #expect(h.model.confirmation?.question == "Quit every app except Notes?")
    }

    @Test func aHotkeyAsksTheSameQuestionBeforeRunning() async throws {
        let h = harness(hotKey: GlobalHotKey(backend: RecordingHotKeyBackend(), reservedShortcuts: { [] }))
        defer { h.model.stop() }
        let shortcut = CommandShortcut(keyCode: 15, modifiers: [.control, .option])
        #expect(h.model.store.saveCommandBinding(CommandBinding(targetID: "system.restart", shortcut: shortcut)))
        h.model.performBoundCommand(targetID: "system.restart")
        #expect(h.model.confirmation?.id == "provided.system.restart")
        #expect(h.actions.actions.isEmpty)
        h.model.performSelected()
        await h.systemCommands.pendingTask?.value
        #expect(h.actions.actions == [.restart])
    }

    @Test func optionalConfirmationsFollowSettingsButRestartAlwaysAsks() async throws {
        let h = harness()
        defer { h.model.stop() }
        #expect(h.model.store.update {
            $0.systemCommandSettings = SystemCommandSettings(confirmsEmptyingTrash: false, confirmsQuittingApps: false)
        })
        h.model.perform(try command("system.emptyTrash", in: h.model))
        #expect(h.model.confirmation == nil)
        await h.systemCommands.pendingTask?.value
        #expect(h.actions.actions == [.emptyTrash])
        h.model.perform(try command("system.restart", in: h.model))
        #expect(h.model.confirmation?.id == "provided.system.restart")
    }

    @Test func quitOthersWithoutAForegroundAppSaysSoAndRunsNothing() throws {
        let h = harness(foreground: nil)
        defer { h.model.stop() }
        h.model.perform(try command("system.quitAllAppsExceptFrontmost", in: h.model))
        #expect(h.model.confirmation == nil)
        #expect(h.model.feedback?.style == .warning)
        #expect(h.actions.actions.isEmpty && h.systemCommands.pendingTask == nil)
    }

    @Test func quitAllHonoursTheExclusionsFromSettings() async throws {
        let h = harness()
        defer { h.model.stop() }
        #expect(h.model.store.update {
            $0.systemCommandSettings = SystemCommandSettings(confirmsQuittingApps: false, quitExclusions: ["com.example.music"])
        })
        h.model.perform(try command("system.quitAllApps", in: h.model))
        await h.systemCommands.pendingTask?.value
        #expect(h.actions.actions == [.quitAllApps(excluded: ["com.example.music"])])
    }

    @Test func setVolumeFromAHotkeyAsksForTheLevelInsteadOfFailing() async throws {
        let h = harness(hotKey: GlobalHotKey(backend: RecordingHotKeyBackend(), reservedShortcuts: { [] }))
        defer { h.model.stop() }
        let shortcut = CommandShortcut(keyCode: 9, modifiers: [.control, .option])
        #expect(h.model.store.saveCommandBinding(CommandBinding(targetID: "system.setVolume", shortcut: shortcut)))
        h.model.performBoundCommand(targetID: "system.setVolume")
        #expect(h.model.feedback == nil)
        #expect(h.model.section == .provided(SystemCommandProvider.volumeScope))
        #expect(h.model.results.first?.title == "Set Volume to 100%")
        #expect(h.model.results.count == 11)
        h.model.query = "35"
        let row = try #require(h.model.results.first)
        #expect(row.title == "Set Volume to 35%" && h.model.results.count == 1)
        h.actions.result = .volume(0.35, muted: false)
        h.model.perform(row)
        await h.systemCommands.pendingTask?.value
        #expect(h.actions.actions == [.volume(.set(0.35))])
        #expect(h.hudTexts == ["Volume 35%"])
    }

    @Test func setVolumeWithATypedArgumentPutsThatLevelFirst() throws {
        let h = harness()
        defer { h.model.stop() }
        var setVolume = try command("system.setVolume", in: h.model)
        setVolume.action = .provided(
            ProvidedRef(provider: SystemCommandProvider.providerID, id: "system.setVolume", arguments: ["level": "40"]))
        h.model.perform(setVolume)
        #expect(h.model.results.first?.title == "Set Volume to 40%")
        #expect(SystemCommandProvider.volumeLevels(query: "", argument: nil).count == 11)
        #expect(SystemCommandProvider.volumeLevels(query: "loud", argument: nil).isEmpty)
    }

    // MARK: Sound devices

    @Test func soundDeviceScopesListDevicesAndSwitchTheDefault() throws {
        let h = harness()
        defer { h.model.stop() }
        h.model.perform(try command("system.soundOutput", in: h.model))
        #expect(h.model.results.map(\.title) == ["MacBook Speakers", "Headphones"])
        #expect(h.model.results.first?.subtitle == "Current output")
        let headphones = try #require(h.model.results.first { $0.title == "Headphones" })
        h.model.perform(headphones)
        #expect(h.audio.defaults[.output] == FakeAudioDevices.headphones)
        #expect(h.hudTexts == ["Output: Headphones"])
        h.model.perform(try command("system.soundInput", in: h.model))
        #expect(h.model.results.map(\.title) == ["MacBook Microphone"])
    }

    // MARK: Search Menu Bar Items

    @Test func menuSearchReadsLiveItemsAndPressesThroughTheReader() async throws {
        let h = harness()
        defer { h.model.stop() }
        h.model.perform(try command("system.searchMenuBarItems", in: h.model))
        #expect(h.model.section == .provided(SystemCommandProvider.menuScope))
        try await waitUntil { h.model.results.count == 3 }
        #expect(h.model.results.map(\.title) == ["New Note", "PDF", "Print"])
        #expect(h.model.results[1].subtitle == "File › Export")
        #expect(h.model.results[1].badge == "⇧⌘E")
        guard case .provided(let printRef) = h.model.results[2].action else { throw CancellationError() }
        #expect(printRef.has(.unavailable))
        h.model.query = "pdf"
        try await waitUntil { h.model.results.first?.title == "PDF" && h.model.results.count == 1 }
        h.model.perform(try #require(h.model.results.first))
        await h.systemCommands.pendingTask?.value
        #expect(h.menus.pressedTitles == ["PDF"])
    }

    @Test func menuSearchExplainsWhenTheresNoAppToSearch() async throws {
        let h = harness(foreground: nil)
        defer { h.model.stop() }
        h.model.navigate(to: .provided(SystemCommandProvider.menuScope))
        try await waitUntil { !h.model.isLoadingProvidedItems }
        #expect(h.model.results.isEmpty)
        #expect(h.model.providedEmptyState(for: SystemCommandProvider.menuScope).title == "No menus to search")
    }

    // MARK: Settings

    @Test func settingsAreStoredInCommandPreferencesAndClampedWhenRead() {
        var database = LibraryStore(fileURL: nil).database
        database.windowManagementSettings = WindowManagementSettings(gaps: WindowGaps(window: 8, screen: 4), cyclesHalves: true)
        #expect(database.windowManagementSettings == WindowManagementSettings(gaps: WindowGaps(window: 8, screen: 4), cyclesHalves: true))
        database.commandPreferences[WindowManagementSettings.storageKey] = ["windowGap": "900", "screenGap": "-3"]
        #expect(database.windowManagementSettings.gaps == WindowGaps(window: WindowGaps.maximum, screen: 0))
        #expect(!database.windowManagementSettings.cyclesHalves)
        #expect(database.systemCommandSettings == SystemCommandSettings())
        database.systemCommandSettings = SystemCommandSettings(
            confirmsEmptyingTrash: false, quitExclusions: ["com.example.music", "com.example.music", "com.example.mail"])
        #expect(database.systemCommandSettings.quitExclusions == ["com.example.music", "com.example.mail"])
        #expect(!database.systemCommandSettings.asksFirst(.emptyTrash))
        #expect(database.systemCommandSettings.asksFirst(.shutDown))
        #expect(!database.systemCommandSettings.asksFirst(.lockScreen))
    }

    @Test func windowsAndSystemPanesSitInTheSliceFiveSlot() {
        let mine: [SettingsPane] = [.windows, .system]
        #expect(SettingsPane.primary.filter(mine.contains) == mine)
        #expect(SettingsPane(rawValue: "windows") == .windows)
        #expect(SettingsPane(rawValue: "system") == .system)
        #expect(Set(SettingsPane.allCases.map(\.id)).count == SettingsPane.allCases.count)
        #expect(WindowsPane.gapTitle(0) == "None" && WindowsPane.gapTitle(8) == "8 pt")
        #expect(WindowLayoutSettingsRow.summary(of: WindowLayoutRecord()) == "0 windows")
    }

    @Test func layoutNamesCountUpPastExistingOnes() {
        #expect(WindowCommandProvider.nextLayoutName(after: []) == "Layout 1")
        let taken = [WindowLayoutRecord(name: "Layout 2")]
        #expect(WindowCommandProvider.nextLayoutName(after: taken) == "Layout 3")
    }

    private static func ref(of item: LauncherItem) -> ProvidedRef? {
        if case .provided(let ref) = item.action { return ref }
        return nil
    }
}
