import Foundation

/// AI preferences, kept in `commandPreferences["ai"]` so the library schema doesn't change.
/// Unknown values fall back to the defaults.
struct AISettings: Equatable, Sendable {
    static let preferencesKey = "ai"

    var model: AIModelChoice = .onDevice
    var defaultAgentID: UUID?
    /// The command Quick Fix runs on the selection.
    var quickFixCommandID = "ai.proofread"
    var toolPermissions: [String: AIToolPermission] = [:]
    var chatRetention: ChatRetention = .forever
    var dictationEnabled = false
    var screenContextEnabled = false
    var chatWindowOnTop = false

    init() {}

    init(database: LibraryDatabase) {
        let values = database.commandPreferences[Self.preferencesKey] ?? [:]
        model = values["model"].flatMap(AIModelChoice.init(rawValue:)) ?? .onDevice
        defaultAgentID = values["defaultAgent"].flatMap(UUID.init(uuidString:))
        quickFixCommandID = values["quickFix"].flatMap { $0.isEmpty ? nil : $0 } ?? "ai.proofread"
        for (key, value) in values where key.hasPrefix("tool.") {
            if let permission = AIToolPermission(rawValue: value) { toolPermissions[String(key.dropFirst(5))] = permission }
        }
        chatRetention = values["retention"].flatMap(ChatRetention.init(rawValue:)) ?? .forever
        dictationEnabled = values["dictation"] == "true"
        screenContextEnabled = values["screenContext"] == "true"
        chatWindowOnTop = values["onTop"] == "true"
    }

    /// Writes every value, dropping keys left at their defaults.
    func write(into database: inout LibraryDatabase) {
        var values: [String: String] = [:]
        if model != .onDevice { values["model"] = model.rawValue }
        if let defaultAgentID { values["defaultAgent"] = defaultAgentID.uuidString }
        if quickFixCommandID != "ai.proofread" { values["quickFix"] = quickFixCommandID }
        for (tool, permission) in toolPermissions where permission != .auto { values["tool.\(tool)"] = permission.rawValue }
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
