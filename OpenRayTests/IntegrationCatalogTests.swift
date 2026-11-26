import AppKit
import Testing

@testable import OpenRay

/// Cross-slice checks on the fully registered launcher: every slice's commands must coexist.
@MainActor
struct IntegrationCatalogTests {
    private func defaultModel() -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), registry: CommandRegistry())
    }

    @Test func everyRegisteredCommandIDIsUnique() {
        let model = defaultModel()
        var owners: [String: [String]] = [:]
        for provider in model.registry.providers {
            for descriptor in provider.commands(in: model) {
                owners[descriptor.id, default: []].append(provider.id)
            }
        }
        let duplicates = owners.filter { $0.value.count > 1 }
        #expect(duplicates.isEmpty, "Command ids registered more than once: \(duplicates)")
    }

    @Test func providedCommandIDsDontShadowBuiltInRows() {
        let model = defaultModel()
        let provided = Set(model.registry.providers.flatMap { $0.commands(in: model).map(\.id) })
        let builtIn = model.commandItems.filter {
            if case .provided = $0.action { false } else { true }
        }
        let shadowed = builtIn.map(\.id).filter(provided.contains)
        #expect(shadowed.isEmpty, "Built-in rows share ids with provided commands: \(shadowed)")
    }
}
