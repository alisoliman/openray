import SwiftUI

@main
struct OpenRayApp: App {
    @NSApplicationDelegateAdaptor(OpenRayDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Button("Open OpenRay    \(delegate.model.store.database.preferences.hotKey.title)") {
                delegate.model.panel?.show(section: .home)
            }
            Button("Ask AI") {
                delegate.model.openAI()
                delegate.model.panel?.show()
            }
            Button("Clipboard History") { delegate.model.panel?.show(section: .clipboard) }
            Divider()
            PomodoroMenuContent(model: delegate.model)
            Divider()
            CaffeinateMenuContent(model: delegate.model)
            Divider()
            Button("Settings…") {
                delegate.model.openSettings()
                delegate.model.panel?.show()
            }
            OpenRayHelpButton()
            Divider()
            Button("Quit OpenRay") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            HStack(spacing: 4) {
                PomodoroMenuBarLabel(service: delegate.model.pomodoro)
                if delegate.model.caffeinate.isActive {
                    Image(systemName: "cup.and.saucer.fill")
                        .accessibilityLabel("Caffeinate active. \(delegate.model.caffeinate.statusText)")
                }
            }
        }
        Settings {
            SettingsView(model: delegate.model, showsBackButton: false)
                .frame(width: 640, height: 560)
                .appAppearance(delegate.model.store.database.preferences.appearance)
        }
        .commands {
            CommandGroup(replacing: .help) { OpenRayHelpButton() }
        }
        Window("OpenRay Help", id: OpenRayHelpView.windowID) {
            OpenRayHelpView(model: delegate.model)
                .appAppearance(delegate.model.store.database.preferences.appearance)
        }
        .defaultSize(width: 700, height: 660)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
