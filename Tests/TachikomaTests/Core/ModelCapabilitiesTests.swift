import Foundation
import Testing
@testable import Tachikoma

enum ModelCapabilitiesTests {
    struct CapabilityDetectionTests {
        @Test
        func `GPT-5 models exclude temperature and topP`() {
            let models: [LanguageModel] = [
                .openai(.gpt5ChatLatest),
                .openai(.gpt55),
                .openai(.gpt54),
                .openai(.gpt54Mini),
                .openai(.gpt54Nano),
                .openai(.gpt5),
                .openai(.gpt5Mini),
                .openai(.gpt5Nano),
            ]

            for model in models {
                let capabilities = ModelCapabilityRegistry.shared.capabilities(for: model)

                #expect(!capabilities.supportsTemperature)
                #expect(!capabilities.supportsTopP)
                #expect(capabilities.excludedParameters.contains("temperature"))
                #expect(capabilities.excludedParameters.contains("topP"))
                #expect(capabilities.supportedProviderOptions.supportsVerbosity)
                #expect(capabilities.supportedProviderOptions.supportsPreviousResponseId)
            }
        }

        @Test
        func `chat-latest does not advertise audio input`() {
            #expect(LanguageModel.openai(.chatLatest).supportsVision)
            #expect(LanguageModel.openai(.chatLatest).supportsTools)
            #expect(LanguageModel.openai(.chatLatest).supportsAudioInput == false)
        }

        @Test
        func `Gemini 3_5 Flash supports thinking config options`() {
            let capabilities = ModelCapabilityRegistry.shared.capabilities(for: .google(.gemini35Flash))
            #expect(capabilities.supportsTopK)
            #expect(capabilities.supportedProviderOptions.supportsThinkingConfig)
            #expect(capabilities.supportedProviderOptions.supportsSafetySettings)
        }

        @Test
        func `Custom OpenAI models support standard parameters`() {
            let models: [LanguageModel] = [
                .openai(.custom("custom-openai")),
            ]

            for model in models {
                let capabilities = ModelCapabilityRegistry.shared.capabilities(for: model)

                #expect(capabilities.supportsTemperature)
                #expect(capabilities.supportsTopP)
                #expect(capabilities.supportsMaxTokens)
                #expect(capabilities.supportsFrequencyPenalty)
                #expect(capabilities.supportsPresencePenalty)
            }
        }

        @Test
        func `Claude models support thinking`() {
            let models: [LanguageModel] = [
                .anthropic(.opus5),
                .anthropic(.fable5),
                .anthropic(.sonnet5),
                .anthropic(.opus47),
                .anthropic(.opus4),
                .anthropic(.sonnet46),
                .anthropic(.sonnet45),
                .anthropic(.haiku45),
            ]

            for model in models {
                let capabilities = ModelCapabilityRegistry.shared.capabilities(for: model)

                #expect(capabilities.supportedProviderOptions.supportsThinking)
                #expect(capabilities.supportedProviderOptions.supportsCacheControl)
            }
        }

        @Test
        func `Current adaptive Claude models reject sampling options`() {
            for model in [
                LanguageModel.anthropic(.opus5),
                LanguageModel.anthropic(.fable5),
                .anthropic(.sonnet5),
                .anthropic(.opus47),
                .anthropic(.opus48),
                .openRouter(modelId: "anthropic/claude-sonnet-5"),
            ] {
                let capabilities = ModelCapabilityRegistry.shared.capabilities(for: model)

                #expect(!capabilities.supportsTemperature)
                #expect(!capabilities.supportsTopP)
                #expect(!capabilities.supportsTopK)
                #expect(capabilities.excludedParameters.contains("temperature"))
                #expect(capabilities.excludedParameters.contains("topP"))
                #expect(capabilities.excludedParameters.contains("topK"))
                #expect(capabilities.supportedProviderOptions.supportsThinking)
                #expect(capabilities.supportedProviderOptions.supportsCacheControl)
            }
        }

        @Test
        func `Custom Anthropic models keep thinking options by default`() {
            let capabilities = ModelCapabilityRegistry.shared
                .capabilities(for: .anthropic(.custom("claude-opus-latest")))

            #expect(capabilities.supportedProviderOptions.supportsThinking)
            #expect(capabilities.supportedProviderOptions.supportsCacheControl)
        }

        @Test
        func `Google models support topK and thinking`() {
            let models: [LanguageModel] = [
                .google(.gemini35Flash),
                .google(.gemini31ProPreview),
                .google(.gemini31FlashLite),
                .google(.gemini25Pro),
                .google(.gemini25Flash),
                .google(.gemini25FlashLite),
            ]

            for model in models {
                let capabilities = ModelCapabilityRegistry.shared.capabilities(for: model)

                #expect(capabilities.supportsTopK)
                #expect(capabilities.supportedProviderOptions.supportsThinkingConfig)
                #expect(capabilities.supportedProviderOptions.supportsSafetySettings)
            }
        }

