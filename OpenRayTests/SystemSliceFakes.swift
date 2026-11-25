import AppKit
import Foundation

@testable import OpenRay

// Fakes for the system-commands and window-management slice. None of them
// touch real windows, apps, sound devices, menus or the screen.

// MARK: - Displays and windows

enum WindowFixture {
    /// A 1440 × 900 laptop: 24 pt menu bar on top, 76 pt Dock at the bottom.
    static let laptop = DisplaySnapshot(
        id: 1, name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 76, width: 1440, height: 800))
    /// A 1920 × 1080 display to the left, lower than the laptop, with a 30 pt menu bar.
    static let secondary = DisplaySnapshot(
        id: 2, name: "Studio Display", frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1050))
    /// A portrait display to the right of the laptop.
    static let portrait = DisplaySnapshot(
        id: 3, name: "Portrait", frame: CGRect(x: 1440, y: -500, width: 1080, height: 1920),
        visibleFrame: CGRect(x: 1440, y: -500, width: 1080, height: 1890))
    /// The Dock on the left edge.
    static let leftDock = CGRect(x: 80, y: 0, width: 1360, height: 876)

    static func window(
        pid: pid_t = 100, token: Int, app: String = "Notes", bundle: String? = "com.example.notes",
        title: String = "", frame: CGRect? = CGRect(x: 100, y: 200, width: 600, height: 400), minimized: Bool = false
    ) -> WindowSnapshot {
        WindowSnapshot(
            handle: WindowHandle(pid: pid, token: token), appName: app, bundleIdentifier: bundle, bundleURL: nil,
            title: title, frame: frame, isMinimized: minimized)
    }

    /// Window-server entries for these windows, front to back in the given order.
    static func entries(for windows: [WindowSnapshot], primaryHeight: CGFloat = 900) -> [WindowServerEntry] {
        windows.compactMap { window in
            window.frame.map {
                WindowServerEntry(
                    number: UInt32(window.handle.token), pid: window.pid,
                    bounds: ScreenCoordinates.flip($0, primaryHeight: primaryHeight), layer: 0)
            }
        }
    }
}

@MainActor
final class FakeWindowSystem: WindowSystem {
    enum Event: Equatable {
        case setFrame(Int, CGRect)
        case minimized(Int, Bool)
        case fullScreen(Int, Bool)
        case focus(Int)
        case close(Int)
        case hide(pid_t)
    }

    var isTrusted = true
    var ownPID: pid_t = 1
    var displayList: [DisplaySnapshot]
    var windowList: [WindowSnapshot]
    var focusedWindows: [pid_t: WindowHandle] = [:]
    var runningPIDs: Set<pid_t> = []
    var fullScreen: [WindowHandle: Bool] = [:]
    /// Windows that refuse to move or resize at all.
    var lockedTokens: Set<Int> = []
    /// Windows that can move but not resize.
    var fixedSizeTokens: Set<Int> = []
    /// Apps that accept a resize and then keep their own size.
    var clampedSizes: [Int: CGSize] = [:]
    /// Windows whose focus or close fails.
    var focusFailures: Set<Int> = []
    var closeFailures: Set<Int> = []
    private(set) var events: [Event] = []
    private(set) var trustRequests = 0
    /// How many listings asked for frames, and how many for titles only.
    private(set) var frameListings = 0
    private(set) var titleListings = 0

    init(displays: [DisplaySnapshot] = [WindowFixture.laptop], windows: [WindowSnapshot] = []) {
        displayList = displays
        windowList = windows
    }

    func requestTrust() { trustRequests += 1 }
    func displays() -> [DisplaySnapshot] { displayList }

    func windows(includeMinimized: Bool, readFrames: Bool) -> [WindowSnapshot] {
        if readFrames { frameListings += 1 } else { titleListings += 1 }
        return (includeMinimized ? windowList : windowList.filter { !$0.isMinimized }).map { window in
            var window = window
            if !readFrames { window.frame = nil }
            return window
        }
    }

    func focusedWindow(of pid: pid_t) -> WindowHandle? {
        focusedWindows[pid] ?? windowList.first { $0.pid == pid && !$0.isMinimized }?.handle
    }

