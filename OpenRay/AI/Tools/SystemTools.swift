import Foundation

// Tools over other slices' services: the calendar (Slice 6) and system and window commands
// (Slice 5). Reading the calendar is a read. System and window commands act on the Mac, so they
// are `.system` tools: `SideEffectGuard` refuses them where side effects are off, each call needs
// its own approval card, and a command Slice 5 asks about (Restart, Empty Trash…) still asks its
// own question in the launcher before it runs.

// MARK: - Calendar

/// Reads upcoming events. Never asks for calendar access; My Schedule does that.
@MainActor
protocol AICalendarReading {
    /// Why events can't be read, or nil when they can.
    var unavailableReason: String? { get }
    /// Events from now until `days` days ahead, in the calendars the person shows, earliest first.
    func upcoming(days: Int) -> [CalendarEvent]
}

/// Slice 6's `CalendarService`, filtered by the calendars My Schedule shows.
@MainActor
struct CalendarServiceReader: AICalendarReading {
    let service: CalendarService
    let store: LibraryStore

    var unavailableReason: String? {
        service.updateAccess()
        switch service.access {
        case .fullAccess: return nil
        case .unavailable: return "Calendars aren't available in this instance of OpenRay."
        default: return "OpenRay can't read your calendars yet. Open My Schedule to allow it, then ask again."
        }
    }

    func upcoming(days: Int) -> [CalendarEvent] {
        service.refreshIfStale()
        let hidden = CalendarPreferences.load(from: store).hiddenCalendarIDs
        let end = service.now().addingTimeInterval(TimeInterval(days) * 86_400)
        return service.upcoming(hidden: hidden).filter { $0.start < end }
    }
}

@MainActor
struct CalendarReadTool: AIToolExecutor {
    let reader: any AICalendarReading
    var now: () -> Date = { .now }
    let spec = AIToolSpec(
        id: "readCalendar", extensionID: "calendar", title: "Read Calendar", symbol: "calendar",
        summary:
            "Lists the person's upcoming calendar events with their times. Use it for questions about their schedule, meetings or free time.",
        parameters: [
            AIToolParameter(name: "days", description: "How many days ahead to look, from 1 to 14. 1 means the rest of today and tomorrow morning.", isOptional: true),
            AIToolParameter(name: "query", description: "Words in the event title to look for.", isOptional: true),
        ])

    func describe(_ arguments: AIToolArguments) -> String {
        arguments["query"].map { "Look for “\($0)” in your calendar" } ?? "Read your upcoming events"
    }

    func run(_ arguments: AIToolArguments) async throws -> String {
        if let reason = reader.unavailableReason { return reason }
        let days = min(14, max(1, Int(arguments["days"] ?? "") ?? 1))
        let query = arguments["query"]?.lowercased()
        let events = reader.upcoming(days: days)
            .filter { event in query.map { event.title.lowercased().contains($0) } ?? true }.prefix(25)
        guard !events.isEmpty else { return "No events in the next \(days) day\(days == 1 ? "" : "s")." }
        return events.map(Self.line).joined(separator: "\n")
    }

    static func line(_ event: CalendarEvent) -> String {
        let day = event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let time =
            event.isAllDay
            ? "all day"
            : "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"
        var parts = ["- \(day), \(time): \(event.title)"]
        if let location = event.location, !location.isEmpty { parts.append("at \(location)") }
        if event.meetingLink != nil { parts.append("(video call)") }
        if !event.calendarTitle.isEmpty { parts.append("· \(event.calendarTitle)") }
        return parts.joined(separator: " ")
    }
}

// MARK: - System and window commands

/// A command a tool may run: its id and the name the model uses.
struct AIRunnableCommand: Hashable, Sendable {
    var id: String
    var title: String
}

enum AICommandRunResult: Equatable, Sendable {
    case ran
    /// The command asked its own question in the launcher; nothing has run yet.
    case askedToConfirm(String)
    case failed(String)
}

/// Runs registered launcher commands for tools.
@MainActor
protocol AICommandRunning: AnyObject {
    /// The provider's commands that run on their own: no list to open, no value to type.
    func commands(fromProvider provider: String) -> [AIRunnableCommand]
    /// Runs a command as its hotkey would. A command that asks first shows its question in
    /// the launcher, and runs only if the person approves it there.
    func run(commandID: String) -> AICommandRunResult
}

