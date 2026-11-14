import Foundation
import Testing
@testable import Tachikoma
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnthropicInterleavedDefaultsTests {
    @Test
    func `Merged beta header includes required interleaved flags`() {
        let header = AnthropicProvider.mergedBetaHeader(existing: nil)
        #expect(header.contains("interleaved-thinking-2025-05-14"))
        #expect(header.contains("fine-grained-tool-streaming-2025-05-14"))

        let withExisting = AnthropicProvider.mergedBetaHeader(
            existing: "oauth-2025-04-20,interleaved-thinking-2025-05-14,oauth-2025-04-20",
        )
        let parts = withExisting
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        #expect(Set(parts).count == parts.count)
        #expect(parts.contains("oauth-2025-04-20"))
        #expect(parts.contains("interleaved-thinking-2025-05-14"))
        #expect(parts.contains("fine-grained-tool-streaming-2025-05-14"))
    }

    @Test
    func `Endpoint identity rejects query and userinfo credentials`() {
        let tenantA = ReasoningEndpointIdentity.canonical("https://gateway.test/v1?tenant=a")
        let tenantB = ReasoningEndpointIdentity.canonical("https://gateway.test/v1?tenant=b")

        #expect(tenantA == nil)
        #expect(tenantB == nil)
        #expect(ReasoningEndpointIdentity.canonical("https://gateway.test/v1/") != nil)
        let credentialA = ReasoningEndpointIdentity.canonical(
            "https://user:secret@gateway.test/v1?tenant=a#frag",
        )
        let credentialB = ReasoningEndpointIdentity.canonical(
            "https://user:rotated@gateway.test/v1?tenant=a#other",
        )
        #expect(credentialA == nil)
        #expect(credentialB == nil)
    }

    @Test
    func `Provider request includes beta header and thinking payload`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus45, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: true)
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta")?
            .contains("interleaved-thinking-2025-05-14") == true)
        #expect(
            urlRequest.value(forHTTPHeaderField: "anthropic-beta")?
                .contains("fine-grained-tool-streaming-2025-05-14") ==
                true,
        )

        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-4-5")
        #expect(json["stream"] as? Bool == true)

        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 12000)
    }

    @Test
    func `Provider request preserves structured tool failure`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus45, configuration: config)
        let call = AgentToolCall(id: "call-failure", name: "background_action", arguments: [:])
        let failure = AgentToolExecutionFailure(
            message: "permission denied",
            content: [AnyAgentToolValue(string: "permission denied")],
            structuredValue: AnyAgentToolValue(object: ["code": AnyAgentToolValue(int: 403)]),
            metadata: AnyAgentToolValue(object: ["retrySafe": AnyAgentToolValue(bool: false)]),
        )
        let request = ProviderRequest(messages: [
            .user("run"),
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(
                role: .tool,
                content: [.toolResult(.error(toolCallId: call.id, failure: failure))],
            ),
        ])

        let body = try #require(provider.makeURLRequest(for: request, stream: false).httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let toolMessage = try #require(messages.last)
        let content = try #require(toolMessage["content"] as? [[String: Any]])
        let toolResult = try #require(content.first)
        let resultContent = try #require(toolResult["content"] as? String)
        let resultJSON = try #require(
            try JSONSerialization.jsonObject(with: Data(resultContent.utf8)) as? [String: Any],
        )

        #expect(toolResult["type"] as? String == "tool_result")
        #expect(toolResult["tool_use_id"] as? String == call.id)
        #expect(toolResult["is_error"] as? Bool == true)
        #expect(resultJSON["error"] as? String == "permission denied")
        #expect((resultJSON["structuredValue"] as? [String: Any])?["code"] as? Int == 403)
        #expect((resultJSON["metadata"] as? [String: Any])?["retrySafe"] as? Bool == false)
    }

    @Test
    func `Opus 4_7 request strips unsupported sampling and uses adaptive thinking`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus47, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            temperature: 0.7,
            topP: 0.9,
            topK: 40,
            providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "claude-opus-4-7")
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["top_k"] == nil)
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["budget_tokens"] == nil)
        let outputConfig = try #require(json["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "medium")
        #expect(json["max_tokens"] as? Int == 64)
    }

    @Test
    func `Opus 4_8 request strips unsupported sampling and uses adaptive thinking`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus48, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            temperature: 0.7,
            topP: 0.9,
            topK: 40,
            reasoningEffort: .low,
            providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "claude-opus-4-8")
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["top_k"] == nil)
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["budget_tokens"] == nil)
        let outputConfig = try #require(json["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "low")
        #expect(json["max_tokens"] as? Int == 64)
    }

    @Test
    func `Opus 5 request strips unsupported sampling and uses adaptive thinking`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus5, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 128_000,
            temperature: 0.7,
            topP: 0.9,
            topK: 40,
            reasoningEffort: .max,
            providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "claude-opus-5")
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["top_k"] == nil)
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["budget_tokens"] == nil)
        let outputConfig = try #require(json["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "max")
        #expect(json["max_tokens"] as? Int == 128_000)
    }

    @Test
    func `Custom Opus 5 model id uses adaptive thinking and extended effort`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .custom("claude-opus-5"), configuration: config)
        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: GenerationSettings(
                maxTokens: 64,
                reasoningEffort: .max,
                providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
            ),
        )

        let body = try #require(provider.makeURLRequest(for: request, stream: false).httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try #require(json["thinking"] as? [String: Any])
        let outputConfig = try #require(json["output_config"] as? [String: Any])

        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["budget_tokens"] == nil)
        #expect(outputConfig["effort"] as? String == "max")
    }

    @Test
    func `Fable 5 request omits thinking config and uses effort output config`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .fable5, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 128_000,
            temperature: 0.7,
            topP: 0.9,
            topK: 40,
            reasoningEffort: .high,
            providerOptions: .init(anthropic: .init(thinking: .adaptive)),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "claude-fable-5")
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["top_k"] == nil)
        #expect(json["thinking"] == nil)
        let outputConfig = try #require(json["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "high")
        #expect(json["max_tokens"] as? Int == 128_000)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test
    func `Fable 5 request uses model-aware default output budget`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .fable5, configuration: config)

        let request = ProviderRequest(messages: [.user("hi")])
        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["max_tokens"] as? Int == 16384)
        #expect(urlRequest.timeoutInterval == 1800)
    }

    @Test
    func `Fable 5 long output requests extend non-streaming timeout`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .fable5, configuration: config)

        let urlRequest = try provider.makeURLRequest(
            for: ProviderRequest(
                messages: [.user("long")],
                settings: GenerationSettings(maxTokens: 128_000),
            ),
            stream: false,
        )

        #expect(urlRequest.timeoutInterval == 1800)
    }

    @Test
    func `Opus long output requests extend non-streaming timeout`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])

        for model in [LanguageModel.Anthropic.opus5, .opus47, .opus48] {
            let provider = try AnthropicProvider(model: model, configuration: config)
            let urlRequest = try provider.makeURLRequest(
                for: ProviderRequest(
                    messages: [.user("long")],
                    settings: GenerationSettings(maxTokens: 128_000),
                ),
                stream: false,
            )

            #expect(urlRequest.timeoutInterval == 1800)
        }
    }

    @Test
    func `Custom Fable model id uses Fable request defaults`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .custom("claude-fable-5"), configuration: config)

        let request = ProviderRequest(messages: [.user("hi")])
        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(provider.capabilities.supportsStreaming == false)
        #expect(provider.capabilities.contextLength == 1_000_000)
        #expect(provider.capabilities.maxOutputTokens == 128_000)
        #expect(LanguageModel.anthropic(.custom("claude-fable-5")).supportsStreaming == false)
        #expect(LanguageModel.anthropic(.custom("claude-fable-5")).contextLength == 1_000_000)
        #expect(LanguageModel.Anthropic.custom("claude-fable-5").maxOutputTokens == 128_000)
        #expect(json["model"] as? String == "claude-fable-5")
        #expect(json["thinking"] == nil)
        #expect(json["max_tokens"] as? Int == 16384)
    }

    @Test
    func `Qualified custom Fable model id uses Fable request defaults`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .custom("anthropic.claude-fable-5"), configuration: config)

        let request = ProviderRequest(messages: [.user("hi")])
        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(provider.capabilities.supportsStreaming == false)
        #expect(provider.capabilities.contextLength == 1_000_000)
        #expect(provider.capabilities.maxOutputTokens == 128_000)
        #expect(LanguageModel.anthropic(.custom("anthropic.claude-fable-5")).contextLength == 1_000_000)
        #expect(LanguageModel.Anthropic.custom("anthropic.claude-fable-5").maxOutputTokens == 128_000)
        #expect(json["model"] as? String == "anthropic.claude-fable-5")
        #expect(json["thinking"] == nil)
        #expect(json["max_tokens"] as? Int == 16384)
    }

    @Test
    func `Fable 5 rejects disabled thinking mode`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .fable5, configuration: config)
        let settings = GenerationSettings(
            maxTokens: 64,
            providerOptions: .init(anthropic: .init(thinking: .disabled)),
        )

        #expect(throws: TachikomaError.self) {
            _ = try provider.makeURLRequest(
                for: ProviderRequest(messages: [.user("hi")], settings: settings),
                stream: false,
            )
        }
    }

    @Test
    func `Custom Fable model id rejects disabled thinking mode`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .custom("claude-fable-5"), configuration: config)
        let settings = GenerationSettings(
            maxTokens: 64,
            providerOptions: .init(anthropic: .init(thinking: .disabled)),
        )

        #expect(throws: TachikomaError.self) {
            _ = try provider.makeURLRequest(
                for: ProviderRequest(messages: [.user("hi")], settings: settings),
                stream: false,
            )
        }
    }

    @Test
    func `Opus reasoning effort is kept when thinking is disabled`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus48, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            reasoningEffort: .low,
            providerOptions: .init(anthropic: .init(thinking: .disabled)),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let outputConfig = try #require(json["output_config"] as? [String: Any])

        #expect(json["thinking"] == nil)
        #expect(outputConfig["effort"] as? String == "low")
    }

    @Test
    func `Opus effort is sent without thinking when reasoning effort is configured`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus48, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            reasoningEffort: .low,
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let outputConfig = try #require(json["output_config"] as? [String: Any])

        #expect(json["thinking"] == nil)
        #expect(outputConfig["effort"] as? String == "low")
    }

    @Test
    func `Unsupported adaptive thinking is omitted for older Claude models`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus45, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            providerOptions: .init(anthropic: .init(thinking: .adaptive)),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["thinking"] == nil)
        #expect(json["output_config"] == nil)
    }

    @Test
    func `Sonnet 4_6 request keeps adaptive thinking payload`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .sonnet46, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            temperature: 0.7,
            reasoningEffort: .medium,
            providerOptions: .init(anthropic: .init(thinking: .adaptive)),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try #require(json["thinking"] as? [String: Any])
        let outputConfig = try #require(json["output_config"] as? [String: Any])

        #expect(json["model"] as? String == "claude-sonnet-4-6")
        #expect(json["temperature"] == nil)
        #expect(thinking["type"] as? String == "adaptive")
        #expect(outputConfig["effort"] as? String == "medium")
    }

    @Test
    func `Sonnet 5 request keeps adaptive thinking payload`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .sonnet5, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            temperature: 0.7,
            reasoningEffort: .high,
            providerOptions: .init(anthropic: .init(thinking: .adaptive)),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try #require(json["thinking"] as? [String: Any])
        let outputConfig = try #require(json["output_config"] as? [String: Any])

        #expect(json["model"] as? String == "claude-sonnet-5")
        #expect(json["temperature"] == nil)
        #expect(thinking["type"] as? String == "adaptive")
        #expect(outputConfig["effort"] as? String == "high")
    }

    @Test
    func `Sonnet 5 encodes extended effort levels`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .sonnet5, configuration: config)

        for effort in [ReasoningEffort.xhigh, .max] {
            let request = ProviderRequest(
                messages: [.user("hi")],
                settings: GenerationSettings(maxTokens: 64, reasoningEffort: effort),
            )
            let body = try #require(provider.makeURLRequest(for: request, stream: false).httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let outputConfig = try #require(json["output_config"] as? [String: Any])

            #expect(outputConfig["effort"] as? String == effort.rawValue)
        }
    }

    @Test
    func `Extended effort levels follow the Anthropic model support matrix`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        for (model, effort) in [
            (LanguageModel.Anthropic.opus5, ReasoningEffort.max),
            (.fable5, .xhigh),
            (.opus48, .xhigh),
            (.opus47, .xhigh),
            (.sonnet46, .max),
        ] {
            let provider = try AnthropicProvider(model: model, configuration: config)
            let request = ProviderRequest(
                messages: [.user("hi")],
                settings: GenerationSettings(maxTokens: 64, reasoningEffort: effort),
            )
            let body = try #require(provider.makeURLRequest(for: request, stream: false).httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let outputConfig = try #require(json["output_config"] as? [String: Any])

            #expect(outputConfig["effort"] as? String == effort.rawValue)
        }

        for (model, effort) in [
            (LanguageModel.Anthropic.sonnet46, ReasoningEffort.xhigh),
            (.opus45, .max),
        ] {
            let provider = try AnthropicProvider(model: model, configuration: config)
            let request = ProviderRequest(
                messages: [.user("hi")],
                settings: GenerationSettings(maxTokens: 64, reasoningEffort: effort),
            )

            #expect(throws: TachikomaError.self) {
                _ = try provider.makeURLRequest(for: request, stream: false)
            }
        }
    }

    @Test
    func `Sonnet 5 maps manual thinking to adaptive and encodes disabled thinking`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .sonnet5, configuration: config)

        let enabledRequest = ProviderRequest(
            messages: [.user("hi")],
            settings: GenerationSettings(
                maxTokens: 64,
                providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
            ),
        )
        let disabledRequest = ProviderRequest(
            messages: [.user("hi")],
            settings: GenerationSettings(
                maxTokens: 64,
                reasoningEffort: .max,
                providerOptions: .init(anthropic: .init(thinking: .disabled)),
            ),
        )

        let enabledBody = try #require(provider.makeURLRequest(for: enabledRequest, stream: false).httpBody)
        let enabledJSON = try #require(try JSONSerialization.jsonObject(with: enabledBody) as? [String: Any])
        let enabledThinking = try #require(enabledJSON["thinking"] as? [String: Any])
        #expect(enabledThinking["type"] as? String == "adaptive")
        #expect(enabledThinking["budget_tokens"] == nil)

        let disabledBody = try #require(provider.makeURLRequest(for: disabledRequest, stream: false).httpBody)
        let disabledJSON = try #require(try JSONSerialization.jsonObject(with: disabledBody) as? [String: Any])
        let disabledThinking = try #require(disabledJSON["thinking"] as? [String: Any])
        let disabledOutputConfig = try #require(disabledJSON["output_config"] as? [String: Any])
        #expect(disabledThinking["type"] as? String == "disabled")
        #expect(disabledOutputConfig["effort"] as? String == "max")
    }

    @Test
    func `Sonnet 5 uses an adaptive-thinking output budget by default`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .sonnet5, configuration: config)
        let request = ProviderRequest(messages: [.user("hi")])

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["max_tokens"] as? Int == 16384)
        #expect(urlRequest.timeoutInterval == 1800)
    }

    @Test
    func `Sonnet 5 rejects assistant prefill requests`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .sonnet5, configuration: config)
        let request = ProviderRequest(messages: [.user("hi"), .assistant("prefix")])

        #expect(throws: TachikomaError.self) {
            _ = try provider.makeURLRequest(for: request, stream: false)
        }
    }

    @Test
    func `Custom Anthropic request keeps thinking payload`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .custom("claude-opus-4-5-latest"), configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
        )

        let request = ProviderRequest(
            messages: [.user("hi")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try #require(json["thinking"] as? [String: Any])

        #expect(json["model"] as? String == "claude-opus-4-5-latest")
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 12000)
    }

    @Test
    func `Provider respects custom baseURL`() throws {
        let config = TachikomaConfiguration(
            apiKeys: ["anthropic": "test-key"],
            baseURLs: ["anthropic": "https://entropic.example/v1"],
        )
        let provider = try AnthropicProvider(model: .opus45, configuration: config)

        let request = ProviderRequest(messages: [.user("hi")])
        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        #expect(urlRequest.url?.absoluteString == "https://entropic.example/v1/messages")
    }

    @Test
    func `Provider includes additional proxy headers`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(
            model: .opus45,
            configuration: config,
            additionalHeaders: [
                "client_id": "proxy-client",
                "client_secret": "proxy-secret",
            ],
        )

        let request = ProviderRequest(messages: [.user("hi")])
        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        #expect(urlRequest.value(forHTTPHeaderField: "client_id") == "proxy-client")
        #expect(urlRequest.value(forHTTPHeaderField: "client_secret") == "proxy-secret")
    }

    @Test
    func `Stream delta decodes thinking_delta payload`() throws {
        let data = try #require("{\"type\":\"thinking_delta\",\"thinking\":\"ok\"}".data(using: .utf8))
        let delta = try JSONDecoder().decode(AnthropicStreamDelta.self, from: data)
        #expect(delta.type == "thinking_delta")
        #expect(delta.thinking == "ok")
        #expect(delta.text == nil)
    }

    @Test
    func `Stream delta decodes signature_delta payload`() throws {
        let data = try #require("{\"type\":\"signature_delta\",\"signature\":\"sig\"}".data(using: .utf8))
        let delta = try JSONDecoder().decode(AnthropicStreamDelta.self, from: data)
        #expect(delta.type == "signature_delta")
        #expect(delta.signature == "sig")
    }

    @Test
    func `Stream delta decodes message_delta stop reason without delta type`() throws {
        let data = try #require(
            "{\"stop_reason\":\"refusal\",\"stop_sequence\":null}".data(using: .utf8),
        )
        let delta = try JSONDecoder().decode(AnthropicStreamDelta.self, from: data)
        #expect(delta.type.isEmpty)
        #expect(delta.stopReason == "refusal")
    }

    @Test
    func `Stream event decodes partial usage with stop reason`() throws {
        let data = try #require(
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":42}}"#
                .data(using: .utf8),
        )
        let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)

        #expect(event.delta?.stopReason == "end_turn")
        #expect(event.usage?.inputTokens == 0)
        #expect(event.usage?.outputTokens == 42)
    }

    @Test
    func `Signed thinking blocks are preserved for assistant messages`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus45, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
        )

        let signedThinking = ModelMessage(
            role: .assistant,
            content: [.text("thinking text")],
            channel: .thinking,
            metadata: .init(customData: [
                "anthropic.thinking.signature": "sig",
                "anthropic.thinking.type": "thinking",
            ]),
        )

        let request = ProviderRequest(
            messages: [.user("hi"), signedThinking, .assistant("hello")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2) // signed thinking is merged into the assistant message

        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant.first?["type"] as? String == "thinking")
        #expect(assistant.first?["thinking"] as? String == "thinking text")
        #expect(assistant.first?["signature"] as? String == "sig")
    }

    @Test
    func `Fable 5 preserves signed thinking history while omitting request thinking field`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .fable5, configuration: config)
        let signedThinking = try ModelMessage(
            role: .assistant,
            content: [.text("fable thinking")],
            channel: .thinking,
            metadata: .init(customData: [
                "anthropic.thinking.model": "claude-fable-5",
                "anthropic.thinking.signature": "sig-fable",
                "anthropic.thinking.type": "thinking",
                "tachikoma.reasoning.provider": "anthropic",
                "tachikoma.reasoning.model": "claude-fable-5",
                "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity
                    .canonical("https://api.anthropic.com")),
            ]),
        )

        let request = ProviderRequest(
            messages: [.user("hi"), signedThinking, .assistant("hello"), .user("continue")],
            settings: GenerationSettings(maxTokens: 64),
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])

        #expect(json["thinking"] == nil)
        #expect(assistant.first?["type"] as? String == "thinking")
        #expect(assistant.first?["thinking"] as? String == "fable thinking")
        #expect(assistant.first?["signature"] as? String == "sig-fable")
    }

    @Test
    func `Sonnet 5 preserves default adaptive thinking history`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .sonnet5, configuration: config)
        let signedThinking = try ModelMessage(
            role: .assistant,
            content: [.text("")],
            channel: .thinking,
            metadata: .init(customData: [
                "anthropic.thinking.model": "claude-sonnet-5",
                "anthropic.thinking.signature": "sig-sonnet",
                "anthropic.thinking.type": "thinking",
                "tachikoma.reasoning.provider": "anthropic",
                "tachikoma.reasoning.model": "claude-sonnet-5",
                "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity
                    .canonical("https://api.anthropic.com")),
            ]),
        )

        let request = ProviderRequest(
            messages: [.user("hi"), signedThinking, .assistant("hello"), .user("continue")],
            settings: GenerationSettings(maxTokens: 64),
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])

        #expect(json["thinking"] == nil)
        #expect(assistant.first?["type"] as? String == "thinking")
        #expect((assistant.first?["thinking"] as? String)?.isEmpty == true)
        #expect(assistant.first?["signature"] as? String == "sig-sonnet")
    }

    @Test
    func `Fable 5 drops mismatched signed thinking history in direct provider requests`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .fable5, configuration: config)
        let signedThinking = try ModelMessage(
            role: .assistant,
            content: [.text("foreign thinking")],
            channel: .thinking,
            metadata: .init(customData: [
                "anthropic.thinking.model": "claude-fable-5",
                "anthropic.thinking.signature": "sig-foreign",
                "anthropic.thinking.type": "thinking",
                "tachikoma.reasoning.provider": "anthropic",
                "tachikoma.reasoning.model": "claude-fable-5",
                "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity
                    .canonical("https://other.example.test")),
            ]),
        )

        let request = ProviderRequest(
            messages: [.user("hi"), signedThinking, .assistant("hello"), .user("continue")],
            settings: GenerationSettings(maxTokens: 64),
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])

        #expect(assistant.count == 1)
        #expect(assistant.first?["type"] as? String == "text")
        #expect(assistant.first?["text"] as? String == "hello")
        #expect(String(data: body, encoding: .utf8)?.contains("foreign thinking") == false)
    }

    @Test
    func `Fable 5 rejects assistant prefill requests`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .fable5, configuration: config)

        #expect(throws: TachikomaError.self) {
            _ = try provider.makeURLRequest(
                for: ProviderRequest(messages: [.user("hi"), .assistant("prefill")]),
                stream: false,
            )
        }
    }

    @Test
    func `Anthropic refusal stop reason maps to content filter`() {
        #expect(AnthropicProvider.mapFinishReason("refusal") == .contentFilter)
        #expect(AnthropicProvider.mapFinishReason("model_context_window_exceeded") == .length)
    }

    @Test
    func `Anthropic refusal response decodes stop details explanation`() throws {
        let data = try #require("""
        {
          "id": "msg_test",
          "type": "message",
          "role": "assistant",
          "content": [],
          "model": "claude-fable-5",
          "stop_reason": "refusal",
          "stop_details": {
            "category": "cyber",
            "explanation": "I cannot help with that request."
          },
          "usage": {
            "input_tokens": 10,
            "output_tokens": 0
          }
        }
        """.data(using: .utf8))

        let response = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)

        #expect(response.stopDetails?.category == "cyber")
        #expect(response.stopDetails?.explanation == "I cannot help with that request.")
    }

    @Test
    func `Redacted thinking blocks preserve opaque data`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus45, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
        )

        let redacted = ModelMessage(
            role: .assistant,
            content: [.text("opaque-redacted-data")],
            channel: .thinking,
            metadata: .init(customData: [
                "anthropic.thinking.type": "redacted_thinking",
            ]),
        )

        let request = ProviderRequest(
            messages: [.user("hi"), redacted, .assistant("hello")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant.first?["type"] as? String == "redacted_thinking")
        #expect(assistant.first?["data"] as? String == "opaque-redacted-data")
        #expect(assistant.first?["signature"] == nil)
    }

    @Test
    func `Redacted thinking response decodes opaque data`() throws {
        let data = try #require(
            """
            {"type":"redacted_thinking","data":"opaque-redacted-data"}
            """.data(using: .utf8),
        )

        let content = try JSONDecoder().decode(AnthropicResponseContent.self, from: data)
        guard case let .redactedThinking(redacted) = content else {
            Issue.record("Expected redacted thinking content")
            return
        }
        #expect(redacted.data == "opaque-redacted-data")
    }

    @Test
    func `Consecutive thinking blocks are preserved in order`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .fable5, configuration: config)

        let signedThinking = try ModelMessage(
            role: .assistant,
            content: [.text("signed")],
            channel: .thinking,
            metadata: .init(customData: [
                "anthropic.thinking.model": "claude-fable-5",
                "anthropic.thinking.signature": "sig",
                "anthropic.thinking.type": "thinking",
                "tachikoma.reasoning.provider": "anthropic",
                "tachikoma.reasoning.model": "claude-fable-5",
                "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity
                    .canonical("https://api.anthropic.com")),
            ]),
        )
        let redactedThinking = try ModelMessage(
            role: .assistant,
            content: [.text("opaque")],
            channel: .thinking,
            metadata: .init(customData: [
                "anthropic.thinking.model": "claude-fable-5",
                "anthropic.thinking.type": "redacted_thinking",
                "tachikoma.reasoning.provider": "anthropic",
                "tachikoma.reasoning.model": "claude-fable-5",
                "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity
                    .canonical("https://api.anthropic.com")),
            ]),
        )

        let request = ProviderRequest(
            messages: [.user("hi"), signedThinking, redactedThinking, .assistant("hello"), .user("continue")],
            settings: GenerationSettings(maxTokens: 64),
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])

        #expect(assistant.count == 3)
        #expect(assistant[0]["type"] as? String == "thinking")
        #expect(assistant[0]["thinking"] as? String == "signed")
        #expect(assistant[0]["signature"] as? String == "sig")
        #expect(assistant[1]["type"] as? String == "redacted_thinking")
        #expect(assistant[1]["data"] as? String == "opaque")
        #expect(assistant[2]["type"] as? String == "text")
        #expect(assistant[2]["text"] as? String == "hello")
    }

    @Test
    func `Current Anthropic models expose documented output caps`() {
        #expect(LanguageModel.Anthropic.opus5.maxOutputTokens == 128_000)
        #expect(LanguageModel.Anthropic.fable5.maxOutputTokens == 128_000)
        #expect(LanguageModel.Anthropic.sonnet5.maxOutputTokens == 128_000)
        #expect(LanguageModel.Anthropic.opus47.maxOutputTokens == 128_000)
        #expect(LanguageModel.Anthropic.opus48.maxOutputTokens == 128_000)
        #expect(LanguageModel.Anthropic.sonnet46.maxOutputTokens == 64000)
        #expect(LanguageModel.Anthropic.haiku45.maxOutputTokens == 64000)
    }

    @Test
    func `Refusal-prone Anthropic streaming is disabled until rollback is supported`() async throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let opus5Provider = try AnthropicProvider(model: .opus5, configuration: config)
        let provider = try AnthropicProvider(model: .fable5, configuration: config)
        let sonnetProvider = try AnthropicProvider(model: .sonnet5, configuration: config)
        let opusProvider = try AnthropicProvider(model: .opus48, configuration: config)

        #expect(opus5Provider.capabilities.supportsStreaming == false)
        #expect(provider.capabilities.supportsStreaming == false)
        #expect(LanguageModel.anthropic(.opus5).supportsStreaming == false)
        #expect(LanguageModel.anthropic(.fable5).supportsStreaming == false)
        #expect(sonnetProvider.capabilities.supportsStreaming == false)
        #expect(opusProvider.capabilities.supportsStreaming == false)
        #expect(LanguageModel.anthropic(.opus47).supportsStreaming == true)
        #expect(LanguageModel.anthropic(.opus48).supportsStreaming == false)
        #expect(LanguageModel.anthropic(.sonnet5).supportsStreaming == false)
        #expect(LanguageModel.anthropic(.sonnet46).supportsStreaming == true)
        #expect(LanguageModel.anthropic(.sonnet45).supportsStreaming == true)
        #expect(LanguageModel.anthropic(.haiku45).supportsStreaming == true)
        await #expect(throws: TachikomaError.self) {
            _ = try await opus5Provider.streamText(request: ProviderRequest(messages: [.user("hi")]))
        }
        await #expect(throws: TachikomaError.self) {
            _ = try await provider.streamText(request: ProviderRequest(messages: [.user("hi")]))
        }
        await #expect(throws: TachikomaError.self) {
            _ = try await sonnetProvider.streamText(request: ProviderRequest(messages: [.user("hi")]))
        }
        await #expect(throws: TachikomaError.self) {
            _ = try await opusProvider.streamText(request: ProviderRequest(messages: [.user("hi")]))
        }
    }

    @Test
    func `Opus 4_8 detection avoids substring false positives`() {
        #expect(LanguageModel.Anthropic.isOpus48(modelId: "claude-opus-4-8") == true)
        #expect(LanguageModel.Anthropic.isOpus48(modelId: "anthropic/claude-opus-4.8") == true)
        #expect(LanguageModel.Anthropic.isOpus48(modelId: "my-opus48-distill") == false)
        #expect(LanguageModel.Anthropic.isOpus48(modelId: "opus480") == false)
    }

    @Test
    func `Opus 5 detection avoids substring false positives`() {
        #expect(LanguageModel.Anthropic.isOpus5(modelId: "claude-opus-5") == true)
        #expect(LanguageModel.Anthropic.isOpus5(modelId: "anthropic/claude-opus5") == true)
        #expect(LanguageModel.Anthropic.isOpus5(modelId: "my-opus5-distill") == false)
        #expect(LanguageModel.Anthropic.isOpus5(modelId: "opus50") == false)
    }

    @Test
    func `Fable detection avoids substring false positives`() {
        #expect(LanguageModel.Anthropic.isFable(modelId: "claude-fable-5") == true)
        #expect(LanguageModel.Anthropic.isFable(modelId: "anthropic/claude-fable-5") == true)
        #expect(LanguageModel.Anthropic.isFable(modelId: "vendor/claude-fable-50") == false)
        #expect(LanguageModel.Anthropic.isFable(modelId: "my-claude-fable-5-distill") == false)
    }

    @Test
    func `Sonnet 5 detection avoids substring false positives`() {
        #expect(LanguageModel.Anthropic.isSonnet5(modelId: "claude-sonnet-5") == true)
        #expect(LanguageModel.Anthropic.isSonnet5(modelId: "anthropic/claude-sonnet-5") == true)
        #expect(LanguageModel.Anthropic.isSonnet5(modelId: "vendor/claude-sonnet-50") == false)
        #expect(LanguageModel.Anthropic.isSonnet5(modelId: "my-claude-sonnet-5-distill") == false)
    }

    @Test
    func `Anthropic-compatible provider tags native thinking with wrapper identity`() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AnthropicIdentityURLProtocol.self]
        let provider = try AnthropicProvider(
            model: .custom("claude-fable-5"),
            configuration: TachikomaConfiguration(apiKeys: ["anthropic": "test-key"]),
            reasoningProvider: "anthropic-compatible",
            reasoningModelId: "claude-fable-5",
            reasoningBaseURL: "https://user:secret@example.test/path?token=secret#frag",
            urlSession: URLSession(configuration: sessionConfig),
        )

        let response = try await provider.generateText(request: ProviderRequest(messages: [.user("hi")]))
        let thinking = try #require(response.assistantMessages.first { $0.channel == .thinking })
        #expect(thinking.metadata?.customData?["tachikoma.reasoning.provider"] == "anthropic-compatible")
        #expect(thinking.metadata?.customData?["tachikoma.reasoning.model"] == "claude-fable-5")
        #expect(thinking.metadata?.customData?["tachikoma.reasoning.base_url"] == nil)
        #expect(thinking.metadata?.customData?["anthropic.thinking.signature"] == "sig")
    }

    @Test
    func `Compatible refusal-prone Anthropic streaming and capabilities are disabled`() async throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic_compatible": "test-key"])
        let provider = try AnthropicCompatibleProvider(
            modelId: "claude-fable-5",
            baseURL: "https://example.test",
            configuration: config,
        )
        let opusProvider = try AnthropicCompatibleProvider(
            modelId: "claude-opus-4-8",
            baseURL: "https://example.test",
            configuration: config,
        )
        let overriddenProvider = try AnthropicCompatibleProvider(
            modelId: "claude-fable-5",
            baseURL: "https://example.test",
            configuration: config,
            capabilities: ModelCapabilities(supportsStreaming: true),
        )

        #expect(provider.capabilities.supportsStreaming == false)
        #expect(opusProvider.capabilities.supportsStreaming == false)
        #expect(overriddenProvider.capabilities.supportsStreaming == false)
        #expect(provider.capabilities.contextLength == 1_000_000)
        #expect(provider.capabilities.maxOutputTokens == 128_000)
        #expect(LanguageModel.anthropicCompatible(
            modelId: "claude-fable-5",
            baseURL: "https://example.test",
        ).supportsStreaming == false)
        #expect(LanguageModel.anthropicCompatible(
            modelId: "claude-opus-4-8",
            baseURL: "https://example.test",
        ).supportsStreaming == false)
        #expect(LanguageModel.openaiCompatible(
            modelId: "claude-fable-5",
            baseURL: "https://example.test",
        ).supportsStreaming == false)
        #expect(LanguageModel.anthropicCompatible(
            modelId: "claude-fable-5",
            baseURL: "https://example.test",
        ).contextLength == 1_000_000)
        #expect(LanguageModel.anthropicCompatible(
            modelId: "anthropic.claude-fable-5",
            baseURL: "https://example.test",
        ).contextLength == 1_000_000)
        let openAICompatibleProvider = try OpenAICompatibleProvider(
            modelId: "claude-fable-5",
            baseURL: "https://example.test",
            configuration: TachikomaConfiguration(apiKeys: ["openai_compatible": "test-key"]),
        )
        let openRouterProvider = try OpenRouterProvider(
            modelId: "anthropic/claude-fable-5",
            configuration: TachikomaConfiguration(apiKeys: ["openrouter": "test-key"]),
        )
        let togetherProvider = try TogetherProvider(
            modelId: "anthropic/claude-fable-5",
            configuration: TachikomaConfiguration(apiKeys: ["together": "test-key"]),
        )
        #expect(openAICompatibleProvider.capabilities.supportsStreaming == false)
        #expect(openRouterProvider.capabilities.supportsStreaming == false)
        #expect(togetherProvider.capabilities.supportsStreaming == false)
        #expect(openAICompatibleProvider.capabilities.contextLength == 1_000_000)
        #expect(openAICompatibleProvider.capabilities.maxOutputTokens == 128_000)
        #expect(openRouterProvider.capabilities.contextLength == 1_000_000)
        #expect(openRouterProvider.capabilities.maxOutputTokens == 128_000)
        #expect(togetherProvider.capabilities.contextLength == 1_000_000)
        #expect(togetherProvider.capabilities.maxOutputTokens == 128_000)
        await #expect(throws: TachikomaError.self) {
            _ = try await provider.streamText(request: ProviderRequest(messages: [.user("hi")]))
        }
        await #expect(throws: TachikomaError.self) {
            _ = try await openAICompatibleProvider.streamText(request: ProviderRequest(messages: [.user("hi")]))
        }
        await #expect(throws: TachikomaError.self) {
            _ = try await openRouterProvider.streamText(request: ProviderRequest(messages: [.user("hi")]))
        }
        await #expect(throws: TachikomaError.self) {
            _ = try await togetherProvider.streamText(request: ProviderRequest(messages: [.user("hi")]))
        }
    }

    @Test
    func `Thinking stays enabled even without signed history`() throws {
        let config = TachikomaConfiguration(apiKeys: ["anthropic": "test-key"])
        let provider = try AnthropicProvider(model: .opus45, configuration: config)

        let settings = GenerationSettings(
            maxTokens: 64,
            providerOptions: .init(anthropic: .init(thinking: .enabled(budgetTokens: 12000))),
        )

        let request = ProviderRequest(
            messages: [.user("hi"), .assistant("hello")],
            settings: settings,
        )

        let urlRequest = try provider.makeURLRequest(for: request, stream: false)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 12000)

        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(assistant.first?["type"] as? String == "text")
    }
}

private final class AnthropicIdentityURLProtocol: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = self.request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            ) else
        {
            self.client?.urlProtocol(self, didFailWithError: TachikomaError.invalidInput("Missing mock response"))
            return
        }

        let body = """
        {
          "id": "msg_test",
          "type": "message",
          "role": "assistant",
          "model": "claude-fable-5",
          "content": [
            {"type": "thinking", "thinking": "private", "signature": "sig"},
            {"type": "text", "text": "ok"}
          ],
          "stop_reason": "end_turn",
          "usage": {"input_tokens": 1, "output_tokens": 2}
        }
        """.data(using: .utf8) ?? Data()

        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: body)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
