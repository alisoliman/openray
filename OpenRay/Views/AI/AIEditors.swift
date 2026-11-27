import AppKit
import Observation
import SwiftUI

/// The editor window for AI Commands and agents: a form, as design gap §6 asks, drawn with
/// the native grouped form the Settings window uses.
final class AIEditorWindowController: AuxiliaryWindowController {
    let state = AIEditorState()

    override func makeRootView() -> AnyView {
        AnyView(AIEditorRoot(model: model, state: state) { [weak self] in self?.window?.close() })
    }
    override var title: String { "AI Editor" }
    override var initialSize: NSSize { NSSize(width: 600, height: 640) }
    override var minimumSize: NSSize { NSSize(width: 520, height: 480) }
    override var identifier: String { "openray.aieditor" }

    func show(_ request: AIEditorRequest) {
        state.open(request)
        showWindow()
        window?.title =
            switch request {
            case .newCommand: "New AI Command"
            case .command: "Edit AI Command"
            case .newAgent: "New Agent"
            case .agent: "Edit Agent"
            }
    }
}

@MainActor
@Observable
final class AIEditorState {
    private(set) var request: AIEditorRequest = .newCommand
    /// Changes on every open, so the form reloads even for the same request.
    private(set) var generation = 0

    func open(_ request: AIEditorRequest) {
        self.request = request
        generation += 1
    }
}

struct AIEditorRoot: View {
    let model: LauncherModel
    let state: AIEditorState
    var close: () -> Void

    var body: some View {
        Group {
            switch state.request {
            case .newCommand:
                AICommandEditor(model: model, original: nil, close: close)
            case .command(let id):
                AICommandEditor(model: model, original: model.aiHub.aiCommands.first { $0.id == id }, close: close)
            case .newAgent:
                AgentEditor(model: model, original: nil, close: close)
            case .agent(let id):
                AgentEditor(model: model, original: model.aiHub.agent(id: id), close: close)
            }
        }
        .id(state.generation)
    }
}

// MARK: - AI Command

struct AICommandEditor: View {
    let model: LauncherModel
    let original: AICommand?
    var close: () -> Void
    @State private var command: AICommand
    @State private var problem: String?

    init(model: LauncherModel, original: AICommand?, close: @escaping () -> Void) {
        self.model = model
        self.original = original
        self.close = close
        // A new command opens in OpenRay, as Raycast's do; Replace Selection is a choice below.
        _command = State(
            initialValue: original
                ?? AICommand(
                    id: "", name: "", symbol: "sparkles",
                    prompt: "Rewrite the following text so it's friendlier.\n\n{selection}", creativity: .low,
                    guardrail: .permissive, output: .show))
    }

    private var isBuiltIn: Bool { original?.isBuiltIn == true }

