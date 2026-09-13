import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider for LMStudio local model server
public actor LMStudioProvider: ModelProvider {
    // MARK: - Properties

    // Store the actual URL internally as non-optional
    private let actualBaseURL: String
    private let configuredApiKey: String?
    private let configuredModelId: String
    private let configuredCapabilities: ModelCapabilities

    /// Expose as optional for protocol conformance, but it's never actually nil
    public nonisolated var baseURL: String? {
        self.actualBaseURL
    }

    public nonisolated var apiKey: String? {
        self.configuredApiKey
    }

    public nonisolated var modelId: String {
        self.configuredModelId
    }

    public nonisolated var capabilities: ModelCapabilities {
        self.configuredCapabilities
    }

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Initialization

    public init(
        baseURL: String = "http://localhost:1234/v1",
        modelId: String = "openai/gpt-oss-20b",
        apiKey: String? = nil,
        sessionConfiguration: URLSessionConfiguration = .default,
    ) {
        self.actualBaseURL = baseURL
        self.configuredModelId = modelId
        self.configuredApiKey = apiKey
        self.configuredCapabilities = ModelCapabilities(
            supportsTools: true,
            supportsStreaming: true,
            contextLength: 16384,
            maxOutputTokens: 4096,
        )

        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 300 // 5 minutes for local models
        config.timeoutIntervalForResource = 600 // 10 minutes total
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auto Detection

    /// Automatically detect if LMStudio is running
    public static func autoDetect() async throws -> LMStudioProvider? {
        // Automatically detect if LMStudio is running
        let commonURLs = [
            "http://localhost:1234/v1",
            "http://127.0.0.1:1234/v1",
            "http://0.0.0.0:1234/v1",
        ]

        for url in commonURLs {
            let provider = LMStudioProvider(baseURL: url)
            if let status = await (try? provider.healthCheck()) {
                return LMStudioProvider(baseURL: url, modelId: status.model ?? "openai/gpt-oss-20b")
            }
        }

        return nil
    }

    // MARK: - Health Check

    public struct HealthStatus: Codable, Sendable {
        public let status: String
        public let model: String?
        public let version: String?
    }

    public func healthCheck() async throws -> HealthStatus {
        let url = try OpenAICompatibleHelper.endpointURL(baseURL: self.actualBaseURL, path: "/models")
        let (data, _) = try await session.data(from: url)

        // Parse models endpoint response
        let response = try decoder.decode(ModelsResponse.self, from: data)

        return HealthStatus(
            status: "ok",
            model: response.data.first?.id,
            version: "1.0",
        )
    }

    // MARK: - Model Management

    public struct Model: Codable, Sendable {
        public let id: String
        public let object: String
        public let created: Int
        public let owned_by: String
    }

    struct ModelsResponse: Codable {
        let data: [Model]
    }

    public func listModels() async throws -> [Model] {
        let url = try OpenAICompatibleHelper.endpointURL(baseURL: self.actualBaseURL, path: "/models")
        let (data, _) = try await session.data(from: url)
        let response = try decoder.decode(ModelsResponse.self, from: data)
        return response.data
    }

    // MARK: - Text Generation

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        let openAIRequest = try mapToOpenAIRequest(request)

        var urlRequest = try URLRequest(url: OpenAICompatibleHelper.endpointURL(
            baseURL: self.actualBaseURL,
            path: "/chat/completions",
        ))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try self.encoder.encode(openAIRequest)

        let (data, _) = try await session.data(for: urlRequest)
        let openAIResponse = try decoder.decode(LMStudioResponse.self, from: data)

        return try self.mapFromOpenAIResponse(openAIResponse, request: request)
    }

    // MARK: - Streaming

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        let openAIRequest = try mapToOpenAIRequest(request, streaming: true)

        var urlRequest = try URLRequest(url: OpenAICompatibleHelper.endpointURL(
            baseURL: self.actualBaseURL,
            path: "/chat/completions",
        ))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try self.encoder.encode(openAIRequest)

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    #if canImport(FoundationNetworking)
                    // This adapter does not offer streaming on Linux.
                    continuation
                        .finish(throwing: TachikomaError.unsupportedOperation("Streaming not supported on Linux"))
                    #else
                    let (bytes, _) = try await session.bytes(for: urlRequest)

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }

                        let jsonString = String(line.dropFirst(6))
                        guard jsonString != "[DONE]" else {
                            continuation.finish()
                            return
                        }

                        if
                            let data = jsonString.data(using: .utf8),
                            let chunk = try? self.decoder.decode(LMStudioStreamChunk.self, from: data),
                            let delta = chunk.choices.first?.delta
                        {
                            // Parse multi-channel responses
                            if let content = delta.content {
                                let channels = LocalModelResponseParser.parseChanneledResponse(content)

                                for (channel, text) in channels {
                                    continuation.yield(TextStreamDelta.text(text, channel: channel))
                                }
                            }

                            // Handle tool calls - emit as text for now
                            if let toolCalls = delta.tool_calls {
                                for toolCall in toolCalls {
                                    if let name = toolCall.function?.name {
                                        continuation.yield(TextStreamDelta.text("[Calling tool: \(name)]"))
                                    }
                                }
                            }
                        }
                    }

                    continuation.finish()
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    // MARK: - Request Mapping

    private func mapToOpenAIRequest(_ request: ProviderRequest, streaming: Bool = false) throws -> LMStudioRequest {
        let messages = try OpenAICompatibleHelper.convertMessages(request.messages)

        var body: [String: Any] = [
            "model": modelId,
            "stream": streaming,
        ]

        // Map generation settings
        let settings = request.settings
        if let maxTokens = settings.maxTokens {
            body["max_tokens"] = maxTokens
        }
        if let temperature = settings.temperature {
            body["temperature"] = self.mapTemperatureForReasoningEffort(
                temperature,
                effort: settings.reasoningEffort,
            )
        }
        if let topP = settings.topP {
            body["top_p"] = topP
        }
        if let stopSequences = settings.stopSequences {
            body["stop"] = stopSequences
        }

        // Map reasoning effort to LMStudio parameters
        if let effort = settings.reasoningEffort {
            let params = self.mapReasoningEffortToParams(effort)
            body.merge(params) { _, new in new }
        }

        // Add tools if present
        if let tools = request.tools {
            body["tools"] = try tools.map { tool in
                try [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.jsonSchema(),
                    ],
                ]
            }
        }

        return LMStudioRequest(body: body, messages: messages)
    }

    private func mapReasoningEffortToParams(_ effort: ReasoningEffort) -> [String: Any] {
        switch effort {
        case .high, .xhigh, .max:
            [
                "repeat_penalty": 1.1,
                "presence_penalty": 0.1,
                "frequency_penalty": 0.1,
                "top_k": 50,
                "typical_p": 1.0,
                "min_p": 0.05,
                "tfs_z": 1.0,
                "mirostat": 0,
            ]
        case .medium:
            [
                "repeat_penalty": 1.05,
                "top_k": 40,
                "typical_p": 0.95,
                "min_p": 0.1,
            ]
        case .low:
            [
                "repeat_penalty": 1.0,
                "top_k": 30,
                "typical_p": 0.9,
                "min_p": 0.2,
            ]
        }
    }

    private func mapTemperatureForReasoningEffort(_ base: Double, effort: ReasoningEffort?) -> Double {
        guard let effort else { return base }

        switch effort {
        case .high, .xhigh, .max:
            return min(base * 1.2, 1.5) // Increase temperature for exploration
        case .medium:
            return base
        case .low:
            return base * 0.7 // Decrease for focused responses
        }
    }

    // MARK: - Response Mapping

    private func mapFromOpenAIResponse(
        _ response: LMStudioResponse,
        request _: ProviderRequest,
    ) throws
        -> ProviderResponse
    {
        guard let choice = response.choices.first else {
            throw TachikomaError.apiError("No choices in response")
        }

        let content = choice.message.content ?? ""

        // Parse multi-channel responses
        let channels = LocalModelResponseParser.parseChanneledResponse(content)

        // Extract final response or use full content
        let finalText = channels[.final] ?? content

        return try ProviderResponse(
            text: finalText,
            usage: response.usage.map { usage in
                Usage(
                    inputTokens: usage.prompt_tokens,
                    outputTokens: usage.completion_tokens,
                    cost: nil,
                )
            },
            finishReason: self.mapFinishReason(choice.finish_reason),
            toolCalls: choice.message.tool_calls?.map { toolCall in
                try AgentToolCall(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    arguments: self.parseToolArguments(toolCall.function.arguments),
                )
            },
        )
    }

    private func mapFinishReason(_ reason: String?) -> FinishReason? {
        switch reason {
        case "stop": .stop
        case "length": .length
        case "tool_calls": .toolCalls
        default: nil
        }
    }

    private func parseToolArguments(_ json: String?) throws -> [String: AnyAgentToolValue] {
        guard
            let json,
            let data = json.data(using: .utf8) else
        {
            return [:]
        }

        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var args: [String: AnyAgentToolValue] = [:]

        for (key, value) in dict {
            args[key] = try AnyAgentToolValue.fromJSON(value)
        }

        return args
    }
}

