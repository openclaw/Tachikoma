import Foundation
import Testing
@testable import Tachikoma
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Linux)
@Suite(.disabled("URLProtocol mocking unavailable on Linux"))
struct ProviderEndToEndTests {}
#else

@Suite(.serialized, .enabled(if: !_isLiveSuite))
struct ProviderEndToEndTests {
    // MARK: - OpenAI Responses (GPT-5)

    @Test
    func `OpenAI Responses provider returns text`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            self.expectPath(
                request,
                endsWithAny: ["/responses", "/chat/completions"],
                allowAudioTranscriptions: true,
            )
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.openAIResponsesPayload(text: "Hello from GPT-5"),
            )
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("sk-live-openai", for: .openai)
            }
            let provider = try OpenAIResponsesProvider(model: .gpt5Mini, configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text.contains("GPT-5"))
            #expect(response.usage?.outputTokens == 5)
        }
    }

    // MARK: - OpenAI Chat Provider

    @Test
    func `OpenAI chat provider hits /chat/completions`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            self.expectPath(request, endsWith: "/chat/completions")
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.chatCompletionPayload(text: "OpenAI chat success"),
            )
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("sk-live-openai", for: .openai)
            }
            let provider = try OpenAIProvider(model: .gpt55, configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "OpenAI chat success")
        }
    }

    // MARK: - Anthropic

    @Test
    func `Anthropic provider decodes Claude responses`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            self.expectPath(request, endsWith: "/messages")
            return NetworkMocking.jsonResponse(for: request, data: Self.anthropicPayload(text: "Claude says hello"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-anthropic", for: .anthropic)
            }
            let provider = try AnthropicProvider(model: .sonnet46, configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "Claude says hello")
        }
    }

    @Test
    func `Anthropic provider preserves complete source tool schemas`() async throws {
        let task = AgentToolParameterProperty(name: "task", type: .string, description: "Task")
        let sourceSchema = AnyAgentToolValue(object: [
            "type": AnyAgentToolValue(string: "object"),
            "additionalProperties": AnyAgentToolValue(bool: false),
            "properties": AnyAgentToolValue(object: [
                "task": AnyAgentToolValue(object: [
                    "type": AnyAgentToolValue(string: "string"),
                ]),
            ]),
            "required": AnyAgentToolValue(array: [AnyAgentToolValue(string: "task")]),
            "allOf": AnyAgentToolValue(array: [
                AnyAgentToolValue(object: [
                    "not": AnyAgentToolValue(object: [
                        "required": AnyAgentToolValue(array: [AnyAgentToolValue(string: "forbidden")]),
                    ]),
                ]),
            ]),
        ])
        let tool = AgentTool(
            name: "run",
            description: "Run task",
            parameters: AgentToolParameters(
                properties: ["task": task],
                required: ["task"],
                sourceSchema: sourceSchema,
            ),
        ) { _ in
            AnyAgentToolValue(string: "unused")
        }
        let request = ProviderRequest(
            messages: [.user("Run it")],
            tools: [tool],
            settings: .init(maxTokens: 32),
        )

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            let schema = try #require(tools.first?["input_schema"] as? [String: Any])

            #expect(schema["additionalProperties"] as? Bool == false)
            #expect((schema["allOf"] as? [[String: Any]])?.count == 1)
            #expect(schema["required"] as? [String] == ["task"])
            return NetworkMocking.jsonResponse(for: request, data: Self.anthropicPayload(text: "Done"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-anthropic", for: .anthropic)
            }
            let provider = try AnthropicProvider(model: .sonnet46, configuration: config)
            _ = try await provider.generateText(request: request)
        }
    }

    // MARK: - Google Gemini

    @Test
    func `Google provider processes streamed SSE content`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.path.contains(":streamGenerateContent") == true)
            return NetworkMocking.streamResponse(for: request, data: Self.googleStreamPayload(text: "Gemini streaming"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("google-live", for: .google)
            }
            let provider = try GoogleProvider(model: .gemini25Flash, configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text.contains("Gemini streaming"))
        }
    }

    @Test
    func `Google provider encodes tool results as user function responses`() async throws {
        let toolCall = AgentToolCall(
            id: "call_weather",
            name: "get_weather",
            arguments: ["location": AnyAgentToolValue(string: "Vienna")],
        )
        let toolResult = AgentToolResult.success(
            toolCallId: "call_weather",
            result: AnyAgentToolValue(object: ["temperature": AnyAgentToolValue(int: 21)]),
        )
        let providerRequest = ProviderRequest(
            messages: [
                .user("Weather?"),
                ModelMessage(role: .assistant, content: [.text("Checking."), .toolCall(toolCall)]),
                ModelMessage(role: .tool, content: [.toolResult(toolResult)]),
            ],
            settings: .init(maxTokens: 32),
        )

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let contents = try #require(json["contents"] as? [[String: Any]])

            #expect(contents.count == 3)
            #expect(contents.compactMap { $0["role"] as? String } == ["user", "model", "user"])

            let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
            #expect(modelParts.count == 2)
            #expect(modelParts[1]["functionCall"] != nil)

            let toolParts = try #require(contents[2]["parts"] as? [[String: Any]])
            let functionResponse = try #require(toolParts.first?["functionResponse"] as? [String: Any])
            #expect(functionResponse["id"] as? String == "call_weather")
            #expect(functionResponse["name"] as? String == "get_weather")

            return NetworkMocking.streamResponse(for: request, data: Self.googleStreamPayload(text: "Done"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("google-live", for: .google)
            }
            let provider = try GoogleProvider(model: .gemini25Flash, configuration: config)
            let response = try await provider.generateText(request: providerRequest)
            #expect(response.text.contains("Done"))
        }
    }

    @Test
    func `Google provider drops orphan required tool parameters`() async throws {
        let tool = AgentTool(
            name: "search",
            description: "Search files",
            parameters: AgentToolParameters(
                properties: [
                    "query": AgentToolParameterProperty(
                        name: "query",
                        type: .string,
                        description: "Search query",
                    ),
                ],
                required: ["query", "mode"],
            ),
        ) { _ in
            AnyAgentToolValue(string: "ok")
        }
        let orphanOnlyTool = AgentTool(
            name: "noop",
            description: "No-op",
            parameters: AgentToolParameters(
                properties: [
                    "reason": AgentToolParameterProperty(
                        name: "reason",
                        type: .string,
                        description: "Reason",
                    ),
                ],
                required: ["missing"],
            ),
        ) { _ in
            AnyAgentToolValue(string: "ok")
        }

        let providerRequest = ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("Find it")])],
            tools: [tool, orphanOnlyTool],
            settings: .init(maxTokens: 32),
        )

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            let declarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
            var parametersByName: [String: [String: Any]] = [:]
            for declaration in declarations {
                let name = try #require(declaration["name"] as? String)
                let parameters = try #require(declaration["parameters"] as? [String: Any])
                #expect(!parametersByName.keys.contains(name))
                parametersByName[name] = parameters
            }
            let searchParameters = try #require(parametersByName["search"])
            let noopParameters = try #require(parametersByName["noop"])

            #expect(searchParameters["properties"] is [String: Any])
            #expect(searchParameters["required"] as? [String] == ["query"])
            #expect(noopParameters["properties"] is [String: Any])
            #expect(noopParameters["required"] == nil)

            return NetworkMocking.streamResponse(for: request, data: Self.googleStreamPayload(text: "Done"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("google-live", for: .google)
            }
            let provider = try GoogleProvider(model: .gemini25Flash, configuration: config)
            let response = try await provider.generateText(request: providerRequest)
            #expect(response.text.contains("Done"))
        }
    }

    @Test
    func `All provider families preserve canonical nested tool schemas`() async throws {
        let providerRequest = Self.schemaParityRequest

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            let schema = try #require(tools.first?["parameters"] as? [String: Any])
            try self.expectSchemaParity(schema)
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.openAIResponsesPayload(text: "OpenAI schema ok"),
            )
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("sk-live-openai", for: .openai)
            }
            let provider = try OpenAIResponsesProvider(model: .gpt5Mini, configuration: config)
            _ = try await provider.generateText(request: providerRequest)
        }

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            let function = try #require(tools.first?["function"] as? [String: Any])
            try self.expectSchemaParity(#require(function["parameters"] as? [String: Any]))
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.chatCompletionPayload(text: "Compatible schema ok"),
            )
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-compatible", for: "openai_compatible")
            }
            let provider = try OpenAICompatibleProvider(
                modelId: "schema-model",
                baseURL: "https://compatible.test",
                configuration: config,
            )
            _ = try await provider.generateText(request: providerRequest)
        }

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            try self.expectSchemaParity(#require(tools.first?["input_schema"] as? [String: Any]))
            return NetworkMocking.jsonResponse(for: request, data: Self.anthropicPayload(text: "Anthropic schema ok"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-anthropic", for: .anthropic)
            }
            let provider = try AnthropicProvider(model: .sonnet46, configuration: config)
            _ = try await provider.generateText(request: providerRequest)
        }

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            let declarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
            try self.expectSchemaParity(#require(declarations.first?["parameters"] as? [String: Any]))
            return NetworkMocking.streamResponse(for: request, data: Self.googleStreamPayload(text: "Google schema ok"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("google-live", for: .google)
            }
            let provider = try GoogleProvider(model: .gemini25Flash, configuration: config)
            _ = try await provider.generateText(request: providerRequest)
        }

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            let function = try #require(tools.first?["function"] as? [String: Any])
            try self.expectSchemaParity(#require(function["parameters"] as? [String: Any]))
            return NetworkMocking.jsonResponse(for: request, data: Self.ollamaPayload(text: "Ollama schema ok"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            _ = try await provider.generateText(request: providerRequest)
        }

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let tools = try #require(json["tools"] as? [[String: Any]])
            let function = try #require(tools.first?["function"] as? [String: Any])
            try self.expectSchemaParity(#require(function["parameters"] as? [String: Any]))
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.chatCompletionPayload(text: "LM Studio schema ok"),
            )
        } operation: {
            let provider = LMStudioProvider(
                baseURL: "http://localhost:1234/v1",
                modelId: "local",
                sessionConfiguration: Self.mockedSessionConfiguration(),
            )
            _ = try await provider.generateText(request: providerRequest)
        }
    }

    // MARK: - OpenAI-compatible providers

    @Test
    func `Mistral provider uses OpenAI-compatible flow`() async throws {
        try await self.assertOpenAICompatibleProvider(.mistral(.smallLatest), provider: .mistral)
    }

    @Test
    func `Groq provider uses OpenAI-compatible flow`() async throws {
        try await self.assertOpenAICompatibleProvider(.groq(.llama318b), provider: .groq)
    }

    @Test
    func `Grok provider uses OpenAI-compatible flow`() async throws {
        try await self.assertOpenAICompatibleProvider(.grok(.grok43), provider: .grok)
    }

    @Test
    func `All Grok catalog models share the same OpenAI-compatible flow`() async throws {
        for grokModel in Model.Grok.allCases {
            try await self.assertOpenAICompatibleProvider(.grok(grokModel), provider: .grok)
        }
    }

    // MARK: - Ollama

    @Test
    func `Ollama provider handles local responses`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            self.expectPath(request, endsWith: "/api/chat")
            let body = try #require(self.bodyData(from: request))
            let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
            #expect(decoded.think == nil)
            return NetworkMocking.jsonResponse(for: request, data: Self.ollamaPayload(text: "Ollama local reply"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            #expect(provider.isResponseCacheSafe == false)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "Ollama local reply")
            #expect(response.finishReason == .stop)
        }
    }

    @Test
    func `Ollama provider normalizes documented and prefixed API base paths`() async throws {
        let cases = [
            ("https://ollama.example.test/api", "/api/chat"),
            ("https://ollama.example.test/api/", "/api/chat"),
            ("https://ollama.example.test/api/chat", "/api/chat"),
            ("https://ollama.example.test/prefix/api", "/prefix/api/chat"),
            ("https://ollama.example.test/prefix", "/prefix/api/chat"),
        ]

        for (baseURL, expectedPath) in cases {
            try await NetworkMocking.withMockedNetwork { request in
                #expect(request.url?.path == expectedPath)
                return NetworkMocking.jsonResponse(for: request, data: Self.ollamaPayload(text: "ok"))
            } operation: {
                let config = Self.makeConfiguration { config in
                    config.setBaseURL(baseURL, for: .ollama)
                }
                let provider = try OllamaProvider(model: .llama33, configuration: config)
                _ = try await provider.generateText(request: Self.basicRequest)
            }
        }
    }

    @Test(arguments: [
        LanguageModel.Ollama.deepseekR18b,
        LanguageModel.Ollama.custom("qwen3:8b"),
    ])
    func `Ollama provider enables thinking for known boolean models`(model: LanguageModel.Ollama) async throws {
        let request = ProviderRequest(
            messages: Self.basicRequest.messages,
            settings: GenerationSettings(reasoningEffort: .low),
        )

        try await NetworkMocking.withMockedNetwork { urlRequest in
            let body = try #require(self.bodyData(from: urlRequest))
            let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
            #expect(decoded.think == .enabled(true))
            return NetworkMocking.jsonResponse(for: urlRequest, data: Self.ollamaPayload(text: "Reasoned"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try OllamaProvider(model: model, configuration: config)
            _ = try await provider.generateText(request: request)
        }
    }

    @Test
    func `Ollama provider omits thinking for unsupported built-in models`() async throws {
        let request = ProviderRequest(
            messages: Self.basicRequest.messages,
            settings: GenerationSettings(reasoningEffort: .low),
        )

        try await NetworkMocking.withMockedNetwork { urlRequest in
            let body = try #require(self.bodyData(from: urlRequest))
            let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
            #expect(decoded.think == nil)
            return NetworkMocking.jsonResponse(for: urlRequest, data: Self.ollamaPayload(text: "Plain reply"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            _ = try await provider.generateText(request: request)
        }
    }

    @Test
    func `Ollama reasoning identity fails closed for API keys and session headers`() throws {
        let baseURL = "https://ollama.example.test/v1"
        let firstConfiguration = Self.makeConfiguration { config in
            config.setBaseURL(baseURL, for: .ollama)
            config.setAPIKey("api-key-one", for: .ollama)
        }
        let rotatedKeyConfiguration = Self.makeConfiguration { config in
            config.setBaseURL(baseURL, for: .ollama)
            config.setAPIKey("api-key-two", for: .ollama)
        }
        let firstSessionConfiguration = URLSessionConfiguration.ephemeral
        firstSessionConfiguration.httpAdditionalHeaders = ["X-Tenant": "tenant-one"]
        let rotatedHeaderConfiguration = URLSessionConfiguration.ephemeral
        rotatedHeaderConfiguration.httpAdditionalHeaders = ["X-Tenant": "tenant-two"]
        let firstSession = URLSession(configuration: firstSessionConfiguration)
        let rotatedKeySession = URLSession(configuration: firstSessionConfiguration)
        let rotatedHeaderSession = URLSession(configuration: rotatedHeaderConfiguration)
        defer {
            firstSession.invalidateAndCancel()
            rotatedKeySession.invalidateAndCancel()
            rotatedHeaderSession.invalidateAndCancel()
        }

        let first = try OllamaProvider(
            model: .llama33,
            configuration: firstConfiguration,
            urlSession: firstSession,
        )
        let rotatedKey = try OllamaProvider(
            model: .llama33,
            configuration: rotatedKeyConfiguration,
            urlSession: rotatedKeySession,
        )
        let rotatedHeader = try OllamaProvider(
            model: .llama33,
            configuration: firstConfiguration,
            urlSession: rotatedHeaderSession,
        )

        #expect(first.reasoningReplayIdentity == nil)
        #expect(rotatedKey.reasoningReplayIdentity == nil)
        #expect(rotatedHeader.reasoningReplayIdentity == nil)
        #expect(first.isResponseCacheSafe == false)
        #expect(rotatedKey.isResponseCacheSafe == false)
        #expect(rotatedHeader.isResponseCacheSafe == false)
    }

    @Test
    func `Ollama provider sends configured API key as bearer auth`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ollama-test-key")
            return NetworkMocking.jsonResponse(for: request, data: Self.ollamaPayload(text: "Authenticated"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("https://ollama.example.test", for: .ollama)
                config.setAPIKey("ollama-test-key", for: .ollama)
            }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "Authenticated")
        }
    }

    @Test
    func `Ollama stream clamps GPT OSS thinking effort to a supported level`() async throws {
        let payload = Data("""
        {"model":"gpt-oss:20b","message":{"role":"assistant","content":"answer"},"done":true,"done_reason":"stop"}

        """.utf8)
        let request = ProviderRequest(
            messages: Self.basicRequest.messages,
            settings: GenerationSettings(reasoningEffort: .xhigh),
        )

        try await NetworkMocking.withMockedNetwork { urlRequest in
            let body = try #require(self.bodyData(from: urlRequest))
            let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
            #expect(decoded.think == .level("high"))
            return NetworkMocking.streamResponse(for: urlRequest, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try Self.mockedOllamaProvider(model: .gptOSS20B, configuration: config)
            let stream = try await provider.streamText(request: request)
            for try await _ in stream {}
        }
    }

    @Test
    func `Ollama stream clamps GPT OSS maximum thinking effort to high`() async throws {
        let payload = Data("""
        {"model":"gpt-oss:20b","message":{"role":"assistant","content":"answer"},"done":true,"done_reason":"stop"}

        """.utf8)
        let request = ProviderRequest(
            messages: Self.basicRequest.messages,
            settings: GenerationSettings(reasoningEffort: .max),
        )

        try await NetworkMocking.withMockedNetwork { urlRequest in
            let body = try #require(self.bodyData(from: urlRequest))
            let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
            #expect(decoded.think == .level("high"))
            return NetworkMocking.streamResponse(for: urlRequest, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try Self.mockedOllamaProvider(model: .gptOSS20B, configuration: config)
            let stream = try await provider.streamText(request: request)
            for try await _ in stream {}
        }
    }

    @Test
    func `Ollama provider encodes vision images as messages[].images`() async throws {
        let imageBase64 = Data("test-image".utf8).base64EncodedString()
        let image = ModelMessage.ContentPart.ImageContent(data: imageBase64, mimeType: "image/png")

        let request = ProviderRequest(
            messages: [
                ModelMessage.user(text: "What's in this image?", images: [image]),
            ],
            tools: nil,
            settings: GenerationSettings(maxTokens: 64, temperature: 0.0),
        )

        try await NetworkMocking.withMockedNetwork { urlRequest in
            self.expectPath(urlRequest, endsWith: "/api/chat")

            let body = self.bodyData(from: urlRequest)
            #expect(body != nil)
            if let body {
                let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
                #expect(decoded.model == "qwen2.5vl:latest")
                #expect(decoded.stream == false)
                #expect(decoded.messages.count == 1)
                #expect(decoded.messages.first?.role == "user")
                #expect(decoded.messages.first?.content == "What's in this image?")
                #expect(decoded.messages.first?.images == [imageBase64])
            }

            return NetworkMocking.jsonResponse(for: urlRequest, data: Self.ollamaPayload(text: "Vision ok"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }

            let provider = try OllamaProvider(model: .custom("qwen2.5vl:latest"), configuration: config)
            let response = try await provider.generateText(request: request)
            #expect(response.text == "Vision ok")
        }
    }

    @Test
    func `Ollama provider replays tool history and recursive schemas`() async throws {
        let toolCall = AgentToolCall(
            id: "call_plan",
            name: "run_plan",
            arguments: [
                "metadata": AnyAgentToolValue(object: [
                    "attempt": AnyAgentToolValue(int: 2),
                    "note": AnyAgentToolValue(null: ()),
                ]),
                "steps": AnyAgentToolValue(array: [
                    AnyAgentToolValue(string: "inspect"),
                    AnyAgentToolValue(int: 3),
                    AnyAgentToolValue(bool: false),
                ]),
            ],
        )
        let result = AgentToolResult.success(
            toolCallId: toolCall.id,
            result: AnyAgentToolValue(object: [
                "completed": AnyAgentToolValue(bool: true),
                "outputs": AnyAgentToolValue(array: [
                    AnyAgentToolValue(string: "alpha"),
                    AnyAgentToolValue(int: 4),
                ]),
            ]),
        )
        let tool = AgentTool(
            name: "run_plan",
            description: "Run a plan",
            parameters: AgentToolParameters(
                properties: [
                    "steps": AgentToolParameterProperty(
                        name: "steps",
                        type: .array,
                        description: "Plan steps",
                        items: AgentToolParameterItems(type: "object", description: "One step"),
                    ),
                ],
                required: ["steps"],
            ),
        ) { _ in
            AnyAgentToolValue(string: "unused")
        }
        let providerRequest = ProviderRequest(
            messages: [
                .user("Run it"),
                ModelMessage(role: .assistant, content: [.text("Working."), .toolCall(toolCall)]),
                ModelMessage(role: .tool, content: [.toolResult(result)]),
            ],
            tools: [tool],
            settings: .init(maxTokens: 32),
        )

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: Any]])

            #expect(messages.count == 3)
            let assistantCalls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
            #expect(assistantCalls.first?["type"] as? String == "function")
            let function = try #require(assistantCalls.first?["function"] as? [String: Any])
            #expect(function["index"] as? Int == 0)
            #expect(function["name"] as? String == "run_plan")
            let arguments = try #require(function["arguments"] as? [String: Any])
            let metadata = try #require(arguments["metadata"] as? [String: Any])
            #expect(metadata["attempt"] as? Int == 2)
            #expect(metadata["note"] is NSNull)
            let steps = try #require(arguments["steps"] as? [Any])
            #expect(steps[0] as? String == "inspect")
            #expect(steps[1] as? Int == 3)
            #expect(steps[2] as? Bool == false)

            #expect(messages[2]["role"] as? String == "tool")
            #expect(messages[2]["tool_name"] as? String == "run_plan")
            let resultText = try #require(messages[2]["content"] as? String)
            let resultData = try #require(resultText.data(using: .utf8))
            let resultJSON = try #require(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
            #expect(resultJSON["completed"] as? Bool == true)
            #expect(resultJSON["outputs"] as? [AnyHashable] == ["alpha", 4])

            let tools = try #require(json["tools"] as? [[String: Any]])
            let toolFunction = try #require(tools.first?["function"] as? [String: Any])
            let parameters = try #require(toolFunction["parameters"] as? [String: Any])
            let properties = try #require(parameters["properties"] as? [String: Any])
            let stepsSchema = try #require(properties["steps"] as? [String: Any])
            let items = try #require(stepsSchema["items"] as? [String: Any])
            #expect(items["type"] as? String == "object")
            #expect(items["description"] as? String == "One step")

            return NetworkMocking.jsonResponse(for: request, data: Self.ollamaPayload(text: "Finished"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            let response = try await provider.generateText(request: providerRequest)
            #expect(response.text == "Finished")
        }
    }

    @Test
    func `Ollama provider marks native tool responses as tool calls`() async throws {
        let payload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"","tool_calls":[{"function":{
        "index":0,"name":"lookup","arguments":{"filters":{"active":true},"limit":2}}}]},"done":true}
        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.jsonResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.finishReason == .toolCalls)
            #expect(response.toolCalls?.first?.name == "lookup")
            #expect(response.toolCalls?.first?.arguments["filters"]?.objectValue?["active"]?.boolValue == true)
            #expect(response.toolCalls?.first?.arguments["limit"]?.intValue == 2)
        }
    }

    @Test(arguments: [
        ("length", FinishReason.length),
        ("unexpected_reason", FinishReason.other),
    ])
    func `Ollama provider preserves abnormal done reasons on tool responses`(
        doneReason: String,
        expected: FinishReason,
    ) async throws {
        let payload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"","tool_calls":[
        {"function":{"index":0,"name":"lookup","arguments":{}}}]},"done":true,"done_reason":"\(
            doneReason
        )"}
        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.jsonResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.finishReason == expected)
            #expect(response.toolCalls?.first?.name == "lookup")
        }
    }

    @Test(arguments: [
        ("length", FinishReason.length),
        ("unexpected_reason", FinishReason.other),
    ])
    func `Ollama abnormal tool responses are not executed`(
        doneReason: String,
        expected: FinishReason,
    ) async throws {
        let payload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"","tool_calls":[
        {"function":{"index":0,"name":"lookup","arguments":{}}}]},"done":true,"done_reason":"\(
            doneReason
        )"}
        """.utf8)
        let probe = ToolInvocationProbe()
        let tool = AgentTool(
            name: "lookup",
            description: "Lookup",
            parameters: AgentToolParameters(),
        ) { _ in
            await probe.recordInvocation()
            return AnyAgentToolValue(string: "should not run")
        }

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.jsonResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let result = try await generateText(
                model: .ollama(.llama33),
                messages: [.user("Look it up")],
                tools: [tool],
                maxSteps: 2,
                configuration: config,
            )

            let invocationCount = await probe.invocationCount
            #expect(invocationCount == 0)
            #expect(result.finishReason == expected)
            #expect(result.steps.first?.toolCalls.first?.name == "lookup")
            #expect(result.steps.first?.toolResults.isEmpty == true)
            #expect(result.messages.flatMap(\.content).contains { part in
                if case .toolCall = part {
                    true
                } else {
                    false
                }
            } == false)
        }
    }

    @Test
    func `Ollama provider requires terminal done status`() async throws {
        let payload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"partial"},"done":false}
        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.jsonResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            do {
                _ = try await provider.generateText(request: Self.basicRequest)
                Issue.record("Expected incomplete Ollama response failure")
            } catch {
                #expect(error.localizedDescription.contains("before terminal done"))
            }
        }
    }

    @Test(arguments: [
        ("length", FinishReason.length),
        ("unexpected_reason", FinishReason.other),
    ])
    func `Ollama provider maps done reasons`(doneReason: String, expected: FinishReason) async throws {
        let payload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"partial"},"done":true,"done_reason":"\(
            doneReason
        )"}
        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.jsonResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.finishReason == expected)
        }
    }

    @Test(arguments: [
        ("length", FinishReason.length),
        ("unexpected_reason", FinishReason.other),
    ])
    func `Ollama stream maps done reasons and thinking`(doneReason: String, expected: FinishReason) async throws {
        let payload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"","thinking":"considering"},"done":false}
        {"model":"llama3.3","message":{"role":"assistant","content":"partial"},"done":true,"done_reason":"\(
            doneReason
        )"}

        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try Self.mockedOllamaProvider(configuration: config)
            let stream = try await provider.streamText(request: Self.basicRequest)

            var thinking = ""
            var finishReason: FinishReason?
            for try await delta in stream {
                if delta.type == .reasoning {
                    thinking.append(delta.content ?? "")
                    #expect(delta.reasoningType == "ollama_thinking")
                } else if delta.type == .done {
                    finishReason = delta.finishReason
                }
            }

            #expect(thinking == "considering")
            #expect(finishReason == expected)
        }
    }

    @Test
    func `Ollama thinking survives response history replay`() async throws {
        let config = Self.makeConfiguration { config in
            config.setBaseURL("http://localhost:11434", for: .ollama)
        }
        let firstPayload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","thinking":"private plan","content":"answer"},
        "done":true,"done_reason":"stop"}
        """.utf8)
        let first = try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.jsonResponse(for: request, data: firstPayload)
        } operation: {
            try await generateText(
                model: .ollama(.llama33),
                messages: [.user("Question")],
                configuration: config,
            )
        }

        let thinkingMessage = try #require(first.messages.first { $0.channel == .thinking })
        #expect(thinkingMessage.content == [.text("private plan")])
        #expect(thinkingMessage.metadata?.customData?["ollama.thinking"] == "private plan")

        let replayMessages = first.messages + [.user("Follow up")]
        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
            let replayedAssistant = try #require(decoded.messages.first { $0.role == "assistant" })
            #expect(replayedAssistant.thinking == "private plan")
            #expect(replayedAssistant.content == "answer")
            return NetworkMocking.jsonResponse(for: request, data: Self.ollamaPayload(text: "next"))
        } operation: {
            _ = try await generateText(
                model: .ollama(.llama33),
                messages: replayMessages,
                configuration: config,
            )
        }
    }

    @Test
    func `Ollama direct provider only replays endpoint-bound thinking`() async throws {
        let config = Self.makeConfiguration { config in
            config.setBaseURL("http://localhost:11434", for: .ollama)
        }
        let provider = try OllamaProvider(model: .llama33, configuration: config)
        let endpointIdentity = try #require(provider.reasoningReplayIdentity)
        let boundThinking = ModelMessage(
            role: .assistant,
            content: [.text("bound plan")],
            channel: .thinking,
            metadata: .init(customData: [
                "ollama.thinking": "bound plan",
                "tachikoma.reasoning.provider": "ollama",
                "tachikoma.reasoning.model": provider.modelId,
                "tachikoma.reasoning.base_url": endpointIdentity,
            ]),
        )
        let unboundThinking = ModelMessage(
            role: .assistant,
            content: [.text("unbound plan")],
            channel: .thinking,
        )

        try await NetworkMocking.withMockedNetwork { request in
            let body = try #require(self.bodyData(from: request))
            let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
            #expect(decoded.messages.contains { $0.thinking == "bound plan" })
            #expect(decoded.messages.contains { $0.thinking == "unbound plan" } == false)
            return NetworkMocking.jsonResponse(for: request, data: Self.ollamaPayload(text: "next"))
        } operation: {
            _ = try await provider.generateText(request: ProviderRequest(messages: [
                .user("Question"),
                unboundThinking,
                boundThinking,
                .assistant("answer"),
                .user("Follow up"),
            ]))
        }
    }

    @Test
    func `Ollama reasoning identity stays pinned to the instantiated provider`() async throws {
        let firstURL = "https://first.example.test/ollama"
        let changedURL = "https://changed.example.test/ollama"
        let config = Self.makeConfiguration { config in
            config.setBaseURL(firstURL, for: .ollama)
        }
        let firstPayload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","thinking":"first plan","content":"answer"},
        "done":true,"done_reason":"stop"}
        """.utf8)
        let first = try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.host == "first.example.test")
            return NetworkMocking.jsonResponse(for: request, data: firstPayload)
        } operation: {
            try await generateText(
                model: .ollama(.llama33),
                messages: [.user("Question")],
                configuration: config,
            )
        }

        config.setProviderFactoryOverride { model, configuration in
            guard case let .ollama(ollamaModel) = model else {
                throw TachikomaError.invalidConfiguration("Expected Ollama model")
            }
            let provider = try Self.mockedOllamaProvider(model: ollamaModel, configuration: configuration)
            configuration.setBaseURL(changedURL, for: .ollama)
            return provider
        }

        let nextPayload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","thinking":"next plan","content":"next"},
        "done":true,"done_reason":"stop"}
        """.utf8)
        let replayMessages = first.messages + [.user("Follow up")]
        let next = try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.host == "first.example.test")
            let body = try #require(self.bodyData(from: request))
            let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
            let replayedAssistant = try #require(decoded.messages.first { $0.role == "assistant" })
            #expect(replayedAssistant.thinking == "first plan")
            return NetworkMocking.jsonResponse(for: request, data: nextPayload)
        } operation: {
            try await generateText(
                model: .ollama(.llama33),
                messages: replayMessages,
                configuration: config,
            )
        }

        #expect(config.getBaseURL(for: .ollama) == changedURL)
        let nextThinking = try #require(next.messages.last { $0.content == [.text("next plan")] })
        #expect(nextThinking.metadata?.customData?["tachikoma.reasoning.base_url"] == ReasoningEndpointIdentity
            .canonical(firstURL))
    }

    @Test
    func `Ollama credential changes prevent thinking replay without leaking its URL`() async throws {
        try await TestEnvironmentMutex.shared.withLock {
            let environmentKey = "PEEKABOO_OLLAMA_BASE_URL"
            let previousValue = getenv(environmentKey).map { String(cString: $0) }
            defer {
                if let previousValue {
                    setenv(environmentKey, previousValue, 1)
                } else {
                    unsetenv(environmentKey)
                }
            }

            let firstURL = "https://ollama-user:private-secret@first.example.test/v1?token=hidden#local"
            let secondURL = "https://ollama-user:rotated-secret@first.example.test/v1?token=hidden#changed"
            setenv(environmentKey, firstURL, 1)

            let config = Self.makeConfiguration { _ in }
            let provider = try OllamaProvider(model: .llama33, configuration: config)
            #expect(provider.baseURL == firstURL)

            let explicitConfig = Self.makeConfiguration { configuration in
                configuration.setBaseURL("https://explicit.example.test", for: .ollama)
            }
            let explicitProvider = try OllamaProvider(model: .llama33, configuration: explicitConfig)
            #expect(explicitProvider.baseURL == "https://explicit.example.test")

            let firstPayload = Data("""
            {"model":"llama3.3","message":{"role":"assistant","thinking":"private plan","content":"answer"},
            "done":true,"done_reason":"stop"}
            """.utf8)
            let first = try await NetworkMocking.withMockedNetwork { request in
                #expect(request.url?.host == "first.example.test")
                #expect(request.url?.path == "/v1/api/chat")
                #expect(request.url?.query == "token=hidden")
                #expect(request.url?.fragment == nil)
                return NetworkMocking.jsonResponse(for: request, data: firstPayload)
            } operation: {
                try await generateText(
                    model: .ollama(.llama33),
                    messages: [.user("Question")],
                    settings: GenerationSettings(reasoningEffort: .medium),
                    configuration: config,
                )
            }

            let thinkingMessage = try #require(first.messages.first { $0.channel == .thinking })
            #expect(thinkingMessage.metadata?.customData?["tachikoma.reasoning.base_url"] == nil)
            #expect(thinkingMessage.metadata?.customData?["ollama.thinking"] == nil)
            #expect(ReasoningEndpointIdentity.canonical(firstURL) == nil)
            #expect(ReasoningEndpointIdentity.canonical(secondURL) == nil)

            setenv(environmentKey, secondURL, 1)
            let replayMessages = first.messages + [.user("Follow up")]
            try await NetworkMocking.withMockedNetwork { request in
                #expect(request.url?.host == "first.example.test")
                #expect(request.url?.path == "/v1/api/chat")
                #expect(request.url?.query == "token=hidden")
                let body = try #require(self.bodyData(from: request))
                let decoded = try JSONDecoder().decode(OllamaChatRequest.self, from: body)
                let replayedAssistant = try #require(decoded.messages.first { $0.role == "assistant" })
                #expect(replayedAssistant.content == "answer")
                #expect(replayedAssistant.thinking == nil)
                return NetworkMocking.jsonResponse(for: request, data: Self.ollamaPayload(text: "next"))
            } operation: {
                _ = try await generateText(
                    model: .ollama(.llama33),
                    messages: replayMessages,
                    settings: GenerationSettings(reasoningEffort: .medium),
                    configuration: config,
                )
            }
        }
    }

    @Test
    func `Ollama stream gives tool calls precedence over stop`() async throws {
        let payload = Data("""
        {"model":"m","message":{"tool_calls":[{"function":{"name":"lookup"}}]},"done":false}
        {"model":"llama3.3","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}

        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try Self.mockedOllamaProvider(configuration: config)
            let stream = try await provider.streamText(request: Self.basicRequest)

            var toolName: String?
            var finishReason: FinishReason?
            for try await delta in stream {
                if delta.type == .toolCall {
                    toolName = delta.toolCall?.name
                } else if delta.type == .done {
                    finishReason = delta.finishReason
                }
            }
            #expect(toolName == "lookup")
            #expect(finishReason == .toolCalls)
        }
    }

    @Test(arguments: [
        ("length", FinishReason.length),
        ("unexpected_reason", FinishReason.other),
    ])
    func `Ollama stream preserves abnormal done reasons after tool calls`(
        doneReason: String,
        expected: FinishReason,
    ) async throws {
        let payload = Data("""
        {"model":"m","message":{"tool_calls":[{"function":{"name":"lookup"}}]},"done":false}
        {"model":"llama3.3","message":{"role":"assistant","content":""},"done":true,"done_reason":"\(
            doneReason
        )"}

        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try Self.mockedOllamaProvider(configuration: config)
            let stream = try await provider.streamText(request: Self.basicRequest)

            var toolName: String?
            var finishReason: FinishReason?
            for try await delta in stream {
                if delta.type == .toolCall {
                    toolName = delta.toolCall?.name
                } else if delta.type == .done {
                    finishReason = delta.finishReason
                }
            }
            #expect(toolName == "lookup")
            #expect(finishReason == expected)
        }
    }

    @Test
    func `Ollama stream rejects malformed nonblank chunks`() async throws {
        let payload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"prefix"},"done":false}
        this is not json

        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try Self.mockedOllamaProvider(configuration: config)
            let stream = try await provider.streamText(request: Self.basicRequest)

            var collected = ""
            do {
                for try await delta in stream where delta.type == .textDelta {
                    collected.append(delta.content ?? "")
                }
                Issue.record("Expected malformed Ollama stream failure")
            } catch {
                #expect(error.localizedDescription.contains("malformed NDJSON"))
            }
            #expect(collected == "prefix")
        }
    }

    @Test
    func `Ollama stream requires a terminal done chunk`() async throws {
        let payload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"prefix"},"done":false}

        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try Self.mockedOllamaProvider(configuration: config)
            let stream = try await provider.streamText(request: Self.basicRequest)

            do {
                for try await _ in stream {}
                Issue.record("Expected truncated Ollama stream failure")
            } catch {
                #expect(error.localizedDescription.contains("before terminal done"))
            }
        }
    }

    @Test
    func `Ollama stream surfaces HTTP 200 NDJSON errors`() async throws {
        let payload = Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"prefix"},"done":false}
        {"error":"mock streamed failure"}
        """.utf8)

        try await NetworkMocking.withMockedNetwork { request in
            NetworkMocking.streamResponse(for: request, data: payload)
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setBaseURL("http://localhost:11434", for: .ollama)
            }
            let provider = try Self.mockedOllamaProvider(configuration: config)
            let stream = try await provider.streamText(request: Self.basicRequest)

            var collected = ""
            do {
                for try await delta in stream where delta.type == .textDelta {
                    collected.append(delta.content ?? "")
                }
                Issue.record("Expected Ollama's HTTP 200 stream error")
            } catch {
                #expect(error.localizedDescription.contains("mock streamed failure"))
            }
            #expect(collected == "prefix")
        }
    }

    // MARK: - LMStudio

    @Test
    func `LMStudio provider maps OpenAI-style responses`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            let path = request.url?.path ?? ""
            #expect(path.contains("chat/completions"))
            return NetworkMocking.jsonResponse(for: request, data: Self.chatCompletionPayload(text: "LMStudio result"))
        } operation: {
            let provider = LMStudioProvider(
                baseURL: "http://localhost:1234/v1",
                modelId: "local",
                sessionConfiguration: Self.mockedSessionConfiguration(),
            )
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "LMStudio result")
        }
    }

    // MARK: - Aggregators & Compatible Providers

    @Test
    func `OpenRouter provider uses OpenAI-compatible flow`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            self.expectPath(request, endsWith: "/chat/completions")
            #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://peekaboo.app")
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "Peekaboo")
            return NetworkMocking.jsonResponse(for: request, data: Self.chatCompletionPayload(text: "OpenRouter reply"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-openrouter", for: "openrouter")
                config.setBaseURL("https://mock.openrouter.test/api/v1", for: "openrouter")
            }
            let provider = try OpenRouterProvider(modelId: "openrouter/google/gemma-2", configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "OpenRouter reply")
        }
    }

    @Test
    func `Together provider uses OpenAI-compatible flow`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            let path = request.url?.path ?? ""
            #expect(path.hasSuffix("/chat/completions"))
            return NetworkMocking.jsonResponse(for: request, data: Self.chatCompletionPayload(text: "Together result"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-together", for: "together")
            }
            let provider = try TogetherProvider(modelId: "togethercomputer/llama-3.1", configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "Together result")
        }
    }

    @Test
    func `Replicate provider uses OpenAI-compatible flow`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            let path = request.url?.path ?? ""
            #expect(path.hasSuffix("/chat/completions"))
            return NetworkMocking.jsonResponse(for: request, data: Self.chatCompletionPayload(text: "Replicate result"))
        } operation: {
            setenv("REPLICATE_PREFERRED_OUTPUT", "turbo", 1)
            defer { unsetenv("REPLICATE_PREFERRED_OUTPUT") }

            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-replicate", for: "replicate")
            }
            let provider = try ReplicateProvider(modelId: "meta/llama-guard", configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "Replicate result")
        }
    }

    @Test
    func `OpenAI-compatible provider hits custom base URL`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.absoluteString == "https://compatible.test/chat/completions")
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.chatCompletionPayload(text: "Compatible success"),
            )
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-compatible", for: "openai_compatible")
            }
            let provider = try OpenAICompatibleProvider(
                modelId: "any-model",
                baseURL: "https://compatible.test",
                configuration: config,
            )
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "Compatible success")
        }
    }

    @Test
    func `Anthropic-compatible provider decodes responses`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            self.expectPath(request, endsWith: "/messages")
            return NetworkMocking.jsonResponse(for: request, data: Self.anthropicPayload(text: "Compat Claude"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-anthropic-compat", for: "anthropic_compatible")
            }
            let provider = try AnthropicCompatibleProvider(
                modelId: "claude-compat-4",
                baseURL: "https://compat.anthropic.test",
                configuration: config,
            )
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "Compat Claude")
        }
    }

    @Test
    func `Anthropic-compatible provider accepts auth override`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            self.expectPath(request, endsWith: "/messages")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer compat-token")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            return NetworkMocking.jsonResponse(for: request, data: Self.anthropicPayload(text: "Compat bearer"))
        } operation: {
            let provider = try AnthropicCompatibleProvider(
                modelId: "claude-compat-4",
                baseURL: "https://compat.anthropic.test",
                configuration: Self.makeConfiguration { _ in },
                auth: .bearer("compat-token", betaHeader: nil),
            )
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "Compat bearer")
        }
    }

    @Test
    func `MiniMax provider uses bearer auth`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            self.expectPath(request, endsWith: "/messages")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-minimax")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            return NetworkMocking.jsonResponse(for: request, data: Self.anthropicPayload(text: "MiniMax ok"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-minimax", for: .minimax)
            }
            let provider = try ProviderFactory.createProvider(for: .minimax(.m27), configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "MiniMax ok")
        }
    }

    @Test
    func `MiniMax M3 sends multimodal requests to the Anthropic endpoint`() async throws {
        let image = ModelMessage.ContentPart.ImageContent(
            data: Data("test-image".utf8).base64EncodedString(),
            mimeType: "image/png",
        )
        let request = ProviderRequest(messages: [ModelMessage.user(text: "Describe this", images: [image])])

        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.host == "api.minimax.io")
            self.expectPath(request, endsWith: "/anthropic/v1/messages")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-minimax")

            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "MiniMax-M3")
            let messages = try #require(json["messages"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? [[String: Any]])
            let source = try #require(content.first { $0["type"] as? String == "image" }?["source"] as? [String: Any])
            #expect(source["media_type"] as? String == "image/png")
            #expect(source["data"] as? String == image.data)

            return NetworkMocking.jsonResponse(for: request, data: Self.anthropicPayload(text: "MiniMax M3 ok"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-minimax", for: .minimax)
            }
            let provider = try ProviderFactory.createProvider(for: .minimax(.m3), configuration: config)
            #expect(provider.capabilities.supportsVision)
            #expect(provider.capabilities.contextLength == 1_000_000)

            let response = try await provider.generateText(request: request)
            #expect(response.text == "MiniMax M3 ok")
        }
    }

    @Test
    func `MiniMax reasoning metadata is bound to configured endpoint`() async throws {
        let baseURL = "https://minimax-proxy.test/anthropic?tenant=a"
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.host == "minimax-proxy.test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-minimax")
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.anthropicPayloadWithThinking(
                    text: "MiniMax ok",
                    thinking: "native-thought",
                    signature: "sig-mm",
                ),
            )
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-minimax", for: .minimax)
                config.setBaseURL(baseURL, for: .minimax)
            }
            let provider = try ProviderFactory.createProvider(for: .minimax(.m27), configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            let thinkingMessage = try #require(response.assistantMessages.first { $0.channel == .thinking })
            let metadata = try #require(thinkingMessage.metadata?.customData)

            #expect(metadata["tachikoma.reasoning.provider"] == "minimax")
            #expect(metadata["tachikoma.reasoning.model"] == "MiniMax-M2.7")
            #expect(metadata["anthropic.thinking.signature"] == "sig-mm")
            #expect(metadata["tachikoma.reasoning.base_url"] == nil)
        }
    }

    @Test
    func `MiniMax China provider uses China endpoint and bearer auth`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.host == "api.minimaxi.com")
            self.expectPath(request, endsWith: "/messages")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-minimax-cn")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            return NetworkMocking.jsonResponse(for: request, data: Self.anthropicPayload(text: "MiniMax China ok"))
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-minimax-cn", for: .minimaxCN)
            }
            let provider = try ProviderFactory.createProvider(for: .minimaxCN(.m27), configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "MiniMax China ok")
        }
    }

    @Test
    func `MiniMax China provider falls back to MiniMax API key`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.host == "api.minimaxi.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer shared-minimax")
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.anthropicPayload(text: "MiniMax China fallback ok"),
            )
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("shared-minimax", for: .minimax)
            }
            let provider = try ProviderFactory.createProvider(for: .minimaxCN(.m27), configuration: config)
            let response = try await provider.generateText(request: Self.basicRequest)
            #expect(response.text == "MiniMax China fallback ok")
        }
    }

    @Test
    func `Kimi provider uses official endpoint and preserves reasoning content`() async throws {
        let image = ModelMessage.ContentPart.ImageContent(data: "aW1hZ2U=", mimeType: "image/png")
        let request = ProviderRequest(messages: [ModelMessage.user(text: "Inspect", images: [image])])

        try await NetworkMocking.withMockedNetwork { request in
            #expect(request.url?.absoluteString == "https://api.moonshot.ai/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-kimi")
            let body = try #require(self.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "kimi-k2.7-code")
            let messages = try #require(json["messages"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? [[String: Any]])
            #expect(content.contains { $0["type"] as? String == "image_url" })
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.kimiPayload(text: "", reasoning: "native Kimi thought"),
            )
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-kimi", for: .kimi)
            }
            let provider = try KimiProvider(model: .k27Code, configuration: config)
            let response = try await provider.generateText(request: request)
            #expect(response.reasoning.first?.type == "kimi_reasoning_content")
            #expect(response.reasoning.first?.text == "native Kimi thought")
            #expect(response.toolCalls?.first?.name == "lookup")
            #expect(provider.capabilities.contextLength == 262_144)
            #expect(provider.capabilities.maxOutputTokens == 32768)
        }
    }

    @Test
    func `MiniMax rate limit does not contaminate Kimi routing`() async throws {
        try await NetworkMocking.withMockedNetwork { request in
            switch request.url?.host {
            case "api.minimax.io":
                NetworkMocking.jsonResponse(
                    for: request,
                    data: #"{"error":{"message":"rate limited","type":"rate_limit_error"}}"#.utf8Data(),
                    statusCode: 429,
                )
            case "api.moonshot.ai":
                NetworkMocking.jsonResponse(
                    for: request,
                    data: Self.chatCompletionPayload(text: "Kimi remained available"),
                )
            default:
                throw TachikomaError.invalidConfiguration("Unexpected host")
            }
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-minimax", for: .minimax)
                config.setAPIKey("live-kimi", for: .kimi)
            }
            let miniMax = try ProviderFactory.createProvider(for: .minimax(.m27), configuration: config)
            let kimi = try ProviderFactory.createProvider(for: .kimi(.k26), configuration: config)

            await #expect(throws: TachikomaError.self) {
                _ = try await miniMax.generateText(request: Self.basicRequest)
            }
            let response = try await kimi.generateText(request: Self.basicRequest)
            #expect(response.text == "Kimi remained available")
        }
    }

    // MARK: - Helpers

    private func assertOpenAICompatibleProvider(_ model: LanguageModel, provider: Provider) async throws {
        try await NetworkMocking.withMockedNetwork { request in
            let path = request.url?.path ?? ""
            #expect(path.contains("chat/completions"))
            return NetworkMocking.jsonResponse(
                for: request,
                data: Self.chatCompletionPayload(text: "Response for \(provider.identifier)"),
            )
        } operation: {
            let config = Self.makeConfiguration { config in
                config.setAPIKey("live-\(provider.identifier)", for: provider)
            }

            let providerInstance: any ModelProvider = switch model {
            case let .mistral(sub): try MistralProvider(model: sub, configuration: config)
            case let .groq(sub): try GroqProvider(model: sub, configuration: config)
            case let .grok(sub): try GrokProvider(model: sub, configuration: config)
            default:
                fatalError("Unsupported model: \(model)")
            }

            let response = try await providerInstance.generateText(request: Self.basicRequest)
            #expect(response.text.contains(provider.identifier))
        }
    }

    private static var basicRequest: ProviderRequest {
        ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("Hello there")])],
        )
    }

    private static var schemaParityRequest: ProviderRequest {
        let tool = AgentTool(
            name: "run_plan",
            description: "Run a constrained plan",
            parameters: AgentToolParameters(
                properties: [
                    "settings": AgentToolParameterProperty(
                        name: "settings",
                        type: .object,
                        description: "Execution settings",
                        properties: [
                            "mode": AgentToolParameterProperty(
                                name: "mode",
                                type: .string,
                                description: "Execution mode",
                                enumValues: ["safe", "fast"],
                                format: "mode-name",
                                minLength: 4,
                                maxLength: 4,
                            ),
                            "retries": AgentToolParameterProperty(
                                name: "retries",
                                type: .integer,
                                description: "Retry count",
                                minimum: 0,
                                maximum: 3,
                            ),
                        ],
                        required: ["mode"],
                    ),
                    "steps": AgentToolParameterProperty(
                        name: "steps",
                        type: .array,
                        description: "Plan steps",
                        items: AgentToolParameterItems(
                            type: "object",
                            description: "One step",
                            properties: [
                                "label": AgentToolParameterProperty(
                                    name: "label",
                                    type: .string,
                                    description: "Step label",
                                ),
                            ],
                            required: ["label"],
                        ),
                    ),
                    "matrix": AgentToolParameterProperty(
                        name: "matrix",
                        type: .array,
                        description: "Rows",
                        items: AgentToolParameterItems(
                            type: "array",
                            description: "Row",
                            items: AgentToolParameterItems(
                                type: "integer",
                                description: "Cell",
                                minimum: 0,
                                maximum: 9,
                            ),
                        ),
                    ),
                ],
                required: ["settings", "steps", "matrix"],
            ),
        ) { _ in
            AnyAgentToolValue(string: "unused")
        }
        return ProviderRequest(
            messages: [.user("Run it")],
            tools: [tool],
            settings: .init(maxTokens: 32),
        )
    }

    private func expectSchemaParity(_ schema: [String: Any]) throws {
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["settings", "steps", "matrix"])
        let properties = try #require(schema["properties"] as? [String: Any])

        let settings = try #require(properties["settings"] as? [String: Any])
        #expect(settings["type"] as? String == "object")
        #expect(settings["required"] as? [String] == ["mode"])
        let settingProperties = try #require(settings["properties"] as? [String: Any])
        let mode = try #require(settingProperties["mode"] as? [String: Any])
        #expect(mode["enum"] as? [String] == ["safe", "fast"])
        #expect(mode["format"] as? String == "mode-name")
        #expect(mode["minLength"] as? Int == 4)
        #expect(mode["maxLength"] as? Int == 4)
        let retries = try #require(settingProperties["retries"] as? [String: Any])
        #expect(retries["minimum"] as? Double == 0)
        #expect(retries["maximum"] as? Double == 3)

        let steps = try #require(properties["steps"] as? [String: Any])
        let items = try #require(steps["items"] as? [String: Any])
        #expect(items["type"] as? String == "object")
        #expect(items["description"] as? String == "One step")
        #expect(items["required"] as? [String] == ["label"])
        let itemProperties = try #require(items["properties"] as? [String: Any])
        #expect((itemProperties["label"] as? [String: Any])?["type"] as? String == "string")

        let matrix = try #require(properties["matrix"] as? [String: Any])
        let row = try #require(matrix["items"] as? [String: Any])
        #expect(row["type"] as? String == "array")
        let cell = try #require(row["items"] as? [String: Any])
        #expect(cell["type"] as? String == "integer")
        #expect(cell["minimum"] as? Double == 0)
        #expect(cell["maximum"] as? Double == 9)
    }

    private static func makeConfiguration(_ builder: (TachikomaConfiguration) -> Void) -> TachikomaConfiguration {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        builder(config)
        return config
    }

    private static func openAIResponsesPayload(text: String) -> Data {
        let dict: [String: Any] = [
            "id": "resp_123",
            "object": "response",
            "created_at": 1_723_000_000,
            "model": "gpt-5-mini",
            "status": "completed",
            "output": [
                [
                    "id": "msg_1",
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": text],
                    ],
                ],
            ],
            "usage": [
                "input_tokens": 10,
                "output_tokens": 5,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private static func chatCompletionPayload(text: String) -> Data {
        let dict: [String: Any] = [
            "id": "chatcmpl-123",
            "object": "chat.completion",
            "created": 1_723_000_000,
            "model": "gpt-5.5",
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": text],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 10,
                "completion_tokens": 5,
                "total_tokens": 15,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private static func kimiPayload(text: String, reasoning: String) -> Data {
        let dict: [String: Any] = [
            "id": "chatcmpl-kimi",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": text,
                        "reasoning_content": reasoning,
                        "tool_calls": [
                            [
                                "id": "call-1",
                                "type": "function",
                                "function": ["name": "lookup", "arguments": "{}"],
                            ],
                        ],
                    ],
                    "finish_reason": "tool_calls",
                ],
            ],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private static func anthropicPayload(text: String) -> Data {
        let dict: [String: Any] = [
            "id": "msg_1",
            "type": "message",
            "role": "assistant",
            "content": [
                ["type": "text", "text": text],
            ],
            "model": "claude-sonnet-4-6",
            "stop_reason": "end_turn",
            "usage": [
                "input_tokens": 12,
                "output_tokens": 6,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private static func anthropicPayloadWithThinking(text: String, thinking: String, signature: String) -> Data {
        let dict: [String: Any] = [
            "id": "msg_1",
            "type": "message",
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": thinking, "signature": signature],
                ["type": "text", "text": text],
            ],
            "model": "MiniMax-M2.7",
            "stop_reason": "end_turn",
            "usage": [
                "input_tokens": 12,
                "output_tokens": 6,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private static func googleStreamPayload(text: String) -> Data {
        let json: [String: Any] = [
            "candidates": [
                [
                    "content": [
                        "parts": [["text": text]],
                    ],
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        var body = Data()
        body.append("data: ".utf8Data())
        body.append(data)
        body.append("\n\n".utf8Data())
        return body
    }

    private static func ollamaPayload(text: String) -> Data {
        let dict: [String: Any] = [
            "model": "llama3",
            "created_at": "2025-01-01T00:00:00Z",
            "message": ["role": "assistant", "content": text],
            "done": true,
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private static func mockedSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        var classes = config.protocolClasses ?? []
        classes.insert(MockURLProtocol.self, at: 0)
        config.protocolClasses = classes
        return config
    }

    private static func mockedOllamaProvider(
        model: LanguageModel.Ollama = .llama33,
        configuration: TachikomaConfiguration,
    ) throws
        -> OllamaProvider
    {
        try OllamaProvider(
            model: model,
            configuration: configuration,
            urlSession: URLSession(configuration: self.mockedSessionConfiguration()),
        )
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }

        return data
    }

    private func expectPath(
        _ request: URLRequest,
        endsWithAny suffixes: [String],
        allowAudioTranscriptions: Bool = false,
    ) {
        let path = request.url?.path ?? ""
        var allowed = suffixes
        if allowAudioTranscriptions {
            allowed.append(contentsOf: ["/audio/transcriptions", "/audio/speech"])
        }
        let matches = allowed.contains { path.hasSuffix($0) }
        #expect(matches, "Expected path to end with one of \(suffixes.joined(separator: ", ")) but found \(path)")
    }

    private func expectPath(
        _ request: URLRequest,
        endsWith suffix: String,
        allowAudioTranscriptions: Bool = false,
    ) {
        self.expectPath(request, endsWithAny: [suffix], allowAudioTranscriptions: allowAudioTranscriptions)
    }
}

private actor ToolInvocationProbe {
    private(set) var invocationCount = 0

    func recordInvocation() {
        self.invocationCount += 1
    }
}
#endif

private let _isLiveSuite: Bool = {
    #if LIVE_PROVIDER_TESTS
    true
    #else
    false
    #endif
}()

// MARK: - Network Mock Helper

enum NetworkMocking {
    static func withMockedNetwork<T>(
        handler: @Sendable @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
        operation: () async throws -> T,
    ) async throws
        -> T
    {
        let previousHandler = MockURLProtocol.handler
        MockURLProtocol.handler = handler
        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.handler = previousHandler
        }
        return try await operation()
    }

    static func jsonResponse(for request: URLRequest, data: Data, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://mock.api.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
        return (response, data)
    }

    static func streamResponse(for request: URLRequest, data: Data, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://mock.api.test/stream")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"],
        )!
        return (response, data)
    }
}
