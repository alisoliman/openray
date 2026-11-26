import Darwin
import Foundation
import Observation

// Running script commands. The live launcher spawns the script in its own process group, so a
// timeout or Cancel stops everything it started, not just the script's first process.

/// One run of a script: the program, its arguments and its surroundings.
struct ScriptInvocation: Hashable, Sendable {
    /// The script file. The side-effect guard checks this path.
    var scriptURL: URL
    /// The program and its leading arguments (`ScriptCommand.launch`), then `$1`–`$3`.
    var argv: [String]
    var workingDirectory: URL
    var environment: [String: String]
    var timeout: Duration
    /// The most output kept, in bytes. Older output is dropped first, so the last line survives.
    var outputLimit = ScriptRunner.outputLimit
}

/// How a run ended.
enum ScriptTermination: Hashable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    case cancelled
    case failedToLaunch(String)
}

/// What a finished run printed and how it ended.
struct ScriptExecution: Hashable, Sendable {
    var termination: ScriptTermination
    /// Standard output and standard error, interleaved as they were read. Full Output shows this.
    var output: String
    /// Standard output alone. Nil when it wasn't kept apart (canned results), which reads `output`.
    var standardOutput: String? = nil
    var duration: Duration
    /// True when older output was dropped to stay within the limit.
    var isTruncated = false

    var succeeded: Bool { termination == .exited(0) }

