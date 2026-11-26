import AppKit
import SwiftUI

@main
struct OpenRayApp: App {
    @NSApplicationDelegateAdaptor(OpenRayDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(isInserted: iconIsShown) {
            MenuBarContent(model: delegate.model)
        } label: {
            Image(nsImage: ORMarkImage.menuBar(paused: capturePaused))
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.model.openSettings() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) { OpenRayHelpButton(model: delegate.model) }
        }
    }

    /// The menu bar icon carries state: an amber dot means capture is paused.
    private var capturePaused: Bool { delegate.model.store.database.clipboardIsPaused }

    /// Settings › Menu Bar can hide the icon; the launcher still opens Settings.
    private var iconIsShown: Binding<Bool> {
        Binding(
            get: { !MenuBarExtras.hidesOpenRayIcon(in: delegate.model.store.database) },
            set: { MenuBarExtras.setHidesOpenRayIcon(!$0, in: delegate.model.store) })
    }
}

/// Shortcuts show the person's actual bindings, read from the library.
private struct MenuBarContent: View {
    let model: LauncherModel

    var body: some View {
        let preferences = model.store.database.preferences
        Button("Open OpenRay") { model.panel?.show(section: .home) }
            .menuShortcut(model.launcherShortcutInUse)
        Button("Clipboard History") { model.panel?.show(section: .clipboard) }
            .menuShortcut(model.store.database.binding(for: "section.clipboard")?.shortcut)
        Button("Ask AI") {
            model.panel?.show()
            // Navigating away would hide the editor's unsaved changes behind AI.
            if model.editor == nil {
                model.openAI()
            } else {
                model.feedback = .warning("Save or cancel the current editor first.")
            }
        }
        .menuShortcut(model.store.database.binding(for: "ai.chat")?.shortcut)
        Button("Notes") { NotesCenter.shared.model(for: model.store).toggle() }
            .menuShortcut(model.store.database.binding(for: NotesCommandProvider.toggleID)?.shortcut)
        Divider()
        // main: pomodoro, caffeinate. Their menu bar extras show while they run; these start them.
        PomodoroMenuSection(model: model)
        Menu("Caffeinate") { MenuBarItemsView(items: CaffeinateCommandProvider.menuItems(in: model)) }
        Divider()
        if preferences.clipboardEnabled {
            Text("Clipboard capture is on")
            Button("Pause Capture", systemImage: "pause.fill") { model.setClipboardCapture(false) }
        } else if model.store.database.clipboardIsPaused {
            Text("Clipboard capture is paused")
            Button("Resume Capture", systemImage: "play.fill") { model.setClipboardCapture(true) }
        } else {
            Button("Turn On Clipboard History…") { model.panel?.show(section: .clipboard) }
        }
        Divider()
        Button("Settings…") { model.openSettings() }
            .keyboardShortcut(",")
        Button("OpenRay Help") { model.openHelp() }
        Divider()
        Button("Quit OpenRay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// main #10's Pomodoro entries in OpenRay's menu: start, pause or resume, and today's progress.
private struct PomodoroMenuSection: View {
    let model: LauncherModel

    var body: some View {
        let pomodoro = model.pomodoro
        let state = pomodoro.state
        Button(state.status == .running ? "Pause Pomodoro" : (state.status == .paused ? "Resume Pomodoro" : "Start Pomodoro")) {
            if pomodoro.state.status == .running { pomodoro.pause() } else { pomodoro.start() }
        }
        .menuShortcut(
            model.store.database.binding(for: PomodoroCommandProvider.startID)?.shortcut.flatMap {
                state.status == .running ? nil : $0
            })
        Button("Open Pomodoro") { model.panel?.show(section: .provided(PomodoroCommandProvider.scope)) }
            .menuShortcut(model.store.database.binding(for: PomodoroCommandProvider.openID)?.shortcut)
        Text("Today: \(pomodoro.completedToday)/\(pomodoro.configuration.dailyGoal) sessions · \(pomodoro.focusMinutesToday) min")
    }
}

/// A provider's menu bar items drawn in OpenRay's SwiftUI menu, so both menus say the same.
struct MenuBarItemsView: View {
    let items: [MenuBarExtraItem]

    var body: some View {
        ForEach(items) { item in
            switch item.role {
            case .separator: Divider()
            case .section, .label: Text(item.title)
            case .action:
                if item.children.isEmpty {
                    Button(item.title) { item.perform?() }.disabled(!item.isEnabled || item.perform == nil)
                } else {
                    Menu(item.title) { MenuBarItemsView(items: item.children) }
                }
            }
        }
    }
}

extension View {
    /// Shows a global shortcut beside a menu item. Menu key equivalents only fire
    /// while the menu is open, so this displays the binding without duplicating it.
    @ViewBuilder func menuShortcut(_ shortcut: CommandShortcut?) -> some View {
        if let shortcut, let equivalent = shortcut.keyEquivalent {
            keyboardShortcut(equivalent, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}

extension CommandShortcut {
    /// The menu key equivalent, or nil when a menu item can't show the key, such as
    /// keypad keys (a menu can't tell them from the main keys) and Help.
    var keyEquivalent: KeyEquivalent? {
        switch keyCode {
        case 49: return .space
        case 36: return .return
        case 48: return .tab
        case 51: return .delete
        case 117: return .deleteForward
        case 53: return .escape
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default:
            if let number = functionKeyNumber {
                return UnicodeScalar(UInt32(NSF1FunctionKey + number - 1)).map { KeyEquivalent(Character($0)) }
            }
            // The layout's own character, not the uppercased cap, so “ß” isn't dropped.
            guard usesPrintableKey, let character = layoutCharacter ?? caps.last?.lowercased(), character.count == 1
            else { return nil }
            return KeyEquivalent(Character(character))
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}
