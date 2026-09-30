import Foundation

// MARK: - AI SDK Core Types

/// Error types for the modern Tachikoma API
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum TachikomaError: Error, LocalizedError, Sendable {
    case modelNotFound(String)
    case invalidConfiguration(String)
    case unsupportedOperation(String)
    case unavailable(String)
    case apiError(String)
    case networkError(Error)
    case toolCallFailed(String)
    case invalidInput(String)
    case rateLimited(retryAfter: TimeInterval?)
    case authenticationFailed(String)
    case apiCallError(APICallError)
    case retryError(RetryError)

    public var errorDescription: String? {
        switch self {
        case let .modelNotFound(model):
            "Model not found: \(model)"
        case let .invalidConfiguration(message):
            "Invalid configuration: \(message)"
        case let .unsupportedOperation(operation):
            "Unsupported operation: \(operation)"
        case let .unavailable(message):
            "Unavailable: \(message)"
        case let .apiError(message):
            "API error: \(message)"
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case let .toolCallFailed(message):
            "Tool call failed: \(message)"
        case let .invalidInput(message):
            "Invalid input: \(message)"
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Rate limited. Retry after \(retryAfter) seconds"
            } else {
                "Rate limited"
            }
        case let .authenticationFailed(message):
            "Authentication failed: \(message)"
        case let .apiCallError(error):
            error.errorDescription ?? "API call failed"
        case let .retryError(error):
            error.errorDescription ?? "Retry failed"
        }
    }
}

/// Structured API call error following Vercel AI SDK pattern
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct APICallError: Error, LocalizedError, Sendable {
    public let statusCode: Int?
    public let responseBody: String?
    public let provider: String
    public let modelId: String?
    public let requestId: String?
    public let errorType: ErrorType
    public let message: String
    public let retryAfter: TimeInterval?

    public enum ErrorType: String, Sendable, Codable {
        case rateLimitExceeded = "rate_limit_exceeded"
        case invalidRequest = "invalid_request"
        case authenticationFailed = "authentication_failed"
        case modelNotFound = "model_not_found"
        case serverError = "server_error"
        case networkError = "network_error"
        case timeout
        case unknown
    }

    public init(
        statusCode: Int? = nil,
        responseBody: String? = nil,
        provider: String,
        modelId: String? = nil,
        requestId: String? = nil,
        errorType: ErrorType,
        message: String,
        retryAfter: TimeInterval? = nil,
    ) {
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.provider = provider
        self.modelId = modelId
        self.requestId = requestId
        self.errorType = errorType
        self.message = message
        self.retryAfter = retryAfter
    }

    public var errorDescription: String? {
        var description = "[\(provider)] \(message)"
        if let statusCode {
            description += " (HTTP \(statusCode))"
        }
        if let modelId {
            description += " [Model: \(modelId)]"
        }
        return description
    }

    /// Check if an error is an APICallError
    public static func isInstance(_ error: Error) -> Bool {
        // Check if an error is an APICallError
        error is APICallError || (error as? TachikomaError)?.apiCallError != nil
    }

    /// Extract APICallError from any error
    public static func extract(from error: Error) -> APICallError? {
        // Extract APICallError from any error
        if let apiError = error as? APICallError {
            return apiError
        }
        if case let .apiCallError(apiError) = error as? TachikomaError {
            return apiError
        }
        return nil
    }
}

/// Retry error with accumulated failure information
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct RetryError: Error, LocalizedError, Sendable {
    public let reason: String
    public let lastError: Error?
    public let errors: [Error]
    public let attempts: Int

    public init(
        reason: String,
        lastError: Error? = nil,
        errors: [Error] = [],
        attempts: Int = 0,
    ) {
        self.reason = reason
        self.lastError = lastError
        self.errors = errors
        self.attempts = attempts
    }

    public var errorDescription: String? {
        var description = "Retry failed: \(reason)"
        if self.attempts > 0 {
            description += " after \(self.attempts) attempts"
        }
        if let lastError {
            description += ". Last error: \(lastError.localizedDescription)"
        }
        return description
    }
}

extension TachikomaError {
    /// Helper to extract APICallError if this is an apiCallError case
    var apiCallError: APICallError? {
        if case let .apiCallError(error) = self {
            return error
        }
        return nil
    }
}

// MARK: - API Configuration

