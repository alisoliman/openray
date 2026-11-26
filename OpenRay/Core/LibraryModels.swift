import Foundation

/// Where the launcher is: Everything, a built-in scope, or a provider's own scope.
enum LauncherSection: CaseIterable, Identifiable, Hashable, Sendable {
    case home, applications, files, clipboard, snippets, quicklinks, notes, calculator, windows
    /// A list a registered provider pushes. Its scope supplies the title, symbol and the rest.
    case provided(ProvidedScope)

    /// The built-in scopes. Provided scopes are open-ended, so they aren't listed.
    static let allCases: [LauncherSection] = [
        .home, .applications, .files, .clipboard, .snippets, .quicklinks, .notes, .calculator, .windows,
    ]

    var rawValue: String {
        switch self {
        case .home: "home"
        case .applications: "applications"
        case .files: "files"
        case .clipboard: "clipboard"
        case .snippets: "snippets"
        case .quicklinks: "quicklinks"
        case .notes: "notes"
        case .calculator: "calculator"
        case .windows: "windows"
        case .provided(let scope): scope.id
        }
    }

    var id: String { rawValue }

    /// The provider's scope, when this is one.
    var providedScope: ProvidedScope? {
        if case .provided(let scope) = self { scope } else { nil }
    }

    var title: String {
        switch self {
        case .home: "Everything"
        case .applications: "Applications"
        case .files: "Files"
        case .clipboard: "Clipboard History"
        case .snippets: "Snippets"
        case .quicklinks: "Quicklinks"
        case .notes: "Notes"
        case .calculator: "Calculator & Conversions"
        case .windows: "Window Management"
        case .provided(let scope): scope.title
        }
    }

    var symbol: String {
        switch self {
        case .home: "magnifyingglass"
        case .applications: "square.grid.2x2"
        case .files: "folder"
        case .clipboard: "clipboard"
        case .snippets: "text.quote"
        case .quicklinks: "link"
        case .notes: "note.text"
        case .calculator: "equal.square"
        case .windows: "rectangle.split.2x1"
        case .provided(let scope): scope.symbol
        }
    }

    var placeholder: String {
        switch self {
        case .home: "Search apps, commands and files"
        case .applications: "Search applications"
        case .files: "Search files and folders"
        case .clipboard: "Search clipboard history"
        case .snippets: "Search snippets"
        case .quicklinks: "Search quicklinks"
        case .notes: "Search notes"
        case .calculator: "Type a calculation or conversion"
        case .windows: "Filter layouts"
        case .provided(let scope): scope.placeholder
        }
    }

    /// A compact name for favorites tiles.
    var shortTitle: String {
        switch self {
        case .clipboard: "Clipboard"
        case .calculator: "Calculator"
        case .windows: "Windows"
        case .provided(let scope): scope.shortTitle ?? scope.title
        default: title
        }
    }

    /// The one-line description shown as a command's subtitle.
    var summary: String {
        switch self {
        case .home: "Search everything"
        case .applications: "Open any app on this Mac"
        case .files: "Find files and folders with Spotlight"
        case .clipboard: "Search and paste what you've copied"
        case .snippets: "Text you type often, behind a keyword"
        case .quicklinks: "Websites, folders and search templates"
        case .notes: "Quick notes, saved on this Mac"
        case .calculator: "Arithmetic and unit conversions"
        case .windows: "Halves, quarters, center and more"
        case .provided(let scope): scope.summary
        }
    }

    var kind: Kind {
        switch self {
        case .home: .command
        case .applications: .system
        case .files: .file
        case .clipboard: .clipboard
        case .snippets: .snippet
        case .quicklinks: .quicklink
        case .notes: .note
        case .calculator: .calculator
        case .windows: .window
        case .provided(let scope): scope.kind
        }
    }

    var tileSymbol: String {
        switch self {
        case .applications: "square.grid.2x2"
        case .files: "folder"
        case .provided(let scope): scope.symbol
        default: kind.symbol
        }
    }

    /// Scopes that show a preview pane beside a two-line list.
    var showsPreview: Bool { providedScope?.showsPreview ?? [.clipboard, .snippets, .notes, .files, .quicklinks].contains(self) }

    /// Scopes whose items can be created from the panel.
    var createsItems: Bool { [.snippets, .quicklinks, .notes].contains(self) }

    var itemNoun: String {
        switch self {
        case .snippets: "snippet"
        case .quicklinks: "quicklink"
        case .notes: "note"
        case .provided(let scope): scope.itemNoun
        default: "item"
        }
    }
}

