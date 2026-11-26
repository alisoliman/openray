import AppKit
@preconcurrency import ApplicationServices

enum WindowLayout: String, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, maximize, center
    case topLeft, topRight, bottomLeft, bottomRight, nextDisplay, restore
    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .maximize: "Maximize"
        case .center: "Center"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .nextDisplay: "Next Display"
        case .restore: "Restore"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .maximize: "arrow.up.left.and.arrow.down.right"
        case .center: "rectangle.center.inset.filled"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: "rectangle.split.2x2"
        case .nextDisplay: "display.2"
        case .restore: "arrow.uturn.backward"
        }
    }

    /// Input and output are in AppKit's bottom-left screen coordinate system.
    /// The original geometry, kept exactly: no rounding, and Next Display fills the given screen.
    func frame(in screen: CGRect, current: CGRect) -> CGRect {
        switch self {
        case .leftHalf: CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .rightHalf: CGRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .topHalf: CGRect(x: screen.minX, y: screen.midY, width: screen.width, height: screen.height / 2)
        case .bottomHalf: CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height / 2)
        case .topLeft: CGRect(x: screen.minX, y: screen.midY, width: screen.width / 2, height: screen.height / 2)
        case .topRight: CGRect(x: screen.midX, y: screen.midY, width: screen.width / 2, height: screen.height / 2)
        case .bottomLeft: CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height / 2)
        case .bottomRight: CGRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height / 2)
        case .maximize, .nextDisplay: screen
        case .center:
            CGRect(
                x: screen.midX - min(current.width, screen.width) / 2,
                y: screen.midY - min(current.height, screen.height) / 2,
                width: min(current.width, screen.width), height: min(current.height, screen.height))
        case .restore: current
        }
    }
}

enum ScreenCoordinates {
    /// The AX origin is the top-left of the primary display, including for secondary displays.
    static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

struct WindowFramePlan {
    let current: CGRect
    let target: CGRect
    var movesPosition: Bool { current.origin != target.origin }
    var changesSize: Bool { current.size != target.size }

    func canApply(movable: Bool, resizable: Bool) -> Bool {
        (!movesPosition || movable) && (!changesSize || resizable)
    }
}

// MARK: - Window system

/// Another app's window: an Accessibility element in the app, a plain token in tests.
/// AXUIElement is an immutable reference that Accessibility accepts from any thread.
struct WindowHandle: Hashable, @unchecked Sendable {
    let pid: pid_t
    let token: Int
    let element: AXUIElement?

    init(pid: pid_t, element: AXUIElement) {
        self.pid = pid
        self.element = element
        token = Int(bitPattern: CFHash(element))
    }

    init(pid: pid_t, token: Int) {
        self.pid = pid
        self.token = token
        element = nil
    }

    static func == (lhs: WindowHandle, rhs: WindowHandle) -> Bool {
        guard lhs.pid == rhs.pid, lhs.token == rhs.token else { return false }
        switch (lhs.element, rhs.element) {
        case (nil, nil): return true
        case let (left?, right?): return CFEqual(left, right)
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(token)
    }
}

/// A display, in AppKit coordinates. The primary display comes first.
struct DisplaySnapshot: Equatable, Sendable {
    var id: UInt32
    var name: String
    var frame: CGRect
    /// The frame without the menu bar and the Dock.
    var visibleFrame: CGRect
}

/// A window of another app as Accessibility reports it.
struct WindowSnapshot: Equatable, Sendable {
    var handle: WindowHandle
    var appName: String
    var bundleIdentifier: String?
    var bundleURL: URL?
    var title: String
    /// AppKit coordinates. Nil when the listing skipped frames or the app didn't report one.
    var frame: CGRect?
    var isMinimized: Bool

