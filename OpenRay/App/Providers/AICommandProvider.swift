import AppKit
import SwiftUI

/// AI Commands and the AI window, served through the command registry: each AI Command is
/// a command (`aicommand.<uuid>` for the person's own, `aicommand.<name>` for the added
/// built-ins), bindable to an alias or hotkey through the `aicommand.` namespace. Also Quick
/// Fix, AI Chat, Search AI Commands, and the editors.
@MainActor
final class AICommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "aicommand", bindablePrefixes: ["aicommand."]) {
        AICommandProvider()
    }

    nonisolated static let chatID = "aicommand.chat"
    nonisolated static let quickFixID = "aicommand.quickFix"
    nonisolated static let createID = "aicommand.create"
    nonisolated static let searchID = "aicommand.search"
    nonisolated static let createAgentID = "aicommand.createAgent"

    static let scope = ProvidedScope(
        id: "aicommand.list", provider: "aicommand", title: "AI Commands", symbol: "sparkles", kind: .ai,
        placeholder: "Search AI Commands", summary: "Built-in and custom AI Commands", shortTitle: "AI Commands",
        itemNoun: "AI command", showsPreview: true)

    var id: String { Self.registration.id }
    var title: String { "AI" }

    /// Argument fields per prompt, so building rows on every keystroke doesn't re-parse. Prompts
    /// that reference snippets aren't cached: their fields follow the snippets.
    private var argumentCache: [String: [ArgumentSpec]] = [:]

    init() {}

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        let hub = model.aiHub
        let available = model.ai.availability.isAvailable
        var commands = hub.aiCommands.map { command in descriptor(for: command, available: available, in: model) }
        commands += [
            CommandDescriptor(
                id: Self.chatID, title: "AI Chat", subtitle: "Saved chats in their own window", kind: .ai,
                symbol: "bubble.left.and.text.bubble.right", keywords: ["AI", "chat", "conversation", "history", "window"],
                mode: .noView, badge: "Command"),
            CommandDescriptor(
                id: Self.quickFixID, title: "Quick Fix",
                subtitle: available ? "Runs \(quickFixTitle(in: hub)) in place on your text" : "Not available yet", kind: .ai,
                symbol: "wand.and.stars", keywords: ["AI", "fix", "selection", "grammar", "hotkey"],
                // It replaces text in the app you're in, with no window (work item 8).
                mode: .noView, badge: "AI command", isUnavailable: !available && !quickFixIsTranslation(in: hub)),
            CommandDescriptor(
                id: Self.createID, title: "Create AI Command", subtitle: "A prompt you can run on any text", kind: .ai,
                symbol: "plus.bubble", keywords: ["AI", "new", "prompt", "custom"], mode: .noView, badge: "Command",
                // Kept out of root search to leave room in Home's capped list; ⌘K in Search AI
                // Commands, Settings, favorites and hotkeys still reach it.
                showsInRoot: false),
            CommandDescriptor(
                id: Self.searchID, title: "Search AI Commands", subtitle: "Run, edit, duplicate or share them", kind: .ai,
                symbol: "sparkle.magnifyingglass", keywords: ["AI", "commands", "prompts", "import", "export"],
                mode: .view(.provided(Self.scope)), badge: "Command"),
            CommandDescriptor(
                id: Self.createAgentID, title: "Create Agent", subtitle: "Instructions and tools for AI Chat", kind: .ai,
                symbol: "person.crop.circle.badge.plus", keywords: ["AI", "agent", "preset", "persona", "instructions"],
                mode: .noView, badge: "Command", showsInRoot: false),
        ]
        return commands
    }

    private func descriptor(for command: AICommand, available: Bool, in model: LauncherModel) -> CommandDescriptor {
        let usable = available || command.performer != .model
        return CommandDescriptor(
            id: command.id, title: command.name,
            subtitle: usable ? LauncherModel.aiCommandSubtitle : "Not available yet", kind: .ai, symbol: command.symbol,
            keywords: ["AI", "command", command.subtitle].filter { !$0.isEmpty }, arguments: arguments(for: command, in: model),
            mode: .ai, badge: "AI command", detail: usable && !command.subtitle.isEmpty ? command.subtitle : nil,
            isUnavailable: !usable)
    }

    /// The fields a command asks for, planned with the same snippet lookup it runs with, so
    /// arguments inside referenced snippets get fields too.
    func arguments(for command: AICommand, in model: LauncherModel) -> [ArgumentSpec] {
        let template = command.template
        if template.placeholders.contains(where: { $0.kind == .snippet }) {
            return template.plan(snippets: PlaceholderValues.snippetLookup(model.store.database)).argumentSpecs
        }
        if let cached = argumentCache[command.prompt] { return cached }
        let specs = template.plan(snippets: { _ in nil }).argumentSpecs
        if argumentCache.count > 200 { argumentCache.removeAll() }
        argumentCache[command.prompt] = specs
        return specs
    }

    private func quickFixTitle(in hub: AIHub) -> String {
        hub.quickFixChoices.first { $0.id == hub.settings.quickFixCommandID }?.title ?? AIAction.proofread.title
    }

    private func quickFixIsTranslation(in hub: AIHub) -> Bool {
        let id = hub.settings.quickFixCommandID
        return hub.aiCommands.first { $0.id == id }.map { $0.performer != .model } ?? false
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        let hub = model.aiHub
        switch ref.id {
        case Self.chatID:
            model.store.recordUse(of: item.id)
            hub.openChatWindow()
        case Self.quickFixID:
            model.store.recordUse(of: item.id)
            let target = hub.settings.quickFixCommandID
            // A target that needs a value opens its fields first, then runs on the selection.
            if let targetItem = model.bindableCommands.first(where: { $0.id == target }), model.needsArguments(targetItem) {
                model.panel?.show()
                model.beginArguments(for: targetItem)
                return
            }
            model.runQuickFix()
        case Self.createID:
            model.store.recordUse(of: item.id)
            hub.requestEditor(.newCommand)
        case Self.createAgentID:
            model.store.recordUse(of: item.id)
            hub.requestEditor(.newAgent)
        default:
            // Rows in Search AI Commands carry the command's own id, so the registry fills
            // their arguments through the same fields as a root search does.
            let commandID = ref.payload ?? ref.id
            // A choice such as Change Tone's tone is asked first, with its default picked, and
            // the command runs on ↵ in the fields (work item 1). The registry fills defaults into
            // `ref`, so the row's own values tell whether the fields were shown.
            // Only a choice that always resolves to a value (its default, or a required first
            // option), so the fields can't come back after ↵.
            let choices = model.argumentSpecs(for: item).filter { spec in
                if case .dropdown = spec.type { spec.defaultValue != nil || !spec.isOptional } else { false }
            }
            if case .provided(let row) = item.action, choices.contains(where: { row.arguments[$0.name] == nil }),
                model.beginArguments(for: item)
            {
                return
            }
            model.store.recordUse(of: commandID)
            run(commandID: commandID, arguments: ref.arguments, in: model)
        }
    }

    /// Runs a command by id: an original writing command, an added built-in or a custom one.
    /// Placeholders are read now, after the arguments validate; `{selection}` uses the ⌘C
    /// fallback when Accessibility sees no selection, so the run can wait for it. A custom
    /// command set to Replace Selection runs in place with no window.
    func run(commandID: String, arguments: [String: String], in model: LauncherModel) {
        if let action = AIWritingCommandProvider.writingActions.first(where: { "ai.\($0.id)" == commandID }) {
            model.openAI(action)
            return
        }
        guard let command = model.aiHub.aiCommands.first(where: { $0.id == commandID }) else {
            model.feedback = .error("That AI Command no longer exists. Choose another in Settings › Apple Intelligence.")
            return
        }
        let plan = command.template.plan(snippets: PlaceholderValues.snippetLookup(model.store.database))
        if let issue = plan.blockingIssues.first {
            model.feedback = .warning(issue.message)
            return
        }
        let resolved: [PlaceholderArgument.ID: String]
        do { resolved = try plan.resolveArguments(arguments) } catch {
            model.feedback = .warning(error.localizedDescription)
            return
        }
        guard plan.requirements.selection, model.readsSelectionImplicitly else {
            render(command, plan: plan, arguments: resolved, in: model)
            return
        }
        // A copy fallback answers later; by then the person may have moved on.
        let destination = model.destination
        let conversation = model.ai.conversationToken
        model.resolveSelection { [weak model] result in
            guard let model, model.destination == destination, model.ai.conversationToken == conversation else { return }
            switch result {
            case .success(let selection):
                self.render(command, plan: plan, arguments: resolved, selection: selection, in: model)
            case .failure(let error):
                self.render(command, plan: plan, arguments: resolved, selectionFailure: error, in: model)
            }
        }
    }

    private func render(
        _ command: AICommand, plan: PlaceholderPlan, arguments: [PlaceholderArgument.ID: String],
        selection: SelectedTextContext? = nil,
        selectionFailure: (any Error)? = nil, in model: LauncherModel
    ) {
        var values = model.placeholderValues(for: plan, selection: selection, readsSelection: selectionFailure == nil)
        values.arguments = arguments
        do {
            let run = try AICommandRenderer.render(
                command, plan: plan, values: values, capabilities: model.ai.capabilities,
                sourceAppName: selection?.sourceName ?? model.previousApplicationName)
            // In place needs the selection's exact place; a copied one opens in OpenRay, where ↵
            // can still paste over it.
            if run.replacesInPlace, let selection = model.lastCapturedSelection, selection.canReplace {
                model.runInPlace(command: run, on: .selection(selection), title: command.name)
            } else {
                model.openAI(command: run)
            }
        } catch AICommandError.noText where selectionFailure != nil {
            // Say why there was no selection, such as “Nothing selected in Notes.”
            model.feedback = .warning(
                "\(selectionFailure?.localizedDescription ?? "") Select some text, or copy it, then run the command again.")
        } catch {
            model.feedback = .warning(error.localizedDescription)
        }
    }

    // MARK: The AI Commands scope

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.scope.id else { return [] }
        let hub = model.aiHub
        let originals = AIWritingCommandProvider.writingActions.map(AICommand.writingTemplate)
        // Each row is its command: the same id for favorites, usage, bindings and argument fields.
        return (originals + hub.aiCommands).map { command in
            LauncherItem(
                id: command.id, title: command.name,
                subtitle: command.isBuiltIn ? "Built-in · \(command.subtitle)" : command.output.title,
                symbol: command.symbol, kind: .ai, badge: command.isBuiltIn ? "Built-in" : "Custom",
                keywords: command.subtitle,
                action: .provided(
                    ProvidedRef(
                        provider: id, id: command.id, payload: command.id, primaryTitle: "Run Command",
                        traits: command.isBuiltIn ? [.favorite] : [.favorite, .edit, .delete])))
        }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        ProvidedEmptyState(
            title: query.isEmpty ? "No AI Commands yet" : "No AI Commands match “\(query)”",
            detail: "Run Create AI Command, or import a JSON export from ⌘K.", symbol: "sparkles")
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.payload == nil ? nil : "Run Command"
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { "sparkles" }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.payload == nil ? nil : "Duplicate"
    }

    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let command = command(for: ref, in: model) else { return }
        if let copy = model.aiHub.duplicate(command) {
            model.toast("Duplicated as “\(copy.name)”")
            model.aiHub.requestEditor(.command(copy.id))
        }
    }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        guard let command = command(for: ref, in: model) else { return [] }
        let hub = model.aiHub
        var entries: [ActionEntry] = []
        if hub.settings.quickFixCommandID != command.id {
            entries.append(
                ActionEntry(id: "aicommand.quickFix", title: "Use for Quick Fix", symbol: "wand.and.stars", group: .organize) {
                    [weak model] in
                    guard let model else { return }
                    if model.aiHub.updateSettings({ $0.quickFixCommandID = command.id }) {
                        model.toast("Quick Fix runs “\(command.name)”")
                    }
                })
        }
        entries.append(
            ActionEntry(id: "aicommand.new", title: "Create AI Command…", symbol: "plus.bubble", group: .panel) {
                [weak model] in model?.aiHub.requestEditor(.newCommand)
            })
        entries.append(
            ActionEntry(id: "aicommand.newAgent", title: "Create Agent…", symbol: "person.crop.circle.badge.plus", group: .panel) {
                [weak model] in model?.aiHub.requestEditor(.newAgent)
            })
        entries.append(
            ActionEntry(id: "aicommand.import", title: "Import AI Commands…", symbol: "square.and.arrow.down", group: .panel) {
                [weak model] in model.map(AICommandFiles.importCommands)
            })
        if hub.aiCommands.contains(where: { !$0.isBuiltIn }) {
            entries.append(
                ActionEntry(id: "aicommand.export", title: "Export AI Commands…", symbol: "square.and.arrow.up", group: .panel) {
                    [weak model] in model.map(AICommandFiles.exportCommands)
                })
        }
        return entries
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        guard let command = command(for: ref, in: model) else { return nil }
        var metadata: [(label: String, value: String)] = [
            ("Output Behavior", command.output.title), ("Creativity", command.creativity.title),
        ]
        if command.performer != .model { metadata = [("Runs with", "Apple Translation")] }
        if let reasoning = command.reasoning { metadata.append(("Reasoning", reasoning.title)) }
        metadata.append(("Guardrail", command.guardrail.title))
        return ProvidedPreview(
            content: AnyView(
                Text(command.prompt).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(OR.Color.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)),
            metadata: metadata)
    }

    func itemNoun(for ref: ProvidedRef) -> String { "AI Command" }

    func deletion(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedDeletion? {
        guard let command = command(for: ref, in: model), let recordID = command.recordID else { return nil }
        return .store { [weak model] in
            guard let model else { return false }
            let saved = model.store.update { database in
                database.aiCommands.removeAll { $0.id == recordID }
                // Its alias and hotkey go with it.
                database.commandBindings.removeAll { $0.targetID == command.id }
                var settings = AISettings(database: database)
                if settings.quickFixCommandID == command.id { settings.quickFixCommandID = "ai.proofread" }
                settings.write(into: &database)
            }
            if saved {
                model.commandCatalogDidChange()
            } else {
                model.feedback = .error(model.store.errorMessage ?? "The AI Command couldn't be deleted.")
            }
            return saved
        }
    }

    func edit(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let command = command(for: ref, in: model), !command.isBuiltIn else { return }
        model.aiHub.requestEditor(.command(command.id))
    }

    private func command(for ref: ProvidedRef, in model: LauncherModel) -> AICommand? {
        guard let commandID = ref.payload else { return nil }
        if let action = AIWritingCommandProvider.writingActions.first(where: { "ai.\($0.id)" == commandID }) {
            return AICommand.writingTemplate(action)
        }
        return model.aiHub.aiCommands.first { $0.id == commandID }
    }
}

/// Open and save panels for AI Command JSON. They never appear in the test host.
@MainActor
enum AICommandFiles {
    static func importCommands(_ model: LauncherModel) {
        guard !SideEffectGuard.isInert else {
            model.feedback = .info("Importing is off in this instance.")
            return
        }
        model.panel?.dismiss(restoreFocus: false)
        let panel = NSOpenPanel()
        panel.title = "Import AI Commands"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try model.aiHub.importCommands(from: Data(contentsOf: url))
            model.panel?.show()
            model.toast(result.summary)
        } catch {
            model.panel?.show()
            model.feedback = .error(error.localizedDescription)
        }
    }

    static func exportCommands(_ model: LauncherModel) {
        guard !SideEffectGuard.isInert else {
            model.feedback = .info("Exporting is off in this instance.")
            return
        }
        model.panel?.dismiss(restoreFocus: false)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OpenRay AI Commands.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.aiHub.exportCommands().write(to: url, options: .atomic)
        } catch {
            model.panel?.show()
            model.feedback = .error("The AI Commands couldn't be exported. \(error.localizedDescription)")
        }
    }
}
