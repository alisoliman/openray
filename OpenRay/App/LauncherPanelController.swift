import AppKit
import SwiftUI

final class LauncherPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    private let model: LauncherModel
    private var window: NSPanel?

    init(model: LauncherModel) {
        self.model = model
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationResignedActive(_:)),
            name: NSApplication.didResignActiveNotification, object: NSApp)
    }

    func toggle() {
        if window?.isVisible == true { dismiss() } else { show() }
    }

    func show(section: LauncherSection? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            model.previousApplication = front
        }
        if let section { model.navigate(to: section) }
        if window == nil { createWindow() }
        guard let window else { return }
        if !window.isVisible {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                window.setFrameOrigin(
                    CGPoint(
                        x: frame.midX - window.frame.width / 2,
                        y: frame.maxY - window.frame.height - max(50, frame.height * 0.12)))
            }
        }
        model.refreshPermissions()
        model.store.pruneClipboard()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        model.resumeSearch()
        model.focusRequest += 1
    }

    func dismiss(restoreFocus: Bool = true) {
        model.showActions = false
        window?.orderOut(nil)
        model.files.stop()
        if restoreFocus { model.previousApplication?.activate() }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard window?.attachedSheet == nil, model.editor == nil, !model.showActions else { return }
        dismiss(restoreFocus: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    @objc private func applicationResignedActive(_ notification: Notification) {
        guard window?.attachedSheet == nil, model.editor == nil else { return }
        dismiss(restoreFocus: false)
    }

    private func createWindow() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 570),
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
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.onCancel = { [weak model] in model?.goBack() }
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ContentView(model: model))
        window = panel
    }
}

@MainActor
final class OpenRayDelegate: NSObject, NSApplicationDelegate {
    let model = LauncherModel(
        store: LibraryStore(fileURL: RuntimeMode.usesInMemoryLibrary ? nil : LibraryStore.defaultURL),
        pasteboard: RuntimeMode.launchPasteboard(arguments: ProcessInfo.processInfo.arguments))
    private var panelController: LauncherPanelController?

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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        panel.show()
        Task { await model.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        model.stop()
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        model.previousApplication = application
    }
}

enum RuntimeMode {
    @MainActor static func launchPasteboard(arguments: [String]) -> NSPasteboard {
        guard arguments.contains("--verification-pasteboard") else { return .general }
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

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static var usesInMemoryLibrary: Bool {
        isTestHost || ProcessInfo.processInfo.arguments.contains("--in-memory-library")
            || ProcessInfo.processInfo.arguments.contains("--verification-pasteboard")
    }
}
