import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider for Google Gemini models
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class GoogleProvider: ModelProvider {
    public let modelId: String
    public let baseURL: String?
    public let apiKey: String?
    public let capabilities: ModelCapabilities

    private let model: LanguageModel.Google
    private var apiModelName: String {
        self.model.apiModelId
    }

    public init(model: LanguageModel.Google, configuration: TachikomaConfiguration) throws {
        self.model = model
        self.modelId = model.userFacingModelId
        self.baseURL = configuration.getBaseURL(for: .google) ?? "https://generativelanguage.googleapis.com/v1beta"

        if let key = configuration.getAPIKey(for: .google) {
            self.apiKey = key
        } else {
            throw TachikomaError.authenticationFailed("GEMINI_API_KEY not found")
        }

        self.capabilities = ModelCapabilities(
            supportsVision: model.supportsVision,
            supportsTools: model.supportsTools,
            supportsStreaming: true,
            contextLength: model.contextLength,
            maxOutputTokens: 8192,
        )
    }

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        // For now, collect the stream and return as a single response
        let stream = try await streamText(request: request)
        var fullText = ""
        var toolCalls: [AgentToolCall] = []
        var usage: Usage?
        var finishReason: FinishReason = .stop

        for try await delta in stream {
            if case .textDelta = delta.type, let content = delta.content {
                fullText += content
            }
            if case .toolCall = delta.type, let toolCall = delta.toolCall {
                toolCalls.append(toolCall)
            }
            if case .done = delta.type {
                usage = delta.usage
                finishReason = delta.finishReason ?? .stop
            }
        }

        if !toolCalls.isEmpty {
            finishReason = .toolCalls
        }

        return ProviderResponse(
            text: fullText,
            usage: usage,
            finishReason: finishReason,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
        )
    }

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    // Convert messages to Google format
                    let googleRequest = try self.buildGoogleRequest(request)
                    let requestBody = try JSONEncoder().encode(googleRequest)
                    let urlRequest = try self.makeStreamRequest(body: requestBody)

                    #if canImport(FoundationNetworking)
                    let (data, response) = try await URLSession.shared.data(for: urlRequest)
                    let httpResponse = try self.httpResponse(response)
                    guard 200..<300 ~= httpResponse.statusCode else {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        throw TachikomaError.apiError(
                            "Google API request failed (HTTP \(httpResponse.statusCode)): \(body)",
                        )
                    }

                    var parser = GoogleSSEParser(
                        onText: { text in
                            continuation.yield(TextStreamDelta.text(text))
                        },
                        onToolCall: { call in
                            continuation.yield(TextStreamDelta.tool(call))
                        },
                    )
                    try parser.feed(data: data)
                    continuation.yield(parser.makeDoneDelta())
                    #else
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    let httpResponse = try self.httpResponse(response)
                    if !(200..<300 ~= httpResponse.statusCode) {
                        var errorBody = ""
                        var iterator = bytes.makeAsyncIterator()
                        while let byte = try await iterator.next() {
                            errorBody.append(Character(UnicodeScalar(byte)))
                            if errorBody.count >= 512 {
                                errorBody.append("…")
                                break
                            }
                        }
                        throw TachikomaError.apiError(
                            "Google API request failed (HTTP \(httpResponse.statusCode)): \(errorBody)",
                        )
                    }

                    var parser = GoogleSSEParser(
                        onText: { text in
                            continuation.yield(TextStreamDelta.text(text))
                        },
                        onToolCall: { call in
                            continuation.yield(TextStreamDelta.tool(call))
                        },
                    )
                    for try await line in bytes.lines {
                        try parser.feed(line: line)
                    }
                    parser.finish()
                    continuation.yield(parser.makeDoneDelta())
                    #endif

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func buildGoogleRequest(_ request: ProviderRequest) throws -> GoogleGenerateRequest {
        var contents: [GoogleGenerateRequest.Content] = []
        var systemParts: [GoogleGenerateRequest.Content.Part] = []

        let toolCallNameById = Self.buildToolCallNameMap(from: request.messages)

        for message in request.messages {
            var parts: [GoogleGenerateRequest.Content.Part] = []

            if message.role == .system {
                for contentPart in message.content {
                    guard case let .text(text) = contentPart else { continue }
                    systemParts.append(.init(
                        text: text,
                        inlineData: nil,
                        functionCall: nil,
                        functionResponse: nil,
                        thoughtSignature: nil,
                    ))
                }
                continue
            }

            for contentPart in message.content {
                switch contentPart {
                case let .text(text):
                    parts.append(.init(
                        text: text,
                        inlineData: nil,
                        functionCall: nil,
                        functionResponse: nil,
                        thoughtSignature: nil,
                    ))
                case let .image(imageContent):
                    let inline = GoogleGenerateRequest.Content.InlineData(
                        mimeType: imageContent.mimeType,
                        data: imageContent.data,
                    )
                    parts.append(.init(
                        text: nil,
                        inlineData: inline,
                        functionCall: nil,
                        functionResponse: nil,
                        thoughtSignature: nil,
                    ))
                case .reasoning:
                    continue
                case let .toolCall(toolCall):
                    let call = try GoogleGenerateRequest.Content.FunctionCall(
                        id: toolCall.id,
                        name: toolCall.name,
                        args: Self.convertToolArguments(toolCall.arguments),
                    )
                    parts.append(.init(
                        text: nil,
                        inlineData: nil,
                        functionCall: call,
                        functionResponse: nil,
                        thoughtSignature: toolCall.recipient,
                    ))
                case let .toolResult(toolResult):
                    guard let name = toolCallNameById[toolResult.toolCallId] else { continue }
                    let response = try GoogleGenerateRequest.Content.FunctionResponse(
                        id: toolResult.toolCallId,
                        name: name,
                        response: Self.convertToolResult(toolResult),
                    )
                    parts.append(.init(
                        text: nil,
                        inlineData: nil,
                        functionCall: nil,
                        functionResponse: response,
                        thoughtSignature: nil,
                    ))
                }
            }

            let role = switch message.role {
            case .assistant:
                "model"
            case .tool:
                "user"
            default:
                "user"
            }
            Self.appendGoogleContent(role: role, parts: parts, to: &contents)
        }

        let config = GoogleGenerateRequest.GenerationConfig(
            temperature: request.settings.temperature ?? 0.7,
            maxOutputTokens: request.settings.maxTokens ?? 2048,
            topP: request.settings.topP ?? 0.95,
            topK: request.settings.topK ?? 40,
        )

        let systemInstruction: GoogleGenerateRequest.Content? = if systemParts.isEmpty {
            nil
        } else {
            GoogleGenerateRequest.Content(role: "system", parts: systemParts)
        }

        let tools = try Self.convertTools(request.tools)

        return GoogleGenerateRequest(
            contents: contents,
            generationConfig: config,
            systemInstruction: systemInstruction,
            tools: tools,
        )
    }
}

