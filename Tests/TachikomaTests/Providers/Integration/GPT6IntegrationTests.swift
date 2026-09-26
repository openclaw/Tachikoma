#if LIVE_PROVIDER_TESTS
import Foundation
import Testing
@testable import Tachikoma

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil))
struct GPT6IntegrationTests {
    private func configuration() throws -> TachikomaConfiguration {
        let key = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        #expect(!key.isEmpty)
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey(key, for: .openai)
        return config
    }

    private var settings: GenerationSettings {
        .init(maxTokens: 4096, providerOptions: .init(openai: .init(verbosity: .low, reasoningEffort: .low)))
    }

    @Test(arguments: [LanguageModel.OpenAI.gpt6Astra, .gpt6Sol, .gpt6Luna])
    func vision(model: LanguageModel.OpenAI) async throws {
        let redPNG = [
            "iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAIAAABMXPacAAABWklEQVR4nO3OQQ0AMBAEofVv+iqDxzRBALvtg/wgzg/i/CDOD+L8",
            "IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8",
            "IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8",
            "IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8",
            "IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8IM4P4vwgzg/i/CDOD+L8",
            "IM4P4vwg7gEgaMOyrMtNTwAAAABJRU5ErkJggg==",
        ].joined()
        let result = try await generateText(
            model: .openai(model),
            messages: [
                .init(role: .user, content: [
                    .text("What color is this square? Reply with just the color name."),
                    .image(.init(data: redPNG, mimeType: "image/png")),
                ]),
            ],
            settings: self.settings,
            timeout: 120,
            configuration: self.configuration(),
        )
        #expect(result.text.lowercased().contains("red"))
        #expect(try #require(result.usage).outputTokens > 0)
    }

    @Test(arguments: [LanguageModel.OpenAI.gpt6Astra, .gpt6Sol, .gpt6Luna])
    func streaming(model: LanguageModel.OpenAI) async throws {
        let provider = try ProviderFactory.createProvider(for: .openai(model), configuration: self.configuration())
        let stream = try await provider.streamText(request: .init(
            messages: [.user("Reply with exactly: Tachikoma stream OK")], settings: self.settings,
        ))
        var text = ""
        var done = false
        for try await delta in stream {
            if delta.type == .textDelta {
                text += delta.content ?? ""
            }
            if delta.type == .done {
                done = true
            }
        }
        #expect(text.contains("Tachikoma stream OK"))
        #expect(done)
    }

    @Test(arguments: [LanguageModel.OpenAI.gpt6Astra, .gpt6Sol, .gpt6Luna])
    func `tool round trip`(model: LanguageModel.OpenAI) async throws {
        let tool = createTool(name: "lookup_code", description: "Look up the secret test code", parameters: []) { _ in
            AnyAgentToolValue(string: "TACHIKOMA-7391")
        }
        let result = try await generateText(
            model: .openai(model),
            messages: [
                .user("Call lookup_code to obtain the test code, then reply with that exact code. Do not guess."),
            ],
            tools: [tool], settings: self.settings, maxSteps: 3, timeout: 120,
            configuration: self.configuration(),
        )
        #expect(result.steps.contains { $0.toolCalls.contains { $0.name == "lookup_code" } })
        #expect(result.steps.contains { !$0.toolResults.isEmpty })
        #expect(result.text.contains("TACHIKOMA-7391"))
    }

    @Test(arguments: [LanguageModel.OpenAI.gpt6Sol, .gpt6Luna])
    func `no reasoning`(model: LanguageModel.OpenAI) async throws {
        let result = try await generateText(
            model: .openai(model), messages: [.user("Reply with exactly: Tachikoma OK")],
            settings: .init(
                maxTokens: 256,
                temperature: 0.2,
                topP: 0.9,
                providerOptions: .init(openai: .init(reasoningEffort: OpenAIOptions.ReasoningEffort.none)),
            ),
            timeout: 120, configuration: self.configuration(),
        )
        #expect(result.text.contains("Tachikoma OK"))
    }
}
#endif
