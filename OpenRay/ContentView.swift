import SwiftUI

struct ContentView: View {
    @Bindable var model: LauncherModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            switch model.destination {
            case .search: LauncherSearchView(model: model)
            case .ai: AIChatView(model: model)
            case .settings: SettingsView(model: model)
            }
        }
        .frame(width: 780, height: 570)
        .background(
            colorScheme == .dark
                ? Color(red: 0.095, green: 0.10, blue: 0.12) : Color(red: 0.98, green: 0.98, blue: 0.99)
        )
        .clipShape(.rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
        .tint(RayStyle.accent)
        .appAppearance(model.store.database.preferences.appearance)
        .sheet(item: $model.editor) { context in LibraryEditorView(context: context, model: model) }
        .onChange(of: model.editor?.id) { _, newValue in
            if newValue == nil { model.focusRequest += 1 }
        }
        .onExitCommand {
            // Settings uses the panel's native responder-aware fallback. Text
            // editing and modal dismissal must get their own Escape first.
            guard model.editor == nil, model.destination != .settings else { return }
            model.goBack()
        }
        .background {
            Button("Open Settings") { model.openSettings() }.keyboardShortcut(",").hidden()
        }
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
