import Foundation

// Script Commands: executables whose comment header describes a command. The header follows
// the public Script Commands format (MIT, github.com/raycast/script-commands, README.md,
// documentation/ARGUMENTS.md and documentation/OUTPUTMODES.md), so community scripts work
// unmodified. Both key prefixes are read: the format's own and `@openray.`, as an alias.
// Neither prefix appears anywhere in the interface.

/// How a script command shows what it prints.
enum ScriptOutputMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// The whole output, in a scrollable view with ANSI colors.
    case fullOutput
    /// The last line, in a toast.
    case compact
    /// The panel closes first; the last line, if any, appears in a HUD.
    case silent
    /// The first line, as the row's subtitle in root search, refreshed on a schedule.
    case inline

    var title: String {
        switch self {
        case .fullOutput: "Full Output"
        case .compact: "Compact"
        case .silent: "Silent"
        case .inline: "Inline"
        }
    }
}

/// A script's icon, as its header gives it.
enum ScriptIcon: Hashable, Sendable {
    case emoji(String)
    /// A PNG, JPEG or ICNS file, resolved against the script's folder.
    case file(URL)
    /// An https image. OpenRay stays offline, so these are never fetched; the row shows its
    /// default glyph instead.
    case remote(URL)

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "icns", "gif", "tif", "tiff", "heic", "pdf"]

    /// Reads an icon value: an https URL, a file path (relative to `directory`, `~` expanded),
    /// or a short emoji. Nil for anything else.
    static func parse(_ value: String, relativeTo directory: URL) -> ScriptIcon? {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        if lowered.hasPrefix("https://") { return URL(string: value).map(ScriptIcon.remote) }
        if lowered.hasPrefix("http://") { return nil }
        let pathExtension = (value as NSString).pathExtension.lowercased()
        if value.contains("/") || imageExtensions.contains(pathExtension) {
            return .file(ScriptMetadataParser.resolvePath(value, relativeTo: directory))
        }
        // Emoji are one or two grapheme clusters (a flag, a symbol with a modifier).
        guard value.count <= 2, value.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x7F })
        else { return nil }
        return .emoji(value)
    }
}

/// One of up to three typed inputs a script receives as `$1`–`$3`.
struct ScriptArgument: Hashable, Sendable {
    /// 1, 2 or 3: the position the value is passed in.
    var index: Int
    var type: ArgumentSpec.InputType
    var placeholder: String
    var isOptional = false
    /// The value is percent-encoded (RFC 3986 unreserved characters kept) before it's passed.
    var percentEncoded = false

    /// The name the launcher's argument fields and `ProvidedRef.arguments` use.
    var name: String { "argument\(index)" }

    var spec: ArgumentSpec {
        ArgumentSpec(name: name, placeholder: placeholder, type: type, isOptional: isOptional)
    }

    /// The value as the script receives it.
    func encoded(_ value: String) -> String {
        guard percentEncoded else { return value }
        return value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? value
    }

    /// RFC 3986's unreserved characters: what `encodeURIComponent` leaves alone, minus `!'()*`.
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// A script command's header, parsed and checked.
struct ScriptMetadata: Hashable, Sendable {
    static let supportedSchemaVersion = 1
    static let maximumArguments = 3
    /// The format's minimum `refreshTime`. Shorter values are raised to it.
    static let minimumRefresh: Duration = .seconds(10)

    var schemaVersion: Int
    var title: String
    /// The mode the script runs in. `inline` without a usable `refreshTime` runs as `compact`,
    /// as the format specifies.
    var mode: ScriptOutputMode
    /// The mode the header asked for.
    var declaredMode: ScriptOutputMode
    var packageName: String?
    var icon: ScriptIcon?
    var iconDark: ScriptIcon?
    /// Where the script runs: the header's `currentDirectoryPath`, resolved, else the script's folder.
    var workingDirectory: URL
    var needsConfirmation = false
    /// How often an inline script refreshes; never under `minimumRefresh`.
    var refreshTime: Duration?
    var arguments: [ScriptArgument] = []
    var author: String?
    var authorURL: String?
    var description: String?
    /// Problems that don't stop the script from running, shown in Settings.
    var warnings: [String] = []
}

/// Why a file with a script header can't be used. Shown in Settings › Scripts.
struct ScriptMetadataError: LocalizedError, Hashable, Sendable {
    var problems: [String]
    var errorDescription: String? { problems.joined(separator: " ") }
}

enum ScriptMetadataParser {
    /// Key prefixes, in the format's spelling and OpenRay's alias.
    static let prefixes = ["@raycast.", "@openray."]
    /// Comment markers a header line may start with: shell, Python and Ruby; Swift, JavaScript,
    /// PHP and C#; AppleScript and Lua.
    static let commentMarkers = ["#", "//", "--"]

