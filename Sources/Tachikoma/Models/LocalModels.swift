import Foundation

extension LanguageModel {
    public enum Ollama: Sendable, Hashable, CaseIterable {
        // GPT-OSS models
        case gptOSS120B
        case gptOSS20B

        // Recommended models for different use cases
        case llama33 // Best overall
        case llama32 // Good alternative
        case llama31 // Older but reliable

        // Vision models (no tool support)
        case llava
        case bakllava
        case llama32Vision11b
        case llama32Vision90b
        case qwen25vl7b
        case qwen25vl32b

        // Specialized models
        case mistralNemo
        case qwen25
        case commandRPlus

        // Additional models referenced by CLI
        case llama4
        case mistral
        case devstral
        case deepseekR18b
        case deepseekR1671b
        case firefunction
        case commandR

        /// Custom/other models
        case custom(String)

        public static var allCases: [Ollama] {
            [
                .gptOSS120B,
                .gptOSS20B,
                .llama33,
                .llama32,
                .llama31,
                .llava,
                .bakllava,
                .llama32Vision11b,
                .llama32Vision90b,
                .qwen25vl7b,
                .qwen25vl32b,
                .mistralNemo,
                .qwen25,
                .commandRPlus,
                .llama4,
                .mistral,
                .devstral,
                .deepseekR18b,
                .deepseekR1671b,
                .firefunction,
                .commandR,
            ]
        }

        public var modelId: String {
            switch self {
            case let .custom(id): id
            case .gptOSS120B: "gpt-oss:120b"
            case .gptOSS20B: "gpt-oss:20b"
            case .llama33: "llama3.3"
            case .llama32: "llama3.2"
            case .llama31: "llama3.1"
            case .llava: "llava"
            case .bakllava: "bakllava"
            case .llama32Vision11b: "llama3.2-vision:11b"
            case .llama32Vision90b: "llama3.2-vision:90b"
            case .qwen25vl7b: "qwen2.5vl:7b"
            case .qwen25vl32b: "qwen2.5vl:32b"
            case .mistralNemo: "mistral-nemo"
            case .qwen25: "qwen2.5"
            case .commandRPlus: "command-r-plus"
            case .llama4: "llama4"
            case .mistral: "mistral"
            case .devstral: "devstral"
            case .deepseekR18b: "deepseek-r1:8b"
            case .deepseekR1671b: "deepseek-r1:671b"
            case .firefunction: "firefunction-v2"
            case .commandR: "command-r"
            }
        }

        public var supportsVision: Bool {
            switch self {
            case .llama4, .llava, .bakllava, .llama32Vision11b, .llama32Vision90b,
                 .qwen25vl7b, .qwen25vl32b:
                return true
            case let .custom(id):
                let lower = id.lowercased()
                // Heuristic: many Ollama vision models include "vision", "vl", or well-known model names.
                // Keep this permissive so `ollama/<anything-vision>` works from config strings.
                if lower.contains("llava") || lower.contains("bakllava") {
                    return true
                }
                if lower.contains("vision") {
                    return true
                }
                if lower.contains("qwen2.5vl") || lower.contains("qwen25vl") {
                    return true
                }
                if lower.contains("vl:") || lower.contains("-vl") || lower.contains("_vl") {
                    return true
                }
                return false
            default:
                return false
            }
        }

        public var supportsTools: Bool {
            switch self {
            case .gptOSS120B, .gptOSS20B:
                return true // GPT-OSS supports tools
            case .llava, .bakllava, .llama32Vision11b, .llama32Vision90b,
                 .qwen25vl7b, .qwen25vl32b:
                return false // Vision models don't support tools
            case .llama33, .llama32, .llama31, .mistralNemo:
                return true
            case .qwen25, .commandRPlus:
                return true
            case .llama4, .mistral, .devstral:
                return true
            case .deepseekR18b, .deepseekR1671b, .firefunction, .commandR:
                return true
            case let .custom(id):
                // Heuristic: treat likely-vision models as tool-less unless explicitly modeled.
                let lower = id.lowercased()
                if lower.contains("llava") || lower.contains("bakllava") {
                    return false
                }
                if lower.contains("vision") {
                    return false
                }
                if lower.contains("qwen2.5vl") || lower.contains("qwen25vl") {
                    return false
                }
                if lower.contains("vl:") || lower.contains("-vl") || lower.contains("_vl") {
                    return false
                }
                return true
            }
        }

        public var supportsAudioInput: Bool {
            false
        } // Ollama models run locally and don't support native audio processing
        public var supportsAudioOutput: Bool {
            false
        }

        public var contextLength: Int {
            switch self {
            case .gptOSS120B, .gptOSS20B: 128_000
            case .llama33, .llama32, .llama31: 128_000
            case .llava, .bakllava: 32000
            case .llama32Vision11b: 128_000
            case .llama32Vision90b: 128_000
            case .qwen25vl7b, .qwen25vl32b: 125_000
            case .mistralNemo: 128_000
            case .qwen25: 32000
            case .commandRPlus: 128_000
            case .llama4: 1_000_000
            case .mistral: 32000
            case .devstral: 128_000
            case .deepseekR18b: 64000
            case .deepseekR1671b: 128_000
            case .firefunction: 8000
            case .commandR: 128_000
            case .custom: 32000
            }
        }
    }

    public enum LMStudio: Sendable, Hashable, CaseIterable {
        // GPT-OSS models
        case gptOSS120B
        case gptOSS20B

        /// Common local models
        case llama3370B

        /// Custom model path
        case custom(String)

        public static var allCases: [LMStudio] {
            [
                .gptOSS120B,
                .gptOSS20B,
                .llama3370B,
            ]
        }

        public var modelId: String {
            switch self {
            case .gptOSS120B: "openai/gpt-oss-120b"
            case .gptOSS20B: "openai/gpt-oss-20b"
            case .llama3370B: "meta/llama-3.3-70b"
            case let .custom(id): id
            }
        }

        public var supportsVision: Bool {
            switch self {
            case .gptOSS120B, .gptOSS20B: false
            case .llama3370B: false
            default: false
            }
        }

        public var supportsTools: Bool {
            switch self {
            case .custom: true // Assume support
            default: true // Most modern models support tools
            }
        }

        public var contextLength: Int {
            switch self {
            case .gptOSS120B, .gptOSS20B: 128_000
            case .llama3370B: 128_000
            case .custom: 16000
            }
        }
    }
}
