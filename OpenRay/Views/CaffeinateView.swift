import SwiftUI

struct CaffeinateView: View {
    let model: LauncherModel
    @State private var duration: CaffeinateDuration? = .indefinitely
    @State private var customMinutes = "60"
    @State private var validationMessage: String?

    private var service: CaffeinateService { model.caffeinate }
    private var statusColor: Color { service.isActive ? .orange : .secondary }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if let error = validationMessage ?? service.errorMessage { StatusBanner(message: error) }
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    statusCard.frame(maxWidth: .infinity)
                    durationCard.frame(width: 300)
                }.padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.6)
            HStack(spacing: 7) {
                Image(systemName: "menubar.rectangle")
                Text("Stays active when the launcher closes.")
                Spacer()
                Keycap(text: "↩")
                Text(service.isActive ? "Update Duration" : "Start Caffeinate")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).frame(height: 36)
        }
        .onAppear(perform: loadDuration)
        .onChange(of: duration) { _, _ in validationMessage = nil }
        .onChange(of: customMinutes) { _, _ in validationMessage = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BackButton { model.goBack() }
            Image(systemName: "cup.and.saucer").font(.system(size: 21)).foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Caffeinate").font(.system(size: 15, weight: .semibold))
                Text("Keep your Mac awake").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Label(service.isActive ? "Active" : "Off", systemImage: service.isActive ? "circle.fill" : "circle")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor)
                .accessibilityIdentifier("caffeinate.status")
        }.padding(.horizontal, 20).frame(height: 64)
    }

    private var statusCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(statusColor.opacity(0.08)).frame(width: 134, height: 134)
                Circle().strokeBorder(statusColor.opacity(0.12)).frame(width: 164, height: 164)
                Image(systemName: service.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 54, weight: .light)).foregroundStyle(statusColor)
            }.accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(service.isActive ? "Your Mac is awake" : "Ready when you are")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(service.isActive ? "Your display stays on, too." : "Give sleep a little break.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 5) {
                Text(countdown)
                    .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(service.isActive ? .primary : .secondary)
                    .accessibilityIdentifier("caffeinate.countdown")
                if service.isActive, let deadline = service.deadline {
                    Text("Stops at \(deadline.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(service.isActive ? "Until you stop it or quit OpenRay" : "Normal sleep settings apply")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 12)
        .background(statusColor.opacity(0.025), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(statusColor.opacity(0.09)) }
    }

    private var durationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keep awake for").font(.system(size: 13, weight: .semibold))
                Text("Choose how long your Mac stays awake.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Picker("Duration", selection: $duration) {
                ForEach(CaffeinateDuration.allCases) { duration in
                    Text(duration.title).tag(Optional(duration))
                }
                Text("Custom…").tag(CaffeinateDuration?.none)
            }
            .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity)
            .accessibilityLabel("Caffeinate duration")
            .accessibilityIdentifier("caffeinate.duration")

            if duration == nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Minutes", text: $customMinutes)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Custom duration in minutes")
                            .accessibilityIdentifier("caffeinate.customMinutes")
                        Text("minutes").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text("1–1,440 minutes (up to 24 hours)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                Button(action: start) {
                    Label(service.isActive ? "Update Duration" : "Start Caffeinate", systemImage: "cup.and.saucer.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(RayStyle.accent)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityIdentifier("caffeinate.start")
                if service.isActive {
                    Button("Stop Caffeinate", systemImage: "stop.circle") {
                        validationMessage = nil
                        service.stop()
                    }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("caffeinate.stop")
                }
            }
            Text(service.isActive ? "Updating starts a new duration from now." : "Timed sessions stop automatically.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Mac and display stay awake", systemImage: "display")
                Label("Stops when you quit OpenRay", systemImage: "power")
                Text("Closing the lid or choosing Sleep can still put your Mac to sleep.")
                    .lineSpacing(3)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.primary.opacity(0.025), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)) }
    }

    private var countdown: String {
        guard service.isActive else { return "Off" }
        guard let seconds = service.remainingSeconds else { return "Indefinitely" }
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    private func start() {
        validationMessage = nil
        if let duration {
            service.start(for: duration)
        } else if let minutes = Int(customMinutes.trimmingCharacters(in: .whitespacesAndNewlines)),
            (1...1440).contains(minutes)
        {
            service.start(minutes: minutes)
        } else {
            validationMessage = "Enter a whole number of minutes from 1 to 1,440."
        }
    }

    private func loadDuration() {
        guard service.isActive, let seconds = service.remainingSeconds else { return }
        let minutes = Int(ceil(Double(seconds) / 60))
        if let preset = CaffeinateDuration.allCases.first(where: { $0.seconds == Double(minutes * 60) }) {
            duration = preset
        } else {
            duration = nil
            customMinutes = String(max(1, minutes))
        }
    }
}