    func isRunning(_ pid: pid_t) -> Bool { runningPIDs.contains(pid) || windowList.contains { $0.pid == pid } }

    func title(of window: WindowHandle) -> String? { windowList.first { $0.handle == window }?.title }

    func frame(of window: WindowHandle) throws -> CGRect {
        guard let frame = windowList[try index(of: window)].frame else {
            throw LibraryValidationError("This window does not support positioning.")
        }
        return frame
    }

    func setFrame(_ frame: CGRect, of window: WindowHandle) throws {
        let index = try index(of: window)
        guard !lockedTokens.contains(window.token) else { throw LibraryValidationError("Fixed window.") }
        if fixedSizeTokens.contains(window.token), windowList[index].frame?.size != frame.size {
            throw LibraryValidationError("Fixed size.")
        }
        var applied = frame
        if let clamped = clampedSizes[window.token] { applied.size = clamped }
        windowList[index].frame = applied
        events.append(.setFrame(window.token, frame))
    }

    func isFullScreen(_ window: WindowHandle) -> Bool? { fullScreen[window] ?? false }

    func setFullScreen(_ value: Bool, of window: WindowHandle) throws {
        _ = try index(of: window)
        fullScreen[window] = value
        events.append(.fullScreen(window.token, value))
    }

    func setMinimized(_ value: Bool, of window: WindowHandle) throws {
        let index = try index(of: window)
        windowList[index].isMinimized = value
        events.append(.minimized(window.token, value))
    }

    func focus(_ window: WindowHandle) throws {
        _ = try index(of: window)
        guard !focusFailures.contains(window.token) else {
            throw LibraryValidationError("The app didn't bring that window forward.")
        }
        events.append(.focus(window.token))
    }

    func close(_ window: WindowHandle) throws {
        let index = try index(of: window)
        guard !closeFailures.contains(window.token) else { throw LibraryValidationError("Can't close.") }
        windowList.remove(at: index)
        events.append(.close(window.token))
    }

    func hideApplication(_ pid: pid_t) throws { events.append(.hide(pid)) }

    func clearEvents() { events.removeAll() }

    var frames: [CGRect] {
        events.compactMap {
            if case .setFrame(_, let frame) = $0 { return frame }
            return nil
        }
    }

    private func index(of window: WindowHandle) throws -> Int {
        guard let index = windowList.firstIndex(where: { $0.handle == window }) else {
            throw LibraryValidationError("This window has closed.")
        }
        return index
    }
}

@MainActor
final class FakeApplicationLauncher: ApplicationLaunching {
    private(set) var launched: [String] = []
    var onLaunch: ((String) -> Void)?

    func launch(bundleIdentifier: String) async throws {
        launched.append(bundleIdentifier)
        onLaunch?(bundleIdentifier)
    }
}

@MainActor
final class FakeWindowServerListing: WindowServerListing {
    var entries: [WindowServerEntry]
    init(_ entries: [WindowServerEntry] = []) { self.entries = entries }
    func onScreenWindows() -> [WindowServerEntry] { entries }
}

// MARK: - System actions

@MainActor
final class RecordingSystemActions: SystemActionPerforming {
    private(set) var actions: [SystemAction] = []
    var result: SystemActionResult = .done

    func perform(_ action: SystemAction) async throws -> SystemActionResult {
        actions.append(action)
        return result
    }
}

// MARK: - Sound

@MainActor
final class FakeAudioDevices: AudioDeviceControlling {
    static let speakers = AudioDevice(id: 10, uid: "speakers", name: "MacBook Speakers", transport: .builtIn)
    static let headphones = AudioDevice(id: 11, uid: "headphones", name: "Headphones", transport: .bluetooth)
    static let microphone = AudioDevice(id: 20, uid: "mic", name: "MacBook Microphone", transport: .builtIn)
    static let usbMicrophone = AudioDevice(id: 21, uid: "usb", name: "USB Microphone", transport: .usb)

