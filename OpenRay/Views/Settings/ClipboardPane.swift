import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsPane {
    static let clipboard = SettingsPane(
        id: "clipboard", title: "Clipboard",
        subtitle: "What OpenRay keeps from your clipboard, and for how long.",
        kind: .clipboard, symbol: "list.clipboard",
        keywords: "history capture pause retention days entries exclude apps password delete storage images files"
    ) { model, _ in AnyView(ClipboardPane(model: model)) }
}

struct ClipboardPane: View {
    @Bindable var model: LauncherModel
    @State private var confirmClear = false
    @State private var confirmOff = false

    enum CaptureState: Hashable { case on, paused, off }

    var body: some View {
        let preferences = model.store.database.preferences
        let entries = model.store.database.clipboard
        let bytes = entries.reduce(0) { $0 + $1.byteCount }
        SettingsPaneScaffold(
            pane: .clipboard,
            subtitle: entries.isEmpty
                ? "What OpenRay keeps from your clipboard, and for how long."
                : "\(entries.count.formatted()) entr\(entries.count == 1 ? "y" : "ies") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(ClipboardLimits.historyBytes), countStyle: .file))"
        ) {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    SettingRowLabel(
                        title: "Save clipboard history",
                        detail: "Paused keeps history searchable. Off asks whether to delete it.")
                    Spacer()
                    SegmentedPicker(
                        options: [(CaptureState.on, "On"), (.paused, "Paused"), (.off, "Off")], selection: captureBinding,
                        accessibilityLabel: "Save clipboard history")
                }
                // What gets captured only matters while capturing.
                let isOff = captureBinding.wrappedValue == .off
                Toggle(isOn: model.optionalPreference(\.clipboardImagesEnabled)) {
                    SettingRowLabel(title: "Include images", detail: "PNG, up to 10 MB each")
                }
                .settingsSwitch()
                .disabled(isOff)
                Toggle(isOn: model.optionalPreference(\.clipboardFilesEnabled)) {
                    SettingRowLabel(title: "Include files", detail: "References only. Originals are never copied or changed.")
                }
                .settingsSwitch()
                .disabled(isOff)
                LabeledContent {
                    HStack {
                        Picker("Days", selection: model.preference(\.clipboardRetentionDays)) {
                            Text("1 day").tag(1)
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                        }
                        .labelsHidden().fixedSize()
                        Picker("Entries", selection: model.preference(\.clipboardLimit)) {
                            ForEach([50, 100, 250, 500], id: \.self) { Text("\($0) entries").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    .neutralMenus()
                } label: {
                    SettingRowLabel(title: "Keep entries for")
                }
                // Retention still prunes saved history while capture is off.
                .disabled(isOff && entries.isEmpty)
                if let note = model.clipboard.accessMessage {
                    Label(note, systemImage: "hand.raised.fill").font(.system(size: 12)).foregroundStyle(OR.Color.warning)
                }
            } footer: {
                Text("Pinned entries are kept until you unpin or delete them. Everything stays within the 64 MB history budget.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ExclusionsSection(model: model)
            Section {
                HStack {
                    Spacer()
                    Button("Delete All History…", role: .destructive) { confirmClear = true }
                        .disabled(entries.isEmpty)
                }
            }
        }
        .confirmationDialog("Delete all clipboard history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete All History", role: .destructive) { deleteAllHistory() }
        } message: {
            Text(deleteAllMessage(entries))
        }
        .confirmationDialog("Turn off clipboard history?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("Delete History and Turn Off", role: .destructive) {
                setCapture(enabled: false, paused: false)
                model.clipboard.clearHistory()
            }
            Button("Keep History (Pause)") { setCapture(enabled: false, paused: true) }
        } message: {
            Text(turnOffMessage(entries))
        }
        .onChange(of: preferences.clipboardEnabled) { model.clipboard.refreshAccessStatus() }
    }

    /// Reads the stored Paused state, so pruning or deleting history while paused doesn't show Off.
    private var captureBinding: Binding<CaptureState> {
        Binding(
            get: {
                let database = model.store.database
                if database.preferences.clipboardEnabled { return .on }
                return database.clipboardIsPaused ? .paused : .off
            },
            set: { state in
                switch state {
                case .on: setCapture(enabled: true, paused: false)
                case .paused: setCapture(enabled: false, paused: true)
                case .off:
                    if model.store.database.clipboard.isEmpty {
                        setCapture(enabled: false, paused: false)
                    } else {
                        confirmOff = true
                    }
                }
            })
    }

    private func setCapture(enabled: Bool, paused: Bool) {
        if model.store.update({
            $0.preferences.clipboardEnabled = enabled
            $0.preferences.clipboardPaused = paused
        }) {
            model.applyPreferences()
        }
    }

    /// A pause inferred from saved history stays Paused; LibraryStore records it as the history goes.
    private func deleteAllHistory() {
        model.clipboard.clearHistory()
    }

    private func deleteAllMessage(_ entries: [ClipboardEntry]) -> String {
        let pinned = entries.filter(\.isPinned).count
        guard pinned > 0 else {
            return "This removes the saved history from OpenRay. Your current clipboard stays as it is."
        }
        return "This removes the saved history from OpenRay, including \(Self.entryPhrase(pinned, "pinned")). "
            + "Your current clipboard stays as it is."
    }

    private func turnOffMessage(_ entries: [ClipboardEntry]) -> String {
        let pinned = entries.filter(\.isPinned).count
        let saved = "\(Self.entryPhrase(entries.count, "saved")) \(entries.count == 1 ? "is" : "are") still on this Mac."
        return pinned > 0 ? saved + " This also deletes \(Self.entryPhrase(pinned, "pinned"))." : saved
    }

    /// "1 pinned entry", "3 pinned entries".
    private static func entryPhrase(_ count: Int, _ adjective: String) -> String {
        "\(count.formatted()) \(adjective) entr\(count == 1 ? "y" : "ies")"
    }
}

/// Exclusions use an app picker. Built-in exclusions are listed and locked.
struct ExclusionsSection: View {
    let model: LauncherModel