    var pid: pid_t { handle.pid }
}

/// Everything window commands, layouts and the window switcher do to other apps.
/// `AXWindowSystem` is the real one; inert launches get `InertWindowSystem`, and
/// tests use a fake.
@MainActor
protocol WindowSystem: AnyObject {
    var isTrusted: Bool { get }
    var ownPID: pid_t { get }
    func requestTrust()
    func displays() -> [DisplaySnapshot]
    /// Standard windows of other running apps, grouped by app name and front to back within each app.
    /// `readFrames: false` keeps title-only listings to one round trip per window.
    func windows(includeMinimized: Bool, readFrames: Bool) -> [WindowSnapshot]
    func focusedWindow(of pid: pid_t) -> WindowHandle?
    func isRunning(_ pid: pid_t) -> Bool
    func title(of window: WindowHandle) -> String?
    /// AppKit coordinates.
    func frame(of window: WindowHandle) throws -> CGRect
    func setFrame(_ frame: CGRect, of window: WindowHandle) throws
    func isFullScreen(_ window: WindowHandle) -> Bool?
    func setFullScreen(_ fullScreen: Bool, of window: WindowHandle) throws
    func setMinimized(_ minimized: Bool, of window: WindowHandle) throws
    /// Raises the window and activates its app. Throws when either doesn't happen.
    func focus(_ window: WindowHandle) throws
    func close(_ window: WindowHandle) throws
    func hideApplication(_ pid: pid_t) throws
}

enum WindowSystemEnvironment {
    /// Accessibility in a normal launch; an inert system in the test host and in
    /// isolated verification mode.
    static func makeSystem(sideEffects: SideEffectGuard = .current) -> any WindowSystem {
        sideEffects.isInert ? InertWindowSystem(sideEffects: sideEffects) : AXWindowSystem(sideEffects: sideEffects)
    }

    /// The window server's on-screen list in a normal launch; empty in inert launches.
    static func makeListing(sideEffects: SideEffectGuard = .current) -> any WindowServerListing {
        sideEffects.isInert ? InertWindowServerListing() : CGWindowServerListing()
    }
}

/// Sees no windows and refuses every change. The default in inert launches.
@MainActor
final class InertWindowSystem: WindowSystem {
    let sideEffects: SideEffectGuard

    nonisolated init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    var isTrusted: Bool { false }
    var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }
    func requestTrust() {}
    func displays() -> [DisplaySnapshot] { [] }
    func windows(includeMinimized: Bool, readFrames: Bool) -> [WindowSnapshot] { [] }
    func focusedWindow(of pid: pid_t) -> WindowHandle? { nil }
    func isRunning(_ pid: pid_t) -> Bool { false }
    func title(of window: WindowHandle) -> String? { nil }
    func frame(of window: WindowHandle) throws -> CGRect { throw refusal("reading other apps' windows") }
    func setFrame(_ frame: CGRect, of window: WindowHandle) throws { throw refusal("moving a window") }
    func isFullScreen(_ window: WindowHandle) -> Bool? { nil }
    func setFullScreen(_ fullScreen: Bool, of window: WindowHandle) throws { throw refusal("changing full screen") }
    func setMinimized(_ minimized: Bool, of window: WindowHandle) throws { throw refusal("minimizing a window") }
    func focus(_ window: WindowHandle) throws { throw refusal("focusing a window") }
    func close(_ window: WindowHandle) throws { throw refusal("closing a window") }
    func hideApplication(_ pid: pid_t) throws { throw refusal("hiding an app") }

    private func refusal(_ what: String) -> SideEffectGuard.Blocked {
        SideEffectGuard.Blocked(what: what, mode: sideEffects.mode)
    }
}

/// The real window system, through the Accessibility API. Every change checks
/// its `SideEffectGuard` before touching the window.
@MainActor
final class AXWindowSystem: WindowSystem {
    /// Listing asks every app; one that's hung must not stall the launcher for AX's default six seconds.
    private static let listingTimeout: Float = 0.25
    private static let fullScreenAttribute = "AXFullScreen"

    let sideEffects: SideEffectGuard

    nonisolated init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    var isTrusted: Bool { AXIsProcessTrusted() }
    var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    func requestTrust() {
        guard !sideEffects.isInert else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func displays() -> [DisplaySnapshot] {
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return DisplaySnapshot(
                id: number?.uint32Value ?? 0, name: screen.localizedName, frame: screen.frame,
                visibleFrame: screen.visibleFrame)
        }
    }

