import Foundation

enum ClipboardLimits {
    static let textBytes = 128_000
    static let sourceImageBytes = 64_000_000
    static let imageBytes = 10_000_000
    static let imagePixels = 40_000_000
    static let fileCount = 100
    static let historyBytes = 64_000_000
    /// RTF and HTML kept next to copied text. Larger rich content is dropped and
    /// the plain text is kept.
    static let richTextBytes = 1_000_000
    /// Text recognized in an image.
    static let recognizedTextBytes = 32_000
}

struct ClipboardImage: Codable, Equatable, Sendable {
    let id: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int

    var isValid: Bool {
        id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && pixelWidth > 0 && pixelHeight > 0
            && pixelWidth <= ClipboardLimits.imagePixels / pixelHeight
            && (1...ClipboardLimits.imageBytes).contains(byteCount)
    }
}

enum ClipboardContent: Equatable, Sendable {
    case text(String)
    case image(ClipboardImage)
    case files([URL])
}

enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all, text, images, files, links
    var id: String { rawValue }
    var title: String { self == .all ? "All Types" : rawValue.capitalized }

    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .text: "text.alignleft"
        case .images: "photo"
        case .files: "doc"
        case .links: "link"
        }
    }

    func includes(_ entry: ClipboardEntry) -> Bool {
        switch (self, entry.content) {
        case (.all, _), (.images, .image), (.files, .files): true
        case (.text, .text): !entry.isLink
        case (.links, .text): entry.isLink
        default: false
        }
    }

    var next: ClipboardFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// File resources point only into the library's own image store. In-memory
/// resources let previews and tests exercise the same image flow without disk I/O.
enum ClipboardImageResource: Sendable {
    case file(ClipboardImage, URL)
    case memory(ClipboardImage, Data)
    case unavailable(ClipboardImage)

    var image: ClipboardImage {
        switch self {
        case .file(let image, _), .memory(let image, _), .unavailable(let image): image
        }
    }
}

struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var content: ClipboardContent
    var copiedAt: Date
    var sourceName: String
    var sourceBundleID: String?
    /// Pinned entries are exempt from retention and the entry limit, not from the byte budget.
    var isPinned = false
    /// The formatted versions of copied text, when the source app offered them.
    var richText: ClipboardRichText?
    /// Text found in an image by on-device recognition, so image entries are searchable.
    var recognizedText: String?

    init(id: UUID = UUID(), text: String, copiedAt: Date = .now, sourceName: String, sourceBundleID: String? = nil) {
        self.init(
            id: id, content: .text(text), copiedAt: copiedAt, sourceName: sourceName, sourceBundleID: sourceBundleID)
    }

    init(
        id: UUID = UUID(), content: ClipboardContent, copiedAt: Date = .now, sourceName: String,
        sourceBundleID: String? = nil
    ) {
        self.id = id
        self.content = content
        self.copiedAt = copiedAt
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
    }

    /// Non-text entries never masquerade as text when passed to copy or AI actions.
    var plainText: String? { if case .text(let value) = content { value } else { nil } }
    var text: String { plainText ?? "" }
    var image: ClipboardImage? { if case .image(let image) = content { image } else { nil } }

    /// A single web or mail link, so the Links filter can find it.
    var isLink: Bool {
        guard case .text(let text) = content else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2_048, !trimmed.contains(where: \.isWhitespace),
            let url = URL(string: trimmed), let scheme = url.scheme?.lowercased()
        else { return false }
        return (["http", "https"].contains(scheme) && url.host?.isEmpty == false) || scheme == "mailto"
    }

    /// What copied text looks like: a link, an email address, a color or plain text.
    var textKind: ClipboardTextKind? {
        guard case .text(let text) = content else { return nil }
        if isLink { return .link }
        // Rows ask for this on every render, so long text skips the parsers.
        guard text.utf8.count <= 300 else { return .text }
        if ClipboardTextKind.isEmailAddress(text) { return .email }
        if ClipboardColor(parsing: text) != nil { return .color }
        return .text
    }

    /// The color an entry's text describes, such as `#FF8800` or `hsl(30 100% 50%)`.
    var color: ClipboardColor? {
        guard case .text(let text) = content, text.utf8.count <= 300 else { return nil }
        return ClipboardColor(parsing: text)
    }

    var title: String {
        switch content {
        case .text(let text):
            String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(120) ?? "Text".prefix(120))
        case .image(let image): "Image · \(image.pixelWidth) × \(image.pixelHeight)"
        case .files(let files):
            files.count == 1
                ? files[0].lastPathComponent : "\(files.count) files · \(files.first?.lastPathComponent ?? "Files")"
        }
    }

    var kindTitle: String {
        switch content {
        case .text: textKind?.title ?? "Text"
        case .image: "Image"
        case .files(let files): files.count == 1 ? "File" : "Files"
        }
    }

    var symbol: String {
        switch content {
        case .text: textKind?.symbol ?? "text.alignleft"
        case .image: "photo"
        case .files(let files): files.count == 1 ? "doc" : "doc.on.doc"
        }
    }

    var searchableText: String {
        switch content {
        case .text(let text): text + " " + sourceName
        case .image: title + " image picture screenshot " + (recognizedText.map { $0 + " " } ?? "") + sourceName
        case .files(let files): files.map(\.path).joined(separator: " ") + " " + sourceName
        }
    }

    var byteCount: Int {
        let extra = (richText?.byteCount ?? 0) + (recognizedText?.utf8.count ?? 0)
        switch content {
        case .text(let text): return text.utf8.count + extra
        case .image(let image): return image.byteCount + extra
        case .files(let files): return files.reduce(0) { $0 + $1.absoluteString.utf8.count } + extra
        }
    }

    var isValid: Bool {
        if let richText {
            guard case .text = content, !richText.isEmpty, richText.byteCount <= ClipboardLimits.richTextBytes else {
                return false
            }
        }
        if let recognizedText, recognizedText.utf8.count > ClipboardLimits.recognizedTextBytes { return false }
        switch content {
        case .text(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && text.utf8.count <= ClipboardLimits.textBytes
        case .image(let image): return image.isValid
        case .files(let files):
            return !files.isEmpty && files.count <= ClipboardLimits.fileCount
                && files.allSatisfy { $0.isFileURL && $0.path.hasPrefix("/") }
                && Set(files).count == files.count
                && files.reduce(0, { $0 + $1.absoluteString.utf8.count }) <= ClipboardLimits.textBytes
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, image, files, copiedAt, sourceName, sourceBundleID, pinned, rich, recognizedText
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        // Added with Paste As and image text recognition; older libraries have neither.
        richText = try container.decodeIfPresent(ClipboardRichText.self, forKey: .rich)
        recognizedText = try container.decodeIfPresent(String.self, forKey: .recognizedText)
        // Version 1 entries contained only a `text` field, without a kind tag.
        switch try container.decodeIfPresent(String.self, forKey: .kind) ?? "text" {
        case "text": content = .text(try container.decode(String.self, forKey: .text))
        case "image": content = .image(try container.decode(ClipboardImage.self, forKey: .image))
        case "files": content = .files(try container.decode([URL].self, forKey: .files))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown clipboard content type.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(copiedAt, forKey: .copiedAt)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        if isPinned { try container.encode(true, forKey: .pinned) }
        if let richText, !richText.isEmpty { try container.encode(richText, forKey: .rich) }
        try container.encodeIfPresent(recognizedText, forKey: .recognizedText)
        switch content {
        case .text(let text):
            try container.encode("text", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .image(let image):
            try container.encode("image", forKey: .kind)
            try container.encode(image, forKey: .image)
        case .files(let files):
            try container.encode("files", forKey: .kind)
            try container.encode(files, forKey: .files)
        }
    }
}

// MARK: - Rich text

/// Formatted versions of copied text, stored as the source app wrote them so a
/// paste can reproduce the formatting.
struct ClipboardRichText: Codable, Equatable, Sendable {
    var rtf: Data?
    var html: Data?

    init(rtf: Data? = nil, html: Data? = nil) {
        self.rtf = rtf?.isEmpty == true ? nil : rtf
        self.html = html?.isEmpty == true ? nil : html
    }

    var isEmpty: Bool { rtf == nil && html == nil }
    var byteCount: Int { (rtf?.count ?? 0) + (html?.count ?? 0) }

    /// Keeps what fits in the rich-text budget, preferring RTF, which every Mac
    /// text view reads. Returns nil when nothing fits or nothing was offered.
    static func capture(rtf: Data?, html: Data?) -> ClipboardRichText? {
        let limit = ClipboardLimits.richTextBytes
        let rtf = rtf.flatMap { $0.isEmpty || $0.count > limit ? nil : $0 }
        let html = html.flatMap { $0.isEmpty || $0.count > limit - (rtf?.count ?? 0) ? nil : $0 }
        let rich = ClipboardRichText(rtf: rtf, html: html)
        return rich.isEmpty ? nil : rich
    }
}

// MARK: - Text kinds

enum ClipboardTextKind: String, CaseIterable, Sendable {
    case text, link, email, color

    var title: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .email: "Email"
        case .color: "Color"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .email: "envelope"
        case .color: "paintpalette"
        }
    }

    /// A single address such as `name@example.com`, without other text.
    static func isEmailAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 254, !trimmed.contains(where: \.isWhitespace) else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last,
            (1...64).contains(local.count), !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..")
        else { return false }
        let localAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-")
        guard local.allSatisfy(localAllowed.contains) else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else {
            return false
        }
        return labels.allSatisfy { label in
            (1...63).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
    }
}

/// A color written as CSS hex, `rgb()`/`rgba()` or `hsl()`/`hsla()`.
struct ClipboardColor: Equatable, Sendable {
    /// Components from 0 to 1, in sRGB.
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    /// `#RRGGBB`, or `#RRGGBBAA` when the color isn't opaque.
    var hexString: String {
        func byte(_ value: Double) -> String { String(format: "%02X", Int((min(1, max(0, value)) * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(parsing text: String) {
        guard text.utf8.count <= 300 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (4...64).contains(trimmed.count) else { return nil }
        if trimmed.hasPrefix("#") {
            guard let color = Self.hex(trimmed.dropFirst()) else { return nil }
            self = color
        } else if let color = Self.function(trimmed) {
            self = color
        } else {
            return nil
        }
    }

    private static func hex(_ digits: Substring) -> ClipboardColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count <= 4 ? String(digits.flatMap { [$0, $0] }) : String(digits)
        var values: [Double] = []
        var index = expanded.startIndex
        while index < expanded.endIndex {
            let next = expanded.index(index, offsetBy: 2)
            guard let byte = UInt8(expanded[index..<next], radix: 16) else { return nil }
            values.append(Double(byte) / 255)
            index = next
        }
        return ClipboardColor(red: values[0], green: values[1], blue: values[2], alpha: values.count == 4 ? values[3] : 1)
    }

    /// `rgb(255, 0, 0)`, `rgba(255 0 0 / 50%)`, `hsl(120deg, 100%, 50%)` and similar.
    private static func function(_ text: String) -> ClipboardColor? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let name = text[..<open].trimmingCharacters(in: .whitespaces)
        guard ["rgb", "rgba", "hsl", "hsla"].contains(name) else { return nil }
        let body = text[text.index(after: open)..<text.index(before: text.endIndex)]
        var parts = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        let slashAlpha = parts.count == 2 ? parts.removeLast() : nil
        var components = parts[0].split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard components.count == 3 || (components.count == 4 && slashAlpha == nil) else { return nil }
        let alphaText = slashAlpha?.trimmingCharacters(in: .whitespaces) ?? (components.count == 4 ? components.removeLast() : nil)
        var alpha = 1.0
        if let alphaText {
            guard let value = number(alphaText, percentScale: 1, plainScale: 1) else { return nil }
            alpha = value
        }
        guard (0...1).contains(alpha) else { return nil }
        if name.hasPrefix("rgb") {
            let values = components.compactMap { number($0, percentScale: 1, plainScale: 255) }
            guard values.count == 3, values.allSatisfy({ (0...1).contains($0) }) else { return nil }
            return ClipboardColor(red: values[0], green: values[1], blue: values[2], alpha: alpha)
        }
        let hueText = components[0].hasSuffix("deg") ? String(components[0].dropLast(3)) : components[0]
        guard let hue = Double(hueText), hue.isFinite, components[1].hasSuffix("%"), components[2].hasSuffix("%"),
            let saturation = number(components[1], percentScale: 1, plainScale: 1),
            let lightness = number(components[2], percentScale: 1, plainScale: 1),
            (0...1).contains(saturation), (0...1).contains(lightness)
        else { return nil }
        let (red, green, blue) = rgb(hue: hue, saturation: saturation, lightness: lightness)
        return ClipboardColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// A percentage maps to 0…1 through `percentScale`; a plain number is divided by `plainScale`.
    private static func number(_ text: String, percentScale: Double, plainScale: Double) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            guard let value = Double(trimmed.dropLast()), value.isFinite else { return nil }
            return value / 100 * percentScale
        }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value / plainScale
    }

    private static func rgb(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1 / 3), channel(h), channel(h - 1 / 3))
    }
}

// MARK: - Paste As

/// How an entry is written back to the clipboard.
enum ClipboardPasteFormat: String, CaseIterable, Identifiable, Sendable {
    /// Everything that was captured: formatting, the image or the files.
    case original
    /// Text only, without formatting.
    case plainText
    case rtf
    case html

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Paste"
        case .plainText: "Paste as Plain Text"
        case .rtf: "Paste as RTF"
        case .html: "Paste as HTML"
        }
    }
}

