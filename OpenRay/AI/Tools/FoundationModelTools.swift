import Foundation
import FoundationModels

/// One OpenRay tool as a FoundationModels `Tool`. Every argument is a string, described by a
/// schema built at runtime from the spec, and every call goes through the broker, which asks
/// for approval and returns the text the model reads.
struct FoundationModelTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let spec: AIToolSpec
    let invoker: any AIToolInvoking
    let parameters: GenerationSchema

    var name: String { spec.id }
    var description: String { spec.summary }

    /// Nil when the spec can't be described as a schema.
    init?(spec: AIToolSpec, invoker: any AIToolInvoking) {
        let properties = spec.parameters.map { parameter in
            DynamicGenerationSchema.Property(
                name: parameter.name, description: parameter.description,
                schema: DynamicGenerationSchema(type: String.self), isOptional: parameter.isOptional)
        }
        let root = DynamicGenerationSchema(name: spec.id + "Arguments", description: spec.summary, properties: properties)
        guard let schema = try? GenerationSchema(root: root, dependencies: []) else { return nil }
        self.spec = spec
        self.invoker = invoker
        parameters = schema
    }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        var values: [String: String] = [:]
        for parameter in spec.parameters {
            if let value = try? arguments.value(String?.self, forProperty: parameter.name) {
                values[parameter.name] = value
            }
        }
        return await invoker.invoke(toolID: spec.id, arguments: AIToolArguments(values))
    }

    static func tools(for request: AIRequest) -> [any Tool] {
        guard request.toolMode != .none, let invoker = request.toolInvoker else { return [] }
        return request.tools.compactMap { FoundationModelTool(spec: $0, invoker: invoker) }
    }
}
