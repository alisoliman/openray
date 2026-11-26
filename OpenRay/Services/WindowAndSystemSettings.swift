import Foundation

/// Window Management settings, stored in `commandPreferences["window.settings"]`. Values are
/// clamped when read, so a damaged or hand-edited library can't set huge gaps.
struct WindowManagementSettings: Equatable, Sendable {
    static let storageKey = "window.settings"

    var gaps = WindowGaps.zero
    /// Repeating Left, Right, Top or Bottom Half steps through 1/2, 2/3 and 1/3.
    var cyclesHalves = false

    init(gaps: WindowGaps = .zero, cyclesHalves: Bool = false) {
        self.gaps = gaps
        self.cyclesHalves = cyclesHalves
    }

    init(_ values: [String: String]?) {
        let values = values ?? [:]
        gaps = WindowGaps(
            window: values["windowGap"].flatMap(Double.init) ?? 0, screen: values["screenGap"].flatMap(Double.init) ?? 0)
        cyclesHalves = values["cyclesHalves"] == "true"
    }

    var values: [String: String] {
        ["windowGap": Self.format(gaps.window), "screenGap": Self.format(gaps.screen), "cyclesHalves": String(cyclesHalves)]
    }

    var managerSettings: WindowManager.Settings {
        WindowManager.Settings(gaps: gaps, cyclesHalves: cyclesHalves)
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// System command settings, stored in `commandPreferences["system.settings"]`.
struct SystemCommandSettings: Equatable, Sendable {
    static let storageKey = "system.settings"

    /// Empty Trash asks first. On by default.
    var confirmsEmptyingTrash = true
    /// Quit All Apps and Quit Others ask first. On by default.
    var confirmsQuittingApps = true
    /// Bundle identifiers Quit All Apps leaves running, in the order they were added.
    var quitExclusions: [String] = []

    init(confirmsEmptyingTrash: Bool = true, confirmsQuittingApps: Bool = true, quitExclusions: [String] = []) {
        self.confirmsEmptyingTrash = confirmsEmptyingTrash
        self.confirmsQuittingApps = confirmsQuittingApps
        self.quitExclusions = quitExclusions
    }

    init(_ values: [String: String]?) {
        let values = values ?? [:]
        confirmsEmptyingTrash = values["confirmEmptyTrash"] != "false"
        confirmsQuittingApps = values["confirmQuitApps"] != "false"
        var seen = Set<String>()
        quitExclusions = (values["quitExclusions"] ?? "").split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var values: [String: String] {
        [
            "confirmEmptyTrash": String(confirmsEmptyingTrash), "confirmQuitApps": String(confirmsQuittingApps),
            "quitExclusions": quitExclusions.joined(separator: "\n"),
        ]
    }

    /// Restart, Shut Down and Log Out always ask; Empty Trash and the quit commands follow the settings.
    func asksFirst(_ id: SystemCommand.ID) -> Bool {
        switch id {
        case .emptyTrash: confirmsEmptyingTrash
        case .quitAllApps, .quitAllAppsExceptFrontmost: confirmsQuittingApps
        default: SystemCommand.command(id).needsConfirmation
        }
    }
}

extension LibraryDatabase {
    var windowManagementSettings: WindowManagementSettings {
        get { WindowManagementSettings(commandPreferences[WindowManagementSettings.storageKey]) }
        set { commandPreferences[WindowManagementSettings.storageKey] = newValue.values }
    }

    var systemCommandSettings: SystemCommandSettings {
        get { SystemCommandSettings(commandPreferences[SystemCommandSettings.storageKey]) }
        set { commandPreferences[SystemCommandSettings.storageKey] = newValue.values }
    }
}
