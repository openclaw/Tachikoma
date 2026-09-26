import Foundation

// MARK: - CLI Model Selection

/// Smart model parsing and selection for command-line interfaces
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ModelSelector {
    /// Parse a model string with intelligent fallbacks and shortcuts
    public static func parseModel(_ modelString: String) throws -> Model {
        // Parse a model string with intelligent fallbacks and shortcuts
        let normalized = modelString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle empty or default
        if normalized.isEmpty || normalized == "default" {
            return .default
        }

        // OpenAI shortcuts and models
        if let openaiModel = parseOpenAIModel(normalized) {
            return .openai(openaiModel)
        }

        // Anthropic shortcuts and models
        if let anthropicModel = parseAnthropicModel(normalized) {
            return .anthropic(anthropicModel)
        }

        // Google shortcuts and models
        if let googleModel = parseGoogleModel(normalized) {
            return .google(googleModel)
        }

        // MiniMax shortcuts and models
        if let miniMaxModel = parseMiniMaxCNModel(normalized) {
            return .minimaxCN(miniMaxModel)
        }

        if let miniMaxModel = parseMiniMaxModel(normalized) {
            return .minimax(miniMaxModel)
        }

        if let kimiModel = parseKimiModel(normalized) {
            return .kimi(kimiModel)
        }

        // Grok shortcuts and models
        if let grokModel = parseGrokModel(normalized) {
            return .grok(grokModel)
        }

        if
            let qualified = ProviderParser.parse(normalized),
            ["grok", "xai", "x-ai"].contains(qualified.provider.lowercased())
        {
            let model = qualified.model.lowercased()
            guard
                !Self.isUnsupportedLegacyGrokModel(model),
                let grokModel = self.parseGrokModel(model) else
            {
                throw ModelValidationError.unsupportedModel(modelString)
            }
            return .grok(grokModel)
        }

        if
            Self.isUnsupportedLegacyOpenAIModel(normalized) ||
            Self.isUnsupportedLegacyAnthropicModel(normalized) ||
            Self.isUnsupportedLegacyGrokModel(normalized)
        {
            throw ModelValidationError.unsupportedModel(modelString)
        }

        // LM Studio shortcuts and models
        if let lmStudioModel = parseLMStudioModel(normalized) {
            return .lmstudio(lmStudioModel)
        }

        if let qualified = ProviderParser.parse(normalized) {
            let provider = qualified.provider.lowercased()
            if provider == "openai", let openaiModel = parseOpenAIModel(qualified.model.lowercased()) {
                return .openai(openaiModel)
            }
            if provider == "openrouter" {
                return .openRouter(modelId: qualified.model)
            }
            if provider == "ollama" {
                // Ollama is an open registry: pass unknown names through as custom
                // model ids instead of gating on the known-model list.
                return .ollama(self
                    .parseOllamaModel(qualified.model.lowercased()) ?? .custom(qualified.model.lowercased()))
            }
            if !["ollama", "lmstudio", "lm-studio"].contains(provider) {
                return .openRouter(modelId: normalized)
            }
        }

        // Ollama shortcuts and models. Keep after explicit local providers because it accepts custom IDs.
        if let ollamaModel = parseOllamaModel(normalized) {
            return .ollama(ollamaModel)
        }

        // OpenRouter format (contains slash)
        if normalized.contains("/") {
            return .openRouter(modelId: normalized)
        }

        // Custom model ID - try to infer provider
        if normalized.contains("gpt-5") || normalized.contains("gpt5") {
            return .openai(.custom(normalized))
        }

        if normalized.contains("claude") {
            return .anthropic(.custom(normalized))
        }

        if normalized.contains("grok") {
            return .grok(.custom(normalized))
        }

        // Default to Ollama for local models
        return .ollama(.custom(normalized))
    }

    // MARK: - Provider-Specific Parsing

    private static func parseOpenAIModel(_ input: String) -> Model.OpenAI? {
        if let model = Model.OpenAI.gpt6Model(for: input) {
            return model
        }
        switch input {
        case "chat-latest", "chatlatest":
            return .chatLatest
        case "gpt-5-chat-latest", "gpt5-chat-latest", "gpt5chatlatest":
            return .gpt5ChatLatest
        // GPT-5.6 preview models
        case "gpt-5.6", "gpt5.6", "gpt-5-6", "gpt5-6", "gpt56",
             "gpt-5.6-sol", "gpt5.6-sol", "gpt-5-6-sol", "gpt5-6-sol", "gpt56-sol", "gpt56sol":
            return .gpt56Sol
        case "gpt-5.6-terra", "gpt5.6-terra", "gpt-5-6-terra", "gpt5-6-terra", "gpt56-terra", "gpt56terra":
            return .gpt56Terra
        case "gpt-5.6-luna", "gpt5.6-luna", "gpt-5-6-luna", "gpt5-6-luna", "gpt56-luna", "gpt56luna":
            return .gpt56Luna
        // GPT-5.5 models
        case "gpt-5.5", "gpt5.5", "gpt-5-5", "gpt5-5", "gpt55":
            return .gpt55
        case "gpt-5.5-mini", "gpt5.5-mini", "gpt55-mini", "gpt55mini", "gpt-5-5-mini", "gpt5-5-mini":
            return .gpt5Mini
        case "gpt-5.5-nano", "gpt5.5-nano", "gpt55-nano", "gpt55nano", "gpt-5-5-nano", "gpt5-5-nano":
            return .gpt5Nano
        // GPT-5.4 models
        case "gpt-5.4", "gpt5.4", "gpt-5-4", "gpt5-4", "gpt54":
            return .gpt54
        case "gpt-5.4-mini", "gpt5.4-mini", "gpt54-mini", "gpt54mini", "gpt-5-4-mini", "gpt5-4-mini":
            return .gpt54Mini
        case "gpt-5.4-nano", "gpt5.4-nano", "gpt54-nano", "gpt54nano", "gpt-5-4-nano", "gpt5-4-nano":
            return .gpt54Nano
        // GPT-5 models
        case "gpt-5", "gpt5":
            return .gpt5
        case "gpt-5-pro", "gpt5-pro", "gpt5pro":
            return .gpt5Pro
        case "gpt-5-mini", "gpt5-mini", "gpt5mini":
            return .gpt5Mini
        case "gpt-5-nano", "gpt5-nano", "gpt5nano":
            return .gpt5Nano
        // Shortcuts
        case "gpt":
            return .gpt55 // Default to flagship GPT-5.5
        case "openai":
            return .gpt55 // Default to GPT-5.5
        default:
            // Check if it's an OpenAI model ID
            if self.isUnsupportedLegacyOpenAIModel(input) {
                return nil
            }
            if input.hasPrefix("gpt-5") || input.hasPrefix("gpt5") {
                return .custom(input)
            }
            return nil
        }
    }

    private static func parseAnthropicModel(_ input: String) -> Model.Anthropic? {
        switch input {
        // Direct matches
        case "claude-opus-5", "claude-opus5", "claude-opus-5-latest", "opus-5", "opus.5", "opus5":
            return .opus5
        case "claude-fable-5", "claude-fable-5-latest", "fable-5", "fable.5", "fable5", "fable":
            return .fable5
        case "claude-sonnet-5", "sonnet-5", "sonnet.5", "sonnet5":
            return .sonnet5
        case "claude-opus-4-8", "claude-opus-4.8", "opus-4-8", "opus-4.8", "opus48",
             "claude-opus-4-8-latest":
            return .opus48
        case "claude-opus-4-7", "claude-opus-4.7", "opus-4-7", "opus-4.7", "opus47":
            return .opus47
        case "claude-opus-4-5", "claude-opus-4.5", "opus-4-5", "opus-4.5", "opus45":
            return .opus45
        case "claude-sonnet-4-6", "claude-sonnet-4.6", "sonnet-4-6", "sonnet-4.6", "sonnet46":
            return .sonnet46
        case "claude-sonnet-4-5-20250929", "claude-sonnet-4.5":
            return .sonnet45
        // Shortcuts
        case "claude", "claude-latest", "claude_latest", "claudelatest", "claude-default", "claude_default":
            return .opus5
        case "claude-opus", "opus":
            return .opus5
        case "claude-sonnet", "sonnet":
            return .sonnet5
        case "claude-haiku", "haiku":
            return .haiku45
        case "anthropic":
            return .opus5
        default:
            // Check if it's a Claude model ID
            if self.isUnsupportedLegacyAnthropicModel(input) {
                return nil
            }
            if input.hasPrefix("claude") {
                return .custom(input)
            }
            return nil
        }
    }

    private static func isUnsupportedLegacyOpenAIModel(_ input: String) -> Bool {
        let normalized = input.lowercased()
        let compact = normalized.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        return normalized.hasPrefix("gpt-4") || compact.hasPrefix("gpt4") ||
            normalized.hasPrefix("gpt-3") || compact.hasPrefix("gpt3") ||
            normalized.hasPrefix("o3") || normalized.hasPrefix("o4") ||
            normalized.hasPrefix("gpt-5.1") || normalized.hasPrefix("gpt-5.2") ||
            compact.hasPrefix("gpt51") || compact.hasPrefix("gpt52") ||
            normalized.contains("gpt-5-thinking") || compact.contains("gpt5thinking")
    }

    private static func isUnsupportedLegacyAnthropicModel(_ input: String) -> Bool {
        let normalized = input.lowercased()
        let compact = normalized.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        return normalized.hasPrefix("claude-3") || compact.hasPrefix("claude3") ||
            normalized == "claude-opus-4-20250514" ||
            normalized == "claude-sonnet-4-20250514" ||
            normalized.contains("-thinking")
    }

    private static func parseGoogleModel(_ input: String) -> Model.Google? {
        switch input {
        case "gemini-3.5-flash", "gemini35flash", "gemini-3-5-flash":
            .gemini35Flash
        case "gemini-3.1-pro-preview", "gemini-3.1-pro", "gemini31pro", "gemini31propreview":
            .gemini31ProPreview
        case "gemini-3.1-flash-lite", "gemini31flashlite", "gemini-3.1-flashlite":
            .gemini31FlashLite
        case "gemini-3-flash", "gemini-3-flash-preview", "gemini3flash", "gemini-3flash":
            .gemini3Flash
        case "gemini-2.5-pro", "gemini25pro", "gemini2.5pro":
            .gemini25Pro
        case "gemini-2.5-flash", "gemini25flash":
            .gemini25Flash
        case "gemini-2.5-flash-lite", "gemini25flashlite", "gemini-2.5-flashlite":
            .gemini25FlashLite
        case "gemini":
            .gemini35Flash
        case "google":
            .gemini35Flash
        default:
            nil
        }
    }

    private static func parseGrokModel(_ input: String) -> Model.Grok? {
        switch input {
        // Direct matches for available models only
        case "grok-4.3", "grok-4-3", "grok43", "grok-4.3-latest", "grok-4-latest", "grok-4", "grok-latest":
            return .grok43
        case "grok-4.20-0309-reasoning", "grok-4-20-0309-reasoning":
            return .grok420Reasoning
        case "grok-4.20-0309-non-reasoning", "grok-4-20-0309-non-reasoning":
            return .grok420NonReasoning
        // Shortcuts
        case "grok":
            return .grok43
        case "xai":
            return .grok43
        default:
            // Check if it's a Grok model ID
            if self.isUnsupportedLegacyGrokModel(input) {
                return nil
            }
            if input.hasPrefix("grok") {
                return .custom(input)
            }
            return nil
        }
    }

    private static func parseMiniMaxModel(_ input: String) -> Model.MiniMax? {
        switch input {
        case "minimax-m2.7", "minimax-m2-7", "m2.7", "m2-7", "minimax/m2.7", "minimax/m2-7",
             "minimax/minimax-m2.7", "minimax/minimax-m2-7":
            .m27
        case "minimax-m2.7-highspeed", "minimax-m2-7-highspeed", "m2.7-highspeed", "m2-7-highspeed",
             "minimax/m2.7-highspeed", "minimax/m2-7-highspeed", "minimax/minimax-m2.7-highspeed",
             "minimax/minimax-m2-7-highspeed":
            .m27Highspeed
        case "minimax-m3", "m3", "minimax/m3", "minimax/minimax-m3":
            .m3
        case "minimax":
            .m27
        default:
            nil
        }
    }

    private static func parseMiniMaxCNModel(_ input: String) -> Model.MiniMax? {
        switch input {
        case "minimax-cn-m2.7", "minimax-cn-m2-7", "minimaxi-m2.7", "minimaxi-m2-7",
             "minimax_cn/m2.7", "minimax_cn/m2-7", "minimax_cn/minimax-m2.7",
             "minimax_cn/minimax-m2-7",
             "minimax-cn/m2.7", "minimax-cn/m2-7", "minimax-cn/minimax-m2.7",
             "minimax-cn/minimax-m2-7", "minimaxi/m2.7", "minimaxi/m2-7":
            .m27
        case "minimax-cn-m2.7-highspeed", "minimax-cn-m2-7-highspeed", "minimaxi-m2.7-highspeed",
             "minimaxi-m2-7-highspeed", "minimax-cn/m2.7-highspeed", "minimax-cn/m2-7-highspeed",
             "minimax_cn/m2.7-highspeed", "minimax_cn/m2-7-highspeed",
             "minimax_cn/minimax-m2.7-highspeed", "minimax_cn/minimax-m2-7-highspeed",
             "minimax-cn/minimax-m2.7-highspeed", "minimax-cn/minimax-m2-7-highspeed",
             "minimaxi/m2.7-highspeed", "minimaxi/m2-7-highspeed":
            .m27Highspeed
        case "minimax-cn-m3", "minimaxi-m3", "minimax-cn/m3", "minimax_cn/m3", "minimaxi/m3",
             "minimax-cn/minimax-m3", "minimax_cn/minimax-m3":
            .m3
        case "minimax-cn", "minimax_cn", "minimaxi":
            .m27
        default:
            nil
        }
    }

    private static func parseKimiModel(_ input: String) -> Model.Kimi? {
        switch input {
        case "kimi-k2.7-code-highspeed", "kimi-k2-7-code-highspeed", "k2.7-code-highspeed", "k2-7-code-highspeed",
             "kimi/kimi-k2.7-code-highspeed", "moonshot/kimi-k2.7-code-highspeed":
            .k27CodeHighspeed
        case "kimi-k2.7-code", "kimi-k2-7-code", "k2.7-code", "k2-7-code", "kimi/kimi-k2.7-code",
             "moonshot/kimi-k2.7-code":
            .k27Code
        case "kimi-k2.6", "kimi-k2-6", "k2.6", "k2-6", "kimi/kimi-k2.6", "moonshot/kimi-k2.6",
             "kimi", "moonshot":
            .k26
        default:
            nil
        }
    }

    private static func isUnsupportedLegacyGrokModel(_ input: String) -> Bool {
        let normalized = input.lowercased()
        return normalized.contains("grok-4.20-multi-agent") ||
            normalized.contains("grok-4-20-multi-agent") ||
            normalized.contains("grok420multiagent")
    }

    private static func parseOllamaModel(_ input: String) -> Model.Ollama? {
        switch input {
        // Direct matches
        case "llama3.3", "llama3.3:latest":
            .llama33
        case "llama3.2", "llama3.2:latest":
            .llama32
        case "llama3.1", "llama3.1:latest":
            .llama31
        case "llava", "llava:latest":
            .llava
        case "bakllava", "bakllava:latest":
            .bakllava
        case "llama3.2-vision:11b":
            .llama32Vision11b
        case "llama3.2-vision:90b":
            .llama32Vision90b
        case "qwen2.5vl:7b":
            .qwen25vl7b
        case "qwen2.5vl:32b":
            .qwen25vl32b
        case "llama4", "llama4:latest":
            .llama4
        case "mistral", "mistral:latest":
            .mistral
        case "mistral-nemo", "mistral-nemo:latest":
            .mistralNemo
        case "devstral", "devstral:latest":
            .devstral
        case "deepseek-r1:8b":
            .deepseekR18b
        case "deepseek-r1:671b":
            .deepseekR1671b
        case "firefunction-v2", "firefunction-v2:latest":
            .firefunction
        case "command-r", "command-r:latest":
            .commandR
        case "command-r-plus", "command-r-plus:latest":
            .commandRPlus
        // Shortcuts
        case "llama", "llama3":
            .llama33 // Default to latest Llama
        case "ollama":
            .llama33 // Default Ollama model
        default:
            // For Ollama, accept any model ID as custom
            .custom(input)
        }
    }

    private static func parseLMStudioModel(_ input: String) -> Model.LMStudio? {
        if input == "lmstudio" || input == "lm-studio" {
            return .gptOSS120B
        }

        for prefix in ["lmstudio/", "lm-studio/"] where input.hasPrefix(prefix) {
            let modelId = String(input.dropFirst(prefix.count))
            guard !modelId.isEmpty else { return nil }
            return Self.parseLMStudioModelIdentifier(modelId)
        }

        return nil
    }

    private static func parseLMStudioModelIdentifier(_ input: String) -> Model.LMStudio {
        switch input {
        case "openai/gpt-oss-120b", "gpt-oss-120b", "gpt-oss:120b":
            .gptOSS120B
        case "openai/gpt-oss-20b", "gpt-oss-20b", "gpt-oss:20b":
            .gptOSS20B
        case "meta/llama-3.3-70b", "llama-3.3-70b", "llama3.3-70b":
            .llama3370B
        default:
            .custom(input)
        }
    }

    // MARK: - Model Information

    /// Get available models for a specific provider
    public static func availableModels(for provider: String) -> [String] {
        // Get available models for a specific provider
        let normalizedProvider = provider.lowercased()

        switch normalizedProvider {
        case "openai":
            return Model.OpenAI.allCases.compactMap {
                if case .custom = $0 {
                    return nil
                }
                return $0.modelId
            }
        case "anthropic", "claude":
            return Model.Anthropic.allCases.compactMap {
                if case .custom = $0 {
                    return nil
                }
                return $0.modelId
            }
        case "grok", "xai":
            return Model.Grok.allCases.compactMap {
                if case .custom = $0 {
                    return nil
                }
                return $0.modelId
            }
        case "google", "gemini":
            return Model.Google.allCases.map(\.userFacingModelId)
        case "minimax", "minimax-cn", "minimaxi":
            return Model.MiniMax.allCases.map(\.modelId)
        case "kimi", "moonshot":
            return Model.Kimi.allCases.map(\.modelId)
        case "ollama":
            return Model.Ollama.allCases.compactMap {
                if case .custom = $0 {
                    return nil
                }
                return $0.modelId
            }
        case "lmstudio", "lm-studio":
            return Model.LMStudio.allCases.compactMap {
                if case .custom = $0 {
                    return nil
                }
                return $0.modelId
            }
        default:
            return []
        }
    }

    /// Get model capabilities for CLI display
    public static func getCapabilities(for model: Model) -> ModelCapabilityInfo {
        // Get model capabilities for CLI display
        ModelCapabilityInfo(
            supportsVision: model.supportsVision,
            supportsTools: model.supportsTools,
            supportsStreaming: model.supportsStreaming,
            provider: model.providerName,
            modelId: model.modelId,
        )
    }
}

