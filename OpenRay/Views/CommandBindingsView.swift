import AppKit
import Carbon
import SwiftUI

struct CommandBindingsView: View {
    let model: LauncherModel
    @State private var editingCommand: LauncherItem?

    var body: some View {
        Section {
            Text("Assign aliases and global shortcuts to these frequently used commands.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.bindableCommands) { command in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(command.title, systemImage: command.symbol)
                        Text(summary(for: model.commandBinding(for: command.id)))
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = model.commandShortcutErrors[command.id] {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Edit…") { editingCommand = command }
                        .accessibilityLabel("Edit alias and shortcut for \(command.title)")
                        .accessibilityIdentifier("commandBinding.edit.\(command.id)")
                }
            }
        } header: {
            Text("Command aliases & hotkeys")
        }
        .sheet(item: $editingCommand) { command in
            CommandBindingEditor(model: model, command: command)
        }
    }

    private func summary(for binding: CommandBinding) -> String {
        let details = [binding.alias.map { "Alias: \($0)" }, binding.shortcut.map { "Shortcut: \($0.title)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return details.isEmpty ? "No alias or shortcut" : details
    }
}

private struct CommandBindingEditor: View {
    let model: LauncherModel
    let command: LauncherItem
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var shortcut: CommandShortcut?
    @State private var isRecording = false
    @State private var didLoad = false
    @State private var isEditing = false
    @State private var errorMessage: String?
    @State private var conflictWarnings: [String] = []
    @State private var confirmsConflicts = false

    private var draft: CommandBinding {
        CommandBinding(targetID: command.id, alias: alias, shortcut: shortcut)
    }

    private var hasSavedBinding: Bool {
        let saved = model.commandBinding(for: command.id)
        return saved.alias != nil || saved.shortcut != nil
    }

    private var savedSummary: String {
        let saved = model.commandBinding(for: command.id)
        let details = [saved.alias.map { "alias “\($0)”" }, saved.shortcut.map { "shortcut \($0.title)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return details.isEmpty ? "No saved binding" : "Saved: \(details)"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label(command.title, systemImage: command.symbol).font(.title3.weight(.semibold))
                Text(savedSummary).font(.caption).foregroundStyle(.secondary)
                Text("Changes apply when you save.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(22)
            Divider()
            Form {
                Section("Alias") {
                    TextField("Alias", text: $alias, prompt: Text("For example, clip"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("commandBinding.alias")
                    Text(
                        "Type the alias in OpenRay to find this command. Aliases must be unique across commands, quicklinks and snippet keywords, ignoring letter case."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Global shortcut") {
                    HStack {
                        Text(shortcut?.title ?? "No shortcut")
                            .font(.body.monospaced())
                            .accessibilityLabel("Draft shortcut")
                            .accessibilityValue(shortcut?.title ?? "None")
                        Spacer()
                        if isRecording {
                            Button("Cancel Recording") { stopRecording() }
                                .accessibilityIdentifier("commandBinding.cancelRecording")
                        } else {
                            Button("Record Shortcut…") { startRecording() }
                                .accessibilityIdentifier("commandBinding.recordShortcut")
                        }
                        if shortcut != nil {
                            Button("Clear") {
                                stopRecording()
                                shortcut = nil
                                errorMessage = nil
                            }
                            .accessibilityLabel("Remove draft shortcut")
                            .accessibilityIdentifier("commandBinding.clearShortcut")
                        }
                    }
                    if isRecording {
                        Label("Hold modifiers, then press a key. Press Escape to cancel.", systemImage: "record.circle")
                            .font(.callout).foregroundStyle(.orange)
                            .background {
                                CommandShortcutCapture(
                                    capture: record, cancel: stopRecording)
                            }
                            .onDisappear { stopRecording() }
                    }
                    Text(
                        "Use Command, Control, Option or Shift with a key. Shortcuts follow physical key positions. Left and right modifiers are treated alike; modifier-only gestures and Hyper Key are not supported."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Text(
                        "macOS-reserved shortcuts are blocked. Other detected conflicts can be saved after a warning; another app may still prevent the shortcut from working."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if let error = model.commandShortcutErrors[command.id] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("commandBinding.error")
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                if hasSavedBinding {
                    Button("Remove Binding", role: .destructive) { removeBinding() }
                        .accessibilityIdentifier("commandBinding.remove")
                }
                Spacer()
                Button("Cancel") {
                    stopRecording()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRecording)
                    .accessibilityIdentifier("commandBinding.save")
            }.padding(18)
        }
        .frame(width: 520, height: 550)
        .onAppear {
            if !isEditing {
                model.beginCommandBindingEditing()
                isEditing = true
            }
            guard !didLoad else { return }
            let saved = model.commandBinding(for: command.id)
            alias = saved.alias ?? ""
            shortcut = saved.shortcut
            didLoad = true
        }
        .onDisappear {
            stopRecording()
            if isEditing {
                model.endCommandBindingEditing()
                isEditing = false
            }
        }
        .alert("Save shortcut with conflicts?", isPresented: $confirmsConflicts) {
            Button("Save Anyway") { save(allowConflicts: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(conflictWarnings.joined(separator: "\n\n"))
        }
    }

    private func startRecording() {
        errorMessage = nil
        model.beginShortcutRecording()
        isRecording = true
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        model.endShortcutRecording()
    }

    private func record(_ event: NSEvent) {
        do {
            shortcut = try CommandShortcutRecording.shortcut(from: event)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        stopRecording()
    }

    private func save(allowConflicts: Bool = false) {
        do {
            try model.validateCommandBinding(draft)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if !allowConflicts {
            conflictWarnings = model.bindingWarnings(for: draft)
            if !conflictWarnings.isEmpty {
                confirmsConflicts = true
                return
            }
        }
        if model.saveCommandBinding(draft, allowConflicts: allowConflicts) {
            dismiss()
        } else {
            errorMessage = model.message ?? model.store.errorMessage ?? "This binding could not be saved."
        }
    }

    private func removeBinding() {
        stopRecording()
        if model.removeCommandBinding(for: command.id) {
            dismiss()
        } else {
            errorMessage = model.message ?? model.store.errorMessage ?? "This binding could not be removed."
        }
    }
}

/// A window-scoped local monitor captures physical key codes before menu equivalents.
/// It exists only while the editor records, and is removed before invoking callbacks.
private struct CommandShortcutCapture: NSViewRepresentable {
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
                guard let self, let window = self.window, window.isKeyWindow else { return false }
                guard event.type == .keyDown, event.window === window else {
                    self.cancelCapture()
                    return false
                }
                guard !event.isARepeat else { return true }
                let isEscape =
                    event.keyCode == UInt16(kVK_Escape)
                    && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                self.stopMonitoring()
                if isEscape { self.cancel?() } else { self.capture?(event) }
                return true
            }
            return consumed ? nil : event
        }
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
