import AppKit
import SwiftUI

// MARK: - Keycaps

/// One cap per key, in macOS order. Hidden from VoiceOver; controls carry the
/// shortcut in words through their accessibility hint instead.
struct KeyCaps: View {
    var keys: [String]
    var size: KeyCap.Size = .regular
    var style: KeyCap.Style = .standard

    init(_ keys: [String], size: KeyCap.Size = .regular, style: KeyCap.Style = .standard) {
        self.keys = keys
        self.size = size
        self.style = style
    }

    init(_ shortcut: KeyShortcut, size: KeyCap.Size = .regular, style: KeyCap.Style = .standard) {
        self.init(shortcut.caps, size: size, style: style)
    }

    var body: some View {
        HStack(spacing: size == .large ? 4 : 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(key, size: size, style: style) }
        }
        .accessibilityHidden(true)
    }
}

struct KeyCap: View {
    enum Size { case small, regular, large, hero }
    enum Style { case standard, onAccent, plain }
    var key: String
    var size: Size = .regular
    var style: Style = .standard

    init(_ key: String, size: Size = .regular, style: Style = .standard) {
        self.key = key
        self.size = size
        self.style = style
    }

    var body: some View {
        Text(key)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(background, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(alignment: .bottom) {
                if style == .standard {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(OR.Color.separator)
                        .frame(height: 1).padding(.horizontal, radius / 2)
                }
            }
    }

    private var height: CGFloat {
        switch size {
        case .small: 18
        case .regular: 20
        case .large: 28
        case .hero: 46
        }
    }

    private var radius: CGFloat {
        switch size {
        case .hero: 10
        case .large: 7
        default: OR.Radius.key
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .hero: 16
        case .large: 8
        default: 5
        }
    }

    private var font: Font {
        switch size {
        case .small: .system(size: 11, weight: .medium)
        case .regular: OR.Font.key
        case .large: .system(size: 13, weight: .medium)
        case .hero: .system(size: 18, weight: .medium)
        }
    }

    /// Caps on a button inherit its foreground: white on accent, danger on Delete.
    private var foreground: AnyShapeStyle {
        switch style {
        case .standard: AnyShapeStyle(size == .hero || size == .large ? OR.Color.text : OR.Color.text2)
        case .onAccent, .plain: AnyShapeStyle(HierarchicalShapeStyle.primary)
        }
    }

    private var background: Color {
        switch style {
        case .standard: OR.Color.fill2
        case .onAccent: Color.white.opacity(0.2)
        case .plain: .clear
        }
    }
}

/// A shortcut in display form, with caps and a spoken description.
struct KeyShortcut: Hashable, Sendable {
    var caps: [String]
    var spoken: String

    init(_ caps: [String], spoken: String? = nil) {
        self.caps = caps
        self.spoken = spoken ?? caps.map(KeyShortcut.spokenName).joined(separator: " ")
    }

    static let `return` = KeyShortcut(["↩"])
    static let commandReturn = KeyShortcut(["⌘", "↩"])
    static let tab = KeyShortcut(["Tab"])
    static let escape = KeyShortcut(["esc"])
    static let commandK = KeyShortcut(["⌘", "K"])

    /// Modifiers follow the macOS menu order: ⌃ ⌥ ⇧ ⌘.
    static func command(_ key: String, shift: Bool = false) -> KeyShortcut {
        KeyShortcut(shift ? ["⇧", "⌘", key] : ["⌘", key])
    }

    init(_ shortcut: CommandShortcut) {
        self.init(shortcut.caps)
    }

    private static func spokenName(_ cap: String) -> String {
        switch cap {
        case "⌘": "Command"
        case "⇧": "Shift"
        case "⌥": "Option"
        case "⌃": "Control"
        case "↩": "Return"
        case "⌫": "Delete"
        case "esc": "Escape"
        case "←": "Left Arrow"
        case "→": "Right Arrow"
        case "↑": "Up Arrow"
        case "↓": "Down Arrow"
        default: cap
        }
    }
}

// MARK: - Chips

/// An alias or keyword chip, monospaced.
struct AliasChip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(OR.Font.monoSmall).foregroundStyle(OR.Color.text2)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).frame(height: 20)
            .background(OR.Color.fill1, in: .rect(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(OR.Color.separator) }
    }
}