        @Test
        func `Mistral models support safe mode`() {
            let models: [LanguageModel] = [
                .mistral(.largeLatest),
                .mistral(.medium35),
                .mistral(.codestralLatest),
            ]

            for model in models {
                let capabilities = ModelCapabilityRegistry.shared.capabilities(for: model)

                #expect(capabilities.supportedProviderOptions.supportsSafeMode)
            }
        }

        @Test
        func `Groq models support speed level`() {
            let models: [LanguageModel] = [
                .groq(.llama3370b),
                .groq(.llama4Maverick),
            ]

            for model in models {
                let capabilities = ModelCapabilityRegistry.shared.capabilities(for: model)

                #expect(capabilities.supportedProviderOptions.supportsSpeedLevel)
            }
        }

        @Test
        func `Grok models support fun mode`() {
            let models: [LanguageModel] = [
                .grok(.grok43),
                .grok(.grok420Reasoning),
            ]

            for model in models {
                let capabilities = ModelCapabilityRegistry.shared.capabilities(for: model)

                #expect(capabilities.supportedProviderOptions.supportsFunMode)
                #expect(capabilities.supportedProviderOptions.supportsCurrentEvents)
            }
        }
    }

    struct SettingsValidationTests {
        @Test
        func `Validate settings for GPT-5.5`() {
            let settings = GenerationSettings(
                maxTokens: 1000,
                temperature: 0.7,
                topP: 0.9,
                frequencyPenalty: 0.5,
                presencePenalty: 0.3,
                providerOptions: .init(
                    openai: .init(
                        verbosity: .high,
                        previousResponseId: "test-123",
                    ),
                ),
            )

            let validated = settings.validated(for: .openai(.gpt55))

            #expect(validated.maxTokens == 1000)
            #expect(validated.temperature == nil) // Excluded
            #expect(validated.topP == nil) // Excluded
            #expect(validated.frequencyPenalty == nil) // Excluded
            #expect(validated.presencePenalty == nil) // Excluded
            #expect(validated.providerOptions.openai?.verbosity == .high) // Kept
            #expect(validated.providerOptions.openai?.previousResponseId == "test-123") // Kept
        }

        @Test
        func `Validate settings preserves stream buffering mode`() {
            let settings = GenerationSettings(
                temperature: 0.7,
                streamBuffering: .untilTerminal,
            )

            let validated = settings.validated(for: .openai(.gpt55))

            #expect(validated.temperature == nil)
            #expect(validated.streamBuffering == .untilTerminal)
        }

        @Test
        func `Validate settings for GPT-5 preserves reasoning and strips sampling options`() {
            let settings = GenerationSettings(
                temperature: 0.5,
                topP: 0.8,
                providerOptions: .init(
                    openai: .init(
                        verbosity: .medium,
                        reasoningEffort: .high,
                    ),
                ),
            )

            let validated = settings.validated(for: LanguageModel.openai(.gpt55))

            #expect(validated.temperature == nil) // Excluded
            #expect(validated.topP == nil) // Excluded
            #expect(validated.providerOptions.openai?.reasoningEffort == .high)
            #expect(validated.providerOptions.openai?.verbosity == .medium) // Kept
        }

        @Test
        func `Validate settings preserves GPT-5_6 reasoning effort`() {
            for model in [
                LanguageModel.OpenAI.gpt56Sol,
                .gpt56Terra,
                .gpt56Luna,
            ] {
                let settings = GenerationSettings(
                    providerOptions: .init(openai: .init(reasoningEffort: .max)),
                )

                let validated = settings.validated(for: .openai(model))

                #expect(validated.providerOptions.openai?.reasoningEffort == .max)
            }
        }

        @Test
        func `Validate settings for custom OpenAI model`() {
            let settings = GenerationSettings(
                maxTokens: 2000,
                temperature: 0.8,
                topP: 0.95,
                frequencyPenalty: 0.2,
                presencePenalty: 0.1,
                providerOptions: .init(
                    openai: .init(
                        parallelToolCalls: true,
                        responseFormat: .json,
                        logprobs: true,
                        topLogprobs: 3,
                    ),
                ),
            )

            let validated = settings.validated(for: .openai(.custom("custom-openai")))

            #expect(validated.maxTokens == 2000)
            #expect(validated.temperature == 0.8)
            #expect(validated.topP == 0.95)
            #expect(validated.frequencyPenalty == 0.2)
            #expect(validated.presencePenalty == 0.1)
        }

        @Test
        func `Validate Anthropic options`() {
            let settings = GenerationSettings(
                temperature: 0.7,
                providerOptions: .init(
                    openai: .init( // Should be ignored for Anthropic
                        verbosity: .high,
                    ),
                    anthropic: .init(
                        thinking: .enabled(budgetTokens: 3000),
                        cacheControl: .persistent,
                    ),
                ),
            )

            let validated = settings.validated(for: LanguageModel.anthropic(.opus4))

            #expect(validated.temperature == 0.7)
            #expect(validated.providerOptions.anthropic?.thinking != nil)
            #expect(validated.providerOptions.anthropic?.cacheControl == .persistent)
            // OpenAI options remain unfiltered (they won't be used by Anthropic provider)
            #expect(validated.providerOptions.openai?.verbosity == .high)
        }

