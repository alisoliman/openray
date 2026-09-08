import Foundation

enum CaffeinateDuration: String, CaseIterable, Identifiable, Sendable {
    case indefinitely
    case tenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case eightHours
    case twelveHours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indefinitely: "Indefinitely"
        case .tenMinutes: "10 Minutes"
        case .thirtyMinutes: "30 Minutes"
        case .oneHour: "1 Hour"
        case .twoHours: "2 Hours"
        case .fourHours: "4 Hours"
        case .eightHours: "8 Hours"
        case .twelveHours: "12 Hours"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .indefinitely: nil
        case .tenMinutes: 10 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .fourHours: 4 * 60 * 60
        case .eightHours: 8 * 60 * 60
        case .twelveHours: 12 * 60 * 60
        }
    }
}
