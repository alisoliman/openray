import SwiftUI

struct PomodoroMenuBarLabel: View {
    let service: PomodoroService

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "command.square.fill")
            if service.state.status != .ready {
                if service.state.status == .paused {
                    Image(systemName: "pause.fill")
                }
                Text(countdown).monospacedDigit()
            } else if service.state.phase != .focus {
                Text("Break")
            }
        }
        .accessibilityLabel(
            service.state.status == .ready
                ? "OpenRay, \(service.state.phase.title) ready"
                : "OpenRay, \(service.state.phase.title), \(countdown), \(service.state.status.rawValue)")
    }

    private var countdown: String {
        String(format: "%02d:%02d", service.remainingSeconds / 60, service.remainingSeconds % 60)
    }
}

struct PomodoroMenuContent: View {
    let model: LauncherModel

    var body: some View {
        Button("Pomodoro — \(model.pomodoro.state.phase.title)") {
            model.openPomodoro()
            model.panel?.show()
        }
        if model.pomodoro.state.status == .running {
            Button("Pause Timer") { model.pomodoro.pause() }
        } else {
            Button(
                model.pomodoro.state.status == .paused ? "Resume Timer" : "Start \(model.pomodoro.state.phase.title)"
            ) {
                model.openPomodoro(start: true)
                model.panel?.show()
            }
        }
        Text(
            "Today: \(model.pomodoro.completedToday)/\(model.pomodoro.configuration.dailyGoal) sessions · \(model.pomodoro.focusMinutesToday) min"
        )
        if let error = model.pomodoro.errorMessage {
            Text(error)
        }
    }
}
