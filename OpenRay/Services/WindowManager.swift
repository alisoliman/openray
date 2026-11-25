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
    func frame(in screen: CGRect, current: CGRect) -> CGRect {
        WindowGeometry.frame(for: command, in: screen, current: current) ?? current
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
struct WindowHandle: Hashable {
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
struct WindowSnapshot: Equatable {
    var handle: WindowHandle
    var appName: String
    var bundleIdentifier: String?
    var bundleURL: URL?
    var title: String
    /// AppKit coordinates.
    var frame: CGRect
    var isMinimized: Bool

    var pid: pid_t { handle.pid }
}

/// Everything window commands, layouts and the window switcher do to other apps.
/// `AXWindowSystem` is the real one; tests use a fake and never touch real windows.
@MainActor
protocol WindowSystem: AnyObject {
    var isTrusted: Bool { get }
    var ownPID: pid_t { get }
    func requestTrust()
    func displays() -> [DisplaySnapshot]
    /// Standard windows of other running apps, grouped by app name and front to back within each app.
    func windows(includeMinimized: Bool) -> [WindowSnapshot]
    func focusedWindow(of pid: pid_t) -> WindowHandle?
    func isRunning(_ pid: pid_t) -> Bool
    func title(of window: WindowHandle) -> String?
    /// AppKit coordinates.
    func frame(of window: WindowHandle) throws -> CGRect
    func setFrame(_ frame: CGRect, of window: WindowHandle) throws
    func isFullScreen(_ window: WindowHandle) -> Bool?
    func setFullScreen(_ fullScreen: Bool, of window: WindowHandle) throws
    func setMinimized(_ minimized: Bool, of window: WindowHandle) throws
    /// Raises the window and activates its app.
    func focus(_ window: WindowHandle) throws
    func close(_ window: WindowHandle) throws
    func hideApplication(_ pid: pid_t) throws
}

/// The real window system, through the Accessibility API.
@MainActor
final class AXWindowSystem: WindowSystem {
    /// Listing asks every app; one that's hung must not stall the launcher for AX's default six seconds.
    private static let listingTimeout: Float = 0.25
    private static let fullScreenAttribute = "AXFullScreen"

    nonisolated init() {}

    var isTrusted: Bool { AXIsProcessTrusted() }
    var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    func requestTrust() {
        guard !SideEffectGuard.isTestHost else { return }
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

    func windows(includeMinimized: Bool) -> [WindowSnapshot] {
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
                let axFrame = try? readFrame(window)
                windows.append(
                    WindowSnapshot(
                        handle: WindowHandle(pid: application.processIdentifier, element: window),
                        appName: application.localizedName ?? "App", bundleIdentifier: application.bundleIdentifier,
                        bundleURL: application.bundleURL,
                        title: attribute(kAXTitleAttribute, of: window) as? String ?? "",
                        frame: axFrame.map { ScreenCoordinates.flip($0, primaryHeight: primaryHeight) } ?? .zero,
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
        try SideEffectGuard.check("moving a window")
        let element = try element(of: window)
        let current = try readFrame(element)
        try writeFrame(ScreenCoordinates.flip(frame, primaryHeight: Self.primaryHeight), from: current, to: element)
    }

    func isFullScreen(_ window: WindowHandle) -> Bool? {
        guard let element = window.element else { return nil }
        return attribute(Self.fullScreenAttribute, of: element) as? Bool
    }

    func setFullScreen(_ fullScreen: Bool, of window: WindowHandle) throws {
        try SideEffectGuard.check("changing full screen")
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
        try SideEffectGuard.check("minimizing a window")
        let element = try element(of: window)
        guard
            AXUIElementSetAttributeValue(
                element, kAXMinimizedAttribute as CFString, (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
                == .success
        else { throw LibraryValidationError("This app did not allow the window to be minimized.") }
    }

    func focus(_ window: WindowHandle) throws {
        try SideEffectGuard.check("focusing a window")
        let element = try element(of: window)
        // A chosen window can sit behind the app's focused one; bring it forward with the app.
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard let application = NSRunningApplication(processIdentifier: window.pid), !application.isTerminated else {
            throw LibraryValidationError("That window's app has quit. Choose another window and try again.")
        }
        application.activate()
    }

    func close(_ window: WindowHandle) throws {
        try SideEffectGuard.check("closing a window")
        let element = try element(of: window)
        guard let button = attribute(kAXCloseButtonAttribute, of: element),
            CFGetTypeID(button) == AXUIElementGetTypeID(),
            AXUIElementPerformAction(unsafeDowncast(button, to: AXUIElement.self), kAXPressAction as CFString)
                == .success
        else { throw LibraryValidationError("This window can't be closed from OpenRay.") }
    }

    func hideApplication(_ pid: pid_t) throws {
        try SideEffectGuard.check("hiding an app")
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func readFrame(_ window: AXUIElement) throws -> CGRect {
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

    private func writeFrame(_ rect: CGRect, from current: CGRect, to window: AXUIElement) throws {
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
        var gaps = WindowGaps.none
        /// Repeating a half command steps through 1/2, 2/3 and 1/3.
        var cyclesHalves = false
    }

    let system: any WindowSystem
    var settings = Settings()
    /// Frames from before the first command, for Restore.
    private var originalFrames: [WindowHandle: CGRect] = [:]

    init(system: any WindowSystem = AXWindowSystem()) {
        self.system = system
    }

    var hasPermission: Bool { system.isTrusted }

    func requestPermission() { system.requestTrust() }

    /// Standard, unminimized windows of other running apps, grouped by app name
    /// and front to back within each app. Empty without Accessibility access.
    func listWindows() -> [TargetWindow] {
        guard hasPermission else { return [] }
        return system.windows(includeMinimized: false).compactMap { window in
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
        try perform(focusedWindowOf: pid) { try perform(custom, on: $0) }
    }

    /// Runs a command on a specific window.
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
        let frames = displays.map(\.frame)
        guard let index = DisplayArrangement.index(of: current, in: frames) else {
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
            guard let target = DisplayArrangement.adjacent(to: index, in: frames, forward: command == .nextDisplay)
            else { throw LibraryValidationError("Connect another display to move this window.") }
            desired = WindowGeometry.centered(
                current.size, in: WindowGeometry.usableArea(displays[target].visibleFrame, gaps: settings.gaps))
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

    /// Runs a custom size-and-position command on a specific window.
    func perform(_ custom: CustomWindowCommand, on window: WindowHandle) throws {
        try requireWindow(window)
        let current = try system.frame(of: window)
        let displays = system.displays()
        guard let index = DisplayArrangement.index(of: current, in: displays.map(\.frame)) else {
            throw LibraryValidationError("No display is available.")
        }
        try apply(custom.frame(in: displays[index].visibleFrame, current: current), to: window, from: current)
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

    /// Save Current Layout: the visible windows on every display, as a draft to name and edit.
    func captureLayout(named name: String) throws -> SavedWindowLayout {
        try requirePermission()
        let layout = WindowLayoutPlanner.capture(
            named: name, displays: system.displays(), windows: system.windows(includeMinimized: false))
        guard !layout.slots.isEmpty else { throw LibraryValidationError("There are no windows to save.") }
        return layout
    }

    /// Places every window a layout lists, launching apps that have no window yet
    /// and waiting up to `launchTimeout` for their windows to appear.
    func apply(
        _ layout: SavedWindowLayout, launcher: any ApplicationLaunching,
        launchTimeout: Duration = .seconds(6), pollInterval: Duration = .milliseconds(250),
        sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async throws -> WindowLayoutOutcome {
        try requirePermission()
        try layout.validate()
        var plan = currentPlan(for: layout)
        if !plan.launches.isEmpty {
            for bundleIdentifier in plan.launches {
                try? await launcher.launch(bundleIdentifier: bundleIdentifier)
            }
            var waited = Duration.zero
            while !plan.unmatchedSlots.isEmpty && waited < launchTimeout {
                await sleep(pollInterval)
                waited += pollInterval
                plan = currentPlan(for: layout)
            }
        }
        var placed = 0
        for move in plan.moves {
            do {
                if move.unminimize { try system.setMinimized(false, of: move.window) }
                let current = try system.frame(of: move.window)
                try apply(move.frame, to: move.window, from: current, focus: false)
                placed += 1
            } catch let error as SideEffectGuard.Blocked {
                throw error
            } catch {
                continue
            }
        }
        for window in plan.others {
            switch layout.otherWindows {
            case .leave: break
            case .minimize: try? system.setMinimized(true, of: window)
            case .close: try? system.close(window)
            }
        }
        // The first slot is the frontmost, so raise the rest first.
        for move in plan.moves.reversed() { try? system.focus(move.window) }
        let missing = layout.slots.filter { plan.unmatchedSlots.contains($0.id) }.map(\.appName)
        var unique: [String] = []
        for name in missing where !unique.contains(name) { unique.append(name) }
        return WindowLayoutOutcome(placed: placed, missing: unique)
    }

    private func currentPlan(for layout: SavedWindowLayout) -> WindowLayoutPlan {
        WindowLayoutPlanner.plan(layout, displays: system.displays(), windows: system.windows(includeMinimized: true))
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
