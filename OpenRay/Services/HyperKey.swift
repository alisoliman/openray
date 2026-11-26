import AppKit
import Carbon
import Foundation

// The Hyper key: one right-side modifier held down acts as ⌃⌥⌘ (and ⇧, unless turned off), so it
// can start any shortcut no app uses. Off unless turned on in Settings › Keyboard.
//
// Safety by construction:
// - Only an event tap changes keys, and only while OpenRay runs. Nothing is remapped in the
//   system (no `hidutil`), so quitting, crashing or turning it off leaves the keyboard as it was.
// - The mapping is stateless. Each key event carries the physical state of every modifier key in
//   its own flags, and the Hyper modifiers are added only when that event says the trigger key is
//   down. A lost key-up can't leave modifiers stuck: the next event shows the key is up and passes
//   unchanged. Anything unexpected passes unchanged too (fail open).
// - The tap's callback does bit arithmetic only, and is inert in the test host and verification
//   mode (`SideEffectGuard`).

/// The key that acts as Hyper while held. Only right-side modifiers: every key event reports
/// whether they're down, which is what makes the mapping stateless.
enum HyperKeyTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case rightCommand, rightOption, rightControl, rightShift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        case .rightShift: "Right ⇧"
        }
    }

    var side: ModifierSides {
        switch self {
        case .rightCommand: .rightCommand
        case .rightOption: .rightOption
        case .rightControl: .rightControl
        case .rightShift: .rightShift
        }
    }

    /// The device-dependent flag bit for the key (IOLLEvent.h).
    var deviceBit: UInt64 {
        switch self {
        case .rightCommand: 0x0000_0010
        case .rightOption: 0x0000_0040
        case .rightControl: 0x0000_2000
        case .rightShift: 0x0000_0004
        }
    }

    /// The device-dependent flag bit for the same modifier's left key.
    var otherSideBit: UInt64 {
        switch self {
        case .rightCommand: 0x0000_0008
        case .rightOption: 0x0000_0020
        case .rightControl: 0x0000_0001
        case .rightShift: 0x0000_0002
        }
    }

    /// The modifier the key normally is.
    var modifier: ShortcutModifiers {
        switch self {
        case .rightCommand: .command
        case .rightOption: .option
        case .rightControl: .control
        case .rightShift: .shift
        }
    }

    /// The device-independent flag that must accompany the device bit.
    var genericFlag: UInt64 {
        switch self {
        case .rightCommand: CGEventFlags.maskCommand.rawValue
        case .rightOption: CGEventFlags.maskAlternate.rawValue
        case .rightControl: CGEventFlags.maskControl.rawValue
        case .rightShift: CGEventFlags.maskShift.rawValue
        }
    }
}

/// The Hyper key's mapping of one key event's flags. Pure and stateless.
enum HyperKeyMapping {
    /// The flags a key event leaves with: the Hyper modifiers when the event's own flags show the
    /// trigger key physically down; otherwise exactly the flags it arrived with. While held, the
    /// trigger stands for Hyper only: a right ⇧ trigger with Shift left out of Hyper sends no ⇧,
    /// unless left ⇧ is held too.
    static func flags(_ flags: UInt64, trigger: HyperKeyTrigger, modifiers: ShortcutModifiers) -> UInt64 {
        // Both the physical bit and its modifier must be set; anything else passes unchanged.
        guard flags & trigger.deviceBit != 0, flags & trigger.genericFlag != 0 else { return flags }
        var mapped = flags
        if !modifiers.contains(trigger.modifier) {
            mapped &= ~trigger.deviceBit
            if flags & trigger.otherSideBit == 0 { mapped &= ~trigger.genericFlag }
        }
        if modifiers.contains(.command) { mapped |= CGEventFlags.maskCommand.rawValue }
        if modifiers.contains(.control) { mapped |= CGEventFlags.maskControl.rawValue }
        if modifiers.contains(.option) { mapped |= CGEventFlags.maskAlternate.rawValue }
        if modifiers.contains(.shift) { mapped |= CGEventFlags.maskShift.rawValue }
        return mapped
    }
}

