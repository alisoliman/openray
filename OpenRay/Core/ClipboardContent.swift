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
    case all, text, images, files
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func includes(_ entry: ClipboardEntry) -> Bool {
        switch (self, entry.content) {
        case (.all, _), (.text, .text), (.images, .image), (.files, .files): true
        default: false
        }
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
        case .text: "Text"
        case .image: "Image"
        case .files(let files): files.count == 1 ? "File" : "Files"
        }
    }

    var symbol: String {
        switch content {
        case .text: "doc.on.clipboard"
        case .image: "photo"
        case .files: "doc.on.doc"
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
        case id, kind, text, image, files, copiedAt, sourceName, sourceBundleID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
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
