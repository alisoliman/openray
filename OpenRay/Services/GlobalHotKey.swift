import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    func register(_ shortcut: LauncherHotKey, action: @escaping () -> Void) throws {
        unregister()
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                // Carbon dispatches application events on the application's main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().action?()
                }
                return noErr
            }, 1, &type, pointer, &handler)
        guard status == noErr else {
            throw LibraryValidationError("The global shortcut could not be installed (\(status)).")
        }
        let modifiers: UInt32 =
            switch shortcut {
            case .optionSpace: UInt32(optionKey)
            case .controlSpace: UInt32(controlKey)
            case .controlOptionSpace: UInt32(controlKey | optionKey)
            }
        let identifier = EventHotKeyID(signature: 0x4F52_4159, id: 1)
        let registration = RegisterEventHotKey(
            UInt32(kVK_Space), modifiers, identifier,
            GetApplicationEventTarget(), 0, &reference)
        guard registration == noErr else {
            unregister()
            throw LibraryValidationError(
                "\(shortcut.title) is already in use. Choose a different launcher shortcut in Settings.")
        }
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        action = nil
    }
}
