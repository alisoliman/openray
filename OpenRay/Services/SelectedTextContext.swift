import AppKit
import Carbon

/// A selection belongs to the app and editor that supplied it, even if the user
/// visits another app while a writing response is running.
@MainActor
struct SelectedTextContext {
    let id = UUID()
    let text: String
    let application: NSRunningApplication?
    let sourceName: String
    let validateForPaste: () throws -> Void
    var element: AXUIElement?
    var range: NSRange?

    func matches(_ other: SelectedTextContext) -> Bool {
        guard text == other.text, application?.processIdentifier == other.application?.processIdentifier,
            sourceName == other.sourceName, range == other.range
        else { return false }
        if let element, let otherElement = other.element { return CFEqual(element, otherElement) }
        return element == nil && other.element == nil
    }

    static func capture(from application: NSRunningApplication?) throws -> SelectedTextContext {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            throw LibraryValidationError("Select text in your app and enable Accessibility in Settings to use it here.")
        }
        guard let application, !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw LibraryValidationError("Select text in another app first.") }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let element = try focusedElement(in: app)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        guard role as? String != kAXSecureTextFieldSubrole else {
            throw LibraryValidationError("Protected text cannot be used for writing assistance.")
        }
        let text = try selectedText(in: element)
        let range = selectedRange(in: element)
        var context = SelectedTextContext(
            text: text, application: application, sourceName: application.localizedName ?? "your app"
        ) {
            guard !application.isTerminated,
                CFEqual(try focusedElement(in: app), element),
                try selectedText(in: element) == text,
                range == nil || selectedRange(in: element) == range
            else {
                throw LibraryValidationError(
                    "The original selection in \(application.localizedName ?? "your app") changed. Your rewrite is copied; select where it belongs and paste with ⌘V."
                )
            }
        }
        context.element = element
        context.range = range
        return context
    }

    private static func focusedElement(in app: AXUIElement) throws -> AXUIElement {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            throw LibraryValidationError("This app does not expose its selected text. Paste a passage to get started.")
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func selectedText(in element: AXUIElement) throws -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
            let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LibraryValidationError("No text is selected in the source app. Paste a passage to get started.") }
        return text
    }

    private static func selectedRange(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
