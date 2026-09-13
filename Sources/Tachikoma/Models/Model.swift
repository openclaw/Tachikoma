import Foundation

// MARK: - Modern Language Model System

/// Language model selection following AI SDK patterns
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum LanguageModel: Sendable, CustomStringConvertible, Hashable {
    // Provider-specific models
    case openai(OpenAI)
    case anthropic(Anthropic)
    case google(Google)
    case mistral(Mistral)
    case groq(Groq)
    case grok(Grok)
    case ollama(Ollama)
    case lmstudio(LMStudio)
    case minimax(MiniMax)
    case minimaxCN(MiniMax)
    case kimi(Kimi)
    case azureOpenAI(deployment: String, resource: String? = nil, apiVersion: String? = nil, endpoint: String? = nil)

    // Third-party aggregators
    case openRouter(modelId: String)
    case together(modelId: String)
    case replicate(modelId: String)

    // Custom endpoints
    case openaiCompatible(modelId: String, baseURL: String)
    case anthropicCompatible(modelId: String, baseURL: String)
    case custom(provider: any ModelProvider)

    // MARK: - Model Properties

    public var description: String {
        switch self {
        case let .openai(model):
            return "OpenAI/\(model.modelId)"
        case let .anthropic(model):
            return "Anthropic/\(model.modelId)"
        case let .google(model):
            return "Google/\(model.userFacingModelId)"
        case let .mistral(model):
            return "Mistral/\(model.rawValue)"
        case let .groq(model):
            return "Groq/\(model.rawValue)"
        case let .grok(model):
            return "Grok/\(model.modelId)"
        case let .ollama(model):
            return "Ollama/\(model.modelId)"
        case let .lmstudio(model):
            return "LMStudio/\(model.modelId)"
        case let .minimax(model):
            return "MiniMax/\(model.modelId)"
        case let .minimaxCN(model):
            return "MiniMax China/\(model.modelId)"
        case let .kimi(model):
            return "Kimi/\(model.modelId)"
        case let .azureOpenAI(deployment, resource, apiVersion, endpoint):
            let host = endpoint ?? resource ?? "endpoint"
            let version = apiVersion ?? "api-version-default"
            return "AzureOpenAI/\(deployment)@\(host)?v=\(version)"
        case let .openRouter(modelId):
            return "OpenRouter/\(modelId)"
        case let .together(modelId):
            return "Together/\(modelId)"
        case let .replicate(modelId):
            return "Replicate/\(modelId)"
        case let .openaiCompatible(modelId, baseURL):
            return "OpenAI-Compatible/\(modelId)@\(baseURL)"
        case let .anthropicCompatible(modelId, baseURL):
            return "Anthropic-Compatible/\(modelId)@\(baseURL)"
        case let .custom(provider):
            return "Custom/\(provider.modelId)"
        }
    }

    public var modelId: String {
        switch self {
        case let .openai(model):
            model.modelId
        case let .anthropic(model):
            model.modelId
        case let .google(model):
            model.userFacingModelId
        case let .mistral(model):
            model.rawValue
        case let .groq(model):
            model.rawValue
        case let .grok(model):
            model.modelId
        case let .ollama(model):
            model.modelId
        case let .lmstudio(model):
            model.modelId
        case let .minimax(model):
            model.modelId
        case let .minimaxCN(model):
            model.modelId
        case let .kimi(model):
            model.modelId
        case let .azureOpenAI(deployment, _, _, _):
            deployment
        case let .openRouter(modelId):
            modelId
        case let .together(modelId):
            modelId
        case let .replicate(modelId):
            modelId
        case let .openaiCompatible(modelId, _):
            modelId
        case let .anthropicCompatible(modelId, _):
            modelId
        case let .custom(provider):
            provider.modelId
        }
    }

    public var supportsVision: Bool {
        switch self {
        case let .openai(model):
            model.supportsVision
        case let .anthropic(model):
            model.supportsVision
        case let .google(model):
            model.supportsVision
        case let .mistral(model):
            model.supportsVision
        case let .groq(model):
            model.supportsVision
        case let .grok(model):
            model.supportsVision
        case let .ollama(model):
            model.supportsVision
        case let .lmstudio(model):
            model.supportsVision
        case let .minimax(model):
            model.supportsVision
        case let .minimaxCN(model):
            model.supportsVision
        case let .kimi(model):
            model.supportsVision
        case .azureOpenAI:
            true // Azure mirrors OpenAI models with vision support when available
        case .openRouter, .together, .replicate:
            false // Unknown, assume no vision support
        case .openaiCompatible, .anthropicCompatible:
            false // Unknown, assume no vision support
        case let .custom(provider):
            provider.capabilities.supportsVision
        }
    }

    public var supportsStreaming: Bool {
        if case let .anthropic(model) = self {
            return model.supportsStreaming
        }
        if case let .anthropicCompatible(modelId, _) = self {
            return !Anthropic.hasStreamingRefusalRisk(modelId: modelId)
        }
        if case let .openRouter(modelId) = self {
            return !Anthropic.hasStreamingRefusalRisk(modelId: modelId)
        }
        if case let .together(modelId) = self {
            return !Anthropic.hasStreamingRefusalRisk(modelId: modelId)
        }
        if case let .openaiCompatible(modelId, _) = self {
            guard !Anthropic.hasStreamingRefusalRisk(modelId: modelId) else {
                return false
            }
            let normalized = modelId.lowercased()
            guard
                normalized.contains("claude") ||
                normalized.hasPrefix("anthropic/") ||
                normalized.hasPrefix("anthropic.") else
            {
                return true
            }
            return true
        }
        if
            case let .custom(provider) = self,
            let parsed = ProviderParser.parse(provider.modelId),
            CustomProviderRegistry.shared.get(parsed.provider)?.kind == .anthropic
        {
            return !Anthropic.hasStreamingRefusalRisk(modelId: parsed.model)
        }
        if case let .custom(provider) = self {
            return provider.capabilities.supportsStreaming
        }
        return true
    }

    public var providerName: String {
        switch self {
        case .openai:
            "OpenAI"
        case .anthropic:
            "Anthropic"
        case .google:
            "Google"
        case .mistral:
            "Mistral"
        case .groq:
            "Groq"
        case .grok:
            "Grok"
        case .ollama:
            "Ollama"
        case .lmstudio:
            "LMStudio"
        case .minimax:
            "MiniMax"
        case .minimaxCN:
            "MiniMax China"
        case .kimi:
            "Kimi"
        case .openRouter:
            "OpenRouter"
        case .together:
            "Together"
        case .replicate:
            "Replicate"
        case .openaiCompatible:
            "OpenAI-Compatible"
        case .anthropicCompatible:
            "Anthropic-Compatible"
        case .azureOpenAI:
            "AzureOpenAI"
        case .custom:
            "Custom"
        }
    }

    // MARK: - Default Model

    public static let `default`: LanguageModel = .anthropic(.opus5)
    public static let defaultStreaming: LanguageModel = .openai(.gpt55)

    // MARK: - Convenience Static Properties

    /// Default Claude model (Opus 5)
    public static let claude: LanguageModel = .anthropic(.opus5)

    /// Default Grok model (Grok 4.3)
    public static let grok4: LanguageModel = .grok(.grok43)

    /// Default Llama model
    public static let llama: LanguageModel = .ollama(.llama33)
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension LanguageModel {
    public var supportsAudioInput: Bool {
        switch self {
        case let .openai(model):
            model.supportsAudioInput
        case let .anthropic(model):
            model.supportsAudioInput
        case let .google(model):
            model.supportsAudioInput
        case let .mistral(model):
            model.supportsAudioInput
        case let .groq(model):
            model.supportsAudioInput
        case let .grok(model):
            model.supportsAudioInput
        case let .ollama(model):
            model.supportsAudioInput
        case .lmstudio:
            false // LMStudio doesn't support audio input
        case let .minimax(model):
            model.supportsAudioInput
        case let .minimaxCN(model):
            model.supportsAudioInput
        case let .kimi(model):
            model.supportsAudioInput
        case .azureOpenAI:
            false // Azure chat endpoints currently omit audio input
        case .openRouter, .together, .replicate:
            false // Unknown, assume no audio input support
        case .openaiCompatible, .anthropicCompatible:
            false // Unknown, assume no audio input support
        case let .custom(provider):
            provider.capabilities.supportsAudioInput
        }
    }

    public var supportsAudioOutput: Bool {
        switch self {
        case let .openai(model):
            model.supportsAudioOutput
        case let .anthropic(model):
            model.supportsAudioOutput
        case let .google(model):
            model.supportsAudioOutput
        case let .mistral(model):
            model.supportsAudioOutput
        case let .groq(model):
            model.supportsAudioOutput
        case let .grok(model):
            model.supportsAudioOutput
        case let .ollama(model):
            model.supportsAudioOutput
        case .lmstudio:
            false // LMStudio doesn't support audio output
        case let .minimax(model):
            model.supportsAudioOutput
        case let .minimaxCN(model):
            model.supportsAudioOutput
        case let .kimi(model):
            model.supportsAudioOutput
        case .azureOpenAI:
            false // Azure chat endpoints currently omit audio output
        case .openRouter, .together, .replicate:
            false // Unknown, assume no audio output support
        case .openaiCompatible, .anthropicCompatible:
            false // Unknown, assume no audio output support
        case let .custom(provider):
            provider.capabilities.supportsAudioOutput
        }
    }

    public var supportsTools: Bool {
        switch self {
        case let .openai(model):
            model.supportsTools
        case let .anthropic(model):
            model.supportsTools
        case let .google(model):
            model.supportsTools
        case let .mistral(model):
            model.supportsTools
        case let .groq(model):
            model.supportsTools
        case let .grok(model):
            model.supportsTools
        case let .ollama(model):
            model.supportsTools
        case let .lmstudio(model):
            model.supportsTools
        case let .minimax(model):
            model.supportsTools
        case let .minimaxCN(model):
            model.supportsTools
        case let .kimi(model):
            model.supportsTools
        case .azureOpenAI:
            true // Azure OpenAI mirrors OpenAI tool support
        case .openRouter, .together, .replicate:
            true // Most aggregator models support tools
        case .openaiCompatible, .anthropicCompatible:
            true // Assume tools support for compatible APIs
        case let .custom(provider):
            provider.capabilities.supportsTools
        }
    }

    public var contextLength: Int {
        switch self {
        case let .openai(model):
            model.contextLength
        case let .anthropic(model):
            model.contextLength
        case let .google(model):
            model.contextLength
        case let .mistral(model):
            model.contextLength
        case let .groq(model):
            model.contextLength
        case let .grok(model):
            model.contextLength
        case let .ollama(model):
            model.contextLength
        case let .lmstudio(model):
            model.contextLength
        case let .minimax(model):
            model.contextLength
        case let .minimaxCN(model):
            model.contextLength
        case let .kimi(model):
            model.contextLength
        case .azureOpenAI:
            128_000 // conservative default matching OpenAI tier
        case let .openRouter(modelId), let .together(modelId):
            if Anthropic.hasMillionTokenContext(modelId: modelId) {
                1_000_000
            } else {
                OpenAI.gpt56Model(for: modelId)?.contextLength ?? 128_000
            }
        case .replicate:
            128_000 // Common default
        case let .openaiCompatible(modelId, _):
            if Anthropic.hasMillionTokenContext(modelId: modelId) {
                1_000_000
            } else {
                OpenAI.gpt56Model(for: modelId)?.contextLength ?? 128_000
            }
        case let .anthropicCompatible(modelId, _):
            Anthropic.hasMillionTokenContext(modelId: modelId) ? 1_000_000 : 128_000
        case let .custom(provider):
            provider.capabilities.contextLength
        }
    }
}

// MARK: - Hashable Conformance

extension LanguageModel {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .openai(model):
            hasher.combine("openai")
            hasher.combine(model)
        case let .anthropic(model):
            hasher.combine("anthropic")
            hasher.combine(model)
        case let .google(model):
            hasher.combine("google")
            hasher.combine(model)
        case let .mistral(model):
            hasher.combine("mistral")
            hasher.combine(model)
        case let .groq(model):
            hasher.combine("groq")
            hasher.combine(model)
        case let .grok(model):
            hasher.combine("grok")
            hasher.combine(model)
        case let .ollama(model):
            hasher.combine("ollama")
            hasher.combine(model)
        case let .lmstudio(model):
            hasher.combine("lmstudio")
            hasher.combine(model)
        case let .minimax(model):
            hasher.combine("minimax")
            hasher.combine(model)
        case let .minimaxCN(model):
            hasher.combine("minimax-cn")
            hasher.combine(model)
        case let .kimi(model):
            hasher.combine("kimi")
            hasher.combine(model)
        case let .openRouter(modelId):
            hasher.combine("openRouter")
            hasher.combine(modelId)
        case let .together(modelId):
            hasher.combine("together")
            hasher.combine(modelId)
        case let .replicate(modelId):
            hasher.combine("replicate")
            hasher.combine(modelId)
        case let .openaiCompatible(modelId, baseURL):
            hasher.combine("openaiCompatible")
            hasher.combine(modelId)
            hasher.combine(baseURL)
        case let .anthropicCompatible(modelId, baseURL):
            hasher.combine("anthropicCompatible")
            hasher.combine(modelId)
            hasher.combine(baseURL)
        case let .azureOpenAI(deployment, resource, apiVersion, endpoint):
            hasher.combine("azureOpenAI")
            hasher.combine(deployment)
            hasher.combine(resource)
            hasher.combine(apiVersion)
            hasher.combine(endpoint)
        case let .custom(provider):
            hasher.combine("custom")
            hasher.combine(provider.modelId)
            hasher.combine(provider.baseURL)
        }
    }

    public static func == (lhs: LanguageModel, rhs: LanguageModel) -> Bool {
        switch (lhs, rhs) {
        case let (.openai(lhsModel), .openai(rhsModel)):
            lhsModel == rhsModel
        case let (.anthropic(lhsModel), .anthropic(rhsModel)):
            lhsModel == rhsModel
        case let (.google(lhsModel), .google(rhsModel)):
            lhsModel == rhsModel
        case let (.mistral(lhsModel), .mistral(rhsModel)):
            lhsModel == rhsModel
        case let (.groq(lhsModel), .groq(rhsModel)):
            lhsModel == rhsModel
        case let (.grok(lhsModel), .grok(rhsModel)):
            lhsModel == rhsModel
        case let (.ollama(lhsModel), .ollama(rhsModel)):
            lhsModel == rhsModel
        case let (.lmstudio(lhsModel), .lmstudio(rhsModel)):
            lhsModel == rhsModel
        case let (.minimax(lhsModel), .minimax(rhsModel)):
            lhsModel == rhsModel
        case let (.minimaxCN(lhsModel), .minimaxCN(rhsModel)):
            lhsModel == rhsModel
        case let (.kimi(lhsModel), .kimi(rhsModel)):
            lhsModel == rhsModel
        case let (.openRouter(lhsId), .openRouter(rhsId)):
            lhsId == rhsId
        case let (.together(lhsId), .together(rhsId)):
            lhsId == rhsId
        case let (.replicate(lhsId), .replicate(rhsId)):
            lhsId == rhsId
        case let (.openaiCompatible(lhsId, lhsURL), .openaiCompatible(rhsId, rhsURL)):
            lhsId == rhsId && lhsURL == rhsURL
        case let (.anthropicCompatible(lhsId, lhsURL), .anthropicCompatible(rhsId, rhsURL)):
            lhsId == rhsId && lhsURL == rhsURL
        case let (
            .azureOpenAI(lhsDeployment, lhsResource, lhsAPIVersion, lhsEndpoint),
            .azureOpenAI(rhsDeployment, rhsResource, rhsAPIVersion, rhsEndpoint),
        ):
            lhsDeployment == rhsDeployment &&
                lhsResource == rhsResource &&
                lhsAPIVersion == rhsAPIVersion &&
                lhsEndpoint == rhsEndpoint
        case let (.custom(lhsProvider), .custom(rhsProvider)):
            lhsProvider.modelId == rhsProvider.modelId && lhsProvider.baseURL == rhsProvider.baseURL
        default:
            false
        }
    }
}

// MARK: - Backward Compatibility

/// Backward compatibility alias for LanguageModel
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public typealias Model = LanguageModel
