import AppKit
import Foundation

/// One modifier event, reduced to what gesture detection needs. Built from `NSEvent`s in
/// production and by hand in tests, which never post or observe real events.
enum ModifierInput: Equatable, Sendable {
    /// The physical modifier keys now down.
    case flags(ModifierSides, time: TimeInterval)
    /// Any other key went down, so a modifier gesture in progress is really a shortcut.
    case key(time: TimeInterval)
}

/// Detects modifier-only and double-tap gestures from modifier changes. Pure, so every
/// sequence is tested with synthetic values.
struct ModifierGestureDetector: Sendable {
    /// Longer than this between press and release and it's a held modifier, not a gesture.
    static let maximumHold: TimeInterval = 1.0
    /// Two taps closer than this make a double tap.
    static let doubleTapInterval: TimeInterval = 0.35

    /// The gestures to watch for, by target id.
    var gestures: [String: CommandShortcut] = [:]

    private var held: ModifierSides = []
    private var peak: ModifierSides = []
    private var interrupted = false
    private var pressedAt: TimeInterval = 0
    private var lastTap: (key: ModifierSides, time: TimeInterval)?

    init(gestures: [String: CommandShortcut] = [:]) { self.gestures = gestures }

    /// Feeds one input. Returns the targets whose gesture it completed, in id order.
    mutating func handle(_ input: ModifierInput) -> [String] {
        switch input {
        case .key:
            if !held.isEmpty { interrupted = true }
            lastTap = nil
            return []
        case .flags(let now, let time):
            defer { held = now }
            if held.isEmpty, !now.isEmpty {
                peak = now
                interrupted = false
                pressedAt = time
                return []
            }
            peak.formUnion(now)
            guard now.isEmpty, !held.isEmpty else { return [] }
            // Every modifier is up: the press is over.
            guard !interrupted, time - pressedAt <= Self.maximumHold else {
                lastTap = nil
                return []
            }
            var fired = matches(.modifiersOnly, pressed: peak)
            if peak.count == 1 {
                if let last = lastTap, last.key == peak, time - last.time <= Self.doubleTapInterval {
                    fired += matches(.doubleTap, pressed: peak)
                    lastTap = nil
                } else {
                    lastTap = (peak, time)
                }
            } else {
                lastTap = nil
            }
            return fired.sorted()
        }
    }

    private func matches(_ gesture: ShortcutGesture, pressed: ModifierSides) -> [String] {
        gestures.compactMap { id, shortcut in
            guard shortcut.gesture == gesture else { return nil }
            if let sides = shortcut.sides { return sides == pressed ? id : nil }
            // Either side counts, but every pressed key must belong to the shortcut.
            return pressed.modifiers == shortcut.modifiers && pressed.count == shortcut.modifiers.rawValue.nonzeroBitCount
                ? id : nil
        }
    }
}

/// Where modifier events come from. The real one watches the system with `NSEvent` monitors;
/// tests use a fake and never observe real input.
@MainActor
protocol ModifierEventSource: AnyObject {
    /// Starts delivering events. Returns false when macOS won't deliver them (no Accessibility).
    func start(_ handler: @escaping @MainActor (ModifierInput) -> Void) -> Bool
    func stop()
}

/// Global and local `NSEvent` monitors for modifier changes and key presses. They observe
/// only; nothing is posted or changed. Global monitors need Accessibility.
@MainActor
final class NSEventModifierSource: ModifierEventSource {
    private var monitors: [Any] = []

    func start(_ handler: @escaping @MainActor (ModifierInput) -> Void) -> Bool {
        stop()
        let deliver: (NSEvent) -> Void = { event in
            let input = Self.input(for: event)
            MainActor.assumeIsolated { handler(input) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: deliver) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            deliver(event)
            return event
        }) {
            monitors.append(local)
        }
        return AXIsProcessTrusted()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }

    nonisolated static func input(for event: NSEvent) -> ModifierInput {
        guard event.type == .flagsChanged else { return .key(time: event.timestamp) }
        return .flags(sides(fromDeviceFlags: UInt32(truncatingIfNeeded: event.modifierFlags.rawValue)), time: event.timestamp)
    }

    /// The device-dependent bits in an event's modifier flags, per physical key (IOLLEvent.h).
    nonisolated static func sides(fromDeviceFlags flags: UInt32) -> ModifierSides {
        let bits: [(UInt32, ModifierSides)] = [
            (0x0000_0001, .leftControl), (0x0000_2000, .rightControl),
            (0x0000_0002, .leftShift), (0x0000_0004, .rightShift),
            (0x0000_0008, .leftCommand), (0x0000_0010, .rightCommand),
            (0x0000_0020, .leftOption), (0x0000_0040, .rightOption),
        ]
        return bits.reduce(into: []) { result, entry in if flags & entry.0 != 0 { result.insert(entry.1) } }
    }
}

/// Registers modifier-only and double-tap shortcuts, beside the Carbon key shortcuts.
@MainActor
final class ModifierHotKeys {
    private let source: any ModifierEventSource
    private var detector = ModifierGestureDetector()
    private var isListening = false
    private var onTrigger: ((String) -> Void)?

    init(source: any ModifierEventSource = NSEventModifierSource()) {
        self.source = source
    }

    var registeredIDs: [String] { detector.gestures.keys.sorted() }

    /// Replaces the watched gestures. Listens only while there's one. Returns false when
    /// macOS won't deliver modifier events (Accessibility isn't allowed).
    @discardableResult
    func synchronize(_ gestures: [String: CommandShortcut], onTrigger: @escaping (String) -> Void) -> Bool {
        detector.gestures = gestures
        self.onTrigger = onTrigger
        guard !gestures.isEmpty else {
            unregister()
            return true
        }
        if isListening { return true }
        isListening = true
        return source.start { [weak self] input in self?.receive(input) }
    }

    func receive(_ input: ModifierInput) {
        for id in detector.handle(input) { onTrigger?(id) }
    }

    func unregister() {
        detector.gestures = [:]
        if isListening { source.stop() }
        isListening = false
    }
}