/// A placeholder chip such as {query} or {date}, in accent.
struct PlaceholderChip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(OR.Color.accent)
            .padding(.horizontal, 6).frame(height: 20)
            .background(OR.Color.accentSoft, in: .rect(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Action panel and search field parts

/// A titled section in the action panel, such as “Fallbacks” or “Paste As”.
struct ActionPanelSectionHeader: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(OR.Color.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8).padding(.top, 6).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The row above an open submenu: its parent's title, with ← or esc to go back.
struct ActionPanelBreadcrumb: View {
    var title: String
    var onBack: () -> Void
    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(title).font(OR.Font.calloutEmphasis).lineLimit(1)
                Spacer(minLength: 8)
                KeyCaps(["←"], size: .small)
            }
            .foregroundStyle(OR.Color.text2)
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back from \(title)")
    }
}

/// One inline argument in the search bar: a compact well holding a field, accented while it
/// has the keyboard. Optional arguments say so in the placeholder.
struct ArgumentFieldWell<Field: View>: View {
    var isFocused: Bool
    var isMissing = false
    @ViewBuilder var field: Field
    var body: some View {
        field
            .padding(.horizontal, 8).frame(height: 30)
            .frame(minWidth: 90, maxWidth: 200)
            .background(OR.Color.fill1, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isMissing ? OR.Color.warning : isFocused ? OR.Color.accentFill : OR.Color.separator)
            }
    }
}

/// The small circular clear button.
struct ClearButton: View {
    var label = "Clear"
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(OR.Color.text2)
                .frame(width: 18, height: 18)
                .background(OR.Color.fill3, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// An attachment chip: what text the next AI request will use.
struct AttachmentChip<Leading: View>: View {
    var text: String
    var leading: Leading
    var onRemove: (() -> Void)?

    init(_ text: String, onRemove: (() -> Void)? = nil, @ViewBuilder leading: () -> Leading) {
        self.text = text
        self.onRemove = onRemove
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(text).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(OR.Color.text2)
                }
                .buttonStyle(.plain).accessibilityLabel("Remove attachment")
            }
        }
        .font(OR.Font.calloutEmphasis)
        .foregroundStyle(OR.Color.text2)
        .padding(.leading, 7).padding(.trailing, 9).frame(height: 26)
        .background(OR.Color.fill1, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(OR.Color.separator) }
        .fixedSize()
    }
}

// MARK: - Buttons

struct ORButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, ghost, destructive }
    var role: Role = .secondary
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? OR.Font.buttonLarge : OR.Font.button)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, large ? 16 : 12)
            .frame(height: large ? 34 : 28)
            .background(background(pressed: configuration.isPressed), in: shape)
            .overlay {
                if role == .secondary { shape.strokeBorder(OR.Color.separator, lineWidth: 0.5) }
                if role == .primary {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                }
            }
            .shadow(color: role == .primary ? .black.opacity(0.18) : .clear, radius: 1, y: 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .animation(OR.Motion.quick, value: configuration.isPressed)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: large ? 10 : OR.Radius.control, style: .continuous)
    }

    private var foreground: Color {
        switch role {
        case .primary: OR.Color.onAccent
        case .secondary: OR.Color.text
        case .ghost: OR.Color.text2
        case .destructive: OR.Color.danger
        }
    }

    private func background(pressed: Bool) -> AnyShapeStyle {
        switch role {
        case .primary:
            AnyShapeStyle(OR.Color.accentButton.opacity(pressed ? 0.85 : 1))
        case .secondary: AnyShapeStyle(pressed ? OR.Color.fill3 : OR.Color.fill2)
        case .ghost: AnyShapeStyle(pressed ? OR.Color.fill2 : Color.clear)
        case .destructive: AnyShapeStyle(OR.Color.dangerSoft.opacity(pressed ? 1.6 : 1))
        }
    }
}

