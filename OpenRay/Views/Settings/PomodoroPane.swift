import SwiftUI

extension SettingsPane {
    // main: pomodoro, caffeinate
    static let pomodoro = SettingsPane(
        id: "pomodoro", title: "Pomodoro",
        subtitle: "Focus and break lengths, the long-break interval, your daily goal and the chime.",
        kind: .command, symbol: "timer",
        keywords: "pomodoro focus timer break short long interval daily goal sound chime automatic tomato menu bar"
    ) { model, _ in AnyView(PomodoroPane(model: model)) }
}

/// main #10's Pomodoro settings. Each change is saved at once and validated; a running or paused
/// phase keeps its length, and new lengths apply from the next phase.
struct PomodoroPane: View {
    @Bindable var model: LauncherModel

    private var pomodoro: PomodoroService { model.pomodoro }
    private var configuration: PomodoroConfiguration { pomodoro.configuration }

    var body: some View {
        SettingsPaneScaffold(pane: .pomodoro) {
            Section {
                stepper("Focus session", \.focusMinutes, in: 1...180, unit: "min")
                    .accessibilityIdentifier("pomodoro.settings.focusMinutes")
                stepper("Short break", \.shortBreakMinutes, in: 1...60, unit: "min")
                    .accessibilityIdentifier("pomodoro.settings.shortBreakMinutes")
                stepper("Long break", \.longBreakMinutes, in: 1...120, unit: "min")
                    .accessibilityIdentifier("pomodoro.settings.longBreakMinutes")
                stepper("Focus sessions before a long break", \.sessionsBeforeLongBreak, in: 1...12, unit: "")
                    .accessibilityIdentifier("pomodoro.settings.sessionsBeforeLongBreak")
                stepper("Daily goal", \.dailyGoal, in: 1...24, unit: "sessions")
                    .accessibilityIdentifier("pomodoro.settings.dailyGoal")
            } header: {
                Text("Rhythm")
            } footer: {
                Text("A running or paused phase keeps its length. New lengths apply to the next phase.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Phases") {
                Toggle(isOn: binding(\.automaticallyStartBreaks)) {
                    SettingRowLabel(
                        title: "Start breaks automatically",
                        detail: "Focus sessions always start when you're ready.")
                }
                .settingsSwitch()
                .accessibilityIdentifier("pomodoro.settings.automaticallyStartBreaks")
                Toggle(isOn: binding(\.playSound)) {
                    SettingRowLabel(title: "Play a sound when a phase finishes", detail: "Only while OpenRay is running.")
                }
                .settingsSwitch()
                .accessibilityIdentifier("pomodoro.settings.playSound")
            }
            Section("Menu bar") {
                Toggle(isOn: menuBarBinding) {
                    SettingRowLabel(
                        title: "Timer in the menu bar", detail: "While a phase runs or a break is ready: time left and controls.")
                }
                .settingsSwitch()
            }
            Section("How it differs from Focus") {
                IconRow("Pomodoro paces your work in focus and break phases and counts completed sessions.", symbol: "timer")
                IconRow("Focus hides distracting apps for a session. You can use both at once.", symbol: "scope")
            }
            if let error = pomodoro.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OR.Color.warning)
                }
            }
        }
    }

    private func stepper(
        _ title: String, _ path: WritableKeyPath<PomodoroConfiguration, Int>, in range: ClosedRange<Int>, unit: String
    ) -> some View {
        Stepper(value: binding(path), in: range) {
            HStack {
                Text(title)
                Spacer()
                Text(unit.isEmpty ? "\(configuration[keyPath: path])" : "\(configuration[keyPath: path]) \(unit)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<PomodoroConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: path] },
            set: { value in
                var updated = configuration
                updated[keyPath: path] = value
                pomodoro.saveConfiguration(updated)
            })
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { MenuBarExtras.isShown(PomodoroCommandProvider.menuBarID, default: true, in: model.store.database) },
            set: { MenuBarExtras.setShown($0, commandID: PomodoroCommandProvider.menuBarID, in: model.store) })
    }
}