    func windows(includeMinimized: Bool, readFrames: Bool) -> [WindowSnapshot] {
        guard isTrusted else { return [] }
        let ownPID = ownPID
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }.sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        let primaryHeight = Self.primaryHeight
        var windows: [WindowSnapshot] = []
        for application in applications {
            let element = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(element, Self.listingTimeout)
            guard let elements = attribute(kAXWindowsAttribute, of: element) as? [AXUIElement] else { continue }
            for window in elements {
                AXUIElementSetMessagingTimeout(window, Self.listingTimeout)
                guard attribute(kAXSubroleAttribute, of: window) as? String == kAXStandardWindowSubrole else {
                    continue
                }
                let minimized = attribute(kAXMinimizedAttribute, of: window) as? Bool == true
                if minimized && !includeMinimized { continue }
                let axFrame = readFrames ? try? readFrame(window) : nil
                windows.append(
                    WindowSnapshot(
                        handle: WindowHandle(pid: application.processIdentifier, element: window),
                        appName: application.localizedName ?? "App", bundleIdentifier: application.bundleIdentifier,
                        bundleURL: application.bundleURL,
                        title: attribute(kAXTitleAttribute, of: window) as? String ?? "",
                        frame: axFrame.map { ScreenCoordinates.flip($0, primaryHeight: primaryHeight) },
                        isMinimized: minimized))
            }
        }
        return windows
    }

    func focusedWindow(of pid: pid_t) -> WindowHandle? {
        let element = AXUIElementCreateApplication(pid)
        guard let value = attribute(kAXFocusedWindowAttribute, of: element),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return WindowHandle(pid: pid, element: unsafeDowncast(value, to: AXUIElement.self))
    }

    func isRunning(_ pid: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return false }
        return !application.isTerminated
    }

    func title(of window: WindowHandle) -> String? {
        guard let element = window.element else { return nil }
        return attribute(kAXTitleAttribute, of: element) as? String
    }

    func frame(of window: WindowHandle) throws -> CGRect {
        let element = try element(of: window)
        // A window from the listing keeps the short listing timeout; a resize gets AX's default (0).
        AXUIElementSetMessagingTimeout(element, 0)
        return ScreenCoordinates.flip(try readFrame(element), primaryHeight: Self.primaryHeight)
    }

    func setFrame(_ frame: CGRect, of window: WindowHandle) throws {
        try sideEffects.check("moving a window")
        let element = try element(of: window)
        let current = try readFrame(element)
        try writeFrame(ScreenCoordinates.flip(frame, primaryHeight: Self.primaryHeight), from: current, to: element)
    }

    func isFullScreen(_ window: WindowHandle) -> Bool? {
        guard let element = window.element else { return nil }
        return attribute(Self.fullScreenAttribute, of: element) as? Bool
    }

    func setFullScreen(_ fullScreen: Bool, of window: WindowHandle) throws {
        try sideEffects.check("changing full screen")
        let element = try element(of: window)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, Self.fullScreenAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { throw LibraryValidationError("This window can't enter full screen.") }
        guard
            AXUIElementSetAttributeValue(
                element, Self.fullScreenAttribute as CFString, (fullScreen ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
                == .success
        else { throw LibraryValidationError("This app did not allow the window to change full screen.") }
    }

    func setMinimized(_ minimized: Bool, of window: WindowHandle) throws {
        try sideEffects.check("minimizing a window")
        let element = try element(of: window)
        guard
            AXUIElementSetAttributeValue(
                element, kAXMinimizedAttribute as CFString, (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
                == .success
        else { throw LibraryValidationError("This app did not allow the window to be minimized.") }
    }

    func focus(_ window: WindowHandle) throws {
        try sideEffects.check("focusing a window")
        let element = try element(of: window)
        guard let application = NSRunningApplication(processIdentifier: window.pid), !application.isTerminated else {
            throw LibraryValidationError("That window's app has quit. Choose another window and try again.")
        }
        let name = application.localizedName ?? "The app"
        // A chosen window can sit behind the app's focused one; bring it forward with the app.
        switch AXUIElementPerformAction(element, kAXRaiseAction as CFString) {
        case .success: break
        case .invalidUIElement:
            throw LibraryValidationError("This window has closed. Choose another window and try again.")
        default:
            throw LibraryValidationError("\(name) didn't bring that window forward.")
        }
        guard application.activate() else { throw LibraryValidationError("\(name) didn't come to the front.") }
    }

    func close(_ window: WindowHandle) throws {
        try sideEffects.check("closing a window")
        let element = try element(of: window)
        guard let button = attribute(kAXCloseButtonAttribute, of: element),
            CFGetTypeID(button) == AXUIElementGetTypeID(),
            AXUIElementPerformAction(unsafeDowncast(button, to: AXUIElement.self), kAXPressAction as CFString)
                == .success
        else { throw LibraryValidationError("This window can't be closed from OpenRay.") }
    }

    func hideApplication(_ pid: pid_t) throws {
        try sideEffects.check("hiding an app")
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            throw LibraryValidationError("That app has quit.")
        }
        application.hide()
    }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    private func element(of window: WindowHandle) throws -> AXUIElement {
        guard let element = window.element else {
            throw LibraryValidationError("This window has closed. Choose another window and try again.")
        }
        return element
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        AXWindowReading.attribute(name, of: element)
    }

    private func readFrame(_ window: AXUIElement) throws -> CGRect {
        try AXWindowReading.frame(of: window)
    }
}

/// Accessibility reads shared by the main-actor window system and the background snapshot reader.
enum AXWindowReading {
    static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// The window's frame in Accessibility's top-left coordinates.
    static func frame(of window: AXUIElement) throws -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let position = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        // A window chosen earlier may have closed since.
        if position == .invalidUIElement {
            throw LibraryValidationError("This window has closed. Choose another window and try again.")
        }
        guard position == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            throw LibraryValidationError("This window does not support positioning.")
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &point),
            AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        else {
            throw LibraryValidationError("The window frame could not be read.")
        }
        return CGRect(origin: point, size: size)
    }
}