/// Where Files looks. Narrowing to one folder makes Spotlight faster.
enum FileSearchScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case home, documents, desktop, downloads, developer
    var id: String { rawValue }
    var title: String { self == .home ? "Home" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: "house"
        case .documents: "doc.text"
        case .desktop: "menubar.dock.rectangle"
        case .downloads: "arrow.down.circle"
        case .developer: "hammer"
        }
    }

    var url: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return self == .home ? home : home.appending(path: rawValue.capitalized, directoryHint: .isDirectory)
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum LauncherHotKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case optionSpace, controlSpace, controlOptionSpace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .controlOptionSpace: "⌃ ⌥ Space"
        }
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var appearance: AppAppearance = .dark
    var hotKey: LauncherHotKey = .optionSpace
    var clipboardEnabled = false
    // Missing fields in a version-1 library mean media capture was never approved.
    var clipboardImagesEnabled: Bool? = true
    // File references start off; people opt in on the clipboard screen or in Settings.
    var clipboardFilesEnabled: Bool? = false
    var clipboardRetentionDays = 7
    var clipboardLimit = 100
    var snippetExpansionEnabled = false
    var excludedClipboardBundleIDs = AppPreferences.builtInClipboardExclusions
    // Added in OpenRay 2.0. Optional so earlier libraries keep decoding; nil
    // means the person upgraded and has already seen the app.
    var firstRunCompleted: Bool? = false
    var rememberLastQuery: Bool? = true
    var barMode: Bool? = false
    var fileSearchScope: FileSearchScope? = .home
    // Whether capture was paused (true) or turned off (false) while it isn't
    // running. Nil until either is chosen; see LibraryDatabase.clipboardIsPaused.
    var clipboardPaused: Bool? = nil
    // Added by the launcher slice (Slice 1). Optional, so earlier libraries keep decoding; nil
    // means the default. Read them through the computed properties below.
    /// Supersedes `rememberLastQuery` once set.
    var popToRoot: PopToRootDelay? = nil
    var escapeBehavior: EscapeBehavior? = nil
    /// ⌃J and ⌃K move the selection, as ⌃N and ⌃P already do.
    var vimNavigation: Bool? = nil
    var launcherScreen: LauncherScreen? = nil
    var interfaceSize: InterfaceSize? = nil
    /// Slices 2 and 3 read `primaryActionPastes` for what ↩ does with copyable rows.
    var primaryAction: PrimaryAction? = nil
    /// A recorded launcher shortcut. Supersedes the `hotKey` preset once set.
    var launcherShortcut: CommandShortcut? = nil
    /// True once fallbacks were chosen by hand; `LibraryDatabase.fallbackOrder` then lists them.
    var customFallbacks: Bool? = nil
    var hyperKey: HyperKeySettings? = nil
    /// Whether searches are remembered for ↑ in an empty field.
    var searchHistory: Bool? = nil

    var capturesClipboardImages: Bool { clipboardImagesEnabled ?? false }
    var capturesClipboardFiles: Bool { clipboardFilesEnabled ?? false }
    var remembersLastQuery: Bool { rememberLastQuery ?? true }
    var usesBarMode: Bool { barMode ?? false }
    var needsFirstRun: Bool { firstRunCompleted == false }
    var popToRootDelay: PopToRootDelay { popToRoot ?? (remembersLastQuery ? .seconds90 : .immediately) }
    var escapeClosesWindow: Bool { escapeBehavior == .closeWindow }
    var usesVimNavigation: Bool { vimNavigation ?? false }
    var screen: LauncherScreen { launcherScreen ?? .mouse }
    var size: InterfaceSize { interfaceSize ?? .standard }
    /// True when ↩ pastes copyable rows and ⌘↩ copies them; false (the default) for the reverse.
    var primaryActionPastes: Bool { primaryAction == .paste }
    /// The shortcut that opens the launcher: a recorded one, else the preset.
    var launcherHotKeyShortcut: CommandShortcut { launcherShortcut ?? hotKey.shortcut }
    /// The launcher shortcut's name, recorded or preset, for menus and messages.
    var launcherHotKeyTitle: String { launcherShortcut?.title ?? hotKey.title }
    var hyper: HyperKeySettings { hyperKey ?? HyperKeySettings() }
    var remembersSearchHistory: Bool { searchHistory ?? true }

    /// The apps capture and expansion skip. Built-in password managers always
    /// apply, even if the saved list no longer contains them.
    var effectiveClipboardExclusions: [String] {
        var seen = Set<String>()
        return (Self.builtInClipboardExclusions + excludedClipboardBundleIDs).filter { seen.insert($0).inserted }
    }

    static let builtInClipboardExclusions = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.Passwords", "org.keepassxc.keepassxc",
    ]
}