extension ButtonStyle where Self == ORButtonStyle {
    static var orPrimary: ORButtonStyle { ORButtonStyle(role: .primary) }
    static var orSecondary: ORButtonStyle { ORButtonStyle(role: .secondary) }
    static var orGhost: ORButtonStyle { ORButtonStyle(role: .ghost) }
    static var orDestructive: ORButtonStyle { ORButtonStyle(role: .destructive) }
    static func or(_ role: ORButtonStyle.Role, large: Bool = false) -> ORButtonStyle {
        ORButtonStyle(role: role, large: large)
    }
}

/// A hover-aware plain button: fill-1 on hover, fill-2 when pressed.
struct HoverButtonStyle: ButtonStyle {
    var radius: CGFloat = OR.Radius.control
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, radius: radius, selected: selected)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(fill, in: .rect(cornerRadius: radius, style: .continuous))
                .contentShape(.rect(cornerRadius: radius, style: .continuous))
                .onHover { hovering = $0 }
                .animation(OR.Motion.quick, value: hovering)
        }

        private var fill: Color {
            if configuration.isPressed { return OR.Color.fill3 }
            if selected { return OR.Color.fill2 }
            return hovering ? OR.Color.fill1 : .clear
        }
    }
}

// MARK: - Switch & segmented control

/// The OpenRay switch: 32 × 19, accent when on. The row is one button, so it takes
/// focus under Full Keyboard Access and Space toggles it; the ring sits on the knob.
struct ORSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 0)
                FocusRingSwitchKnob(isOn: configuration.isOn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(SwitchRowButtonStyle())
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// The row doesn't dim when pressed; the knob moving is the feedback.
private struct SwitchRowButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View { configuration.label }
}

/// Reads the row button's focus so only the knob draws the ring.
private struct FocusRingSwitchKnob: View {
    var isOn: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View { SwitchKnob(isOn: isOn, focused: isFocused) }
}

struct SwitchKnob: View {
    var isOn: Bool
    /// Draws the focus ring: a 1 pt accent stroke inside a 3 pt soft accent ring.
    var focused = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(isOn ? OR.Color.accentFill : OR.Color.fill3)
            .frame(width: 32, height: 19)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .padding(2)
            }
            .overlay {
                if focused { Capsule().strokeBorder(OR.Color.accentFill, lineWidth: 1) }
            }
            .background {
                if focused { Capsule().stroke(OR.Color.accentSoft, lineWidth: 3).padding(-1.5) }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(OR.Motion.resolve(OR.Motion.quick, reduceMotion: reduceMotion), value: isOn)
            .animation(OR.Motion.resolve(OR.Motion.quick, reduceMotion: reduceMotion), value: focused)
            .contentShape(.capsule)
    }
}

extension ToggleStyle where Self == ORSwitchStyle {
    static var orSwitch: ORSwitchStyle { ORSwitchStyle() }
}

/// A compact segmented control used inside the panel.
private enum SegmentMetrics {
    /// The segment text's baseline from the control's top: 2 pt inset, then 12 pt text
    /// centered in a 24 pt segment.
    nonisolated static let textBaseline: CGFloat = {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let lineHeight = font.ascender - font.descender + font.leading
        return 2 + (24 - lineHeight) / 2 + font.ascender
    }()
}