    var body: some View {
        let arguments = command.template.plan(snippets: { _ in "" }).arguments
        VStack(spacing: 0) {
            Form {
                if isBuiltIn {
                    Section {
                        Label("Built-in commands can't be changed. Duplicate it to make your own version.", systemImage: "info.circle")
                    }
                }
                Section {
                    TextField("Name", text: $command.name, prompt: Text("Make Friendlier"))
                    LabeledContent("Icon") {
                        HStack {
                            Image(systemName: command.symbol).frame(width: 20)
                            TextField("Icon", text: $command.symbol, prompt: Text("SF Symbol name")).labelsHidden()
                        }
                    }
                }
                Section {
                    TextEditor(text: $command.prompt)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(minHeight: 140)
                        .accessibilityLabel("Prompt")
                } header: {
                    Text("Prompt")
                } footer: {
                    Text(
                        "Use {selection} for the selected text, {clipboard} for the clipboard, {argument name=\"tone\" options=\"Formal, Casual\"} for a value you choose when it runs, and {date} for today. Supplied text reaches the model fenced as data."
                    )
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if !arguments.isEmpty {
                    Section("Asks for") {
                        ForEach(arguments) { argument in
                            LabeledContent(argument.title) {
                                Text(argument.options.isEmpty ? (argument.defaultValue ?? "Typed when it runs") : argument.options.joined(separator: ", "))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Section {
                    Picker("Output Behavior", selection: $command.output) {
                        ForEach(AICommandOutput.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Creativity", selection: $command.creativity) {
                        ForEach(AICreativity.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Reasoning", selection: $command.reasoning) {
                        Text("Default").tag(AIReasoningLevel?.none)
                        ForEach(AIReasoningLevel.allCases) { Text($0.title).tag(AIReasoningLevel?.some($0)) }
                    }
                    .disabled(!model.ai.capabilities.contains(.reasoning))
                    .help(model.ai.capabilities.contains(.reasoning) ? "" : "This Mac's model doesn't offer reasoning levels.")
                    Picker("Guardrail", selection: $command.guardrail) {
                        ForEach(AIGuardrail.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Output")
                } footer: {
                    Text(
                        command.output == .replace
                            ? "Replace Selection writes the result over the selected text with no window, once OpenRay checks the selection hasn't changed. If it has, the result is copied instead."
                            : "Open in OpenRay shows the result in the launcher, where Return pastes it into the app you came from."
                    )
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isBuiltIn)
            .neutralMenus()
            footer
        }
    }

    private var footer: some View {
        HStack {
            if let problem = problem ?? (isBuiltIn ? nil : command.validationMessage) {
                Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(OR.Color.warning)
                    .font(OR.Font.callout).lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            if isBuiltIn, let original {
                Button("Duplicate") {
                    if let copy = model.aiHub.duplicate(original) { model.aiHub.requestEditor(.command(copy.id)) }
                }
                .buttonStyle(.borderedProminent).tint(OR.Color.accentButton)
            } else {
                Button("Save") {
                    if model.aiHub.save(command) {
                        close()
                    } else {
                        problem = command.validationMessage ?? model.store.errorMessage ?? "The command couldn't be saved."
                    }
                }
                .buttonStyle(.borderedProminent).tint(OR.Color.accentButton)
                .keyboardShortcut(.defaultAction)
                .disabled(command.validationMessage != nil)
            }
        }
        .padding(14)
    }
}

// MARK: - Agent

struct AgentEditor: View {
    let model: LauncherModel
    let original: Agent?
    var close: () -> Void
    @State private var agent: Agent
    @State private var isDefault: Bool
    @State private var tokens: Int?
    @State private var contextSize: Int?
    @State private var problem: String?

    init(model: LauncherModel, original: Agent?, close: @escaping () -> Void) {
        self.model = model
        self.original = original
        self.close = close
        _agent = State(initialValue: original ?? Agent(name: "", instructions: ""))
        _isDefault = State(initialValue: original != nil && model.aiHub.settings.defaultAgentID == original?.id)
    }

    var body: some View {
        let extensions = model.aiHub.toolExtensions
        VStack(spacing: 0) {
            Form {
                if agent.isAssistant {
                    Section { Label("The assistant is built in and can't be changed.", systemImage: "info.circle") }
                }
                Section {
                    TextField("Name", text: $agent.name, prompt: Text("Writing Coach"))
                    LabeledContent("Icon") {
                        HStack {
                            Image(systemName: agent.symbol).frame(width: 20)
                            TextField("Icon", text: $agent.symbol, prompt: Text("SF Symbol name")).labelsHidden()
                        }
                    }
                    Toggle("Use for new chats", isOn: $isDefault).settingsSwitch()
                }
                Section {
                    TextEditor(text: $agent.instructions).frame(minHeight: 110).accessibilityLabel("Instructions")
                } header: {
                    Text("Instructions")
                } footer: {
                    Text(costLine).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Section("Behavior") {
                    Picker(
                        "Creativity",
                        selection: Binding(
                            get: { AICreativity.nearest(to: agent.temperature) },
                            set: { agent.temperature = $0.temperature ?? 0 })
                    ) {
                        ForEach(AICreativity.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Reasoning", selection: $agent.reasoning) {
                        Text("Default").tag(AIReasoningLevel?.none)
                        ForEach(AIReasoningLevel.allCases) { Text($0.title).tag(AIReasoningLevel?.some($0)) }
                    }
                    .disabled(!model.ai.capabilities.contains(.reasoning))
                    Picker("Guardrail", selection: $agent.guardrail) {
                        ForEach(AIGuardrail.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    ForEach(extensions) { item in
                        ForEach(item.tools) { tool in
                            Toggle(isOn: toolBinding(tool.id)) {
                                SettingRowLabel(title: tool.title, detail: tool.isAction ? "Asks before it changes anything" : nil)
                            }
                            .settingsSwitch()
                        }
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("The agent may use these without an @-mention. Up to \(AIToolRouter.maximumTools) are offered at once, to save context.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(agent.isAssistant)
            .neutralMenus()
            footer
        }
        .task(id: agent.instructions + agent.toolIDs.joined()) { await measure() }
    }

    private var costLine: String {
        var line = "Instructions are sent with every message, so keep them short."
        if let tokens {
            line += " About \(tokens.formatted()) tokens"
            if let contextSize, contextSize > 0 {
                line += ", \(Int((Double(tokens) / Double(contextSize) * 100).rounded()))% of the \(contextSize.formatted())-token window"
            }
            line += "."
        }
        return line
    }

    private func measure() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let engine = model.ai.engine
        tokens = await engine.tokenCount(agent.composedInstructions(hasTools: !agent.toolIDs.isEmpty))
        contextSize = await engine.contextSize()
    }

    private func toolBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { agent.toolIDs.contains(id) },
            set: { on in
                agent.toolIDs.removeAll { $0 == id }
                if on { agent.toolIDs.append(id) }
            })
    }

    private var footer: some View {
        HStack {
            if let problem = problem ?? agent.validationMessage {
                Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(OR.Color.warning)
                    .font(OR.Font.callout).lineLimit(2)
            }
            Spacer()
            if let original, !original.isAssistant {
                Button("Delete", role: .destructive) {
                    if model.aiHub.deleteAgent(original.id) {
                        close()
                    } else {
                        problem = model.store.errorMessage ?? "The agent couldn't be deleted."
                    }
                }
            }
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button("Save") {
                // The agent and whether it starts new chats save together, or not at all.
                guard model.aiHub.save(agent, isDefault: isDefault) else {
                    problem = agent.validationMessage ?? model.store.errorMessage ?? "The agent couldn't be saved."
                    return
                }
                close()
            }
            .buttonStyle(.borderedProminent).tint(OR.Color.accentButton)
            .keyboardShortcut(.defaultAction)
            .disabled(agent.validationMessage != nil || agent.isAssistant)
        }
        .padding(14)
    }
}