    static func lines(_ text: String) -> [String] {
        ANSIText.strip(text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Every line, both streams, with ANSI codes removed and blank lines dropped.
    var plainLines: [String] { Self.lines(output) }

    /// The lines a result is read from: standard output's, so a warning on standard error never
    /// stands in for the answer. A script that printed only to standard error (AppleScript's
    /// `log` does) is read from everything.
    var resultLines: [String] {
        let standard = standardOutput.map(Self.lines) ?? []
        return standard.isEmpty ? plainLines : standard
    }

    var firstLine: String? { resultLines.first }
    var lastLine: String? { resultLines.last }

    /// A sentence for a failure toast: the last line of everything printed, which includes the
    /// diagnostics on standard error, else how it ended.
    func failureMessage(title: String) -> String {
        switch termination {
        case .timedOut: return "“\(title.truncatedForFeedback)” took too long and was stopped."
        case .cancelled: return "“\(title.truncatedForFeedback)” was stopped."
        case .failedToLaunch(let reason): return "“\(title.truncatedForFeedback)” couldn't run. \(reason)"
        case .signaled(let signal): return plainLines.last ?? "“\(title.truncatedForFeedback)” ended with signal \(signal)."
        case .exited(let code): return plainLines.last ?? "“\(title.truncatedForFeedback)” failed with exit code \(code)."
        }
    }
}

/// Starts script processes. The live one is `POSIXScriptLauncher`; tests may use it only on
/// fixture scripts they write into a temporary folder.
protocol ScriptProcessLaunching: Sendable {
    /// Runs to completion. `onOutput` gets text as it arrives, on a background thread. Cancelling
    /// the calling task stops the process; the result then says `.cancelled`.
    func run(_ invocation: ScriptInvocation, onOutput: @escaping @Sendable (String) -> Void) async -> ScriptExecution
}

/// The environment scripts run in: OpenRay's own, as a non-login shell would see it, with
/// `/usr/local/bin` and `/opt/homebrew/bin` added to PATH and a UTF-8 locale when none is set.
enum ScriptEnvironment {
    static let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin"]
    static let systemPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func make(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        var paths = (base["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for path in systemPaths + extraPaths where !paths.contains(path) { paths.append(path) }
        environment["PATH"] = paths.joined(separator: ":")
        if environment["LANG"] == nil, environment["LC_ALL"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }
}

/// Spawns scripts with `posix_spawn` in a new process group, standard input from /dev/null and
/// one pipe each for standard output and standard error. A timeout or cancel sends SIGTERM to the
/// group, then SIGKILL a second later. While OpenRay is inert (tests, verification), it refuses
/// every script outside `allowedRoots`, any program other than the script itself or a system
/// interpreter, and any working directory outside `allowedRoots`.
struct POSIXScriptLauncher: ScriptProcessLaunching {
    var sideEffects: SideEffectGuard = .current
    /// Folders whose scripts may run while inert: tests pass the temporary folder they wrote.
    var allowedRoots: [URL] = []
    /// How long to keep reading after the script exits, for output its children still write.
    var drainGrace: Duration = .seconds(1)
    var killGrace: Duration = .seconds(1)

    /// Where interpreters may live while inert.
    static let systemInterpreterFolders = ["/bin/", "/usr/bin/"]

    func run(_ invocation: ScriptInvocation, onOutput: @escaping @Sendable (String) -> Void) async -> ScriptExecution {
        let start = ContinuousClock.now
        func failure(_ reason: String) -> ScriptExecution {
            ScriptExecution(termination: .failedToLaunch(reason), output: "", duration: ContinuousClock.now - start)
        }
        do { try checkAllowed(invocation) } catch { return failure(error.localizedDescription) }
        guard !Task.isCancelled else {
            return ScriptExecution(termination: .cancelled, output: "", duration: ContinuousClock.now - start)
        }
        guard let program = invocation.argv.first else { return failure("There's nothing to run.") }
        // C strings end at NUL, so a value containing one would reach the script cut short.
        guard !invocation.argv.contains(where: { $0.contains("\0") }) else {
            return failure("An argument contains a NUL character.")
        }

        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { return failure(String(cString: strerror(errno))) }
        guard pipe(&errorPipe) == 0 else {
            close(outputPipe[0])
            close(outputPipe[1])
            return failure(String(cString: strerror(errno)))
        }
        _ = fcntl(outputPipe[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(errorPipe[0], F_SETFD, FD_CLOEXEC)

        var pid: pid_t = 0
        let spawnError = Self.spawn(
            program: program, argv: invocation.argv, environment: invocation.environment,
            workingDirectory: invocation.workingDirectory.path, output: outputPipe[1], error: errorPipe[1], pid: &pid)
        close(outputPipe[1])
        close(errorPipe[1])
        if spawnError != 0 {
            close(outputPipe[0])
            close(errorPipe[0])
            return failure(Self.launchFailure(spawnError, program: program))
        }

        let process = SpawnedScript(
            pid: pid, outputFD: outputPipe[0], errorFD: errorPipe[0], limit: invocation.outputLimit, onOutput: onOutput)
        let killGrace = killGrace
        let drainGrace = drainGrace
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ScriptExecution, Never>) in
                process.start(timeout: invocation.timeout, killGrace: killGrace, drainGrace: drainGrace) { result in
                    continuation.resume(
                        returning: ScriptExecution(
                            termination: result.termination, output: result.output, standardOutput: result.standardOutput,
                            duration: ContinuousClock.now - start, isTruncated: result.truncated))
                }
            }
        } onCancel: {
            process.terminate(.cancelled, killGrace: killGrace)
        }
    }

    func checkAllowed(_ invocation: ScriptInvocation) throws {
        guard sideEffects.effective.isInert else { return }
        func resolved(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        func isInsideRoots(_ path: String) -> Bool {
            allowedRoots.contains { root in
                let root = resolved(root)
                return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        }
        let script = resolved(invocation.scriptURL)
        let program = invocation.argv.first.map { resolved(URL(fileURLWithPath: $0)) } ?? ""
        let programIsAllowed =
            program == script || Self.systemInterpreterFolders.contains { program.hasPrefix($0) }
        guard isInsideRoots(script), programIsAllowed, isInsideRoots(resolved(invocation.workingDirectory)) else {
            try sideEffects.check("running script commands")
            return
        }
    }

    private static func launchFailure(_ code: Int32, program: String) -> String {
        switch code {
        case ENOENT where FileManager.default.fileExists(atPath: program):
            "Its #! interpreter wasn't found."
        case ENOENT: "The file wasn't found."
        case ENOEXEC: "Add a #! line naming its interpreter."
        case EACCES: "It isn't executable. Run chmod +x on it."
        default: String(cString: strerror(code))
        }
    }

    /// Returns 0 or an errno.
    private static func spawn(
        program: String, argv: [String], environment: [String: String], workingDirectory: String, output: Int32,
        error: Int32, pid: inout pid_t
    ) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGALRM, SIGCHLD, SIGUSR1, SIGUSR2] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, error, 2)
        posix_spawn_file_actions_addchdir(&actions, workingDirectory)

        let cArguments = argv.map { strdup($0) } + [nil]
        let cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in cArguments { free(pointer) }
            for pointer in cEnvironment { free(pointer) }
        }
        return posix_spawn(&pid, program, &actions, &attributes, cArguments, cEnvironment)
    }
}

/// A spawned script: reads its two pipes, reaps it, and stops it on request. Its state is guarded by a lock.
private final class SpawnedScript: @unchecked Sendable {
    struct Result: Sendable {
        var termination: ScriptTermination
        var output: String
        var standardOutput: String
        var truncated: Bool
    }

    let pid: pid_t
    private let outputFD: Int32
    private let errorFD: Int32
    private let limit: Int
    private let onOutput: @Sendable (String) -> Void
    private let lock = NSLock()
    private var reason: ScriptTermination?
    private var exited = false
    private var stopReading = false
    private var waitStatus: Int32 = 0
    /// Both streams, interleaved in the order they were read.
    private var combined = Data()
    private var standardOutput = Data()
    private var truncated = false
    private var pending: [Int32: Data] = [:]

    init(pid: pid_t, outputFD: Int32, errorFD: Int32, limit: Int, onOutput: @escaping @Sendable (String) -> Void) {
        self.pid = pid
        self.outputFD = outputFD
        self.errorFD = errorFD
        self.limit = max(1_024, limit)
        self.onOutput = onOutput
    }

    func start(
        timeout: Duration, killGrace: Duration, drainGrace: Duration, completion: @escaping @Sendable (Result) -> Void
    ) {
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread { [self] in
            readLoop()
            group.leave()
        }
        group.enter()
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            let finalStatus = status
            lock.withLock {
                exited = true
                waitStatus = finalStatus
            }
            // Children that outlive the script may hold the pipes open; stop reading soon after.
            DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace.timeInterval) { [self] in
                lock.withLock { stopReading = true }
            }
            group.leave()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
            terminate(.timedOut, killGrace: killGrace)
        }
        group.notify(queue: .global()) { [self] in
            close(outputFD)
            close(errorFD)
            let result = lock.withLock { () -> Result in
                let output = String(decoding: combined, as: UTF8.self)
                let standard = String(decoding: standardOutput, as: UTF8.self)
                if let reason { return Result(termination: reason, output: output, standardOutput: standard, truncated: truncated) }
                let code = waitStatus & 0x7F
                return Result(
                    termination: code == 0 ? .exited((waitStatus >> 8) & 0xFF) : .signaled(code), output: output,
                    standardOutput: standard, truncated: truncated)
            }
            completion(result)
        }
    }