    /// One `key value` line from a header.
    struct Field: Hashable, Sendable {
        var key: String
        var value: String
        var line: Int
    }

    /// Every metadata line in a script, in file order. Lines must be comments; text after the key
    /// is the value, trimmed. An unknown key is kept, so the caller can ignore or report it.
    static func fields(in text: String) -> [Field] {
        var fields: [Field] = []
        var number = 0
        text.enumerateLines { line, _ in
            number += 1
            var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
            guard let marker = commentMarkers.first(where: { rest.hasPrefix($0) }) else { return }
            rest = rest.dropFirst(marker.count).drop { $0 == " " || $0 == "\t" || $0 == "#" || $0 == "/" }
            guard let prefix = prefixes.first(where: { rest.hasPrefix($0) }) else { return }
            rest = rest.dropFirst(prefix.count)
            let key = rest.prefix { $0.isLetter || $0.isNumber }
            guard !key.isEmpty else { return }
            let value = rest.dropFirst(key.count)
            // A key must end at whitespace or the line's end: `@raycast.titles` isn't `title`.
            guard value.isEmpty || value.first == " " || value.first == "\t" else { return }
            fields.append(Field(key: String(key), value: value.trimmingCharacters(in: .whitespaces), line: number))
        }
        return fields
    }

    /// Whether a file declares any metadata. Files without it aren't script commands and are skipped quietly.
    static func hasMetadata(_ text: String) -> Bool { !fields(in: text).isEmpty }

    /// Parses a script's header. `scriptURL` resolves relative icons and the working directory.
    static func parse(_ text: String, scriptURL: URL) throws -> ScriptMetadata {
        let directory = scriptURL.deletingLastPathComponent()
        var values: [String: String] = [:]
        for field in fields(in: text) { values[field.key] = field.value }
        var problems: [String] = []
        var warnings: [String] = []

        let schemaVersion: Int
        if let raw = values["schemaVersion"] {
            if let version = Int(raw), version == ScriptMetadata.supportedSchemaVersion {
                schemaVersion = version
            } else {
                schemaVersion = Int(raw) ?? 0
                problems.append("schemaVersion “\(raw)” isn't supported; use 1.")
            }
        } else {
            schemaVersion = 0
            problems.append("schemaVersion is missing.")
        }

        let title = values["title"] ?? ""
        if title.isEmpty { problems.append("title is missing.") }

        var declaredMode = ScriptOutputMode.compact
        if let raw = values["mode"] {
            if let mode = ScriptOutputMode(rawValue: raw) {
                declaredMode = mode
            } else {
                problems.append("mode “\(raw)” isn't one of fullOutput, compact, silent or inline.")
            }
        } else {
            problems.append("mode is missing.")
        }

        if let platform = values["platform"]?.lowercased(), !platform.isEmpty, !platform.contains("macos") {
            problems.append("This script is for \(values["platform"] ?? platform), not macOS.")
        }

        var refreshTime: Duration?
        if let raw = values["refreshTime"] {
            if let parsed = parseRefreshTime(raw) {
                if parsed < ScriptMetadata.minimumRefresh {
                    warnings.append("refreshTime \(raw) is raised to the 10-second minimum.")
                    refreshTime = ScriptMetadata.minimumRefresh
                } else {
                    refreshTime = parsed
                }
            } else {
                warnings.append("refreshTime “\(raw)” isn't a duration like 10s, 1m, 12h or 1d.")
            }
        }
        var mode = declaredMode
        if declaredMode == .inline, refreshTime == nil {
            mode = .compact
            if values["refreshTime"] == nil { warnings.append("Inline scripts need a refreshTime; this one runs as Compact.") }
        }

        var needsConfirmation = false
        if let raw = values["needsConfirmation"] {
            switch raw.lowercased() {
            case "true": needsConfirmation = true
            case "false", "": break
            default: warnings.append("needsConfirmation “\(raw)” isn't true or false; it's treated as false.")
            }
        }

        var arguments: [ScriptArgument] = []
        let argumentKeys = values.keys.filter { $0.hasPrefix("argument") }
            .compactMap { key in Int(key.dropFirst("argument".count)).map { (key, $0) } }
            .sorted { $0.1 < $1.1 }
        for (key, index) in argumentKeys {
            guard (1...ScriptMetadata.maximumArguments).contains(index) else {
                warnings.append("Only three arguments are supported; \(key) is ignored.")
                continue
            }
            do {
                arguments.append(try parseArgument(values[key] ?? "", index: index))
            } catch {
                problems.append("\(key): \(error.localizedDescription)")
            }
        }

        var icon: ScriptIcon?
        if let raw = values["icon"], !raw.isEmpty {
            icon = ScriptIcon.parse(raw, relativeTo: directory)
            if icon == nil { warnings.append("icon “\(raw)” isn't an emoji, an image file or an https URL.") }
        }
        var iconDark: ScriptIcon?
        if let raw = values["iconDark"], !raw.isEmpty {
            iconDark = ScriptIcon.parse(raw, relativeTo: directory)
            if iconDark == nil { warnings.append("iconDark “\(raw)” isn't an emoji, an image file or an https URL.") }
        }

        var workingDirectory = directory
        if let raw = values["currentDirectoryPath"], !raw.isEmpty {
            workingDirectory = resolvePath(raw, relativeTo: directory)
        }

        guard problems.isEmpty else { throw ScriptMetadataError(problems: problems) }
        return ScriptMetadata(
            schemaVersion: schemaVersion, title: title, mode: mode, declaredMode: declaredMode,
            packageName: values["packageName"].flatMap { $0.isEmpty ? nil : $0 },
            icon: icon, iconDark: iconDark, workingDirectory: workingDirectory, needsConfirmation: needsConfirmation,
            refreshTime: mode == .inline ? refreshTime : nil, arguments: arguments,
            author: values["author"].flatMap { $0.isEmpty ? nil : $0 },
            authorURL: values["authorURL"].flatMap { $0.isEmpty ? nil : $0 },
            description: values["description"].flatMap { $0.isEmpty ? nil : $0 },
            warnings: warnings)
    }

