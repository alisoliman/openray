import AppKit
import CoreGraphics
import PDFKit
import ScreenCaptureKit
import UniformTypeIdentifiers

// Attachments beyond typed text: files (text, code, PDFs through PDFKit), images and
// screenshots (as images for models with vision, otherwise as recognized text), notes,
// clipboard entries and the screen. Long text isn't refused; chat summarizes it in parts
// to fit when it's sent (`AttachmentCondenser`).

enum AIAttachmentError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupported(String)
    case tooLarge(String)
    case noText(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "OpenRay couldn't read “\(name)”."
        case .unsupported(let name): "“\(name)” isn't a text, PDF or image file, so it can't be attached."
        case .tooLarge(let name): "“\(name)” is too large to attach. Choose a file under 20 MB."
        case .noText(let name): "OpenRay found no text in “\(name)”."
        }
    }
}

enum AIAttachmentLoader {
    static let maximumFileBytes = 20_000_000

    /// Reads a file as an attachment. Images become pictures when the model has vision, and
    /// their recognized text otherwise.
    @MainActor
    static func load(_ url: URL, capabilities: AIModelCapabilities, recognizer: any TextRecognizing) async throws
        -> AIAttachment
    {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true { throw AIAttachmentError.unsupported(name) }
        if let size = values?.fileSize, size > maximumFileBytes { throw AIAttachmentError.tooLarge(name) }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { throw AIAttachmentError.unreadable(name) }
            let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AIAttachmentError.noText(name) }
            return AIAttachment(source: .file, text: text, name: name)
        }
        if type.conforms(to: .image) {
            guard let data = try? Data(contentsOf: url) else { throw AIAttachmentError.unreadable(name) }
            return try await image(data, name: name, source: .image, capabilities: capabilities, recognizer: recognizer)
        }
        guard let data = try? Data(contentsOf: url) else { throw AIAttachmentError.unreadable(name) }
        guard let text = decodedText(data, isText: type.conforms(to: .text)) else { throw AIAttachmentError.unsupported(name) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIAttachmentError.noText(name) }
        return AIAttachment(source: .file, text: text, name: name)
    }

    /// A picture: kept as an image for models with vision; read with on-device text
    /// recognition otherwise.
    @MainActor
    static func image(
        _ data: Data, name: String, source: AIAttachment.Source, capabilities: AIModelCapabilities,
        recognizer: any TextRecognizing
    ) async throws -> AIAttachment {
        if capabilities.contains(.vision) {
            return AIAttachment(source: source, text: "", name: name, image: AIImageInput(data: data, label: name))
        }
        let result = try await recognizer.recognizeText(in: data, options: TextRecognitionOptions())
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIAttachmentError.noText(name) }
        return AIAttachment(source: source, text: text, name: name)
    }

    /// Text from a file's bytes: UTF-8 or UTF-16, or Latin-1 for declared text. Binary data
    /// (a NUL in the first few kilobytes) isn't text.
    static func decodedText(_ data: Data, isText: Bool) -> String? {
        if data.prefix(4_096).contains(0), !(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])) {
            return nil
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return isText ? String(data: data, encoding: .isoLatin1) : nil
    }

    static func note(_ note: QuickNote) -> AIAttachment {
        AIAttachment(source: .note, text: note.content, name: note.title)
    }

    /// A clipboard history entry: its text, or the text recognized in its image.
    static func clipboardEntry(_ entry: ClipboardEntry) -> AIAttachment? {
        guard let text = entry.plainText ?? entry.recognizedText, !text.isEmpty else { return nil }
        return AIAttachment(source: .clipboard, text: text, appName: entry.sourceName)
    }
}

// MARK: - Screen

/// What to capture for screen context.
enum AIScreenTarget: Equatable, Sendable {
    /// The frontmost window of the app OpenRay was opened over.
    case focusedWindow(processID: pid_t?)
    /// The main display, without OpenRay's own windows.
    case entireScreen
}

/// Captures the screen for AI context. Opt-in, and the permission is asked only when the
/// person chooses to attach the screen.
@MainActor
protocol AIScreenCapturing {
    var hasPermission: Bool { get }
    /// Shows macOS's Screen Recording prompt. False when it can't or wasn't granted yet.
    func requestPermission() -> Bool
    func capture(_ target: AIScreenTarget) async throws -> (png: Data, title: String)
}

enum AIScreenCaptureError: LocalizedError, Equatable {
    case noPermission, nothingToCapture, unknownWindow, failed(String)
    var errorDescription: String? {
        switch self {
        case .unknownWindow:
            "OpenRay couldn't tell which window to attach. Open OpenRay over that window, then try again."
        case .noPermission:
            "OpenRay needs Screen Recording permission to attach the screen. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        case .nothingToCapture: "There's no window to capture."
        case .failed(let message): message
        }
    }
}

/// ScreenCaptureKit, behind `SideEffectGuard`: it never captures in tests or verification.
@MainActor
struct LiveScreenCapture: AIScreenCapturing {
    var sideEffects: SideEffectGuard = .current

    /// Inert where either this adapter's rule or the process's is (tests, verification).
    private var isInert: Bool { sideEffects.isInert || SideEffectGuard.isInert }

    var hasPermission: Bool { !isInert && CGPreflightScreenCaptureAccess() }

    func requestPermission() -> Bool {
        guard (try? sideEffects.check("asking for Screen Recording permission")) != nil else { return false }
        return CGRequestScreenCaptureAccess()
    }

    func capture(_ target: AIScreenTarget) async throws -> (png: Data, title: String) {
        try sideEffects.check("capturing the screen")
        guard CGPreflightScreenCaptureAccess() else { throw AIScreenCaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        let title: String
        switch target {
        case .focusedWindow(let pid):
            // Only the app OpenRay opened over, and its frontmost window in on-screen order.
            guard let pid, pid != ownPID else { throw AIScreenCaptureError.unknownWindow }
            guard let frontID = Self.frontmostWindowID(of: pid),
                let window = content.windows.first(where: { $0.windowID == frontID })
            else { throw AIScreenCaptureError.nothingToCapture }
            filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            title = [window.owningApplication?.applicationName, window.title].compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " — ")
        case .entireScreen:
            guard let display = content.displays.first else { throw AIScreenCaptureError.nothingToCapture }
            let own = content.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            configuration.width = display.width * 2
            configuration.height = display.height * 2
            title = "Screen"
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw AIScreenCaptureError.failed("The capture couldn't be encoded.")
        }
        return (png, title.isEmpty ? "Window" : title)
    }
}

extension LiveScreenCapture {
    /// The frontmost normal window of an app, from the window server's front-to-back order.
    static func frontmostWindowID(of pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }
        let entry = list.first { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0
        }
        return (entry?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
    }
}

/// Refuses every capture, for tests.
@MainActor
struct InertScreenCapture: AIScreenCapturing {
    var hasPermission: Bool { false }
    func requestPermission() -> Bool { false }
    func capture(_ target: AIScreenTarget) async throws -> (png: Data, title: String) {
        throw AIScreenCaptureError.failed("Screen capture is off here.")
    }
}
