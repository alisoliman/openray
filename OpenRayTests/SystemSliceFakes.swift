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
        title: String = "", frame: CGRect = CGRect(x: 100, y: 200, width: 600, height: 400), minimized: Bool = false
    ) -> WindowSnapshot {
        WindowSnapshot(
            handle: WindowHandle(pid: pid, token: token), appName: app, bundleIdentifier: bundle, bundleURL: nil,
            title: title, frame: frame, isMinimized: minimized)
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
    /// Windows whose frame can't change, like fixed-size panels.
    var lockedTokens: Set<Int> = []
    private(set) var events: [Event] = []
    private(set) var trustRequests = 0

    init(displays: [DisplaySnapshot] = [WindowFixture.laptop], windows: [WindowSnapshot] = []) {
        displayList = displays
        windowList = windows
    }

    func requestTrust() { trustRequests += 1 }
    func displays() -> [DisplaySnapshot] { displayList }

    func windows(includeMinimized: Bool) -> [WindowSnapshot] {
        includeMinimized ? windowList : windowList.filter { !$0.isMinimized }
    }

    func focusedWindow(of pid: pid_t) -> WindowHandle? {
        focusedWindows[pid] ?? windowList.first { $0.pid == pid && !$0.isMinimized }?.handle
    }

    func isRunning(_ pid: pid_t) -> Bool { runningPIDs.contains(pid) || windowList.contains { $0.pid == pid } }

    func title(of window: WindowHandle) -> String? { windowList.first { $0.handle == window }?.title }

    func frame(of window: WindowHandle) throws -> CGRect {
        windowList[try index(of: window)].frame
    }

    func setFrame(_ frame: CGRect, of window: WindowHandle) throws {
        let index = try index(of: window)
        guard !lockedTokens.contains(window.token) else { throw LibraryValidationError("Fixed size.") }
        windowList[index].frame = frame
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
        events.append(.focus(window.token))
    }

    func close(_ window: WindowHandle) throws {
        windowList.remove(at: try index(of: window))
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

    var outputs = [speakers, headphones]
    var inputs = [microphone]
    var defaults: [AudioScope: AudioDevice] = [.output: speakers, .input: microphone]
    var volumes: [String: Double] = ["speakers.output": 0.5, "headphones.output": 0.25, "mic.input": 0.6]
    var mutes: [String: Bool] = ["speakers.output": false, "headphones.output": false]
    var volumeless: Set<String> = []
    var unmutable: Set<String> = ["mic.input"]
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
        mutes[key(device, scope)] = muted
        changes.append("mute.\(key(device, scope))=\(muted)")
    }

    func canSetVolume(of device: AudioDevice, scope: AudioScope) -> Bool {
        !volumeless.contains(key(device, scope)) && volumes[key(device, scope)] != nil
    }

    func canMute(_ device: AudioDevice, scope: AudioScope) -> Bool { !unmutable.contains(key(device, scope)) }

    private func key(_ device: AudioDevice, _ scope: AudioScope) -> String { "\(device.uid).\(scope.rawValue)" }
}

// MARK: - Menus

@MainActor
final class FakeMenuElement: MenuAXElement {
    var role: String?
    var title: String?
    var isEnabled: Bool
    var commandCharacter: String?
    var commandModifiers: Int?
    var commandGlyph: Int?
    var commandVirtualKey: Int?
    var children: [any MenuAXElement]
    private(set) var pressCount = 0

    init(
        role: String, title: String? = nil, enabled: Bool = true, character: String? = nil, modifiers: Int? = nil,
        glyph: Int? = nil, children: [any MenuAXElement] = []
    ) {
        self.role = role
        self.title = title
        isEnabled = enabled
        commandCharacter = character
        commandModifiers = modifiers
        commandGlyph = glyph
        self.children = children
    }

    func press() throws { pressCount += 1 }

    static func bar(_ menus: [FakeMenuElement]) -> FakeMenuElement {
        FakeMenuElement(role: "AXMenuBar", children: menus)
    }

    /// A top-level menu: an AXMenuBarItem holding an AXMenu.
    static func menu(_ title: String, _ items: [FakeMenuElement]) -> FakeMenuElement {
        FakeMenuElement(
            role: "AXMenuBarItem", title: title, children: [FakeMenuElement(role: "AXMenu", children: items)])
    }

    static func item(
        _ title: String, character: String? = nil, modifiers: Int? = nil, glyph: Int? = nil, enabled: Bool = true,
        submenu: [FakeMenuElement]? = nil
    ) -> FakeMenuElement {
        FakeMenuElement(
            role: "AXMenuItem", title: title, enabled: enabled, character: character, modifiers: modifiers,
            glyph: glyph, children: submenu.map { [FakeMenuElement(role: "AXMenu", children: $0)] } ?? [])
    }

    static func separator() -> FakeMenuElement { FakeMenuElement(role: "AXMenuItem", title: "") }
}

@MainActor
final class FakeMenuBarProvider: MenuBarProviding {
    var isTrusted = true
    var bars: [pid_t: FakeMenuElement] = [:]
    func menuBar(of pid: pid_t) -> (any MenuAXElement)? { bars[pid] }
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