// MARK: - CLI Helpers

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ModelCapabilityInfo {
    public let supportsVision: Bool
    public let supportsTools: Bool
    public let supportsStreaming: Bool
    public let provider: String
    public let modelId: String

    /// Format capabilities for CLI display
    public var description: String {
        var capabilities: [String] = []
        if self.supportsVision {
            capabilities.append("vision")
        }
        if self.supportsTools {
            capabilities.append("tools")
        }
        if self.supportsStreaming {
            capabilities.append("streaming")
        }

        let capabilityString = capabilities.isEmpty ? "basic" : capabilities.joined(separator: ", ")
        return "\(self.provider)/\(self.modelId) (\(capabilityString))"
    }
}

/// Format model list for CLI display
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func formatModelList(title: String, models: [String]) -> String {
    var output = "\n\(title):\n"
    for model in models.sorted() {
        output += "  • \(model)\n"
    }
    return output
}

/// Get all available models for CLI help
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func getAllAvailableModels() -> String {
    var output = "Available Models:\n"

    output += formatModelList(
        title: "OpenAI",
        models: ModelSelector.availableModels(for: "openai"),
    )

    output += formatModelList(
        title: "Anthropic",
        models: ModelSelector.availableModels(for: "anthropic"),
    )

    output += formatModelList(
        title: "Google",
        models: ModelSelector.availableModels(for: "google"),
    )

    output += formatModelList(
        title: "MiniMax",
        models: ModelSelector.availableModels(for: "minimax"),
    )

    output += formatModelList(
        title: "MiniMax China",
        models: ModelSelector.availableModels(for: "minimax-cn"),
    )

    output += formatModelList(
        title: "Kimi (Moonshot AI)",
        models: ModelSelector.availableModels(for: "kimi"),
    )

    output += formatModelList(
        title: "Grok (xAI)",
        models: ModelSelector.availableModels(for: "grok"),
    )

    output += formatModelList(
        title: "Ollama",
        models: ModelSelector.availableModels(for: "ollama"),
    )

    output += "\nShortcuts:\n"
    output += "  • claude, claude-opus, opus → claude-opus-5\n"
    output += "  • fable → claude-fable-5\n"
    output += "  • gpt → gpt-5.5\n"
    output += "  • gemini → gemini-3.5-flash\n"
    output += "  • minimax → MiniMax-M2.7\n"
    output += "  • minimax-cn → MiniMax-M2.7 via api.minimaxi.com\n"
    output += "  • kimi, moonshot → kimi-k2.6\n"
    output += "  • grok → grok-4.3\n"
    output += "  • llama, llama3 → llama3.3\n"

    output += "\nCustom Models:\n"
    output += "  • OpenRouter: anthropic/claude-fable-5\n"
    output += "  • Custom OpenAI: custom-gpt-model\n"
    output += "  • Local Ollama: any-model:tag\n"

    return output
}

