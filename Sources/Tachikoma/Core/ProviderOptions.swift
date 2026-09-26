import Foundation

// MARK: - Provider Options Container

/// Container for provider-specific options that aren't part of universal settings
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ProviderOptions: Sendable, Codable {
    /// OpenAI-specific options
    public var openai: OpenAIOptions?

    /// Anthropic-specific options
    public var anthropic: AnthropicOptions?

    /// Google-specific options
    public var google: GoogleOptions?

    /// Mistral-specific options
    public var mistral: MistralOptions?

    /// Groq-specific options
    public var groq: GroqOptions?

    /// Grok (xAI)-specific options
    public var grok: GrokOptions?

    public init(
        openai: OpenAIOptions? = nil,
        anthropic: AnthropicOptions? = nil,
        google: GoogleOptions? = nil,
        mistral: MistralOptions? = nil,
        groq: GroqOptions? = nil,
        grok: GrokOptions? = nil,
    ) {
        self.openai = openai
        self.anthropic = anthropic
        self.google = google
        self.mistral = mistral
        self.groq = groq
        self.grok = grok
    }
}

// MARK: - OpenAI Options

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct OpenAIOptions: Sendable, Codable {
    /// Whether to enable parallel tool calls
    public var parallelToolCalls: Bool?

    /// Response format (e.g., JSON mode)
    public var responseFormat: ResponseFormat?

    /// Random seed for deterministic output
    public var seed: Int?

    /// Verbosity level for GPT-5 models
    public var verbosity: Verbosity?

    /// Reasoning effort for GPT-5 models
    public var reasoningEffort: ReasoningEffort?

    /// Previous response ID for Responses API chaining
    public var previousResponseId: String?

    /// Frequency penalty (-2.0 to 2.0)
    public var frequencyPenalty: Double?

    /// Presence penalty (-2.0 to 2.0)
    public var presencePenalty: Double?

    /// Number of chat completion choices to generate
    public var n: Int?

    /// Whether to return log probabilities
    public var logprobs: Bool?

    /// Number of most likely tokens to return at each position
    public var topLogprobs: Int?

    public init(
        parallelToolCalls: Bool? = nil,
        responseFormat: ResponseFormat? = nil,
        seed: Int? = nil,
        verbosity: Verbosity? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        previousResponseId: String? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        n: Int? = nil,
        logprobs: Bool? = nil,
        topLogprobs: Int? = nil,
    ) {
        self.parallelToolCalls = parallelToolCalls
        self.responseFormat = responseFormat
        self.seed = seed
        self.verbosity = verbosity
        self.reasoningEffort = reasoningEffort
        self.previousResponseId = previousResponseId
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.n = n
        self.logprobs = logprobs
        self.topLogprobs = topLogprobs
    }

    public enum ResponseFormat: String, Sendable, Codable {
        case text
        case json = "json_object"
        case jsonSchema = "json_schema"
    }

    public enum Verbosity: String, Sendable, Codable {
        case low
        case medium
        case high
    }

    public enum ReasoningEffort: String, Sendable, Codable {
        case none
        case minimal
        case low
        case medium
        case high
        case xhigh
        case max
    }
}

// MARK: - Anthropic Options

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct AnthropicOptions: Sendable, Codable {
    /// Thinking mode for Claude models
    public var thinking: ThinkingMode?

    /// Cache control for conversation context
    public var cacheControl: CacheControl?

    /// Maximum number of tokens to sample before stopping
    public var maxTokensToSample: Int?

    /// Stop sequences specific to Anthropic
    public var stopSequences: [String]?

    /// Metadata for the request
    public var metadata: [String: String]?

    public init(
        thinking: ThinkingMode? = nil,
        cacheControl: CacheControl? = nil,
        maxTokensToSample: Int? = nil,
        stopSequences: [String]? = nil,
        metadata: [String: String]? = nil,
    ) {
        self.thinking = thinking
        self.cacheControl = cacheControl
        self.maxTokensToSample = maxTokensToSample
        self.stopSequences = stopSequences
        self.metadata = metadata
    }

    public enum ThinkingMode: Sendable, Codable {
        case disabled
        case enabled(budgetTokens: Int)
        case adaptive

        private enum CodingKeys: String, CodingKey {
            case type
            case budgetTokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "disabled":
                self = .disabled
            case "enabled":
                let budget = try container.decode(Int.self, forKey: .budgetTokens)
                self = .enabled(budgetTokens: budget)
            case "adaptive":
                self = .adaptive
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown thinking mode type: \(type)",
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .disabled:
                try container.encode("disabled", forKey: .type)
            case let .enabled(budgetTokens):
                try container.encode("enabled", forKey: .type)
                try container.encode(budgetTokens, forKey: .budgetTokens)
            case .adaptive:
                try container.encode("adaptive", forKey: .type)
            }
        }
    }

    public enum CacheControl: String, Sendable, Codable {
        case ephemeral
        case persistent
    }
}

// MARK: - Google Options

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct GoogleOptions: Sendable, Codable {
    /// Thinking configuration for Gemini models
    public var thinkingConfig: ThinkingConfig?

    /// Safety settings
    public var safetySettings: SafetySettings?

    /// Candidate count
    public var candidateCount: Int?

    /// Stop sequences
    public var stopSequences: [String]?

    public init(
        thinkingConfig: ThinkingConfig? = nil,
        safetySettings: SafetySettings? = nil,
        candidateCount: Int? = nil,
        stopSequences: [String]? = nil,
    ) {
        self.thinkingConfig = thinkingConfig
        self.safetySettings = safetySettings
        self.candidateCount = candidateCount
        self.stopSequences = stopSequences
    }

    public struct ThinkingConfig: Sendable, Codable {
        public var budgetTokens: Int
        public var includeThoughts: Bool

        public init(budgetTokens: Int, includeThoughts: Bool = false) {
            self.budgetTokens = budgetTokens
            self.includeThoughts = includeThoughts
        }
    }

    public enum SafetySettings: String, Sendable, Codable {
        case strict
        case moderate
        case relaxed
    }
}

// MARK: - Mistral Options

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct MistralOptions: Sendable, Codable {
    /// Whether to use safe mode
    public var safeMode: Bool?

    /// Random seed for deterministic output
    public var randomSeed: Int?

    public init(
        safeMode: Bool? = nil,
        randomSeed: Int? = nil,
    ) {
        self.safeMode = safeMode
        self.randomSeed = randomSeed
    }
}

// MARK: - Groq Options

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct GroqOptions: Sendable, Codable {
    /// Speed optimization level
    public var speed: SpeedLevel?

    public init(speed: SpeedLevel? = nil) {
        self.speed = speed
    }

    public enum SpeedLevel: String, Sendable, Codable {
        case normal
        case fast
        case ultraFast = "ultra_fast"
    }
}

// MARK: - Grok Options

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct GrokOptions: Sendable, Codable {
    /// Fun mode for more creative responses
    public var funMode: Bool?

    /// Include current events context
    public var includeCurrentEvents: Bool?

    public init(
        funMode: Bool? = nil,
        includeCurrentEvents: Bool? = nil,
    ) {
        self.funMode = funMode
        self.includeCurrentEvents = includeCurrentEvents
    }
}