/// The launcher's own path for commands, so their confirmations, permission checks and
/// `SideEffectGuard` rules all apply.
@MainActor
final class LauncherCommandRunner: AICommandRunning {
    weak var model: LauncherModel?

    init(model: LauncherModel) { self.model = model }

    func commands(fromProvider provider: String) -> [AIRunnableCommand] {
        guard let model, let source = model.registry.provider(id: provider) else { return [] }
        return source.commands(in: model).compactMap { descriptor in
            guard descriptor.mode == .noView, descriptor.isBindable,
                !descriptor.arguments.contains(where: { !$0.isOptional && $0.defaultValue == nil })
            else { return nil }
            return AIRunnableCommand(id: descriptor.id, title: descriptor.title)
        }
    }

    func run(commandID: String) -> AICommandRunResult {
        guard let model else { return .failed("OpenRay isn't ready to run commands.") }
        guard let item = model.bindableCommands.first(where: { $0.id == commandID }) else {
            return .failed("That command isn't available.")
        }
        model.perform(item)
        if let confirmation = model.confirmation {
            // Asked in the launcher, as from a hotkey: shown, and answered there.
            if model.panel?.isVisible == false {
                model.panel?.show()
                if model.confirmation == nil { model.presentConfirmation(confirmation) }
            }
            return .askedToConfirm(confirmation.question)
        }
        if let feedback = model.feedback, feedback.style == .error || feedback.style == .warning {
            return .failed(feedback.text)
        }
        return .ran
    }
}

/// Runs one of a provider's commands by name.
@MainActor
struct RunCommandTool: AIToolExecutor {
    let runner: any AICommandRunning
    let provider: String
    let spec: AIToolSpec

    /// System commands: Lock Screen, Toggle Dark Mode, Empty Trash, Restart and the rest.
    static func system(runner: any AICommandRunning) -> RunCommandTool {
        RunCommandTool(
            runner: runner, provider: "system",
            spec: AIToolSpec(
                id: "runSystemCommand", extensionID: "system", title: "Run System Command", symbol: "gearshape.2",
                summary: summary(
                    "Runs one of OpenRay's system commands on this Mac, such as locking the screen or turning on Dark Mode.",
                    commands: runner.commands(fromProvider: "system")),
                parameters: [AIToolParameter(name: "command", description: "The command's exact name from the list.")],
                effect: .system))
    }

    /// Window commands: halves, thirds, maximize, center and the rest, on the frontmost window.
    static func windows(runner: any AICommandRunning) -> RunCommandTool {
        RunCommandTool(
            runner: runner, provider: "windows",
            spec: AIToolSpec(
                id: "arrangeWindow", extensionID: "windows", title: "Arrange Window", symbol: "macwindow",
                summary: summary(
                    "Moves or resizes the frontmost window of the app the person was using.",
                    commands: runner.commands(fromProvider: "windows")),
                parameters: [AIToolParameter(name: "command", description: "The layout's exact name from the list.")],
                effect: .system))
    }

    private static func summary(_ lead: String, commands: [AIRunnableCommand]) -> String {
        let names = commands.map(\.title).joined(separator: ", ")
        return names.isEmpty ? lead : lead + " Commands: " + names + "."
    }

    func describe(_ arguments: AIToolArguments) -> String {
        "Run “\(arguments["command"] ?? "a command")” on this Mac"
    }

    /// The command a name means: exact, then case- and space-insensitive.
    func command(named name: String) -> AIRunnableCommand? {
        let commands = runner.commands(fromProvider: provider)
        if let exact = commands.first(where: { $0.title == name }) { return exact }
        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
        }
        let key = fold(name)
        return commands.first { fold($0.title) == key }
    }

    func run(_ arguments: AIToolArguments) async throws -> String {
        guard let name = arguments["command"] else { throw AIToolError.missingArgument("command") }
        guard let command = command(named: name) else {
            return "There's no command named “\(name)”. Use a name from the list."
        }
        switch runner.run(commandID: command.id) {
        case .ran: return "Ran \(command.title)."
        case .askedToConfirm(let question):
            return "OpenRay asked the person to confirm “\(question)” first. Nothing has happened unless they approve it."
        case .failed(let reason): return "\(command.title) didn't run: \(reason)"
        }
    }
}