struct UsageRecord: Codable, Equatable, Sendable {
    var id: String
    var count: Int = 1
    var lastUsed: Date = .now
}

struct LibraryDatabase: Codable, Equatable, Sendable {
    // Version 4 is OpenRay 2.0. Version 5 adds the collections the parity slices fill in.
    // A build opens libraries newer than it understands read-only.
    static let currentSchemaVersion = 5
    var schemaVersion = LibraryDatabase.currentSchemaVersion
    var preferences = AppPreferences()
    var quicklinks = Quicklink.defaults
    var snippets: [Snippet] = []
    var notes: [QuickNote] = []
    var clipboard: [ClipboardEntry] = []
    var favoriteIDs: Set<String> = Set(LibraryDatabase.defaultFavorites)
    /// The order favorites appear in, for ⌘1–⌘8. IDs missing here follow in a stable order.
    var favoriteOrder: [String] = LibraryDatabase.defaultFavorites
    var usage: [UsageRecord] = []
    var commandBindings: [CommandBinding] = []

    // Added in schema 5. Each is decoded with decodeIfPresent, so version 4 libraries load
    // with them empty, and each belongs to one slice; see LibraryRecords.swift.
    /// Slice 7: user-defined AI commands.
    var aiCommands: [AICommandRecord] = []
    /// Slice 7: agents.
    var agents: [AgentRecord] = []
    /// Slice 1: commands turned off in Settings, by command id.
    var disabledCommandIDs: Set<String> = []
    /// Slice 1: fallback commands in the order the person chose, by item id.
    var fallbackOrder: [String] = []
    /// Slice 8: folders of script commands.
    var scriptDirectories: [ScriptDirectoryRecord] = []
    /// Slice 5: saved multi-app window layouts.
    var windowLayouts: [WindowLayoutRecord] = []
    /// Slice 6: focus categories.
    var focusCategories: [FocusCategoryRecord] = []
    /// Slice 3: emoji frecency.
    var emojiUsage: [EmojiUsageRecord] = []
    /// Slice 3: kept calculations.
    var calculatorHistory: [CalculatorHistoryRecord] = []
    /// Per-command settings: command id → key → value. Any slice can store small values here
    /// without a schema change, e.g. `commandPreferences["system.sleep", default: [:]]["confirm"] = "false"`.
    var commandPreferences: [String: [String: String]] = [:]