extension AXWindowSystem {
    fileprivate func writeFrame(_ rect: CGRect, from current: CGRect, to window: AXUIElement) throws {
        let plan = WindowFramePlan(current: current, target: rect)
        if !plan.movesPosition && !plan.changesSize { return }
        var movable: DarwinBoolean = false
        var resizable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
        _ = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable)
        guard plan.canApply(movable: movable.boolValue, resizable: resizable.boolValue) else {
            throw LibraryValidationError(
                "This window does not support the requested layout. Fixed-size windows can still be centered or moved when positioning is allowed."
            )
        }
        var position = rect.origin
        var size = rect.size
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            throw LibraryValidationError("The requested layout is invalid.")
        }
        // Moving between differently sized displays may constrain the first size change.
        if plan.changesSize { _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) }
        let moved =
            plan.movesPosition
            ? AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) : .success
        let resized =
            plan.changesSize ? AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) : .success
        guard moved == .success, resized == .success else {
            throw LibraryValidationError(
                "This app did not allow the window to move or resize. Full-screen and fixed-size windows may not support this layout."
            )
        }
    }
}

// MARK: - Window manager

@MainActor
final class WindowManager {
    /// A window in another app that layouts can target, read through Accessibility
    /// so titles don't need Screen Recording access.
    struct TargetWindow: Identifiable, Equatable {
        let pid: pid_t
        let appName: String
        let bundleURL: URL?
        let element: AXUIElement
        let title: String
        var id: String { "\(pid).\(CFHash(element))" }
    }

    struct Settings: Equatable, Sendable {
        var gaps = WindowGaps.zero
        /// Repeating a half command steps through 1/2, 2/3 and 1/3.
        var cyclesHalves = false
    }

    let system: any WindowSystem
    /// The window server's on-screen list, to tell visible windows from hidden or off-Space ones.
    let listing: any WindowServerListing
    var settings = Settings()
    /// Frames from before the first command, for Restore.
    private var originalFrames: [WindowHandle: CGRect] = [:]

