import AppKit
import Carbon

/// Why the selection in another app couldn't be read. Two of them, where Accessibility saw no
/// selection, may still be answered by the app's own Copy (`allowsCopyFallback`).
enum SelectionReadError: LocalizedError, Equatable {
    case accessibilityOff
    /// A password field, or the lock screen, holds Secure Input.
    case secureInput
    case noSourceApp
    case protectedField
    /// The app shows no focused element, or no selected text, over Accessibility; a selection
    /// may still be there.
    case notExposed(app: String)
    /// Nothing is selected: Accessibility shows an empty selection, or the app's Copy left the
    /// clipboard as it was.
    case nothingSelected(app: String)
    /// The clipboard changed again while the app's copy was being read: that's someone's own copy.
    case copyInterrupted(app: String)
    /// A change OpenRay can't tell apart from someone else's copy: another app came forward, or a
    /// key or click reached the Mac, while the app's copy was awaited.
    case copyUnattributable(app: String)

    var errorDescription: String? {
        switch self {
        case .accessibilityOff:
            "Accessibility access is required to read selected text. Paste or type the text instead."
        case .secureInput:
            "Secure Input is on, so the selection can't be read. Finish with the password field, or paste the text here."
        case .noSourceApp: "Select text in another app first."
        case .protectedField: "Protected text cannot be used for writing assistance."
        case .notExposed(let app): "\(app) doesn't share its selected text. Paste or type the text instead."
        case .nothingSelected(let app): "Nothing selected in \(app)."
        case .copyInterrupted(let app):
            "Your clipboard changed while the selection in \(app) was read, so OpenRay left it as it is."
        case .copyUnattributable(let app):
            "OpenRay couldn't be sure the copy came from \(app), so it didn't use it and left your clipboard as it is. Paste or type the text instead."
        }
    }

