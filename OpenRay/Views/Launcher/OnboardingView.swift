import AppKit
import SwiftUI

/// First run in three short steps, inside the real panel. Each permission is
/// asked for only when you turn on the feature that needs it. Esc skips.
struct OnboardingView: View {
    @Bindable var model: LauncherModel
    var step: LauncherModel.OnboardingStep
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .shortcut: ShortcutStep(model: model)
                case .features: FeaturesStep(model: model)
                case .keys: KeysStep()
                }
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity)
            .id(step)

            ActionBar(
                feedback: model.feedback, confirmation: model.confirmation, confirmationInstance: model.confirmationInstanceID,
                context: { StepDots(current: step.rawValue, count: LauncherModel.OnboardingStep.allCases.count) },
                actions: { actions },
                onCancelConfirmation: { model.confirmation = nil },
                onConfirm: { if let confirmation = model.confirmation { model.confirm(confirmation) } },
                onConfirmationShown: model.confirmationDidAppear, onApprove: model.approveConfirmation)
        }
        .animation(OR.Motion.resolve(OR.Motion.standard, reduceMotion: reduceMotion), value: step)
        .background {
            ZStack {
                Button("Continue") { model.advanceOnboarding() }.keyboardShortcut(.defaultAction)
                Button("Back") { model.onboardingBack() }.keyboardShortcut(.delete, modifiers: [])
                    .disabled(step == .shortcut)
                Button("Skip") { model.finishOnboarding() }.keyboardShortcut(.cancelAction)
            }
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var actions: some View {
        switch step {
        case .shortcut:
            ActionBarButton(title: "Skip", keys: ["esc"], style: .ghost) { model.finishOnboarding() }
            ActionBarButton(title: "Continue", keys: ["↩"], style: .accent) { model.advanceOnboarding() }
        case .features:
            ActionBarButton(title: "Back", keys: ["⌫"], style: .ghost) { model.onboardingBack() }
            ActionBarButton(title: "Continue", keys: ["↩"], style: .accent) { model.advanceOnboarding() }
        case .keys:
            ActionBarButton(title: "Start Searching", keys: ["↩"], style: .accent) { model.finishOnboarding() }
        }
    }
}

private struct StepDots: View {
    var current: Int
    var count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? OR.Color.accentFill : OR.Color.fill3)
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(OR.Motion.resolve(OR.Motion.standard, reduceMotion: reduceMotion), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

private struct ShortcutStep: View {
    @Bindable var model: LauncherModel

    var body: some View {
        // A shortcut that couldn't be registered never shows as learned.
        let pressed = model.onboardingHotKeyPressed && model.shortcutError == nil
        VStack(alignment: .leading, spacing: 0) {
            ORMark(size: 52)
            Text("OpenRay is one shortcut away").font(OR.Font.display).tracking(-0.4)
                .foregroundStyle(OR.Color.text).padding(.top, 14)
            Text("Press it from any app to find apps, files and commands, or to ask AI. Try it now.")
                .font(OR.Font.body).lineSpacing(3).foregroundStyle(OR.Color.text2).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Self.caps(for: model), id: \.self) { cap in
                    Text(cap)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(pressed ? OR.Color.accent : OR.Color.text)
                        .padding(.horizontal, 16).frame(minWidth: 52, minHeight: 46)
                        .background(
                            pressed ? OR.Color.accentSoft : OR.Color.fill2,
                            in: .rect(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(pressed ? OR.Color.accentFill : OR.Color.separator, lineWidth: pressed ? 1.5 : 1)
                        }
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 22).padding(.bottom, 10)
            .animation(OR.Motion.quick, value: pressed)
            .accessibilityElement()
            .accessibilityLabel("Shortcut: \(KeyShortcut(Self.caps(for: model)).spoken)")
            Group {
                if let error = model.launcherHotKeyRefusal ?? model.shortcutError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5)).foregroundStyle(OR.Color.warning)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                } else if pressed {
                    Label("That's it. You'll use this every day.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(OR.Color.success)
                } else {
                    Text("Waiting for \(model.launcherShortcutInUse.title)…").foregroundStyle(OR.Color.text2)
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .labelStyle(TightLabelStyle())
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("Prefer another shortcut?").font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                SegmentedPicker(
                    options: LauncherHotKey.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { model.store.database.preferences.hotKey },
                        set: { value in
                            // A shortcut macOS reserves is refused; the reason shows under the keys.
                            if model.setLauncherHotKey(value) { model.onboardingHotKeyPressed = false }
                        }), accessibilityLabel: "Launcher shortcut")
            }
            .frame(maxWidth: .infinity)
        }
        .announce(model.launcherHotKeyRefusal ?? model.shortcutError)
    }

    /// The shortcut that opens OpenRay: a recorded one as recorded, otherwise the preset.
    static func caps(for preferences: AppPreferences) -> [String] {
        preferences.launcherShortcut?.caps ?? caps(for: preferences.hotKey)
    }

    /// The shortcut that opens OpenRay right now, which a fallback can make differ from the saved one.
    @MainActor static func caps(for model: LauncherModel) -> [String] {
        let preferences = model.store.database.preferences
        guard let active = model.activeLauncherShortcut, active != preferences.launcherHotKeyShortcut else {
            return caps(for: preferences)
        }
        return LauncherHotKey.allCases.first { $0.shortcut == active }.map(caps(for:)) ?? active.caps
    }

    static func caps(for hotKey: LauncherHotKey) -> [String] {
        switch hotKey {
        case .optionSpace: ["⌥ Option", "Space"]
        case .controlSpace: ["⌃ Control", "Space"]
        case .controlOptionSpace: ["⌃", "⌥", "Space"]
        }
    }
}

