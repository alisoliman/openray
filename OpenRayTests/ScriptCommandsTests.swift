import AppKit
import Foundation
import Testing

@testable import OpenRay

/// A temporary folder of harmless fixture scripts (`echo`, `printf`, `sleep`, `exit`), removed afterwards.
final class ScriptFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "OpenRayScriptTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ name: String, _ contents: String, executable: Bool = true) throws -> URL {
        let file = url.appending(path: name)
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        return file
    }

    /// A bash script command with the given mode and body.
    @discardableResult
    func script(
        _ name: String, title: String, mode: String = "compact", extra: [String] = [], body: String
    ) throws -> URL {
        let header = ["#!/bin/bash", "# @raycast.schemaVersion 1", "# @raycast.title \(title)", "# @raycast.mode \(mode)"]
            + extra.map { "# @raycast.\($0)" }
        return try write(name, (header + ["", body]).joined(separator: "\n") + "\n")
    }

    var record: ScriptDirectoryRecord { ScriptDirectoryRecord(path: url.path) }

    /// A fixed environment for fixture processes: system paths only, home in the fixture folder,
    /// nothing inherited from the developer's shell (no BASH_ENV, no personal PATH entries).
    var environment: [String: String] {
        ScriptEnvironment.make(base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": url.path, "LANG": "en_US.UTF-8"])
    }

    /// This folder's identity now, as an approval records it.
    var identity: FolderIdentity? { FolderIdentity.current(of: url) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Records silent scripts' HUD messages instead of drawing them.
@MainActor
final class RecordingScriptPresenter: ScriptResultPresenting {
    var messages: [(text: String, isError: Bool)] = []
    init() {}
    func showHUD(_ text: String, isError: Bool, in model: LauncherModel) { messages.append((text, isError)) }
}

/// A launcher that never starts a process: it answers with a canned result.
struct CannedScriptLauncher: ScriptProcessLaunching {
    var execution: ScriptExecution
    func run(_ invocation: ScriptInvocation, onOutput: @escaping @Sendable (String) -> Void) async -> ScriptExecution {
        onOutput(execution.output)
        return execution
    }
}

private func parse(_ text: String, at path: String = "/tmp/scripts/fixture.sh") throws -> ScriptMetadata {
    try ScriptMetadataParser.parse(text, scriptURL: URL(fileURLWithPath: path))
}

private func command(_ text: String, path: String = "/tmp/scripts/fixture.sh") throws -> ScriptCommand {
    let url = URL(fileURLWithPath: path)
    let metadata = try ScriptMetadataParser.parse(text, scriptURL: url)
    return ScriptCommand(
        id: ScriptCommand.id(for: url), url: url, directoryID: UUID(), metadata: metadata,
        packageName: metadata.packageName ?? "scripts", launch: [url.path])
}

// MARK: - Metadata

@Suite("Script metadata")
struct ScriptMetadataTests {
    @Test("Every public template header parses, in each comment style")
    func templates() throws {
        for fixture in [
            ScriptFixtures.bashTemplate, ScriptFixtures.swiftTemplate, ScriptFixtures.pythonTemplate,
            ScriptFixtures.javaScriptTemplate,
        ] {
            let metadata = try parse(fixture)
            #expect(metadata.schemaVersion == 1)
            #expect(metadata.title == "My First Script")
            #expect(metadata.mode == .fullOutput)
            #expect(metadata.packageName == "Raycast Scripts")
            #expect(metadata.icon == .emoji("🤖"))
            #expect(metadata.author == "Your name")
            #expect(metadata.description?.hasPrefix("Write a nice") == true)
            #expect(!metadata.needsConfirmation)
        }
        let bash = try parse(ScriptFixtures.bashTemplate)
        #expect(bash.workingDirectory.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        #expect(bash.authorURL == "An URL for one of your social medias")
    }

    @Test("JavaScript template arguments map to argument specs in order")
    func javaScriptArguments() throws {
        let metadata = try parse(ScriptFixtures.javaScriptTemplate)
        #expect(metadata.arguments.map(\.index) == [1, 2])
        #expect(metadata.arguments[0].spec == ArgumentSpec(name: "argument1", placeholder: "js, css, html", isOptional: true))
        #expect(metadata.arguments[1].spec == ArgumentSpec(name: "argument2", placeholder: "query"))
        // Without a value for the required one, resolution fails like any command's arguments.
        #expect(throws: (any Error).self) { try ArgumentSpec.resolve(metadata.arguments.map(\.spec), typed: [:]) }
        let resolved = try ArgumentSpec.resolve(metadata.arguments.map(\.spec), typed: ["argument2": " fetch "])
        #expect(resolved == ["argument2": "fetch"])
    }

    @Test("Community inline scripts keep their refresh time")
    func inlineScripts() throws {
        let cpu = try parse(ScriptFixtures.inlineCPU)
        #expect(cpu.mode == .inline)
        #expect(cpu.refreshTime == .seconds(10))
        #expect(cpu.packageName == "System")
        #expect(cpu.icon == .emoji("🖥️"))
        let caffeinate = try parse(ScriptFixtures.caffeinateStatus)
        #expect(caffeinate.mode == .inline)
        #expect(caffeinate.refreshTime == .seconds(30))
        #expect(caffeinate.icon == .emoji("☕️"))
    }

    @Test("AppleScript headers in any key order, with icons relative to the script's folder")
    func appleScript() throws {
        let metadata = try parse(ScriptFixtures.amphetamineOn, at: "/Users/x/Scripts/amphetamine-on.applescript")
        #expect(metadata.title == "Start Default Session")
        #expect(metadata.mode == .silent)
        #expect(metadata.icon == .file(URL(fileURLWithPath: "/Users/x/Scripts/images/amphetamine.png")))
        #expect(metadata.workingDirectory.path == "/Users/x/Scripts")
    }

    @Test("Three optional arguments and a JXA shebang")
    func timing() throws {
        let metadata = try parse(ScriptFixtures.timingStartTimer)
        #expect(metadata.arguments.map(\.placeholder) == ["Project", "Title", "Duration"])
        #expect(metadata.arguments.allSatisfy { $0.isOptional })
        let weather = try parse(ScriptFixtures.checkWeather)
        #expect(weather.packageName == "wttr.in")
        #expect(weather.arguments.count == 2)
    }

    @Test("-- comments and the @openray. alias")
    func luaStyleAndAlias() throws {
        let text = """
            #!/usr/bin/osascript
            -- @openray.schemaVersion 1
            -- @openray.title Toggle Something
            -- @raycast.mode compact
            -- @openray.needsConfirmation true
            return "ok"
            """
        let metadata = try parse(text)
        #expect(metadata.title == "Toggle Something")
        #expect(metadata.mode == .compact)
        #expect(metadata.needsConfirmation)
    }

    @Test("Only comment lines count, and keys must match exactly")
    func onlyComments() throws {
        let text = """
            #!/bin/bash
            # @raycast.schemaVersion 1
            # @raycast.title Real Title
            # @raycast.titles Not A Title
            # @raycast.mode silent
            echo "# @raycast.title Fake"
            """
        let metadata = try parse(text)
        #expect(metadata.title == "Real Title")
        #expect(!ScriptMetadataParser.hasMetadata("#!/bin/bash\necho hi\n"))
    }

    @Test("Missing or wrong required keys are reported together")
    func requiredKeys() {
        do {
            _ = try parse("#!/bin/bash\n# @raycast.schemaVersion 2\n# @raycast.mode loud\n")
            Issue.record("Expected an error")
        } catch let error as ScriptMetadataError {
            #expect(error.problems.count == 3)
            #expect(error.problems.contains { $0.contains("schemaVersion") })
            #expect(error.problems.contains { $0.contains("title is missing") })
            #expect(error.problems.contains { $0.contains("loud") })
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("refreshTime has a ten-second minimum; inline without it runs as compact")
    func refreshMinimum() throws {
        let fast = try parse("# @raycast.schemaVersion 1\n# @raycast.title Fast\n# @raycast.mode inline\n# @raycast.refreshTime 5s\n")
        #expect(fast.refreshTime == .seconds(10))
        #expect(fast.warnings.contains { $0.contains("minimum") })
        #expect(ScriptMetadataParser.parseRefreshTime("2m") == .seconds(120))
        #expect(ScriptMetadataParser.parseRefreshTime("12h") == .seconds(43_200))
        #expect(ScriptMetadataParser.parseRefreshTime("1d") == .seconds(86_400))
        #expect(ScriptMetadataParser.parseRefreshTime("soon") == nil)
        #expect(ScriptMetadataParser.parseRefreshTime("0s") == nil)
        let missing = try parse("# @raycast.schemaVersion 1\n# @raycast.title Slow\n# @raycast.mode inline\n")
        #expect(missing.declaredMode == .inline)
        #expect(missing.mode == .compact)
        #expect(missing.refreshTime == nil)
        let compact = try parse("# @raycast.schemaVersion 1\n# @raycast.title C\n# @raycast.mode compact\n# @raycast.refreshTime 1m\n")
        #expect(compact.refreshTime == nil)
    }

    @Test("Argument types: dropdown data, password, the deprecated secure flag and percent-encoding")
    func argumentTypes() throws {
        let dropdown = try ScriptMetadataParser.parseArgument(
            #"{ "type": "dropdown", "placeholder": "Size", "data": [{"title": "Small", "value": "s"}, {"title": "Large", "value": "l"}] }"#,
            index: 1)
        #expect(dropdown.type == .dropdown([.init(title: "Small", value: "s"), .init(title: "Large", value: "l")]))
        let password = try ScriptMetadataParser.parseArgument(#"{ "type": "password", "placeholder": "Token" }"#, index: 2)
        #expect(password.type == .password)
        let secure = try ScriptMetadataParser.parseArgument(#"{ "type": "text", "placeholder": "Key", "secure": true }"#, index: 3)
        #expect(secure.type == .password)
        let encoded = try ScriptMetadataParser.parseArgument(#"{ "placeholder": "q", "percentEncoded": true }"#, index: 1)
        #expect(encoded.encoded("a b&c/é") == "a%20b%26c%2F%C3%A9")
        #expect(throws: (any Error).self) { try ScriptMetadataParser.parseArgument(#"{ "type": "text" }"#, index: 1) }
        #expect(throws: (any Error).self) {
            try ScriptMetadataParser.parseArgument(#"{ "type": "dropdown", "placeholder": "x" }"#, index: 1)
        }
        #expect(throws: (any Error).self) {
            try ScriptMetadataParser.parseArgument(#"{ "type": "date", "placeholder": "x" }"#, index: 1)
        }
        #expect(throws: (any Error).self) { try ScriptMetadataParser.parseArgument("not json", index: 1) }
    }

    @Test("A fourth argument is ignored with a warning; a bad one makes the script invalid")
    func argumentLimits() throws {
        let four = try parse(
            """
            # @raycast.schemaVersion 1
            # @raycast.title Four
            # @raycast.mode compact
            # @raycast.argument1 { "type": "text", "placeholder": "a" }
            # @raycast.argument4 { "type": "text", "placeholder": "d" }
            """)
        #expect(four.arguments.count == 1)
        #expect(four.warnings.contains { $0.contains("argument4") })
        #expect(throws: ScriptMetadataError.self) {
            try parse("# @raycast.schemaVersion 1\n# @raycast.title Bad\n# @raycast.mode compact\n# @raycast.argument1 {}\n")
        }
    }

    @Test("Icons: emoji, relative and absolute files, https only")
    func icons() {
        let folder = URL(fileURLWithPath: "/s")
        #expect(ScriptIcon.parse("🇩🇪", relativeTo: folder) == .emoji("🇩🇪"))
        #expect(ScriptIcon.parse("./images/a.png", relativeTo: folder) == .file(URL(fileURLWithPath: "/s/images/a.png")))
        #expect(ScriptIcon.parse("/abs/b.icns", relativeTo: folder) == .file(URL(fileURLWithPath: "/abs/b.icns")))
        #expect(ScriptIcon.parse("https://example.com/i.png", relativeTo: folder) == .remote(URL(string: "https://example.com/i.png")!))
        #expect(ScriptIcon.parse("http://example.com/i.png", relativeTo: folder) == nil)
        #expect(ScriptIcon.parse("hello", relativeTo: folder) == nil)
    }

    @Test("$1–$3 keep their positions and are percent-encoded when asked")
    func positionalArguments() throws {
        let flights = try command(ScriptFixtures.searchFlights)
        #expect(ScriptRunner.positionalArguments(for: flights, values: ["argument1": "New York"]) == ["New%20York", ""])
        let gap = try command(
            """
            # @raycast.schemaVersion 1
            # @raycast.title Gap
            # @raycast.mode compact
            # @raycast.argument2 { "type": "text", "placeholder": "b" }
            """)
        #expect(ScriptRunner.positionalArguments(for: gap, values: ["argument2": "x"]) == ["", "x"])
        let none = try command("# @raycast.schemaVersion 1\n# @raycast.title None\n# @raycast.mode compact\n")
        #expect(ScriptRunner.positionalArguments(for: none, values: ["argument1": "ignored"]) == [])
    }
}

// MARK: - ANSI

@Suite("ANSI output")
struct ANSITextTests {
    @Test("SGR colors and styles become spans; reset clears them")
    func colors() {
        let spans = ANSIText.parse("plain \u{1B}[1;31;42mred on green\u{1B}[0m done")
        #expect(spans.map(\.text) == ["plain ", "red on green", " done"])
        #expect(spans[1].style.bold)
        #expect(spans[1].style.foreground == .standard(1))
        #expect(spans[1].style.background == .standard(2))
        #expect(spans[2].style == .plain)
    }

    @Test("8-bit and 24-bit colors, bright colors and style resets")
    func extendedColors() {
        let spans = ANSIText.parse("\u{1B}[38;5;196ma\u{1B}[48;2;1;2;3mb\u{1B}[97;4mc\u{1B}[24;39;49md")
        #expect(spans[0].style.foreground == .palette(196))
        #expect(spans[0].style.foreground?.rgbComponents?.red == 255)
        #expect(spans[1].style.background == .rgb(1, 2, 3))
        #expect(spans[2].style.foreground == .bright(7))
        #expect(spans[2].style.underline)
        #expect(spans[3].style == .plain)
        #expect(ANSIColor.palette(9).normalized == .bright(1))
        #expect(ANSIColor.palette(244).rgbComponents?.green == 128)
    }

    @Test("Other escape sequences and control characters are dropped; \\r rewrites its line")
    func stripping() {
        #expect(ANSIText.strip("a\u{1B}[2Kb\u{1B}]0;title\u{07}c\u{1B}(Bd\u{07}e") == "abcde")
        #expect(ANSIText.strip("10%\r50%\r100%\nnext") == "100%\nnext")
        #expect(ANSIText.strip("crlf\r\nline") == "crlf\nline")
    }

    @Test("Streamed bytes never split a character")
    func utf8Boundaries() {
        let bytes = Data("aé😀".utf8)
        let cut = bytes.prefix(bytes.count - 2)
        let (complete, rest) = ANSIText.splitCompleteUTF8(Data(cut))
        #expect(String(decoding: complete, as: UTF8.self) == "aé")
        #expect(rest.count == 2)
        #expect(ANSIText.splitCompleteUTF8(bytes).remainder.isEmpty)
    }

    @Test("Execution lines ignore escapes and blank lines")
    func executionLines() {
        let execution = ScriptExecution(
            termination: .exited(0), output: "\u{1B}[32mfirst\u{1B}[0m\n\nlast\n\n", duration: .zero)
        #expect(execution.firstLine == "first")
        #expect(execution.lastLine == "last")
        let failed = ScriptExecution(termination: .exited(4), output: "", duration: .zero)
        #expect(failed.failureMessage(title: "Deploy").contains("exit code 4"))
    }
}

// MARK: - Folders

@Suite("Script folders")
@MainActor
struct ScriptCatalogTests {
    @Test("A scan finds scripts, skips templates, hidden files and plain files, and reports bad headers")
    func scan() throws {
        let folder = try ScriptFolder()
        try folder.script("b-hello.sh", title: "Hello", body: "echo hi")
        try folder.script("a-inline.sh", title: "Clock", mode: "inline", extra: ["refreshTime 1m", "packageName Clocks"], body: "date")
        try folder.script("c.template.sh", title: "Template", body: "echo")
        try folder.script(".hidden.sh", title: "Hidden", body: "echo")
        try folder.write("README.md", "# Notes\nNothing here.\n")
        try folder.write("broken.sh", "#!/bin/bash\n# @raycast.title Broken\n")
        let scan = ScriptScanner.scan([folder.record])
        #expect(scan.commands.map(\.title) == ["Clock", "Hello"])
        #expect(scan.commands[0].packageName == "Clocks")
        // Without a packageName, the folder's name is the package.
        #expect(scan.commands[1].packageName == folder.url.lastPathComponent)
        #expect(scan.issues.map(\.title) == ["Broken"])
        #expect(scan.issues[0].problems.contains { $0.contains("schemaVersion") })
    }

    @Test("Ids come from the path, so they're stable across scans and distinct per file")
    func stableIDs() throws {
        let folder = try ScriptFolder()
        let file = try folder.script("one.sh", title: "One", body: "echo 1")
        try folder.script("two.sh", title: "Two", body: "echo 2")
        let first = ScriptScanner.scan([folder.record])
        try folder.script("one.sh", title: "One Renamed", body: "echo 1")
        let second = ScriptScanner.scan([folder.record])
        #expect(first.commands.map(\.id) == second.commands.map(\.id))
        #expect(Set(first.commands.map(\.id)).count == 2)
        #expect(first.commands[0].id == ScriptCommand.id(for: file))
        #expect(first.commands[0].id.hasPrefix("script."))
        #expect(first.commands[0].id.count == "script.".count + 16)
    }

    @Test("Non-executable scripts run through their #! interpreter; without one they're reported")
    func launchCommands() throws {
        let folder = try ScriptFolder()
        let plain = try folder.write(
            "plain.sh", "#!/usr/bin/env bash -e\n# @raycast.schemaVersion 1\n# @raycast.title P\n# @raycast.mode silent\n",
            executable: false)
        try folder.write(
            "nothing.txt", "# @raycast.schemaVersion 1\n# @raycast.title N\n# @raycast.mode silent\n", executable: false)
        let scan = ScriptScanner.scan([folder.record])
        let launch = try #require(scan.commands.first?.launch)
        #expect(Array(launch.dropLast()) == ["/usr/bin/env", "bash", "-e"])
        #expect(URL(fileURLWithPath: launch.last ?? "").resolvingSymlinksInPath() == plain.resolvingSymlinksInPath())
        #expect(scan.issues.first?.problems.first?.contains("chmod +x") == true)
    }

    @Test("Disabled folders are skipped and missing ones reported")
    func folderStates() throws {
        let folder = try ScriptFolder()
        try folder.script("one.sh", title: "One", body: "echo 1")
        var disabled = folder.record
        disabled.isEnabled = false
        #expect(ScriptScanner.scan([disabled]).commands.isEmpty)
        let missing = ScriptDirectoryRecord(path: folder.url.appending(path: "nope").path)
        #expect(ScriptScanner.scan([missing]).unreadable[missing.id] != nil)
    }

    @Test("The catalog rescans when its folders change and tells the launcher")
    func catalogChanges() throws {
        let folder = try ScriptFolder()
        try folder.script("one.sh", title: "One", body: "echo 1")
        let catalog = ScriptCatalog()
        var changes = 0
        catalog.didChange = { changes += 1 }
        let record = folder.record
        catalog.setDirectories([record], approvals: [record.id: try #require(folder.identity)], synchronously: true)
        #expect(catalog.commands.map(\.title) == ["One"])
        #expect(changes == 1)
        try folder.script("two.sh", title: "Two", body: "echo 2")
        catalog.reloadNow()
        #expect(catalog.commands.map(\.title) == ["One", "Two"])
        #expect(changes == 2)
        catalog.reloadNow()
        #expect(changes == 2)
    }

    @Test("Script folders round-trip in the library, and older records still load")
    func directoryRecords() throws {
        let record = ScriptDirectoryRecord(path: "/Users/x/Scripts", isEnabled: false, addedAt: Date(timeIntervalSince1970: 10))
        let decoded = try JSONDecoder().decode(ScriptDirectoryRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        let old = try JSONDecoder().decode(
            ScriptDirectoryRecord.self, from: Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8))
        #expect(old.path.isEmpty)
        #expect(old.isEnabled)
        #expect(old.url == nil)
    }

    @Test("New scripts from the template parse back, are executable and never overwrite")
    func templates() throws {
        let folder = try ScriptFolder()
        var draft = ScriptTemplate.Draft()
        draft.title = "Say Hello"
        draft.mode = .inline
        draft.refreshTime = "30s"
        draft.packageName = "Greetings"
        draft.icon = "👋"
        draft.argumentPlaceholder = "Name"
        for language in ScriptTemplate.Language.allCases {
            draft.language = language
            let text = ScriptTemplate.render(draft)
            let metadata = try parse(text)
            #expect(metadata.title == "Say Hello")
            #expect(metadata.mode == .inline)
            #expect(metadata.refreshTime == .seconds(30))
            #expect(metadata.icon == .emoji("👋"))
            #expect(metadata.arguments.first?.placeholder == "Name")
            #expect(!text.contains("@raycast."))
        }
        draft.language = .bash
        let first = try ScriptTemplate.create(draft, in: folder.url)
        let second = try ScriptTemplate.create(draft, in: folder.url)
        #expect(first.lastPathComponent == "say-hello.sh")
        #expect(second.lastPathComponent == "say-hello-2.sh")
        #expect(FileManager.default.isExecutableFile(atPath: first.path))
        #expect(ScriptScanner.scan([folder.record]).commands.count == 2)
        draft.title = "  "
        #expect(throws: (any Error).self) { try ScriptTemplate.create(draft, in: folder.url) }
    }
}

// MARK: - Running

@Suite("Running scripts")
struct ScriptRunnerTests {
    func invocation(_ url: URL, _ arguments: [String] = [], timeout: Duration = .seconds(10), in folder: URL? = nil)
        -> ScriptInvocation
    {
        let home = url.deletingLastPathComponent().path
        return ScriptInvocation(
            scriptURL: url, argv: [url.path] + arguments, workingDirectory: folder ?? url.deletingLastPathComponent(),
            environment: ScriptEnvironment.make(base: ["PATH": "/usr/bin:/bin", "HOME": home]), timeout: timeout)
    }

    @Test("Output, arguments, working directory and PATH")
    func basics() async throws {
        let folder = try ScriptFolder()
        let script = try folder.write(
            "basics.sh", "#!/bin/bash\necho \"args:$1|$2\"\npwd\necho \"$PATH\"\necho oops >&2\n")
        let launcher = POSIXScriptLauncher(allowedRoots: [folder.url])
        let result = await launcher.run(invocation(script, ["one", "two words"])) { _ in }
        #expect(result.termination == .exited(0))
        let lines = try #require(result.standardOutput).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "args:one|two words")
        #expect(URL(fileURLWithPath: lines[1]).resolvingSymlinksInPath() == folder.url.resolvingSymlinksInPath())
        #expect(lines[2].split(separator: ":").contains("/usr/local/bin"))
        #expect(lines[2].split(separator: ":").contains("/opt/homebrew/bin"))
        // Standard error is in the full output, never in standard output.
        #expect(result.output.contains("oops"))
        #expect(result.lastLine == lines[2])
    }

    @Test("A non-zero exit is a failure whose message is the last line")
    func failure() async throws {
        let folder = try ScriptFolder()
        let script = try folder.write("fail.sh", "#!/bin/bash\necho working\necho 'Invalid value provided'\nexit 3\n")
        let result = await POSIXScriptLauncher(allowedRoots: [folder.url]).run(invocation(script)) { _ in }
        #expect(result.termination == .exited(3))
        #expect(!result.succeeded)
        #expect(result.failureMessage(title: "Fail") == "Invalid value provided")
    }

    @Test("A timeout stops the script and everything it started")
    func timeout() async throws {
        let folder = try ScriptFolder()
        let script = try folder.write("slow.sh", "#!/bin/bash\n/bin/sleep 30 &\necho \"child $!\"\nwait\n")
        var launcher = POSIXScriptLauncher(allowedRoots: [folder.url])
        launcher.killGrace = .milliseconds(200)
        launcher.drainGrace = .milliseconds(200)
        let start = ContinuousClock.now
        let result = await launcher.run(invocation(script, timeout: .milliseconds(400))) { _ in }
        #expect(result.termination == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(5))
        // Standard output says "child <pid>"; standard error may add the shell's own report.
        let line = try #require(result.standardOutput?.split(separator: "\n").first { $0.hasPrefix("child ") })
        let pid = try #require(pid_t(line.dropFirst("child ".count).trimmingCharacters(in: .whitespaces)))
        var gone = false
        for _ in 0..<30 {
            if kill(pid, 0) == -1 {
                gone = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(gone, "The script's child process should be stopped with it")
    }

    @Test("Cancelling the task stops the script")
    func cancel() async throws {
        let folder = try ScriptFolder()
        let script = try folder.write("wait.sh", "#!/bin/bash\necho ready\n/bin/sleep 30\n")
        var launcher = POSIXScriptLauncher(allowedRoots: [folder.url])
        launcher.killGrace = .milliseconds(200)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let run = Task { await launcher.run(invocation(script)) { continuation.yield($0) } }
        for await text in stream where text.contains("ready") { break }
        run.cancel()
        let result = await run.value
        #expect(result.termination == .cancelled)
        #expect(result.output.contains("ready"))
        #expect(result.duration < .seconds(5))
    }

    @Test("Output streams before the script ends")
    func streaming() async throws {
        let folder = try ScriptFolder()
        let script = try folder.write("stream.sh", "#!/bin/bash\necho first\n/bin/sleep 0.3\necho second\n")
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let run = Task {
            await POSIXScriptLauncher(allowedRoots: [folder.url]).run(invocation(script)) { continuation.yield($0) }
        }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.contains("first") == true)
        #expect(first?.contains("second") == false)
        let result = await run.value
        #expect(result.output == "first\nsecond\n")
    }

    @Test("While OpenRay is inert, scripts outside the allowed folders never run")
    func guarded() async throws {
        let folder = try ScriptFolder()
        let marker = folder.url.appending(path: "ran")
        let script = try folder.write("touch.sh", "#!/bin/bash\necho > \"\(marker.path)\"\n")
        let result = await POSIXScriptLauncher(sideEffects: SideEffectGuard(mode: .testHost))
            .run(invocation(script)) { _ in }
        guard case .failedToLaunch(let reason) = result.termination else {
            Issue.record("Expected a refusal, got \(result.termination)")
            return
        }
        #expect(reason.contains("tests"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("A missing interpreter explains itself")
    func missingInterpreter() async throws {
        let folder = try ScriptFolder()
        let script = try folder.write("ghost.sh", "#!/no/such/interpreter\necho hi\n")
        let result = await POSIXScriptLauncher(allowedRoots: [folder.url]).run(invocation(script)) { _ in }
        #expect(result.termination == .failedToLaunch("Its #! interpreter wasn't found."))
    }

    @Test("The environment adds Homebrew and /usr/local to PATH once, and a UTF-8 locale")
    func environment() {
        let environment = ScriptEnvironment.make(base: ["PATH": "/usr/bin:/usr/local/bin", "HOME": "/Users/x"])
        let paths = environment["PATH"]!.split(separator: ":").map(String.init)
        #expect(paths.first == "/usr/bin")
        #expect(paths.filter { $0 == "/usr/local/bin" }.count == 1)
        #expect(paths.contains("/opt/homebrew/bin"))
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["HOME"] == "/Users/x")
        #expect(ScriptEnvironment.make(base: ["LC_ALL": "C"])["LANG"] == nil)
    }
}

// MARK: - Inline refresh

@Suite("Inline refresh")
struct ScriptInlineScheduleTests {
    func inline(_ index: Int, refresh: String = "10s", argument: String? = nil) throws -> ScriptCommand {
        var text = "# @raycast.schemaVersion 1\n# @raycast.title Inline \(index)\n# @raycast.mode inline\n# @raycast.refreshTime \(refresh)\n"
        if let argument { text += "# @raycast.argument1 \(argument)\n" }
        return try command(text, path: "/tmp/inline-\(index).sh")
    }

    @Test("Only the first ten inline scripts refresh on their own")
    func firstTen() throws {
        let commands = try (1...12).map { try inline($0) }
        let auto = ScriptInlineSchedule.autoRefreshing(commands)
        #expect(auto.count == 10)
        #expect(auto.map(\.title) == commands.prefix(10).map(\.title))
    }

    @Test("A required argument keeps a script from refreshing by itself")
    func requiredArgument() throws {
        let needsValue = try inline(1, argument: #"{ "type": "text", "placeholder": "x" }"#)
        let optional = try inline(2, argument: #"{ "type": "text", "placeholder": "x", "optional": true }"#)
        #expect(ScriptInlineSchedule.autoRefreshing([needsValue, optional]).map(\.title) == ["Inline 2"])
    }

    @Test("A script is due once its interval passes, never under ten seconds, and never while running")
    func due() throws {
        let fast = try inline(1, refresh: "3s")
        let minute = try inline(2, refresh: "1m")
        #expect(ScriptInlineSchedule.interval(for: fast) == .seconds(10))
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ScriptInlineSchedule.due([fast, minute], lastRun: [:], running: [], now: now).count == 2)
        let lastRun = [fast.id: now.addingTimeInterval(-9), minute.id: now.addingTimeInterval(-59)]
        #expect(ScriptInlineSchedule.due([fast, minute], lastRun: lastRun, running: [], now: now).isEmpty)
        let later = now.addingTimeInterval(1)
        #expect(ScriptInlineSchedule.due([fast, minute], lastRun: lastRun, running: [], now: later).map(\.title) == ["Inline 1", "Inline 2"])
        #expect(ScriptInlineSchedule.due([fast, minute], lastRun: lastRun, running: [fast.id], now: later).map(\.title) == ["Inline 2"])
        #expect(ScriptInlineSchedule.nextDue([fast, minute], lastRun: lastRun, now: now) == now.addingTimeInterval(1))
    }
}

// MARK: - Output modes in the launcher

@Suite("Script commands in the launcher")
@MainActor
struct ScriptCommandLauncherTests {
    struct Harness {
        let folder: ScriptFolder
        let model: LauncherModel
        let provider: ScriptCommandProvider
        let presenter: RecordingScriptPresenter
    }

    func harness(launcher: (any ScriptProcessLaunching)? = nil) throws -> Harness {
        let folder = try ScriptFolder()
        let presenter = RecordingScriptPresenter()
        let provider = ScriptCommandProvider(
            catalog: ScriptCatalog(),
            runner: ScriptRunner(
                launcher: launcher ?? POSIXScriptLauncher(allowedRoots: [folder.url]), environment: folder.environment),
            presenter: presenter, refreshesAutomatically: false)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), registry: CommandRegistry(providers: [provider]))
        return Harness(folder: folder, model: model, provider: provider, presenter: presenter)
    }

    /// Lists the fixture folder and allows it on "this Mac", as Add Script Folder does.
    @discardableResult
    func load(_ harness: Harness) -> ScriptDirectoryRecord {
        let record = harness.folder.record
        harness.model.store.update { $0.scriptDirectories = [record] }
        LocalApprovalStore.for(harness.model.store).approve(record)
        harness.provider.synchronize(with: harness.model, synchronously: true)
        return record
    }

    func row(_ title: String, in harness: Harness) throws -> LauncherItem {
        try #require(harness.model.commandItems.first { $0.title == title })
    }

    func finish(_ harness: Harness, _ title: String) async throws {
        let script = try #require(harness.provider.catalog.commands.first { $0.title == title })
        let job = try #require(harness.provider.runner.latestJob(for: script.id))
        await job.task?.value
    }

    @Test("Scripts become bindable commands with their arguments and a stable id")
    func commands() throws {
        let h = try harness()
        try h.folder.script(
            "greet.sh", title: "Greet", extra: [#"argument1 { "type": "text", "placeholder": "Name" }"#, "packageName Hello"],
            body: "echo hi")
        load(h)
        let item = try row("Greet", in: h)
        #expect(item.subtitle == "Hello")
        #expect(item.isBuiltInCommand)
        #expect(item.id.hasPrefix("script."))
        #expect(ScriptCommandProvider.registration.acceptsBinding(item.id))
        guard case .provided(let ref) = item.action else {
            Issue.record("Not a provided row")
            return
        }
        #expect(h.model.registry.descriptor(for: ref, in: h.model)?.arguments.map(\.name) == ["argument1"])
        #expect(h.model.commandItems.contains { $0.id == ScriptCommandProvider.browseID })
    }

    @Test("Compact: the last line in a toast; a failure in an error toast")
    func compact() async throws {
        let h = try harness()
        try h.folder.script("ok.sh", title: "OK", body: "echo one\necho 'all done'")
        try h.folder.script("bad.sh", title: "Bad", body: "echo 'Invalid value provided'\nexit 1")
        load(h)
        h.model.perform(try row("OK", in: h))
        #expect(h.model.feedback?.style == .working)
        try await finish(h, "OK")
        #expect(h.model.feedback?.style == .success)
        #expect(h.model.feedback?.text == "all done")
        h.model.perform(try row("Bad", in: h))
        try await finish(h, "Bad")
        #expect(h.model.feedback?.style == .error)
        #expect(h.model.feedback?.text == "Invalid value provided")
    }

    @Test("Silent: the last line goes to the HUD; failures too, marked as errors")
    func silent() async throws {
        let h = try harness()
        try h.folder.script("quiet.sh", title: "Quiet", mode: "silent", body: "echo 'Session started'")
        try h.folder.script("loud.sh", title: "Loud", mode: "silent", body: "echo 'No session'\nexit 2")
        try h.folder.script("mute.sh", title: "Mute", mode: "silent", body: "true")
        load(h)
        h.model.perform(try row("Quiet", in: h))
        try await finish(h, "Quiet")
        h.model.perform(try row("Loud", in: h))
        try await finish(h, "Loud")
        h.model.perform(try row("Mute", in: h))
        try await finish(h, "Mute")
        #expect(h.presenter.messages.map(\.text) == ["Session started", "No session"])
        #expect(h.presenter.messages.map(\.isError) == [false, true])
    }

    @Test("Full output: a detail view with ANSI output, its own row and actions")
    func fullOutput() async throws {
        let h = try harness()
        try h.folder.script("report.sh", title: "Report", mode: "fullOutput", body: #"printf '\033[31mred\033[0m\nplain\n'"#)
        load(h)
        h.model.perform(try row("Report", in: h))
        #expect(h.model.section.providedScope?.id == ScriptCommandProvider.outputScope.id)
        #expect(h.model.section.title == "Report")
        try await finish(h, "Report")
        let detail = try #require(h.model.providedDetail)
        #expect(detail.body == .ansi("\u{1B}[31mred\u{1B}[0m\nplain\n"))
        guard case .succeeded? = detail.status else {
            Issue.record("Expected success, got \(String(describing: detail.status))")
            return
        }
        let output = try #require(h.model.results.first)
        #expect(output.copyText == "red\nplain\n")
        #expect(h.model.primaryTitle(for: output) == "Copy Output")
        let actions = h.model.actions(for: output).map(\.id)
        #expect(actions.contains("script.runAgain"))
        #expect(actions.contains("script.copyLastLine"))
        // Esc leaves the output for search.
        h.model.goBack()
        #expect(h.model.section == .home)
        #expect(h.model.providedDetail == nil)
    }

    @Test("Inline: the first line becomes the row's subtitle; a failure shows in the row")
    func inline() async throws {
        let h = try harness()
        try h.folder.script("cpu.sh", title: "CPU", mode: "inline", extra: ["refreshTime 10s"], body: "echo 'CPU 3%'\necho second")
        try h.folder.script("down.sh", title: "Down", mode: "inline", extra: ["refreshTime 10s"], body: "echo 'host down'\nexit 1")
        load(h)
        #expect(try row("CPU", in: h).subtitle == h.folder.url.lastPathComponent)
        h.provider.refreshDueInlineScripts(in: h.model)
        try await finish(h, "CPU")
        try await finish(h, "Down")
        #expect(try row("CPU", in: h).subtitle == "CPU 3%")
        #expect(try row("Down", in: h).subtitle == "Failed: host down")
        // Background refreshes don't raise toasts.
        #expect(h.model.feedback == nil)
        // Not due again until ten seconds have passed.
        h.provider.refreshDueInlineScripts(in: h.model)
        #expect(h.provider.runner.runningJobs.isEmpty)
        guard case .provided(let ref) = try row("CPU", in: h).action else { return }
        #expect(h.model.registry.descriptor(for: ref, in: h.model)?.mode == .inline(refresh: .seconds(10)))
    }

    @Test("Arguments arrive as $1–$3, percent-encoded when asked; required ones must be given")
    func arguments() async throws {
        let h = try harness()
        try h.folder.script(
            "args.sh", title: "Args",
            extra: [
                #"argument1 { "type": "text", "placeholder": "Query", "percentEncoded": true }"#,
                #"argument2 { "type": "text", "placeholder": "Extra", "optional": true }"#,
            ],
            body: "echo \"[$1][$2]\"")
        load(h)
        var item = try row("Args", in: h)
        h.model.perform(item)
        #expect(h.model.feedback?.style == .warning)
        #expect(h.provider.runner.jobs.isEmpty)
        guard case .provided(var ref) = item.action else { return }
        ref.arguments = ["argument1": "a b&c"]
        item.action = .provided(ref)
        h.model.perform(item)
        try await finish(h, "Args")
        #expect(h.model.feedback?.text == "[a%20b%26c][]")
    }

    @Test("needsConfirmation asks first, and runs only once approved")
    func confirmation() async throws {
        let h = try harness()
        try h.folder.script("danger.sh", title: "Danger", extra: ["needsConfirmation true"], body: "echo boom")
        load(h)
        h.model.perform(try row("Danger", in: h))
        let question = try #require(h.model.confirmation)
        #expect(question.question == "Run “Danger”?")
        #expect(h.provider.runner.jobs.isEmpty)
        h.model.confirm(question)
        try await finish(h, "Danger")
        #expect(h.model.feedback?.text == "boom")
    }

    @Test("Fallback scripts get the query as their first argument")
    func fallbacks() async throws {
        let h = try harness()
        try h.folder.script(
            "search.sh", title: "Search Docs", extra: [#"argument1 { "type": "text", "placeholder": "Query" }"#],
            body: "echo \"searching $1\"")
        load(h)
        let script = try #require(h.provider.catalog.commands.first)
        #expect(h.provider.fallbackItems(for: "swift", in: h.model).isEmpty)
        #expect(h.provider.setFallback(true, for: script.id, in: h.model))
        let fallback = try #require(h.model.registry.fallbackItems(for: "swift", in: h.model).first)
        #expect(fallback.id == "fallback.\(script.id)")
        #expect(!fallback.canFavorite)
        h.model.perform(fallback)
        try await finish(h, "Search Docs")
        #expect(h.model.feedback?.text == "searching swift")
        h.provider.setFallback(false, for: script.id, in: h.model)
        #expect(h.model.store.database.commandPreferences[script.id] == nil)
    }

    @Test("A timeout preference overrides the mode's default")
    func timeoutPreference() throws {
        let h = try harness()
        try h.folder.script("t.sh", title: "T", body: "echo")
        load(h)
        let script = try #require(h.provider.catalog.commands.first)
        #expect(h.provider.timeout(for: script, in: h.model) == .seconds(120))
        h.model.store.update { $0.commandPreferences[script.id] = [ScriptCommandProvider.timeoutKey: "5"] }
        #expect(h.provider.timeout(for: script, in: h.model) == .seconds(5))
        #expect(ScriptRunner.defaultTimeout(for: .fullOutput) == .seconds(600))
        #expect(ScriptRunner.defaultTimeout(for: .inline) == .seconds(30))
    }

    @Test("A running script shows as running and can be stopped from ⌘K")
    func runningRow() async throws {
        let h = try harness()
        try h.folder.script("long.sh", title: "Long", body: "echo started\n/bin/sleep 30")
        load(h)
        h.model.perform(try row("Long", in: h))
        let running = try row("Long", in: h)
        #expect(running.badge == "Running")
        let stop = try #require(h.model.actions(for: running).first { $0.id == "script.stop" })
        #expect(stop.shortcut == KeyShortcut(["⌃", "C"]))
        // Asking again doesn't start a second copy.
        h.model.perform(running)
        #expect(h.provider.runner.jobs.count == 1)
        stop.perform()
        try await finish(h, "Long")
        #expect(h.model.feedback?.style == .error)
        #expect(h.model.feedback?.text.contains("was stopped") == true)
        #expect(try row("Long", in: h).badge == "Script")
    }

    @Test("Copy Output copies the text without escape codes")
    func plainOutput() throws {
        let job = ScriptJob(command: try command("# @raycast.schemaVersion 1\n# @raycast.title J\n# @raycast.mode fullOutput\n"), arguments: [], values: [:])
        job.append("\u{1B}[1mbold\u{1B}[0m\n")
        #expect(job.plainOutput == "bold\n")
        job.append("more\n")
        #expect(job.plainOutput == "bold\nmore\n")
    }

    @Test("Canned results work without any process, for the provider's own logic")
    func canned() async throws {
        let h = try harness(
            launcher: CannedScriptLauncher(execution: ScriptExecution(termination: .exited(0), output: "canned\n", duration: .zero)))
        try h.folder.script("c.sh", title: "Canned", body: "exit 9")
        load(h)
        h.model.perform(try row("Canned", in: h))
        try await finish(h, "Canned")
        #expect(h.model.feedback?.text == "canned")
    }
}

// MARK: - Authorization (review fixes)

extension ScriptCommandLauncherTests {
    @Test("A folder's scripts run only once it's allowed on this Mac, and again only after a change")
    func folderApproval() throws {
        let h = try harness()
        try h.folder.script("one.sh", title: "One", body: "echo 1")
        let record = h.folder.record
        h.model.store.update { $0.scriptDirectories = [record] }
        h.provider.synchronize(with: h.model, synchronously: true)
        // Listed and on, as an import would leave it, but never allowed here.
        #expect(h.provider.catalog.commands.isEmpty)
        #expect(h.provider.catalog.scan.unapproved == [record.id])
        #expect(!h.provider.isActive(record, in: h.model))

        #expect(h.provider.setDirectory(record.id, enabled: true, in: h.model))
        h.provider.catalog.reloadNow()
        #expect(h.provider.catalog.commands.map(\.title) == ["One"])

        // The folder is replaced by another at the same path: it needs allowing again.
        let aside = h.folder.url.deletingLastPathComponent().appending(path: "aside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: aside) }
        try FileManager.default.moveItem(at: h.folder.url, to: aside)
        try FileManager.default.createDirectory(at: h.folder.url, withIntermediateDirectories: true)
        try h.folder.script("one.sh", title: "One", body: "echo 1")
        h.provider.catalog.reloadNow()
        #expect(h.provider.catalog.commands.isEmpty)
        #expect(!h.provider.isActive(record, in: h.model))

        // Allowed again, then pointed elsewhere through a link: refused again.
        #expect(h.provider.setDirectory(record.id, enabled: true, in: h.model))
        h.provider.catalog.reloadNow()
        #expect(h.provider.catalog.commands.count == 1)
        try FileManager.default.removeItem(at: h.folder.url)
        try FileManager.default.createSymbolicLink(at: h.folder.url, withDestinationURL: aside)
        h.provider.catalog.reloadNow()
        #expect(h.provider.catalog.commands.isEmpty)

        // Turning it off forgets the approval.
        #expect(h.provider.setDirectory(record.id, enabled: false, in: h.model))
        #expect(LocalApprovalStore.for(h.model.store).approvals.scriptFolders[record.id] == nil)
    }

    @Test("Inline scripts that ask first, or whose command is off, never refresh on their own")
    func inlineAuthorization() async throws {
        let h = try harness()
        try h.folder.script("ask.sh", title: "Ask", mode: "inline", extra: ["refreshTime 10s", "needsConfirmation true"], body: "echo a")
        try h.folder.script("off.sh", title: "Off", mode: "inline", extra: ["refreshTime 10s"], body: "echo o")
        try h.folder.script("on.sh", title: "On", mode: "inline", extra: ["refreshTime 10s"], body: "echo on")
        load(h)
        let off = try #require(h.provider.catalog.commands.first { $0.title == "Off" })
        h.model.store.update { $0.disabledCommandIDs.insert(off.id) }
        h.provider.refreshDueInlineScripts(in: h.model)
        #expect(h.provider.runner.jobs.map(\.command.title) == ["On"])
        try await finish(h, "On")
        // ↩ on the one that asks still asks.
        h.model.perform(try row("Ask", in: h))
        #expect(h.model.confirmation != nil)
        #expect(h.provider.runner.jobs.count == 1)
    }

    @Test("Run Again goes through the command's current checks")
    func runAgainChecks() async throws {
        let h = try harness()
        try h.folder.script("ask.sh", title: "Ask", mode: "fullOutput", extra: ["needsConfirmation true"], body: "echo asked")
        let record = load(h)
        h.model.perform(try row("Ask", in: h))
        h.model.confirm(try #require(h.model.confirmation))
        try await finish(h, "Ask")
        let job = try #require(h.provider.runner.jobs.first)
        let again = try #require(h.model.actions(for: try #require(h.model.results.first)).first { $0.id == "script.runAgain" })
        again.perform()
        #expect(h.model.confirmation != nil, "The confirmation is asked again")
        #expect(h.provider.runner.jobs.count == 1)
        h.model.confirmation = nil

        h.model.store.update { $0.disabledCommandIDs.insert(job.command.id) }
        h.provider.runAgain(job, in: h.model)
        #expect(h.provider.runner.jobs.count == 1)
        h.model.store.update { $0.disabledCommandIDs = [] }

        h.provider.setDirectory(record.id, enabled: false, in: h.model)
        h.provider.catalog.reloadNow()
        h.provider.runAgain(job, in: h.model)
        #expect(h.model.feedback?.text.contains("no longer available") == true)
        #expect(h.provider.runner.jobs.count == 1)
    }

    @Test("Results come from standard output; diagnostics stay in the full output and failures")
    func standardOutputSummaries() async throws {
        let h = try harness()
        try h.folder.script("warn.sh", title: "Warn", body: "echo result\necho 'warning: slow disk' >&2")
        try h.folder.script("log.sh", title: "Log", body: "echo 'logged only' >&2")
        try h.folder.script("bad.sh", title: "Bad", body: "echo partial\necho 'error: bad input' >&2\nexit 1")
        load(h)
        h.model.perform(try row("Warn", in: h))
        try await finish(h, "Warn")
        #expect(h.model.feedback?.text == "result")
        h.model.perform(try row("Log", in: h))
        try await finish(h, "Log")
        #expect(h.model.feedback?.text == "logged only")
        h.model.perform(try row("Bad", in: h))
        try await finish(h, "Bad")
        #expect(h.model.feedback?.style == .error)
        #expect(h.model.feedback?.text == "error: bad input")
    }

    @Test("Arguments containing NUL never reach the script")
    func nulArguments() async throws {
        let h = try harness()
        try h.folder.script(
            "args.sh", title: "Args", extra: [#"argument1 { "type": "text", "placeholder": "Value" }"#], body: "echo \"$1\"")
        load(h)
        let script = try #require(h.provider.catalog.commands.first)
        #expect(h.provider.run(script, values: ["argument1": "a\u{0}b"], in: h.model) == nil)
        #expect(h.model.feedback?.style == .error)
        #expect(h.provider.runner.jobs.isEmpty)
        let result = await POSIXScriptLauncher(allowedRoots: [h.folder.url]).run(
            h.provider.runner.invocation(for: script, arguments: ["a\u{0}b"], timeout: .seconds(5))) { _ in }
        #expect(result.termination == .failedToLaunch("An argument contains a NUL character."))
    }
}

extension ScriptRunnerTests {
    @Test("While inert, only the script itself or a system interpreter runs, in an allowed folder")
    func inertLaunchRules() throws {
        let folder = try ScriptFolder()
        let script = try folder.write("ok.sh", "#!/bin/bash\necho ok\n")
        let launcher = POSIXScriptLauncher(allowedRoots: [folder.url])
        var allowed = invocation(script)
        try launcher.checkAllowed(allowed)
        allowed.argv = ["/bin/bash", script.path]
        try launcher.checkAllowed(allowed)
        var otherProgram = invocation(script)
        otherProgram.argv = ["/usr/local/bin/python3", script.path]
        #expect(throws: SideEffectGuard.Blocked.self) { try launcher.checkAllowed(otherProgram) }
        var otherFolder = invocation(script)
        otherFolder.workingDirectory = FileManager.default.homeDirectoryForCurrentUser
        #expect(throws: SideEffectGuard.Blocked.self) { try launcher.checkAllowed(otherFolder) }
        // An injected live rule can't make the test host run anything outside the fixtures.
        let live = POSIXScriptLauncher(sideEffects: SideEffectGuard(mode: .live), allowedRoots: [])
        #expect(throws: SideEffectGuard.Blocked.self) { try live.checkAllowed(invocation(script)) }
    }
}
