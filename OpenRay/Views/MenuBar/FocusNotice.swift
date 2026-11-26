import AppKit
import SwiftUI

/// A Focus notice: what it says and for how long.
struct FocusNotice: Equatable {
    var symbol: String
    var tone: Tone
    var title: String
    var detail: String
    var seconds: Double

    enum Tone: Equatable { case accent, success, warning }

    static func blocked(appName: String, goal: String) -> FocusNotice {
        FocusNotice(
            symbol: "hand.raised.fill", tone: .warning, title: "\(appName) is blocked",
            detail: "You're focusing on \(goal). Snooze or pause from the menu bar.", seconds: 2.4)
    }

    static func started(_ configuration: FocusConfiguration) -> FocusNotice {
        let length = configuration.duration.map { FocusFormat.duration(minutes: Int($0 / 60)) } ?? "No time limit"
        let names = configuration.categoryNames.isEmpty ? "no categories" : ListFormatter.localizedString(byJoining: configuration.categoryNames)
        return FocusNotice(
            symbol: "scope", tone: .accent, title: configuration.displayGoal,
            detail: "\(length) · \(configuration.mode.verb) \(names)", seconds: 2.4)
    }

    static func summary(_ summary: FocusSummary) -> FocusNotice {
        FocusNotice(
            symbol: "checkmark.seal.fill", tone: .success,
            title: summary.finishedOnTime ? "Focus session complete" : "Session ended", detail: summary.text, seconds: 6)
    }
}

/// Shows Focus notices in a small panel at the top of the screen, over other apps, without
/// taking focus or clicks. Refused in tests and verification mode.
@MainActor
final class FocusNoticeCenter: FocusNoticePresenting {
    let guardrail: SideEffectGuard
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// The last notice asked for, shown or not. Tests read it through a fake instead.
    private(set) var lastNotice: FocusNotice?

    init(guardrail: SideEffectGuard = .current) {
        self.guardrail = guardrail
    }

    func showBlocked(appName: String, goal: String) { present(.blocked(appName: appName, goal: goal)) }
    func showStarted(_ configuration: FocusConfiguration) { present(.started(configuration)) }
    func showSummary(_ summary: FocusSummary) { present(.summary(summary)) }

    private func present(_ notice: FocusNotice) {
        lastNotice = notice
        guard (try? guardrail.check("showing a Focus notice")) != nil else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: FocusNoticeView(notice: notice))
        let size = host.fittingSize
        panel.contentView = host
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(
                NSRect(x: (frame.midX - size.width / 2).rounded(), y: (frame.maxY - size.height - 12).rounded(),
                       width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: "\(notice.title). \(notice.detail)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(notice.seconds))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("openray.focus.notice")
        return panel
    }
}

struct FocusNoticeView: View {
    let notice: FocusNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(OR.Font.headline).foregroundStyle(OR.Color.text).lineLimit(1)
                Text(notice.detail).font(OR.Font.callout).foregroundStyle(OR.Color.text2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minWidth: 240, maxWidth: 380, alignment: .leading)
        .popoverSurface()
        .padding(10)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch notice.tone {
        case .accent: OR.Color.accent
        case .success: OR.Color.success
        case .warning: OR.Color.warning
        }
    }
}
