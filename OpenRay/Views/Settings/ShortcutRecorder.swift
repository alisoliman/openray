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
    /// A modifier gesture recorded (⌥⌘, Right ⌘, ⌘ ⌘). Nil records keys only.
    var onRecordGesture: ((CommandShortcut) -> Void)? = nil
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
            if isRecording { CommandShortcutCapture(capture: onRecord, captureGesture: onRecordGesture, cancel: onStop) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Shortcut for \(title)")
        .accessibilityValue(shortcut.map { KeyShortcut($0).spoken } ?? "None")
        .accessibilityHint(
            isRecording
                ? "Press a key combination, tap modifier keys, Delete to remove, or Escape to cancel"
                : "Records a new shortcut")
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
    var captureGesture: ((CommandShortcut) -> Void)? = nil
    var cancel: () -> Void

    func makeNSView(context: Context) -> CommandShortcutCaptureView {
        let view = CommandShortcutCaptureView()
        view.capture = capture
        view.captureGesture = captureGesture
        view.cancel = cancel
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: CommandShortcutCaptureView, context: Context) {
        view.capture = capture
        view.captureGesture = captureGesture
        view.cancel = cancel
    }

    static func dismantleNSView(_ view: CommandShortcutCaptureView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class CommandShortcutCaptureView: NSView {
    var capture: ((NSEvent) -> Void)?
    var captureGesture: ((CommandShortcut) -> Void)?
    var cancel: (() -> Void)?
    private var monitor: Any?
    private var gestures = ShortcutRecordingSession()
    private var pendingTimeout: DispatchWorkItem?

    var isMonitoring: Bool { monitor != nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
        gestures = ShortcutRecordingSession()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) {
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
        if event.type == .flagsChanged {
            guard captureGesture != nil, event.window === window else { return false }
            handleGesture(gestures.handle(NSEventModifierSource.input(for: event)))
            return false
        }
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

    /// A single tap waits briefly for a second one before it counts as one side of a modifier.
    private func handleGesture(_ outcome: ShortcutRecordingSession.Outcome) {
        pendingTimeout?.cancel()
        switch outcome {
        case .shortcut(let shortcut):
            stopMonitoring()
            captureGesture?(shortcut)
        case .pending:
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let shortcut = self.gestures.timeout() else { return }
                    self.stopMonitoring()
                    self.captureGesture?(shortcut)
                }
            }
            pendingTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + ModifierGestureDetector.doubleTapInterval + 0.05, execute: work)
        case .ignored:
            break
        }
    }

    func stopMonitoring() {
        pendingTimeout?.cancel()
        pendingTimeout = nil
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

/// Records a modifier gesture from modifier changes: two or more modifiers pressed and
/// released together, one modifier tapped twice, or one side of a modifier tapped once. Pure,
/// so recording is tested with synthetic values.
struct ShortcutRecordingSession {
    enum Outcome: Equatable {
        case shortcut(CommandShortcut)
        /// One modifier was tapped; a second tap would make it a double tap.
        case pending
        case ignored
    }

    private var held: ModifierSides = []
    private var peak: ModifierSides = []
    private var pressedAt: TimeInterval = 0
    private var lastTap: (key: ModifierSides, time: TimeInterval)?

    mutating func handle(_ input: ModifierInput) -> Outcome {
        guard case .flags(let now, let time) = input else {
            lastTap = nil
            return .ignored
        }
        defer { held = now }
        if held.isEmpty, !now.isEmpty {
            peak = now
            pressedAt = time
            return .ignored
        }
        peak.formUnion(now)
        guard now.isEmpty, !held.isEmpty, time - pressedAt <= ModifierGestureDetector.maximumHold else {
            return .ignored
        }
        if peak.count >= 2 {
            lastTap = nil
            // Several modifiers together: either side of each counts.
            return .shortcut(.modifiersOnly(peak.modifiers))
        }
        if let last = lastTap, last.key == peak, time - last.time <= ModifierGestureDetector.doubleTapInterval {
            lastTap = nil
            return .shortcut(.doubleTap(peak.modifiers))
        }
        lastTap = (peak, time)
        return .pending
    }

    /// No second tap came: the single tap records that side of the modifier, such as Right ⌘.
    mutating func timeout() -> CommandShortcut? {
        guard let last = lastTap else { return nil }
        lastTap = nil
        return .modifiersOnly(last.key.modifiers, sides: last.key)
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
