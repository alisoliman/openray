import Foundation
import Observation

/// Pending controls belong to the launcher session, independently of the
/// running sleep assertion and the dashboard's SwiftUI view lifetime.
@MainActor
@Observable
final class CaffeinateDraft {
    var duration: CaffeinateDuration? = .indefinitely {
        didSet { if duration != oldValue { edited() } }
    }
    var customMinutes = "60" {
        didSet { if customMinutes != oldValue { edited() } }
    }
    var validationMessage: String?
    private(set) var hasPendingChanges = false

    private struct Session: Equatable {
        let isActive: Bool
        let deadline: Date?
    }

    @ObservationIgnored private var lastSession: Session?
    @ObservationIgnored private var isSynchronizing = false

    func refresh(from service: CaffeinateService) {
        let session = Session(isActive: service.isActive, deadline: service.deadline)
        guard !hasPendingChanges, lastSession != session else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        if service.isActive {
            if let seconds = service.remainingSeconds {
                let minutes = max(1, Int(ceil(Double(seconds) / 60)))
                duration = CaffeinateDuration.allCases.first { $0.seconds == Double(minutes * 60) }
                customMinutes = String(minutes)
            } else {
                duration = .indefinitely
            }
        }
        validationMessage = nil
        lastSession = session
    }

    @discardableResult
    func start(using service: CaffeinateService) -> Bool {
        // A menu-bar command may have changed the active session before the
        // dashboard's next render. Untouched controls must follow that change.
        refresh(from: service)
        validationMessage = nil
        let succeeded: Bool
        if let duration {
            succeeded = service.start(for: duration)
        } else if let minutes = Int(customMinutes.trimmingCharacters(in: .whitespacesAndNewlines)),
            (1...1440).contains(minutes)
        {
            succeeded = service.start(minutes: minutes)
        } else {
            validationMessage = "Enter a whole number of minutes from 1 to 1,440."
            return false
        }
        if succeeded {
            hasPendingChanges = false
            lastSession = Session(isActive: service.isActive, deadline: service.deadline)
        }
        return succeeded
    }

    private func edited() {
        guard !isSynchronizing else { return }
        hasPendingChanges = true
        validationMessage = nil
    }
}
