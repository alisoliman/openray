import AppKit
import ServiceManagement
import SwiftUI

extension SettingsPane {
    static let permissions = SettingsPane(
        id: "permissions", title: "Permissions",
        subtitle: "OpenRay works without any of these. Each one unlocks specific features.",
        kind: .permission, symbol: "checkmark.shield",
        keywords: "accessibility clipboard access login spotlight privacy allow"
    ) { model, _ in AnyView(PermissionsPane(model: model)) }
}

struct PermissionsPane: View {
    let model: LauncherModel

    var body: some View {
        SettingsPaneScaffold(pane: .permissions) {
            Section {
                permission(
                    kind: .quicklink, symbol: "accessibility", title: "Accessibility",
                    detail: "Window layouts, Paste to app, selected text, snippet expansion"
                ) {
                    if model.accessibilityAllowed {
                        StatusLabel(tone: .success, text: "Allowed")
                    } else {
                        Button("Enable…") {
                            model.windows.requestPermission()
                            SystemSettingsLink.open(.accessibility)
                        }
                    }
                }
                permission(kind: .clipboard, symbol: nil, title: "Clipboard access", detail: clipboardDetail) {
                    clipboardStatus
                }
                permission(
                    kind: .system, symbol: "bolt", title: "Open at login",
                    detail: "Keeps \(model.store.database.preferences.hotKey.title) ready after a restart",
                    error: model.loginError
                ) {
                    if model.loginNeedsApproval {
                        Button("Approve…") { SMAppService.openSystemSettingsLoginItems() }
                    } else {
                        Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLaunchAtLogin($0) }))
                            .labelsHidden().toggleStyle(.switch).settingsSwitch()
                    }
                }
                permission(kind: .ai, symbol: nil, title: "Apple Intelligence", detail: "Ask AI and writing commands, on this Mac") {
                    let availability = model.ai.availability
                    StatusLabel(
                        tone: availability.isAvailable ? .success : availability == .preparing ? .working : .warning,
                        text: availability.shortStatus)
                }
                permission(kind: .file, symbol: "folder", title: "Spotlight", detail: "File search uses your existing Spotlight index") {
                    StatusLabel(tone: .success, text: "In use")
                }
            } footer: {
                Label("Status refreshes when you come back to this window.", systemImage: "arrow.clockwise")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// Fix… opens System Settings, so say first which choice to make there.
    private var clipboardDetail: String {
        guard model.store.database.preferences.clipboardEnabled, model.clipboard.accessBehavior != .alwaysAllow else {
            return "Background capture for Clipboard History"
        }
        return "In System Settings › Privacy & Security › Paste from Other Apps, set OpenRay to Always Allow."
    }

    @ViewBuilder private var clipboardStatus: some View {
        if !model.store.database.preferences.clipboardEnabled {
            StatusLabel(tone: .neutral, text: "Not in use")
        } else {
            switch model.clipboard.accessBehavior {
            case .alwaysAllow: StatusLabel(tone: .success, text: "Always allowed")
            case .alwaysDeny:
                HStack {
                    StatusLabel(tone: .danger, text: "Blocked")
                    Button("Fix…") { SystemSettingsLink.open(.pasteboard) }
                }
            default:
                HStack {
                    StatusLabel(tone: .warning, text: "Asks each time")
                    Button("Fix…") { SystemSettingsLink.open(.pasteboard) }
                        .help("In System Settings, choose Always Allow for OpenRay.")
                }
            }
        }
    }

    private func permission<Trailing: View>(
        kind: Kind, symbol: String?, title: String, detail: String, error: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                KindTile(kind: kind, symbol: symbol, size: 28)
                SettingRowLabel(title: title, detail: detail)
                Spacer()
                trailing()
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(OR.Font.callout).foregroundStyle(OR.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 40)
            }
        }
        .padding(.vertical, 2)
    }
}