/// OpenAI API mode selection
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum OpenAIAPIMode: String, Sendable, CaseIterable {
    case chat
    case responses

    public var displayName: String {
        switch self {
        case .chat: "Chat Completions API"
        case .responses: "Responses API"
        }
    }

    /// Determine default API mode for a given model
    public static func defaultMode(for model: LanguageModel.OpenAI) -> OpenAIAPIMode {
        // Determine default API mode for a given model
        switch model {
        case .chatLatest, .gpt5ChatLatest,
             .gpt61Sol, .gpt6Astra, .gpt6Sol, .gpt6Luna,
             .gpt56Sol, .gpt56Terra, .gpt56Luna,
             .gpt5, .gpt5Pro, .gpt5Mini, .gpt5Nano, .gpt54, .gpt54Mini, .gpt54Nano, .gpt55:
            .responses // GPT-5 defaults to Responses API
        default:
            .chat // All other models use Chat Completions API
        }
    }
}

// MARK: - Message Types

/// A message in a conversation with an AI model
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ModelMessage: Sendable, Codable, Equatable {
    public let id: String
    public let role: Role
    public let content: [ContentPart]
    public let timestamp: Date
    public let channel: ResponseChannel?
    public let metadata: MessageMetadata?

    public enum Role: String, Sendable, Codable, CaseIterable {
        case system
        case user
        case assistant
        case tool
    }

    public enum ContentPart: Sendable, Codable, Equatable {
        case text(String)
        case image(ImageContent)
        case reasoning(ReasoningContent)
        case toolCall(AgentToolCall)
        case toolResult(AgentToolResult)

        public struct ImageContent: Sendable, Codable, Equatable {
            public let data: String // base64 encoded
            public let mimeType: String

            public init(data: String, mimeType: String = "image/png") {
                self.data = data
                self.mimeType = mimeType
            }
        }

        /// Opaque reasoning state that a provider requires on subsequent turns.
        public struct ReasoningContent: Sendable, Codable, Equatable {
            public let id: String
            public let encryptedContent: String
            public let summary: [Summary]?

            public struct Summary: Sendable, Codable, Equatable {
                public let type: String
                public let text: String

                public init(type: String, text: String) {
                    self.type = type
                    self.text = text
                }
            }

            public init(id: String, encryptedContent: String, summary: [Summary]? = nil) {
                self.id = id
                self.encryptedContent = encryptedContent
                self.summary = summary
            }
        }
    }

    public init(
        id: String = UUID().uuidString,
        role: Role,
        content: [ContentPart],
        timestamp: Date = Date(),
        channel: ResponseChannel? = nil,
        metadata: MessageMetadata? = nil,
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.channel = channel
        self.metadata = metadata
    }

    /// Convenience initializers
    public static func system(_ text: String) -> ModelMessage {
        ModelMessage(role: .system, content: [.text(text)])
    }

    public static func user(_ text: String) -> ModelMessage {
        ModelMessage(role: .user, content: [.text(text)])
    }

    public static func assistant(_ text: String) -> ModelMessage {
        ModelMessage(role: .assistant, content: [.text(text)])
    }

    public static func user(text: String, images: [ContentPart.ImageContent]) -> ModelMessage {
        var content: [ContentPart] = [.text(text)]
        content.append(contentsOf: images.map { .image($0) })
        return ModelMessage(role: .user, content: content)
    }
}

// MARK: - Usage Statistics

/// Token usage statistics for a generation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct Usage: Sendable, Codable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let cost: Cost?

    public struct Cost: Sendable, Codable, Equatable {
        public let input: Double
        public let output: Double
        public let total: Double

        public init(input: Double, output: Double) {
            self.input = input
            self.output = output
            self.total = input + output
        }
    }

    public init(inputTokens: Int, outputTokens: Int, cost: Cost? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = inputTokens + outputTokens
        self.cost = cost
    }
}

// MARK: - Finish Reason

/// Reason why generation finished
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum FinishReason: String, Sendable, Codable, CaseIterable {
    case stop
    case length
    case toolCalls = "tool_calls"
    case contentFilter = "content_filter"
    case error
    case cancelled
    case other
}

// MARK: - Image Input

/// Input type for image analysis
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum ImageInput: Sendable {
    case base64(String)
    case url(String)
    case filePath(String)
}

// MARK: - Generation Settings