    init(
        system: any WindowSystem = WindowSystemEnvironment.makeSystem(),
        listing: any WindowServerListing = WindowSystemEnvironment.makeListing()
    ) {
        self.system = system
        self.listing = listing
    }

    var hasPermission: Bool { system.isTrusted }

    func requestPermission() { system.requestTrust() }

    /// Standard, unminimized windows of other running apps, grouped by app name
    /// and front to back within each app. Empty without Accessibility access.
    /// Reads titles only, so it stays light.
    func listWindows() -> [TargetWindow] {
        guard hasPermission else { return [] }
        return system.windows(includeMinimized: false, readFrames: false).compactMap { window in
            guard let element = window.handle.element else { return nil }
            return TargetWindow(
                pid: window.pid, appName: window.appName, bundleURL: window.bundleURL, element: element,
                title: window.title)
        }
    }

    /// Arranges the focused window of the app you came from.
    func arrange(_ layout: WindowLayout, application: NSRunningApplication?) throws {
        try perform(layout.command, application: application)
    }

    /// Arranges a specific window, such as one chosen from listWindows().
    func arrange(_ layout: WindowLayout, window: AXUIElement, pid: pid_t) throws {
        try perform(layout.command, on: WindowHandle(pid: pid, element: window))
    }

    /// Runs a command on the focused window of the app you came from.
    func perform(_ command: WindowCommand, application: NSRunningApplication?) throws {
        try perform(command, focusedWindowOf: application.flatMap { $0.isTerminated ? nil : $0.processIdentifier })
    }

    func perform(_ command: WindowCommand, focusedWindowOf pid: pid_t?) throws {
        try perform(focusedWindowOf: pid) { try perform(command, on: $0) }
    }

    func perform(_ custom: CustomWindowCommand, focusedWindowOf pid: pid_t?) throws {
        try custom.validate()
        try perform(focusedWindowOf: pid) { try perform(custom, on: $0) }
    }

    /// Runs a command on a specific window. With default settings the original
    /// twelve commands keep their original geometry and display order.
    func perform(_ command: WindowCommand, on window: WindowHandle) throws {
        try requireWindow(window)
        switch command {
        case .minimize:
            try system.setMinimized(true, of: window)
            return
        case .toggleFullscreen:
            let fullScreen = system.isFullScreen(window) ?? false
            try system.setFullScreen(!fullScreen, of: window)
            try? system.focus(window)
            return
        default: break
        }
        let current = try system.frame(of: window)
        let displays = system.displays()
        guard let index = DisplayArrangement.index(of: current, in: displays.map(\.frame)) else {
            throw LibraryValidationError("No display is available.")
        }
        let screen = displays[index].visibleFrame
        let desired: CGRect
        switch command {
        case .restore:
            guard let original = originalFrames[window] else {
                throw LibraryValidationError("There is no previous layout to restore for this window.")
            }
            desired = original
        case .nextDisplay, .previousDisplay:
            guard
                let target = DisplayArrangement.adjacent(
                    to: index, count: displays.count, forward: command == .nextDisplay)
            else { throw LibraryValidationError("Connect another display to move this window.") }
            let targetScreen = displays[target].visibleFrame
            desired =
                settings.gaps == WindowGaps.zero
                ? WindowLayout.center.frame(in: targetScreen, current: current)
                : WindowGeometry.centered(current.size, in: WindowGeometry.usableArea(targetScreen, gaps: settings.gaps))
        default:
            let cycled =
                settings.cyclesHalves && command.cycles
                ? HalfCycling.frame(for: command, in: screen, current: current, gaps: settings.gaps) : nil
            guard
                let frame = cycled
                    ?? WindowGeometry.frame(for: command, in: screen, current: current, gaps: settings.gaps)
            else { throw LibraryValidationError("This command doesn't move windows.") }
            desired = frame
        }
        try apply(desired, to: window, from: current, restoring: command == .restore)
    }

