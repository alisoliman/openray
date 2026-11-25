import AppKit
import CoreGraphics

/// One window in the window server's list, front to back. Bounds use the same
/// top-left global coordinates as Accessibility. Reading bounds and owners needs
/// no Screen Recording access; only window names would.
struct WindowServerEntry: Equatable, Sendable {
    var number: UInt32
    var pid: pid_t
    var bounds: CGRect
    /// 0 is the normal window layer; menus, the Dock and overlays sit above it.
    var layer: Int
}

/// The on-screen window list, behind a protocol so tests supply their own.
@MainActor
protocol WindowServerListing: AnyObject {
    func onScreenWindows() -> [WindowServerEntry]
}

@MainActor
final class CGWindowServerListing: WindowServerListing {
    nonisolated init() {}

    func onScreenWindows() -> [WindowServerEntry] {
        guard
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return info.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
                let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            return WindowServerEntry(
                number: number.uint32Value, pid: pid.int32Value, bounds: bounds,
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
        }
    }
}

/// A row in Switch Windows.
struct SwitchableWindow: Identifiable, Equatable {
    var snapshot: WindowSnapshot
    /// The window server's number, when the window is on screen in the current Space.
    var windowNumber: UInt32?

    var id: String { "\(snapshot.pid).\(snapshot.handle.token)" }
    var handle: WindowHandle { snapshot.handle }
    var appName: String { snapshot.appName }
    var bundleURL: URL? { snapshot.bundleURL }
    var isMinimized: Bool { snapshot.isMinimized }
    var isOnScreen: Bool { windowNumber != nil }
    /// Untitled windows show their app's name.
    var title: String { snapshot.title.isEmpty ? snapshot.appName : snapshot.title }
    var subtitle: String {
        isMinimized ? "\(appName) · Minimized" : snapshot.title.isEmpty ? "" : appName
    }
    /// Both the title and the app, so "Safari" finds every Safari window.
    var searchText: String { "\(title) \(appName)" }

    func icon() -> NSImage? {
        bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

enum WindowSwitcherOrdering {
    /// On-screen windows first, front to back as the window server stacks them;
    /// then windows in other Spaces; then minimized ones. Ties keep their order.
    static func order(
        _ windows: [WindowSnapshot], entries: [WindowServerEntry], primaryHeight: CGFloat
    ) -> [SwitchableWindow] {
        var remaining = windows
        var onScreen: [SwitchableWindow] = []
        for entry in entries where entry.layer == 0 {
            guard
                let index = remaining.firstIndex(where: { window in
                    window.pid == entry.pid && !window.isMinimized
                        && WindowGeometry.approximatelyEqual(
                            ScreenCoordinates.flip(window.frame, primaryHeight: primaryHeight), entry.bounds,
                            tolerance: 2)
                })
            else { continue }
            onScreen.append(SwitchableWindow(snapshot: remaining.remove(at: index), windowNumber: entry.number))
        }
        let elsewhere = remaining.filter { !$0.isMinimized }.map { SwitchableWindow(snapshot: $0) }
        let minimized = remaining.filter(\.isMinimized).map { SwitchableWindow(snapshot: $0) }
        return onScreen + elsewhere + minimized
    }

    /// The app's next or previous window in a stable order (window-server number,
    /// then title), wrapping around. Nil when the app has a single window.
    static func adjacent(
        in windows: [SwitchableWindow], pid: pid_t, current: WindowHandle?, forward: Bool
    ) -> SwitchableWindow? {
        let own = windows.filter { $0.snapshot.pid == pid }.sorted { lhs, rhs in
            switch (lhs.windowNumber, rhs.windowNumber) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
        guard own.count > 1 else { return nil }
        guard let current, let index = own.firstIndex(where: { $0.handle == current }) else {
            return forward ? own.first : own.last
        }
        return own[(index + (forward ? 1 : own.count - 1)) % own.count]
    }
}

/// Switch Windows: every window across apps, and what you can do with one.
@MainActor
final class WindowSwitcher {
    let system: any WindowSystem
    let listing: any WindowServerListing

    init(system: any WindowSystem, listing: any WindowServerListing = CGWindowServerListing()) {
        self.system = system
        self.listing = listing
    }

    var hasPermission: Bool { system.isTrusted }

    /// Every window of other apps, most recently stacked first. Empty without Accessibility access.
    func windows() -> [SwitchableWindow] {
        guard system.isTrusted else { return [] }
        let primaryHeight = system.displays().first?.frame.maxY ?? 0
        return WindowSwitcherOrdering.order(
            system.windows(includeMinimized: true), entries: listing.onScreenWindows(), primaryHeight: primaryHeight)
    }

    static func filter(_ windows: [SwitchableWindow], query: String) -> [SwitchableWindow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return windows }
        let scored = windows.enumerated().compactMap { offset, window -> (Int, Int, SwitchableWindow)? in
            let title = SearchMatcher.score(trimmed, in: window.title)
            let all = SearchMatcher.score(trimmed, in: window.searchText).map { $0 - 50 }
            guard let score = [title, all].compactMap({ $0 }).max() else { return nil }
            return (score, offset, window)
        }
        let ranked = scored.sorted { (lhs: (Int, Int, SwitchableWindow), rhs: (Int, Int, SwitchableWindow)) -> Bool in
            lhs.0 != rhs.0 ? lhs.0 > rhs.0 : lhs.1 < rhs.1
        }
        return ranked.map { $0.2 }
    }

    /// ↩: brings the window forward, restoring it first when minimized.
    func focus(_ window: SwitchableWindow) throws {
        try requireOtherApp(window)
        if window.isMinimized { try system.setMinimized(false, of: window.handle) }
        try system.focus(window.handle)
    }

    func minimize(_ window: SwitchableWindow) throws {
        try requireOtherApp(window)
        try system.setMinimized(true, of: window.handle)
    }

    func close(_ window: SwitchableWindow) throws {
        try requireOtherApp(window)
        try system.close(window.handle)
    }

    func toggleFullScreen(_ window: SwitchableWindow) throws {
        try requireOtherApp(window)
        if window.isMinimized { try system.setMinimized(false, of: window.handle) }
        try system.setFullScreen(!(system.isFullScreen(window.handle) ?? false), of: window.handle)
        try system.focus(window.handle)
    }

    func hideApplication(of window: SwitchableWindow) throws {
        try requireOtherApp(window)
        try system.hideApplication(window.snapshot.pid)
    }

    /// Focus Next / Previous App Window: cycles the windows of the app you came from.
    func focusAdjacentWindow(of pid: pid_t?, forward: Bool) throws {
        guard system.isTrusted else {
            throw LibraryValidationError(
                "Allow OpenRay in System Settings → Privacy & Security → Accessibility to switch windows.")
        }
        guard let pid, pid != system.ownPID, system.isRunning(pid) else {
            throw LibraryValidationError("Focus a window in another app, then open OpenRay and try again.")
        }
        guard
            let next = WindowSwitcherOrdering.adjacent(
                in: windows(), pid: pid, current: system.focusedWindow(of: pid), forward: forward)
        else { throw LibraryValidationError("This app has no other window.") }
        try focus(next)
    }

    private func requireOtherApp(_ window: SwitchableWindow) throws {
        guard system.isTrusted else {
            throw LibraryValidationError(
                "Allow OpenRay in System Settings → Privacy & Security → Accessibility to switch windows.")
        }
        guard window.snapshot.pid != system.ownPID, system.isRunning(window.snapshot.pid) else {
            throw LibraryValidationError("That window's app has quit.")
        }
    }
}
