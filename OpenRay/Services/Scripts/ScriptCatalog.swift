import CoreServices
import CryptoKit
import Foundation
import Observation

/// A script command found in one of the person's script folders.
struct ScriptCommand: Identifiable, Hashable, Sendable {
    /// `script.` and the first 16 hex digits of the SHA-256 of the script's resolved path, so the
    /// id survives edits and relaunches, and favorites, aliases and hotkeys stay attached.
    var id: String
    var url: URL
    var directoryID: UUID
    var metadata: ScriptMetadata
    /// The header's `packageName`, else the folder's name, as the format specifies.
    var packageName: String
    /// The program and leading arguments that start the script: the file itself when it's
    /// executable, else the interpreter its `#!` line names.
    var launch: [String]

    var title: String { metadata.title }
    var mode: ScriptOutputMode { metadata.mode }

    static let idPrefix = "script."

    static func id(for url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return idPrefix + SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// A file with a script header that can't be used, and why. Settings › Scripts lists these.
struct ScriptIssue: Identifiable, Hashable, Sendable {
    var url: URL
    var directoryID: UUID
    /// The header's title, when it has one.
    var title: String?
    var problems: [String]

    var id: String { url.path }
}

/// What a scan of the script folders found.
struct ScriptScan: Equatable, Sendable {
    var commands: [ScriptCommand] = []
    var issues: [ScriptIssue] = []
    /// Folders that couldn't be read, by record id, with the reason.
    var unreadable: [UUID: String] = [:]
    /// Turned-on folders that this Mac hasn't allowed, or that changed since: moved, replaced
    /// or pointed elsewhere. Their scripts aren't read until the person allows them again.
    var unapproved: Set<UUID> = []
}

/// Reads script folders. Pure file reading, safe off the main actor.
enum ScriptScanner {
    /// Larger files aren't read; a script header is a few lines at the top.
    static let maximumFileBytes = 512 * 1024

    enum Inspection: Equatable, Sendable {
        case command(ScriptCommand)
        case issue(ScriptIssue)
    }

    /// Scans each enabled folder's top level in name order. Hidden files, files whose name
    /// contains `.template.` (the format's marker for scripts that need editing first) and files
    /// without any header lines are skipped quietly. With `approvals`, a folder is read only when
    /// it's still the folder this Mac allowed; nil skips that check (tests of the format only).
    static func scan(_ directories: [ScriptDirectoryRecord], approvals: [UUID: FolderIdentity]? = nil) -> ScriptScan {
        var result = ScriptScan()
        var seen = Set<String>()
        for directory in directories where directory.isEnabled {
            guard let folder = directory.url else { continue }
            if let approvals {
                guard let approved = approvals[directory.id], FolderIdentity.current(of: folder) == approved else {
                    result.unapproved.insert(directory.id)
                    continue
                }
            }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles])
            } catch {
                result.unreadable[directory.id] = error.localizedDescription
                continue
            }
            let sorted = entries.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            for url in sorted {
                switch inspect(url, directory: directory) {
                case .command(let command)?:
                    if seen.insert(command.id).inserted { result.commands.append(command) }
                case .issue(let issue)?:
                    if seen.insert(ScriptCommand.id(for: issue.url)).inserted { result.issues.append(issue) }
                case nil:
                    continue
                }
            }
        }
        return result
    }

    /// One file: a command, an issue, or nil when it isn't a script command at all.
    static func inspect(_ url: URL, directory: ScriptDirectoryRecord) -> Inspection? {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), !name.contains(".template.") else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, (values.fileSize ?? 0) <= maximumFileBytes,
            let data = try? Data(contentsOf: resolved)
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let fields = ScriptMetadataParser.fields(in: text)
        guard !fields.isEmpty else { return nil }
        let headerTitle = fields.last(where: { $0.key == "title" })?.value
        let metadata: ScriptMetadata
        do {
            metadata = try ScriptMetadataParser.parse(text, scriptURL: url)
        } catch let error as ScriptMetadataError {
            return .issue(ScriptIssue(url: url, directoryID: directory.id, title: headerTitle, problems: error.problems))
        } catch {
            return .issue(
                ScriptIssue(url: url, directoryID: directory.id, title: headerTitle, problems: [error.localizedDescription]))
        }
        guard let launch = launchCommand(for: url, text: text) else {
            return .issue(
                ScriptIssue(
                    url: url, directoryID: directory.id, title: headerTitle,
                    problems: ["The script isn't executable and has no #! line. Run chmod +x on it, or add one."]))
        }
        let folderName = directory.url?.lastPathComponent ?? url.deletingLastPathComponent().lastPathComponent
        return .command(
            ScriptCommand(
                id: ScriptCommand.id(for: url), url: url, directoryID: directory.id, metadata: metadata,
                packageName: metadata.packageName ?? folderName, launch: launch))
    }

    /// The file itself when it's executable; else its `#!` interpreter and that line's arguments,
    /// followed by the file. Nil when neither works.
    static func launchCommand(for url: URL, text: String) -> [String]? {
        if FileManager.default.isExecutableFile(atPath: url.path) { return [url.path] }
        guard let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
            line.hasPrefix("#!")
        else { return nil }
        let parts = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
        guard let interpreter = parts.first, interpreter.hasPrefix("/") else { return nil }
        return parts + [url.path]
    }
}

