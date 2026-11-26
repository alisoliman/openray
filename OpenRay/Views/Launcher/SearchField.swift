import AppKit
import SwiftUI

/// A scope or argument token inside the field. It replaces the Back button and section title.
struct ScopeToken: View {
    enum Style { case scope, argument }
    var kind: Kind
    var symbol: String?
    var title: String
    var style: Style = .scope
    var onRemove: (() -> Void)?

    var body: some View {
        Button {
            onRemove?()
        } label: {
            HStack(spacing: 6) {
                KindTile(kind: kind, symbol: symbol, size: 20)
                Text(title).font(OR.Font.token).lineLimit(1)
            }
            .foregroundStyle(style == .argument ? OR.Color.accent : OR.Color.text)
            .padding(.leading, 5).padding(.trailing, 10).frame(height: 30)
            .background(
                style == .argument ? OR.Color.accentSoft : OR.Color.fill2,
                in: .rect(cornerRadius: 9, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(style == .argument ? "Delete to edit the keyword" : "Delete to leave \(title)")
        .accessibilityLabel(style == .argument ? "Argument: \(title)" : "Scope: \(title)")
        .accessibilityHint(style == .argument ? "Delete to edit the keyword." : "Delete to leave.")
    }
}

/// The search field for Everything and every scope.
struct SearchFieldBar: View {
    @Bindable var model: LauncherModel

    var body: some View {
        HStack(spacing: 10) {
            leading
            if let session = model.argumentSession {
                ArgumentFieldsRow(model: model, session: session)
            } else {
                queryField
            }
            accessories
        }
        .padding(.leading, model.section == .home && model.argumentLink == nil && model.argumentSession == nil ? 18 : 14)
        .padding(.trailing, 14)
        .frame(height: OR.Metric.field)
    }

    private var queryField: some View {
        LauncherSearchInput(
            text: $model.query, placeholder: placeholder,
            focusRequest: model.focusRequest, submit: model.performSelected,
            move: model.moveSelection, cancel: model.escape, paste: model.pasteSelected,
            tab: model.handleTab, deleteOnEmpty: model.deleteBackwardOnEmptyField,
            moveHorizontally: { model.arrowsMoveSelection ? model.moveSelectionHorizontally($0) : false },
            jump: model.jumpSection, backtab: { _ = model.browseEnclosingFolder() }, tertiary: model.performTertiary,
            selectsAllOnFocus: model.selectsQueryOnFocus,
            didSelectAll: { model.selectsQueryOnFocus = false },
            readOnly: model.showsClipboardOptIn, fontSize: OR.scaled(20)
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var leading: some View {
        if let session = model.argumentSession {
            ScopeToken(
                kind: session.item.kind, symbol: session.item.symbol, title: session.item.title, style: .argument,
                onRemove: model.cancelArguments)
        } else if let link = model.argumentLink {
            ScopeToken(
                kind: .quicklink, symbol: "link", title: link.name, style: .argument,
                onRemove: { model.clearArgument(restoreKeyword: true) })
        } else if model.section != .home {
            ScopeToken(
                kind: model.section.kind, symbol: model.section.tileSymbol, title: model.section.title,
                onRemove: model.leaveScope)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(OR.Color.text2)
                .frame(width: 22)
                .accessibilityHidden(true)
        }
    }

    private var placeholder: String {
        if model.argumentLink != nil { return "Search term" }
        if model.showsClipboardOptIn { return "" }
        if model.section == .clipboard, !model.store.database.clipboard.isEmpty {
            let count = model.store.database.clipboard.count
            return "Search \(count.formatted()) item\(count == 1 ? "" : "s")"
        }
        return model.section.placeholder
    }

    @ViewBuilder private var accessories: some View {
        HStack(spacing: 8) {
            if let label = busyLabel {
                Spinner(accessibilityLabel: label)
            }
            if !model.query.isEmpty {
                ClearButton(label: "Clear search") {
                    model.query = ""
                    model.focusRequest += 1
                }
            }
            switch model.section {
            case _ where model.argumentSession != nil:
                HStack(spacing: 7) {
                    Text("Run").foregroundStyle(OR.Color.text2)
                    KeyCaps(["↩"])
                }
                .font(OR.Font.callout)
            case _ where model.argumentLink != nil:
                if !model.query.isEmpty {
                    HStack(spacing: 7) {
                        Text("Open in \(model.defaultBrowserName)").foregroundStyle(OR.Color.text2)
                        KeyCaps(["↩"])
                    }
                    .font(OR.Font.callout)
                }
            case .home where model.query.isEmpty:
                HStack(spacing: 7) {
                    Text("Ask AI").foregroundStyle(OR.Color.text2)
                    KeyCaps(["Tab"])
                }
                .font(OR.Font.callout)
            case .clipboard where !model.store.database.clipboard.isEmpty:
                DropdownMenu(
                    options: ClipboardFilter.allCases.map { ($0, $0.title) }, selection: $model.clipboardFilter,
                    accessibilityLabel: "Content type", symbol: { $0.symbol })
                    .accessibilityIdentifier("clipboard.filter")
            case .files:
                DropdownMenu(
                    options: FileSearchScope.allCases.map { ($0, $0.title) }, selection: $model.fileScope,
                    accessibilityLabel: "Search in", symbol: { $0.symbol })
            case .windows:
                TargetWindowChip(model: model)
            default:
                EmptyView()
            }
        }
    }

    /// What the field is waiting on, in words for VoiceOver. Nil when nothing is.
    private var busyLabel: String? {
        if model.files.isSearching, model.section == .files || model.section == .home, model.argumentLink == nil {
            return "Searching files"
        }
        if model.section == .applications, model.applications.isLoading { return "Loading applications" }
        if model.section == .clipboard, model.clipboard.isProcessing { return "Processing clipboard" }
        return nil
    }
}

/// Names the window a layout will apply to. Click it to choose another window.
struct TargetWindowChip: View {
    let model: LauncherModel

    var body: some View {
        // previousApplication isn't observed; reading its observed name first keeps the chip
        // and its icon in step when the target app changes.
        let name = model.previousApplicationName
        if let app = model.previousApplication, let url = app.bundleURL {
            let title = chipTitle(name ?? app.localizedName ?? "App")
            Menu {
                TargetWindowMenu(model: model)
            } label: {
                AttachmentChip(title) {
                    WorkspaceIcon(url: url, size: 16)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            // A menu keeps the items it built on its first open, so each show makes a
            // new one, and windows opened or closed while OpenRay was hidden are listed.
            .id(model.presentation)
            .help("Choose the window layouts apply to")
            .accessibilityLabel("Target window: \(title)")
        }
    }

    private func chipTitle(_ name: String) -> String {
        guard let title = model.targetWindowTitle, !title.isEmpty, title != name else { return name }
        let short = title.count > 34 ? String(title.prefix(32)) + "…" : title
        return "\(name) — \(short)"
    }
}

/// Every open window, grouped by app. Read from Accessibility when the menu is
/// first opened after each show.
private struct TargetWindowMenu: View {
    let model: LauncherModel

    private struct AppWindows: Identifiable {
        var pid: pid_t
        var windows: [WindowManager.TargetWindow]
        var id: pid_t { pid }
    }

    var body: some View {
        let apps = Self.grouped(model.windows.listWindows())
        if apps.isEmpty {
            Text(model.accessibilityAllowed ? "No other windows are open" : "Allow Accessibility to choose a window")
        } else {
            ForEach(apps) { app in
                Section {
                    ForEach(app.windows) { window in
                        Button {
                            model.selectTargetWindow(window)
                        } label: {
                            if let icon = Self.icon(for: window) {
                                Label { Text(Self.title(of: window)) } icon: { Image(nsImage: icon) }
                            } else {
                                Text(Self.title(of: window))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Keeps the order windows were listed in, with each app's windows together.
    private static func grouped(_ windows: [WindowManager.TargetWindow]) -> [AppWindows] {
        var apps: [AppWindows] = []
        var indexes: [pid_t: Int] = [:]
        for window in windows {
            if let index = indexes[window.pid] {
                apps[index].windows.append(window)
            } else {
                indexes[window.pid] = apps.count
                apps.append(AppWindows(pid: window.pid, windows: [window]))
            }
        }
        return apps
    }

    private static func title(of window: WindowManager.TargetWindow) -> String {
        guard !window.title.isEmpty, window.title != window.appName else { return window.appName }
        let short = window.title.count > 60 ? String(window.title.prefix(58)) + "…" : window.title
        return "\(window.appName) — \(short)"
    }

    /// Menus draw images at their own size, so the icon is a 16 pt copy.
    private static func icon(for window: WindowManager.TargetWindow) -> NSImage? {
        guard let url = window.bundleURL, let image = FileIconCache.shared.icon(for: url).copy() as? NSImage else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

/// The field when an editor is open: the scope token, a chevron and the editor title.
struct BreadcrumbBar: View {
    var kind: Kind
    var symbol: String?
    var scope: String
    var title: String
    var onScope: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScopeToken(kind: kind, symbol: symbol, title: scope, onRemove: onScope)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OR.Color.text3)
                .accessibilityHidden(true)
            Text(title).font(OR.Font.title).foregroundStyle(OR.Color.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: OR.Metric.field)
    }
}

/// The inline argument fields that replace the query while a command takes its arguments: Tab
/// and ⇧Tab move between them, ↩ runs, esc or ⌫ in the first empty field closes them.
struct ArgumentFieldsRow: View {
    @Bindable var model: LauncherModel
    let session: ArgumentSession

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(session.specs.enumerated()), id: \.element.name) { index, spec in
                ArgumentFieldWell(isFocused: session.focus == index) { field(spec, at: index) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func field(_ spec: ArgumentSpec, at index: Int) -> some View {
        let options: [ArgumentSpec.Option]? = if case .dropdown(let options) = spec.type { options } else { nil }
        let text = Binding<String>(
            get: {
                let value = model.argumentSession?.value(at: index) ?? ""
                return options.map { options in options.first { $0.value == value }?.title ?? "" } ?? value
            },
            set: { if options == nil { model.setArgumentValue($0, at: index) } })
        let focused = session.focus == index
        return LauncherSearchInput(
            text: text, placeholder: spec.placeholder + (spec.isOptional ? " (optional)" : ""),
            focusRequest: focused ? session.focusToken : -1,
            submit: model.submitArguments,
            move: { offset in if options != nil { model.cycleArgumentOption(offset, at: index) } },
            cancel: model.goBack, paste: model.submitArguments,
            tab: { model.moveArgumentFocus(1) }, deleteOnEmpty: model.deleteBackwardInArguments,
            moveHorizontally: { options != nil ? model.cycleArgumentOption($0, at: index) : false },
            backtab: { model.moveArgumentFocus(-1) },
            autoFocus: focused, secure: spec.type == .password, onFocus: { model.argumentFieldDidFocus(index) },
            readOnly: options != nil,
            fontSize: OR.scaled(15), accessibilityLabel: spec.placeholder + (spec.isOptional ? ", optional" : ""),
            identifier: "argument.\(spec.name)")
    }
}
