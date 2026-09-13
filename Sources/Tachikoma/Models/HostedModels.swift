import Foundation

extension LanguageModel {
    public enum Google: String, Sendable, Hashable, CaseIterable {
        case gemini35Flash = "gemini-3.5-flash"
        case gemini31ProPreview = "gemini-3.1-pro-preview"
        case gemini31FlashLite = "gemini-3.1-flash-lite"
        // NOTE: As of 2025-12-17, ListModels exposes Gemini 3 Flash as `gemini-3-flash-preview` on v1beta.
        // We keep the user-facing identifier as `gemini-3-flash` and map it to the preview model id for API calls.
        case gemini3Flash = "gemini-3-flash-preview"
        case gemini25Pro = "gemini-2.5-pro"
        case gemini25Flash = "gemini-2.5-flash"
        case gemini25FlashLite = "gemini-2.5-flash-lite"

        public var apiModelId: String {
            self.rawValue
        }

        public var userFacingModelId: String {
            switch self {
            case .gemini35Flash:
                "gemini-3.5-flash"
            case .gemini3Flash:
                "gemini-3-flash"
            case .gemini31ProPreview:
                "gemini-3.1-pro-preview"
            case .gemini31FlashLite:
                "gemini-3.1-flash-lite"
            default:
                self.rawValue
            }
        }

        public var supportsVision: Bool {
            true
        }

        public var supportsTools: Bool {
            true
        }

        public var supportsAudioInput: Bool {
            switch self {
            case .gemini35Flash, .gemini31ProPreview, .gemini3Flash, .gemini25Pro, .gemini25Flash:
                true
            case .gemini31FlashLite, .gemini25FlashLite:
                false
            }
        }

        public var supportsAudioOutput: Bool {
            false
        }

        public var contextLength: Int {
            switch self {
            case .gemini35Flash, .gemini31ProPreview, .gemini31FlashLite, .gemini3Flash, .gemini25Pro,
                 .gemini25Flash:
                1_048_576
            case .gemini25FlashLite:
                524_288
            }
        }
    }

    public enum MiniMax: String, Sendable, Hashable, CaseIterable {
        case m27 = "MiniMax-M2.7"
        case m27Highspeed = "MiniMax-M2.7-highspeed"
        case m3 = "MiniMax-M3"

        public var modelId: String {
            self.rawValue
        }

        public var supportsVision: Bool {
            switch self {
            case .m3: true
            case .m27, .m27Highspeed: false
            }
        }

        public var supportsTools: Bool {
            true
        }

        public var supportsAudioInput: Bool {
            false
        }

        public var supportsAudioOutput: Bool {
            false
        }

        public var contextLength: Int {
            switch self {
            case .m3: 1_000_000
            case .m27, .m27Highspeed: 204_800
            }
        }
    }

    /// Kimi (Moonshot AI) models exposed via the OpenAI-compatible API.
    public enum Kimi: String, Sendable, Hashable, CaseIterable {
        case k27Code = "kimi-k2.7-code"
        case k27CodeHighspeed = "kimi-k2.7-code-highspeed"
        case k26 = "kimi-k2.6"

        public var modelId: String {
            self.rawValue
        }

        public var supportsVision: Bool {
            true
        }

        public var supportsTools: Bool {
            true
        }

        public var supportsAudioInput: Bool {
            false
        }

        public var supportsAudioOutput: Bool {
            false
        }

        public var contextLength: Int {
            262_144
        }
    }

    public enum Mistral: String, Sendable, Hashable, CaseIterable {
        case largeLatest = "mistral-large-latest"
        case mediumLatest = "mistral-medium-latest"
        case medium35 = "mistral-medium-3-5"
        case smallLatest = "mistral-small-latest"
        case nemo = "open-mistral-nemo-2407"
        case codestralLatest = "codestral-latest"

        public var supportsVision: Bool {
            switch self {
            case .largeLatest, .mediumLatest, .medium35, .smallLatest: true
            default: false
            }
        }

        public var supportsTools: Bool {
            true
        }

        public var supportsAudioInput: Bool {
            false
        } // Mistral doesn't support audio yet
        public var supportsAudioOutput: Bool {
            false
        }

        public var contextLength: Int {
            switch self {
            case .largeLatest, .mediumLatest, .medium35, .smallLatest: 128_000
            case .nemo: 128_000
            case .codestralLatest: 256_000
            }
        }
    }

    public enum Groq: String, Sendable, Hashable, CaseIterable {
        // Groq-hosted models (ultra-fast inference)
        case gptOSS120B = "openai/gpt-oss-120b"
        case gptOSS20B = "openai/gpt-oss-20b"
        case llama3370b = "llama-3.3-70b-versatile"
        case llama318b = "llama-3.1-8b-instant"
        case llama4Maverick = "meta-llama/llama-4-maverick-17b-128e-instruct"
        case llama4Scout = "meta-llama/llama-4-scout-17b-16e-instruct"

        public var supportsVision: Bool {
            false
        } // Groq models don't support vision yet
        public var supportsTools: Bool {
            true
        }

        public var supportsAudioInput: Bool {
            false
        } // Groq focuses on text inference speed
        public var supportsAudioOutput: Bool {
            false
        }

        public var contextLength: Int {
            switch self {
            case .gptOSS120B, .gptOSS20B, .llama3370b, .llama318b, .llama4Maverick, .llama4Scout:
                128_000
            }
        }
    }

    public enum Grok: Sendable, Hashable, CaseIterable {
        // xAI Grok models
        case grok43
        case grok420MultiAgent
        case grok420Reasoning
        case grok420NonReasoning

        /// Custom models
        case custom(String)

        public static var allCases: [Grok] {
            [
                .grok43,
                .grok420Reasoning,
                .grok420NonReasoning,
            ]
        }

        public var modelId: String {
            switch self {
            case let .custom(id): id
            case .grok43: "grok-4.3"
            case .grok420MultiAgent: "grok-4.20-multi-agent-0309"
            case .grok420Reasoning: "grok-4.20-0309-reasoning"
            case .grok420NonReasoning: "grok-4.20-0309-non-reasoning"
            }
        }

        public var supportsVision: Bool {
            switch self {
            case .grok43, .grok420Reasoning, .grok420NonReasoning, .custom:
                true
            case .grok420MultiAgent:
                // Upstream supports images, but this model requires Responses API routing.
                false
            }
        }

        public var supportsTools: Bool {
            switch self {
            case .grok420MultiAgent:
                false
            default:
                true
            }
        }

        public var supportsAudioInput: Bool {
            // Grok has voice support but limited API access as of 2025
            false
        }

        public var supportsAudioOutput: Bool {
            // Grok supports 145+ language voice but API access is limited
            false
        }

        public var contextLength: Int {
            switch self {
            case .grok43:
                1_000_000
            case .grok420MultiAgent,
                 .grok420Reasoning,
                 .grok420NonReasoning:
                2_000_000
            case .custom: 128_000 // Default assumption for custom models
            }
        }
    }
}
