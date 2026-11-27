import Foundation

/// What ↵ does on a writing result: its own setting, as Raycast's AI › Quick AI › Primary Action
/// is. Launcher rows follow General's Primary Action instead.
enum AIPrimaryAction: String, CaseIterable, Identifiable, Sendable {
    case paste, copy

    var id: String { rawValue }
    var title: String { self == .paste ? "Paste Response" : "Copy Response" }
}

/// AI preferences, kept in `commandPreferences["ai"]` so the library schema doesn't change.
/// Unknown values fall back to the defaults, and a key that isn't there is its default.
struct AISettings: Equatable, Sendable {
    static let preferencesKey = "ai"

    var model: AIModelChoice = .onDevice
    /// ↵ on a writing result: Paste Response unless Copy Response was chosen.
    var primaryAction: AIPrimaryAction = .paste
    var defaultAgentID: UUID?
    /// The command Quick Fix runs on the selection.
    var quickFixCommandID = "ai.proofread"
    /// Quick Fix works on the selection when there is one; off, it always takes the whole field.
    var quickFixPrefersSelection = true
    /// Commands whose highlight setting differs from its default, by command id.
    var highlightOverrides: [String: Bool] = [:]
    var toolPermissions: [String: AIToolPermission] = [:]
    var chatRetention: ChatRetention = .forever
    var dictationEnabled = false
    var screenContextEnabled = false
    var chatWindowOnTop = false

    /// Commands whose results show their changes unless turned off: Fix Spelling & Grammar.
    static let highlightedByDefault: Set<String> = ["ai.proofread"]

    init() {}

    init(database: LibraryDatabase) {
        let values = database.commandPreferences[Self.preferencesKey] ?? [:]
        model = values["model"].flatMap(AIModelChoice.init(rawValue:)) ?? .onDevice
        defaultAgentID = values["defaultAgent"].flatMap(UUID.init(uuidString:))
        quickFixCommandID = values["quickFix"].flatMap { $0.isEmpty ? nil : $0 } ?? "ai.proofread"
        quickFixPrefersSelection = values["quickFixSelection"] != "false"
        primaryAction = values["primaryAction"].flatMap(AIPrimaryAction.init(rawValue:)) ?? .paste
        for (key, value) in values where key.hasPrefix("tool.") {
            if let permission = AIToolPermission(rawValue: value) { toolPermissions[String(key.dropFirst(5))] = permission }
        }
        for (key, value) in values where key.hasPrefix("highlight.") && (value == "true" || value == "false") {
            highlightOverrides[String(key.dropFirst(10))] = value == "true"
        }
        chatRetention = values["retention"].flatMap(ChatRetention.init(rawValue:)) ?? .forever
        dictationEnabled = values["dictation"] == "true"
        screenContextEnabled = values["screenContext"] == "true"
        chatWindowOnTop = values["onTop"] == "true"
    }

    /// Whether a command's results open with their changes marked inline.
    func highlightsChanges(for commandID: String) -> Bool {
        highlightOverrides[commandID] ?? Self.highlightedByDefault.contains(commandID)
    }

    mutating func setHighlightsChanges(_ highlights: Bool, for commandID: String) {
        highlightOverrides[commandID] = highlights == Self.highlightedByDefault.contains(commandID) ? nil : highlights
    }

    /// Writes every value, dropping keys left at their defaults.
    func write(into database: inout LibraryDatabase) {
        var values: [String: String] = [:]
        if model != .onDevice { values["model"] = model.rawValue }
        if let defaultAgentID { values["defaultAgent"] = defaultAgentID.uuidString }
        if quickFixCommandID != "ai.proofread" { values["quickFix"] = quickFixCommandID }
        if !quickFixPrefersSelection { values["quickFixSelection"] = "false" }
        if primaryAction != .paste { values["primaryAction"] = primaryAction.rawValue }
        for (tool, permission) in toolPermissions where permission != .auto { values["tool.\(tool)"] = permission.rawValue }
        for (command, highlights) in highlightOverrides
        where highlights != Self.highlightedByDefault.contains(command) {
            values["highlight.\(command)"] = highlights ? "true" : "false"
        }
        if chatRetention != .forever { values["retention"] = chatRetention.rawValue }
        if dictationEnabled { values["dictation"] = "true" }
        if screenContextEnabled { values["screenContext"] = "true" }
        if chatWindowOnTop { values["onTop"] = "true" }
        if values.isEmpty {
            database.commandPreferences.removeValue(forKey: Self.preferencesKey)
        } else {
            database.commandPreferences[Self.preferencesKey] = values
        }
    }
}

/// Tool permissions stored in the library's AI preferences.
@MainActor
final class LibraryToolPermissions: AIToolPermissionStoring {
    let store: LibraryStore

    init(store: LibraryStore) { self.store = store }

    func permission(for toolID: String) -> AIToolPermission? {
        AISettings(database: store.database).toolPermissions[toolID]
    }

    func setPermission(_ permission: AIToolPermission?, for toolID: String) {
        store.update { database in
            var settings = AISettings(database: database)
            settings.toolPermissions[toolID] = permission
            settings.write(into: &database)
        }
    }
}
