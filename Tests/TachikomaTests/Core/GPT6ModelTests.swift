import Testing
@testable import Tachikoma

struct GPT6ModelTests {
    @Test(arguments: [LanguageModel.OpenAI.gpt6Astra, .gpt6Sol, .gpt6Luna])
    func `catalog and parsing`(model: LanguageModel.OpenAI) throws {
        let expected = LanguageModel.openai(model)
        for name in [
            model.modelId,
            model.modelId.replacingOccurrences(of: "-", with: ""),
            model.modelId.replacingOccurrences(of: "-", with: "_"),
        ] {
            #expect(LanguageModel.parse(from: name) == expected)
            #expect(LanguageModel.parse(from: "openai/\(name)") == expected)
            #expect(try ModelSelector.parseModel(name) == expected)
            #expect(ProviderParser.determineDefaultModel(
                from: "openai/\(name)", hasOpenAI: true, hasAnthropic: false,
            ) == expected)
        }
        #expect(LanguageModel.OpenAI.allCases.contains(model))
        #expect(model.contextLength == 1_050_000)
        #expect(model.supportsVision)
        #expect(model.supportsTools)
        #expect(!model.supportsAudioInput)

        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("test-openai", for: .openai)
        for selection in [expected, .openai(.custom(model.modelId))] {
            let provider = try ProviderFactory.createProvider(for: selection, configuration: config)
            #expect(provider is OpenAIResponsesProvider)
            #expect(provider.modelId == model.modelId)
            #expect(provider.capabilities.maxOutputTokens == 128_000)
            #expect(provider.capabilities.contextLength == 1_050_000)
        }
    }

    @Test
    func `aliases do not capture unknown models`() throws {
        #expect(LanguageModel.parse(from: "gpt-6") == .openai(.gpt6Astra))
        #expect(try ModelSelector.parseModel("gpt6") == .openai(.gpt6Astra))
        for name in ["gpt-60", "gpt-6-terra", "my-gpt6-distill", "gpt-6-astra-preview"] {
            #expect(LanguageModel.parse(from: name) == nil)
        }
    }

    @Test(arguments: [
        (LanguageModel.OpenAI.gpt6Astra, 10.0, 50.0),
        (.gpt6Sol, 2.0, 10.0),
        (.gpt6Luna, 0.1, 0.5),
    ])
    func `standard pricing`(model: LanguageModel.OpenAI, input: Double, output: Double) {
        let calculator = ModelCostCalculator()
        for selection in [LanguageModel.openai(model), .openai(.custom(model.modelId))] {
            let short = calculator.calculateCost(for: selection, usage: Usage(inputTokens: 272_000, outputTokens: 1000))
            #expect(abs(short.input - 0.272 * input) < 0.000001)
            #expect(abs(short.output - 0.001 * output) < 0.000001)
            let long = calculator.calculateCost(for: selection, usage: Usage(inputTokens: 272_001, outputTokens: 1000))
            #expect(abs(long.input - 0.272001 * input * 2) < 0.000001)
            #expect(abs(long.output - 0.001 * output * 1.5) < 0.000001)
        }
    }
}
