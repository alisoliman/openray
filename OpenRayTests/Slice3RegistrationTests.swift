import Testing

@testable import OpenRay

/// Slice 3's lines sit directly below its comments in the shared registration lists.
struct Slice3RegistrationTests {
    @Test func settingsPanesSitInTheSliceSlot() {
        let mine: [SettingsPane] = [.calculator, .emoji, .translator]
        #expect(SettingsPane.primary.filter(mine.contains) == mine)
        let index = SettingsPane.primary.firstIndex(of: .translator)!
        #expect(SettingsPane.primary[index + 1] == .files)
        #expect(SettingsPane(rawValue: "calculator") == .calculator)
    }

    @Test func registrationsSitInTheSliceSlot() {
        let ids = CommandProviders.all.map(\.id)
        #expect(ids.filter(["calculator", "emoji", "translate"].contains) == ["calculator", "emoji", "translate"])
        #expect(CuratedCommand.supports(CalculatorProvider.historyID))
        #expect(CuratedCommand.supports(EmojiProvider.searchID))
        #expect(CuratedCommand.supports(TranslatorProvider.openID))
    }
}
