/// Every command provider, one line each. Order is the order their commands appear in
/// Settings › Shortcuts after the original twenty, and the order rows from different
/// providers tie in.
///
/// Each slice adds its own line in its own slot. The comment lines between slots keep
/// parallel additions from touching adjacent lines, so they merge without conflicts.
enum CommandProviders {
    static let all: [CommandProviderRegistration] = [
        AIWritingCommandProvider.registration,
        // Slice 1: launcher core
        // Slice 2: clipboard, snippets, quicklinks
        // Slice 3: calculator, emoji, translator
        // Slice 4: files, screenshots, applications
        // Slice 5: system, windows
        // Slice 6: notes, calendar, focus
        // Slice 7: AI commands, agents
        // Slice 8: script commands
    ]
}
