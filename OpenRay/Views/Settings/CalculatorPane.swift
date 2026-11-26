import SwiftUI

extension SettingsPane {
    static let calculator = SettingsPane(
        id: "calculator", title: "Calculator",
        subtitle: "Currency rates, CSS sizes and the history of answers.",
        kind: .calculator, symbol: "plus.forwardslash.minus",
        keywords: "currency exchange rates ECB euro dollar network rem em px pixels css history calculator"
    ) { model, _ in AnyView(CalculatorPane(model: model)) }
}

struct CalculatorPane: View {
    let model: LauncherModel
    @State private var confirmsClear = false

    private var provider: CalculatorProvider? {
        model.registry.provider(id: CalculatorProvider.registration.id) as? CalculatorProvider
    }

    var body: some View {
        SettingsPaneScaffold(pane: .calculator) {
            if let provider {
                currency(provider)
                Section("CSS units") {
                    let pixels = CalculatorProvider.pixelsPerEm(in: model.store.database)
                    Stepper(
                        value: Binding(get: { pixels }, set: { provider.setPixelsPerEm($0, in: model) }), in: 8...32,
                        step: 1
                    ) {
                        SettingRowLabel(
                            title: "\(Calculator.format(pixels)) pixels per rem and em",
                            detail: "Used by conversions such as 2 rem in px.")
                    }
                }
                history(provider)
            }
        }
    }

    @ViewBuilder private func currency(_ provider: CalculatorProvider) -> some View {
        let enabled = CalculatorProvider.currencyRatesEnabled(in: model.store.database)
        Section {
            Toggle(isOn: Binding(get: { enabled }, set: { provider.setCurrencyRates($0, in: model) })) {
                SettingRowLabel(
                    title: "Daily currency rates",
                    detail: "Downloads the European Central Bank's reference rates once a day, for conversions such as 100 usd in eur. Nothing else leaves this Mac.")
            }
            .settingsSwitch()
            if enabled {
                LabeledContent {
                    Button(provider.rates.isRefreshing ? "Refreshing…" : "Refresh Now") {
                        provider.refresh(in: model, force: true)
                    }
                    .disabled(provider.rates.isRefreshing)
                } label: {
                    SettingRowLabel(title: provider.ratesSummary, detail: ratesDetail(provider))
                }
            }
        } header: {
            Text("Currency")
        } footer: {
            Text("Off by default. Without rates, OpenRay converts units on this Mac only.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func ratesDetail(_ provider: CalculatorProvider) -> String {
        if let error = provider.rates.lastError { return error }
        guard let table = provider.rates.table else { return "Not downloaded yet." }
        return "Downloaded \(table.fetchedAt.formatted(date: .abbreviated, time: .shortened)). About 30 currencies."
    }

    @ViewBuilder private func history(_ provider: CalculatorProvider) -> some View {
        let count = model.store.database.calculatorHistory.count
        Section("History") {
            LabeledContent {
                Button("Clear History…", role: .destructive) { confirmsClear = true }
                    .disabled(count == 0)
                    .confirmationDialog("Clear Calculator History?", isPresented: $confirmsClear) {
                        Button("Clear History", role: .destructive) { model.store.update { $0.calculatorHistory = [] } }
                    } message: {
                        Text("\(count) calculation\(count == 1 ? "" : "s") will be removed.")
                    }
            } label: {
                SettingRowLabel(
                    title: "\(count) calculation\(count == 1 ? "" : "s")",
                    detail: "Answers you copy or paste stay for three months. Open Calculator History to search them.")
            }
        }
    }
}
