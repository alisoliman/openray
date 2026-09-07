import AppKit
import Carbon
import Testing

@testable import OpenRay

@MainActor
struct CommandShortcutRecorderTests {
    @Test func fnModifiedLetterCannotSilentlyBecomeAStandardShortcut() throws {
        let event = try keyEvent(code: kVK_ANSI_K, modifiers: [.function, .option])
        #expect(throws: LibraryValidationError.self) {
            try CommandShortcutRecording.shortcut(from: event)
        }
    }

    @Test(arguments: [kVK_LeftArrow, kVK_F7, kVK_Home])
    func automaticFunctionFlagOnNavigationAndFunctionKeysIsSupported(code: Int) throws {
        let event = try keyEvent(code: code, modifiers: [.function, .option])
        let shortcut = try CommandShortcutRecording.shortcut(from: event)
        #expect(shortcut.keyCode == UInt32(code))
        #expect(shortcut.modifiers == .option)
    }

    @Test func ordinaryLetterKeepsTheRecordedModifiersAndPhysicalKey() throws {
        let event = try keyEvent(code: kVK_ANSI_K, modifiers: [.control, .option])
        let shortcut = try CommandShortcutRecording.shortcut(from: event)
        #expect(shortcut.keyCode == UInt32(kVK_ANSI_K))
        #expect(shortcut.modifiers == [.control, .option])
    }

    @Test func attachingAndRemovingRecorderScopesItsMonitorToTheWindow() {
        let recorder = CommandShortcutCaptureView()
        var cancellations = 0
        recorder.cancel = { cancellations += 1 }
        #expect(!recorder.isMonitoring)
        let window = makeWindow()
        defer { window.close() }

        window.contentView = recorder
        #expect(recorder.isMonitoring)
        window.contentView = NSView()
        #expect(!recorder.isMonitoring)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(cancellations == 0)
    }

    @Test func deactivatingRecordingWindowCancelsAndRemovesMonitorOnce() {
        let recorder = CommandShortcutCaptureView()
        var cancellations = 0
        recorder.cancel = { cancellations += 1 }
        let window = makeWindow()
        defer { window.close() }
        window.contentView = recorder

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(cancellations == 1)
        #expect(!recorder.isMonitoring)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(cancellations == 1)
    }

    @Test func movingRecorderDetachesItsPreviousWindowObserver() {
        let recorder = CommandShortcutCaptureView()
        var cancellations = 0
        recorder.cancel = { cancellations += 1 }
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        defer {
            firstWindow.close()
            secondWindow.close()
        }
        firstWindow.contentView = recorder
        firstWindow.contentView = NSView()
        secondWindow.contentView = recorder

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: firstWindow)
        #expect(cancellations == 0)
        #expect(recorder.isMonitoring)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: secondWindow)
        #expect(cancellations == 1)
        #expect(!recorder.isMonitoring)
    }

    @Test func stoppingRecorderIsIdempotentAndRemovesWindowObserver() {
        let recorder = CommandShortcutCaptureView()
        var cancellations = 0
        recorder.cancel = { cancellations += 1 }
        let window = makeWindow()
        defer { window.close() }
        window.contentView = recorder

        recorder.stopMonitoring()
        recorder.stopMonitoring()
        #expect(!recorder.isMonitoring)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(cancellations == 0)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 150), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func keyEvent(code: Int, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(code)))
    }
}