    var body: some View {
        // Built-ins always apply, even when an older library's stored list dropped them.
        let ids = model.store.database.preferences.effectiveClipboardExclusions
        // Rows of the group itself, as System Settings lists login items, not a list boxed inside it.
        Section {
            ForEach(ids, id: \.self) { id in
                let name = displayName(for: id)
                HStack(spacing: 10) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        WorkspaceIcon(url: url, size: 20)
                        Text(name)
                    } else if Self.knownNames[id] != nil {
                        Image(systemName: "lock.square").font(.system(size: 16)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                        Text(name)
                        Text("Not installed").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 20, height: 20)
                        Text(id).font(.system(size: 12, design: .monospaced))
                    }
                    Spacer()
                    if AppPreferences.builtInClipboardExclusions.contains(id) {
                        Label("Always excluded", systemImage: "lock.fill").labelStyle(TightLabelStyle())
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Button("Remove") { remove(id) }
                            .accessibilityLabel("Remove \(name)")
                    }
                }
            }
            Button { addApp() } label: { Label("Add App…", systemImage: "plus") }
                .buttonStyle(.borderless)
        } header: {
            Text("Never save from these apps")
        } footer: {
            Text("Copies made in these apps are never captured, and snippets don't expand there.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    static let knownNames = [
        "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden", "com.apple.Passwords": "Passwords", "org.keepassxc.keepassxc": "KeePassXC",
    ]

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to exclude"
        panel.prompt = "Exclude"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !added.isEmpty else { return }
        if model.store.update({
            $0.preferences.excludedClipboardBundleIDs = Array(
                NSOrderedSet(array: $0.preferences.excludedClipboardBundleIDs + added)) as? [String] ?? []
        }) {
            model.applyPreferences()
        }
    }

    private func displayName(for id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return Self.knownNames[id] ?? id
    }

    private func remove(_ id: String) {
        guard !AppPreferences.builtInClipboardExclusions.contains(id) else { return }
        if model.store.update({ $0.preferences.excludedClipboardBundleIDs.removeAll { $0 == id } }) {
            model.applyPreferences()
        }
    }
}
