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
        case .topLeft: "Top Left Quarter"
        case .topRight: "Top Right Quarter"
        case .bottomLeft: "Bottom Left Quarter"
        case .bottomRight: "Bottom Right Quarter"
        case .nextDisplay: "Next Display"
        case .restore: "Restore Window"
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

@MainActor
final class WindowManager {
    private struct WindowKey: Hashable {
        var pid: pid_t
        var elementHash: CFHashCode
    }
    private var originalFrames: [WindowKey: CGRect] = [:]

    var hasPermission: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func arrange(_ layout: WindowLayout, application: NSRunningApplication?) throws {
        guard hasPermission else {
            throw LibraryValidationError(
                "Allow OpenRay in System Settings → Privacy & Security → Accessibility to arrange windows.")
        }
        guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            !application.isTerminated
        else { throw LibraryValidationError("Focus a window in another app, then open OpenRay and try again.") }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            throw LibraryValidationError("This app has no accessible focused window.")
        }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        let axFrame = try readFrame(window)
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let current = ScreenCoordinates.flip(axFrame, primaryHeight: primaryHeight)
        let screens = NSScreen.screens
        guard
            let screen = screens.max(by: { intersectionArea($0.frame, current) < intersectionArea($1.frame, current) })
        else {
            throw LibraryValidationError("No display is available.")
        }
        let key = WindowKey(pid: application.processIdentifier, elementHash: CFHash(window))
        var desired: CGRect
        if layout == .restore {
            guard let original = originalFrames[key] else {
                throw LibraryValidationError("There is no previous layout to restore for this window.")
            }
            desired = original
        } else {
            if layout == .nextDisplay {
                guard screens.count > 1, let index = screens.firstIndex(of: screen) else {
                    throw LibraryValidationError("Connect another display to move this window.")
                }
                desired = WindowLayout.center.frame(
                    in: screens[(index + 1) % screens.count].visibleFrame, current: current)
            } else {
                desired = layout.frame(in: screen.visibleFrame, current: current)
            }
        }
        // Preserve the first original frame, not the result of the last tiling command.
        if originalFrames[key] == nil { originalFrames[key] = current }
        try writeFrame(ScreenCoordinates.flip(desired, primaryHeight: primaryHeight), from: axFrame, to: window)
        if layout == .restore { originalFrames.removeValue(forKey: key) }
        application.activate()
    }

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

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func readFrame(_ window: AXUIElement) throws -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
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
