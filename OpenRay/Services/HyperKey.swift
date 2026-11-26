import AppKit
import Carbon
import Foundation
import IOKit
import IOKit.hidsystem

// The Hyper key: Caps Lock held down acts as ⌃⌥⌘ (and ⇧, unless turned off), so it can start
// any shortcut without a finger on the modifiers. Off unless turned on in Settings › Keyboard.
//
// How: `hidutil` remaps Caps Lock to F18, a key nothing types, for this login session. An event
// tap (under the Accessibility permission OpenRay already asks for) then holds the Hyper
// modifiers on every key pressed while F18 is down, and swallows F18 itself. A lone press can
// toggle Caps Lock. Turning it off removes the remap; a remap left by a crash is removed at the
// next launch. Every side effect sits behind a protocol, and tests use fakes.

/// The F18 key Caps Lock becomes.
let hyperTriggerKeyCode: Int64 = Int64(kVK_F18)

/// What the Hyper key does with each key event. Pure, so every sequence is tested with
/// synthetic values.
struct HyperKeyMachine: Sendable {
    enum Input: Equatable, Sendable {
        case hyperDown(isRepeat: Bool)
        case hyperUp
        case keyDown
        case keyUp
        case other
    }

    enum Output: Equatable, Sendable {
        /// Drop the event: it's the Hyper key itself.
        case swallow
        /// Pass the event on with these modifiers held.
        case addModifiers(ShortcutModifiers)
        case passUnchanged
        /// The Hyper key went down and up with nothing in between.
        case quickPress
    }

    var modifiers: ShortcutModifiers
    private(set) var isHeld = false
    private var usedWhileHeld = false

    init(modifiers: ShortcutModifiers) { self.modifiers = modifiers }

    mutating func handle(_ input: Input) -> Output {
        switch input {
        case .hyperDown(let isRepeat):
            if !isRepeat || !isHeld {
                isHeld = true
                usedWhileHeld = false
            }
            return .swallow
        case .hyperUp:
            let wasUsed = usedWhileHeld
            isHeld = false
            usedWhileHeld = false
            return wasUsed ? .swallow : .quickPress
        case .keyDown, .keyUp:
            guard isHeld else { return .passUnchanged }
            usedWhileHeld = true
            return .addModifiers(modifiers)
        case .other:
            return .passUnchanged
        }
    }
}

/// One `hidutil` key mapping, as HID usages (page << 32 | usage).
struct KeyMapping: Equatable, Sendable {
    var source: UInt64
    var destination: UInt64

    /// Caps Lock (usage 0x39) to F18 (usage 0x6D), on the keyboard page.
    static let capsLockToF18 = KeyMapping(source: 0x7_0000_0039, destination: 0x7_0000_006D)
}

/// Adds or removes the Hyper key's mapping while keeping any others the person set up.
enum HyperRemapPlan {
    static func adding(to mappings: [KeyMapping]) -> [KeyMapping] {
        mappings.filter { $0.source != KeyMapping.capsLockToF18.source } + [.capsLockToF18]
    }

    static func removing(from mappings: [KeyMapping]) -> [KeyMapping] {
        mappings.filter { $0 != .capsLockToF18 }
    }

    /// `hidutil property --get UserKeyMapping` output: an old-style plist array of dictionaries,
    /// or "(null)" when there are none.
    static func parse(_ output: String) -> [KeyMapping] {
        output.components(separatedBy: "}").compactMap { block in
            guard let source = number(after: "HIDKeyboardModifierMappingSrc", in: block),
                let destination = number(after: "HIDKeyboardModifierMappingDst", in: block)
            else { return nil }
            return KeyMapping(source: source, destination: destination)
        }
    }

    /// The `hidutil property --set` argument.
    static func json(_ mappings: [KeyMapping]) -> String {
        let entries = mappings.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}"
        }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }

    private static func number(after key: String, in block: String) -> UInt64? {
        guard let range = block.range(of: key) else { return nil }
        let digits = block[range.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "x" }
        if digits.hasPrefix("0x") { return UInt64(digits.dropFirst(2), radix: 16) }
        return UInt64(digits)
    }
}

/// Reads and writes the session's key remapping.
@MainActor
protocol KeyRemapping {
    func currentMappings() throws -> [KeyMapping]
    func setMappings(_ mappings: [KeyMapping]) throws
}

/// `/usr/bin/hidutil`. The remap lasts until logout; OpenRay removes it when the Hyper key is turned off.
struct HIDUtilRemapper: KeyRemapping {
    func currentMappings() throws -> [KeyMapping] {
        HyperRemapPlan.parse(try run(["property", "--get", "UserKeyMapping"]))
    }

    func setMappings(_ mappings: [KeyMapping]) throws {
        _ = try run(["property", "--set", HyperRemapPlan.json(mappings)])
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LibraryValidationError("macOS didn't accept the Caps Lock remap.")
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// Toggles the Caps Lock state, for a lone press of the Hyper key.
@MainActor
protocol CapsLockToggling {
    func toggle()
}

struct IOKitCapsLock: CapsLockToggling {
    func toggle() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return
        }
        defer { IOServiceClose(connect) }
        var state = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state)
    }
}