    static let defaultFavorites = ["ai.chat", "section.clipboard", "section.files", "section.notes", "section.snippets"]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, preferences, quicklinks, snippets, notes, clipboard, favoriteIDs, favoriteOrder, usage,
            commandBindings
        // Schema 5.
        case aiCommands, agents, disabledCommandIDs, fallbackOrder, scriptDirectories, windowLayouts,
            focusCategories, emojiUsage, calculatorHistory, commandPreferences
    }

    var orderedFavoriteIDs: [String] {
        let ordered = favoriteOrder.filter(favoriteIDs.contains)
        let remaining = favoriteIDs.subtracting(ordered).sorted()
        var seen = Set<String>()
        return (ordered + remaining).filter { seen.insert($0).inserted }
    }

    /// Capture is off but meant to resume. An explicit choice wins; libraries
    /// without one count as paused while they still hold history.
    var clipboardIsPaused: Bool {
        !preferences.clipboardEnabled && (preferences.clipboardPaused ?? !clipboard.isEmpty)
    }

    /// Retired commands may have obsolete payloads. Ignore them before decoding
    /// fields whose representation is no longer relevant to this version.
    private struct AvailableCommandBinding: Decodable {
        var binding: CommandBinding?

        private enum CodingKeys: String, CodingKey { case targetID }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let targetID = try container.decode(String.self, forKey: .targetID)
            if CuratedCommand.supports(targetID) { binding = try CommandBinding(from: decoder) }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        preferences = try container.decode(AppPreferences.self, forKey: .preferences)
        quicklinks = try container.decode([Quicklink].self, forKey: .quicklinks)
        snippets = try container.decode([Snippet].self, forKey: .snippets)
        notes = try container.decode([QuickNote].self, forKey: .notes)
        clipboard = try container.decode([ClipboardEntry].self, forKey: .clipboard)
        favoriteIDs = try container.decode(Set<String>.self, forKey: .favoriteIDs)
        favoriteOrder = try container.decodeIfPresent([String].self, forKey: .favoriteOrder) ?? []
        usage = try container.decode([UsageRecord].self, forKey: .usage)
        commandBindings =
            try container.decodeIfPresent([AvailableCommandBinding].self, forKey: .commandBindings)?
            .compactMap(\.binding) ?? []
        aiCommands = try container.decodeIfPresent([AICommandRecord].self, forKey: .aiCommands) ?? []
        agents = try container.decodeIfPresent([AgentRecord].self, forKey: .agents) ?? []
        disabledCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .disabledCommandIDs) ?? []
        fallbackOrder = try container.decodeIfPresent([String].self, forKey: .fallbackOrder) ?? []
        scriptDirectories =
            try container.decodeIfPresent([ScriptDirectoryRecord].self, forKey: .scriptDirectories) ?? []
        windowLayouts = try container.decodeIfPresent([WindowLayoutRecord].self, forKey: .windowLayouts) ?? []
        focusCategories = try container.decodeIfPresent([FocusCategoryRecord].self, forKey: .focusCategories) ?? []
        emojiUsage = try container.decodeIfPresent([EmojiUsageRecord].self, forKey: .emojiUsage) ?? []
        calculatorHistory =
            try container.decodeIfPresent([CalculatorHistoryRecord].self, forKey: .calculatorHistory) ?? []
        commandPreferences =
            try container.decodeIfPresent([String: [String: String]].self, forKey: .commandPreferences) ?? [:]
    }

    func binding(for targetID: String) -> CommandBinding? {
        commandBindings.first { $0.targetID == targetID && CuratedCommand.supports($0.targetID) }
    }

    /// Aliases match the entire query so ordinary searches with arguments stay searches.
    func aliasTarget(for query: String) -> String? {
        guard let query = CommandBinding.normalizedAlias(query) else { return nil }
        return commandBindings.first {
            CuratedCommand.supports($0.targetID) && CommandBinding.normalizedAlias($0.alias) == query
        }?.targetID
    }

    mutating func discardUnavailableCommandBindings() {
        commandBindings.removeAll { !CuratedCommand.supports($0.targetID) }
    }

    func validate() throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw LibraryValidationError("This library requires a newer version of OpenRay.")
        }
        let identities = [
            quicklinks.map { $0.id.uuidString }, snippets.map { $0.id.uuidString },
            notes.map { $0.id.uuidString }, clipboard.map { $0.id.uuidString }, usage.map(\.id),
            commandBindings.map(\.targetID),
            aiCommands.map { $0.id.uuidString }, agents.map { $0.id.uuidString },
            scriptDirectories.map { $0.id.uuidString }, windowLayouts.map { $0.id.uuidString },
            focusCategories.map(\.id), emojiUsage.map(\.id), calculatorHistory.map { $0.id.uuidString },
        ]
        guard identities.allSatisfy({ Set($0).count == $0.count }) else {
            throw LibraryValidationError("The library contains duplicate item identifiers.")
        }
        guard (1...500).contains(preferences.clipboardLimit), (1...365).contains(preferences.clipboardRetentionDays),
            usage.allSatisfy({ (1...10_000).contains($0.count) })
        else {
            throw LibraryValidationError("The library contains invalid history limits or usage records.")
        }
        for link in quicklinks { try link.validate() }
        for snippet in snippets { try snippet.validate(against: snippets) }
        var aliases = Set<String>()
        let keywords = Set(
            (quicklinks.map(\.keyword) + snippets.map(\.keyword)).compactMap(CommandBinding.normalizedAlias))
        for binding in commandBindings {
            try binding.validate()
            guard let alias = CommandBinding.normalizedAlias(binding.alias) else { continue }
            guard aliases.insert(alias).inserted else {
                throw LibraryValidationError("Another command already uses this alias.")
            }
            guard !keywords.contains(alias) else {
                throw LibraryValidationError("This alias is already used by a quicklink or snippet keyword.")
            }
        }
        guard clipboard.allSatisfy(\.isValid) else {
            throw LibraryValidationError("The library contains invalid clipboard content.")
        }
    }
}

struct LibraryValidationError: LocalizedError, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
