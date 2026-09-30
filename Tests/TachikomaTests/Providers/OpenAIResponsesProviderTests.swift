import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Testing
@testable import Tachikoma

#if os(Linux)
@Suite(.disabled("URLProtocol mocking unavailable on Linux"))
struct OpenAIResponsesProviderTests {}
#else

@Suite(.serialized)
struct OpenAIResponsesProviderTests {
    @Test(arguments: [LanguageModel.OpenAI.gpt61Sol, .gpt6Astra, .gpt6Sol, .gpt6Luna])
    func `gpt 6 request parameters`(model: LanguageModel.OpenAI) async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)
        let efforts: [OpenAIOptions.ReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
        for effort in efforts + (model == .gpt6Sol || model == .gpt6Luna ? [.none] : []) {
            try await self.withMockedSession { request in
                let body = try #require(Self.bodyData(from: request))
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(request.url?.path == "/v1/responses")
                #expect(json["model"] as? String == model.modelId)
                #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == effort.rawValue)
                #expect(json["max_output_tokens"] as? Int == 4096)
                if effort == .none {
                    #expect(json["temperature"] as? Double == 0.2)
                    #expect(json["top_p"] as? Double == 0.9)
                } else {
                    #expect(json["temperature"] == nil)
                    #expect(json["top_p"] == nil)
                }
                return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "pong"))
            } operation: { session in
                let provider = try OpenAIResponsesProvider(model: model, configuration: config, session: session)
                _ = try await provider.generateText(request: .init(
                    messages: [.user("ping")],
                    settings: .init(
                        maxTokens: 4096,
                        temperature: 0.2,
                        topP: 0.9,
                        providerOptions: .init(openai: .init(reasoningEffort: effort)),
                    ),
                ))
            }
        }
    }

    @Test(arguments: [
        (LanguageModel.OpenAI.gpt6Astra, OpenAIOptions.ReasoningEffort.none),
        (.gpt6Astra, .minimal), (.gpt6Sol, .minimal), (.gpt6Luna, .minimal),
        (.gpt61Sol, .none), (.gpt61Sol, .minimal),
    ])
    func `gpt 6 rejects unsupported effort`(
        model: LanguageModel.OpenAI,
        effort: OpenAIOptions.ReasoningEffort,
    ) async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)
        try await self.withMockedSession { request in
            Issue.record("Invalid reasoning effort must fail before HTTP dispatch")
            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "unexpected"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: model, configuration: config, session: session)
            await #expect(throws: TachikomaError.self) {
                _ = try await provider.generateText(request: .init(
                    messages: [.user("ping")],
                    settings: .init(providerOptions: .init(openai: .init(reasoningEffort: effort))),
                ))
            }
        }
    }

    @Test
    func `GPT-5+ uses Responses API provider`() throws {
        // Test that GPT-5 models use the OpenAIResponsesProvider
        let config = self.openAIConfig()

        let gpt5Models: [LanguageModel.OpenAI] = [
            .chatLatest,
            .gpt56Sol,
            .gpt56Terra,
            .gpt56Luna,
            .gpt55,
            .gpt54,
            .gpt54Mini,
            .gpt54Nano,
            .gpt5,
            .gpt5Mini,
            .gpt5Nano,
        ]

        for model in gpt5Models {
            let provider = try ProviderFactory.createProvider(
                for: .openai(model),
                configuration: config,
            )

            #expect(
                provider is OpenAIResponsesProvider,
                "GPT-5 model \(model) should use OpenAIResponsesProvider",
            )
        }
    }

    @Test
    func `GPT-5.5 text.verbosity parameter is set correctly`() throws {
        // Test that the text.verbosity parameter is properly configured for GPT-5.5
        let config = self.openAIConfig()

        // Skip if no API key
        guard config.getAPIKey(for: .openai) != nil else {
            throw TestSkipped("OpenAI API key not configured")
        }

        let provider = try OpenAIResponsesProvider(
            model: .gpt55,
            configuration: config,
        )

        // Create a simple request
        _ = ProviderRequest(
            messages: [
                ModelMessage(role: .user, content: [.text("Hello")]),
            ],
            tools: nil,
            settings: GenerationSettings(),
        )

        // We can't directly test the internal request building without making it public
        // But we can verify the provider is configured correctly
        #expect(provider.modelId == "gpt-5.5")
        #expect(provider.capabilities.supportsTools == true)
        #expect(provider.capabilities.supportsVision == true)
    }

    @Test
    func `GPT-5 models use Responses API`() throws {
        // Test that GPT-5 models use the OpenAIResponsesProvider
        let config = self.openAIConfig()

        let responsesModels: [LanguageModel.OpenAI] = [
            .chatLatest,
            .gpt56Sol,
            .gpt56Terra,
            .gpt56Luna,
            .gpt55,
            .gpt54,
            .gpt54Mini,
            .gpt54Nano,
            .gpt5,
            .gpt5Mini,
        ]

        for model in responsesModels {
            let provider = try ProviderFactory.createProvider(
                for: .openai(model),
                configuration: config,
            )

            #expect(
                provider is OpenAIResponsesProvider,
                "Reasoning model \(model) should use OpenAIResponsesProvider",
            )
        }
    }

    @Test
    func `Custom OpenAI models use standard OpenAI provider`() throws {
        let config = self.openAIConfig()

        let legacyModels: [LanguageModel.OpenAI] = [.custom("custom-openai")]

        for model in legacyModels {
            let provider = try ProviderFactory.createProvider(
                for: .openai(model),
                configuration: config,
            )

            #expect(
                provider is OpenAIProvider,
                "Custom model \(model) should use OpenAIProvider",
            )
        }
    }

    @Test
    func `TextConfig encodes verbosity correctly`() throws {
        // Test that TextConfig properly encodes the verbosity parameter
        let textConfig = TextConfig(verbosity: .high)

        let encoder = JSONEncoder()
        let data = try encoder.encode(textConfig)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["verbosity"] as? String == "high")
    }

    @Test
    func `OpenAIResponsesRequest includes text config for GPT-5`() throws {
        // Test that the request properly includes text config
        let textConfig = TextConfig(verbosity: .medium)
        let request = OpenAIResponsesRequest(
            model: "gpt-5",
            input: [.message(ResponsesMessage(role: "user", content: .text("Test")))],
            temperature: nil,
            topP: nil,
            maxOutputTokens: nil,
            text: textConfig,
            tools: nil,
            toolChoice: nil,
            metadata: nil,
            parallelToolCalls: nil,
            previousResponseId: nil,
            store: nil,
            user: nil,
            instructions: nil,
            serviceTier: nil,
            include: nil,
            reasoning: nil,
            truncation: nil,
            stream: false,
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let textJson = json?["text"] as? [String: Any] {
            #expect(textJson["verbosity"] as? String == "medium")
        } else {
            Issue.record("Expected text field in JSON")
        }
    }

    @Test
    func `GPT-5 tool call outputs are parsed`() throws {
        let toolCall = OpenAIResponsesResponse.ResponsesToolCall(
            id: "call_1",
            type: "function",
            function: .init(name: "see", arguments: "{\"mode\":\"screen\"}"),
        )

        let output = OpenAIResponsesResponse.ResponsesOutput(
            id: "out_1",
            type: "message",
            status: "completed",
            content: [
                .init(type: "output_text", text: "Capturing now.", toolCall: nil),
                .init(type: "tool_call", text: nil, toolCall: toolCall),
            ],
            role: "assistant",
            toolCall: nil,
        )

        let response = OpenAIResponsesResponse(
            id: "resp_1",
            object: "response",
            createdAt: 0,
            created: nil,
            status: "completed",
            model: "gpt-5",
            output: [output],
            choices: nil,
            usage: nil,
            metadata: nil,
            incompleteDetails: nil,
        )

        let providerResponse = try OpenAIResponsesProvider.convertToProviderResponse(response)

        #expect(providerResponse.text == "Capturing now.")
        let toolCalls = try #require(providerResponse.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].name == "see")
        #expect(toolCalls[0].arguments["mode"]?.stringValue == "screen")
        #expect(providerResponse.finishReason == .toolCalls)
    }

    @Test
    func `Responses output preserves encrypted reasoning before function call`() throws {
        let response = OpenAIResponsesResponse(
            id: "resp_1",
            object: "response",
            createdAt: 0,
            created: nil,
            status: "completed",
            model: "gpt-5",
            output: [
                .init(
                    id: "rs_123",
                    type: "reasoning",
                    encryptedContent: "sealed-reasoning",
                    summary: [.init(type: "summary_text", text: "Checking")],
                ),
                .init(
                    id: "fc_item_123",
                    type: "function_call",
                    callId: "call_123",
                    name: "lookup",
                    arguments: #"{"query":"weather"}"#,
                ),
            ],
            choices: nil,
            usage: nil,
            metadata: nil,
            incompleteDetails: nil,
        )

        let providerResponse = try OpenAIResponsesProvider.convertToProviderResponse(response)
        let assistantMessage = try #require(providerResponse.assistantMessages.first)
        #expect(assistantMessage.content.count == 2)
        guard case let .reasoning(reasoning) = assistantMessage.content[0] else {
            Issue.record("Expected reasoning before the function call")
            return
        }
        #expect(reasoning.id == "rs_123")
        #expect(reasoning.encryptedContent == "sealed-reasoning")
        guard case let .toolCall(call) = assistantMessage.content[1] else {
            Issue.record("Expected function call after reasoning")
            return
        }
        #expect(call.id == "call_123")
        #expect(providerResponse.finishReason == .toolCalls)
    }

    @Test
    func `GPT-5 incomplete content filter response maps finish reason`() throws {
        let output = OpenAIResponsesResponse.ResponsesOutput(
            id: "out_1",
            type: "message",
            status: "incomplete",
            content: [
                .init(type: "output_text", text: "blocked partial", toolCall: nil),
            ],
            role: "assistant",
            toolCall: nil,
        )

        let response = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: #require("""
        {
          "id": "resp_1",
          "object": "response",
          "created_at": 0,
          "status": "incomplete",
          "model": "gpt-5",
          "output": [
            {
              "id": "out_1",
              "type": "message",
              "status": "incomplete",
              "role": "assistant",
              "content": [
                { "type": "output_text", "text": "blocked partial" }
              ]
            }
          ],
          "incomplete_details": { "reason": "content_filter" }
        }
        """.data(using: .utf8)))

        let providerResponse = try OpenAIResponsesProvider.convertToProviderResponse(response)

        #expect(output.status == "incomplete")
        #expect(providerResponse.text.isEmpty)
        #expect(providerResponse.finishReason == .contentFilter)
    }

    @Test
    func `GPT-5 incomplete content filter discards parsed tool calls`() throws {
        let toolCall = OpenAIResponsesResponse.ResponsesToolCall(
            id: "call_1",
            type: "function",
            function: .init(name: "see", arguments: "{\"mode\":\"screen\"}"),
        )
        let output = OpenAIResponsesResponse.ResponsesOutput(
            id: "out_1",
            type: "message",
            status: "incomplete",
            content: [
                .init(type: "output_text", text: "blocked partial", toolCall: nil),
                .init(type: "tool_call", text: nil, toolCall: toolCall),
            ],
            role: "assistant",
            toolCall: nil,
        )
        let response = OpenAIResponsesResponse(
            id: "resp_1",
            object: "response",
            createdAt: 0,
            created: nil,
            status: "incomplete",
            model: "gpt-5",
            output: [output],
            choices: nil,
            usage: nil,
            metadata: nil,
            incompleteDetails: .init(reason: "content_filter"),
        )

        let providerResponse = try OpenAIResponsesProvider.convertToProviderResponse(response)

        #expect(providerResponse.text.isEmpty)
        #expect(providerResponse.toolCalls == nil)
        #expect(providerResponse.finishReason == .contentFilter)
    }

    @Test
    func `GPT-5 completed refusal output maps to content filter`() throws {
        let output = OpenAIResponsesResponse.ResponsesOutput(
            id: "out_1",
            type: "message",
            status: "completed",
            content: [
                .init(type: "refusal", refusal: "I cannot help with that."),
            ],
            role: "assistant",
            toolCall: nil,
        )
        let response = OpenAIResponsesResponse(
            id: "resp_1",
            object: "response",
            createdAt: 0,
            created: nil,
            status: "completed",
            model: "gpt-5",
            output: [output],
            choices: nil,
            usage: nil,
            metadata: nil,
            incompleteDetails: nil,
        )

        let providerResponse = try OpenAIResponsesProvider.convertToProviderResponse(response)

        #expect(providerResponse.text.isEmpty)
        #expect(providerResponse.toolCalls == nil)
        #expect(providerResponse.finishReason == .contentFilter)
    }

    @Test
    func `Alternate choices content filter suppresses text and tool calls`() throws {
        let response = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: #require("""
        {
          "id": "chatcmpl_1",
          "object": "chat.completion",
          "created": 0,
          "model": "gpt-5",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": "blocked partial",
                "tool_calls": [
                  {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "see",
                      "arguments": "{\\"mode\\":\\"screen\\"}"
                    }
                  }
                ]
              },
              "finish_reason": "content_filter",
              "logprobs": null
            }
          ]
        }
        """.data(using: .utf8)))

        let providerResponse = try OpenAIResponsesProvider.convertToProviderResponse(response)

        #expect(providerResponse.text.isEmpty)
        #expect(providerResponse.toolCalls == nil)
        #expect(providerResponse.finishReason == .contentFilter)
    }

    @Test
    func `Responses provider hits /v1/responses and encodes body`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            #expect(request.url?.path == "/v1/responses")

            let body = try #require(Self.bodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["model"] as? String == "gpt-5-mini")

            if
                let input = json?["input"] as? [[String: Any]],
                let first = input.first,
                let content = first["content"] as? [[String: Any]],
                let text = content.first?["text"] as? String
            {
                #expect(text == "ping")
            } else {
                Issue.record("Missing input payload")
            }

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "pong"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt5Mini, configuration: config, session: session)
            let response = try await provider.generateText(request: self.sampleRequest)
            #expect(response.text.contains("GPT-5") || response.text.contains("pong"))
        }
    }

    @Test
    func `GPT-5_6 Responses payload preserves requested reasoning effort`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let reasoning = try #require(json["reasoning"] as? [String: Any])

            #expect(json["model"] as? String == "gpt-5.6-sol")
            #expect(reasoning["effort"] as? String == "max")

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "pong"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt56Sol, configuration: config, session: session)
            let request = ProviderRequest(
                messages: [.user("ping")],
                settings: .init(
                    maxTokens: 32,
                    providerOptions: .init(openai: .init(reasoningEffort: .max)),
                ),
            )
            _ = try await provider.generateText(request: request)
        }
    }

    @Test
    func `GPT-5_6 Responses payload preserves xhigh reasoning effort`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let reasoning = try #require(json["reasoning"] as? [String: Any])

            #expect(reasoning["effort"] as? String == "xhigh")

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "pong"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt56Sol, configuration: config, session: session)
            let request = ProviderRequest(
                messages: [.user("ping")],
                settings: .init(providerOptions: .init(openai: .init(reasoningEffort: .xhigh))),
            )
            _ = try await provider.generateText(request: request)
        }
    }

    @Test
    func `GPT-5_6 Responses payload rejects minimal reasoning effort`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        let provider = try OpenAIResponsesProvider(model: .gpt56Sol, configuration: config)
        await #expect(throws: TachikomaError.self) {
            _ = try await provider.generateText(request: ProviderRequest(
                messages: [.user("ping")],
                settings: .init(providerOptions: .init(openai: .init(reasoningEffort: .minimal))),
            ))
        }
    }

    @Test
    func `chat-latest Responses payload omits GPT-5 reasoning controls`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["model"] as? String == "chat-latest")
            #expect(json?["reasoning"] == nil)
            #expect(json?["text"] == nil)

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "pong"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .chatLatest, configuration: config, session: session)
            _ = try await provider.generateText(request: self.sampleRequest)
        }
    }

    @Test
    func `GPT-5 Chat Responses payload preserves model ID`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["model"] as? String == "gpt-5-chat-latest")
            #expect(json?["reasoning"] == nil)
            #expect(json?["text"] == nil)

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "pong"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(
                model: .gpt5ChatLatest,
                configuration: config,
                session: session,
            )
            #expect(provider.capabilities.contextLength == 128_000)
            #expect(provider.capabilities.maxOutputTokens == 16384)
            _ = try await provider.generateText(request: self.sampleRequest)
        }
    }

    @Test(arguments: [
        (LanguageModel.OpenAI.gpt55, "gpt-5.5"),
        (.gpt56Sol, "gpt-5.6-sol"),
        (.gpt56Terra, "gpt-5.6-terra"),
        (.gpt56Luna, "gpt-5.6-luna"),
        (.gpt6Astra, "gpt-6-astra"),
        (.gpt6Sol, "gpt-6-sol"),
        (.gpt61Sol, "gpt-6.1-sol"),
        (.gpt6Luna, "gpt-6-luna"),
    ])
    func `Codex OAuth provider sends image input through ChatGPT Responses transport`(
        model: LanguageModel.OpenAI,
        expectedModelID: String,
    ) async throws {
        try await self.withIsolatedAuthState {
            let accessToken = Self.openAIJWT(
                accountID: "account-123",
                expiration: Date().addingTimeInterval(3600),
            )
            try TKAuthManager.shared.setCredentials([
                "OPENAI_ACCESS_TOKEN": accessToken,
                "OPENAI_REFRESH_TOKEN": "oauth-refresh-token",
                "OPENAI_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            ])
            let config = TachikomaConfiguration(loadFromEnvironment: false)

            try await self.withMockedSession { request in
                #expect(request.url?.host == "chatgpt.com")
                #expect(request.url?.path == "/backend-api/codex/responses")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessToken)")
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-123")
                #expect(request.value(forHTTPHeaderField: "originator") == "peekaboo")
                #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
                #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

                let body = try #require(Self.bodyData(from: request))
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["model"] as? String == expectedModelID)
                #expect(json["stream"] as? Bool == true)
                #expect(json["store"] as? Bool == false)
                #expect(json["instructions"] as? String == "You are a helpful assistant.")
                #expect(json["include"] as? [String] == ["reasoning.encrypted_content"])
                #expect(json["reasoning"] == nil)
                #expect((json["text"] as? [String: String])?["verbosity"] == "low")
                #expect(json["truncation"] == nil)
                #expect(json["max_output_tokens"] == nil)

                let input = try #require(json["input"] as? [[String: Any]])
                let content = try #require(input.first?["content"] as? [[String: Any]])
                let image = try #require(content.first { $0["type"] as? String == "input_image" })
                #expect(image["image_url"] as? String == "data:image/png;base64,BASE64DATA")

                let payload = Self.responsesStreamPayload(chunks: [
                    Self.streamChunkJSON(content: "vision through oauth", finishReason: nil),
                    Self.streamEventJSON([
                        "type": "response.completed",
                        "response": [
                            "usage": [
                                "input_tokens": 12,
                                "output_tokens": 4,
                            ],
                        ],
                    ]),
                ])
                return NetworkMocking.streamResponse(for: request, data: payload)
            } operation: { session in
                let provider = try OpenAIResponsesProvider(model: model, configuration: config, session: session)
                #expect(provider.isResponseCacheSafe == false)
                let image = ModelMessage.ContentPart.ImageContent(
                    data: "BASE64DATA",
                    mimeType: "image/png",
                )
                let request = ProviderRequest(
                    messages: [
                        ModelMessage.user(
                            text: "What do you see?",
                            images: [image],
                        ),
                    ],
                    settings: .init(maxTokens: 32),
                )
                let response = try await provider.generateText(request: request)
                #expect(response.text == "vision through oauth")
                #expect(response.finishReason == .stop)
                #expect(response.usage == Usage(inputTokens: 12, outputTokens: 4))
            }
        }
    }

    @Test
    func `Codex OAuth replays encrypted reasoning before tool calls`() async throws {
        try await self.withIsolatedAuthState {
            let accessToken = Self.openAIJWT(
                accountID: "account-123",
                expiration: Date().addingTimeInterval(3600),
            )
            try TKAuthManager.shared.setCredentials([
                "OPENAI_ACCESS_TOKEN": accessToken,
                "OPENAI_REFRESH_TOKEN": "oauth-refresh-token",
                "OPENAI_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            ])
            let config = TachikomaConfiguration(loadFromEnvironment: false)
            let firstRequest = ProviderRequest(
                messages: [.user("Look up the weather")],
                settings: .init(maxTokens: 32),
            )

            let firstResponse = try await self.withMockedSession { request in
                #expect(request.url?.host == "chatgpt.com")
                let payload = Self.responsesStreamPayload(chunks: [
                    Self.streamEventJSON([
                        "type": "response.output_item.added",
                        "item": ["id": "rs_123", "type": "reasoning", "summary": []],
                    ]),
                    Self.streamEventJSON([
                        "type": "response.output_item.done",
                        "item": [
                            "id": "rs_123",
                            "type": "reasoning",
                            "encrypted_content": "sealed-reasoning",
                            "summary": [["type": "summary_text", "text": "Checking the weather"]],
                        ],
                    ]),
                    Self.streamEventJSON([
                        "type": "response.output_item.added",
                        "item": [
                            "id": "fc_item_123",
                            "type": "function_call",
                            "call_id": "call_123",
                            "name": "get_weather",
                        ],
                    ]),
                    Self.streamEventJSON([
                        "type": "response.function_call_arguments.done",
                        "item_id": "fc_item_123",
                        "arguments": #"{"location":"San Francisco"}"#,
                    ]),
                    Self.streamEventJSON(["type": "response.completed"]),
                ])
                return NetworkMocking.streamResponse(for: request, data: payload)
            } operation: { session in
                let provider = try OpenAIResponsesProvider(model: .gpt56Sol, configuration: config, session: session)
                return try await provider.generateText(request: firstRequest)
            }

            let assistantMessage = try #require(firstResponse.assistantMessages.first)
            #expect(firstResponse.toolCalls?.first?.id == "call_123")
            guard case let .reasoning(reasoning) = assistantMessage.content.first else {
                Issue.record("Expected the encrypted reasoning item first")
                return
            }
            #expect(reasoning.id == "rs_123")
            #expect(reasoning.encryptedContent == "sealed-reasoning")
            #expect(reasoning.summary == [.init(type: "summary_text", text: "Checking the weather")])
            guard case let .toolCall(toolCall) = assistantMessage.content.last else {
                Issue.record("Expected the function call after reasoning")
                return
            }

            let toolResult = AgentToolResult.success(
                toolCallId: toolCall.id,
                result: AnyAgentToolValue(string: "68 F"),
            )
            let secondRequest = ProviderRequest(
                messages: [
                    .user("Look up the weather"),
                    assistantMessage,
                    ModelMessage(role: .tool, content: [.toolResult(toolResult)]),
                ],
                settings: .init(maxTokens: 32),
            )

            try await self.withMockedSession { request in
                let body = try #require(Self.bodyData(from: request))
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let input = try #require(json["input"] as? [[String: Any]])
                let reasoningIndex = try #require(input.firstIndex { $0["type"] as? String == "reasoning" })
                let callIndex = try #require(input.firstIndex { $0["type"] as? String == "function_call" })
                let outputIndex = try #require(input.firstIndex { $0["type"] as? String == "function_call_output" })
                #expect(reasoningIndex < callIndex)
                #expect(callIndex < outputIndex)
                #expect(input[reasoningIndex]["id"] as? String == "rs_123")
                #expect(input[reasoningIndex]["encrypted_content"] as? String == "sealed-reasoning")
                let summary = try #require(input[reasoningIndex]["summary"] as? [[String: String]])
                #expect(summary == [["type": "summary_text", "text": "Checking the weather"]])
                #expect(input[callIndex]["call_id"] as? String == "call_123")
                #expect(input[outputIndex]["call_id"] as? String == "call_123")

                let payload = Self.responsesStreamPayload(chunks: [
                    Self.streamEventJSON(["type": "response.output_text.delta", "delta": "It is 68 F."]),
                    Self.streamEventJSON(["type": "response.completed"]),
                ])
                return NetworkMocking.streamResponse(for: request, data: payload)
            } operation: { session in
                let provider = try OpenAIResponsesProvider(model: .gpt56Sol, configuration: config, session: session)
                let response = try await provider.generateText(request: secondRequest)
                #expect(response.text == "It is 68 F.")
            }
        }
    }

    @Test
    func `API key route omits provider-native reasoning input`() async throws {
        let config = self.openAIConfig()
        let reasoning = ModelMessage.ContentPart.ReasoningContent(
            id: "rs_private",
            encryptedContent: "sealed-private",
        )
        let toolCall = AgentToolCall(id: "call_123", name: "lookup", arguments: [:])
        let toolResult = AgentToolResult.success(
            toolCallId: toolCall.id,
            result: AnyAgentToolValue(string: "done"),
        )
        let providerRequest = ProviderRequest(
            messages: [
                .user("go"),
                ModelMessage(role: .assistant, content: [.reasoning(reasoning), .toolCall(toolCall)]),
                ModelMessage(role: .tool, content: [.toolResult(toolResult)]),
            ],
            settings: .init(maxTokens: 32),
        )

        try await self.withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let input = try #require(json["input"] as? [[String: Any]])
            #expect(input.map { $0["type"] as? String } == [nil, "function_call", "function_call_output"])
            #expect(input.allSatisfy { $0["encrypted_content"] == nil })
            #expect(json["include"] == nil)
            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "Done"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt5, configuration: config, session: session)
            _ = try await provider.generateText(request: providerRequest)
        }
    }

    @Test
    func `Responses provider preserves generic stored access token routing`() async throws {
        try await self.withIsolatedAuthState {
            try TKAuthManager.shared.setCredential(
                key: "OPENAI_ACCESS_TOKEN",
                value: "opaque-access-token",
            )
            let config = TachikomaConfiguration(loadFromEnvironment: false)
            config.setBaseURL("https://openai-compatible.example.test/v1", for: .openai)

            try await self.withMockedSession { request in
                #expect(request.url?.absoluteString == "https://openai-compatible.example.test/v1/responses")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-access-token")
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
                return NetworkMocking.jsonResponse(
                    for: request,
                    data: Self.responsesPayload(text: "generic bearer ok"),
                )
            } operation: { session in
                let provider = try OpenAIResponsesProvider(
                    model: .gpt5Mini,
                    configuration: config,
                    session: session,
                )
                let response = try await provider.generateText(request: self.sampleRequest)
                #expect(response.text.contains("generic bearer ok"))
            }
        }
    }

    @Test
    func `Responses payload uses data URL string for images`() async throws {
        let config = self.openAIConfig()

        try await self.withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let input = json?["input"] as? [[String: Any]]
            let message = input?.first
            let content = message?["content"] as? [[String: Any]]
            let image = content?.first { $0["type"] as? String == "input_image" }
            let imageURL = try #require(image?["image_url"] as? String)
            #expect(imageURL == "data:image/png;base64,BASE64DATA")

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "vision ok"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt5Mini, configuration: config, session: session)
            let request = ProviderRequest(
                messages: [
                    ModelMessage.user(
                        text: "What do you see?",
                        images: [ModelMessage.ContentPart.ImageContent(data: "BASE64DATA", mimeType: "image/png")],
                    ),
                ],
                settings: .init(maxTokens: 32),
            )

            let response = try await provider.generateText(request: request)
            #expect(response.text.contains("vision ok"))
        }
    }

    @Test
    func `Responses image_url accepts legacy object and normalizes to string`() throws {
        // Craft a legacy-style payload (image_url object) and ensure decoder tolerates it.
        let legacyJSON: [String: Any] = [
            "type": "input_image",
            "image_url": ["url": "data:image/png;base64,LEGACY", "detail": "auto"],
        ]

        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let part = try JSONDecoder().decode(ResponsesContentPart.self, from: data)
        #expect(part.imageUrl?.url == "data:image/png;base64,LEGACY")
        #expect(part.imageUrl?.detail == "auto")

        // And when we re-encode, it should collapse to the string form.
        let encoded = try JSONEncoder().encode(part)
        let encodedJSON = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(encodedJSON?["image_url"] as? String == "data:image/png;base64,LEGACY")
    }

    @Test
    func `Responses provider emits tool schemas with parameters`() async throws {
        let config = self.openAIConfig()
        let tool = AgentTool(
            name: "app",
            description: "Control apps",
            parameters: AgentToolParameters(
                properties: [
                    "action": AgentToolParameterProperty(
                        name: "action",
                        type: .string,
                        description: "Action to perform",
                    ),
                    "to": AgentToolParameterProperty(
                        name: "to",
                        type: .string,
                        description: "Target application",
                    ),
                    "apps": AgentToolParameterProperty(
                        name: "apps",
                        type: .array,
                        description: "Batch targets",
                        items: AgentToolParameterItems(type: "string"),
                    ),
                ],
                required: ["action"],
            ),
        ) { _ in
            AnyAgentToolValue(string: "ok")
        }

        let providerRequest = ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("ping")])],
            tools: [tool],
            settings: .init(maxTokens: 32),
        )

        try await withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let tools = try #require(json?["tools"] as? [[String: Any]])
            let encodedTool = try #require(tools.first)
            #expect(encodedTool["name"] as? String == "app")
            #expect(encodedTool["description"] as? String == "Control apps")
            #expect(encodedTool["strict"] as? Bool == false)
            #expect(encodedTool["function"] == nil)
            let parameters = try #require(encodedTool["parameters"] as? [String: Any])
            let required = try #require(parameters["required"] as? [String])
            #expect(required == ["action"])
            let props = try #require(parameters["properties"] as? [String: Any])
            let actionProp = try #require(props["action"] as? [String: Any])
            #expect(actionProp["type"] as? String == "string")
            let appsProp = try #require(props["apps"] as? [String: Any])
            let items = try #require(appsProp["items"] as? [String: Any])
            #expect(items["type"] as? String == "string")

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "pong"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt5, configuration: config, session: session)
            _ = try await provider.generateText(request: providerRequest)
        }
    }

    @Test
    func `Responses provider keeps optional tool properties omittable`() async throws {
        let config = self.openAIConfig()
        let optionalProperties: [String: AgentToolParameterProperty] = [
            "app_target": .init(name: "app_target", type: .string, description: "Application target"),
            "window_id": .init(name: "window_id", type: .integer, description: "Exact window ID"),
            "snapshot": .init(name: "snapshot", type: .string, description: "Existing snapshot ID"),
            "web_focus": .init(name: "web_focus", type: .boolean, description: "Allow web focus"),
            "max_depth": .init(name: "max_depth", type: .number, description: "Traversal depth"),
            "max_elements": .init(name: "max_elements", type: .number, description: "Element limit"),
            "max_children": .init(name: "max_children", type: .number, description: "Child limit"),
        ]
        let tool = AgentTool(
            name: "inspect_ui",
            description: "Inspect accessibility state",
            parameters: AgentToolParameters(properties: optionalProperties, required: []),
        ) { _ in
            AnyAgentToolValue(string: "ok")
        }
        let providerRequest = ProviderRequest(
            messages: [.user("Inspect the frontmost app")],
            tools: [tool],
            settings: .init(maxTokens: 32),
        )

        try await self.withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            let encodedTool = try #require(tools.first)
            #expect(encodedTool["strict"] as? Bool == false)

            let parameters = try #require(encodedTool["parameters"] as? [String: Any])
            #expect(try #require(parameters["required"] as? [String]).isEmpty)
            let properties = try #require(parameters["properties"] as? [String: Any])
            #expect(Set(properties.keys) == Set(optionalProperties.keys))
            #expect((properties["snapshot"] as? [String: Any])?["type"] as? String == "string")

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "pong"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt5, configuration: config, session: session)
            _ = try await provider.generateText(request: providerRequest)
        }
    }

    @Test
    func `Function call history encodes into Responses input`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        let toolArguments = [
            "location": AnyAgentToolValue(string: "San Francisco"),
            "unit": AnyAgentToolValue(string: "fahrenheit"),
        ]
        let toolCall = AgentToolCall(id: "call_123", name: "get_weather", arguments: toolArguments)
        let toolResult = AgentToolResult(
            toolCallId: "call_123",
            result: AnyAgentToolValue(object: [
                "temperature": AnyAgentToolValue(int: 68),
            ]),
            isError: false,
        )

        let providerRequest = ProviderRequest(
            messages: [
                .user("What is the weather?"),
                ModelMessage(role: .assistant, content: [.toolCall(toolCall)]),
                ModelMessage(role: .tool, content: [.toolResult(toolResult)]),
            ],
            settings: .init(maxTokens: 32),
        )

        try await withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let input = try #require(json?["input"] as? [[String: Any]])

            let functionCallEntry = input.first { ($0["type"] as? String) == "function_call" }
            #expect(functionCallEntry?["name"] as? String == "get_weather")
            #expect(functionCallEntry?["call_id"] as? String == "call_123")

            let outputEntry = input.first { ($0["type"] as? String) == "function_call_output" }
            #expect(outputEntry?["call_id"] as? String == "call_123")
            #expect((outputEntry?["output"] as? String)?.contains("temperature") == true)
            #expect(outputEntry?["status"] == nil)

            let messageRoles = input.compactMap { $0["role"] as? String }
            #expect(!messageRoles.contains("tool"))

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "Done"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt5, configuration: config, session: session)
            _ = try await provider.generateText(request: providerRequest)
        }
    }

    @Test
    func `Responses tool errors preserve output and omit status`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        let toolCall = AgentToolCall(id: "call_error", name: "read_file", arguments: [
            "path": AnyAgentToolValue(string: "/missing"),
        ])
        let toolResult = AgentToolResult.error(
            toolCallId: "call_error",
            error: "file not found",
        )

        let providerRequest = ProviderRequest(
            messages: [
                .user("read the file"),
                ModelMessage(role: .assistant, content: [.toolCall(toolCall)]),
                ModelMessage(role: .tool, content: [.toolResult(toolResult)]),
            ],
            settings: .init(maxTokens: 32),
        )

        try await withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let input = try #require(json?["input"] as? [[String: Any]])

            let outputEntry = input.first { ($0["type"] as? String) == "function_call_output" }
            #expect(outputEntry?["call_id"] as? String == "call_error")
            #expect(outputEntry?["output"] as? String == "file not found")
            #expect(outputEntry?["status"] == nil)

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "Handled"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt5, configuration: config, session: session)
            _ = try await provider.generateText(request: providerRequest)
        }
    }

    @Test
    func `Responses tool output is emitted even when result is empty`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        let toolCall = AgentToolCall(id: "call_empty", name: "shell", arguments: [
            "command": AnyAgentToolValue(string: "true"),
        ])
        let toolResult = AgentToolResult(
            toolCallId: "call_empty",
            result: AnyAgentToolValue(string: ""),
            isError: false,
        )

        let providerRequest = ProviderRequest(
            messages: [
                .user("run"),
                ModelMessage(role: .assistant, content: [.toolCall(toolCall)]),
                ModelMessage(role: .tool, content: [.toolResult(toolResult)]),
            ],
            settings: .init(maxTokens: 32),
        )

        try await withMockedSession { request in
            let body = try #require(Self.bodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let input = try #require(json?["input"] as? [[String: Any]])

            let functionCallEntry = input.first { ($0["type"] as? String) == "function_call" }
            #expect(functionCallEntry?["call_id"] as? String == "call_empty")

            let outputEntry = input.first { ($0["type"] as? String) == "function_call_output" }
            #expect(outputEntry?["call_id"] as? String == "call_empty")
            #expect(outputEntry?["output"] as? String == "ok")

            return NetworkMocking.jsonResponse(for: request, data: Self.responsesPayload(text: "Done"))
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt5, configuration: config, session: session)
            _ = try await provider.generateText(request: providerRequest)
        }
    }

    @Test
    func `Responses provider streams accumulated deltas`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            #expect(request.url?.path == "/v1/responses")
            let payload = Self.responsesStreamPayload(chunks: [
                Self.streamChunkJSON(content: "Hello", finishReason: nil),
                Self.streamChunkJSON(content: " world", finishReason: nil),
                Self.streamChunkJSON(content: nil, finishReason: "stop"),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt55, configuration: config, session: session)
            let stream = try await provider.streamText(request: self.sampleRequest)

            var collected = ""
            var receivedDone = false
            for try await delta in stream {
                switch delta.type {
                case .textDelta:
                    collected.append(delta.content ?? "")
                case .done:
                    receivedDone = true
                case .toolCall, .toolResult, .reasoning:
                    break
                }
            }

            #expect(collected == "Hello world")
            #expect(receivedDone)
        }
    }

    @Test
    func `Responses provider marks completed tool streams as tool calls`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            #expect(request.url?.path == "/v1/responses")
            let payload = Self.responsesStreamPayload(chunks: [
                Self.streamEventJSON([
                    "type": "response.output_item.added",
                    "item": [
                        "id": "item_1",
                        "type": "function_call",
                        "name": "lookup",
                    ],
                ]),
                Self.streamEventJSON([
                    "type": "response.function_call_arguments.done",
                    "item_id": "item_1",
                    "arguments": #"{"query":"weather"}"#,
                ]),
                Self.streamEventJSON(["type": "response.completed"]),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt55, configuration: config, session: session)
            let stream = try await provider.streamText(request: self.sampleRequest)

            var sawToolCall = false
            var finishReason: FinishReason?
            for try await delta in stream {
                if delta.type == .toolCall {
                    sawToolCall = true
                }
                if delta.type == .done {
                    finishReason = delta.finishReason
                }
            }

            #expect(sawToolCall)
            #expect(finishReason == .toolCalls)
        }
    }

    @Test
    func `Responses provider maps incomplete content filter stream finish reason`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            #expect(request.url?.path == "/v1/responses")
            let payload = Self.responsesStreamPayload(chunks: [
                Self.streamChunkJSON(content: "partial", finishReason: nil),
                Self.streamEventJSON([
                    "type": "response.incomplete",
                    "response": [
                        "incomplete_details": ["reason": "content_filter"],
                    ],
                ]),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt55, configuration: config, session: session)
            let stream = try await provider.streamText(request: self.sampleRequest)

            var collected = ""
            var finishReason: FinishReason?
            for try await delta in stream {
                if case .textDelta = delta.type {
                    collected.append(delta.content ?? "")
                }
                if delta.type == .done {
                    finishReason = delta.finishReason
                }
            }

            #expect(collected == "partial")
            #expect(finishReason == .contentFilter)
        }
    }

    @Test
    func `Responses provider maps refusal stream events to content filter`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            #expect(request.url?.path == "/v1/responses")
            let payload = Self.responsesStreamPayload(chunks: [
                Self.streamEventJSON([
                    "type": "response.refusal.delta",
                    "delta": "no",
                ]),
                Self.streamEventJSON(["type": "response.refusal.done"]),
                Self.streamEventJSON(["type": "response.completed"]),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt55, configuration: config, session: session)
            let stream = try await provider.streamText(request: self.sampleRequest)

            var finishReason: FinishReason?
            for try await delta in stream where delta.type == .done {
                finishReason = delta.finishReason
            }

            #expect(finishReason == .contentFilter)
        }
    }

    @Test
    func `Responses provider throws on failed stream event`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            #expect(request.url?.path == "/v1/responses")
            let payload = Self.responsesStreamPayload(chunks: [
                Self.streamEventJSON([
                    "type": "response.failed",
                    "response": [
                        "error": [
                            "message": "stream failed after partial output",
                        ],
                    ],
                ]),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt55, configuration: config, session: session)
            let stream = try await provider.streamText(request: self.sampleRequest)

            do {
                for try await _ in stream {}
                Issue.record("Expected stream failure")
            } catch let error as TachikomaError {
                guard case let .apiError(message) = error else {
                    Issue.record("Expected apiError, got \(error)")
                    return
                }
                #expect(message.contains("response.failed"))
                #expect(message.contains("stream failed after partial output"))
            }
        }
    }

    @Test
    func `Responses provider throws on error stream event`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            #expect(request.url?.path == "/v1/responses")
            let payload = Self.responsesStreamPayload(chunks: [
                Self.streamEventJSON([
                    "type": "error",
                    "message": "top-level stream error",
                ]),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .gpt55, configuration: config, session: session)
            let stream = try await provider.streamText(request: self.sampleRequest)

            do {
                for try await _ in stream {}
                Issue.record("Expected stream failure")
            } catch let error as TachikomaError {
                guard case let .apiError(message) = error else {
                    Issue.record("Expected apiError, got \(error)")
                    return
                }
                #expect(message.contains("error"))
                #expect(message.contains("top-level stream error"))
            }
        }
    }

    @Test
    func `chat-latest streams Responses event deltas`() async throws {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("live-openai", for: .openai)

        try await self.withMockedSession { request in
            #expect(request.url?.path == "/v1/responses")
            let payload = Self.responsesStreamPayload(chunks: [
                Self.streamChunkJSON(content: "Hello", finishReason: nil),
                Self.streamChunkJSON(content: " latest", finishReason: nil),
                Self.streamChunkJSON(content: nil, finishReason: "stop"),
            ])
            return NetworkMocking.streamResponse(for: request, data: payload)
        } operation: { session in
            let provider = try OpenAIResponsesProvider(model: .chatLatest, configuration: config, session: session)
            let stream = try await provider.streamText(request: self.sampleRequest)

            var collected = ""
            for try await delta in stream {
                if case .textDelta = delta.type {
                    collected.append(delta.content ?? "")
                }
            }

            #expect(collected == "Hello latest")
        }
    }

    private var sampleRequest: ProviderRequest {
        ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("ping")])],
            settings: .init(maxTokens: 32),
        )
    }

    private static func responsesPayload(text: String) -> Data {
        let dict: [String: Any] = [
            "id": "resp_test",
            "object": "response",
            "created_at": 1_700_000_000,
            "model": "gpt-5-mini",
            "status": "completed",
            "output": [
                [
                    "id": "msg_1",
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Hello from GPT-5: \(text)"]],
                ],
            ],
            "usage": [
                "input_tokens": 10,
                "output_tokens": 5,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }

        return data
    }

    private static func responsesStreamPayload(chunks: [String]) -> Data {
        var data = Data()
        for chunk in chunks {
            data.append("data: ".utf8Data())
            data.append(chunk.utf8Data())
            data.append("\n\n".utf8Data())
        }
        data.append("data: [DONE]\n\n".utf8Data())
        return data
    }

    private static func streamChunkJSON(content: String?, finishReason: String?) -> String {
        if let content {
            let chunk: [String: Any] = [
                "type": "response.output_text.delta",
                "delta": content,
            ]
            let data = try! JSONSerialization.data(withJSONObject: chunk)
            return String(data: data, encoding: .utf8)!
        }

        let chunk: [String: Any] = [
            "type": finishReason == nil ? "response.output_text.done" : "response.completed",
        ]
        let data = try! JSONSerialization.data(withJSONObject: chunk)
        return String(data: data, encoding: .utf8)!
    }

    private static func streamEventJSON(_ event: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: event)
        return String(data: data, encoding: .utf8)!
    }

    private static func openAIJWT(accountID: String, expiration: Date) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let payload: [String: Any] = [
            "exp": Int(expiration.timeIntervalSince1970),
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
        ]
        return "\(self.base64URLJSON(header)).\(self.base64URLJSON(payload)).signature"
    }

    private static func base64URLJSON(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func withMockedSession<T>(
        handler: @Sendable @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
        operation: (URLSession) async throws -> T,
    ) async rethrows
        -> T
    {
        let previousHandler = ResponsesTestURLProtocol.handler
        ResponsesTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        defer {
            session.invalidateAndCancel()
            ResponsesTestURLProtocol.handler = previousHandler
        }

        return try await operation(session)
    }

    private func openAIConfig() -> TachikomaConfiguration {
        TestHelpers.createTestConfiguration(
            apiKeys: ["openai": "test-key"],
            enableMockOverride: false,
        )
    }

    private func withIsolatedAuthState<T: Sendable>(
        _ body: @Sendable () async throws -> T,
    ) async rethrows
        -> T
    {
        try await TestEnvironmentMutex.shared.withLock {
            let originalProfileDirectory = TachikomaConfiguration.profileDirectoryName
            let profileDirectory = ".tachikoma-responses-auth-tests-\(UUID().uuidString)"
            let profilePath = NSString(string: "~/" + profileDirectory).expandingTildeInPath
            let previousIgnoreEnvironment = TKAuthManager.shared.setIgnoreEnvironment(false)
            let previousIgnoreCredentialStore = TKAuthManager.shared.setIgnoreCredentialStore(false)
            let environmentKeys = [
                "OPENAI_API_KEY",
                "OPENAI_ACCESS_TOKEN",
                "OPENAI_REFRESH_TOKEN",
                "OPENAI_ACCESS_EXPIRES",
            ]
            let savedEnvironment = Dictionary(uniqueKeysWithValues: environmentKeys.map { key in
                (key, getenv(key).map { String(cString: $0) })
            })

            TachikomaConfiguration.profileDirectoryName = profileDirectory
            environmentKeys.forEach { unsetenv($0) }
            try? FileManager.default.removeItem(atPath: profilePath)

            defer {
                for key in environmentKeys {
                    if case let value?? = savedEnvironment[key] {
                        setenv(key, value, 1)
                    } else {
                        unsetenv(key)
                    }
                }
                TKAuthManager.shared.setIgnoreEnvironment(previousIgnoreEnvironment)
                TKAuthManager.shared.setIgnoreCredentialStore(previousIgnoreCredentialStore)
                TachikomaConfiguration.profileDirectoryName = originalProfileDirectory
                try? FileManager.default.removeItem(atPath: profilePath)
            }

            return try await body()
        }
    }
}

private final class ResponsesTestURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerLock = NSLock()
    private nonisolated(unsafe) static var _handler: Handler?

    static var handler: Handler? {
        get { handlerLock.withLock { _handler } }
        set { handlerLock.withLock { _handler = newValue } }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            let error = URLError(.resourceUnavailable)
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Helper to skip tests when API keys aren't available
struct TestSkipped: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
#endif