/// Watches key events and can change or drop them.
@MainActor
protocol HyperEventTap: AnyObject {
    /// Starts the tap. Returns false when macOS refuses it (no Accessibility).
    func start(_ handler: @escaping @MainActor (HyperKeyMachine.Input) -> HyperKeyMachine.Output) -> Bool
    func stop()
}

/// A session event tap on the main run loop. It changes only events that pass while the Hyper
/// key is held, adding its modifiers, and drops the Hyper key's own events.
@MainActor
final class CGHyperEventTap: HyperEventTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: (@MainActor (HyperKeyMachine.Input) -> HyperKeyMachine.Output)?

    func start(_ handler: @escaping @MainActor (HyperKeyMachine.Input) -> HyperKeyMachine.Output) -> Bool {
        stop()
        self.handler = handler
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<CGHyperEventTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { tap.reenable() }
                return Unmanaged.passUnretained(event)
            }
            let input = CGHyperEventTap.input(
                type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            let output = MainActor.assumeIsolated { tap.decide(input) }
            return CGHyperEventTap.apply(output, to: event)
        }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        handler = nil
    }

    private func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    private func decide(_ input: HyperKeyMachine.Input) -> HyperKeyMachine.Output {
        handler?(input) ?? .passUnchanged
    }

    nonisolated static func input(type: CGEventType, keyCode: Int64, isRepeat: Bool) -> HyperKeyMachine.Input {
        let isHyper = keyCode == hyperTriggerKeyCode
        switch type {
        case .keyDown: return isHyper ? .hyperDown(isRepeat: isRepeat) : .keyDown
        case .keyUp: return isHyper ? .hyperUp : .keyUp
        default: return .other
        }
    }

    nonisolated static func apply(_ output: HyperKeyMachine.Output, to event: CGEvent) -> Unmanaged<CGEvent>? {
        switch output {
        case .swallow, .quickPress:
            return nil
        case .addModifiers(let modifiers):
            var flags = event.flags
            if modifiers.contains(.command) { flags.insert(.maskCommand) }
            if modifiers.contains(.control) { flags.insert(.maskControl) }
            if modifiers.contains(.option) { flags.insert(.maskAlternate) }
            if modifiers.contains(.shift) { flags.insert(.maskShift) }
            event.flags = flags
            return Unmanaged.passUnretained(event)
        case .passUnchanged:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Turns the Hyper key on and off from its settings.
@MainActor
final class HyperKey {
    private let remapper: any KeyRemapping
    private let tap: any HyperEventTap
    private let capsLock: any CapsLockToggling
    private var machine = HyperKeyMachine(modifiers: .all)
    private var quickPress: HyperKeyQuickPress = .toggleCapsLock
    private(set) var isActive = false
    /// Why the Hyper key isn't working, for Settings.
    private(set) var problem: String?

    init(
        remapper: any KeyRemapping = HIDUtilRemapper(), tap: any HyperEventTap = CGHyperEventTap(),
        capsLock: any CapsLockToggling = IOKitCapsLock()
    ) {
        self.remapper = remapper
        self.tap = tap
        self.capsLock = capsLock
    }

    /// Applies the settings: on remaps and taps, off undoes both.
    func apply(_ settings: HyperKeySettings, accessibilityAllowed: Bool) {
        machine.modifiers = settings.modifiers
        quickPress = settings.quickPress
        guard settings.isEnabled else {
            if isActive { deactivate() }
            problem = nil
            return
        }
        guard accessibilityAllowed else {
            if isActive { deactivate() }
            problem = "The Hyper key needs Accessibility. Allow OpenRay in System Settings › Privacy & Security."
            return
        }
        guard !isActive else { return }
        do {
            try remapper.setMappings(HyperRemapPlan.adding(to: try remapper.currentMappings()))
        } catch {
            problem = error.localizedDescription
            return
        }
        guard tap.start({ [weak self] input in self?.handle(input) ?? .passUnchanged }) else {
            try? remapper.setMappings(HyperRemapPlan.removing(from: (try? remapper.currentMappings()) ?? []))
            problem = "macOS didn't let OpenRay watch the keyboard. Check Accessibility in System Settings."
            return
        }
        isActive = true
        problem = nil
    }

    /// Removes a remap a crash left behind, when the Hyper key is off.
    func removeStaleRemap(_ settings: HyperKeySettings) {
        guard !settings.isEnabled, !isActive, let mappings = try? remapper.currentMappings(),
            mappings.contains(.capsLockToF18)
        else { return }
        try? remapper.setMappings(HyperRemapPlan.removing(from: mappings))
    }

    func stop() {
        if isActive { deactivate() }
    }

    func handle(_ input: HyperKeyMachine.Input) -> HyperKeyMachine.Output {
        let output = machine.handle(input)
        if output == .quickPress, quickPress == .toggleCapsLock { capsLock.toggle() }
        return output
    }

    private func deactivate() {
        tap.stop()
        try? remapper.setMappings(HyperRemapPlan.removing(from: (try? remapper.currentMappings()) ?? []))
        isActive = false
    }
}
