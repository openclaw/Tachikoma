import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Tachikoma

struct CLIConfig {
    var modelString: String?
    var apiMode: OpenAIAPIMode? // For OpenAI models
    var stream: Bool = false
    var showThinking: Bool = false // Show the provider's reasoning summary
    var verbose: Bool = false // Show detailed debug output
    var showHelp: Bool = false
    var showVersion: Bool = false
    var showConfig: Bool = false
    var query: String?
}

@main
struct AICLI {
    static func main() async {
        // Parse command line arguments
        guard let config = parseArguments() else {
            exit(1)
        }

        // Handle special commands
        if config.showVersion {
            self.showVersion()
            return
        }

        if config.showHelp {
            self.showHelp()
            return
        }

        if config.showConfig {
            self.showConfiguration(config: config)
            return
        }

        // Validate query
        guard let query = config.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("❌ Error: No query provided")
            print("Use --help for usage information")
            exit(1)
        }

        // Parse and validate model
        let model: LanguageModel
        do {
            if let modelString = config.modelString {
                model = try ModelSelector.parseModel(modelString)
            } else {
                model = .openai(.gpt55)
            }
        } catch {
            print("❌ Error parsing model: \(error)")
            print("Use --help to see available models")
            exit(1)
        }

        // Check API key for the provider
        do {
            try self.validateAPIKey(for: model)
        } catch {
            print("❌ \(error)")
            self.showAPIKeyInstructions(for: model)
            exit(1)
        }

        // Set verbose mode if requested
        if config.verbose {
            TachikomaConfiguration.current.verbose = true
        }

        // Display configuration
        self.showRequestConfig(model: model, config: config, query: query)