    var outputs = [speakers, headphones]
    var inputs = [microphone]
    var defaults: [AudioScope: AudioDevice] = [.output: speakers, .input: microphone]
    var volumes: [String: Double] = ["speakers.output": 0.5, "headphones.output": 0.25]
    var mutes: [String: Bool] = ["speakers.output": false, "headphones.output": false, "mic.input": false]
    var volumeless: Set<String> = []
    var unmutable: Set<String> = []
    /// Per-channel gain for inputs: key → element → gain.
    var gains: [String: [UInt32: Double]] = [:]
    /// Inputs whose gain controls don't cover every channel.
    var partialGain: Set<String> = []
    /// Inputs that report success but don't actually change.
    var ignoresChanges: Set<String> = []
    private(set) var changes: [String] = []

    func devices(for scope: AudioScope) -> [AudioDevice] { scope == .output ? outputs : inputs }
    func defaultDevice(for scope: AudioScope) -> AudioDevice? { defaults[scope] }

    func setDefaultDevice(_ device: AudioDevice, for scope: AudioScope) throws {
        defaults[scope] = device
        changes.append("default.\(scope.rawValue)=\(device.uid)")
    }

    func volume(of device: AudioDevice, scope: AudioScope) -> Double? {
        volumeless.contains(key(device, scope)) ? nil : volumes[key(device, scope)]
    }

    func setVolume(_ volume: Double, of device: AudioDevice, scope: AudioScope) throws {
        guard canSetVolume(of: device, scope: scope) else { throw AudioDeviceError.noVolumeControl }
        volumes[key(device, scope)] = volume
        changes.append("volume.\(key(device, scope))=\(volume)")
    }

    func isMuted(_ device: AudioDevice, scope: AudioScope) -> Bool? {
        unmutable.contains(key(device, scope)) ? nil : mutes[key(device, scope)] ?? false
    }

    func setMuted(_ muted: Bool, of device: AudioDevice, scope: AudioScope) throws {
        guard canMute(device, scope: scope) else { throw AudioDeviceError.noMuteControl }
        changes.append("mute.\(key(device, scope))=\(muted)")
        if !ignoresChanges.contains(key(device, scope)) { mutes[key(device, scope)] = muted }
    }

    func canSetVolume(of device: AudioDevice, scope: AudioScope) -> Bool {
        !volumeless.contains(key(device, scope)) && volumes[key(device, scope)] != nil
    }

    func canMute(_ device: AudioDevice, scope: AudioScope) -> Bool { !unmutable.contains(key(device, scope)) }

    func gainElements(of device: AudioDevice, scope: AudioScope) -> [UInt32] {
        (gains[key(device, scope)] ?? [:]).keys.sorted()
    }

    func gainCoversAllChannels(of device: AudioDevice, scope: AudioScope) -> Bool {
        !partialGain.contains(key(device, scope)) && !gainElements(of: device, scope: scope).isEmpty
    }

    func gain(of device: AudioDevice, scope: AudioScope, element: UInt32) -> Double? {
        gains[key(device, scope)]?[element]
    }

    func setGain(_ gain: Double, of device: AudioDevice, scope: AudioScope, element: UInt32) throws {
        changes.append("gain.\(key(device, scope)).\(element)=\(gain)")
        if !ignoresChanges.contains(key(device, scope)) { gains[key(device, scope), default: [:]][element] = gain }
    }

    private func key(_ device: AudioDevice, _ scope: AudioScope) -> String { "\(device.uid).\(scope.rawValue)" }
}

// MARK: - Menus

/// A menu tree described as values.
struct MenuSpec {
    var info: MenuNodeInfo
    var children: [MenuSpec] = []

    static func bar(_ menus: [MenuSpec]) -> MenuSpec { MenuSpec(info: MenuNodeInfo(role: "AXMenuBar"), children: menus) }

    /// A top-level menu: an AXMenuBarItem holding an AXMenu.
    static func menu(_ title: String, _ items: [MenuSpec]) -> MenuSpec {
        MenuSpec(
            info: MenuNodeInfo(role: "AXMenuBarItem", title: title),
            children: [MenuSpec(info: MenuNodeInfo(role: "AXMenu"), children: items)])
    }