// MARK: - Model Validation

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension ModelSelector {
    /// Validate that a model supports the required capabilities
    public static func validateModel(_ model: Model, requiresVision: Bool = false, requiresTools: Bool = false) throws {
        // Validate that a model supports the required capabilities
        if requiresVision, !model.supportsVision {
            throw ModelValidationError.visionNotSupported(model.modelId)
        }

        if requiresTools, !model.supportsTools {
            throw ModelValidationError.toolsNotSupported(model.modelId)
        }
    }

    /// Get recommended models for specific use cases
    public static func recommendedModels(for useCase: UseCase) -> [Model] {
        // Get recommended models for specific use cases
        switch useCase {
        case .coding:
            [.claude, .openai(.gpt55), .google(.gemini35Flash)]
        case .vision:
            [.claude, .openai(.gpt55), .google(.gemini35Flash)]
        case .reasoning:
            [.openai(.gpt54), .claude, .google(.gemini35Flash)]
        case .local:
            [.llama, .ollama(.mistralNemo), .ollama(.commandRPlus)]
        case .general:
            [.claude, .openai(.gpt55), .google(.gemini35Flash), .grok(.grok43), .llama]
        }
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum UseCase {
    case coding
    case vision
    case reasoning
    case local
    case general
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum ModelValidationError: Error, LocalizedError {
    case visionNotSupported(String)
    case toolsNotSupported(String)
    case unsupportedModel(String)

    public var errorDescription: String? {
        switch self {
        case let .visionNotSupported(modelId):
            "Model '\(modelId)' does not support vision inputs"
        case let .toolsNotSupported(modelId):
            "Model '\(modelId)' does not support tool calling"
        case let .unsupportedModel(modelId):
            "Model '\(modelId)' is no longer supported"
        }
    }
}
