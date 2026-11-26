import AppKit
import QuickLookUI
import SwiftUI

final class LauncherPanel: NSPanel {
    var onCancel: (() -> Void)?
    var escapeAction: (() -> Bool)?
    /// The visible panel in content-view coordinates. The rest of the window
    /// only holds the shadow, so a click there closes the panel.
    var panelRect: (() -> CGRect)?
    var onClickOutside: (() -> Void)?
    /// Return confirms a pending action-bar confirmation, even from a text editor. It gets
    /// whether the key is an autorepeat, which never confirms, and the key event's own timestamp
    /// (seconds since startup), so a press made before the prompt was on screen never answers it,
    /// however late it's handled. Returns whether it handled the key.
    var confirmAction: ((_ isRepeat: Bool, _ timestamp: TimeInterval) -> Bool)?
    /// The file Quick Look previews. Quick Look finds its controller through the
    /// responder chain, which ends at this window, so the panel controls it.
    var quickLook: QuickLookPreview? {
        didSet {
            // Quick Look doesn't retain its data source; repoint it before the old one goes.
            guard let oldValue, QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared(),
                preview.dataSource === oldValue
            else { return }
            preview.dataSource = quickLook
            preview.delegate = quickLook
            preview.reloadData()
        }
    }
    var onQuickLookEnd: (() -> Void)?
    /// Launcher keys that aren't text editing (⌘Esc, ⌘W, Vim ⌃J/⌃K), by key code and modifiers.
    /// Returns whether the key was used.
    var keyCommand: ((UInt16, ShortcutModifiers) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil, !(firstResponder is NSTextView) else {
            super.cancelOperation(sender)
            return
        }
        onCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        if handleEscapeKey(event) { return }
        if event.type == .keyDown, attachedSheet == nil, !((firstResponder as? NSTextView)?.hasMarkedText() ?? false),
            keyCommand?(event.keyCode, Self.modifiers(of: event)) == true
        {
            return
        }
        if event.type == .keyDown, [36, 76].contains(event.keyCode),
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            !((firstResponder as? NSTextView)?.hasMarkedText() ?? false), confirmAction?(event.isARepeat, event.timestamp) == true
        {
            return
        }
        // A closing layer can leave no text responder. Typing should still land in the field.
        if event.type == .keyDown, firstResponder === self || firstResponder == nil,
            event.modifierFlags.intersection([.command, .control]).isEmpty,
            let field = Self.firstTextInput(in: contentView)
        {
            // focusIfNeeded puts the caret after the query, so the keystroke adds to it.
            if let search = field as? FocusedSearchField { search.focusIfNeeded() } else { makeFirstResponder(field) }
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), let rect = panelRect?(),
            let content = contentView, !rect.contains(content.convert(event.locationInWindow, from: nil))
        {
            onClickOutside?()
            return
        }
        super.sendEvent(event)
    }

    static func modifiers(of event: NSEvent) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    static func firstTextInput(in view: NSView?) -> NSView? {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
        if view is FocusedSearchField || view is FocusedComposerTextView { return view }
        for subview in view.subviews {
            if let found = firstTextInput(in: subview) { return found }
        }
        return nil
    }

    /// Esc closes exactly one layer, including from inline editors and the AI
    /// composer. The search field handles its own Escape so it can clear the
    /// live field editor in the same callback, and input methods keep theirs.
    func handleEscapeKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            attachedSheet == nil
        else { return false }
        if let editor = firstResponder as? NSTextView {
            if editor.hasMarkedText() { return false }
            if editor.isFieldEditor, (editor.delegate as? NSTextField)?.delegate is LauncherSearchInput.Coordinator {
                return false
            }
        }
        return escapeAction?() ?? false
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook != nil }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = quickLook
            panel.delegate = quickLook
            panel.reloadData()
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            onQuickLookEnd?()
        }
    }
}