    static func item(
        _ title: String, character: String? = nil, modifiers: Int? = nil, glyph: Int? = nil,
        virtualKey: Int? = nil, enabled: Bool = true, submenu: [MenuSpec]? = nil
    ) -> MenuSpec {
        MenuSpec(
            info: MenuNodeInfo(
                role: "AXMenuItem", title: title, isEnabled: enabled, commandCharacter: character,
                commandModifiers: modifiers, commandGlyph: glyph, commandVirtualKey: virtualKey),
            children: submenu.map { [MenuSpec(info: MenuNodeInfo(role: "AXMenu"), children: $0)] } ?? [])
    }

    static func separator() -> MenuSpec { MenuSpec(info: MenuNodeInfo(role: "AXMenuItem", title: "")) }
}

/// A menu tree source over value specs. Counts reads, records presses, and can
/// hold the reader at the menu bar until a test lets it go.
final class FakeMenuTree: MenuTreeSource, @unchecked Sendable {
    let isTrusted: Bool
    private let lock = NSLock()
    private var infos: [Int: MenuNodeInfo] = [:]
    private var childTokens: [Int: [Int]] = [:]
    private var roots: [pid_t: Int] = [:]
    private var pressedTokens: [Int] = []
    private var infoReadCounts: [Int: Int] = [:]
    private var childReadCounts: [Int: Int] = [:]
    private var entered = false
    private let gate: DispatchSemaphore?

    init(bars: [pid_t: MenuSpec], trusted: Bool = true, gate: DispatchSemaphore? = nil) {
        isTrusted = trusted
        self.gate = gate
        var next = 1
        var infos: [Int: MenuNodeInfo] = [:]
        var childTokens: [Int: [Int]] = [:]
        func add(_ spec: MenuSpec) -> Int {
            let token = next
            next += 1
            infos[token] = spec.info
            childTokens[token] = spec.children.map(add)
            return token
        }
        var roots: [pid_t: Int] = [:]
        for (pid, bar) in bars { roots[pid] = add(bar) }
        self.infos = infos
        self.childTokens = childTokens
        self.roots = roots
    }

    var hasEntered: Bool { lock.withLock { entered } }
    var pressedTitles: [String] { lock.withLock { pressedTokens.compactMap { infos[$0]?.title } } }
    /// The most times any single node's attributes or children were read.
    var maxReadsPerNode: Int {
        lock.withLock { max(infoReadCounts.values.max() ?? 0, childReadCounts.values.max() ?? 0) }
    }
    var totalInfoReads: Int { lock.withLock { infoReadCounts.values.reduce(0, +) } }

    func menuBar(of pid: pid_t) -> MenuNodeRef? {
        lock.withLock { entered = true }
        gate?.wait()
        return lock.withLock { roots[pid] }.map(MenuNodeRef.init(token:))
    }

    func info(of node: MenuNodeRef) -> MenuNodeInfo {
        lock.withLock {
            infoReadCounts[node.token, default: 0] += 1
            return infos[node.token] ?? MenuNodeInfo()
        }
    }

    func children(of node: MenuNodeRef) -> [MenuNodeRef] {
        lock.withLock {
            childReadCounts[node.token, default: 0] += 1
            return (childTokens[node.token] ?? []).map(MenuNodeRef.init(token:))
        }
    }

    func press(_ node: MenuNodeRef) throws {
        lock.withLock { pressedTokens.append(node.token) }
    }
}

// MARK: - HUD

@MainActor
final class FakeHUDPresenter: HUDPresenting {
    private(set) var presented: [(message: HUDMessage, frame: CGRect)] = []
    private(set) var dismissals = 0

    func size(for message: HUDMessage) -> CGSize { CGSize(width: 240, height: 88) }
    func present(_ message: HUDMessage, in frame: CGRect) { presented.append((message, frame)) }
    func dismiss() { dismissals += 1 }
}

/// Records sleeps without waiting.
final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []

    var durations: [Duration] { lock.withLock { values } }
    func record(_ duration: Duration) { lock.withLock { values.append(duration) } }
}
