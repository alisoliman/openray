import SwiftUI

struct ContentView: View {
    @Bindable var model: LauncherModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            switch model.destination {
            case .search:
                LauncherSearchView(model: model)
                    .modifier(RayDestinationEntrance(isRoot: true))
            case .ai:
                AIChatView(model: model)
                    .modifier(RayDestinationEntrance())
            case .settings:
                SettingsView(model: model)
                    .modifier(RayDestinationEntrance())
            case .pomodoro:
                PomodoroView(model: model)
                    .modifier(RayDestinationEntrance())
            case .caffeinate:
                CaffeinateView(model: model)
                    .modifier(RayDestinationEntrance())
            }
        }
        .frame(width: 780, height: 570)
        .background { backdrop }
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.35 : 0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .tint(RayStyle.accent)
        .appAppearance(model.store.database.preferences.appearance)
        .sheet(item: $model.editor) { context in LibraryEditorView(context: context, model: model) }
        .onChange(of: model.editor?.id) { _, newValue in
            if newValue == nil { model.focusRequest += 1 }
        }
        .onExitCommand {
            // Dashboards use the panel's native responder-aware fallback. Text
            // editing and modal dismissal must get their own Escape first.
            guard model.editor == nil, model.destination != .settings, model.destination != .pomodoro,
                model.destination != .caffeinate
            else { return }
            model.hideLauncher()
        }
        .background {
            Button("Open Settings") { model.openSettings() }.keyboardShortcut(",").hidden()
            Button("Go Back") { model.goBack() }.keyboardShortcut("[").hidden()
        }
    }

    private var backdrop: some View {
        ZStack(alignment: .topLeading) {
            colorScheme == .dark
                ? Color(red: 0.095, green: 0.10, blue: 0.12) : Color(red: 0.98, green: 0.98, blue: 0.99)
            if contrast != .increased {
                RadialGradient(
                    colors: [
                        (model.destination == .ai ? Color.purple : RayStyle.accent)
                            .opacity(colorScheme == .dark ? 0.10 : 0.035),
                        .clear,
                    ], center: .topLeading, startRadius: 0, endRadius: 390
                )
                .frame(height: 220)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview {
    ContentView(model: LauncherModel(store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: PreviewAIEngine())))
}

@MainActor
private final class PreviewAIEngine: AIEngine {
    var availability: AIAvailability { .notEnabled }
    func prepare(for action: AIAction) {}
    func reset() {}
    func stream(_ prompt: String, action: AIAction, onSnapshot: @escaping @MainActor (String) -> Void) async throws {
        throw AIServiceError.unavailable(.notEnabled)
    }
}
