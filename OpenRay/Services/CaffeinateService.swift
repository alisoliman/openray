import AppKit
import IOKit.pwr_mgt
import Observation

@MainActor
protocol CaffeinatePowerAssertions {
    func create() throws -> UInt32
    func release(_ id: UInt32) throws
}

@MainActor
struct SystemCaffeinatePowerAssertions: CaffeinatePowerAssertions {
    func create() throws -> UInt32 {
        var id: IOPMAssertionID = 0
        // Preventing idle display sleep also prevents idle system sleep. Explicit
        // sleep, closing a laptop's lid, and macOS emergency sleep remain available.
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "OpenRay Caffeinate" as CFString,
            &id)
        guard result == kIOReturnSuccess else {
            throw CaffeinatePowerError(operation: "start", code: result)
        }
        return id
    }

    func release(_ id: UInt32) throws {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else {
            throw CaffeinatePowerError(operation: "stop", code: result)
        }
    }
}

private struct CaffeinatePowerError: LocalizedError {
    let operation: String
    let code: IOReturn

    var errorDescription: String? {
        "macOS could not \(operation) Caffeinate (error \(code)). Please try again."
    }
}

/// Owns one power assertion for this app session. Dates drive the countdown so
/// an explicit sleep or delayed timer never extends a timed session.
@MainActor
@Observable
final class CaffeinateService {
    private(set) var deadline: Date?
    private(set) var errorMessage: String?
    private var assertionID: UInt32?
    private var currentDate: Date
    private var durationSeconds: TimeInterval?
    @ObservationIgnored private let assertions: any CaffeinatePowerAssertions
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let automaticallyMonitors: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var shouldRetryStop = false

    var isActive: Bool { assertionID != nil }

    var remainingSeconds: Int? {
        guard isActive, let deadline, let durationSeconds else { return nil }
        return Int(ceil(min(durationSeconds, max(0, deadline.timeIntervalSince(currentDate)))))
    }

    var statusText: String {
        guard isActive else { return "Off" }
        guard let remainingSeconds else { return "On Indefinitely" }
        let hours = remainingSeconds / 3_600
        let minutes = remainingSeconds % 3_600 / 60
        let seconds = remainingSeconds % 60
        let countdown =
            hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return "On · \(countdown) Remaining"
    }

    init(
        assertions: any CaffeinatePowerAssertions = SystemCaffeinatePowerAssertions(),
        now: @escaping () -> Date = { .now },
        automaticallyMonitors: Bool = true
    ) {
        self.assertions = assertions
        self.now = now
        self.automaticallyMonitors = automaticallyMonitors
        currentDate = now()
    }

    isolated deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let assertionID { try? assertions.release(assertionID) }
    }

    @discardableResult
    func start(for duration: CaffeinateDuration = .indefinitely) -> Bool {
        start(seconds: duration.seconds)
    }

    @discardableResult
    func start(minutes: Int) -> Bool {
        guard (1...1_440).contains(minutes) else {
            errorMessage = "Enter a duration between 1 and 1,440 minutes."
            return false
        }
        return start(seconds: TimeInterval(minutes * 60))
    }

    @discardableResult
    func stop() -> Bool {
        guard let assertionID else {
            clearSession()
            return true
        }
        do {
            try assertions.release(assertionID)
        } catch {
            // Keep ownership and the active indicator until macOS confirms the
            // release. A later refresh or explicit stop retries the same ID.
            errorMessage = error.localizedDescription
            shouldRetryStop = true
            startMonitoring()
            return false
        }
        self.assertionID = nil
        clearSession()
        return true
    }

    @discardableResult
    func toggle() -> Bool {
        isActive ? stop() : start()
    }

    func refresh() {
        currentDate = now()
        guard isActive else { return }
        if shouldRetryStop || deadline.map({ currentDate >= $0 }) == true {
            stop()
        }
    }

    func shutdown() {
        stop()
        stopMonitoring()
    }

    private func start(seconds: TimeInterval?) -> Bool {
        // Reuse an active assertion when changing duration. This keeps the Mac
        // awake continuously and avoids a release/create failure during restart.
        if assertionID == nil {
            do {
                assertionID = try assertions.create()
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        currentDate = now()
        durationSeconds = seconds
        deadline = seconds.map { currentDate.addingTimeInterval($0) }
        errorMessage = nil
        shouldRetryStop = false
        startMonitoring()
        return true
    }

    private func clearSession() {
        deadline = nil
        durationSeconds = nil
        errorMessage = nil
        shouldRetryStop = false
        stopMonitoring()
    }

    private func startMonitoring() {
        guard automaticallyMonitors, timer == nil else { return }
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

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
}