// MARK: - Streaming Helpers

extension GoogleProvider {
    private static func appendGoogleContent(
        role: String,
        parts: [GoogleGenerateRequest.Content.Part],
        to contents: inout [GoogleGenerateRequest.Content],
    ) {
        guard !parts.isEmpty else { return }

        if let last = contents.last, last.role == role {
            contents[contents.count - 1] = .init(role: role, parts: last.parts + parts)
        } else {
            contents.append(.init(role: role, parts: parts))
        }
    }

    private static func buildToolCallNameMap(from messages: [ModelMessage]) -> [String: String] {
        var map: [String: String] = [:]
        for message in messages {
            for contentPart in message.content {
                guard case let .toolCall(toolCall) = contentPart else { continue }
                map[toolCall.id] = toolCall.name
            }
        }
        return map
    }

    private static func convertTools(_ tools: [AgentTool]?) throws -> [GoogleGenerateRequest.Tool]? {
        guard let tools, !tools.isEmpty else { return nil }
        let declarations = try tools.map(Self.convertTool)
        return [GoogleGenerateRequest.Tool(functionDeclarations: declarations)]
    }

    private static func convertTool(_ tool: AgentTool) throws -> GoogleGenerateRequest.Tool.FunctionDeclaration {
        // Gemini validates that every name in `required` exists in `properties`. Tools occasionally
        // ship with a `required` entry whose property got filtered out during MCP→Agent conversion
        // (e.g. anyOf/oneOf schemas that don't survive the simplified MCP→Agent translation). Drop
        // any orphan `required` names so we never send Gemini an invalid schema.
        let parameters = try tool.parameters.jsonSchema(options: [
            .filterUndeclaredRequired,
            .omitEmptyRequired,
        ])

        guard let schema = JSONValue(value: parameters) else {
            throw TachikomaError.invalidInput("Failed to encode tool parameters for '\(tool.name)'")
        }

        return GoogleGenerateRequest.Tool.FunctionDeclaration(
            name: tool.name,
            description: tool.description,
            parameters: schema,
        )
    }

    private static func convertToolArguments(_ arguments: [String: AnyAgentToolValue]) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in arguments {
            let json = try value.toJSON()
            if let wrapped = JSONValue(value: json) {
                result[key] = wrapped
            }
        }
        return result
    }

    private static func convertToolResult(_ toolResult: AgentToolResult) throws -> JSONValue {
        let resultJSON = try toolResult.result.toJSON()
        let payload: [String: Any] = [
            "result": resultJSON,
            "is_error": toolResult.isError,
        ]
        guard let wrapped = JSONValue(value: payload) else {
            throw TachikomaError.invalidInput("Failed to encode tool result")
        }
        return wrapped
    }

    private func makeStreamRequest(body: Data) throws -> URLRequest {
        guard let apiKey else {
            throw TachikomaError.authenticationFailed("GEMINI_API_KEY not found")
        }

        let url = try OpenAICompatibleHelper.endpointURL(
            baseURL: self.baseURL,
            path: "/models/\(self.apiModelName):streamGenerateContent",
        )
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TachikomaError.invalidConfiguration("Invalid Google streaming URL")
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "alt", value: "sse"))
        items.append(URLQueryItem(name: "key", value: apiKey))
        components.queryItems = items

        guard let streamURL = components.url else {
            throw TachikomaError.invalidConfiguration("Invalid Google streaming URL")
        }

        var request = URLRequest(url: streamURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TachikomaError.networkError(NSError(domain: "GoogleProvider", code: -1))
        }
        return httpResponse
    }

    fileprivate static func mapFinishReason(_ reason: String) -> FinishReason {
        switch reason.lowercased() {
        case "stop", "stop_sequence":
            .stop
        case "max_tokens", "length":
            .length
        case "safety":
            .contentFilter
        default:
            .other
        }
    }
}

