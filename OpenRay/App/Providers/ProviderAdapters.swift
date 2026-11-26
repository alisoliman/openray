import AppKit

/// How a provider closes the launcher. Inert launches (tests, isolated verification) never
/// bring another app forward; tests inject a recorder.
struct LauncherDismissal: Sendable {
    var dismiss: @MainActor @Sendable (LauncherModel, _ restoreFocus: Bool) -> Void

    /// Whether closing may activate the app OpenRay opened over: never while this guard or the
    /// process is inert.
    static func restoresFocus(_ requested: Bool, sideEffects: SideEffectGuard) -> Bool {
        requested && !sideEffects.effective.isInert
    }

    static func live(sideEffects: SideEffectGuard = .current) -> LauncherDismissal {
        LauncherDismissal { model, restoreFocus in
            model.panel?.dismiss(restoreFocus: restoresFocus(restoreFocus, sideEffects: sideEffects))
        }
    }
}

/// Opens System Settings and other places outside OpenRay, only in a live launch.
struct ExternalOpener: Sendable {
    var open: @MainActor @Sendable (URL) -> Bool

    static let accessibilitySettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let automationSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static func live(
        sideEffects: SideEffectGuard = .current,
        workspace: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> ExternalOpener {
        ExternalOpener { url in
            guard !sideEffects.effective.isInert else { return false }
            return workspace(url)
        }
    }
}
