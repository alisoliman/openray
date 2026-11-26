import AppKit
import SwiftUI

extension SettingsPane {
    static let commands = SettingsPane(
        id: "commands", title: "Commands",
        subtitle: "Every command, by where it comes from: turn it off, give it an alias or a shortcut.",
        kind: .command, symbol: "square.grid.3x3",
        keywords: "extensions commands enable disable turn off configure preferences fallback fallbacks alias hotkey"
    ) { model, navigation in AnyView(CommandsPane(model: model, navigation: navigation)) }
}

/// The command catalog: fallbacks first, then each source's commands with an on/off switch,
/// an alias, a shortcut and any preferences the command stores.
struct CommandsPane: View {
    @Bindable var model: LauncherModel
    @Bindable var navigation: SettingsNavigation
    @State private var highlightedCommandID: String?

    var body: some View {
        ScrollViewReader { proxy in
            SettingsPaneScaffold(pane: .commands) {
                FallbacksSection(model: model)
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.commands) { command in
                            CommandCatalogRow(model: model, command: command, isFocusTarget: highlightedCommandID == command.id)
                                .id(command.id)
                        }
                    }
                }
            }
            .onAppear { focusRequestedCommand(proxy) }
            .onChange(of: navigation.focusCommandID) { focusRequestedCommand(proxy) }
        }
    }

    /// Built-in commands, then each provider's, in registration order. While searching, only
    /// matching commands; every command when none match, because then the pane itself matched.
    private var groups: [(title: String, commands: [LauncherItem])] {
        let all = model.commandCatalog
        let query = navigation.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        let filtered = all.map { group in
            (group.title, group.commands.filter {
                SettingsSearch.wordPrefixScore(query, in: model.settingsSearchText(for: $0)) != nil
            })
        }
        .filter { !$0.1.isEmpty }
        return filtered.isEmpty ? all : filtered.map { (title: $0.0, commands: $0.1) }
    }

    private func focusRequestedCommand(_ proxy: ScrollViewProxy) {
        guard let id = navigation.focusCommandID else { return }
        navigation.focusCommandID = nil
        guard model.commandCatalog.contains(where: { $0.commands.contains { $0.id == id } }) else { return }
        if !groups.contains(where: { $0.commands.contains { $0.id == id } }) { navigation.search = "" }
        Task { @MainActor in
            proxy.scrollTo(id, anchor: .center)
            highlightedCommandID = id
            try? await Task.sleep(for: .seconds(1.6))
            if highlightedCommandID == id { highlightedCommandID = nil }
        }
    }
}

/// One command: its switch, then its alias and shortcut when it can hold them, then its
/// stored preferences.
struct CommandCatalogRow: View {
    let model: LauncherModel
    let command: LauncherItem
    var isFocusTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.isCommandEnabled(command.id) },
                    set: { model.setCommand(command.id, enabled: $0) })
                ) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .settingsSwitch()
                .accessibilityLabel("\(command.title) enabled")
                .accessibilityIdentifier("commands.enabled.\(command.id)")
                if model.canBind(command) {
                    CommandBindingRow(model: model, command: command, isFocusTarget: isFocusTarget)
                } else {
                    HStack(spacing: 8) {
                        KindTile(kind: command.kind, symbol: command.symbol, size: 18)
                        Text(command.title).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .opacity(model.isCommandEnabled(command.id) ? 1 : 0.55)
            let preferences = model.store.database.commandPreferences[command.id] ?? [:]
            ForEach(preferences.keys.sorted(), id: \.self) { key in
                CommandPreferenceField(model: model, commandID: command.id, key: key)
                    .padding(.leading, 46)
            }
        }
    }
}

/// A stored per-command value, edited as text and saved on Return or when the field loses focus.
struct CommandPreferenceField: View {
    let model: LauncherModel
    let commandID: String
    let key: String
    @State private var value = ""

    var body: some View {
        LabeledContent(key) {
            TextField(key, text: $value)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(save)
        }
        .font(.system(size: 12))
        .onAppear { value = model.store.database.commandPreferences[commandID]?[key] ?? "" }
        .onDisappear(perform: save)
    }

    private func save() {
        guard model.store.database.commandPreferences[commandID]?[key] != value else { return }
        model.store.update { $0.commandPreferences[commandID, default: [:]][key] = value }
    }
}

/// Fallback Commands: the rows under “Use … with” when a search finds nothing better, in order.
struct FallbacksSection: View {
    let model: LauncherModel

    var body: some View {
        let enabled = model.enabledFallbackIDs
        let candidates = model.fallbackCandidates
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        Section {
            ForEach(Array(enabled.enumerated()), id: \.element) { index, id in
                if let candidate = byID[id] {
                    HStack(spacing: 8) {
                        KindTile(kind: candidate.kind, symbol: candidate.symbol, size: 18)
                        Text(candidate.title).lineLimit(1)
                        Spacer()
                        Button { model.moveFallback(id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(candidate.title) up")
                        Button { model.moveFallback(id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == enabled.count - 1)
                            .accessibilityLabel("Move \(candidate.title) down")
                        Button { model.setFallback(id, enabled: false) } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove \(candidate.title) from fallbacks")
                    }
                    .buttonStyle(.borderless)
                }
            }
            let available = candidates.filter { !enabled.contains($0.id) }
            HStack {
                Menu("Add Fallback") {
                    ForEach(available) { candidate in
                        Button(candidate.title) { model.setFallback(candidate.id, enabled: true) }
                    }
                }
                .neutralMenus()
                .disabled(available.isEmpty)
                .fixedSize()
                Spacer()
                if model.usesCustomFallbacks {
                    Button("Restore Defaults") { model.resetFallbacks() }
                }
            }
        } header: {
            HStack {
                Text("Fallback Commands")
                Spacer()
                Text("Offered for any search, in this order").fontWeight(.regular)
            }
        }
    }
}

extension LauncherModel {
    /// Every command for the catalog, disabled ones included: built-in commands, then each
    /// registered provider's (shown and hidden), in registration order.
    var commandCatalog: [(title: String, commands: [LauncherItem])] {
        let builtIn = commandItems.filter { item in
            if case .provided = item.action { return false }
            return isDisableable(item)
        }
        var groups: [(title: String, commands: [LauncherItem])] = [("Built-in", builtIn)]
        for provider in registry.providers {
            let commands = provider.commands(in: self).map(provider.item(for:))
            if !commands.isEmpty { groups.append((provider.title, commands)) }
        }
        return groups
    }
}
