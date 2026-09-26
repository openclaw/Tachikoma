import Foundation

// MARK: - Provider Factory

/// Factory for creating model providers from LanguageModel enum
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ProviderFactory {
    /// Create a provider for the specified language model
    public static func createProvider(
        for model: LanguageModel,
        configuration: TachikomaConfiguration,
    ) throws
        -> any ModelProvider
    {
        // Create a provider for the specified language model
        switch model {
        case let .openai(openaiModel):
            if let model = LanguageModel.OpenAI.gpt6Model(for: openaiModel.modelId) {
                return try OpenAIResponsesProvider(model: model, configuration: configuration)
            }
            // Use Responses API for the GPT-5 family
            switch openaiModel {
            case .chatLatest,
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
                 .gpt5Nano:
                return try OpenAIResponsesProvider(model: openaiModel, configuration: configuration)
            default:
                return try OpenAIProvider(model: openaiModel, configuration: configuration)
            }

        case let .anthropic(anthropicModel):
            return try AnthropicProvider(model: anthropicModel, configuration: configuration)

        case let .google(googleModel):
            return try GoogleProvider(model: googleModel, configuration: configuration)

        case let .mistral(mistralModel):
            return try MistralProvider(model: mistralModel, configuration: configuration)

        case let .groq(groqModel):
            return try GroqProvider(model: groqModel, configuration: configuration)

        case let .grok(grokModel):
            return try GrokProvider(model: grokModel, configuration: configuration)

        case let .ollama(ollamaModel):
            return try OllamaProvider(model: ollamaModel, configuration: configuration)

        case let .lmstudio(lmstudioModel):
            // LMStudio doesn't need API key, just use default configuration
            let baseURL = configuration.getBaseURL(for: "lmstudio") ?? "http://localhost:1234/v1"
            return LMStudioProvider(
                baseURL: baseURL,
                modelId: lmstudioModel.modelId,
            )

        case let .minimax(minimaxModel):
            guard let apiKey = configuration.getAPIKey(for: .minimax) else {
                throw TachikomaError.authenticationFailed("MINIMAX_API_KEY not found")
            }
            return try Self.makeMiniMaxProvider(
                model: minimaxModel,
                provider: .minimax,
                apiKey: apiKey,
                configuration: configuration,
            )

        case let .minimaxCN(minimaxModel):
            guard let apiKey = configuration.getAPIKey(for: .minimaxCN) ?? configuration.getAPIKey(for: .minimax) else {
                throw TachikomaError.authenticationFailed("MINIMAX_CN_API_KEY or MINIMAX_API_KEY not found")
            }
            return try Self.makeMiniMaxProvider(
                model: minimaxModel,
                provider: .minimaxCN,
                apiKey: apiKey,
                configuration: configuration,
            )

        case let .kimi(kimiModel):
            return try KimiProvider(model: kimiModel, configuration: configuration)

        case let .openRouter(modelId):
            return try OpenRouterProvider(modelId: modelId, configuration: configuration)

        case let .together(modelId):
            return try TogetherProvider(modelId: modelId, configuration: configuration)

        case let .replicate(modelId):
            return try ReplicateProvider(modelId: modelId, configuration: configuration)

        case let .openaiCompatible(modelId, baseURL):
            return try OpenAICompatibleProvider(modelId: modelId, baseURL: baseURL, configuration: configuration)

        case let .anthropicCompatible(modelId, baseURL):
            return try AnthropicCompatibleProvider(modelId: modelId, baseURL: baseURL, configuration: configuration)

        case let .azureOpenAI(deployment, resource, apiVersion, endpoint):
            return try AzureOpenAIProvider(
                deploymentId: deployment,
                resource: resource,
                apiVersion: apiVersion,
                endpoint: endpoint,
                configuration: configuration,
            )

        case let .custom(provider):
            // If the custom provider is a dynamic selection string (providerId/model),
            // attempt to resolve via CustomProviderRegistry first.
            if let parsed = ProviderParser.parse(provider.modelId) {
                if let custom = CustomProviderRegistry.shared.get(parsed.provider) {
                    switch custom.kind {
                    case .openai:
                        return try OpenAICompatibleProvider(
                            modelId: parsed.model,
                            baseURL: custom.baseURL,
                            configuration: configuration,
                            apiKey: custom.apiKey,
                            additionalHeaders: custom.headers,
                        )
                    case .anthropic:
                        return try AnthropicCompatibleProvider(
                            modelId: parsed.model,
                            baseURL: custom.baseURL,
                            configuration: configuration,
                            apiKey: custom.apiKey,
                            additionalHeaders: custom.headers,
                            reasoningProvider: "custom-anthropic",
                            reasoningBaseURL: custom.baseURL,
                        )
                    }
                }
            }
            return provider
        }
    }

    private static func makeMiniMaxProvider(
        model: LanguageModel.MiniMax,
        provider: Provider,
        apiKey: String,
        configuration: TachikomaConfiguration,
    ) throws
        -> any ModelProvider
    {
        let baseURL = configuration.getBaseURL(for: provider) ?? provider.defaultBaseURL ?? "https://api.minimax.io/anthropic"
        return try AnthropicCompatibleProvider(
            modelId: model.modelId,
            baseURL: baseURL,
            configuration: configuration,
            apiKey: apiKey,
            // MiniMax's Anthropic-compatible setup uses Claude Code-style Authorization auth, not Anthropic x-api-key.
            auth: .bearer(apiKey, betaHeader: nil),
            capabilities: ModelCapabilities(
                supportsVision: model.supportsVision,
                supportsTools: model.supportsTools,
                supportsStreaming: true,
                contextLength: model.contextLength,
                maxOutputTokens: 8192,
            ),
            reasoningProvider: provider == .minimaxCN ? "minimax-cn" : "minimax",
            reasoningBaseURL: baseURL,
        )
    }
}

// MARK: - Third-Party Aggregators

// MARK: - Compatible Providers

// MARK: - Mock Provider for Testing