    /// Stops the group: SIGTERM now, SIGKILL after the grace period if it's still running. The
    /// first reason wins; a script that already exited is left alone.
    func terminate(_ why: ScriptTermination, killGrace: Duration) {
        let send = lock.withLock { () -> Bool in
            guard !exited, reason == nil else { return false }
            reason = why
            return true
        }
        guard send else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace.timeInterval) { [self] in
            let stillRunning = lock.withLock { !exited }
            if stillRunning { kill(-pid, SIGKILL) }
            // Anything left in the group after the script itself is gone goes too.
            kill(-pid, SIGKILL)
        }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var open: [Int32] = [outputFD, errorFD]
        while !open.isEmpty {
            if lock.withLock({ stopReading }) { break }
            var descriptors = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard ready > 0 else { continue }
            for descriptor in descriptors where descriptor.revents != 0 {
                let count = read(descriptor.fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 {
                    open.removeAll { $0 == descriptor.fd }
                    continue
                }
                append(Data(chunk[0..<count]), from: descriptor.fd)
            }
        }
        for fd in [outputFD, errorFD] { flushPending(fd) }
    }

    private func keepTail(_ buffer: inout Data) {
        guard buffer.count > limit else { return }
        // Keep the tail, starting after a newline when there's one near the cut.
        var cut = buffer.count - limit
        if let newline = buffer[buffer.startIndex + cut..<buffer.endIndex].firstIndex(of: 0x0A),
            newline - buffer.startIndex - cut < 4_096
        {
            cut = newline - buffer.startIndex + 1
        }
        buffer = Data(buffer.dropFirst(cut))
        truncated = true
    }

