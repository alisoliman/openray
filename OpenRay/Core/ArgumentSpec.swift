import Foundation

/// One input a command takes before it runs, typed inline after the command's name.
///
/// This is the model only. Today a quicklink's single `{query}` is the one argument the
/// launcher asks for (`ArgumentSpec.query`); the multi-field UI comes with Slice 1.
/// The persisted form is flat JSON: `name`, `placeholder`, `type` (`text`, `password` or
/// `dropdown`), `options` (dropdowns only), `optional` and `default`.
struct ArgumentSpec: Codable, Hashable, Sendable {
    enum InputType: Hashable, Sendable {
        case text
        /// Typed text that is never shown, stored or logged.
        case password
        /// A fixed choice. Commands receive an option's value; the field shows its title.
        case dropdown([Option])
    }

    struct Option: Codable, Hashable, Sendable {
        var title: String
        var value: String
    }

    var name: String
    var placeholder: String
    var type: InputType = .text
    var isOptional = false
    var defaultValue: String? = nil

    /// The single search term a `{query}` quicklink takes.
    static let query = ArgumentSpec(name: "query", placeholder: "Search term")

    /// The value a command receives: what was typed, else the default. Whitespace-only text
    /// counts as nothing typed. Nil when there is no value at all.
    func value(from typed: String?) -> String? {
        let trimmed = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return type == .password ? typed : trimmed }
        guard let defaultValue, !defaultValue.isEmpty else { return nil }
        return defaultValue
    }

    /// Checks one resolved value: required arguments need one, and a dropdown accepts only its options.
    func validate(_ value: String?) throws {
        guard let value else {
            guard isOptional else { throw LibraryValidationError("Enter \(placeholder.isEmpty ? name : placeholder).") }
            return
        }
        if case .dropdown(let options) = type, !options.contains(where: { $0.value == value }) {
            throw LibraryValidationError("Choose one of the options for \(placeholder.isEmpty ? name : placeholder).")
        }
    }

    /// Resolves every argument by name, applying defaults, and validates each. Optional
    /// arguments without a value are left out of the result.
    static func resolve(_ specs: [ArgumentSpec], typed: [String: String]) throws -> [String: String] {
        var values: [String: String] = [:]
        for spec in specs {
            let value = spec.value(from: typed[spec.name])
            try spec.validate(value)
            if let value { values[spec.name] = value }
        }
        return values
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case name, placeholder, type, options, isOptional = "optional", defaultValue = "default"
    }

    init(name: String, placeholder: String, type: InputType = .text, isOptional: Bool = false, defaultValue: String? = nil) {
        self.name = name
        self.placeholder = placeholder
        self.type = type
        self.isOptional = isOptional
        self.defaultValue = defaultValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        isOptional = try container.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        switch try container.decodeIfPresent(String.self, forKey: .type) ?? "text" {
        case "text": type = .text
        case "password": type = .password
        case "dropdown": type = .dropdown(try container.decodeIfPresent([Option].self, forKey: .options) ?? [])
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown argument type “\(other)”.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(placeholder, forKey: .placeholder)
        switch type {
        case .text: try container.encode("text", forKey: .type)
        case .password: try container.encode("password", forKey: .type)
        case .dropdown(let options):
            try container.encode("dropdown", forKey: .type)
            try container.encode(options, forKey: .options)
        }
        if isOptional { try container.encode(true, forKey: .isOptional) }
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}
