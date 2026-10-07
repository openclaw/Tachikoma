import Foundation

/// Request-local wire fragments; no executable call is exposed until the complete batch validates.
struct OpenAICompatibleToolCallAccumulator {
    private struct PendingCall {
        var id: String?
        var name: String?
        var arguments: String?
    }

    private var calls: [PendingCall] = []
    private var positions: [Int: Int] = [:]

    var isEmpty: Bool {
        self.calls.isEmpty
    }

    mutating func append(_ fragment: OpenAIStreamChunk.Delta.ToolCall) throws {
        let position: Int
        if let index = fragment.index {
            guard index >= 0 else {
                throw TachikomaError.apiError("Compatible stream returned a negative tool-call index")
            }
            if let existing = self.positions[index] {
                position = existing
            } else {
                position = self.calls.count
                self.positions[index] = position
                self.calls.append(PendingCall())
            }
        } else {
            // Some compatible providers send complete calls without indices, but fragments are ambiguous.
            guard fragment.function?.name?.isEmpty == false, fragment.function?.arguments != nil else {
                throw TachikomaError.apiError("Compatible stream returned an unindexed tool-call fragment")
            }
            position = self.calls.count
            self.calls.append(PendingCall())
        }

        if let id = fragment.id, !id.isEmpty {
            guard self.calls[position].id == nil || self.calls[position].id == id else {
                throw TachikomaError.apiError("Compatible stream changed a tool-call identifier")
            }
            self.calls[position].id = id
        }
        if let name = fragment.function?.name, !name.isEmpty {
            guard self.calls[position].name == nil || self.calls[position].name == name else {
                throw TachikomaError.apiError("Compatible stream changed a tool-call name")
            }
            self.calls[position].name = name
        }
        if let arguments = fragment.function?.arguments {
            if self.calls[position].arguments == nil {
                self.calls[position].arguments = arguments
            } else {
                self.calls[position].arguments?.append(contentsOf: arguments)
            }
        }
    }

    func finish() throws -> [AgentToolCall] {
        var identifiers: Set<String> = []
        return try self.calls.map { pending in
            guard let name = pending.name, !name.isEmpty else {
                throw TachikomaError.apiError("Compatible stream ended with an unnamed tool call")
            }
            guard let encodedArguments = pending.arguments else {
                throw TachikomaError.apiError("Compatible stream ended without tool-call arguments")
            }
            // Complete empty strings are the legacy no-argument form, unlike a never-received field.
            let arguments = try Self.decodeArguments(encodedArguments)
            let id = pending.id ?? UUID().uuidString
            guard identifiers.insert(id).inserted else {
                throw TachikomaError.apiError("Compatible stream returned duplicate tool-call identifiers")
            }
            return AgentToolCall(id: id, name: name, arguments: arguments)
        }
    }

    /// Decode one complete object, including the legacy empty-string no-argument form.
    static func decodeArguments(_ encodedArguments: String) throws -> [String: AnyAgentToolValue] {
        if encodedArguments.isEmpty {
            return [:]
        }
        do {
            return try JSONDecoder().decode(
                [String: AnyAgentToolValue].self,
                from: Data(encodedArguments.utf8),
            )
        } catch {
            throw TachikomaError.apiError("Compatible stream ended with invalid or incomplete tool-call arguments")
        }
    }
}