/// Settings for text generation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct GenerationSettings: Sendable {
    public enum StreamBufferingMode: String, Sendable, Codable {
        case incremental
        case untilTerminal
    }

    public let maxTokens: Int?
    public let temperature: Double?
    public let topP: Double?
    public let topK: Int?
    public let frequencyPenalty: Double?
    public let presencePenalty: Double?
    public let stopSequences: [String]?
    public let reasoningEffort: ReasoningEffort?
    public let stopConditions: (any StopCondition)?
    public let seed: Int?
    public let providerOptions: ProviderOptions
    public let streamBuffering: StreamBufferingMode

    public init(
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        stopSequences: [String]? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        stopConditions: (any StopCondition)? = nil,
        seed: Int? = nil,
        providerOptions: ProviderOptions = .init(),
        streamBuffering: StreamBufferingMode = .incremental,
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.stopSequences = stopSequences
        self.reasoningEffort = reasoningEffort
        self.stopConditions = stopConditions
        self.seed = seed
        self.providerOptions = providerOptions
        self.streamBuffering = streamBuffering
    }

    public static let `default` = GenerationSettings()

    public func withStreamBuffering(_ mode: StreamBufferingMode) -> GenerationSettings {
        GenerationSettings(
            maxTokens: self.maxTokens,
            temperature: self.temperature,
            topP: self.topP,
            topK: self.topK,
            frequencyPenalty: self.frequencyPenalty,
            presencePenalty: self.presencePenalty,
            stopSequences: self.stopSequences,
            reasoningEffort: self.reasoningEffort,
            stopConditions: self.stopConditions,
            seed: self.seed,
            providerOptions: self.providerOptions,
            streamBuffering: mode,
        )
    }
}

/// Manual Codable conformance excluding non-codable stopConditions
extension GenerationSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case maxTokens
        case temperature
        case topP
        case topK
        case frequencyPenalty
        case presencePenalty
        case stopSequences
        case reasoningEffort
        case seed
        case providerOptions
        case streamBuffering
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        self.topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        self.topK = try container.decodeIfPresent(Int.self, forKey: .topK)
        self.frequencyPenalty = try container.decodeIfPresent(Double.self, forKey: .frequencyPenalty)
        self.presencePenalty = try container.decodeIfPresent(Double.self, forKey: .presencePenalty)
        self.stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences)
        self.reasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        self.seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        self.providerOptions = try container.decodeIfPresent(ProviderOptions.self, forKey: .providerOptions) ?? .init()
        self.streamBuffering = try container
            .decodeIfPresent(StreamBufferingMode.self, forKey: .streamBuffering) ?? .incremental
        self.stopConditions = nil // Can't decode function types
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(self.temperature, forKey: .temperature)
        try container.encodeIfPresent(self.topP, forKey: .topP)
        try container.encodeIfPresent(self.topK, forKey: .topK)
        try container.encodeIfPresent(self.frequencyPenalty, forKey: .frequencyPenalty)
        try container.encodeIfPresent(self.presencePenalty, forKey: .presencePenalty)
        try container.encodeIfPresent(self.stopSequences, forKey: .stopSequences)
        try container.encodeIfPresent(self.reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(self.seed, forKey: .seed)
        try container.encode(self.providerOptions, forKey: .providerOptions)
        try container.encode(self.streamBuffering, forKey: .streamBuffering)
        // Don't encode stopConditions since it can't be serialized
    }
}

// MARK: - Streaming Types

/// Result from streamText function with UI transformation utilities
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct StreamTextResult: Sendable {
    public let stream: AsyncThrowingStream<TextStreamDelta, Error>
    public let model: LanguageModel
    public let settings: GenerationSettings

    public init(
        stream: AsyncThrowingStream<TextStreamDelta, Error>,
        model: LanguageModel,
        settings: GenerationSettings,
    ) {
        self.stream = stream
        self.model = model
        self.settings = settings
    }

    /// Convert stream to UI message stream response format (following Vercel AI SDK pattern)
    public func toUIMessageStreamResponse(
        sendReasoning: Bool = false,
        headers: [String: String]? = nil,
    )
        -> UIMessageStreamResponse
    {
        // Convert stream to UI message stream response format (following Vercel AI SDK pattern)
        UIMessageStreamResponse(
            stream: self.stream,
            sendReasoning: sendReasoning,
            headers: headers,
        )
    }
}

/// UI Message stream response for client consumption
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct UIMessageStreamResponse: Sendable {
    public let stream: AsyncThrowingStream<TextStreamDelta, Error>
    public let sendReasoning: Bool
    public let headers: [String: String]?

    public init(
        stream: AsyncThrowingStream<TextStreamDelta, Error>,
        sendReasoning: Bool = false,
        headers: [String: String]? = nil,
    ) {
        self.stream = stream
        self.sendReasoning = sendReasoning
        self.headers = headers
    }
}

