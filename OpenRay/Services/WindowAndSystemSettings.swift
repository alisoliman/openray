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
    /// Where builds before the shared Keep Running list saved Quit All exclusions. Read once and
    /// moved into `LibraryDatabase.keepRunningBundleIDs` on the next write; never written.
    static let legacyExclusionsKey = "quitExclusions"

    /// Commands that can't be undone. They always ask, whatever is saved: no setting turns their
    /// question off. (Force Quit, in Applications, always asks too.) Earlier builds saved
    /// `confirmEmptyTrash` and `confirmQuitApps`; both are ignored and dropped on the next write.
    static let alwaysConfirmed: Set<SystemCommand.ID> = [
        .emptyTrash, .shutDown, .restart, .logOut, .quitAllApps, .quitAllAppsExceptFrontmost,
    ]

    /// Hide Others asks first. On by default. Hiding is undone by Unhide All Apps, so this one
    /// question may be turned off. It has its own key, so no earlier quit setting turns it off.
    var confirmsHidingOtherApps = true

    init(confirmsHidingOtherApps: Bool = true) {
        self.confirmsHidingOtherApps = confirmsHidingOtherApps
    }

    init(_ values: [String: String]?) {
        confirmsHidingOtherApps = values?["confirmHideOthers"] != "false"
    }

    var values: [String: String] {
        ["confirmHideOthers": String(confirmsHidingOtherApps)]
    }

    /// Exclusions an earlier build saved here, in order, without duplicates.
    static func legacyExclusions(_ values: [String: String]?) -> [String] {
        unique((values?[legacyExclusionsKey] ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Every command that can't be undone asks; Hide Others follows its setting. Quit All and Quit
    /// Others ask in Applications' batch flow, which names the apps.
    func asksFirst(_ id: SystemCommand.ID) -> Bool {
        if Self.alwaysConfirmed.contains(id) { return true }
        return switch id {
        case .hideOtherApps: confirmsHidingOtherApps
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
        set {
            // Move any older Quit All exclusions into Keep Running first, so this write keeps them.
            keepRunningBundleIDs = keepRunningBundleIDs
            commandPreferences[SystemCommandSettings.storageKey] = newValue.values
        }
    }

    /// Keep Running: the one list of apps that Hide All, Quit All, Quit Others and Hide Others
    /// leave alone, stored with Settings › Applications. Exclusions an earlier build saved in
    /// Settings › System are read too, after it, and moved here on the next write.
    var keepRunningBundleIDs: [String] {
        get {
            let applications = ApplicationSettings(commandPreferences[ApplicationSettings.key]).keepRunningBundleIDs
            let legacy = SystemCommandSettings.legacyExclusions(commandPreferences[SystemCommandSettings.storageKey])
            return SystemCommandSettings.unique(applications + legacy)
        }
        set {
            var applications = ApplicationSettings(commandPreferences[ApplicationSettings.key])
            applications.keepRunningBundleIDs = SystemCommandSettings.unique(newValue)
            commandPreferences[ApplicationSettings.key] = applications.values
            commandPreferences[SystemCommandSettings.storageKey]?[SystemCommandSettings.legacyExclusionsKey] = nil
        }
    }
}