// MARK: - OpenAI Format Types

private struct LMStudioRequest: Encodable {
    let body: [String: Any]
    let messages: [OpenAIChatMessage]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in self.body {
            try container.encode(AnyEncodable(value), forKey: DynamicCodingKey(stringLiteral: key))
        }
        try container.encode(self.messages, forKey: DynamicCodingKey(stringLiteral: "messages"))
    }
}

// MARK: - OpenAI Format Types (continued)

private struct LMStudioResponse: Decodable {
    let id: String
    let object: String
    let created: Int
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let index: Int
        let message: Message
        let finish_reason: String?

        struct Message: Decodable {
            let role: String
            let content: String?
            let tool_calls: [AgentToolCall]?

            struct AgentToolCall: Decodable {
                let id: String
                let type: String
                let function: Function

                struct Function: Decodable {
                    let name: String
                    let arguments: String
                }
            }
        }
    }

    struct Usage: Decodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
}

private struct LMStudioStreamChunk: Decodable {
    let id: String
    let object: String
    let created: Int
    let model: String?
    let choices: [Choice]

    struct Choice: Decodable {
        let index: Int
        let delta: Delta
        let finish_reason: String?

        struct Delta: Decodable {
            let role: String?
            let content: String?
            let tool_calls: [AgentToolCall]?

