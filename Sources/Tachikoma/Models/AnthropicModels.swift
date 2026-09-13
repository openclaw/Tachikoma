import Foundation

extension LanguageModel {
    public enum Anthropic: Sendable, Hashable, CaseIterable {
        // Claude 5 / 4.x Series
        case opus5
        case fable5
        case sonnet5
        case opus48
        case opus47
        case opus45
        case opus4
        case sonnet46
        case sonnet45
        case haiku45

        /// Fine-tuned models
        case custom(String)

        public static var allCases: [Anthropic] {
            [
                .opus5,
                .fable5,
                .sonnet5,
                .opus48,
                .opus47,
                .opus45,
                .opus4,
                .sonnet46,
                .sonnet45,
                .haiku45,
            ]
        }

        public var modelId: String {
            switch self {
            case let .custom(id): id
            case .opus5: "claude-opus-5"
            case .fable5: "claude-fable-5"
            case .sonnet5: "claude-sonnet-5"
            case .opus48: "claude-opus-4-8"
            case .opus47: "claude-opus-4-7"
            case .opus45: "claude-opus-4-5"
            case .opus4: "claude-opus-4-1-20250805"
            case .sonnet46: "claude-sonnet-4-6"
            case .sonnet45: "claude-sonnet-4-5-20250929"
            case .haiku45: "claude-haiku-4-5"
            }
        }

        public var supportsVision: Bool {
            switch self {
            case .opus5, .fable5, .sonnet5, .opus48, .opus47, .opus45, .opus4, .sonnet46, .sonnet45, .haiku45:
                true
            case .custom: true // Assume custom models support vision
            }
        }

        public var supportsTools: Bool {
            true
        } // All Claude models support tools

        public var supportsAudioInput: Bool {
            // Anthropic has voice features in mobile apps but limited API support as of 2025
            false
        }

        public var supportsAudioOutput: Bool {
            // Anthropic does not currently support audio output through API
            false
        }

        public var contextLength: Int {
            switch self {
            case .opus5, .fable5, .sonnet5, .opus48, .opus47, .sonnet46: 1_000_000
            case .haiku45: 200_000
            case .opus45, .opus4, .sonnet45: 500_000
            case let .custom(id):
                Self.hasMillionTokenContext(modelId: id) ? 1_000_000 : 200_000 // Default assumption
            }
        }

        public var maxOutputTokens: Int {
            switch self {
            case .opus5, .fable5, .sonnet5, .opus48, .opus47: 128_000
            case .sonnet46, .haiku45: 64000
            case let .custom(id):
                Self.has128KOutput(modelId: id) ? 128_000 : 8192
            case .opus45, .opus4, .sonnet45: 4096
            }
        }

        public var supportsStreaming: Bool {
            !Self.hasStreamingRefusalRisk(modelId: self.modelId)
        }

        public static func isFable(modelId: String) -> Bool {
            let normalized = modelId.lowercased()
            let pathSegments = normalized
                .components(separatedBy: CharacterSet(charactersIn: "/:@"))
                .filter { !$0.isEmpty }
            let dotSegments = pathSegments.flatMap { $0.components(separatedBy: ".") }
                .filter { !$0.isEmpty }
            let segments = pathSegments + dotSegments
            let canonicalSegments: Set = [
                "claude-fable-5",
                "fable-5",
                "fable5",
                "fable",
            ]
            return normalized == Self.fable5.modelId || segments.contains { segment in
                if canonicalSegments.contains(segment) {
                    return true
                }
                let compactSegment = segment
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: ".", with: "")
                return compactSegment == "claudefable5" || compactSegment == "fable5"
            }
        }

        public static func isSonnet5(modelId: String) -> Bool {
            let normalized = modelId.lowercased()
            let pathSegments = normalized
                .components(separatedBy: CharacterSet(charactersIn: "/:@"))
                .filter { !$0.isEmpty }
            let dotSegments = pathSegments.flatMap { $0.components(separatedBy: ".") }
                .filter { !$0.isEmpty }
            let segments = pathSegments + dotSegments
            let canonicalSegments: Set = [
                "claude-sonnet-5",
                "sonnet-5",
                "sonnet5",
            ]
            return normalized == Self.sonnet5.modelId || segments.contains { segment in
                if canonicalSegments.contains(segment) {
                    return true
                }
                let compactSegment = segment
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: ".", with: "")
                return compactSegment == "claudesonnet5" || compactSegment == "sonnet5"
            }
        }

        public static func isOpus5(modelId: String) -> Bool {
            let normalized = modelId.lowercased()
            let compactExact = normalized
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")
            let pathSegments = normalized
                .components(separatedBy: CharacterSet(charactersIn: "/:@"))
                .filter { !$0.isEmpty }
            let dotSegments = pathSegments.flatMap { $0.components(separatedBy: ".") }
                .filter { !$0.isEmpty }
            let segments = pathSegments + dotSegments
            let canonicalSegments: Set = [
                "claude-opus-5",
                "claude-opus5",
                "opus-5",
                "opus5",
                "claude-opus-5-latest",
            ]
            return normalized == Self.opus5.modelId || segments.contains { segment in
                if canonicalSegments.contains(segment) {
                    return true
                }
                let compactSegment = segment
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: ".", with: "")
                return compactSegment == "claudeopus5" || compactSegment == "opus5"
            } || compactExact == "claudeopus5" || compactExact == "opus5"
        }

        public static func hasMillionTokenContext(modelId: String) -> Bool {
            self.isOpus5(modelId: modelId) || self.isFable(modelId: modelId) || self.isSonnet5(modelId: modelId)
        }

        public static func hasDefaultAdaptiveThinking(modelId: String) -> Bool {
            self.isOpus5(modelId: modelId) || self.isFable(modelId: modelId) || self.isSonnet5(modelId: modelId)
        }

        public static func has128KOutput(modelId: String) -> Bool {
            self.hasMillionTokenContext(modelId: modelId)
        }

        public static func isOpus48(modelId: String) -> Bool {
            let normalized = modelId.lowercased()
            let compactExact = normalized
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")
            let pathSegments = normalized
                .components(separatedBy: CharacterSet(charactersIn: "/:@"))
                .filter { !$0.isEmpty }
            let dotSegments = pathSegments.flatMap { $0.components(separatedBy: ".") }
                .filter { !$0.isEmpty }
            let segments = pathSegments + dotSegments
            let canonicalSegments: Set = [
                "claude-opus-4-8",
                "opus-4-8",
                "opus48",
            ]
            return normalized == Self.opus48.modelId || segments.contains { segment in
                if canonicalSegments.contains(segment) {
                    return true
                }
                let compactSegment = segment
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: ".", with: "")
                return compactSegment == "claudeopus48" || compactSegment == "opus48"
            } || compactExact == "claudeopus48" || compactExact == "opus48"
        }

        public static func hasStreamingRefusalRisk(modelId: String) -> Bool {
            self.isOpus5(modelId: modelId) || self.isFable(modelId: modelId) || self.isSonnet5(modelId: modelId) ||
                self.isOpus48(modelId: modelId)
        }
    }
}