    private func append(_ data: Data, from fd: Int32) {
        let text = lock.withLock { () -> String in
            combined.append(data)
            keepTail(&combined)
            if fd == outputFD {
                standardOutput.append(data)
                keepTail(&standardOutput)
            }
            var waiting = pending[fd] ?? Data()
            waiting.append(data)
            let (complete, rest) = ANSIText.splitCompleteUTF8(waiting)
            pending[fd] = rest
            return String(decoding: complete, as: UTF8.self)
        }
        if !text.isEmpty { onOutput(text) }
    }

    private func flushPending(_ fd: Int32) {
        let text = lock.withLock { () -> String in
            defer { pending[fd] = Data() }
            return String(decoding: pending[fd] ?? Data(), as: UTF8.self)
        }
        if !text.isEmpty { onOutput(text) }
    }
}

extension Duration {
    /// Seconds, for Dispatch deadlines.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// One run of a script command, observed by its row, the output view and Settings.
@MainActor
@Observable
final class ScriptJob: Identifiable {
    let id = UUID()
    let command: ScriptCommand
    /// The values passed as `$1`–`$3`, already percent-encoded where the header asks.
    let arguments: [String]
    /// The argument values as typed, by name, for Run Again.
    let values: [String: String]
    let startedAt: Date
    private(set) var output = ""
    private(set) var execution: ScriptExecution?
    @ObservationIgnored var task: Task<Void, Never>?

    init(command: ScriptCommand, arguments: [String], values: [String: String], startedAt: Date = .now) {
        self.command = command
        self.arguments = arguments
        self.values = values
        self.startedAt = startedAt
    }

    @ObservationIgnored private var plainCache: (count: Int, text: String)?

    var isRunning: Bool { execution == nil }

    /// The output without ANSI codes, as Copy Output copies it. Cached until the output grows.
    var plainOutput: String {
        let count = output.utf8.count
        if let plainCache, plainCache.count == count { return plainCache.text }
        let text = ANSIText.strip(output)
        plainCache = (count, text)
        return text
    }

    func append(_ text: String, limit: Int = ScriptRunner.outputLimit) {
        guard execution == nil else { return }
        output += text
        if output.utf8.count > limit {
            let excess = output.utf8.count - limit
            let index = output.utf8.index(output.utf8.startIndex, offsetBy: excess)
            output = String(output[index...].drop { $0 != "\n" }.dropFirst())
        }
    }

    func finish(_ execution: ScriptExecution) {
        output = execution.output
        self.execution = execution
    }

    func cancel() { task?.cancel() }
}

/// Starts script commands and keeps their runs: the running ones and the latest of each command.
@MainActor
@Observable
final class ScriptRunner {
    /// Output kept per run.
    nonisolated static let outputLimit = 1_000_000
    /// Finished runs kept for the output view and Run Again.
    nonisolated static let historyLimit = 20

    private(set) var jobs: [ScriptJob] = []
    @ObservationIgnored let launcher: any ScriptProcessLaunching
    @ObservationIgnored private let environment: [String: String]

    init(launcher: any ScriptProcessLaunching = POSIXScriptLauncher(), environment: [String: String] = ScriptEnvironment.make()) {
        self.launcher = launcher
        self.environment = environment
    }

    /// How long a run may take before it's stopped. `commandPreferences[id]["timeout"]`, in
    /// seconds, overrides it.
    nonisolated static func defaultTimeout(for mode: ScriptOutputMode) -> Duration {
        switch mode {
        case .fullOutput: .seconds(600)
        case .compact, .silent: .seconds(120)
        case .inline: .seconds(30)
        }
    }

