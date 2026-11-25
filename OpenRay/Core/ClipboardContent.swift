import Foundation

enum ClipboardLimits {
    static let textBytes = 128_000
    static let sourceImageBytes = 64_000_000
    static let imageBytes = 10_000_000
    static let imagePixels = 40_000_000
    static let fileCount = 100
    static let historyBytes = 64_000_000
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
        case .text: isLink ? "Link" : "Text"
        case .image: "Image"
        case .files(let files): files.count == 1 ? "File" : "Files"
        }
    }

    var symbol: String {
        switch content {
        case .text: isLink ? "link" : "text.alignleft"
        case .image: "photo"
        case .files(let files): files.count == 1 ? "doc" : "doc.on.doc"
        }
    }

    var searchableText: String {
        switch content {
        case .text(let text): text + " " + sourceName
        case .image: title + " image picture screenshot " + sourceName
        case .files(let files): files.map(\.path).joined(separator: " ") + " " + sourceName
        }
    }

    var byteCount: Int {
        switch content {
        case .text(let text): text.utf8.count
        case .image(let image): image.byteCount
        case .files(let files): files.reduce(0) { $0 + $1.absoluteString.utf8.count }
        }
    }

    var isValid: Bool {
        switch content {
        case .text(let text):
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && byteCount <= ClipboardLimits.textBytes
        case .image(let image): image.isValid
        case .files(let files):
            !files.isEmpty && files.count <= ClipboardLimits.fileCount
                && files.allSatisfy { $0.isFileURL && $0.path.hasPrefix("/") }
                && Set(files).count == files.count && byteCount <= ClipboardLimits.textBytes
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, image, files, copiedAt, sourceName, sourceBundleID, pinned
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
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