/// Tells the catalog when files in its folders change.
@MainActor
protocol DirectoryWatching: AnyObject {
    func watch(_ folders: [URL], onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Watches folders with FSEvents, coalescing bursts of changes over half a second.
@MainActor
final class FSEventsDirectoryWatcher: DirectoryWatching {
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var onChange: (@MainActor () -> Void)?

    init() {}

    func watch(_ folders: [URL], onChange: @escaping @MainActor () -> Void) {
        stop()
        guard !folders.isEmpty else { return }
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange?() }
        }
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, folders.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// The script commands in the person's script folders, kept current as files change.
@MainActor
@Observable
final class ScriptCatalog {
    private(set) var scan = ScriptScan()
    private(set) var directories: [ScriptDirectoryRecord] = []
    private(set) var approvals: [UUID: FolderIdentity] = [:]
    private(set) var isScanning = false
    /// True once the first scan has finished, so links to scripts can wait for it.
    private(set) var hasLoaded = false
    @ObservationIgnored private var loadWaiters: [@MainActor () -> Void] = []
    /// Called after a scan changes the commands, so the launcher re-registers hotkeys.
    @ObservationIgnored var didChange: (@MainActor () -> Void)?
    @ObservationIgnored private let watcher: (any DirectoryWatching)?
    @ObservationIgnored private var generation = 0

    /// `watcher` nil never watches; tests reload by hand.
    init(watcher: (any DirectoryWatching)? = nil) {
        self.watcher = watcher
    }

    var commands: [ScriptCommand] { scan.commands }
    var issues: [ScriptIssue] { scan.issues }

    func command(withID id: String) -> ScriptCommand? { scan.commands.first { $0.id == id } }

    /// Points the catalog at these folders and this Mac's approvals. A change rescans and
    /// rewatches; the same lists do nothing.
    func setDirectories(
        _ records: [ScriptDirectoryRecord], approvals: [UUID: FolderIdentity], synchronously: Bool = false
    ) {
        guard records != directories || approvals != self.approvals else {
            if !hasLoaded, records.isEmpty { finishLoading() }
            return
        }
        directories = records
        self.approvals = approvals
        let watched = records.filter { $0.isEnabled && approvals[$0.id] != nil }.compactMap(\.url)
        watcher?.watch(watched) { [weak self] in self?.reload() }
        if synchronously { reloadNow() } else { reload() }
    }

    /// Runs `action` once the first scan has finished: now, if it has.
    func whenLoaded(_ action: @escaping @MainActor () -> Void) {
        if hasLoaded { action() } else { loadWaiters.append(action) }
    }

    private func finishLoading() {
        hasLoaded = true
        let waiters = loadWaiters
        loadWaiters = []
        for waiter in waiters { waiter() }
    }

    /// Rescans off the main actor. A later reload supersedes an earlier one still running.
    func reload() {
        generation += 1
        let generation = generation
        let directories = directories
        let approvals = approvals
        isScanning = true
        Task.detached(priority: .utility) { [weak self] in
            let result = ScriptScanner.scan(directories, approvals: approvals)
            await self?.apply(result, generation: generation)
        }
    }

    /// Rescans now, on the calling thread.
    func reloadNow() {
        generation += 1
        isScanning = true
        apply(ScriptScanner.scan(directories, approvals: approvals), generation: generation)
    }

    private func apply(_ result: ScriptScan, generation: Int) {
        guard generation == self.generation else { return }
        isScanning = false
        if result != scan {
            let commandsChanged = result.commands != scan.commands
            scan = result
            if commandsChanged { didChange?() }
        }
        if !hasLoaded { finishLoading() }
    }
}

/// A new script command, written from a starter template.
enum ScriptTemplate {
    enum Language: String, CaseIterable, Identifiable, Sendable {
        case bash, python, applescript, swift, node, ruby

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bash: "Bash"
            case .python: "Python"
            case .applescript: "AppleScript"
            case .swift: "Swift"
            case .node: "JavaScript (Node)"
            case .ruby: "Ruby"
            }
        }

        var fileExtension: String {
            switch self {
            case .bash: "sh"
            case .python: "py"
            case .applescript: "applescript"
            case .swift: "swift"
            case .node: "js"
            case .ruby: "rb"
            }
        }

        var shebang: String {
            switch self {
            case .bash: "#!/bin/bash"
            case .python: "#!/usr/bin/env python3"
            case .applescript: "#!/usr/bin/osascript"
            case .swift: "#!/usr/bin/swift"
            case .node: "#!/usr/bin/env node"
            case .ruby: "#!/usr/bin/env ruby"
            }
        }

        var comment: String {
            switch self {
            case .swift, .node: "//"
            case .bash, .python, .applescript, .ruby: "#"
            }
        }

        /// A first line of code that prints a greeting and, when there's an argument, the first one.
        func body(hasArgument: Bool) -> String {
            switch self {
            case .bash:
                hasArgument ? "echo \"Hello, $1\"" : "echo \"Hello from OpenRay\""
            case .python:
                hasArgument ? "import sys\n\nprint(f\"Hello, {sys.argv[1]}\")" : "print(\"Hello from OpenRay\")"
            case .applescript:
                hasArgument
                    ? "on run argv\n  return \"Hello, \" & (item 1 of argv)\nend run"
                    : "on run argv\n  return \"Hello from OpenRay\"\nend run"
            case .swift:
                hasArgument
                    ? "import Foundation\n\nprint(\"Hello, \\(CommandLine.arguments[1])\")"
                    : "print(\"Hello from OpenRay\")"
            case .node:
                hasArgument ? "console.log(`Hello, ${process.argv[2]}`)" : "console.log(\"Hello from OpenRay\")"
            case .ruby:
                hasArgument ? "puts \"Hello, #{ARGV[0]}\"" : "puts \"Hello from OpenRay\""
            }
        }
    }

