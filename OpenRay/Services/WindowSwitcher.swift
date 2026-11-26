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

/// Lists nothing. The default in inert launches, so tests never read the real window list.
@MainActor
final class InertWindowServerListing: WindowServerListing {
    nonisolated init() {}
    func onScreenWindows() -> [WindowServerEntry] { [] }
}

@MainActor
final class CGWindowServerListing: WindowServerListing {
    nonisolated init() {}

    func onScreenWindows() -> [WindowServerEntry] { Self.read() }

    /// The window server's list, front to back. Safe off the main actor.
    nonisolated static func read() -> [WindowServerEntry] {
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
struct SwitchableWindow: Identifiable, Equatable, Sendable {
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

/// How Accessibility windows pair with the window server's on-screen entries. A window and an
/// entry fit when they belong to the same process and their bounds agree within two points.
struct WindowServerJoin: Equatable, Sendable {
    struct Pairing: Equatable, Sendable {
        /// The entry's place in the window server's list, front to back.
        var rank: Int
        var number: UInt32
    }

    /// Windows certainly on screen in the current Space, by index, with their entry.
    var onScreen: [Int: Pairing] = [:]
    /// Windows paired one to one: exactly one entry fits the window, and that entry fits no
    /// other window. Only these can stand for "this window is on screen here" when a wrong
    /// guess would act on another window.
    var unambiguous: Set<Int> = []

    static let tolerance: CGFloat = 2

    /// Windows and entries that fit each other form groups. Every on-screen entry is some
    /// window's, so a group with as many windows as entries, which pair up completely, is on
    /// screen as a whole. A group with more windows than entries holds one somewhere else (two
    /// same-sized windows of an app on different Spaces) and nothing says which: all of its
    /// windows are left out. Counting nearby entries can't overstate a group, because a group
    /// only grows through entries that fit one of its windows.
    init(_ windows: [WindowSnapshot], entries: [WindowServerEntry], primaryHeight: CGFloat) {
        let normal = entries.filter { $0.layer == 0 }
        let flipped = windows.map { window -> CGRect? in
            guard !window.isMinimized, let frame = window.frame else { return nil }
            return ScreenCoordinates.flip(frame, primaryHeight: primaryHeight)
        }
        func distance(_ window: Int, _ entry: Int) -> CGFloat {
            guard let frame = flipped[window] else { return .infinity }
            let bounds = normal[entry].bounds
            let origin: CGFloat = abs(frame.minX - bounds.minX) + abs(frame.minY - bounds.minY)
            let size: CGFloat = abs(frame.width - bounds.width) + abs(frame.height - bounds.height)
            return origin + size
        }
        var windowEdges = [[Int]](repeating: [], count: windows.count)
        var entryEdges = [[Int]](repeating: [], count: normal.count)
        for window in windows.indices {
            guard let frame = flipped[window] else { continue }
            for entry in normal.indices where normal[entry].pid == windows[window].pid
                && WindowGeometry.approximatelyEqual(frame, normal[entry].bounds, tolerance: Self.tolerance)
            {
                windowEdges[window].append(entry)
                entryEdges[entry].append(window)
            }
        }
        // Each entry tries its closest window first, so near neighbors keep their own entries.
        for entry in normal.indices {
            entryEdges[entry].sort { lhs, rhs in
                let left = distance(lhs, entry)
                let right = distance(rhs, entry)
                return left != right ? left < right : lhs < rhs
            }
        }

        var seenWindows = Set<Int>()
        var seenEntries = Set<Int>()
        for start in windows.indices where !windowEdges[start].isEmpty && seenWindows.insert(start).inserted {
            var groupWindows: [Int] = []
            var groupEntries: [Int] = []
            var stack: [(isWindow: Bool, index: Int)] = [(true, start)]
            while let next = stack.popLast() {
                let (isWindow, index) = next
                if isWindow {
                    groupWindows.append(index)
                    for entry in windowEdges[index] where seenEntries.insert(entry).inserted { stack.append((false, entry)) }
                } else {
                    groupEntries.append(index)
                    for window in entryEdges[index] where seenWindows.insert(window).inserted { stack.append((true, window)) }
                }
            }
            guard groupWindows.count == groupEntries.count,
                let pairs = Self.pair(entries: groupEntries.sorted(), edges: entryEdges)
            else { continue }
            for (window, entry) in pairs { onScreen[window] = Pairing(rank: entry, number: normal[entry].number) }
            if groupWindows.count == 1 { unambiguous.insert(groupWindows[0]) }
        }
    }

    /// A complete pairing of `entries` with distinct windows, or nil when there's none.
    private static func pair(entries: [Int], edges: [[Int]]) -> [Int: Int]? {
        var owner: [Int: Int] = [:]  // window → entry
        func claim(_ entry: Int, _ visited: inout Set<Int>) -> Bool {
            for window in edges[entry] where visited.insert(window).inserted {
                if let other = owner[window], !claim(other, &visited) { continue }
                owner[window] = entry
                return true
            }
            return false
        }
        for entry in entries {
            var visited = Set<Int>()
            guard claim(entry, &visited) else { return nil }
        }
        return owner
    }
}

enum WindowSwitcherOrdering {
    /// On-screen windows first, front to back as the window server stacks them;
    /// then windows in other Spaces; then minimized ones. Ties keep their order.
    static func order(
        _ windows: [WindowSnapshot], entries: [WindowServerEntry], primaryHeight: CGFloat
    ) -> [SwitchableWindow] {
        let join = WindowServerJoin(windows, entries: entries, primaryHeight: primaryHeight)
        let onScreen = join.onScreen.sorted { $0.value.rank < $1.value.rank }.map { paired in
            SwitchableWindow(snapshot: windows[paired.key], windowNumber: paired.value.number)
        }
        let remaining = windows.indices.filter { join.onScreen[$0] == nil }.map { windows[$0] }
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

    init(
        system: any WindowSystem = WindowSystemEnvironment.makeSystem(),
        listing: any WindowServerListing = WindowSystemEnvironment.makeListing()
    ) {
        self.system = system
        self.listing = listing
    }

    var hasPermission: Bool { system.isTrusted }

    /// Every window of other apps, most recently stacked first. Empty without Accessibility access.
    func windows() -> [SwitchableWindow] {
        guard system.isTrusted else { return [] }
        let primaryHeight = system.displays().first?.frame.maxY ?? 0
        return WindowSwitcherOrdering.order(
            system.windows(includeMinimized: true, readFrames: true), entries: listing.onScreenWindows(),
            primaryHeight: primaryHeight)
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

    /// Acts on the window where it is, without switching to it first.
    func toggleFullScreen(_ window: SwitchableWindow) throws {
        try requireOtherApp(window)
        if window.isMinimized { try system.setMinimized(false, of: window.handle) }
        try system.setFullScreen(!(system.isFullScreen(window.handle) ?? false), of: window.handle)
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

// MARK: - Background snapshots

/// An app to read windows from, gathered on the main actor.
struct WindowAppRecord: Equatable, Sendable {
    var pid: pid_t
    var name: String
    var bundleIdentifier: String?
    var bundleURL: URL?
}

/// Reads windows for Switch Windows off the main actor. `AXWindowSnapshotSource` is the real
/// one; inert launches get an empty one, and tests use fakes.
protocol WindowSnapshotSource: Sendable {
    var isTrusted: Bool { get }
    /// Regular apps other than OpenRay, by name.
    @MainActor func applications() -> [WindowAppRecord]
    /// Standard windows of these apps, front to back within each, stopping when `shouldStop` says so.
    func windows(
        of apps: [WindowAppRecord], includeMinimized: Bool, primaryHeight: CGFloat, shouldStop: () -> Bool
    ) -> [WindowSnapshot]
    func onScreenWindows() -> [WindowServerEntry]
}

extension WindowSystemEnvironment {
    /// Accessibility in a normal launch; nothing in inert launches.
    static func makeSnapshotSource(sideEffects: SideEffectGuard = .current) -> any WindowSnapshotSource {
        sideEffects.effective.isInert ? InertWindowSnapshotSource() : AXWindowSnapshotSource()
    }
}

final class InertWindowSnapshotSource: WindowSnapshotSource {
    init() {}
    var isTrusted: Bool { false }
    @MainActor func applications() -> [WindowAppRecord] { [] }
    func windows(
        of apps: [WindowAppRecord], includeMinimized: Bool, primaryHeight: CGFloat, shouldStop: () -> Bool
    ) -> [WindowSnapshot] { [] }
    func onScreenWindows() -> [WindowServerEntry] { [] }
}

/// The real snapshot: Accessibility for titles, the window server for stacking.
final class AXWindowSnapshotSource: WindowSnapshotSource {
    /// One hung app costs at most this per call, and the read as a whole has its own budget.
    private static let timeout: Float = 0.25

    init() {}

    var isTrusted: Bool { AXIsProcessTrusted() }

    @MainActor func applications() -> [WindowAppRecord] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }.sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
            .map {
                WindowAppRecord(
                    pid: $0.processIdentifier, name: $0.localizedName ?? "App", bundleIdentifier: $0.bundleIdentifier,
                    bundleURL: $0.bundleURL)
            }
    }

    func windows(
        of apps: [WindowAppRecord], includeMinimized: Bool, primaryHeight: CGFloat, shouldStop: () -> Bool
    ) -> [WindowSnapshot] {
        guard isTrusted else { return [] }
        var windows: [WindowSnapshot] = []
        for app in apps {
            guard !shouldStop() else { break }
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, Self.timeout)
            guard let elements = AXWindowReading.attribute(kAXWindowsAttribute, of: element) as? [AXUIElement] else {
                continue
            }
            for window in elements {
                guard !shouldStop() else { break }
                AXUIElementSetMessagingTimeout(window, Self.timeout)
                guard AXWindowReading.attribute(kAXSubroleAttribute, of: window) as? String == kAXStandardWindowSubrole
                else { continue }
                let minimized = AXWindowReading.attribute(kAXMinimizedAttribute, of: window) as? Bool == true
                if minimized && !includeMinimized { continue }
                let frame = (try? AXWindowReading.frame(of: window)).map {
                    ScreenCoordinates.flip($0, primaryHeight: primaryHeight)
                }
                windows.append(
                    WindowSnapshot(
                        handle: WindowHandle(pid: app.pid, element: window), appName: app.name,
                        bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL,
                        title: AXWindowReading.attribute(kAXTitleAttribute, of: window) as? String ?? "", frame: frame,
                        isMinimized: minimized))
            }
        }
        return windows
    }

    func onScreenWindows() -> [WindowServerEntry] { CGWindowServerListing.read() }
}

/// Reads Switch Windows' snapshot on its own serial queue, so unresponsive apps can't hold
/// the launcher. A read stops when its task is cancelled or its time budget runs out.
final class WindowSnapshotReader: Sendable {
    let source: any WindowSnapshotSource
    private let queue = DispatchQueue(label: "app.openray.window-snapshot-reader", qos: .userInitiated)

    init(source: any WindowSnapshotSource) {
        self.source = source
    }

    /// The apps' windows, ordered by the window server. Throws CancellationError when cancelled.
    func windows(
        of apps: [WindowAppRecord], primaryHeight: CGFloat, timeBudget: Duration = .seconds(2)
    ) async throws -> [SwitchableWindow] {
        let flag = BackgroundReadCancellation()
        let source = source
        let queue = queue
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SwitchableWindow], any Error>) in
                queue.async {
                    let start = ContinuousClock.now
                    let snapshots = source.windows(
                        of: apps, includeMinimized: true, primaryHeight: primaryHeight,
                        shouldStop: { flag.isSet || ContinuousClock.now - start > timeBudget })
                    guard !flag.isSet else { return continuation.resume(throwing: CancellationError()) }
                    let entries = source.onScreenWindows()
                    guard !flag.isSet else { return continuation.resume(throwing: CancellationError()) }
                    continuation.resume(
                        returning: WindowSwitcherOrdering.order(snapshots, entries: entries, primaryHeight: primaryHeight))
                }
            }
        } onCancel: {
            flag.set()
        }
    }
}