/// One type and its bytes inside a pasteboard item.
struct ClipboardRepresentation: Equatable, Sendable {
    /// A uniform type identifier, as used by `NSPasteboard.PasteboardType`.
    var type: String
    var data: Data

    static let plainTextType = "public.utf8-plain-text"
    static let rtfType = "public.rtf"
    static let htmlType = "public.html"
    static let pngType = "public.png"
    static let fileURLType = "public.file-url"
}

/// Builds what to write to the pasteboard for each paste format. Pure data, so
/// it can be tested without touching any pasteboard. Each inner array is one
/// pasteboard item, richest representation first.
enum ClipboardPayload {
    /// The formats an entry can be pasted as. `original` is always first.
    static func formats(for entry: ClipboardEntry) -> [ClipboardPasteFormat] {
        ClipboardPasteFormat.allCases.filter { items(for: entry, format: $0, imageData: Data([0])) != nil }
    }

    /// The pasteboard items for `entry` in `format`, or nil when the entry has no
    /// such version. Images need their PNG bytes, which live outside the entry.
    static func items(for entry: ClipboardEntry, format: ClipboardPasteFormat, imageData: Data? = nil)
        -> [[ClipboardRepresentation]]?
    {
        switch entry.content {
        case .text(let text):
            return items(text: text, richText: entry.richText, format: format)
        case .image:
            switch format {
            case .original:
                guard let imageData, !imageData.isEmpty else { return nil }
                return [[ClipboardRepresentation(type: ClipboardRepresentation.pngType, data: imageData)]]
            case .plainText:
                guard let text = entry.recognizedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return [[plain(text)]]
            case .rtf, .html:
                return nil
            }
        case .files(let urls):
            switch format {
            case .original:
                return urls.map { [ClipboardRepresentation(type: ClipboardRepresentation.fileURLType, data: Data($0.absoluteString.utf8))] }
            case .plainText:
                return [[plain(urls.map(\.path).joined(separator: "\n"))]]
            case .rtf, .html:
                return nil
            }
        }
    }