    /// Exact Move, Exact Resize and custom commands. Invalid input and sizes the
    /// display can't hold fail before anything moves; an app that clamps the
    /// request is reported instead of passing for success.
    func perform(_ custom: CustomWindowCommand, on window: WindowHandle) throws {
        try custom.validate()
        try requireWindow(window)
        let current = try system.frame(of: window)
        let displays = system.displays()
        guard let index = DisplayArrangement.index(of: current, in: displays.map(\.frame)) else {
            throw LibraryValidationError("No display is available.")
        }
        let desired = try custom.frame(in: displays[index].visibleFrame, current: current)
        try apply(desired, to: window, from: current)
        let actual = try system.frame(of: window)
        if abs(actual.width - desired.width) > 1 || abs(actual.height - desired.height) > 1 {
            throw LibraryValidationError(
                "The app limited the window to \(Int(actual.width.rounded())) × \(Int(actual.height.rounded())) points.")
        }
        if abs(actual.minX - desired.minX) > 1 || abs(actual.minY - desired.minY) > 1 {
            throw LibraryValidationError("The app kept the window in a different position.")
        }
    }

    /// The title of the window a layout will apply to, when Accessibility allows reading it.
    func focusedWindowTitle(of application: NSRunningApplication?) -> String? {
        guard hasPermission, let application, !application.isTerminated,
            let window = system.focusedWindow(of: application.processIdentifier),
            let title = system.title(of: window), !title.isEmpty
        else { return nil }
        return title
    }

    // MARK: Layouts

    /// Windows on screen right now, front to back: the Accessibility list checked
    /// against the window server, so hidden apps and other Spaces drop out.
    func visibleWindows() -> [WindowSnapshot] {
        let primaryHeight = system.displays().first?.frame.maxY ?? 0
        return WindowSwitcherOrdering.order(
            system.windows(includeMinimized: false, readFrames: true), entries: listing.onScreenWindows(),
            primaryHeight: primaryHeight
        ).filter(\.isOnScreen).map(\.snapshot)
    }

    /// Save Current Layout: the windows on screen, front to back, as a draft to name and edit.
    func captureLayout(named name: String) throws -> SavedWindowLayout {
        try requirePermission()
        let layout = WindowLayoutPlanner.capture(named: name, displays: system.displays(), windows: visibleWindows())
        guard !layout.slots.isEmpty else { throw LibraryValidationError("There are no windows to save.") }
        return layout
    }

