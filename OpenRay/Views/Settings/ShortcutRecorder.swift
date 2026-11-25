import AppKit
import Carbon
import SwiftUI

/// A shortcut recorder: “Record Shortcut”, a live recording state, or keycaps with a clear button.
struct ShortcutRecorderControl: View {
    /// The command's title, so VoiceOver can tell the recorders in a list apart.
    var title: String
    var shortcut: CommandShortcut?
    var isRecording: Bool
    var hasWarning = false
    var minWidth: CGFloat = 168
    var onStart: () -> Void
    var onStop: () -> Void
    var onRecord: (NSEvent) -> Void
    var onClear: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button {
            if isRecording { onStop() } else { onStart() }
        } label: {
            HStack(spacing: 6) {
                if isRecording {
                    Circle().fill(OR.Color.accentFill).frame(width: 7, height: 7)
                        .phaseAnimator([1.0, 0.25]) { view, opacity in view.opacity(opacity) } animation: { _ in
                            .easeInOut(duration: 0.5)
                        }
                    Text("Press keys…").foregroundStyle(OR.Color.accent)
                    Spacer(minLength: 4)
                    KeyCap("esc", size: .small)
                } else if let shortcut {
                    KeyCaps(KeyShortcut(shortcut))
                    if hasWarning {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                            .foregroundStyle(OR.Color.warning)
                    }
                    Spacer(minLength: 4)
                    if let onClear {
                        ClearButton(label: "Remove shortcut", action: onClear).opacity(hovering ? 1 : 0.7)
                    }
                } else {
                    Text("Record Shortcut").foregroundStyle(OR.Color.text2)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 12.5))
            .padding(.leading, 10).padding(.trailing, 6).frame(minWidth: minWidth, minHeight: 28, alignment: .leading)
            .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OR.Radius.control, style: .continuous)
                    .strokeBorder(isRecording ? OR.Color.accentFill : hasWarning ? OR.Color.warning : OR.Color.separator)
            }
            .background {
                if isRecording {
                    RoundedRectangle(cornerRadius: OR.Radius.control + 3, style: .continuous)
                        .stroke(OR.Color.accentSoft, lineWidth: 3).padding(-1.5)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background {
            if isRecording { CommandShortcutCapture(capture: onRecord, cancel: onStop) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Shortcut for \(title)")
        .accessibilityValue(shortcut.map { KeyShortcut($0).spoken } ?? "None")
        .accessibilityHint(
            isRecording ? "Press a key combination, Delete to remove, or Escape to cancel" : "Records a new shortcut")
        // The clear button sits inside this button's label, where VoiceOver can't reach it.
        .accessibilityActions {
            if let onClear, shortcut != nil, !isRecording {
                Button("Remove Shortcut", action: onClear)
            }
        }
    }
}

/// A window-scoped local monitor captures physical key codes before menu equivalents.
/// It exists only while recording, and is removed before invoking callbacks.
struct CommandShortcutCapture: NSViewRepresentable {
    var capture: (NSEvent) -> Void
    var cancel: () -> Void

    func makeNSView(context: Context) -> CommandShortcutCaptureView {
        let view = CommandShortcutCaptureView()
        view.capture = capture
        view.cancel = cancel
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: CommandShortcutCaptureView, context: Context) {
        view.capture = capture
        view.cancel = cancel
    }

    static func dismantleNSView(_ view: CommandShortcutCaptureView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class CommandShortcutCaptureView: NSView {
    var capture: ((NSEvent) -> Void)?
    var cancel: (() -> Void)?
    private var monitor: Any?

    var isMonitoring: Bool { monitor != nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.window?.isKeyWindow == true else { return false }
                return self.handle(event)
            }
            return consumed ? nil : event
        }
    }

    /// Routes one event while recording, in the key window. Returns true when it's consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        guard event.type == .keyDown, event.window === window else {
            // A click on the recorder itself only stops recording. Consuming it keeps the
            // button from seeing the click and starting a new recording on mouse-up.
            let onRecorder =
                event.type == .leftMouseDown && event.window === window
                && bounds.contains(convert(event.locationInWindow, from: nil))
            cancelCapture()
            return onRecorder
        }
        guard !event.isARepeat else { return true }
        let isEscape =
            event.keyCode == UInt16(kVK_Escape)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        stopMonitoring()
        if isEscape { cancel?() } else { capture?(event) }
        return true
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    @objc private func windowResignedKey() { cancelCapture() }

    private func cancelCapture() {
        stopMonitoring()
        cancel?()
    }
}

enum CommandShortcutRecording {
    /// Delete or Forward Delete with no modifiers removes the shortcut, like the system recorders.
    static func isRemoveKey(_ event: NSEvent) -> Bool {
        [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)].contains(event.keyCode)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    static func shortcut(from event: NSEvent) throws -> CommandShortcut {
        // AppKit also sets .function automatically for these physical keys.
        // For other keys, retaining only the four standard modifiers would
        // silently turn an unsupported Fn gesture into a different shortcut.
        if event.modifierFlags.contains(.function), !functionAndNavigationKeys.contains(event.keyCode) {
            throw LibraryValidationError(
                "Fn and Globe modifiers are not supported. Use Command, Control, Option or Shift.")
        }
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        let shortcut = CommandShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        try shortcut.validate()
        return shortcut
    }

    private static let functionAndNavigationKeys = Set<UInt16>(
        [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
            kVK_Help, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        ].map(UInt16.init))
}