    /// `10s`, `1m`, `12h`, `1d`: a whole number and a unit. Nil for anything else.
    static func parseRefreshTime(_ text: String) -> Duration? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last, let amount = Int(trimmed.dropLast().trimmingCharacters(in: .whitespaces)),
            amount > 0, amount <= 365 * 86_400
        else { return nil }
        switch unit {
        case "s": return .seconds(amount)
        case "m": return .seconds(amount * 60)
        case "h": return .seconds(amount * 3_600)
        case "d": return .seconds(amount * 86_400)
        default: return nil
        }
    }

    /// One `argumentN` value: a JSON object with `type`, `placeholder`, and optionally
    /// `optional`, `percentEncoded` and (for dropdowns) `data`. The deprecated `secure: true`
    /// means a password.
    static func parseArgument(_ json: String, index: Int) throws -> ScriptArgument {
        guard let data = json.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw LibraryValidationError("isn't a JSON object.") }
        func flag(_ key: String) -> Bool {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? String { return value.lowercased() == "true" }
            if let value = object[key] as? NSNumber { return value.boolValue }
            return false
        }
        guard let placeholder = object["placeholder"] as? String, !placeholder.isEmpty else {
            throw LibraryValidationError("needs a placeholder.")
        }
        let type: ArgumentSpec.InputType
        switch (object["type"] as? String)?.lowercased() ?? "text" {
        case "text": type = flag("secure") ? .password : .text
        case "password": type = .password
        case "dropdown":
            let entries = object["data"] as? [[String: Any]] ?? []
            let options = entries.compactMap { entry -> ArgumentSpec.Option? in
                guard let title = entry["title"] as? String else { return nil }
                let value = entry["value"] as? String ?? (entry["value"] as? NSNumber)?.stringValue ?? title
                return ArgumentSpec.Option(title: title, value: value)
            }
            guard !options.isEmpty, options.count == entries.count else {
                throw LibraryValidationError("a dropdown needs data: a list of title and value pairs.")
            }
            type = .dropdown(options)
        case let other:
            throw LibraryValidationError("type “\(other)” isn't text, password or dropdown.")
        }
        return ScriptArgument(
            index: index, type: type, placeholder: placeholder, isOptional: flag("optional"),
            percentEncoded: flag("percentEncoded"))
    }

    /// Expands `~` and resolves a relative path against `directory`.
    static func resolvePath(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return directory.appending(path: expanded).standardizedFileURL
    }
}
