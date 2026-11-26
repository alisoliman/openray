import AppKit
import Foundation

/// One runtime rule for side effects on the person's Mac: windows, apps, sound,
/// power, menus, synthetic input and the system clipboard.
///
/// Side effects run only in a normal launch. Two launches are inert:
/// - the XCTest host, and
/// - isolated verification (`--in-memory-library` or `--verification-pasteboard`,
///   see README "Manual UI and clipboard checks").
///
/// Inert means default executors do nothing and every live adapter calls
/// `check(_:)` before acting, which throws `Blocked`. Writes to the general
/// pasteboard are refused too; private pasteboards stay usable.
///
/// Use the static members for the current process. Adapters take an instance
/// (defaulting to `.current`) so tests can inject either launch configuration.
struct SideEffectGuard: Equatable, Sendable {
    enum Mode: String, Sendable {
        case live
        case testHost
        case verification
    }

    /// Launch arguments that start OpenRay in isolated verification mode.
    static let verificationArguments: Set<String> = ["--in-memory-library", "--verification-pasteboard"]

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    /// Classifies a launch. XCTest wins over verification arguments.
    init(arguments: [String], environment: [String: String], xcTestLoaded: Bool) {
        if xcTestLoaded || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil
        {
            mode = .testHost
        } else if arguments.contains(where: Self.verificationArguments.contains) {
            mode = .verification
        } else {
            mode = .live
        }
    }

    /// This process's rule, read once at launch.
    static let current = SideEffectGuard(
        arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment,
        xcTestLoaded: NSClassFromString("XCTestCase") != nil)

    // MARK: Instance

    var isTestHost: Bool { mode == .testHost }
    var isVerificationMode: Bool { mode == .verification }
    /// True in the test host and in verification mode.
    var isInert: Bool { mode != .live }

    /// The rule that actually applies: an injected `.live` guard can never re-enable side effects
    /// in a process that is itself inert (the test host or isolated verification). An inert
    /// instance stays inert, so fakes can still simulate the inert modes in a live process.
    var effective: SideEffectGuard { isInert ? self : .current }

    /// Throws `Blocked` unless side effects are allowed by both this guard and the process.
    /// Call it first, before any OS call.
    func check(_ what: String) throws {
        let rule = effective
        if rule.isInert { throw Blocked(what: what, mode: rule.mode) }
    }

    /// Writes to the general pasteboard are refused while this guard or the process is inert;
    /// named private pasteboards are fine.
    func mayWrite(toPasteboardNamed name: NSPasteboard.Name) -> Bool {
        !effective.isInert || name != .general
    }

    func checkWrite(toPasteboardNamed name: NSPasteboard.Name) throws {
        guard mayWrite(toPasteboardNamed: name) else {
            throw Blocked(what: "writing to the system clipboard", mode: effective.mode)
        }
    }

    @MainActor
    func mayWrite(to pasteboard: NSPasteboard) -> Bool { mayWrite(toPasteboardNamed: pasteboard.name) }

    @MainActor
    func checkWrite(to pasteboard: NSPasteboard) throws { try checkWrite(toPasteboardNamed: pasteboard.name) }

    // MARK: Current process

    static var isTestHost: Bool { current.isTestHost }
    static var isVerificationMode: Bool { current.isVerificationMode }
    static var isInert: Bool { current.isInert }

    static func check(_ what: String) throws { try current.check(what) }

    static func mayWrite(toPasteboardNamed name: NSPasteboard.Name) -> Bool {
        current.mayWrite(toPasteboardNamed: name)
    }

    static func checkWrite(toPasteboardNamed name: NSPasteboard.Name) throws {
        try current.checkWrite(toPasteboardNamed: name)
    }

    @MainActor
    static func mayWrite(to pasteboard: NSPasteboard) -> Bool { current.mayWrite(to: pasteboard) }

    @MainActor
    static func checkWrite(to pasteboard: NSPasteboard) throws { try current.checkWrite(to: pasteboard) }

    // MARK: Errors

    struct Blocked: LocalizedError, Equatable, Sendable {
        var what: String
        var mode: Mode

        var errorDescription: String? {
            switch mode {
            case .testHost: "OpenRay doesn't allow \(what) while tests run."
            case .verification: "OpenRay doesn't allow \(what) in isolated verification mode."
            case .live: "OpenRay didn't allow \(what)."
            }
        }
    }
}