/// Stream delta event types
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TextStreamDelta: Sendable {
    public let type: StreamEventType
    public let content: String?
    public let channel: ResponseChannel?
    public let reasoningSignature: String?
    public let reasoningType: String?
    public let reasoningContent: ModelMessage.ContentPart.ReasoningContent?
    public let toolCall: AgentToolCall?
    public let toolResult: AgentToolResult?
    public let usage: Usage?
    public let finishReason: FinishReason?

    public enum StreamEventType: String, Sendable, Codable {
        case textDelta = "text_delta"
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case reasoning
        case done
    }

    public init(
        type: StreamEventType,
        content: String? = nil,
        channel: ResponseChannel? = nil,
        reasoningSignature: String? = nil,
        reasoningType: String? = nil,
        reasoningContent: ModelMessage.ContentPart.ReasoningContent? = nil,
        toolCall: AgentToolCall? = nil,
        toolResult: AgentToolResult? = nil,
        usage: Usage? = nil,
        finishReason: FinishReason? = nil,
    ) {
        self.type = type
        self.content = content
        self.channel = channel
        self.reasoningSignature = reasoningSignature
        self.reasoningType = reasoningType
        self.reasoningContent = reasoningContent
        self.toolCall = toolCall
        self.toolResult = toolResult
        self.usage = usage
        self.finishReason = finishReason
    }

    /// Convenience constructors
    public static func text(_ content: String, channel: ResponseChannel? = nil) -> TextStreamDelta {
        TextStreamDelta(type: .textDelta, content: content, channel: channel)
    }

    public static func reasoning(_ content: ModelMessage.ContentPart.ReasoningContent) -> TextStreamDelta {
        TextStreamDelta(type: .reasoning, reasoningContent: content)
    }

    public static func reasoning(_ content: String, signature: String? = nil, type: String? = nil) -> TextStreamDelta {
        TextStreamDelta(
            type: .reasoning,
            content: content,
            channel: .thinking,
            reasoningSignature: signature,
            reasoningType: type,
        )
    }

    public static func tool(_ call: AgentToolCall) -> TextStreamDelta {
        TextStreamDelta(type: .toolCall, toolCall: call)
    }

    public static func done(usage: Usage? = nil, finishReason: FinishReason? = nil) -> TextStreamDelta {
        TextStreamDelta(type: .done, usage: usage, finishReason: finishReason)
    }
}

// MARK: - Generation Result Types

/// Result from generateText function
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct GenerateTextResult: Sendable {
    public let text: String
    public let usage: Usage?
    public let finishReason: FinishReason?
    public let steps: [GenerationStep]
    public let messages: [ModelMessage]

    public init(
        text: String,
        usage: Usage? = nil,
        finishReason: FinishReason? = nil,
        steps: [GenerationStep] = [],
        messages: [ModelMessage] = [],
    ) {
        self.text = text
        self.usage = usage
        self.finishReason = finishReason
        self.steps = steps
        self.messages = messages
    }
}

/// Individual step in a multi-step generation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct GenerationStep: Sendable {
    public let stepIndex: Int
    public let text: String
    public let toolCalls: [AgentToolCall]
    public let toolResults: [AgentToolResult]
    public let usage: Usage?
    public let finishReason: FinishReason?

    public init(
        stepIndex: Int,
        text: String,
        toolCalls: [AgentToolCall] = [],
        toolResults: [AgentToolResult] = [],
        usage: Usage? = nil,
        finishReason: FinishReason? = nil,
    ) {
        self.stepIndex = stepIndex
        self.text = text
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.usage = usage
        self.finishReason = finishReason
    }
}

/// Result from generateObject function
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct GenerateObjectResult<T: Codable & Sendable>: Sendable {
    public let object: T
    public let usage: Usage?
    public let finishReason: FinishReason?

    public init(
        object: T,
        usage: Usage? = nil,
        finishReason: FinishReason? = nil,
    ) {
        self.object = object
        self.usage = usage
        self.finishReason = finishReason
    }
}

// MARK: - Multi-Channel Response Support

/// Response channel for multi-channel outputs (inspired by OpenAI Harmony)
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum ResponseChannel: String, Sendable, Codable, CaseIterable {
    case thinking // Chain of thought reasoning
    case analysis // Deep analysis of the problem
    case commentary // Meta-commentary about the response
    case final // Final answer to the user
}

/// Reasoning effort level for models that support it (GPT-5 thinking, opus-4, etc.)
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum ReasoningEffort: String, Sendable, Codable, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max
}

/// Metadata for messages (conversation context, etc.)
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct MessageMetadata: Sendable, Codable, Equatable {
    public let conversationId: String?
    public let turnId: String?
    public let customData: [String: String]?

    public init(
        conversationId: String? = nil,
        turnId: String? = nil,
        customData: [String: String]? = nil,
    ) {
        self.conversationId = conversationId
        self.turnId = turnId
        self.customData = customData
    }
}
