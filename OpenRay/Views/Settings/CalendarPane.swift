import SwiftUI

extension SettingsPane {
    static let calendar = SettingsPane(
        id: "calendar", title: "Calendar",
        subtitle: "My Schedule, the next meeting in search, and your availability.",
        kind: .command, symbol: "calendar",
        keywords: "calendar schedule events meetings zoom meet teams join availability block time menu bar countdown access"
    ) { model, _ in AnyView(CalendarPane(model: model)) }
}

struct CalendarPane: View {
    @Bindable var model: LauncherModel
    private let service = CalendarService.shared

    private var preferences: CalendarPreferences { .load(from: model.store) }

    var body: some View {
        SettingsPaneScaffold(pane: .calendar) {
            Section("Access") {
                LabeledContent {
                    switch service.access {
                    case .notDetermined:
                        Button("Allow Access…") { Task { await service.requestAccessIfNeeded() } }
                    case .denied, .restricted, .writeOnly:
                        Button("Open Privacy Settings") { try? service.opener.open(CalendarCommandProvider.privacySettingsURL) }
                    case .fullAccess, .unavailable:
                        EmptyView()
                    }
                } label: {
                    SettingRowLabel(title: "Calendars", detail: accessDetail)
                }
            }
            if service.access.canRead {
                Section("Calendars in My Schedule") {
                    ForEach(service.source.calendars()) { calendar in
                        Toggle(isOn: includes(calendar.id)) {
                            HStack(spacing: 8) {
                                Circle().fill(calendar.color.map { Color(hex: $0) } ?? OR.Color.accent).frame(width: 9, height: 9)
                                    .accessibilityHidden(true)
                                SettingRowLabel(title: calendar.title, detail: calendar.source)
                            }
                        }
                        .settingsSwitch()
                    }
                }
            }
            Section("Search") {
                Picker(selection: binding(\.rootLeadMinutes)) {
                    ForEach(CalendarPreferences.leadChoices, id: \.self) { Text("\($0) minutes").tag($0) }
                } label: {
                    SettingRowLabel(
                        title: "Show the next event in search",
                        detail: "From this long before it starts until this long after. ↩ joins the call.")
                }
                .neutralMenus()
            }
            Section("Menu bar") {
                Toggle(isOn: menuBarBinding) {
                    SettingRowLabel(title: "Next event in the menu bar", detail: "A countdown to your next meeting, with Join.")
                }
                .settingsSwitch()
                Picker("Show it from", selection: binding(\.menuBarLeadMinutes)) {
                    ForEach([15, 30, 60, 120, 240], id: \.self) { minutes in
                        Text("\(FocusFormat.duration(minutes: minutes)) before").tag(minutes)
                    }
                }
                .neutralMenus()
                Toggle("Only events with a call link", isOn: binding(\.menuBarOnlyMeetings)).settingsSwitch()
            }
            Section("Availability") {
                Stepper(value: availability(\.days), in: 1...10) {
                    SettingRowLabel(
                        title: "Copy Availability covers \(preferences.availability.days) working day\(preferences.availability.days == 1 ? "" : "s")",
                        detail: "Free slots of 30 minutes or more, starting today.")
                }
                Picker("Day starts", selection: availability(\.dayStart)) {
                    ForEach(Array(stride(from: 5 * 60, through: 12 * 60, by: 30)), id: \.self) { Text(Self.time($0)).tag($0) }
                }
                .neutralMenus()
                Picker("Day ends", selection: availability(\.dayEnd)) {
                    ForEach(Array(stride(from: 13 * 60, through: 23 * 60, by: 30)), id: \.self) { Text(Self.time($0)).tag($0) }
                }
                .neutralMenus()
                Toggle("Skip weekends", isOn: availability(\.skipsWeekends)).settingsSwitch()
            }
        }
        .onAppear {
            service.updateAccess()
            if service.access.canRead { service.refreshIfStale() }
        }
    }

    private var accessDetail: String {
        switch service.access {
        case .notDetermined: "OpenRay asks the first time you open My Schedule. Events stay on this Mac."
        case .denied, .restricted: "Access is off. Allow OpenRay in Privacy & Security › Calendars."
        case .writeOnly: "OpenRay can add events but not read them. Allow full access to see your schedule."
        case .fullAccess: "OpenRay can read your events. Nothing leaves this Mac."
        case .unavailable: "Calendars aren't read in isolated verification mode."
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<CalendarPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: path] },
            set: { value in
                var updated = preferences
                updated[keyPath: path] = value
                updated.save(to: model.store)
            })
    }

    private func availability<Value>(_ path: WritableKeyPath<Availability.Options, Value>) -> Binding<Value> {
        let base: WritableKeyPath<CalendarPreferences, Availability.Options> = \.availability
        return binding(base.appending(path: path))
    }

    private func includes(_ calendarID: String) -> Binding<Bool> {
        Binding(
            get: { !preferences.hiddenCalendarIDs.contains(calendarID) },
            set: { included in
                var updated = preferences
                if included { updated.hiddenCalendarIDs.remove(calendarID) } else { updated.hiddenCalendarIDs.insert(calendarID) }
                updated.save(to: model.store)
            })
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { MenuBarExtras.isShown(CalendarCommandProvider.menuBarID, default: false, in: model.store.database) },
            set: { MenuBarExtras.setShown($0, commandID: CalendarCommandProvider.menuBarID, in: model.store) })
    }

    static func time(_ minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}
