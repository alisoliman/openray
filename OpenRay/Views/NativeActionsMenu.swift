import AppKit
import SwiftUI

/// AppKit's menu tracking owns arrows, Return, Escape, and accessibility focus.
/// A SwiftUI popover alone leaves those keys in the launcher's field editor.
struct NativeActionsMenu: NSViewRepresentable {
    struct Entry {
        var title: String
        var symbol: String
        var perform: @MainActor () -> Void
    }

    @Binding var isPresented: Bool
    var title: String
    var entries: [Entry]
    var didClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        guard isPresented else {
            context.coordinator.cancelTracking()
            return
        }
        guard !context.coordinator.isTracking else { return }
        context.coordinator.isTracking = true
        // Leave SwiftUI's update transaction before starting AppKit's menu loop.
        DispatchQueue.main.async { [weak view, coordinator = context.coordinator] in
            guard coordinator.parent.isPresented else {
                coordinator.isTracking = false
                return
            }
            guard let view, view.window?.isVisible == true else {
                coordinator.isTracking = false
                coordinator.parent.isPresented = false
                coordinator.parent.didClose()
                return
            }
            coordinator.present(in: view)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeActionsMenu
        var isTracking = false
        private var activeEntries: [Entry] = []
        private var activeMenu: NSMenu?

        init(parent: NativeActionsMenu) { self.parent = parent }

        func makeMenu() -> NSMenu {
            activeEntries = parent.entries
            let menu = NSMenu(title: parent.title)
            menu.autoenablesItems = false
            let heading = NSMenuItem(title: parent.title, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            menu.addItem(.separator())
            for (index, entry) in activeEntries.enumerated() {
                let item = NSMenuItem(title: entry.title, action: #selector(performEntry(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            let close = NSMenuItem(title: "Close Actions", action: #selector(closeMenu(_:)), keyEquivalent: "k")
            close.target = self
            close.keyEquivalentModifierMask = .command
            close.isHidden = true
            close.allowsKeyEquivalentWhenHidden = true
            menu.addItem(close)
            return menu
        }

        func present(in view: NSView) {
            let menu = makeMenu()
            activeMenu = menu
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: view.bounds.maxY), in: view)
            activeMenu = nil
            isTracking = false
            parent.isPresented = false
            parent.didClose()
        }

        func cancelTracking() { activeMenu?.cancelTracking() }

        @objc private func performEntry(_ sender: NSMenuItem) {
            guard activeEntries.indices.contains(sender.tag) else { return }
            activeEntries[sender.tag].perform()
        }

        @objc private func closeMenu(_ sender: NSMenuItem) { sender.menu?.cancelTracking() }
    }
}
