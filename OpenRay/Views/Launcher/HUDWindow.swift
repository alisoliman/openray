import AppKit
import SwiftUI

/// A short confirmation that appears after the launcher closes, for commands
/// with no view: system commands, window layouts and silent scripts.
struct HUDMessage: Equatable, Sendable {
    enum Style: Sendable { case success, info, warning, error }

    var text: String
    var symbol: String?
    var style: Style

    init(_ text: String, symbol: String? = nil, style: Style = .success) {
        self.text = text
        self.symbol = symbol
        self.style = style
    }
}

/// Draws the HUD. `HUDPanelPresenter` is the real one; tests use a fake so no
/// panel appears on the screen while they run.
@MainActor
protocol HUDPresenting: AnyObject {
    /// The window size the message needs, including room for its shadow.
    func size(for message: HUDMessage) -> CGSize
    func present(_ message: HUDMessage, in frame: CGRect)
    func dismiss()
}

enum HUDPlacement {
    /// The HUD sits this share of the display's height above the bottom edge.
    static let bottomFraction: CGFloat = 0.12
    static let minimumBottomOffset: CGFloat = 64

    /// Centered horizontally, low on the display, inside its visible frame.
    static func frame(for size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let offset = max(visibleFrame.height * bottomFraction, minimumBottomOffset)
        let y = min(visibleFrame.minY + offset, visibleFrame.maxY - height)
        return CGRect(x: (visibleFrame.midX - width / 2).rounded(), y: y.rounded(), width: width, height: height)
    }
}

/// Shows one HUD at a time. A new message replaces the current one and restarts its timer.
@MainActor
final class HUDController {
    /// Runs `action` after `delay`. Injected so tests drive time by hand.
    typealias Schedule = @MainActor (Duration, @escaping @MainActor @Sendable () -> Void) -> Void

    static let duration: Duration = .milliseconds(1_500)

    /// The app's one HUD, so a new message always replaces the last.
    static let shared = HUDController()

    private let presenter: any HUDPresenting
    private let screenFrame: @MainActor () -> CGRect?
    private let schedule: Schedule
    /// Bumped by every show and hide, so a stale timer never hides a newer message.
    private var generation = 0
    private(set) var current: HUDMessage?

    init(
        presenter: any HUDPresenting = HUDPanelPresenter(),
        screenFrame: @escaping @MainActor () -> CGRect? = HUDController.activeScreenFrame,
        schedule: @escaping Schedule = HUDController.scheduleOnMainActor
    ) {
        self.presenter = presenter
        self.screenFrame = screenFrame
        self.schedule = schedule
    }

    func show(message: String, symbol: String? = nil) {
        show(HUDMessage(message, symbol: symbol))
    }

    func show(_ message: HUDMessage) {
        guard let screen = screenFrame() else { return }
        presenter.present(message, in: HUDPlacement.frame(for: presenter.size(for: message), in: screen))
        current = message
        generation += 1
        let shown = generation
        schedule(Self.duration) { [weak self] in self?.hide(ifShowing: shown) }
    }

    func hide() {
        generation += 1
        guard current != nil else { return }
        current = nil
        presenter.dismiss()
    }

    private func hide(ifShowing shown: Int) {
        guard shown == generation, current != nil else { return }
        current = nil
        presenter.dismiss()
    }

    static func scheduleOnMainActor(_ delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            action()
        }
    }

    /// The display under the pointer, where the launcher was just used.
    static func activeScreenFrame() -> CGRect? {
        let mouse = NSEvent.mouseLocation
        return (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
    }
}

/// The HUD's capsule, in the design system's glass.
struct HUDView: View {
    /// Room around the capsule for its shadow.
    static let shadowMargin: CGFloat = 24
    /// Longer messages wrap onto a second line.
    static let maximumContentWidth: CGFloat = 420

    var message: HUDMessage
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OR.Radius.popover, style: .continuous)
        HStack(spacing: 8) {
            if let symbol = message.symbol {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(message.text).font(OR.Font.bodyEmphasis).foregroundStyle(OR.Color.text)
                .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, OR.Space.s4)
        .padding(.vertical, 10)
        .frame(minHeight: 40)
        .background {
            if reduceTransparency {
                OR.Color.popoverSolid
            } else {
                ZStack {
                    VisualEffectBackground(material: .hudWindow, blending: .behindWindow)
                    OR.Color.popover
                }
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(OR.Color.popoverEdge, lineWidth: 0.5) }
        .shadow(color: OR.Color.shadowSoft, radius: 12, y: 6)
        .padding(Self.shadowMargin)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch message.style {
        case .success: OR.Color.success
        case .info: OR.Color.info
        case .warning: OR.Color.warning
        case .error: OR.Color.danger
        }
    }
}

/// A borderless panel that never takes focus or clicks, above other windows on every Space.
@MainActor
final class HUDPanelPresenter: HUDPresenting {
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var orderOut: Task<Void, Never>?

    nonisolated init() {}

    /// True while the panel is on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    func size(for message: HUDMessage) -> CGSize {
        let controller = NSHostingController(rootView: HUDView(message: message))
        let unlimited = CGFloat.greatestFiniteMagnitude
        let ideal = controller.sizeThatFits(in: CGSize(width: unlimited, height: unlimited))
        let limit = HUDView.maximumContentWidth + HUDView.shadowMargin * 2
        guard ideal.width > limit else { return ideal }
        let wrapped = controller.sizeThatFits(in: CGSize(width: limit, height: unlimited))
        return CGSize(width: min(wrapped.width, limit), height: wrapped.height)
    }

    func present(_ message: HUDMessage, in frame: CGRect) {
        // The test host never puts a panel on the person's screen.
        guard !SideEffectGuard.isTestHost else { return }
        orderOut?.cancel()
        let panel = panel ?? makePanel()
        hosting?.rootView = HUDView(message: message)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [
                .announcement: message.text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }
        orderOut?.cancel()
        orderOut = Task { [weak panel] in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: HUDView(message: HUDMessage("")))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}
