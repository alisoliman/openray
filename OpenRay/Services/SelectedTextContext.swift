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
    /// Where the text was selected. Without it the result can be read and copied, but never
    /// replaces anything: identical text elsewhere in the same field would pass every other check.
    var range: NSRange?

    /// Whether a result may replace this selection in place: its range must be usable.
    var canReplace: Bool { Self.isUsable(range, for: text) }

    /// A range Replace can trust: not empty, and exactly as long as the selected text (UTF-16,
    /// as Accessibility counts). A stale or caret-only range never passes.
    nonisolated static func isUsable(_ range: NSRange?, for text: String) -> Bool {
        guard let range, range.location != NSNotFound, range.location >= 0 else { return false }
        return range.length > 0 && range.length == text.utf16.count
    }

    /// The check right before Replace: the source app is still frontmost and running, the same
    /// element stayed focused while it was read, and it still holds the same text at the same
    /// usable range. Any value that couldn't be read counts as changed.
    nonisolated static func verifyUnchanged(
        capturedText: String, capturedRange: NSRange?, appIsRunning: Bool, sameElement: Bool, currentText: String?,
        currentRange: NSRange?, sourceName: String, isFrontmost: Bool = true
    ) throws {
        guard isUsable(capturedRange, for: capturedText) else {
            throw LibraryValidationError(
                "\(sourceName) doesn't say exactly where the selection is, so nothing was replaced. Your result is copied; paste it with ⌘V.")
        }
        guard appIsRunning, isFrontmost, sameElement, currentText == capturedText, currentRange == capturedRange else {
            throw LibraryValidationError(
                "The original selection in \(sourceName) changed. Your rewrite is copied; select where it belongs and paste with ⌘V.")
        }
    }

    /// What the last check reads from the source app. Each read can fail (nil). The live probe
    /// reads Accessibility; tests pass a fake to change focus between reads.
    struct Probe {
        var frontmostProcess: @MainActor () -> pid_t?
        /// Whether the element captured is still the focused one; nil when it can't be read.
        var focusIsOriginal: @MainActor () -> Bool?
        var text: @MainActor () -> String?
        var range: @MainActor () -> NSRange?
    }

    /// Re-reads the full identity right before ⌘V: frontmost app, focus (before and after the
    /// text and range are read, so focus moving mid-check is caught), text and range.
    static func validate(
        capturedText: String, capturedRange: NSRange?, process: pid_t, appIsRunning: Bool, sourceName: String,
        probe: Probe
    ) throws {
        let focusBefore = probe.focusIsOriginal()
        let text = probe.text()
        let range = probe.range()
        let focusAfter = probe.focusIsOriginal()
        try verifyUnchanged(
            capturedText: capturedText, capturedRange: capturedRange, appIsRunning: appIsRunning,
            sameElement: focusBefore == true && focusAfter == true, currentText: text, currentRange: range,
            sourceName: sourceName, isFrontmost: probe.frontmostProcess() == process)
    }

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
        let sourceName = application.localizedName ?? "your app"
        let probe = Probe(
            frontmostProcess: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            focusIsOriginal: { (try? focusedElement(in: app)).map { CFEqual($0, element) } },
            text: { try? selectedText(in: element) },
            range: { selectedRange(in: element) })
        var context = SelectedTextContext(text: text, application: application, sourceName: sourceName) {
            try validate(
                capturedText: text, capturedRange: range, process: application.processIdentifier,
                appIsRunning: !application.isTerminated, sourceName: sourceName, probe: probe)
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
