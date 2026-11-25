import AppKit
import SwiftUI

extension SettingsPane {
    static let about = SettingsPane(
        id: "about", title: "About",
        subtitle: "Version, help and privacy.",
        kind: .about, symbol: "info",
        keywords: "version help guide privacy support issue feedback"
    ) { model, _ in AnyView(AboutPane(model: model)) }
}

struct AboutPane: View {
    let model: LauncherModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ORMark(size: 72).padding(.top, 8)
                    Text("OpenRay").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                    Text("Version \(AppInformation.version) · Apple silicon · macOS 27+").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("One quiet surface for everything you reach for. No account, analytics or cloud sync.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            Section {
                Button("OpenRay Help") { model.presentHelp?() }
                // Links, so VoiceOver says they open a web page, styled like the Help button.
                Link("Read the Guide", destination: AppInformation.documentationURL).buttonStyle(.bordered)
                Link("Report an Issue", destination: AppInformation.supportURL).buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped)
    }
}