    struct Draft: Equatable, Sendable {
        var title = ""
        var mode: ScriptOutputMode = .compact
        var language: Language = .bash
        var packageName = ""
        var icon = ""
        /// Inline scripts only: `10s`, `5m`, `1h`.
        var refreshTime = "1m"
        var needsConfirmation = false
        /// A placeholder adds one required text argument.
        var argumentPlaceholder = ""
    }

    /// The new file's contents. Keys use OpenRay's `@openray.` alias of the format's keys.
    static func render(_ draft: Draft) -> String {
        let c = draft.language.comment
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [draft.language.shebang, "", "\(c) Script command for OpenRay. The lines below describe it;"]
        lines.append("\(c) edit them and save, and OpenRay picks up the change.")
        lines.append(c)
        lines.append("\(c) @openray.schemaVersion 1")
        lines.append("\(c) @openray.title \(title.isEmpty ? "New Script" : title)")
        lines.append("\(c) @openray.mode \(draft.mode.rawValue)")
        let package = draft.packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !package.isEmpty { lines.append("\(c) @openray.packageName \(package)") }
        let icon = draft.icon.trimmingCharacters(in: .whitespacesAndNewlines)
        if !icon.isEmpty { lines.append("\(c) @openray.icon \(icon)") }
        if draft.mode == .inline {
            let refresh = draft.refreshTime.trimmingCharacters(in: .whitespaces)
            lines.append("\(c) @openray.refreshTime \(refresh.isEmpty ? "1m" : refresh)")
        }
        if draft.needsConfirmation { lines.append("\(c) @openray.needsConfirmation true") }
        let placeholder = draft.argumentPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !placeholder.isEmpty {
            let json = (try? JSONSerialization.data(
                withJSONObject: ["type": "text", "placeholder": placeholder], options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{ \"type\": \"text\", \"placeholder\": \"Value\" }"
            lines.append("\(c) @openray.argument1 \(json)")
        }
        lines.append("")
        lines.append(draft.language.body(hasArgument: !placeholder.isEmpty))
        return lines.joined(separator: "\n") + "\n"
    }

    /// `my-script.sh` from “My Script”: lowercase letters, digits and dashes.
    static func fileName(for title: String, language: Language) -> String {
        let slug = title.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        return (slug.isEmpty ? "script" : String(slug.prefix(60))) + "." + language.fileExtension
    }

    /// Writes a new executable script into `folder`. Never replaces a file: a taken name gets a number.
    static func create(_ draft: Draft, in folder: URL, sideEffects: SideEffectGuard = .current) throws -> URL {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryValidationError("Give the script a title.")
        }
        try InertWrites.check(folder, sideEffects: sideEffects, what: "creating scripts")
        let base = fileName(for: draft.title, language: draft.language)
        let stem = (base as NSString).deletingPathExtension
        var url = folder.appending(path: base)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(stem)-\(number).\(draft.language.fileExtension)")
            number += 1
        }
        let data = Data(render(draft).utf8)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o755])
        else { throw LibraryValidationError("Couldn't create \(url.lastPathComponent) in \(folder.lastPathComponent).") }
        return url
    }
}