struct SegmentedPicker<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value
    var accessibilityLabel: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isOn ? OR.Color.text : OR.Color.text2)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(OR.Color.popoverSolid)
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(OR.Color.separator, lineWidth: 0.5)
                                    }
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(2)
        .background(OR.Color.fill2, in: .rect(cornerRadius: OR.Radius.control, style: .continuous))
        // Buttons don't pass their text baseline up, so rows would align the label with the
        // control's top. Put the baseline on the segment text.
        .alignmentGuide(.firstTextBaseline) { _ in SegmentMetrics.textBaseline }
        .alignmentGuide(.lastTextBaseline) { _ in SegmentMetrics.textBaseline }
        // One keyboard stop, as a native segmented control is: ← and → change the choice. Only
        // keyboard navigation focuses it, so a click never takes focus from the search field.
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            guard let index = options.firstIndex(where: { $0.0 == selection }) else { return }
            switch direction {
            case .left where index > 0: selection = options[index - 1].0
            case .right where index < options.count - 1: selection = options[index + 1].0
            default: break
            }
        }
        // VoiceOver hears a native segmented control: a group of choices with the selected one.
        .accessibilityRepresentation {
            Picker(accessibilityLabel, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// A dropdown menu styled as an in-field control (“All Types ⇅”).
struct DropdownMenu<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value
    var accessibilityLabel: String
    var symbol: (Value) -> String? = { _ in nil }

    var body: some View {
        Menu {
            Picker(accessibilityLabel, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    if let image = symbol(option.0) {
                        Label(option.1, systemImage: image).tag(option.0)
                    } else {
                        Text(option.1).tag(option.0)
                    }
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            DropdownLabel(title: options.first { $0.0 == selection }?.1 ?? "")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
    }
}

struct DropdownLabel: View {
    var title: String
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(OR.Color.text)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(OR.Color.text2)
                // Otherwise the menu is exposed twice, once for the chevron.
                .accessibilityHidden(true)
        }
        .padding(.leading, 10).padding(.trailing, 8).frame(height: 28)
        .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OR.Radius.control, style: .continuous)
                .strokeBorder(OR.Color.separator, lineWidth: 0.5)
        }
        .contentShape(.rect)
    }
}

// MARK: - Progress

/// A thin ring spinner. Respects Reduce Motion by pulsing instead of spinning.
/// Hidden from VoiceOver unless it has a label, such as “Searching files”.
struct Spinner: View {
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2
    var accessibilityLabel: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    var body: some View {
        ZStack {
            Circle().stroke(OR.Color.fill3, lineWidth: lineWidth)
            Circle().trim(from: 0, to: 0.25)
                .stroke(OR.Color.text2, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
                .opacity(reduceMotion && rotating ? 0.5 : 1)
        }
        .frame(width: size - lineWidth, height: size - lineWidth)
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(
                reduceMotion
                    ? .easeInOut(duration: 0.8).repeatForever() : .linear(duration: 0.8).repeatForever(autoreverses: false)
            ) { rotating = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? "")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityHidden(accessibilityLabel == nil)
    }
}

// MARK: - Notices & empty states

/// A persistent, non-error state shown as the first row of a list, with one action.
struct InlineNotice<Actions: View>: View {
    enum Tone { case warning, info, error, success }
    var tone: Tone
    var symbol: String
    var title: String
    var detail: String?
    /// Words in the detail to set in primary text, such as a button the user must find next.
    var emphasis: String?
    var actions: Actions

    init(
        _ tone: Tone, symbol: String, title: String, detail: String? = nil, emphasis: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.tone = tone
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.emphasis = emphasis
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(color)
                .frame(width: 18).accessibilityHidden(true)
            Text("\(Text(title).foregroundStyle(OR.Color.text))\(Text(detailText))")
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            actions.controlSize(.small)
        }
        .padding(.vertical, 9).padding(.leading, 12).padding(.trailing, 10)
        .frame(minHeight: 40)
        .background(soft, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var detailText: AttributedString {
        guard let detail else { return AttributedString() }
        var text = AttributedString(" " + detail)
        text.foregroundColor = OR.Color.text2
        if let emphasis, let range = text.range(of: emphasis) {
            text[range].foregroundColor = OR.Color.text
            text[range].font = .system(size: 12.5, weight: .semibold)
        }
        return text
    }

    private var color: Color {
        switch tone {
        case .warning: OR.Color.warning
        case .info: OR.Color.info
        case .error: OR.Color.danger
        case .success: OR.Color.success
        }
    }

    private var soft: Color {
        switch tone {
        case .warning: OR.Color.warningSoft
        case .info: OR.Color.infoSoft
        case .error: OR.Color.dangerSoft
        case .success: OR.Color.successSoft
        }
    }
}

extension InlineNotice where Actions == EmptyView {
    init(_ tone: Tone, symbol: String, title: String, detail: String? = nil, emphasis: String? = nil) {
        self.init(tone, symbol: symbol, title: title, detail: detail, emphasis: emphasis) { EmptyView() }
    }
}

/// Explains why a list is empty and offers the most likely next step.
struct EmptyStateView<Actions: View>: View {
    var kind: Kind
    var symbol: String?
    var title: String
    var detail: String
    var actions: Actions

