import SwiftUI

@main
struct OpenRayApp: App {
    @NSApplicationDelegateAdaptor(OpenRayDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

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
            Button("OpenRay Help") { openWindow(id: "help") }
            Divider()
            Button("Quit OpenRay") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        Settings {
            SettingsView(model: delegate.model, showsBackButton: false)
                .frame(width: 640, height: 560)
        }
        Window("OpenRay Help", id: "help") {
            HelpView(model: delegate.model)
                .frame(minWidth: 560, idealWidth: 620, minHeight: 500, idealHeight: 660)
        }
        .defaultSize(width: 620, height: 660)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .help) {
                Button("OpenRay Help") { openWindow(id: "help") }
            }
        }
    }
}
