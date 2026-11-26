import SwiftUI

extension SettingsPane {
    // main: pomodoro, caffeinate
    static let caffeinate = SettingsPane(
        id: "caffeinate", title: "Caffeinate",
        subtitle: "Keep your Mac awake now, for a set time or until you stop it.",
        kind: .system, symbol: "cup.and.saucer",
        keywords: "caffeinate coffee caffeine awake sleep display prevent duration custom minutes menu bar"
    ) { model, _ in AnyView(CaffeinatePane(model: model)) }
}

/// main #11's Caffeinate controls. The pending duration is `model.caffeinateDraft`, so a custom
/// value survives closing Settings until it's applied; untouched controls follow the session.
struct CaffeinatePane: View {
    @Bindable var model: LauncherModel

    private var service: CaffeinateService { model.caffeinate }

    var body: some View {
        @Bindable var draft = model.caffeinateDraft
        SettingsPaneScaffold(pane: .caffeinate) {
            Section("Status") {
                HStack(alignment: .firstTextBaseline) {
                    SettingRowLabel(
                        title: service.isActive ? "Your Mac is awake" : "Off",
                        detail: service.isActive ? statusDetail : "Normal sleep settings apply.")
                    Spacer()
                    if service.isActive {
                        Button("Stop Caffeinate") {
                            draft.validationMessage = nil
                            service.stop()
                        }
                        .accessibilityIdentifier("caffeinate.stop")
                    }
                }
                .accessibilityIdentifier("caffeinate.status")
            }
            Section {
                Picker("Keep awake for", selection: $draft.duration) {
                    ForEach(CaffeinateDuration.allCases) { Text($0.title).tag(Optional($0)) }
                    Text("Custom…").tag(CaffeinateDuration?.none)
                }
                .neutralMenus()
                .accessibilityIdentifier("caffeinate.duration")
                if draft.duration == nil {
                    LabeledContent("Minutes") {
                        TextField("Minutes", text: $draft.customMinutes, prompt: Text("1–1,440"))
                            .labelsHidden().frame(width: 90).multilineTextAlignment(.trailing)
                            .accessibilityLabel("Custom duration in minutes")
                            .accessibilityIdentifier("caffeinate.customMinutes")
                    }
                }
                HStack {
                    Button(service.isActive ? "Update Duration" : "Start Caffeinate") { draft.start(using: service) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("caffeinate.start")
                    if let message = draft.validationMessage ?? service.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(OR.Color.warning)
                    }
                }
            } header: {
                Text("Duration")
            } footer: {
                Text(
                    service.isActive
                        ? "Updating starts the chosen duration from now." : "Timed sessions stop on their own.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle(isOn: menuBarBinding) {
                    SettingRowLabel(title: "Cup in the menu bar", detail: "While your Mac is kept awake: status and controls.")
                }
                .settingsSwitch()
            }
            Section("About Caffeinate") {
                IconRow("Your Mac and its display stay awake. Closing the lid or choosing Sleep still sleeps.", symbol: "display")
                IconRow("Quitting OpenRay stops it. Sessions aren't saved or resumed after a relaunch.", symbol: "power")
            }
        }
        .onAppear { draft.refresh(from: service) }
        .onChange(of: service.isActive) { draft.refresh(from: service) }
        .onChange(of: service.deadline) { draft.refresh(from: service) }
    }

    private var statusDetail: String {
        if let deadline = service.deadline {
            return "\(service.statusText) · stops at \(deadline.formatted(date: .omitted, time: .shortened))"
        }
        return "Until you stop it or quit OpenRay."
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { MenuBarExtras.isShown(CaffeinateCommandProvider.menuBarID, default: true, in: model.store.database) },
            set: { MenuBarExtras.setShown($0, commandID: CaffeinateCommandProvider.menuBarID, in: model.store) })
    }
}