/// Changes key events' flags. The real one is a Quartz event tap; tests use a fake.
@MainActor
protocol HyperEventTap: AnyObject {
    /// Starts mapping key events with `map`. Returns false when it can't (no Accessibility, or an
    /// inert launch).
    func start(map: @escaping @Sendable (UInt64) -> UInt64) -> Bool
    func stop()
    /// True while it's installed and enabled, so key events really pass through it.
    var isRunning: Bool { get }
    /// True once macOS reported it disabled on purpose (`tapDisabledByUserInput`). It stays off.
    var isDisabledByUser: Bool { get }
}

extension HyperEventTap {
    var isDisabledByUser: Bool { false }
}

/// A session event tap for key down and up. Its callback only rewrites flags with a pure
/// function, so it never blocks. It is never created in the test host or verification mode.
@MainActor
final class CGHyperEventTap: HyperEventTap {
    private let sideEffects: SideEffectGuard
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Read by the callback; written only on the main thread while the tap is stopped or starting.
    nonisolated(unsafe) private var map: (@Sendable (UInt64) -> UInt64)?

    init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    var isRunning: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    private(set) var isDisabledByUser = false

    func start(map: @escaping @Sendable (UInt64) -> UInt64) -> Bool {
        stop()
        guard (try? sideEffects.check("changing keyboard events")) != nil else { return false }
        isDisabledByUser = false
        self.map = map
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<CGHyperEventTap>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout:
                // macOS disabled it for being slow. The mapping holds no state, so resuming is safe.
                MainActor.assumeIsolated { tap.resume() }
            case .tapDisabledByUserInput:
                // Disabled on purpose (Secure Input, for one): stay off, and say so.
                MainActor.assumeIsolated { tap.isDisabledByUser = true }
            case .keyDown, .keyUp:
                if let map = tap.map {
                    let mapped = map(event.flags.rawValue)
                    if mapped != event.flags.rawValue { event.flags = CGEventFlags(rawValue: mapped) }
                }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            self.map = nil
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        map = nil
    }

    private func resume() {
        if let port, map != nil { CGEvent.tapEnable(tap: port, enable: true) }
    }
}

/// Turns the Hyper key on and off from its settings.
@MainActor
final class HyperKey {
    private let tap: any HyperEventTap
    private var applied: HyperKeySettings?
    /// Why the Hyper key isn't working, for Settings.
    private(set) var problem: String?

    init(tap: any HyperEventTap = CGHyperEventTap()) {
        self.tap = tap
    }

    var isActive: Bool { tap.isRunning }

    /// Applies the settings: on starts the tap with the chosen key and modifiers, off stops it.
    func apply(_ settings: HyperKeySettings, accessibilityAllowed: Bool) {
        guard settings.isEnabled else {
            stop()
            problem = nil
            return
        }
        guard accessibilityAllowed else {
            stop()
            problem = "The Hyper key needs Accessibility. Allow OpenRay in System Settings › Privacy & Security."
            return
        }
        if settings == applied, tap.isDisabledByUser {
            // macOS turned it off on purpose. It stays off until the setting changes.
            problem = "macOS turned the Hyper key off. Turn it off and on again here to resume."
            return
        }
        guard settings != applied || !tap.isRunning else { return }
        let trigger = settings.trigger
        let modifiers = settings.modifiers
        stop()
        if tap.start(map: { HyperKeyMapping.flags($0, trigger: trigger, modifiers: modifiers) }) {
            applied = settings
            problem = nil
        } else {
            problem = "macOS didn't let OpenRay watch the keyboard. Check Accessibility in System Settings."
        }
    }

    func stop() {
        tap.stop()
        applied = nil
    }
}