        // Execute the request
        do {
            if config.stream {
                try await self.executeStreamingRequest(model: model, config: config, query: query)
            } else {
                try await self.executeRequest(model: model, config: config, query: query)
            }
        } catch {
            print("\n❌ Error: \(error)")

            // Provide helpful context for common errors
            if let error = error as? TachikomaError {
                self.showErrorHelp(for: error, model: model)
            }
            exit(1)
        }
    }

    // MARK: - Argument Parsing

    static func parseArguments() -> CLIConfig? {
        let args = CommandLine.arguments
        var config = CLIConfig()
        var queryArgs: [String] = []

        var i = 1
        while i < args.count {
            let arg = args[i]

            switch arg {
            case "--help", "-h":
                config.showHelp = true
                return config
            case "--version":
                config.showVersion = true
                return config
            case "--config":
                config.showConfig = true
                return config
            case "--model", "-m":
                guard i + 1 < args.count else {
                    print("❌ Error: --model requires a value")
                    return nil
                }
                config.modelString = args[i + 1]
                i += 2
            case "--api":
                guard i + 1 < args.count else {
                    print("❌ Error: --api requires a value")
                    return nil
                }
                let apiValue = args[i + 1].lowercased()
                if let mode = OpenAIAPIMode(rawValue: apiValue) {
                    config.apiMode = mode
                    i += 2
                } else {
                    print("❌ Error: --api must be 'chat' or 'responses'")
                    return nil
                }
            case "--stream", "-s":
                config.stream = true
                i += 1
            case "--thinking":
                config.showThinking = true
                i += 1
            case "--verbose", "-v":
                config.verbose = true
                i += 1
            default:
                if arg.starts(with: "--") {
                    print("❌ Error: Unknown option '\(arg)'")
                    print("Use --help for available options")
                    return nil
                } else {
                    queryArgs.append(arg)
                    i += 1
                }
            }
        }

        if !queryArgs.isEmpty {
            config.query = queryArgs.joined(separator: " ")
        }

        return config
    }

    // MARK: - Help and Information

    static func showVersion() {
        print("AI CLI v1.0.0")
        print("Powered by Tachikoma - Universal AI Integration Library")
        print("Supports: OpenAI, Anthropic, Google, Mistral, Groq, Grok, Ollama")
    }

    static func showHelp() {
        // swiftformat:disable indent trailingSpace
        print("""
        AI CLI - Universal AI Assistant

        USAGE:
            ai-cli [OPTIONS] "your question here"

        OPTIONS:
            -m, --model <MODEL>     Specify the AI model to use
            --api <API>            For OpenAI models: 'chat' or 'responses' (default: responses for GPT-5)
            -s, --stream           Stream the response (partial support)
            --thinking             Show reasoning summary (GPT-5 via Responses API)
            --verbose, -v          Show detailed debug output
            --config               Show current configuration and exit
            -h, --help             Show this help message
            --version              Show version information

        EXAMPLES:
            # Use default model (GPT-5)
            ai-cli "What is the capital of France?"

            # Use specific models
            ai-cli --model claude "Explain quantum computing"
            ai-cli --model gpt-5.5 "Describe this image"
            ai-cli --model grok "Tell me a joke"
            ai-cli --model llama3.3 "Help me debug this code"

            # OpenAI API selection
            ai-cli --model gpt-5 --api chat "Use Chat Completions API"
            ai-cli --model gpt-5 --api responses "Use Responses API"

            # Streaming responses
            ai-cli --stream --model claude "Write a short story"

            # Show reasoning summary
            ai-cli --thinking --model gpt-5.5 "Solve this logic puzzle"
            ai-cli --thinking --model gpt-5 "Complex reasoning task"

        PROVIDERS & MODELS:

        OpenAI:
          • gpt-5, gpt-5-pro, gpt-5-mini, gpt-5-nano (GPT-5 series, August 2025)
          • gpt-5.5, gpt-5.4, gpt-5.4-mini, gpt-5.4-nano

        Anthropic:
          • claude-opus-4-7, claude-opus-4-5, claude-opus-4-1-20250805
          • claude-sonnet-4-6, claude-sonnet-4-5-20250929, claude-haiku-4-5

        Google:
          • gemini-3.1-pro-preview, gemini-3.1-flash-lite
          • gemini-3-flash-preview
          • gemini-2.5-pro (reasoning, thinking support)
          • gemini-2.5-flash, gemini-2.5-flash-lite

        Mistral:
          • mistral-large-latest, mistral-medium-latest, mistral-medium-3-5
          • mistral-small-latest, open-mistral-nemo-2407, codestral-latest

        Groq (Ultra-fast):
          • openai/gpt-oss-120b, openai/gpt-oss-20b
          • llama-3.3-70b-versatile, llama-3.1-8b-instant
          • meta-llama/llama-4-maverick-17b-128e-instruct

        Grok (xAI):
          • grok-4.3
          • grok-4.20-0309-reasoning, grok-4.20-0309-non-reasoning

        Ollama (Local):
          • llama3.3, llama3.2, llama3.1 (Recommended)
          • llava, bakllava (Vision models)
          • mistral-nemo, qwen2.5
          • deepseek-r1:8b, deepseek-r1:671b, command-r-plus
          • Custom: any-model:tag

        SHORTCUTS:
          • claude, opus → claude-opus-4-7
          • gpt → gpt-5.5
          • grok → grok-4.3
          • gemini → gemini-3.1-pro-preview
          • llama, llama3 → llama3.3

        API KEYS:
        Set the appropriate environment variable for your provider:
          • OPENAI_API_KEY for OpenAI models
          • ANTHROPIC_API_KEY for Claude models
          • GEMINI_API_KEY for Gemini models (legacy GOOGLE_API_KEY also accepted)
          • MISTRAL_API_KEY for Mistral models
          • GROQ_API_KEY for Groq models
          • X_AI_API_KEY, XAI_API_KEY, or GROK_API_KEY for Grok models
          • Ollama requires local installation (no API key needed)

        For detailed documentation, visit: https://github.com/steipete/tachikoma
        """)
        // swiftformat:enable indent trailingSpace
    }

    static func showConfiguration(config: CLIConfig) {
        print("🔧 Current Configuration:")

        // Model information
        if let modelString = config.modelString {
            do {
                let model = try ModelSelector.parseModel(modelString)
                let caps = ModelSelector.getCapabilities(for: model)
                print("📱 Model: \(caps.description)")
                print("🏢 Provider: \(model.providerName)")
                print("🆔 Model ID: \(model.modelId)")

                // Show capabilities
                print("✨ Capabilities:")
                print("   • Vision: \(model.supportsVision ? "✅" : "❌")")
                print("   • Tools: \(model.supportsTools ? "✅" : "❌")")
                print("   • Streaming: \(model.supportsStreaming ? "✅" : "❌")")

                if case let .openai(openaiModel) = model {
                    let mode = config.apiMode ?? OpenAIAPIMode.defaultMode(for: openaiModel)
                    print("🌐 API Mode: \(mode.displayName)")
                }
            } catch {
                print("📱 Model: \(modelString) (❌ Invalid)")
            }
        } else {
            print("📱 Model: gpt-5 (default)")
            print("🏢 Provider: OpenAI")
        }

        // API Key status
        print("\n🔐 API Keys:")
        self.checkAPIKeyStatus(provider: "OpenAI", envVars: ["OPENAI_API_KEY"])
        self.checkAPIKeyStatus(provider: "Anthropic", envVars: ["ANTHROPIC_API_KEY"])
        self.checkAPIKeyStatus(provider: "Google", envVars: ["GEMINI_API_KEY", "GOOGLE_API_KEY"])
        self.checkAPIKeyStatus(provider: "Mistral", envVars: ["MISTRAL_API_KEY"])
        self.checkAPIKeyStatus(provider: "Groq", envVars: ["GROQ_API_KEY"])
        self.checkAPIKeyStatus(provider: "Grok", envVars: ["X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"])

        // Ollama status
        print("   • Ollama: Local (no API key required)")

        print("\n💫 Options:")
        print("   • Streaming: \(config.stream ? "enabled" : "disabled")")
    }

    static func checkAPIKeyStatus(provider: String, envVars: [String]) {
        let config = TachikomaConfiguration.current
        let prov = Provider.from(identifier: provider.lowercased())

        if config.hasAPIKey(for: prov) {
            print("   • \(provider): Configured")
        } else if
            envVars.contains(where: { ProcessInfo.processInfo.environment[$0]?.isEmpty == false })
        {
            print("   • \(provider): Configured")
        } else {
            print("   • \(provider): Not set")
        }
    }

    // MARK: - API Key Validation

    static func validateAPIKey(for model: LanguageModel) throws {
        let provider = self.getProvider(for: model)
        let config = TachikomaConfiguration.current

        // Check if API key is available (from config or environment)
        if !config.hasAPIKey(for: provider), provider.requiresAPIKey {
            let envVar = provider.environmentVariable.isEmpty ? "API key" : provider.environmentVariable
            if provider == .grok {
                // Special case for Grok with alternative variables
                throw CLIError.missingAPIKey("X_AI_API_KEY, XAI_API_KEY, or GROK_API_KEY")
            } else {
                throw CLIError.missingAPIKey(envVar)
            }
        }

        // Check for unsupported providers
        switch model {
        case .openRouter, .together, .replicate:
            throw CLIError.unsupportedProvider("Third-party aggregators not yet implemented in CLI")
        case .openaiCompatible, .anthropicCompatible, .custom:
            throw CLIError.unsupportedProvider("Custom providers not yet implemented in CLI")
        case .azureOpenAI:
            break
        default:
            break
        }
    }

    static func getProvider(for model: LanguageModel) -> Provider {
        switch model {
        case .openai: .openai
        case .anthropic: .anthropic
        case .google: .google
        case .minimax: .minimax
        case .minimaxCN: .minimaxCN
        case .kimi: .kimi
        case .mistral: .mistral
        case .groq: .groq
        case .grok: .grok
        case .ollama: .ollama
        case .lmstudio: .lmstudio
        case .azureOpenAI: .azureOpenAI
        case .openRouter, .together, .replicate,
             .openaiCompatible, .anthropicCompatible, .custom:
            .custom(model.providerName)
        }
    }

    static func showAPIKeyInstructions(for model: LanguageModel) {
        print("\n💡 Setup Instructions:")

        switch model {
        case .openai:
            print("Set your OpenAI API key:")
            print("export OPENAI_API_KEY='sk-your-key-here'")
            print("Get your key at: https://platform.openai.com/api-keys")
        case .anthropic:
            print("Set your Anthropic API key:")
            print("export ANTHROPIC_API_KEY='sk-ant-your-key-here'")
            print("Get your key at: https://console.anthropic.com/")
        case .google:
            print("Set your Gemini API key:")
            print("export GEMINI_API_KEY='gk-your-key-here'")
            print("# Legacy names still supported:")
            print("export GOOGLE_API_KEY='gk-your-key-here'")
            print("Get your key at: https://aistudio.google.com/apikey")
        case .minimax:
            print("Set your MiniMax API key:")
            print("export MINIMAX_API_KEY='your-key-here'")
        case .minimaxCN:
            print("Set your MiniMax China API key:")
            print("export MINIMAX_CN_API_KEY='your-key-here'")
            print("# or reuse the global MiniMax key name:")
            print("export MINIMAX_API_KEY='your-key-here'")
        case .kimi:
            print("Set your Moonshot AI API key:")
            print("export MOONSHOT_API_KEY='your-key-here'")
            print("Setup guide: https://platform.kimi.ai/docs/guide/start-using-kimi-api")
        case .mistral:
            print("Set your Mistral API key:")
            print("export MISTRAL_API_KEY='your-key-here'")
            print("Get your key at: https://console.mistral.ai/")
        case .groq:
            print("Set your Groq API key:")
            print("export GROQ_API_KEY='gsk_your-key-here'")
            print("Get your key at: https://console.groq.com/keys")
        case .grok:
            print("Set your xAI API key:")
            print("export X_AI_API_KEY='xai-your-key-here'")
            print("# or alternatively:")
            print("export XAI_API_KEY='xai-your-key-here'")
            print("export GROK_API_KEY='xai-your-key-here'")
            print("Get your key at: https://console.x.ai/")
        case .ollama:
            print("Install Ollama locally:")
            print("brew install ollama")
            print("ollama serve")
            print("ollama pull llama3.3")
        case .azureOpenAI:
            print("Set your Azure OpenAI credentials:")
            print("export AZURE_OPENAI_API_KEY='your-key-here'  # or AZURE_OPENAI_BEARER_TOKEN for Entra ID")
            print(
                "export AZURE_OPENAI_RESOURCE='my-aoai'       # or AZURE_OPENAI_ENDPOINT='https://my-aoai.openai.azure.com'",
            )
            print("export AZURE_OPENAI_API_VERSION='2025-04-01-preview'")
        default:
            print("This provider requires additional setup.")
        }
    }

    // MARK: - Request Execution

    static func showRequestConfig(model: LanguageModel, config: CLIConfig, query: String) {
        let provider = self.getProvider(for: model)
        let credentialStatus = provider.requiresAPIKey ? "Configured" : "Not required"
        print("🔐 API Key: \(credentialStatus)")
        print("🤖 Model: \(model.modelId)")
        print("🏢 Provider: \(model.providerName)")

        if case let .openai(openaiModel) = model {
            let apiMode = config.apiMode ?? OpenAIAPIMode.defaultMode(for: openaiModel)
            print("🌐 API: \(apiMode.displayName)")
        }

        print("📝 Query: \(query)")
        print("---")
    }

    static func executeRequest(model: LanguageModel, config: CLIConfig, query: String) async throws {
        print("🚀 Sending query...")

        let startTime = Date()

        // Use the global generate function with proper model selection
        let result: GenerateTextResult
        var reasoningText: String?

        // Check if we should show thinking for this model
        let actualApiMode: OpenAIAPIMode? = if case let .openai(openaiModel) = model {
            config.apiMode ?? OpenAIAPIMode.defaultMode(for: openaiModel)
        } else {
            nil
        }

        let supportsThinking = self.isReasoningModel(model) && actualApiMode != .chat
        if config.showThinking, !supportsThinking {
            print("⚠️  Note: --thinking only works with GPT-5 models via Responses API")
        }

        if case let .openai(openaiModel) = model, actualApiMode == .chat {
            // Force Chat Completions API (no reasoning available)
            let provider = try OpenAIProvider(model: openaiModel, configuration: TachikomaConfiguration.current)
            let request = ProviderRequest(
                messages: [.user(query)],
                tools: nil,
                settings: GenerationSettings(maxTokens: 2000),
            )
            let providerResponse = try await provider.generateText(request: request)
            result = GenerateTextResult(
                text: providerResponse.text,
                usage: providerResponse.usage,
                finishReason: providerResponse.finishReason,
                steps: [],
                messages: [.user(query)],
            )
        } else if
            case let .openai(openaiModel) = model,
            actualApiMode == .responses, config.showThinking
        {
            // Use Responses API with reasoning extraction for thinking models
            let (response, reasoning) = try await executeResponsesAPIWithReasoning(
                model: openaiModel,
                query: query,
            )
            reasoningText = reasoning
            result = GenerateTextResult(
                text: response.text,
                usage: response.usage,
                finishReason: response.finishReason,
                steps: [],
                messages: [.user(query)],
            )
        } else if case let .openai(openaiModel) = model, actualApiMode == .responses {
            // Force Responses API (without reasoning extraction)
            let provider = try OpenAIResponsesProvider(
                model: openaiModel,
                configuration: TachikomaConfiguration.current,
            )
            let request = ProviderRequest(
                messages: [.user(query)],
                tools: nil,
                settings: GenerationSettings(maxTokens: 2000),
            )
            let providerResponse = try await provider.generateText(request: request)
            result = GenerateTextResult(
                text: providerResponse.text,
                usage: providerResponse.usage,
                finishReason: providerResponse.finishReason,
                steps: [],
                messages: [.user(query)],
            )
        } else {
            // Use global generate function for all other providers
            result = try await generateText(
                model: model,
                messages: [.user(query)],
                settings: GenerationSettings(maxTokens: 2000),
            )
        }

        let duration = Date().timeIntervalSince(startTime)

        print("✅ Response received in \(String(format: "%.2f", duration))s")

        // Display thinking/reasoning if available (before the response)
        if config.showThinking {
            if let reasoning = reasoningText, !reasoning.isEmpty {
                print("\n🧠 Reasoning Summary:")
                print("-------------------")
                print(reasoning)
                print("-------------------")
            } else if supportsThinking {
                // Show that reasoning occurred but isn't exposed
                if result.usage != nil {
                    print("\n⚠️  Note: Model used internal reasoning but doesn't expose the thinking process.")
                    print("   The model performed reasoning internally as part of generating the response.")
                }
            }
        }

        print("\n💬 Response:")
        print(result.text)

        // Show usage information in a single line
        if let usage = result.usage {
            var usageStr = "\n📊 Usage: \(usage.inputTokens) tokens in, \(usage.outputTokens) tokens out, \(usage.totalTokens) tokens total"

            // Add cost estimate if available
            if let cost = estimateCost(for: model, usage: usage) {
                usageStr += " (~$\(String(format: "%.4f", cost)))"
            }

            // Add finish reason
            if let finishReason = result.finishReason {
                usageStr += " [\(finishReason.rawValue)]"
            }

            print(usageStr)
        } else if let finishReason = result.finishReason {
            print("\n🎯 Finished: \(finishReason.rawValue)")
        }
    }

    // MARK: - Reasoning Support

    static func isReasoningModel(_ model: LanguageModel) -> Bool {
        guard case let .openai(openaiModel) = model else { return false }
        switch openaiModel {
        case .gpt55,
             .gpt54,
             .gpt54Mini,
             .gpt54Nano,
             .gpt5Pro,
             .gpt5Mini:
            return true
        case .gpt5,
             .gpt5Nano:
            return true
        default:
            return false
        }
    }

    static func executeResponsesAPIWithReasoning(
        model: LanguageModel.OpenAI,
        query: String,
    ) async throws
        -> (response: ProviderResponse, reasoning: String?)
    {
        let provider = try OpenAIResponsesProvider(model: model, configuration: .current)
        let result = try await provider.generateTextWithSummary(request: ProviderRequest(
            messages: [.user(query)],
            tools: nil,
            settings: GenerationSettings(
                providerOptions: ProviderOptions(openai: OpenAIOptions(reasoningEffort: .high)),
            ),
        ))
        return (result.response, result.summary)
    }

    static func executeStreamingRequest(model: LanguageModel, config _: CLIConfig, query: String) async throws {
        print("🚀 Streaming response...")
        print("\n💬 Response:")

        // Use streaming generate function
        let stream = try await streamText(
            model: model,
            messages: [.user(query)],
            settings: GenerationSettings(maxTokens: 2000),
        )

        var fullText = ""
        var usage: Usage?

        for try await delta in stream.stream {
            switch delta.type {
            case .textDelta:
                if let content = delta.content {
                    print(content, terminator: "")
                    fflush(nil)
                    fullText += content
                }
            case .done:
                if let deltaUsage = delta.usage {
                    usage = deltaUsage
                }
            case .toolCall, .toolResult, .reasoning:
                // Handle tool calls if needed in the future
                continue
            }

            // Update usage if available
            if let deltaUsage = delta.usage {
                usage = deltaUsage
            }
        }

        print("\n")

        // Show final usage information in a single line
        if let usage {
            var usageStr = "📊 Usage: \(usage.inputTokens) tokens in, \(usage.outputTokens) tokens out, \(usage.totalTokens) tokens total"

            // Add cost estimate if available
            if let cost = estimateCost(for: model, usage: usage) {
                usageStr += " (~$\(String(format: "%.4f", cost)))"
            }

            print(usageStr)
        }
    }

    // MARK: - Utility Functions

    static func estimateCost(for model: LanguageModel, usage: Usage) -> Double? {
        // Rough cost estimates (as of 2025, prices may vary)
        let inputCostPer1k: Double
        let outputCostPer1k: Double

        switch model {
        case let .openai(openaiModel):
            switch openaiModel {
            case .gpt55, .gpt54, .gpt5:
                inputCostPer1k = 0.005
                outputCostPer1k = 0.020
            case .gpt54Mini, .gpt54Nano, .gpt5Mini, .gpt5Nano:
                return nil // Pricing TBD
            default: return nil
            }
        case let .anthropic(anthropicModel):
            switch anthropicModel {
            case .opus47, .opus45, .opus4:
                inputCostPer1k = 0.015
                outputCostPer1k = 0.075
            case .sonnet46, .sonnet45:
                inputCostPer1k = 0.003
                outputCostPer1k = 0.015
            case .haiku45:
                inputCostPer1k = 0.0008
                outputCostPer1k = 0.004
            default: return nil
            }
        case .minimax:
            inputCostPer1k = 0.0003
            outputCostPer1k = 0.0012
        default:
            return nil
        }

        let inputCost = (Double(usage.inputTokens) / 1000.0) * inputCostPer1k
        let outputCost = (Double(usage.outputTokens) / 1000.0) * outputCostPer1k
        return inputCost + outputCost
    }

    static func showErrorHelp(for error: TachikomaError, model: LanguageModel) {
        print("\n💡 Troubleshooting:")

        switch error {
        case .authenticationFailed:
            print("Authentication failed. Check your API key:")
            self.showAPIKeyInstructions(for: model)
        case .rateLimited:
            print("Rate limit exceeded. Try:")
            print("• Wait a moment and retry")
            print("• Use a different model")
            print("• Check your usage limits")
        case .modelNotFound:
            print("Model not found. Try:")
            print("• Check model name spelling")
            print("• Use --help to see available models")
            print("• Ensure you have access to this model")
        case .networkError:
            print("Network error. Try:")
            print("• Check your internet connection")
            print("• Retry the request")
            print("• Check if the service is down")
        default:
            print("For more help, visit: https://github.com/steipete/tachikoma")
        }
    }
}

// MARK: - Error Types

enum CLIError: Error, LocalizedError {
    case missingAPIKey(String)
    case unsupportedProvider(String)
    case invalidModel(String)

    var errorDescription: String? {
        switch self {
        case let .missingAPIKey(key):
            "Missing API key: \(key) environment variable not set"
        case let .unsupportedProvider(provider):
            "Unsupported provider: \(provider)"
        case let .invalidModel(model):
            "Invalid model: \(model)"
        }
    }
}
