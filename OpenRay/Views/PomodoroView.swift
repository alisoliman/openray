import SwiftUI

struct PomodoroView: View {
    @Bindable var model: LauncherModel

    private var pomodoro: PomodoroService { model.pomodoro }
    private var phaseColor: Color { pomodoro.state.phase == .focus ? RayStyle.accent : .green }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if let error = pomodoro.errorMessage { StatusBanner(message: error) }
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    timerCard.frame(maxWidth: .infinity)
                    VStack(spacing: 14) {
                        todayCard
                        historyCard
                    }.frame(width: 260)
                }.padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.6)
            HStack(spacing: 7) {
                Image(systemName: "timer")
                Text("Your timer continues when the launcher closes.")
                Spacer()
                Keycap(text: "↩")
                Text(primaryActionTitle)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).frame(height: 36)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BackButton { model.goBack() }
            Image(systemName: "timer").font(.system(size: 21)).foregroundStyle(RayStyle.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pomodoro").font(.system(size: 15, weight: .semibold))
                Text("One focus session at a time").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings", systemImage: "slider.horizontal.3") { model.openSettings() }
                .font(.system(size: 12)).buttonStyle(.borderless)
                .accessibilityLabel("Open Pomodoro settings")
                .accessibilityIdentifier("pomodoro.settings")
        }.padding(.horizontal, 20).frame(height: 64)
    }

    private var timerCard: some View {
        VStack(spacing: 16) {
            HStack {
                Label(pomodoro.state.phase.title, systemImage: pomodoro.state.phase.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(phaseColor)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(phaseColor.opacity(0.1), in: .capsule)
                Spacer()
                Text(statusTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ZStack {
                    Circle().stroke(.primary.opacity(0.06), lineWidth: 8)
                    Circle().trim(from: 0, to: min(1, max(0, pomodoro.progress)))
                        .stroke(phaseColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 8) {
                        Text(countdown)
                            .font(.system(size: 46, weight: .medium, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .accessibilityIdentifier("pomodoro.countdown")
                        Text(timerCaption).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 198, height: 198)
                .padding(4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(pomodoro.state.phase.title) timer")
                .accessibilityValue(
                    "\(pomodoro.remainingSeconds / 60) minutes, \(pomodoro.remainingSeconds % 60) seconds remaining. \(statusTitle)"
                )
            }

            HStack(spacing: 7) {
                ForEach(0..<pomodoro.configuration.sessionsBeforeLongBreak, id: \.self) { index in
                    Circle().fill(index < pomodoro.state.completedInCycle ? phaseColor : .primary.opacity(0.1))
                        .frame(width: 7, height: 7)
                }
                Text(
                    "\(pomodoro.state.completedInCycle) / \(pomodoro.configuration.sessionsBeforeLongBreak) this cycle"
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(pomodoro.state.completedInCycle) of \(pomodoro.configuration.sessionsBeforeLongBreak) focus sessions completed this cycle"
            )

            Button(action: primaryAction) {
                Label(primaryActionTitle, systemImage: pomodoro.state.status == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).tint(phaseColor)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityIdentifier("pomodoro.primaryAction")

            HStack(spacing: 18) {
                Button("Reset Cycle", systemImage: "arrow.counterclockwise") { pomodoro.reset() }
                    .disabled(!canReset)
                    .help("Return to a fresh focus timer. Completed sessions stay in your history.")
                    .accessibilityIdentifier("pomodoro.reset")
                if pomodoro.state.phase != .focus {
                    Button("Skip Break", systemImage: "forward.end") { pomodoro.skipBreak() }
                        .accessibilityIdentifier("pomodoro.skipBreak")
                }
            }.font(.system(size: 11)).buttonStyle(.borderless)
        }
        .padding(18)
        .background(.primary.opacity(0.025), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)) }
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Today").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Date.now, format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                metric(value: "\(pomodoro.completedToday)", label: "sessions")
                Divider().frame(height: 33).padding(.horizontal, 18)
                metric(value: "\(pomodoro.focusMinutesToday)", label: "focus minutes")
            }
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(Double(pomodoro.completedToday) / Double(pomodoro.configuration.dailyGoal), 1))
                    .tint(RayStyle.accent)
                    .accessibilityLabel("Daily focus goal")
                    .accessibilityValue("\(pomodoro.completedToday) of \(pomodoro.configuration.dailyGoal) sessions")
                Text(
                    pomodoro.completedToday >= pomodoro.configuration.dailyGoal
                        ? "Daily goal reached. Well done."
                        : "\(max(0, pomodoro.configuration.dailyGoal - pomodoro.completedToday)) more to your daily goal of \(pomodoro.configuration.dailyGoal)"
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(16)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12))
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent focus sessions").font(.system(size: 13, weight: .semibold))
            if pomodoro.recentSessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("Make room for a little focus.").font(.system(size: 12, weight: .medium))
                    Text(
                        "Completed focus sessions appear here. Breaks and unfinished sessions don’t count toward your goal."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                }.frame(maxWidth: .infinity, minHeight: 153, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(pomodoro.recentSessions.prefix(20)) { session in
                            HStack(spacing: 9) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    .font(.system(size: 13)).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(session.durationSeconds / 60) min of focus")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(
                                        session.completedAt, format: .dateTime.month(.abbreviated).day().hour().minute()
                                    )
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.accessibilityElement(children: .combine)
                        }
                    }.padding(.trailing, 3)
                }.frame(height: 153)
            }
        }.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)) }
    }

    private var countdown: String {
        let seconds = max(0, pomodoro.remainingSeconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var statusTitle: String {
        switch pomodoro.state.status {
        case .ready: "Ready"
        case .running: "In progress"
        case .paused: "Paused"
        }
    }

    private var timerCaption: String {
        switch pomodoro.state.status {
        case .ready: "Ready when you are"
        case .running: pomodoro.state.phase == .focus ? "Focus on one thing" : "Take a moment to recharge"
        case .paused: "Take your time"
        }
    }

    private var primaryActionTitle: String {
        switch pomodoro.state.status {
        case .ready: pomodoro.state.phase == .focus ? "Start Focus" : "Start Break"
        case .running: "Pause"
        case .paused: "Resume"
        }
    }

    private var canReset: Bool {
        pomodoro.state.status != .ready || pomodoro.state.phase != .focus || pomodoro.state.completedInCycle > 0
    }

    private func primaryAction() {
        if pomodoro.state.status == .running { pomodoro.pause() } else { pomodoro.start() }
    }
}

struct PomodoroSettingsSection: View {
    let service: PomodoroService
    @State private var draft = PomodoroConfiguration()
    @State private var hasLoaded = false
    @State private var saveMessage: String?
    @State private var saveFailed = false

    var body: some View {
        Section {
            Text("Set a focus rhythm that works for you. Completed focus sessions are saved locally.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            durationSetting("Focus session", minutes: $draft.focusMinutes, range: 1...180)
                .accessibilityIdentifier("pomodoro.settings.focusMinutes")
            durationSetting("Short break", minutes: $draft.shortBreakMinutes, range: 1...60)
                .accessibilityIdentifier("pomodoro.settings.shortBreakMinutes")
            durationSetting("Long break", minutes: $draft.longBreakMinutes, range: 1...120)
                .accessibilityIdentifier("pomodoro.settings.longBreakMinutes")
            Stepper(value: $draft.sessionsBeforeLongBreak, in: 1...12) {
                settingLabel("Focus sessions before a long break", value: "\(draft.sessionsBeforeLongBreak)")
            }.accessibilityIdentifier("pomodoro.settings.sessionsBeforeLongBreak")
            Stepper(value: $draft.dailyGoal, in: 1...24) {
                settingLabel("Daily goal", value: "\(draft.dailyGoal) sessions")
            }.accessibilityIdentifier("pomodoro.settings.dailyGoal")
            Toggle("Start breaks automatically", isOn: $draft.automaticallyStartBreaks)
                .accessibilityIdentifier("pomodoro.settings.automaticallyStartBreaks")
            Toggle("Play a sound when a phase finishes", isOn: $draft.playSound)
                .accessibilityIdentifier("pomodoro.settings.playSound")
            Text(
                "Focus sessions always start when you’re ready. Running or paused timers keep their current duration; new durations apply to the next phase."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Save Pomodoro Settings") {
                    saveFailed = !service.saveConfiguration(draft)
                    saveMessage =
                        saveFailed
                        ? service.errorMessage ?? "Could not save Pomodoro settings." : "Pomodoro settings saved."
                }
                .buttonStyle(.bordered)
                .disabled(draft == service.configuration)
                .accessibilityIdentifier("pomodoro.settings.save")
                if let saveMessage {
                    Label(saveMessage, systemImage: saveFailed ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(saveFailed ? Color.orange : .secondary)
                }
            }
        } header: {
            Label("Pomodoro", systemImage: "timer")
        }
        .onAppear {
            guard !hasLoaded else { return }
            draft = service.configuration
            hasLoaded = true
        }
        .onChange(of: draft) { saveMessage = nil }
    }

    private func durationSetting(_ title: String, minutes: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: minutes, in: range) {
            settingLabel(title, value: "\(minutes.wrappedValue) min")
        }
    }

    private func settingLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