    init(
        kind: Kind, symbol: String? = nil, title: String, detail: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            KindTile(kind: kind, symbol: symbol, size: 40).padding(.bottom, 14)
            Text(title).font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                .foregroundStyle(OR.Color.text).multilineTextAlignment(.center)
                .padding(.bottom, 6)
            Text(detail).font(OR.Font.body).foregroundStyle(OR.Color.text2)
                .multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions }.padding(.top, 18)
        }
        .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(kind: Kind, symbol: String? = nil, title: String, detail: String) {
        self.init(kind: kind, symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// A monospaced example that fills the field when clicked.
struct ExampleChip: View {
    var text: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(OR.Color.text)
                .padding(.horizontal, 10).frame(height: 28)
                .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OR.Radius.control, style: .continuous).strokeBorder(OR.Color.separator)
                }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Fills the search field")
    }
}

// MARK: - Form fields (in-panel)

/// A label + field + help stack with the focus ring from the design.
struct FieldGroup<Field: View>: View {
    var label: String
    var help: String?
    var error: String?
    var field: Field

    init(_ label: String, help: String? = nil, error: String? = nil, @ViewBuilder field: () -> Field) {
        self.label = label
        self.help = help
        self.error = error
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(OR.Color.text)
            field
            if let error {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(OR.Font.callout).foregroundStyle(OR.Color.danger)
                .labelStyle(TightLabelStyle())
                .transition(.opacity)
            } else if let help {
                Text(help).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// The in-panel text box: fill-1 with a hairline, accent ring when focused.
struct FieldBox: ViewModifier {
    var focused: Bool
    var invalid = false
    var minHeight: CGFloat = 32

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(minHeight: minHeight)
            .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OR.Radius.control, style: .continuous)
                    .strokeBorder(invalid ? OR.Color.danger : focused ? OR.Color.accentFill : OR.Color.separator)
            }
            .background {
                if invalid || focused {
                    RoundedRectangle(cornerRadius: OR.Radius.control + 3, style: .continuous)
                        .stroke(invalid ? OR.Color.dangerSoft : OR.Color.accentSoft, lineWidth: 3)
                        .padding(-1.5)
                }
            }
            .animation(OR.Motion.quick, value: focused)
            .animation(OR.Motion.quick, value: invalid)
    }
}

extension View {
    func fieldBox(focused: Bool, invalid: Bool = false, minHeight: CGFloat = 32) -> some View {
        modifier(FieldBox(focused: focused, invalid: invalid, minHeight: minHeight))
    }
}

// MARK: - Misc

/// Label–value metadata rows.
struct MetaTable: View {
    var rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(OR.Color.text2)
                    Text(row.1).foregroundStyle(OR.Color.text).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(OR.Font.callout)
    }
}

/// The 1 pt hairline between field, content and action bar.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(OR.Color.separator)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

/// Status dot that always appears with a word.
struct StatusLabel: View {
    enum Tone { case success, warning, danger, info, neutral, working }
    var tone: Tone
    var text: String
    /// When false, only the dot carries the color and the word stays secondary.
    var tintsText = true
    var body: some View {
        HStack(spacing: 6) {
            if tone == .working {
                Spinner(size: 12, lineWidth: 1.5)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text)
        }
        .font(OR.Font.callout).foregroundStyle(tone == .neutral || !tintsText ? OR.Color.text2 : color)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .success: OR.Color.success
        case .warning: OR.Color.warning
        case .danger: OR.Color.danger
        case .info, .working: OR.Color.info
        case .neutral: OR.Color.text3
        }
    }
}

extension View {
    /// Posts a VoiceOver announcement, used for toasts. With `initial`, a view that
    /// appears already holding text announces it too.
    func announce(_ text: String?, initial: Bool = false) -> some View {
        onChange(of: text, initial: initial) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: newValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