    /// Places every window a layout lists, launching apps that have no window yet
    /// and waiting up to `launchTimeout` for their windows. Cancellation stops it
    /// before the next launch, wait or move. Other windows are minimized or closed
    /// only on displays where a window was placed, and only when the window
    /// server confirms they are on screen.
    func apply(
        _ layout: SavedWindowLayout, launcher: any ApplicationLaunching,
        launchTimeout: Duration = .seconds(6), pollInterval: Duration = .milliseconds(250),
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> WindowLayoutOutcome {
        try requirePermission()
        try layout.validate()
        try Task.checkCancellation()
        var plan = currentPlan(for: layout)
        if !plan.launches.isEmpty {
            for bundleIdentifier in plan.launches {
                try Task.checkCancellation()
                // A failed launch leaves its slots missing; the rest still apply.
                try? await launcher.launch(bundleIdentifier: bundleIdentifier)
            }
            var waited = Duration.zero
            while !plan.unmatchedSlots.isEmpty && waited < launchTimeout {
                try Task.checkCancellation()
                try await sleep(pollInterval)
                waited += pollInterval
                plan = currentPlan(for: layout)
            }
        }
        try Task.checkCancellation()
        let displays = system.displays()
        var placed: [WindowLayoutPlan.Move] = []
        var failedSlots = Set<UUID>()
        for move in plan.moves {
            try Task.checkCancellation()
            do {
                if move.unminimize { try system.setMinimized(false, of: move.window) }
                let current = try system.frame(of: move.window)
                try apply(move.frame, to: move.window, from: current, focus: false)
                // An app can accept the write and keep the window where it was. Only a window
                // that really ended up on its display counts, and only that can clear the display.
                let actual = try system.frame(of: move.window)
                guard displays.indices.contains(move.displayIndex),
                    DisplayArrangement.index(of: actual, in: displays.map(\.frame)) == move.displayIndex,
                    !displays[move.displayIndex].frame.intersection(actual).isNull
                else {
                    failedSlots.insert(move.slotID)
                    continue
                }
                placed.append(move)
            } catch let error as SideEffectGuard.Blocked {
                throw error
            } catch {
                failedSlots.insert(move.slotID)
            }
        }
        var cleanupFailures = 0
        if layout.otherWindows != .leave && !placed.isEmpty {
            // A superseded or cancelled apply must never touch windows another layout placed.
            try Task.checkCancellation()
            let targets = WindowLayoutPlanner.cleanupTargets(
                visible: visibleWindows(), claimed: Set(plan.moves.map(\.window)), displays: displays,
                placedDisplays: Set(placed.map(\.displayIndex)))
            for window in targets {
                try Task.checkCancellation()
                do {
                    switch layout.otherWindows {
                    case .leave: break
                    case .minimize: try system.setMinimized(true, of: window)
                    case .close: try system.close(window)
                    }
                } catch {
                    cleanupFailures += 1
                }
            }
        }
        // The first slot is the frontmost, so raise the rest first.
        for move in placed.reversed() { try? system.focus(move.window) }
        let unmatched = Set(plan.unmatchedSlots)
        return WindowLayoutOutcome(
            requested: layout.slots.count, placed: placed.count,
            missing: Self.uniqueNames(layout.slots.filter { unmatched.contains($0.id) }),
            failed: Self.uniqueNames(layout.slots.filter { failedSlots.contains($0.id) }),
            cleanupFailures: cleanupFailures)
    }

    private func currentPlan(for layout: SavedWindowLayout) -> WindowLayoutPlan {
        WindowLayoutPlanner.plan(
            layout, displays: system.displays(), windows: system.windows(includeMinimized: true, readFrames: false))
    }

    private static func uniqueNames(_ slots: [SavedWindowLayout.Slot]) -> [String] {
        var names: [String] = []
        for slot in slots where !names.contains(slot.appName) { names.append(slot.appName) }
        return names
    }

    // MARK: Text

    func selectedText(in application: NSRunningApplication?) throws -> String {
        guard hasPermission else {
            throw LibraryValidationError(
                "Accessibility access is required to read selected text. You can paste text manually instead.")
        }
        guard let application else { throw LibraryValidationError("Select text in another app first.") }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            throw LibraryValidationError("The active app does not expose selected text.")
        }
        var text: CFTypeRef?
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &text) == .success,
            let text = text as? String, !text.isEmpty
        else { throw LibraryValidationError("No text is selected in the previous app.") }
        return text
    }

    // MARK: Helpers

    private func perform(focusedWindowOf pid: pid_t?, _ body: (WindowHandle) throws -> Void) throws {
        try requirePermission()
        guard let pid, pid != system.ownPID, system.isRunning(pid) else {
            throw LibraryValidationError("Focus a window in another app, then open OpenRay and try again.")
        }
        guard let window = system.focusedWindow(of: pid) else {
            throw LibraryValidationError("This app has no accessible focused window.")
        }
        try body(window)
    }

    private func requireWindow(_ window: WindowHandle) throws {
        try requirePermission()
        guard window.pid != system.ownPID, system.isRunning(window.pid) else {
            throw LibraryValidationError("That window's app has quit. Choose another window and try again.")
        }
    }

    private func apply(
        _ desired: CGRect, to window: WindowHandle, from current: CGRect, restoring: Bool = false, focus: Bool = true
    ) throws {
        // Preserve the first original frame, not the result of the last tiling command.
        if originalFrames[window] == nil { originalFrames[window] = current }
        try system.setFrame(desired, of: window)
        if restoring { originalFrames.removeValue(forKey: window) }
        if focus { try? system.focus(window) }
    }

    private func requirePermission() throws {
        guard hasPermission else {
            throw LibraryValidationError(
                "Allow OpenRay in System Settings → Privacy & Security → Accessibility to arrange windows.")
        }
    }
}
