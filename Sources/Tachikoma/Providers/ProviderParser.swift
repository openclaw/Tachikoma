import Foundation

/// Utility for parsing AI provider configuration strings and determining default models
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum ProviderParser {
    /// Represents a parsed AI provider configuration
    public struct ProviderConfig: Equatable, Sendable {
        /// The provider name (e.g., "openai", "anthropic", "ollama")
        public let provider: String

        /// The model name (e.g., "gpt-5.5", "claude-fable-5", "llava:latest")
        public let model: String

        /// The full string representation (e.g., "openai/gpt-5.5")
        public var fullString: String {
            "\(self.provider)/\(self.model)"
        }

        public init(provider: String, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    /// Parse a provider string in the format "provider/model"
    /// - Parameter providerString: String like "openai/gpt-5.5" or "ollama/llava:latest"
    /// - Returns: Parsed configuration or nil if invalid format
    public static func parse(_ providerString: String) -> ProviderConfig? {
        // Parse a provider string in the format "provider/model"
        let trimmed = providerString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slashIndex = trimmed.firstIndex(of: "/") else {
            return nil
        }

        let provider = String(trimmed[..<slashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let model = String(trimmed[trimmed.index(after: slashIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate both parts are non-empty
        guard !provider.isEmpty, !model.isEmpty else {
            return nil
        }

        return ProviderConfig(provider: provider, model: model)
    }

    /// Parse a comma-separated list of providers
    /// - Parameter providersString: String like "openai/gpt-5.5,anthropic/claude-fable-5,ollama/llava:latest"
    /// - Returns: Array of parsed configurations
    public static func parseList(_ providersString: String) -> [ProviderConfig] {
        // Parse a comma-separated list of providers
        providersString
            .split(separator: ",")
            .compactMap { self.parse(String($0)) }
    }

    /// Get the first provider from a comma-separated list
    /// - Parameter providersString: String like "openai/gpt-5.5,anthropic/claude-fable-5"
    /// - Returns: First parsed configuration or nil if none valid
    public static func parseFirst(_ providersString: String) -> ProviderConfig? {
        // Get the first provider from a comma-separated list
        self.parseList(providersString).first
    }

    /// Result of determining the default model with conflict information
    public struct ModelDetermination {
        /// The determined language model
        public let model: LanguageModel

        /// Whether there was a conflict between env var and config
        public let hasConflict: Bool

        /// The model from environment variable (if any)
        public let environmentModel: String?

        /// The model from configuration (if any)
        public let configModel: String?

        public init(
            model: LanguageModel,
            hasConflict: Bool,
            environmentModel: String? = nil,
            configModel: String? = nil,
        ) {
            self.model = model
            self.hasConflict = hasConflict
            self.environmentModel = environmentModel
            self.configModel = configModel
        }
    }

    /// Determine the default model based on available providers and API keys
    /// - Parameters:
    ///   - providersString: The AI_PROVIDERS string (e.g., from TACHIKOMA_AI_PROVIDERS env var)
    ///   - hasOpenAI: Whether OpenAI API key is available
    ///   - hasAnthropic: Whether Anthropic API key is available
    ///   - hasGrok: Whether Grok API key is available
    ///   - hasGoogle: Whether Google/Gemini API key is available
    ///   - hasMiniMax: Whether MiniMax API key is available
    ///   - hasKimi: Whether Moonshot/Kimi API key is available
    ///   - hasOllama: Whether Ollama is available (always true as it doesn't require API key)
    ///   - configuredDefault: Optional default from configuration
    ///   - isEnvironmentProvided: Whether the providers string came from environment variable
    /// - Returns: Model determination result with conflict information
    public static func determineDefaultModelWithConflict(
        from providersString: String,
        hasOpenAI: Bool,
        hasAnthropic: Bool,
        hasGrok: Bool = false,
        hasGoogle: Bool? = nil,
        hasMiniMax: Bool = false,
        hasKimi: Bool = false,
        hasOllama: Bool = true,
        configuredDefault: LanguageModel? = nil,
        isEnvironmentProvided: Bool = false,
    )
        -> ModelDetermination
    {
        // Parse providers and find first available one
        let providers = self.parseList(providersString)
        var environmentModel: LanguageModel?

        let canUseGoogleProvider = hasGoogle ?? true
        let canFallbackToGoogle = hasGoogle ?? false

        for config in providers {
            switch config.provider.lowercased() {
            case "openai" where hasOpenAI:
                environmentModel = self.parseOpenAIModel(config.model)
            case "anthropic" where hasAnthropic:
                environmentModel = self.parseAnthropicModel(config.model)
            case "google" where canUseGoogleProvider, "gemini" where canUseGoogleProvider:
                environmentModel = self.parseGoogleModel(config.model)
            case "minimax" where hasMiniMax:
                environmentModel = self.parseMiniMaxModel(config.model)
            case "minimax-cn" where hasMiniMax, "minimax_cn" where hasMiniMax, "minimaxi" where hasMiniMax:
                environmentModel = self.parseMiniMaxCNModel(config.model)
            case "kimi" where hasKimi, "moonshot" where hasKimi:
                environmentModel = self.parseKimiModel(config.model)
            case "grok" where hasGrok, "xai" where hasGrok:
                environmentModel = self.parseGrokModel(config.model)
            case "ollama" where hasOllama:
                environmentModel = self.parseOllamaModel(config.model)
            default:
                continue
            }
            if environmentModel != nil {
                break
            }
        }

        // Determine if there's a conflict
        let hasConflict = isEnvironmentProvided &&
            environmentModel != nil &&
            configuredDefault != nil &&
            !self.modelsAreEqual(environmentModel, configuredDefault)

        // Environment variable takes precedence over config
        let finalModel: LanguageModel = if let envModel = environmentModel, isEnvironmentProvided {
            envModel
        } else if let configuredDefault {
            configuredDefault
        } else if let envModel = environmentModel {
            // Use the first available provider from the list even when not from environment
            envModel
        } else {
            // Fall back to defaults based on available API keys
            self.getDefaultFallbackModel(
                hasOpenAI: hasOpenAI,
                hasAnthropic: hasAnthropic,
                hasGrok: hasGrok,
                hasGoogle: canFallbackToGoogle,
                hasMiniMax: hasMiniMax,
                hasKimi: hasKimi,
                hasOllama: hasOllama,
            )
        }

        return ModelDetermination(
            model: finalModel,
            hasConflict: hasConflict,
            environmentModel: environmentModel?.description,
            configModel: configuredDefault?.description,
        )
    }

    /// Determine the default model based on available providers and API keys (simple version)
    public static func determineDefaultModel(
        from providersString: String,
        hasOpenAI: Bool,
        hasAnthropic: Bool,
        hasGrok: Bool = false,
        hasGoogle: Bool? = nil,
        hasMiniMax: Bool = false,
        hasKimi: Bool = false,
        hasOllama: Bool = true,
        configuredDefault: LanguageModel? = nil,
    )
        -> LanguageModel
    {
        // Determine the default model based on available providers and API keys (simple version)
        let determination = self.determineDefaultModelWithConflict(
            from: providersString,
            hasOpenAI: hasOpenAI,
            hasAnthropic: hasAnthropic,
            hasGrok: hasGrok,
            hasGoogle: hasGoogle,
            hasMiniMax: hasMiniMax,
            hasKimi: hasKimi,
            hasOllama: hasOllama,
            configuredDefault: configuredDefault,
            isEnvironmentProvided: false,
        )
        return determination.model
    }

    /// Extract provider name from a full provider/model string
    public static func extractProvider(from fullString: String) -> String? {
        // Extract provider name from a full provider/model string
        self.parse(fullString)?.provider
    }

    /// Extract model name from a full provider/model string
    public static func extractModel(from fullString: String) -> String? {
        // Extract model name from a full provider/model string
        self.parse(fullString)?.model
    }

    // MARK: - Private Helpers

    private static func parseOpenAIModel(_ modelString: String) -> LanguageModel? {
        if let model = LanguageModel.OpenAI.gpt6Model(for: modelString) {
            return .openai(model)
        }
        let normalized = modelString.lowercased()
        let compact = normalized.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        guard
            !normalized.hasPrefix("gpt-4"), !compact.hasPrefix("gpt4"),
            !normalized.hasPrefix("gpt-3"), !compact.hasPrefix("gpt3"),
            !normalized.hasPrefix("o3"), !normalized.hasPrefix("o4"),
            !normalized.hasPrefix("gpt-5.1"), !compact.hasPrefix("gpt51"),
            !normalized.hasPrefix("gpt-5.2"), !compact.hasPrefix("gpt52"),
            !normalized.contains("gpt-5-thinking"), !compact.contains("gpt5thinking") else
        {
            return nil
        }

        return switch normalized {
        case "chat-latest", "chatlatest":
            .openai(.chatLatest)
        case "gpt-5-chat-latest", "gpt5-chat-latest", "gpt5chatlatest":
            .openai(.gpt5ChatLatest)
        case "gpt-5.6", "gpt5.6", "gpt-5-6", "gpt5-6", "gpt56",
             "gpt-5.6-sol", "gpt5.6-sol", "gpt-5-6-sol", "gpt5-6-sol", "gpt56-sol", "gpt56sol":
            .openai(.gpt56Sol)
        case "gpt-5.6-terra", "gpt5.6-terra", "gpt-5-6-terra", "gpt5-6-terra", "gpt56-terra", "gpt56terra":
            .openai(.gpt56Terra)
        case "gpt-5.6-luna", "gpt5.6-luna", "gpt-5-6-luna", "gpt5-6-luna", "gpt56-luna", "gpt56luna":
            .openai(.gpt56Luna)
        case "gpt-5.5", "gpt5.5", "gpt-5-5", "gpt5-5", "gpt55": .openai(.gpt55)
        case "gpt-5.5-mini", "gpt5.5-mini", "gpt-5-5-mini", "gpt5-5-mini", "gpt55-mini", "gpt55mini":
            .openai(.gpt5Mini)
        case "gpt-5.5-nano", "gpt5.5-nano", "gpt-5-5-nano", "gpt5-5-nano", "gpt55-nano", "gpt55nano":
            .openai(.gpt5Nano)
        case "gpt-5.4", "gpt5.4", "gpt-5-4", "gpt5-4", "gpt54": .openai(.gpt54)
        case "gpt-5.4-mini", "gpt5.4-mini", "gpt-5-4-mini", "gpt5-4-mini", "gpt54-mini", "gpt54mini":
            .openai(.gpt54Mini)
        case "gpt-5.4-nano", "gpt5.4-nano", "gpt-5-4-nano", "gpt5-4-nano", "gpt54-nano", "gpt54nano":
            .openai(.gpt54Nano)
        case "gpt-5", "gpt5": .openai(.gpt5)
        case "gpt-5-pro", "gpt5-pro", "gpt5pro": .openai(.gpt5Pro)
        case "gpt-5-mini", "gpt5-mini", "gpt5mini": .openai(.gpt5Mini)
        case "gpt-5-nano", "gpt5-nano", "gpt5nano": .openai(.gpt5Nano)
        default:
            // Handle custom/fine-tuned models
            .openai(.custom(modelString))
        }
    }

    private static func parseAnthropicModel(_ modelString: String) -> LanguageModel? {
        let normalized = modelString.lowercased()
        let compact = normalized.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        guard
            !normalized.hasPrefix("claude-3"), !compact.hasPrefix("claude3"),
            normalized != "claude-opus-4-20250514",
            normalized != "claude-sonnet-4-20250514",
            !normalized.contains("-thinking") else
        {
            return nil
        }

        return switch normalized {
        case "claude-opus-5", "claude-opus5", "claude-opus-5-latest", "opus-5", "opus.5", "opus5":
            .anthropic(.opus5)
        case "claude-fable-5", "claude-fable-5-latest", "fable-5", "fable.5", "fable5", "fable":
            .anthropic(.fable5)
        case "claude-sonnet-5", "sonnet-5", "sonnet.5", "sonnet5", "sonnet":
            .anthropic(.sonnet5)
        case "claude-opus-4-8", "claude-opus-4.8", "claude-opus-4-8-latest", "opus-4-8", "opus-4.8",
             "opus48":
            .anthropic(.opus48)
        case "anthropic", "claude", "claude-opus", "opus", "claude-latest", "claude_latest", "claudelatest",
             "claude-default", "claude_default":
            .anthropic(.opus5)
        case "claude-opus-4-7", "claude-opus-4.7", "claude-opus-4-7-latest", "opus-4-7", "opus-4.7", "opus47":
            .anthropic(.opus47)
        case "claude-opus-4-5", "claude-opus-4.5", "claude-opus-4-5-latest", "opus-4-5", "opus-4.5", "opus45":
            .anthropic(.opus45)
        case "claude-opus-4-1-20250805", "claude-opus-4", "opus-4": .anthropic(.opus4)
        case "claude-sonnet-4-6", "claude-sonnet-4.6", "sonnet-4-6", "sonnet-4.6", "sonnet46":
            .anthropic(.sonnet46)
        case "claude-sonnet-4-5-20250929", "claude-sonnet-4.5", "sonnet-4-5", "sonnet-4.5", "sonnet45":
            .anthropic(.sonnet45)
        case "claude-haiku-4-5-20251001", "claude-haiku-4-5", "claude-haiku-4.5", "haiku-4-5", "haiku45":
            .anthropic(.haiku45)
        default:
            // Handle custom models
            .anthropic(.custom(modelString))
        }
    }

    private static func parseGoogleModel(_ modelString: String) -> LanguageModel? {
        switch modelString.lowercased() {
        case "gemini-3.5-flash", "gemini35flash", "gemini-3-5-flash":
            .google(.gemini35Flash)
        case "gemini-3.1-pro-preview", "gemini-3.1-pro", "gemini31pro", "gemini31propreview":
            .google(.gemini31ProPreview)
        case "gemini-3.1-flash-lite", "gemini31flashlite", "gemini-3.1-flashlite":
            .google(.gemini31FlashLite)
        case "gemini-3-flash", "gemini-3-flash-preview", "gemini3flash", "gemini-3flash":
            .google(.gemini3Flash)
        case "gemini-2.5-pro", "gemini25pro", "gemini2.5pro":
            .google(.gemini25Pro)
        case "gemini-2.5-flash", "gemini25flash":
            .google(.gemini25Flash)
        case "gemini-2.5-flash-lite", "gemini25flashlite", "gemini-2.5-flashlite":
            .google(.gemini25FlashLite)
        case "gemini":
            .google(.gemini35Flash)
        default:
            nil
        }
    }

    private static func parseMiniMaxModel(_ modelString: String) -> LanguageModel? {
        switch modelString.lowercased() {
        case "minimax-m2.7", "minimax-m2-7", "m2.7", "m2-7":
            .minimax(.m27)
        case "minimax-m2.7-highspeed", "minimax-m2-7-highspeed", "m2.7-highspeed", "m2-7-highspeed":
            .minimax(.m27Highspeed)
        case "minimax-m3", "m3":
            .minimax(.m3)
        default:
            nil
        }
    }

    private static func parseMiniMaxCNModel(_ modelString: String) -> LanguageModel? {
        switch modelString.lowercased() {
        case "minimax-m2.7", "minimax-m2-7", "m2.7", "m2-7":
            .minimaxCN(.m27)
        case "minimax-m2.7-highspeed", "minimax-m2-7-highspeed", "m2.7-highspeed", "m2-7-highspeed":
            .minimaxCN(.m27Highspeed)
        case "minimax-m3", "m3":
            .minimaxCN(.m3)
        default:
            nil
        }
    }

    private static func parseKimiModel(_ modelString: String) -> LanguageModel? {
        switch modelString.lowercased() {
        case "kimi-k2.7-code-highspeed", "kimi-k2-7-code-highspeed", "k2.7-code-highspeed", "k2-7-code-highspeed":
            .kimi(.k27CodeHighspeed)
        case "kimi-k2.7-code", "kimi-k2-7-code", "k2.7-code", "k2-7-code":
            .kimi(.k27Code)
        case "kimi-k2.6", "kimi-k2-6", "k2.6", "k2-6":
            .kimi(.k26)
        default:
            nil
        }
    }

    private static func parseGrokModel(_ modelString: String) -> LanguageModel? {
        switch modelString.lowercased() {
        case "grok-4.3", "grok-4-3", "grok43", "grok-4.3-latest", "grok-4-latest", "grok-4", "grok-latest":
            return .grok(.grok43)
        case "grok-4.20-0309-reasoning", "grok-4-20-0309-reasoning":
            return .grok(.grok420Reasoning)
        case "grok-4.20-0309-non-reasoning", "grok-4-20-0309-non-reasoning":
            return .grok(.grok420NonReasoning)
        default:
            if self.isUnsupportedLegacyGrokModel(modelString) {
                return nil
            }
            return .grok(.custom(modelString))
        }
    }

    private static func isUnsupportedLegacyGrokModel(_ modelString: String) -> Bool {
        let normalized = modelString.lowercased()
        return normalized.contains("grok-4.20-multi-agent") ||
            normalized.contains("grok-4-20-multi-agent") ||
            normalized.contains("grok420multiagent")
    }

    private static func parseOllamaModel(_ modelString: String) -> LanguageModel? {
        switch modelString.lowercased() {
        // GPT-OSS models
        case "gpt-oss:120b", "gpt-oss-120b": .ollama(.gptOSS120B)
        case "gpt-oss:20b", "gpt-oss-20b": .ollama(.gptOSS20B)
        // Quantized versions removed - not defined in model enum
        // Llama models
        case "llama3.3", "llama3.3:latest": .ollama(.llama33)
        case "llama3.2", "llama3.2:latest": .ollama(.llama32)
        case "llama3.1", "llama3.1:latest": .ollama(.llama31)
        case "llava", "llava:latest": .ollama(.llava)
        case "llava:13b": .ollama(.custom("llava:13b"))
        case "llava:34b": .ollama(.custom("llava:34b"))
        case "mistral-nemo", "mistral-nemo:latest": .ollama(.mistralNemo)
        case "qwen2.5", "qwen2.5:latest": .ollama(.qwen25)
        default:
            .ollama(.custom(modelString))
        }
    }

    private static func getDefaultFallbackModel(
        hasOpenAI: Bool,
        hasAnthropic: Bool,
        hasGrok: Bool,
        hasGoogle: Bool,
        hasMiniMax: Bool,
        hasKimi: Bool,
        hasOllama _: Bool,
    )
        -> LanguageModel
    {
        if hasAnthropic {
            .anthropic(.opus5)
        } else if hasOpenAI {
            .openai(.gpt55)
        } else if hasGrok {
            .grok(.grok43)
        } else if hasGoogle {
            .google(.gemini35Flash)
        } else if hasMiniMax {
            .minimax(.m27)
        } else if hasKimi {
            .kimi(.k26)
        } else {
            .ollama(.llama33)
        }
    }

    private static func modelsAreEqual(_ model1: LanguageModel?, _ model2: LanguageModel?) -> Bool {
        guard let model1, let model2 else { return false }
        return model1.description == model2.description
    }
}