    /// Text with optional formatting. Plain text is always included so apps that
    /// can't read the formatting still get the words.
    static func items(text: String, richText: ClipboardRichText?, format: ClipboardPasteFormat)
        -> [[ClipboardRepresentation]]?
    {
        var item: [ClipboardRepresentation] = []
        switch format {
        case .original:
            if let rtf = richText?.rtf { item.append(.init(type: ClipboardRepresentation.rtfType, data: rtf)) }
            if let html = richText?.html { item.append(.init(type: ClipboardRepresentation.htmlType, data: html)) }
        case .plainText:
            break
        case .rtf:
            guard let rtf = richText?.rtf else { return nil }
            item.append(.init(type: ClipboardRepresentation.rtfType, data: rtf))
        case .html:
            guard let html = richText?.html else { return nil }
            item.append(.init(type: ClipboardRepresentation.htmlType, data: html))
        }
        item.append(plain(text))
        return [item]
    }

    private static func plain(_ text: String) -> ClipboardRepresentation {
        ClipboardRepresentation(type: ClipboardRepresentation.plainTextType, data: Data(text.utf8))
    }
}

// MARK: - Retention

/// How long unpinned clipboard history is kept.
enum ClipboardRetention: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneDay, sevenDays, thirtyDays, threeMonths, unlimited

    static let `default` = ClipboardRetention.thirtyDays

    var id: String { rawValue }

    /// Nil means entries never expire; the entry cap and byte budget still apply.
    var days: Int? {
        switch self {
        case .oneDay: 1
        case .sevenDays: 7
        case .thirtyDays: 30
        case .threeMonths: 90
        case .unlimited: nil
        }
    }

    var title: String {
        switch self {
        case .oneDay: "1 Day"
        case .sevenDays: "7 Days"
        case .thirtyDays: "30 Days"
        case .threeMonths: "3 Months"
        case .unlimited: "Unlimited"
        }
    }

    /// The shortest option that keeps history at least `days` long, so mapping a
    /// saved day count never deletes something the person meant to keep.
    init(days: Int) {
        self = Self.allCases.first { ($0.days ?? .max) >= max(1, days) } ?? .unlimited
    }
}

