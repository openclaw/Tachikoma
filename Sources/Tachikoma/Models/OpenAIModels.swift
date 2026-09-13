import Foundation

extension LanguageModel {
    public enum OpenAI: Sendable, Hashable, CaseIterable {
        /// Latest ChatGPT Instant alias.
        case chatLatest

        /// GPT-5 snapshot previously used in ChatGPT.
        case gpt5ChatLatest

        /// GPT-5.5 Series
        case gpt55 // Flagship GPT-5.5

        /// GPT-5.6 preview series
        case gpt56Sol
        case gpt56Terra
        case gpt56Luna

        /// GPT-5.4 Series
        case gpt54
        case gpt54Mini
        case gpt54Nano

        // GPT-5 Series (August 2025)
        case gpt5 // Best for coding and agentic tasks
        case gpt5Pro // Higher reasoning budget
        case gpt5Mini // Cost-optimized
        case gpt5Nano // Ultra-low latency

        /// Fine-tuned models
        case custom(String)

        public static var allCases: [OpenAI] {
            [
                .chatLatest,
                .gpt5ChatLatest,
                .gpt56Sol,
                .gpt56Terra,
                .gpt56Luna,
                .gpt55,
                .gpt54,
                .gpt54Mini,
                .gpt54Nano,
                .gpt5,
                .gpt5Pro,
                .gpt5Mini,
                .gpt5Nano,
            ]
        }

        public var modelId: String {
            switch self {
            case let .custom(id): id
            case .chatLatest: "chat-latest"
            case .gpt5ChatLatest: "gpt-5-chat-latest"
            case .gpt56Sol: "gpt-5.6-sol"
            case .gpt56Terra: "gpt-5.6-terra"
            case .gpt56Luna: "gpt-5.6-luna"
            case .gpt55: "gpt-5.5"
            case .gpt54: "gpt-5.4"
            case .gpt54Mini: "gpt-5.4-mini"
            case .gpt54Nano: "gpt-5.4-nano"
            case .gpt5: "gpt-5"
            case .gpt5Pro: "gpt-5-pro"
            case .gpt5Mini: "gpt-5-mini"
            case .gpt5Nano: "gpt-5-nano"
            }
        }

        public var supportsVision: Bool {
            switch self {
            case .chatLatest,
                 .gpt5ChatLatest,
                 .gpt56Sol, .gpt56Terra, .gpt56Luna,
                 .gpt55,
                 .gpt54, .gpt54Mini, .gpt54Nano,
                 .gpt5, .gpt5Pro, .gpt5Mini, .gpt5Nano: true // GPT-5+ supports multimodal
            default: false
            }
        }

        public var supportsTools: Bool {
            switch self {
            case .chatLatest,
                 .gpt5ChatLatest,
                 .gpt56Sol, .gpt56Terra, .gpt56Luna,
                 .gpt55,
                 .gpt54, .gpt54Mini, .gpt54Nano,
                 .gpt5, .gpt5Pro, .gpt5Mini, .gpt5Nano: true // GPT-5+ excels at tool calling
            case .custom: true // Assume custom models support tools
            }
        }

        public var supportsAudioInput: Bool {
            switch self {
            case .gpt55,
                 .gpt54, .gpt54Mini, .gpt54Nano,
                 .gpt5, .gpt5Pro, .gpt5Mini, .gpt5Nano: true // GPT-5+ is fully multimodal
            default: false
            }
        }

        public var supportsAudioOutput: Bool {
            switch self {
            case let .custom(id): id.contains("realtime")
            default: false
            }
        }

        public var supportsRealtime: Bool {
            switch self {
            case let .custom(id): id.contains("realtime")
            default: false
            }
        }

        public var contextLength: Int {
            switch self {
            case .gpt5ChatLatest:
                128_000
            case .gpt56Sol, .gpt56Terra, .gpt56Luna:
                372_000
            case .chatLatest, .gpt55,
                 .gpt54, .gpt54Mini, .gpt54Nano,
                 .gpt5, .gpt5Pro, .gpt5Mini, .gpt5Nano: 400_000 // 272k input + 128k output
            case .custom: 128_000 // Default assumption
            }
        }

        /// Resolves a GPT-5.6 model ID, including provider-qualified IDs used by compatible APIs.
        public static func gpt56Model(for modelId: String) -> OpenAI? {
            let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let modelComponent = trimmed.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
            guard !modelComponent.isEmpty else { return nil }

            // OpenRouter routing variants are terminal metadata; ignore them only for capability inference.
            let baseModel = if
                let suffixSeparator = modelComponent.firstIndex(of: ":"),
                modelComponent.index(after: suffixSeparator) < modelComponent.endIndex
            {
                modelComponent[..<suffixSeparator]
            } else {
                modelComponent[...]
            }
            let compact = baseModel.lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "_", with: "")
            switch compact {
            case "gpt56", "gpt56sol":
                return .gpt56Sol
            case "gpt56terra":
                return .gpt56Terra
            case "gpt56luna":
                return .gpt56Luna
            default:
                return nil
            }
        }

        public var isUnsupportedLegacyFamily: Bool {
            let normalized = self.modelId.lowercased()
            let compact = normalized.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ".", with: "")
            return normalized.hasPrefix("gpt-4") || compact.hasPrefix("gpt4") ||
                normalized.hasPrefix("gpt-3") || compact.hasPrefix("gpt3") ||
                normalized.hasPrefix("o3") || normalized.hasPrefix("o4") ||
                normalized.hasPrefix("gpt-5.1") || compact.hasPrefix("gpt51") ||
                normalized.hasPrefix("gpt-5.2") || compact.hasPrefix("gpt52") ||
                normalized.contains("gpt-5-thinking") || compact.contains("gpt5thinking")
        }
    }
}
