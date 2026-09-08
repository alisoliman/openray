import AppKit
import Observation

/// Persists phase changes atomically; the visible countdown is derived from a deadline.
@MainActor
@Observable
final class PomodoroService {
    private(set) var errorMessage: String?
    private var currentDate: Date
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let playCompletionSound: () -> Void
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    var configuration: PomodoroConfiguration { store.database.pomodoro.configuration }
    var state: PomodoroState { store.database.pomodoro.state }
    var remainingSeconds: Int { state.remainingSeconds(at: currentDate) }
    var progress: Double { 1 - Double(remainingSeconds) / Double(state.durationSeconds) }
    var completedToday: Int { todaySessions.count }
    var focusMinutesToday: Int { todaySessions.reduce(0) { $0 + $1.durationSeconds } / 60 }
    var recentSessions: [PomodoroSession] {
        Array(store.database.pomodoro.sessions.sorted { $0.completedAt > $1.completedAt }.prefix(20))
    }

    private var todaySessions: [PomodoroSession] {
        store.database.pomodoro.sessions.filter {
            Calendar.current.isDate($0.completedAt, inSameDayAs: currentDate)
        }
    }

    init(
        store: LibraryStore, now: @escaping () -> Date = { .now },
        playCompletionSound: @escaping () -> Void = { NSSound(named: "Glass")?.play() }
    ) {
        self.store = store
        self.now = now
        self.playCompletionSound = playCompletionSound
        currentDate = now()
        refresh(at: currentDate)
    }

    func startMonitoring() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    @discardableResult
    func refresh() -> Bool { refresh(at: now()) }

    @discardableResult
    func refresh(at date: Date) -> Bool {
        currentDate = date
        guard state.status == .running, let deadline = state.deadline, date >= deadline else { return true }
        var next = store.database.pomodoro
        let finished = next.state
        if finished.phase == .focus {
            guard let startedAt = finished.startedAt else { return false }
            next.sessions.append(
                PomodoroSession(
                    startedAt: startedAt, completedAt: deadline, durationSeconds: finished.durationSeconds))
            let completed = finished.completedInCycle + 1
            let phase: PomodoroPhase = completed >= configuration.sessionsBeforeLongBreak ? .longBreak : .shortBreak
            next.state = .ready(phase: phase, configuration: configuration, completedInCycle: completed)
            if configuration.automaticallyStartBreaks {
                next.state.status = .running
                next.state.startedAt = date
                next.state.deadline = date.addingTimeInterval(Double(next.state.durationSeconds))
            }
        } else {
            next.state = .ready(
                phase: .focus, configuration: configuration,
                completedInCycle: finished.phase == .longBreak ? 0 : finished.completedInCycle)
        }
        guard commit(next) else { return false }
        if configuration.playSound { playCompletionSound() }
        return true
    }

    func start() {
        let date = now()
        guard refresh(at: date), state.status != .running else { return }
        var next = store.database.pomodoro
        next.state.status = .running
        next.state.startedAt = next.state.startedAt ?? date
        next.state.deadline = date.addingTimeInterval(Double(next.state.remainingSeconds))
        commit(next)
    }

    func pause() {
        let date = now()
        guard refresh(at: date), state.status == .running else { return }
        var next = store.database.pomodoro
        next.state.remainingSeconds = state.remainingSeconds(at: date)
        next.state.status = .paused
        next.state.deadline = nil
        commit(next)
    }

    func reset() {
        guard refresh() else { return }
        var next = store.database.pomodoro
        next.state = .ready(phase: .focus, configuration: configuration, completedInCycle: 0)
        commit(next)
    }

    func skipBreak() {
        guard refresh(), state.phase != .focus else { return }
        var next = store.database.pomodoro
        next.state = .ready(
            phase: .focus, configuration: configuration,
            completedInCycle: state.phase == .longBreak ? 0 : state.completedInCycle)
        commit(next)
    }

    @discardableResult
    func saveConfiguration(_ configuration: PomodoroConfiguration) -> Bool {
        do { try configuration.validate() } catch {
            errorMessage = error.localizedDescription
            return false
        }
        guard refresh() else { return false }
        var next = store.database.pomodoro
        next.configuration = configuration
        if next.state.status == .ready {
            next.state = .ready(
                phase: state.phase, configuration: configuration, completedInCycle: state.completedInCycle)
        }
        return commit(next)
    }

    @discardableResult
    private func commit(_ data: PomodoroData) -> Bool {
        guard store.update({ $0.pomodoro = data }) else {
            errorMessage = store.errorMessage ?? "Your Pomodoro changes could not be saved. Please try again."
            return false
        }
        errorMessage = nil
        return true
    }
}