/// One file for the shared Quick Look panel. ⌘Y closes it again, as in Finder.
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let url: NSURL

    init(url: URL) {
        self.url = url as NSURL
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "y",
            event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
        else { return false }
        MainActor.assumeIsolated { panel.orderOut(nil) }
        return true
    }
}

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    private let model: LauncherModel
    private var window: LauncherPanel?
    private var appearanceObservation: Any?
    /// Set while Quick Look takes key, so the launcher doesn't close under it.
    private var isOpeningQuickLook = false

    init(model: LauncherModel) {
        self.model = model
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationResignedActive(_:)),
            name: NSApplication.didResignActiveNotification, object: NSApp)
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Visible, fully faded in and key: what a prompt needs before it can be approved.
    var isSurfaceVisible: Bool {
        guard let window else { return false }
        return window.isVisible && window.alphaValue >= 1 && window.isKeyWindow && window.occlusionState.contains(.visible)
    }

    /// When the panel's reveal animation finished, or it last took key back, while it's visible
    /// and key; nil otherwise, including during the reveal. Prompt approval counts from here.
    var surfaceVisibleSince: Date? { isSurfaceVisible ? revealedAt : nil }
    private var revealedAt: Date?
    /// Changes on every show and hide, so a reveal that finishes after the panel hid, or after
    /// it showed again, never counts.
    private var revealGeneration = 0

    func toggle() {
        if window?.isVisible == true { dismiss() } else { show() }
    }

    func show(section: LauncherSection? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            model.previousApplication = front
            model.targetWindow = nil
        }
        // The interface size applies as the panel appears, before anything is drawn or placed.
        if window?.isVisible != true { applyInterfaceSize() }
        if window == nil { createWindow() }
        guard let window else { return }
        let wasVisible = window.isVisible
        if !wasVisible {
            model.panelWillShow()
            model.beginOnboardingIfNeeded()
            position(window)
        }
        if let section {
            // Closing a dirty editor would only raise the discard prompt, so it stays open.
            if model.editor == nil {
                model.navigate(to: section)
            } else if section != .home, section != model.section {
                model.feedback = .warning("Save or cancel the current editor first.")
            }
        }
        applyAppearance()
        model.refreshPermissions()
        model.store.pruneClipboard()
        if !wasVisible {
            model.isPresented = false
            window.alphaValue = 0
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        model.resumeSearch()
        model.focusRequest += 1
        if !wasVisible {
            revealedAt = nil
            revealGeneration += 1
            let generation = revealGeneration
            DispatchQueue.main.async { [weak self, model] in
                window.alphaValue = 1
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                withAnimation(
                    OR.Motion.resolve(OR.Motion.panel, reduceMotion: reduceMotion), completionCriteria: .logicallyComplete
                ) {
                    model.isPresented = true
                } completion: { [weak self] in
                    // Only once the reveal has finished does the panel count as showing prompts.
                    guard let self, self.revealGeneration == generation, window.isVisible else { return }
                    self.revealedAt = Date()
                }
            }
        }
    }

    func dismiss(restoreFocus: Bool = true) {
        guard let window, window.isVisible else { return }
        revealedAt = nil
        revealGeneration += 1
        model.panelDidHide()
        window.orderOut(nil)
        if isQuickLookVisible { QLPreviewPanel.shared().orderOut(nil) }
        model.files.stop()
        // Activating another app is a side effect inert launches never take.
        if restoreFocus, !model.sideEffects.isInert { model.previousApplication?.activate() }
    }

    /// Previews a file in the shared Quick Look panel above the launcher, or closes it.
    func toggleQuickLook(_ url: URL) {
        guard InertReadBoundary.allows(url) else { return }
        guard let window, window.isVisible, let preview = QLPreviewPanel.shared() else { return }
        if preview.isVisible {
            preview.orderOut(nil)
            return
        }
        window.quickLook = QuickLookPreview(url: url)
        // Once it's key, Quick Look looks for its controller from the main window.
        if !window.isMainWindow { window.makeMain() }
        preview.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpeningQuickLook = true
        preview.makeKeyAndOrderFront(nil)
        isOpeningQuickLook = false
    }

    private var isQuickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// AppKit usually hands key back when the preview closes. Quick Look also
    /// ends its control when another of OpenRay's windows takes key, which
    /// closes the launcher as it would without a preview.
    private func quickLookDidEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible, !window.isKeyWindow, NSApp.isActive
            else { return }
            switch NSApp.keyWindow {
            case nil: window.makeKey()
            case is QLPreviewPanel: break
            case .some: self.dismiss(restoreFocus: false)
            }
        }
    }

    /// The upper third of the chosen screen, with a fixed top edge: the screen with the
    /// pointer, the one with the active window, or the primary one.
    private func position(_ window: NSWindow) {
        guard let frame = Self.screen(for: model.store.database.preferences.screen)?.visibleFrame else { return }
        let size = PanelGeometry.windowSize
        let panelTop = frame.maxY - max(40, frame.height * 0.13)
        window.setFrame(
            NSRect(
                x: (frame.midX - size.width / 2).rounded(),
                y: (panelTop + PanelGeometry.topMargin - size.height).rounded(),
                width: size.width, height: size.height),
            display: false)
    }

    /// Sets the design tokens' scale from Settings › General › Interface size, and rebuilds the
    /// panel's views when it changed, so every font and length takes it.
    private func applyInterfaceSize() {
        let scale = model.store.database.preferences.size.scale
        guard OR.interfaceScale != scale else { return }
        OR.interfaceScale = scale
        guard let window else { return }
        let size = PanelGeometry.windowSize
        let host = NSHostingView(rootView: LauncherRootView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        window.contentView = host
    }

    static func screen(for choice: LauncherScreen) -> NSScreen? {
        let pointer = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        switch choice {
        case .mouse:
            return pointer
        case .primary:
            return NSScreen.screens.first ?? pointer
        case .focusedWindow:
            guard let frame = frontmostWindowFrame() else { return pointer }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            return NSScreen.screens.first { $0.frame.contains(center) } ?? pointer
        }
    }

    /// The frontmost app's front window, in AppKit screen coordinates. Window bounds need no
    /// permission; titles aren't read.
    private static func frontmostWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
            let info = windows.first(where: {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == 0
            }),
            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        // Quartz measures from the top of the primary screen; AppKit from its bottom.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    func applyAppearance() {
        let appearance: NSAppearance? =
            switch model.store.database.preferences.appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        window?.appearance = appearance
    }

    /// Taking key back from a sheet or Quick Look restarts prompt exposure: what was on top may
    /// have covered the prompt.
    func windowDidBecomeKey(_ notification: Notification) {
        if revealedAt != nil { revealedAt = Date() }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard window?.attachedSheet == nil, !isOpeningQuickLook else { return }
        guard isQuickLookVisible else {
            dismiss(restoreFocus: false)
            return
        }
        // The preview holds key while it's open. Any other window taking key still closes the launcher.
        DispatchQueue.main.async { [weak self] in
            guard let self, let key = NSApp.keyWindow, key !== self.window, !(key is QLPreviewPanel) else { return }
            self.dismiss(restoreFocus: false)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    /// Leaving OpenRay closes the launcher and any Quick Look preview over it.
    @objc private func applicationResignedActive(_ notification: Notification) {
        guard window?.attachedSheet == nil else { return }
        dismiss(restoreFocus: false)
    }

    private func createWindow() {
        let size = PanelGeometry.windowSize
        let panel = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = model.clipboard.usesGeneralPasteboard ? "OpenRay" : "OpenRay — Clipboard Verification"
        panel.identifier = NSUserInterfaceItemIdentifier("OpenRayLauncher")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The panel draws its own layered shadow; see PanelSurface.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.onCancel = { [weak model] in model?.escape() }
        panel.delegate = self
        panel.escapeAction = { [weak model] in
            guard let model else { return false }
            model.escape()
            return true
        }
        panel.keyCommand = { [weak model] keyCode, modifiers in
            guard let model,
                let command = LauncherKeyCommand.command(
                    keyCode: keyCode, modifiers: modifiers, vim: model.store.database.preferences.usesVimNavigation)
            else { return false }
            return model.handle(command)
        }
        panel.panelRect = { [weak model] in
            guard let model else { return .zero }
            let size = model.panelSize
            let window = PanelGeometry.windowSize
            // AppKit content coordinates are bottom-up; the panel hangs from the top margin.
            return CGRect(
                x: (window.width - size.width) / 2, y: window.height - PanelGeometry.topMargin - size.height,
                width: size.width, height: size.height)
        }
        // The margin belongs to whatever is behind it, so focus goes back to that app.
        panel.onClickOutside = { [weak self] in self?.dismiss() }
        panel.onQuickLookEnd = { [weak self] in self?.quickLookDidEnd() }
        panel.confirmAction = { [weak model] isRepeat, timestamp in
            guard let model else { return false }
            return model.confirmFromReturn(isRepeat: isRepeat, pressedAt: model.promptDate(forEventTimestamp: timestamp))
        }
        let host = NSHostingView(rootView: LauncherRootView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        window = panel
        applyAppearance()
    }
}

@MainActor
final class OpenRayDelegate: NSObject, NSApplicationDelegate {
    let model = LauncherModel(
        store: LibraryStore(fileURL: RuntimeMode.usesInMemoryLibrary ? nil : LibraryStore.defaultURL),
        pasteboard: RuntimeMode.launchPasteboard(arguments: ProcessInfo.processInfo.arguments))
    private var panelController: LauncherPanelController?
    private(set) lazy var settingsController = SettingsWindowController(model: model)
    private(set) lazy var helpController = HelpWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !RuntimeMode.isTestHost else { return }
        if ProcessInfo.processInfo.arguments.contains("--verification-pasteboard"),
            RuntimeMode.verificationPasteboardName(arguments: ProcessInfo.processInfo.arguments) == nil
        {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let panel = LauncherPanelController(model: model)
        panelController = panel
        model.panel = panel
        model.presentSettings = { [weak self] pane, commandID in
            self?.settingsController.show(pane: pane, focusCommandID: commandID)
        }
        model.presentHelp = { [weak self] in self?.helpController.show() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        panel.show()
        // Slice 6: the Notes window reaches the launcher, and menu bar extras start drawing.
        NotesCenter.shared.launcher = model
        MenuBarExtrasController.shared.start(model: model)
        Task { await model.start() }
        if let pane = RuntimeMode.settingsPane(arguments: ProcessInfo.processInfo.arguments) {
            model.openSettings(pane)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotesCenter.shared.prepareForTermination()
        MenuBarExtrasController.shared.stop()
        model.stop()
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        model.previousApplication = application
        model.targetWindow = nil
    }
}

/// A standard window hosting SwiftUI, created on demand.
@MainActor
class AuxiliaryWindowController: NSObject, NSWindowDelegate {
    let model: LauncherModel
    private(set) var window: NSWindow?

    init(model: LauncherModel) {
        self.model = model
    }

    func makeRootView() -> AnyView { AnyView(EmptyView()) }
    var title: String { "OpenRay" }
    var initialSize: NSSize { NSSize(width: 760, height: 540) }
    var minimumSize: NSSize { NSSize(width: 640, height: 440) }
    var identifier: String { "openray.window" }

    func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = title
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.minSize = minimumSize
            window.contentViewController = NSHostingController(rootView: makeRootView())
            window.setContentSize(initialSize)
            window.center()
            window.setFrameAutosaveName(identifier)
            window.delegate = self
            self.window = window
        }
        applyAppearance()
        activateFromFrontmostApplication()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The launcher is a non-activating panel, so the app it opened over stays
    /// frontmost. A plain activate() then changes nothing, and this window
    /// would appear without keyboard focus; taking activation from that app works.
    private func activateFromFrontmostApplication() {
        let current = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != current.processIdentifier,
            current.activate(from: front)
        {
            return
        }
        NSApp.activate()
    }

    func applyAppearance() {
        window?.appearance =
            switch model.store.database.preferences.appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshPermissions()
    }

    /// Ends field editing so a focused field, such as an alias, commits before the window goes.
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }
}

final class SettingsWindowController: AuxiliaryWindowController {
    private let navigation = SettingsNavigation()

    override func makeRootView() -> AnyView { AnyView(SettingsWindowView(model: model, navigation: navigation)) }
    override var title: String { "Settings" }
    override var initialSize: NSSize { NSSize(width: 780, height: 580) }
    override var minimumSize: NSSize { NSSize(width: 700, height: 460) }
    override var identifier: String { "openray.settings" }

    /// Opens Settings, optionally at a pane and at a command's row in Shortcuts.
    func show(pane: SettingsPane?, focusCommandID: String? = nil) {
        if let pane {
            // A leftover sidebar search could hide the pane being opened.
            navigation.search = ""
            navigation.pane = pane
            navigation.focusCommandID = focusCommandID
        }
        showWindow()
    }
}

final class HelpWindowController: AuxiliaryWindowController {
    override func makeRootView() -> AnyView { AnyView(OpenRayHelpView(model: model)) }
    override var title: String { "OpenRay Help" }
    override var initialSize: NSSize { NSSize(width: 720, height: 680) }
    override var minimumSize: NSSize { NSSize(width: 600, height: 440) }
    override var identifier: String { "openray-help" }

    func show() { showWindow() }
}

enum RuntimeMode {
    /// The pasteboard a launch uses: a named verification pasteboard when one is given, a
    /// private one in any other inert launch (the test host, `--in-memory-library`), and the
    /// system clipboard only in a normal launch.
    @MainActor static func launchPasteboard(
        arguments: [String], sideEffects: SideEffectGuard = .current
    ) -> NSPasteboard {
        guard arguments.contains("--verification-pasteboard") else {
            return sideEffects.isInert ? NSPasteboard.withUniqueName() : .general
        }
        if let name = verificationPasteboardName(arguments: arguments) { return NSPasteboard(name: name) }
        // Invalid verification arguments must never fall back to the user's clipboard.
        return NSPasteboard.withUniqueName()
    }

    static func verificationPasteboardName(arguments: [String]) -> NSPasteboard.Name? {
        guard arguments.contains("--in-memory-library"),
            let index = arguments.firstIndex(of: "--verification-pasteboard"), arguments.indices.contains(index + 1)
        else { return nil }
        let name = arguments[index + 1]
        guard name.hasPrefix("OpenRayVerification."), name.count <= 160,
            name.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45
            })
        else { return nil }
        return .init(name)
    }

    /// The pane `--open-settings [pane]` asks for. General when the next argument isn't a pane.
    static func settingsPane(arguments: [String]) -> SettingsPane? {
        guard let index = arguments.firstIndex(of: "--open-settings") else { return nil }
        let next = arguments.indices.contains(index + 1) ? SettingsPane(rawValue: arguments[index + 1]) : nil
        return next ?? .general
    }

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static var usesInMemoryLibrary: Bool {
        isTestHost || SideEffectGuard.isInert || ProcessInfo.processInfo.arguments.contains("--in-memory-library")
            || ProcessInfo.processInfo.arguments.contains("--verification-pasteboard")
    }
}