        @Test
        func `Validate Anthropic options keeps adaptive thinking for Opus 4_8`() {
            let settings = GenerationSettings(
                temperature: 0.7,
                topP: 0.9,
                topK: 40,
                providerOptions: .init(
                    anthropic: .init(
                        thinking: .enabled(budgetTokens: 3000),
                        cacheControl: .persistent,
                    ),
                ),
            )

            let validated = settings.validated(for: LanguageModel.anthropic(.opus48))

            #expect(validated.temperature == nil)
            #expect(validated.topP == nil)
            #expect(validated.topK == nil)
            #expect(validated.providerOptions.anthropic?.thinking != nil)
            #expect(validated.providerOptions.anthropic?.cacheControl == .persistent)
        }

        @Test
        func `Validate Anthropic-compatible Fable strips unsupported sampling`() {
            let settings = GenerationSettings(
                temperature: 0.7,
                topP: 0.9,
                topK: 40,
                providerOptions: .init(
                    anthropic: .init(thinking: .adaptive),
                ),
            )

            let validated = settings.validated(for: LanguageModel.anthropicCompatible(
                modelId: "claude-fable-5",
                baseURL: "https://example.test",
            ))

            #expect(validated.temperature == nil)
            #expect(validated.topP == nil)
            #expect(validated.topK == nil)
            #expect(validated.providerOptions.anthropic?.thinking != nil)
        }

        @Test
        func `Validate direct custom Fable strips unsupported sampling`() {
            let settings = GenerationSettings(
                temperature: 0.7,
                topP: 0.9,
                topK: 40,
                providerOptions: .init(
                    anthropic: .init(thinking: .adaptive),
                ),
            )

            let validated = settings.validated(
                for: LanguageModel.anthropic(.custom("anthropic.claude-fable-5")),
            )

            #expect(validated.temperature == nil)
            #expect(validated.topP == nil)
            #expect(validated.topK == nil)
            #expect(validated.providerOptions.anthropic?.thinking != nil)
        }
    }

    struct CustomModelTests {
        @Test
        func `Register custom model capabilities`() {
            let customCaps = ModelParameterCapabilities(
                supportsTemperature: false,
                supportsTopP: false,
                supportsMaxTokens: true,
                forcedTemperature: 0.8,
                excludedParameters: ["temperature", "topP"],
            )

            let model = LanguageModel.custom(
                provider: TestModelProvider(modelId: "test-model"),
            )
            ModelCapabilityRegistry.shared.register(customCaps, for: model)

            let retrieved = ModelCapabilityRegistry.shared.capabilities(for: model)

            #expect(!retrieved.supportsTemperature)
            #expect(retrieved.forcedTemperature == 0.8)
            #expect(retrieved.supportsMaxTokens)
            #expect(retrieved.excludedParameters.contains("temperature"))
        }

        @Test
        func `OpenAI-compatible model registration`() {
            let capabilities = ModelParameterCapabilities(
                supportsTemperature: true,
                supportsTopK: true,
                temperatureRange: 0.0...1.5,
            )

            ModelCapabilityRegistry.shared.registerOpenAICompatible(
                endpoint: "https://test.example.com",
                capabilities: capabilities,
            )

            // The capability is registered but we need the actual model to retrieve it
            let model = LanguageModel.openaiCompatible(
                modelId: "test-model",
                baseURL: "https://test.example.com",
            )

            // Default capabilities will be returned since we register by endpoint
            let retrieved = ModelCapabilityRegistry.shared.capabilities(for: model)
            #expect(retrieved.supportsTemperature) // Default OpenAI capabilities
        }
    }

    struct ThreadSafetyTests {
        @Test
        func `Concurrent capability access`() async {
            let models: [LanguageModel] = [
                .openai(.gpt54),
                .openai(.gpt55),
                .anthropic(.opus4),
                .google(.gemini25Flash),
            ]

            await withTaskGroup(of: Void.self) { group in
                // Multiple readers
                for _ in 0..<100 {
                    group.addTask {
                        let model = models.randomElement()!
                        _ = ModelCapabilityRegistry.shared.capabilities(for: model)
                    }
                }

                // Multiple writers
                for i in 0..<10 {
                    group.addTask {
                        let caps = ModelParameterCapabilities(
                            supportsTemperature: Bool.random(),
                        )
                        let model = LanguageModel.custom(
                            provider: TestModelProvider(modelId: "concurrent-\(i)"),
                        )
                        ModelCapabilityRegistry.shared.register(caps, for: model)
                    }
                }
            }

            // Should complete without crashes
            #expect(Bool(true))
        }
    }
}

/// Helper for testing custom models
private struct TestModelProvider: ModelProvider {
    let modelId: String
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities(
        supportsVision: false,
        supportsTools: false,
        supportsStreaming: true,
        contextLength: 4096,
        maxOutputTokens: 4096,
    )

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        throw TachikomaError.unsupportedOperation("Test provider")
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        throw TachikomaError.unsupportedOperation("Test provider")
    }
}
