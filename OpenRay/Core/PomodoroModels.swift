import Foundation

struct PomodoroConfiguration: Codable, Equatable, Sendable {
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var sessionsBeforeLongBreak = 4
    var dailyGoal = 8
    var automaticallyStartBreaks = false
    var playSound = true

    func validate() throws {
        guard (1...180).contains(focusMinutes), (1...60).contains(shortBreakMinutes),
            (1...120).contains(longBreakMinutes), (1...12).contains(sessionsBeforeLongBreak),
            (1...24).contains(dailyGoal)
        else {
            throw LibraryValidationError(
                "Choose focus sessions of 1–180 minutes, short breaks of 1–60 minutes, long breaks of 1–120 minutes, 1–12 sessions per cycle, and a daily goal of 1–24 sessions."
            )
        }
    }

    func durationSeconds(for phase: PomodoroPhase) -> Int {
        switch phase {
        case .focus: focusMinutes * 60
        case .shortBreak: shortBreakMinutes * 60
        case .longBreak: longBreakMinutes * 60
        }
    }
}

enum PomodoroPhase: String, Codable, CaseIterable, Sendable {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short Break"
        case .longBreak: "Long Break"
        }
    }

    var symbol: String {
        switch self {
        case .focus: "timer"
        case .shortBreak: "cup.and.saucer"
        case .longBreak: "leaf"
        }
    }
}

enum PomodoroStatus: String, Codable, Sendable {
    case ready, running, paused
}

struct PomodoroState: Codable, Equatable, Sendable {
    var phase: PomodoroPhase = .focus
    var status: PomodoroStatus = .ready
    var completedInCycle = 0
    var durationSeconds = 25 * 60
    /// The time left at the last start or pause. Running timers use their deadline.
    var remainingSeconds = 25 * 60
    var deadline: Date?
    var startedAt: Date?

    static func ready(
        phase: PomodoroPhase, configuration: PomodoroConfiguration, completedInCycle: Int
    ) -> Self {
        let duration = configuration.durationSeconds(for: phase)
        return Self(
            phase: phase, completedInCycle: completedInCycle,
            durationSeconds: duration, remainingSeconds: duration)
    }

    func remainingSeconds(at date: Date) -> Int {
        guard status == .running, let deadline else { return remainingSeconds }
        let seconds = deadline.timeIntervalSince(date)
        // Clamp before converting to Int, including when the system clock moves backward.
        return Int(ceil(min(Double(durationSeconds), max(0, seconds))))
    }

    func validate() throws {
        let maximumMinutes = phase == .focus ? 180 : (phase == .shortBreak ? 60 : 120)
        guard (60...(maximumMinutes * 60)).contains(durationSeconds), durationSeconds.isMultiple(of: 60),
            (1...durationSeconds).contains(remainingSeconds), (0...12).contains(completedInCycle),
            startedAt?.timeIntervalSinceReferenceDate.isFinite != false,
            deadline?.timeIntervalSinceReferenceDate.isFinite != false
        else { throw LibraryValidationError("The library contains an invalid Pomodoro timer.") }
        let validCycleCount =
            switch phase {
            case .focus: (0...11).contains(completedInCycle)
            case .shortBreak: (1...11).contains(completedInCycle)
            case .longBreak: (1...12).contains(completedInCycle)
            }
        guard validCycleCount else {
            throw LibraryValidationError("The library contains an invalid Pomodoro cycle.")
        }
        switch status {
        case .ready:
            guard startedAt == nil, deadline == nil, remainingSeconds == durationSeconds else {
                throw LibraryValidationError("A ready Pomodoro timer contains active session data.")
            }
        case .running:
            guard let startedAt, let deadline, deadline > startedAt else {
                throw LibraryValidationError("A running Pomodoro timer is missing its start or deadline.")
            }
        case .paused:
            guard startedAt != nil, deadline == nil else {
                throw LibraryValidationError("A paused Pomodoro timer contains an invalid deadline.")
            }
        }
    }
}

struct PomodoroSession: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var startedAt: Date
    var completedAt: Date
    var durationSeconds: Int

    func validate() throws {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
            completedAt.timeIntervalSinceReferenceDate.isFinite, completedAt > startedAt,
            (60...(180 * 60)).contains(durationSeconds), durationSeconds.isMultiple(of: 60)
        else { throw LibraryValidationError("The library contains an invalid Pomodoro session.") }
    }
}

struct PomodoroData: Codable, Equatable, Sendable {
    var configuration = PomodoroConfiguration()
    var state = PomodoroState()
    var sessions: [PomodoroSession] = []

    func validate() throws {
        try configuration.validate()
        try state.validate()
        guard state.status != .ready || state.durationSeconds == configuration.durationSeconds(for: state.phase) else {
            throw LibraryValidationError("The ready Pomodoro timer does not match its configuration.")
        }
        guard Set(sessions.map(\.id)).count == sessions.count else {
            throw LibraryValidationError("The library contains duplicate Pomodoro sessions.")
        }
        for session in sessions { try session.validate() }
    }
}