private struct GoogleSSEParser {
    private let onText: (String) -> Void
    private let onToolCall: (AgentToolCall) -> Void
    private(set) var usage: Usage?
    private(set) var finishReason: FinishReason?
    private(set) var sawToolCall: Bool = false

    init(
        onText: @escaping (String) -> Void,
        onToolCall: @escaping (AgentToolCall) -> Void,
    ) {
        self.onText = onText
        self.onToolCall = onToolCall
    }

    mutating func feed(line: String) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return }
        let payload = trimmed.dropFirst(5).drop { $0 == " " }
        try self.process(payload: String(payload))
    }

    mutating func feed(data: Data) throws {
        guard let body = String(data: data, encoding: .utf8) else {
            return
        }
        let lines = body.components(separatedBy: .newlines)
        for line in lines {
            try self.feed(line: line)
        }
    }

    mutating func finish() {}

    mutating func process(payload: String) throws {
        guard payload != "[DONE]" else { return }
        guard let data = payload.data(using: .utf8) else { return }
        let chunk = try JSONDecoder().decode(GoogleStreamChunk.self, from: data)

        if let candidates = chunk.candidates {
            for candidate in candidates {
                if let parts = candidate.content?.parts {
                    for part in parts {
                        if let text = part.text, !text.isEmpty {
                            self.onText(text)
                        }
                        if
                            let functionCall = part.functionCall,
                            let toolCall = Self.convertToolCall(functionCall, thoughtSignature: part.thoughtSignature)
                        {
                            self.sawToolCall = true
                            self.onToolCall(toolCall)
                        }
                    }
                }
                if let reason = candidate.finishReason {
                    self.finishReason = GoogleProvider.mapFinishReason(reason)
                }
            }
        }

        if let metadata = chunk.usageMetadata {
            let input = metadata.promptTokenCount ?? 0
            let output = metadata.candidatesTokenCount
                ?? max(0, (metadata.totalTokenCount ?? 0) - (metadata.promptTokenCount ?? 0))
            self.usage = Usage(inputTokens: input, outputTokens: output)
        }
    }

    func makeDoneDelta() -> TextStreamDelta {
        let finishReason: FinishReason? = if self.sawToolCall {
            .toolCalls
        } else {
            self.finishReason
        }
        return TextStreamDelta.done(usage: self.usage, finishReason: finishReason)
    }

    private static func convertToolCall(
        _ functionCall: GoogleStreamChunk.Candidate.Content.Part.FunctionCall,
        thoughtSignature: String?,
    )
        -> AgentToolCall?
    {
        var arguments: [String: AnyAgentToolValue] = [:]
        for (key, value) in functionCall.args ?? [:] {
            do {
                arguments[key] = try AnyAgentToolValue.fromJSON(value.value)
            } catch {
                continue
            }
        }

        let id = functionCall.id ?? UUID().uuidString
        return AgentToolCall(
            id: id,
            name: functionCall.name,
            arguments: arguments,
            namespace: nil,
            recipient: thoughtSignature,
        )
    }
}

private struct GoogleStreamChunk: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
                let functionCall: FunctionCall?
                let thoughtSignature: String?

                struct FunctionCall: Decodable {
                    let id: String?
                    let name: String
                    let args: [String: JSONValue]?
                }
            }

            let parts: [Part]?
        }

        let content: Content?
        let finishReason: String?
    }

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
    }

    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
}

private struct GoogleGenerateRequest: Encodable {
    struct Content: Encodable {
        struct InlineData: Encodable {
            let mimeType: String
            let data: String

            enum CodingKeys: String, CodingKey { case mimeType, data }
        }

        struct Part: Encodable {
            let text: String?
            let inlineData: InlineData?
            let functionCall: FunctionCall?
            let functionResponse: FunctionResponse?
            let thoughtSignature: String?

            enum CodingKeys: String, CodingKey {
                case text
                case inlineData
                case functionCall
                case functionResponse
                case thoughtSignature
            }
        }

        struct FunctionCall: Encodable {
            let id: String
            let name: String
            let args: [String: JSONValue]
        }

        struct FunctionResponse: Encodable {
            let id: String
            let name: String
            let response: JSONValue
        }

        let role: String
        let parts: [Part]
    }

    struct Tool: Encodable {
        let functionDeclarations: [FunctionDeclaration]

        struct FunctionDeclaration: Encodable {
            let name: String
            let description: String
            let parameters: JSONValue
        }
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int
        let topP: Double
        let topK: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case maxOutputTokens
            case topP
            case topK
        }
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
    let systemInstruction: Content?
    let tools: [Tool]?
}