            struct AgentToolCall: Decodable {
                let index: Int?
                let id: String?
                let type: String?
                let function: Function?

                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }
            }
        }
    }
}

// MARK: - Response Parser

public enum LocalModelResponseParser {
    /// Parse multi-channel responses from local models
    public static func parseChanneledResponse(_ text: String) -> [ResponseChannel: String] {
        // Parse multi-channel responses from local models
        var channels: [ResponseChannel: String] = [:]

        // Parse XML-style tags
        if let thinking = extractTag(text, "thinking") {
            channels[.thinking] = thinking
        }
        if let analysis = extractTag(text, "analysis") {
            channels[.analysis] = analysis
        }
        if let commentary = extractTag(text, "commentary") {
            channels[.commentary] = commentary
        }
        if let final = extractTag(text, "final") {
            channels[.final] = final
        } else {
            // If no explicit final tag, clean the text of all tags
            let cleaned = self.removeAllTags(text)
            if !cleaned.isEmpty {
                channels[.final] = cleaned
            }
        }

        // If no channels found, treat entire text as final
        if channels.isEmpty {
            channels[.final] = text
        }

        return channels
    }

    private static func extractTag(_ text: String, _ tag: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"

        // Find the opening tag
        guard let startRange = text.range(of: openTag) else {
            return nil
        }

        // Find the closing tag after the opening tag
        let searchStart = startRange.upperBound
        guard let endRange = text[searchStart...].range(of: closeTag) else {
            return nil
        }

        // Extract the content between tags
        let contentStart = startRange.upperBound
        let contentEnd = endRange.lowerBound

        return String(text[contentStart..<contentEnd])
    }

    private static func removeAllTags(_ text: String) -> String {
        let tags = ["thinking", "analysis", "commentary", "final"]
        var result = text

        for tag in tags {
            let pattern = "<\(tag)>.*?</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(location: 0, length: result.count),
                    withTemplate: "",
                )
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Error Types

public enum LMStudioError: Error, LocalizedError {
    case serverNotRunning
    case modelNotLoaded
    case insufficientMemory(required: Int, available: Int)
    case modelNotFound(String)
    case connectionFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            "LMStudio server is not running. Please start the server in LMStudio."
        case .modelNotLoaded:
            "No model is currently loaded in LMStudio."
        case let .insufficientMemory(required, available):
            "Insufficient memory: \(required)GB required, \(available)GB available."
        case let .modelNotFound(name):
            "Model '\(name)' not found in LMStudio."
        case let .connectionFailed(error):
            "Connection to LMStudio failed: \(error.localizedDescription)"
        }
    }
}