    /// Accessibility couldn't see whether anything is selected, but the app's own Copy might.
    /// When Accessibility shows an empty selection, no copy is sent: editors such as code
    /// editors copy the whole line when nothing is selected.
    var allowsCopyFallback: Bool {
        if case .notExposed = self { return true }
        return false
    }
}

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
    /// Whether the element that was focused at capture still is; nil when that can't be read.
    /// ↵ on a result checks only this, the app and Secure Input before it pastes (work item 6).
    var focusIsOriginal: @MainActor () -> Bool? = { nil }

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
                "\(sourceName) doesn't say exactly where the selection is, so nothing was replaced.")
        }
        guard appIsRunning, isFrontmost, sameElement, currentText == capturedText, currentRange == capturedRange else {
            throw LibraryValidationError("The original selection in \(sourceName) changed, so nothing was replaced.")
        }
    }

    /// The check before an explicit ↵ pastes a result: the same element is still focused when
    /// that can be read. The text and range may have changed; the person chose to paste.
    nonisolated static func verifyFocus(_ focusIsOriginal: Bool?, sourceName: String) throws {
        guard focusIsOriginal != false else {
            throw LibraryValidationError(
                "The text field you selected in \(sourceName) isn't focused any more, so nothing was pasted.")
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
        guard AXIsProcessTrusted() else { throw SelectionReadError.accessibilityOff }
        guard !IsSecureEventInputEnabled() else { throw SelectionReadError.secureInput }
        guard let application, !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw SelectionReadError.noSourceApp }
        let sourceName = application.localizedName ?? "your app"
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let element = focusedElement(in: app) else { throw SelectionReadError.notExposed(app: sourceName) }
        guard !isSecure(element) else { throw SelectionReadError.protectedField }
        guard let text = selectedText(in: element) else {
            // Only an empty selection Accessibility can place is certainly nothing; otherwise the
            // app may just not be sharing it.
            if selectedRange(in: element)?.length == 0, hasSelectedTextAttribute(element) {
                throw SelectionReadError.nothingSelected(app: sourceName)
            }
            throw SelectionReadError.notExposed(app: sourceName)
        }
        let range = selectedRange(in: element)
        let probe = Probe(
            frontmostProcess: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            focusIsOriginal: { focusedElement(in: app).map { CFEqual($0, element) } },
            text: { selectedText(in: element) },
            range: { selectedRange(in: element) })
        var context = SelectedTextContext(text: text, application: application, sourceName: sourceName) {
            try validate(
                capturedText: text, capturedRange: range, process: application.processIdentifier,
                appIsRunning: !application.isTerminated, sourceName: sourceName, probe: probe)
        }
        context.element = element
        context.range = range
        context.focusIsOriginal = probe.focusIsOriginal
        return context
    }

    /// A selection the app's own Copy gave, after Accessibility saw none. Its place in the field
    /// is unknown, so it never replaces anything unattended; ↵ can still paste over it. The
    /// element focused now, when Accessibility shows one, is what ↵ checks later.
    static func copied(_ text: String, from application: NSRunningApplication?, sourceName: String) -> SelectedTextContext {
        let appElement = application.map { AXUIElementCreateApplication($0.processIdentifier) }
        if let appElement { AXUIElementSetMessagingTimeout(appElement, 0.2) }
        let focused = AXIsProcessTrusted() ? appElement.flatMap(focusedElement(in:)) : nil
        var context = SelectedTextContext(text: text, application: application, sourceName: sourceName) {
            try verifyUnchanged(
                capturedText: text, capturedRange: nil, appIsRunning: true, sameElement: false, currentText: nil,
                currentRange: nil, sourceName: sourceName)
        }
        context.element = focused
        if let appElement, let focused {
            context.focusIsOriginal = { focusedElement(in: appElement).map { CFEqual($0, focused) } }
        }
        return context
    }

    /// Whether the app's focused element is a password field, read now. False when it can't be
    /// read, and in an inert launch, which never reads another app.
    static func focusedFieldIsSecure(in application: NSRunningApplication) -> Bool {
        guard !SideEffectGuard.isInert, AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return focusedElement(in: app).map(isSecure) ?? false
    }

    fileprivate static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    fileprivate static func isSecure(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        return role as? String == kAXSecureTextFieldSubrole
    }

    private static func selectedText(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
            let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Whether the element answers for its selected text at all, even with an empty one.
    private static func hasSelectedTextAttribute(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
            && value is String
    }

    fileprivate static func selectedRange(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

/// Quick Fix's whole-field target (work item 8): the focused text field's full value, for when
/// nothing is selected or Prefer Selection is off. Replacing it is unattended, so it checks the
/// app, the focus and the value are all unchanged first.
@MainActor
struct FocusedFieldContext {
    let text: String
    let application: NSRunningApplication?
    let sourceName: String
    /// Throws unless the app is frontmost and the same field still holds the same value.
    var validate: @MainActor () throws -> Void
    /// Sets a one-line field's value through Accessibility. False when the field doesn't take it,
    /// and for text areas, where a set value would skip undo; those are pasted over instead.
    var replaceValue: @MainActor (String) -> Bool
    /// Selects the whole value and confirms the selection covers exactly it, so a paste replaces
    /// it. False when the field doesn't allow it, or the selection came out different.
    var selectAll: @MainActor () -> Bool

    /// The field's value. `selectionHidden` refuses when the field has a selection it doesn't share,
    /// so Prefer Selection never widens to the whole field over a selection it couldn't read.
    static func capture(from application: NSRunningApplication?, selectionHidden refuses: Bool) throws
        -> FocusedFieldContext
    {
        guard AXIsProcessTrusted() else { throw SelectionReadError.accessibilityOff }
        guard !IsSecureEventInputEnabled() else { throw SelectionReadError.secureInput }
        guard let application, !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw SelectionReadError.noSourceApp }
        let sourceName = application.localizedName ?? "your app"
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let element = SelectedTextContext.focusedElement(in: app) else {
            throw SelectionReadError.notExposed(app: sourceName)
        }
        guard !SelectedTextContext.isSecure(element) else { throw SelectionReadError.protectedField }
        // With Prefer Selection on, only an empty selection Accessibility can place widens to
        // the whole field: one it can't read may hide a selection.
        if refuses, SelectedTextContext.selectedRange(in: element)?.length != 0 {
            throw SelectionReadError.notExposed(app: sourceName)
        }
        func value() -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
                return nil
            }
            return value as? String
        }
        guard let text = value(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryValidationError("There's no text to fix in \(sourceName).")
        }
        // Pictures and attachments in the text can't survive a plain replace.
        guard !text.contains("\u{FFFC}") else {
            throw LibraryValidationError(
                "\(sourceName)'s field has pictures or attachments. Select the text to fix, then run Quick Fix again.")
        }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let isOneLine = role as? String == kAXTextFieldRole
        let pid = application.processIdentifier
        return FocusedFieldContext(
            text: text, application: application, sourceName: sourceName,
            validate: {
                // Checked again right before anything is written, directly or by paste.
                guard !IsSecureEventInputEnabled(), !SelectedTextContext.isSecure(element) else {
                    throw LibraryValidationError("A password field has the keyboard, so nothing was replaced.")
                }
                let focused = SelectedTextContext.focusedElement(in: app).map { CFEqual($0, element) }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !application.isTerminated,
                    focused == true, value() == text
                else {
                    throw LibraryValidationError("The text in \(sourceName) changed, so nothing was replaced.")
                }
            },
            replaceValue: { newValue in
                var settable: DarwinBoolean = false
                guard isOneLine, !IsSecureEventInputEnabled(), !SelectedTextContext.isSecure(element),
                    AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
                    settable.boolValue
                else { return false }
                // Accepted is done: a field may store the text a little differently, and pasting
                // over it again would double it.
                return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFString)
                    == .success
            },
            selectAll: {
                // Selected, then read back: a paste must cover exactly the whole value.
                let whole = NSRange(location: 0, length: (text as NSString).length)
                var range = CFRange(location: whole.location, length: whole.length)
                guard let value = AXValueCreate(.cfRange, &range),
                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
                else { return false }
                return SelectedTextContext.selectedRange(in: element) == whole
            })
    }
}