private struct FeaturesStep: View {
    @Bindable var model: LauncherModel
    @State private var requestedAccessibility = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose what OpenRay can do").font(OR.Font.display).tracking(-0.4).foregroundStyle(OR.Color.text)
            Text("Apps, files, calculator, notes and quicklinks work right away. These need your OK first.")
                .font(OR.Font.body).lineSpacing(3).foregroundStyle(OR.Color.text2).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                feature(
                    .clipboard, "Clipboard history", detail: "Saved on this Mac. Off until you turn it on.",
                    isOn: Binding(
                        get: { model.store.database.preferences.clipboardEnabled },
                        set: { enabled in
                            // Off here means Off; Pause is for history you want to keep.
                            if enabled { model.enableClipboardHistory() } else { model.turnOffClipboardHistory() }
                        }))
                Hairline()
                feature(.window, "Windows, paste & selection", detail: accessibilityDetail, symbol: "rectangle.split.2x1") {
                    if model.accessibilityAllowed {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(OR.Color.success)
                            .accessibilityHidden(true)
                    } else {
                        Button("Enable…") {
                            model.windows.requestPermission()
                            SystemSettingsLink.open(.accessibility)
                            requestedAccessibility = true
                        }
                        .buttonStyle(.orSecondary)
                    }
                }
                Hairline()
                feature(
                    .ai, "Apple Intelligence",
                    detail: model.ai.availability.isAvailable ? "Ready. Runs on this Mac only." : model.ai.availability.headline
                ) {
                    if model.ai.availability.isAvailable {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(OR.Color.success)
                            .accessibilityHidden(true)
                    } else {
                        Button("Set Up…") { AppleIntelligenceSettings.open() }.buttonStyle(.orSecondary)
                    }
                }
                Hairline()
                feature(
                    .system, "Open at login", detail: "Keeps \(model.launcherShortcutInUse.title) ready after a restart",
                    symbol: "bolt", isOn: Binding(get: { model.loginEnabled }, set: { model.setLaunchAtLogin($0) }))
            }
            .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: OR.Radius.card, style: .continuous).strokeBorder(OR.Color.separator) }
            .padding(.top, 16)
        }
        .onAppear { model.refreshPermissions() }
    }

    private var accessibilityDetail: String {
        if model.accessibilityAllowed { return "Accessibility is on." }
        return requestedAccessibility
            ? "Turn on OpenRay in System Settings, then press \(model.launcherShortcutInUse.title) to come back."
            : "Needs Accessibility, which macOS will ask about"
    }

    private func feature<Trailing: View>(
        _ kind: Kind, _ title: String, detail: String, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            featureLabel(kind, title, detail: detail, symbol: symbol)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    /// A row that is one switch, so it takes focus under Full Keyboard Access and Space flips it.
    private func feature(_ kind: Kind, _ title: String, detail: String, symbol: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { featureLabel(kind, title, detail: detail, symbol: symbol) }
            .toggleStyle(.orSwitch)
            .padding(.horizontal, 12).padding(.vertical, 11)
    }

    private func featureLabel(_ kind: Kind, _ title: String, detail: String, symbol: String?) -> some View {
        HStack(spacing: 12) {
            KindTile(kind: kind, symbol: symbol, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(OR.Font.bodyEmphasis).foregroundStyle(OR.Color.text)
                Text(detail).font(OR.Font.callout).foregroundStyle(OR.Color.text2).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct KeysStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Three keys to remember").font(OR.Font.display).tracking(-0.4).foregroundStyle(OR.Color.text)
            Text("Everything else appears in the action bar as you go.")
                .font(OR.Font.body).foregroundStyle(OR.Color.text2).padding(.top, 6)
            VStack(spacing: 8) {
                tip(["Tab"], "Ask AI", "Turn any search into a question")
                tip(["⌘", "K"], "Actions", "Everything you can do with the selection")
                tip(["⌘", "/"], "Shortcuts", "See what works where you are")
            }
            .padding(.top, 18)
        }
    }

    private func tip(_ keys: [String], _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            KeyCaps(keys, size: .large).frame(minWidth: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(OR.Color.text)
                Text(detail).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