/// Which clipboard entries survive. Pinned entries are exempt from retention and
/// the entry cap, but not from the byte budget, and they claim the budget first.
struct ClipboardRetentionPolicy: Equatable, Sendable {
    static let itemRange = 1...5_000

    var retention: ClipboardRetention
    var maximumItems: Int
    var byteBudget: Int

    init(
        retention: ClipboardRetention = .default, maximumItems: Int = 100,
        byteBudget: Int = ClipboardLimits.historyBytes
    ) {
        self.retention = retention
        self.maximumItems = min(Self.itemRange.upperBound, max(Self.itemRange.lowerBound, maximumItems))
        self.byteBudget = max(0, byteBudget)
    }

    /// Entries copied at or before this moment have expired. Nil when they never do.
    func cutoff(now: Date) -> Date? {
        retention.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    /// The entries to keep, in their original order (newest first).
    func prune(_ entries: [ClipboardEntry], now: Date) -> [ClipboardEntry] {
        let cutoff = cutoff(now: now)
        var unpinned = 0
        let candidates = entries.filter { entry in
            if entry.isPinned { return true }
            guard cutoff.map({ entry.copiedAt > $0 }) ?? true, unpinned < maximumItems else { return false }
            unpinned += 1
            return true
        }
        var bytes = 0
        var kept = Set<UUID>()
        for pinned in [true, false] {
            for entry in candidates where entry.isPinned == pinned {
                let cost = max(0, entry.byteCount)
                if cost <= byteBudget - bytes {
                    bytes += cost
                    kept.insert(entry.id)
                }
            }
        }
        return candidates.filter { kept.contains($0.id) }
    }
}
