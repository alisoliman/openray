import SwiftUI

@main
struct OpenRayApp: App {
    @NSApplicationDelegateAdaptor(OpenRayDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("OpenRay", systemImage: "command.square.fill") {
            Button("Open OpenRay    \(delegate.model.store.database.preferences.hotKey.title)") {
                delegate.model.panel?.show(section: .home)
            }
            Button("Ask AI") {
                delegate.model.openAI()
                delegate.model.panel?.show()
            }
            Button("Clipboard History") { delegate.model.panel?.show(section: .clipboard) }
            Divider()
            Button("Settings…") {
                delegate.model.openSettings()
                delegate.model.panel?.show()
            }
            Divider()
            Button("Quit OpenRay") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        Settings {
            SettingsView(model: delegate.model, showsBackButton: false)
                .frame(width: 640, height: 560)
        }
    }
}
