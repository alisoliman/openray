import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: LauncherModel
    var showsBackButton = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var clearHistory = false
    @State private var exclusions = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if showsBackButton { BackButton { model.navigate(to: .home) } }
                Text("Make OpenRay yours").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Refresh Status", systemImage: "arrow.clockwise") { model.refreshPermissions() }
                    .font(.system(size: 11)).buttonStyle(.borderless)
            }.padding(.horizontal, 22).frame(height: 64)
            Divider()
            if let message = model.message ?? model.store.errorMessage ?? model.shortcutError {
                StatusBanner(message: message) { model.message = nil }
            }
            Form {
                Section("General") {
                    Picker("Open launcher", selection: preference(\.hotKey)) {
                        ForEach(LauncherHotKey.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Appearance", selection: preference(\.appearance)) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(
                        "Launch at login",
                        isOn: Binding(get: { model.loginEnabled }, set: { model.setLaunchAtLogin($0) }))
                    if model.loginNeedsApproval {
                        Button("Approve OpenRay in Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    HStack {
                        Text("\(model.applications.applications.count) applications indexed").foregroundStyle(
                            .secondary)
                        Spacer()
                        Button(model.applications.isLoading ? "Refreshing…" : "Refresh Apps") {
                            Task { await model.applications.refresh() }
                        }.disabled(model.applications.isLoading)
                    }
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.accessibilityAllowed ? "checkmark.shield.fill" : "hand.raised")
                            .foregroundStyle(model.accessibilityAllowed ? Color.green : .orange).font(.title2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.accessibilityAllowed ? "Accessibility is enabled" : "Accessibility is optional")
                                .fontWeight(.medium)
                            Text(
                                "Needed only for window layouts, pasting into other apps, selected text, and optional snippet expansion. App search, quicklinks, notes, calculator, and AI work without it."
                            )
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !model.accessibilityAllowed {
                            Button("Enable…") { model.windows.requestPermission() }
                        }
                    }
                    Toggle("Expand snippet keywords as I type", isOn: preference(\.snippetExpansionEnabled))
                        .disabled(!model.accessibilityAllowed)
                    Text(
                        "When enabled, only a short keyword buffer is held in memory. Typing is never saved. Expansion is skipped during Secure Input and in excluded apps."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                } header: {
                    Text("Cross-app features")
                }

                Section {
                    Toggle("Capture clipboard history", isOn: preference(\.clipboardEnabled))
                    Toggle("Include copied images", isOn: optionalPreference(\.clipboardImagesEnabled))
                    Toggle("Include copied files", isOn: optionalPreference(\.clipboardFilesEnabled))
                    if let note = model.clipboard.accessMessage {
                        Label(note, systemImage: "hand.raised").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Text(
                        "Copied text, images, and file references are saved locally. Content marked confidential or transient and known password managers are excluded. Unmarked sensitive content can still be captured; pause capture or add an exclusion when needed."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("Keep history for", selection: preference(\.clipboardRetentionDays)) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    Picker("Maximum entries", selection: preference(\.clipboardLimit)) {
                        ForEach([50, 100, 250, 500], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Text(
                        "History is also bounded to 64 MB. Images are saved as PNGs up to 10 MB each; copied files are references to the originals."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Excluded apps (one bundle identifier per line)").font(.system(size: 12))
                        TextEditor(text: $exclusions).font(.system(size: 11, design: .monospaced))
                            .frame(height: 65).scrollContentBackground(.hidden)
                            .padding(6).background(.primary.opacity(0.035), in: .rect(cornerRadius: 5))
                            .accessibilityLabel("Excluded application bundle identifiers")
                        Button("Save Exclusions") {
                            let values = exclusions.split(whereSeparator: \.isNewline)
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                            if model.store.update({
                                $0.preferences.excludedClipboardBundleIDs = Array(Set(values)).sorted()
                            }) {
                                model.applyPreferences()
                                model.message = "Clipboard exclusions saved."
                            }
                        }
                    }
                    HStack {
                        Text("\(model.store.database.clipboard.count) saved entries").foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear History…", role: .destructive) { clearHistory = true }
                            .disabled(model.store.database.clipboard.isEmpty)
                    }
                } header: {
                    Text("Clipboard & privacy")
                }

                Section("Apple Intelligence") {
                    Label(model.ai.availability.title, systemImage: "sparkles").foregroundStyle(.purple)
                    Text(model.ai.availability.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(
                        "AI uses Apple’s Foundation Models framework. Clipboard and selected text are shared with the model only when you click their buttons. Chats are not saved automatically, and no cloud fallback is used."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !model.ai.availability.isAvailable {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                        }
                    }
                }

                Section("Local library") {
                    Text(
                        "Quicklinks, snippets, notes, favorites, preferences, and enabled clipboard history are stored in Application Support/OpenRay. No account or analytics."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let url = model.store.fileURL {
                        Button("Reveal Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .disabled(!FileManager.default.fileExists(atPath: url.path))
                    }
                    Text("OpenRay · Native Swift 6 · macOS 26+").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }.formStyle(.grouped)
        }
        .tint(RayStyle.accent)
        .onAppear {
            exclusions = model.store.database.preferences.excludedClipboardBundleIDs.joined(separator: "\n")
            model.refreshPermissions()
        }
        .onChange(of: scenePhase) { if scenePhase == .active { model.refreshPermissions() } }
        .confirmationDialog("Delete all clipboard history?", isPresented: $clearHistory, titleVisibility: .visible) {
            Button("Delete All History", role: .destructive) { model.clipboard.clearHistory() }
        } message: {
            Text(
                "This permanently removes the saved history from OpenRay. It does not change your current system clipboard."
            )
        }
    }

    private func preference<Value>(_ path: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.store.database.preferences[keyPath: path] },
            set: { value in
                if model.store.update({ $0.preferences[keyPath: path] = value }) { model.applyPreferences() }
            })
    }

    private func optionalPreference(_ path: WritableKeyPath<AppPreferences, Bool?>) -> Binding<Bool> {
        Binding(
            get: { model.store.database.preferences[keyPath: path] ?? false },
            set: { value in
                if model.store.update({ $0.preferences[keyPath: path] = value }) { model.applyPreferences() }
            })
    }
}