    /// `$1`–`$3`: each declared argument's value by position, empty when an optional one has
    /// none, percent-encoded when the header asks.
    nonisolated static func positionalArguments(for command: ScriptCommand, values: [String: String]) -> [String] {
        guard let last = command.metadata.arguments.map(\.index).max() else { return [] }
        return (1...last).map { index in
            guard let argument = command.metadata.arguments.first(where: { $0.index == index }) else { return "" }
            return argument.encoded(values[argument.name] ?? "")
        }
    }

    func invocation(for command: ScriptCommand, arguments: [String], timeout: Duration) -> ScriptInvocation {
        ScriptInvocation(
            scriptURL: command.url, argv: command.launch + arguments,
            workingDirectory: command.metadata.workingDirectory, environment: environment, timeout: timeout)
    }

    /// Starts a run. `completion` runs on the main actor once it ends, however it ends.
    @discardableResult
    func run(
        _ command: ScriptCommand, values: [String: String], timeout: Duration? = nil,
        completion: @escaping @MainActor (ScriptJob, ScriptExecution) -> Void = { _, _ in }
    ) -> ScriptJob {
        let arguments = Self.positionalArguments(for: command, values: values)
        let job = ScriptJob(command: command, arguments: arguments, values: values)
        let invocation = invocation(
            for: command, arguments: arguments, timeout: timeout ?? Self.defaultTimeout(for: command.mode))
        jobs.append(job)
        let launcher = launcher
        job.task = Task { [weak self] in
            let execution = await launcher.run(invocation) { text in
                DispatchQueue.main.async { MainActor.assumeIsolated { job.append(text) } }
            }
            job.finish(execution)
            self?.prune()
            completion(job, execution)
        }
        return job
    }

    func runningJob(for commandID: String) -> ScriptJob? {
        jobs.last { $0.command.id == commandID && $0.isRunning }
    }

    func latestJob(for commandID: String) -> ScriptJob? { jobs.last { $0.command.id == commandID } }

    func job(withID id: UUID) -> ScriptJob? { jobs.first { $0.id == id } }

    var runningJobs: [ScriptJob] { jobs.filter(\.isRunning) }

    func cancelAll() { for job in jobs where job.isRunning { job.cancel() } }

    /// Keeps running jobs and the newest finished ones.
    private func prune() {
        let finished = jobs.filter { !$0.isRunning }
        guard finished.count > Self.historyLimit else { return }
        let dropped = Set(finished.prefix(finished.count - Self.historyLimit).map(\.id))
        jobs.removeAll { dropped.contains($0.id) }
    }
}

/// Which inline scripts refresh on their own, and when.
enum ScriptInlineSchedule {
    /// Only the first ten inline scripts refresh automatically, as the format specifies.
    static let autoRefreshLimit = 10

    /// The inline scripts that refresh by themselves: the first ten, in catalog order. A script
    /// with a required argument has nothing to run with, so it refreshes only from ↩.
    static func autoRefreshing(_ commands: [ScriptCommand]) -> [ScriptCommand] {
        let inline = commands.filter { command in
            command.mode == .inline && command.metadata.refreshTime != nil
                && !command.metadata.arguments.contains { !$0.isOptional }
        }
        return Array(inline.prefix(autoRefreshLimit))
    }

    /// The refresh interval: the header's, never under the ten-second minimum.
    static func interval(for command: ScriptCommand) -> Duration {
        max(command.metadata.refreshTime ?? ScriptMetadata.minimumRefresh, ScriptMetadata.minimumRefresh)
    }

    /// The auto-refreshing scripts due at `now`: never run, or last run at least one interval
    /// ago, and not running now.
    static func due(
        _ commands: [ScriptCommand], lastRun: [String: Date], running: Set<String>, now: Date
    ) -> [ScriptCommand] {
        autoRefreshing(commands).filter { command in
            guard !running.contains(command.id) else { return false }
            guard let last = lastRun[command.id] else { return true }
            return now.timeIntervalSince(last) >= interval(for: command).timeInterval
        }
    }

    /// When the next auto-refreshing script falls due, for the scheduler's sleep.
    static func nextDue(_ commands: [ScriptCommand], lastRun: [String: Date], now: Date) -> Date? {
        autoRefreshing(commands).map { command in
            lastRun[command.id].map { $0.addingTimeInterval(interval(for: command).timeInterval) } ?? now
        }.min()
    }
}
