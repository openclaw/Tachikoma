import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Tachikoma

#if os(Linux)
@Suite(.disabled("URLProtocol mocking unavailable on Linux"))
struct OpenAICompatibleHelperTests {}
#else

@Suite(.serialized)
struct OpenAICompatibleHelperTests {
    @Test
    func `Compatible providers infer GPT-5.6 limits`() throws {
        let compatible = try OpenAICompatibleProvider(
            modelId: "gpt-5.6-sol",
            baseURL: "https://mock.compatible",
            configuration: TachikomaConfiguration(apiKeys: ["openai_compatible": "sk-test"]),
        )
        let openRouter = try OpenRouterProvider(
            modelId: "openai/gpt-5.6-terra",
            configuration: TachikomaConfiguration(apiKeys: ["openrouter": "sk-test"]),
        )
        let together = try TogetherProvider(
            modelId: "gpt-5.6-luna",
            configuration: TachikomaConfiguration(apiKeys: ["together": "sk-test"]),
        )

        for provider in [compatible, openRouter, together] as [any ModelProvider] {
            #expect(provider.capabilities.contextLength == 372_000)
            #expect(provider.capabilities.maxOutputTokens == 128_000)
        }
        #expect(LanguageModel.openaiCompatible(
            modelId: "openai/gpt-5.6-sol",
            baseURL: "https://mock.compatible",
        ).contextLength == 372_000)
        #expect(LanguageModel.openRouter(modelId: "openai/gpt-5.6-terra").contextLength == 372_000)
        #expect(LanguageModel.together(modelId: "gpt-5.6-luna").contextLength == 372_000)
    }

    @Test
    func `OpenRouter GPT-5.6 variants retain limits and routed model ids`() throws {
        let models = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        let variants = ["online", "nitro", "floor", "exacto"]
        let configuration = TachikomaConfiguration(apiKeys: ["openrouter": "sk-test"])

        for model in models {
            for variant in variants {
                let routedModelId = "openai/\(model):\(variant)"
                let provider = try OpenRouterProvider(modelId: routedModelId, configuration: configuration)

                #expect(provider.modelId == routedModelId)
                #expect(provider.capabilities.contextLength == 372_000)
                #expect(provider.capabilities.maxOutputTokens == 128_000)
                #expect(LanguageModel.openRouter(modelId: routedModelId).modelId == routedModelId)
                #expect(LanguageModel.openRouter(modelId: routedModelId).contextLength == 372_000)
            }
        }
    }

    @Test
    func `generateText encodes stop sequences, headers, and tool definitions`() async throws {
        let tool = AgentTool(
            name: "lookup",
            description: "Lookup a value",
            parameters: AgentToolParameters(
                properties: [
                    "query": AgentToolParameterProperty(
                        name: "query",
                        type: .string,
                        description: "Query string",
                    ),
                ],
                required: ["query"],
            ),
        ) { _ in AnyAgentToolValue(string: "unused") }

        let request = ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("ping")])],
            tools: [tool],
            settings: GenerationSettings(
                maxTokens: 64,
                temperature: 0.2,
                stopConditions: StringStopCondition("END"),
            ),
        )

        let capture = CapturedRequest()

        let response = try await withMockedSession { urlRequest in
            #expect(urlRequest.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            capture.body = self.bodyData(from: urlRequest)
            return self.jsonResponse(for: urlRequest, data: Self.chatCompletionPayload(text: "pong"))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: request,
                modelId: "compatible-model",
                baseURL: "https://mock.compatible",
                apiKey: "sk-test",
                providerName: "TestProvider",
                additionalHeaders: ["X-Test": "1"],
                session: session,
            )
        }

        #expect(response.text == "pong")

        let bodyJSON = try #require(capture.body).jsonObject()
        let stop = bodyJSON["stop"] as? [String]
        #expect(stop == ["END"])
        #expect(bodyJSON["temperature"] as? Double == 0.2)
        let tools = bodyJSON["tools"] as? [[String: Any]]
        let firstTool = try #require(tools?.first)
        #expect(firstTool["type"] as? String == "function")
        let function = firstTool["function"] as? [String: Any]
        let parameters = try #require(function?["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let query = try #require(properties["query"] as? [String: Any])
        #expect(query["type"] as? String == "string")
        let required = parameters["required"] as? [String]
        #expect(required == ["query"])
    }

    @Test
    func `streamText emits deltas as SSE chunks arrive`() async throws {
        let request = ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("stream")])],
        )

        let deltas = try await withMockedSession { urlRequest in
            let sse = """
            data: {\"id\":\"chunk_1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"index\":0,\"finish_reason\":null}]}

            data: {\"id\":\"chunk_2\",\"choices\":[{\"delta\":{\"content\":\" world\"},\"index\":0,\"finish_reason\":null}]}

            data: {\"id\":\"chunk_3\",\"choices\":[{\"delta\":{},\"index\":0,\"finish_reason\":\"stop\"}]}

            data: [DONE]

            """.utf8Data()
            let response = HTTPURLResponse(
                url: urlRequest.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"],
            )!
            return (response, sse)
        } operation: { session in
            let stream = try await OpenAICompatibleHelper.streamText(
                request: request,
                modelId: "compatible-model",
                baseURL: "https://mock.compatible",
                apiKey: "sk-test",
                providerName: "TestProvider",
                session: session,
            )

            var collected = ""
            for try await delta in stream {
                if delta.type == .textDelta {
                    collected += delta.content ?? ""
                }
            }
            return collected
        }

        #expect(deltas == "Hello world")
    }

    @Test
    func `streamText maps content filter finish reasons`() async throws {
        let request = ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("blocked")])],
        )

        let deltas = try await withMockedSession { urlRequest in
            let sse = """
            data: {\"id\":\"chunk_1\",\"choices\":[{\"delta\":{\"content\":\"partial\"},\"index\":0,\"finish_reason\":null}]}

            data: {\"id\":\"chunk_2\",\"choices\":[{\"delta\":{},\"index\":0,\"finish_reason\":\"content_filter\"}]}

            data: [DONE]

            """.utf8Data()
            let response = HTTPURLResponse(
                url: urlRequest.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"],
            )!
            return (response, sse)
        } operation: { session in
            let stream = try await OpenAICompatibleHelper.streamText(
                request: request,
                modelId: "compatible-model",
                baseURL: "https://mock.compatible",
                apiKey: "sk-test",
                providerName: "TestProvider",
                session: session,
            )

            var deltas: [TextStreamDelta] = []
            for try await delta in stream {
                deltas.append(delta)
            }
            return deltas
        }

        #expect(deltas.contains { $0.type == .textDelta && $0.content == "partial" })
        #expect(deltas.contains { $0.type == .done && $0.finishReason == .contentFilter })
    }

    @Test(arguments: ["gpt-5.6-sol", "openai/gpt-5.6-sol", "compatible-fixture"])
    func `Compatible streaming keeps payloads off process output`(modelID: String) async throws {
        let marker = "TACHIKOMA_PRIVATE_REQUEST_FIXTURE"
        let tool = AgentTool(
            name: "quiet_tool",
            description: "\(marker) schema",
            parameters: AgentToolParameters(
                properties: [
                    "query": AgentToolParameterProperty(
                        name: "query", type: .string, description: "Synthetic query",
                    ),
                ],
                required: ["query"],
            ),
        ) { _ in
            Issue.record("Provider streaming must not execute the fixture tool")
            return AnyAgentToolValue(string: "unused")
        }
        let request = ProviderRequest(
            messages: [.user("\(marker) prompt")],
            tools: [tool],
            settings: GenerationSettings(maxTokens: 64),
        )
        let captured = CapturedRequest()
        let deltas = try await self.withMockedSession { urlRequest in
            #expect(captured.body == nil)
            let body = try #require(self.bodyData(from: urlRequest))
            captured.body = body
            let json = try body.jsonObject()
            #expect(urlRequest.httpMethod == "POST")
            #expect(urlRequest.url?.absoluteString == "https://mock.compatible/v1/chat/completions")
            #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(json["model"] as? String == modelID)
            #expect(json["stream"] as? Bool == true)
            let tokenKey = modelID == "gpt-5.6-sol" ? "max_completion_tokens" : "max_tokens"
            #expect(json[tokenKey] as? Int == 64)
            let messages = try #require(json["messages"] as? [[String: Any]])
            #expect(messages.count == 1)
            #expect(messages[0]["role"] as? String == "user")
            #expect(messages[0]["content"] as? String == "\(marker) prompt")
            let tools = try #require(json["tools"] as? [[String: Any]])
            #expect(tools.count == 1)
            let function = try #require(tools[0]["function"] as? [String: Any])
            #expect(function["name"] as? String == "quiet_tool")
            #expect(function["description"] as? String == "\(marker) schema")
            let parameters = try #require(function["parameters"] as? [String: Any])
            #expect(parameters["required"] as? [String] == ["query"])
            let properties = try #require(parameters["properties"] as? [String: [String: Any]])
            #expect(properties["query"]?["type"] as? String == "string")
            let url = try #require(urlRequest.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"],
            ))
            return (response, Self.quietContractStream)
        } operation: { session in
            let provider = try OpenAICompatibleProvider(
                modelId: modelID,
                baseURL: "https://mock.compatible/v1",
                configuration: TachikomaConfiguration(apiKeys: ["openai_compatible": "fixture-key"]),
                session: session,
            )
            var result: [TextStreamDelta] = []
            let stream = try await provider.streamText(request: request)
            for try await delta in stream {
                result.append(delta)
            }
            return result
        }
        #expect(captured.body != nil)
        #expect(deltas.map(\.type) == [.textDelta, .textDelta, .toolCall, .done])
        #expect(deltas.compactMap(\.content) == ["Fixture answer\n", "  with whitespace 😀"])
        let call = try #require(deltas.compactMap(\.toolCall).first)
        #expect(call.id == "f")
        #expect(call.name == "quiet_tool")
        #expect(call.arguments["query"]?.stringValue == "synthetic-value")
        #expect(deltas.last?.finishReason == .toolCalls)
    }

    @Test(arguments: [false, true])
    func `Compatible streaming assembles tool argument fragments`(initialArgumentsAbsent: Bool) async throws {
        let initialArguments = initialArgumentsAbsent ? "" : #", "arguments":"""#
        let deltas = try await self.compatibleToolStream([
            #"{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"lookup""# + initialArguments + "}}]}",
            #"{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]}"#,
            #"{"tool_calls":[{"index":0,"function":{"arguments":"\"needle\"}"}}]}"#,
        ])
        #expect(deltas.map(\.type) == [.toolCall, .done])
        let call = try #require(deltas.compactMap(\.toolCall).first)
        #expect(call.id == "call_1")
        #expect(call.name == "lookup")
        #expect(call.arguments == ["query": AnyAgentToolValue(string: "needle")])
        #expect(deltas.last?.finishReason == .toolCalls)
    }

    private func compatibleToolStream(_ deltas: [String]) async throws -> [TextStreamDelta] {
        let observation = try await self.compatibleStreamObservation(deltas)
        if let error = observation.error {
            throw error
        }
        return observation.deltas
    }

    @Test(arguments: [false, true], ["", "{}"])
    func `Compatible streaming preserves explicit complete no argument calls`(
        indexed: Bool,
        arguments: String,
    ) async throws {
        let index = indexed ? #""index":0,"# : ""
        let deltas = try await self.compatibleToolStream([
            #"{"tool_calls":[{"# + index + #""id":"empty","function":{"name":"lookup","arguments":""# +
                arguments + #""}}]}"#,
        ])
        #expect(deltas.map(\.type) == [.toolCall, .done])
        let call = try #require(deltas.compactMap(\.toolCall).first)
        #expect(call.id == "empty")
        #expect(call.name == "lookup")
        #expect(call.arguments.isEmpty)
    }

    @Test
    func `Compatible streaming rejects calls whose argument field never arrives`() async throws {
        let observation = try await self.compatibleStreamObservation([
            #"{"tool_calls":[{"index":0,"id":"absent","function":{"name":"lookup"}}]}"#,
        ])
        #expect(observation.error is TachikomaError)
        #expect(observation.deltas.isEmpty)
    }

    @Test(arguments: ["tool_calls", "stop", "[DONE]"])
    func `Compatible streaming defers complete calls until successful terminal`(terminal: String) async throws {
        let observation = try await self.compatibleStreamObservation([
            #"{"tool_calls":[{"index":0,"id":"a","function":{"name":"lookup","arguments":"{}"}}]}"#,
            #"{"content":"between"}"#,
        ], terminal: terminal)
        #expect(observation.error == nil)
        #expect(observation.deltas.map(\.type) == [.textDelta, .toolCall, .done])
        #expect(observation.deltas.first?.content == "between")
        #expect(observation.deltas.compactMap(\.toolCall).first?.id == "a")
        let expected: FinishReason? = terminal == "tool_calls" ? .toolCalls : terminal == "stop" ? .stop : nil
        #expect(observation.deltas.last?.finishReason == expected)
    }

    @Test(arguments: ["length", "content_filter", "unknown"])
    func `Compatible streaming never emits tools from unsuccessful terminal`(terminal: String) async throws {
        let observation = try await self.compatibleStreamObservation([
            #"{"tool_calls":[{"index":0,"id":"a","function":{"name":"lookup","arguments":"{}"}}]}"#,
        ], terminal: terminal)
        #expect(observation.error == nil)
        #expect(observation.deltas.map(\.type) == [.done])
        let expected: FinishReason = terminal == "length" ? .length : terminal == "content_filter" ? .contentFilter :
            .other
        #expect(observation.deltas.last?.finishReason == expected)
    }

    @Test(arguments: ["tool_calls", "[DONE]", "EOF"])
    func `Compatible streaming rejects incomplete calls without partial batch delivery`(terminal: String) async throws {
        let observation = try await self.compatibleStreamObservation([
            #"{"tool_calls":[{"index":0,"id":"valid","function":{"name":"lookup","arguments":"{}"}}]}"#,
            #"{"tool_calls":[{"index":1,"id":"invalid","function":{"name":"lookup","arguments":"{"}}]}"#,
        ], terminal: terminal == "EOF" ? nil : terminal)
        #expect(observation.error is TachikomaError)
        #expect(observation.deltas.isEmpty)
    }

    @Test
    func `Compatible streaming associates interleaved calls`() async throws {
        let deltas = try await self.compatibleToolStream([
            #"{"tool_calls":[{"index":0,"id":"a","function":{"name":"first","arguments":"{\"value\":"}}]}"#,
            #"{"tool_calls":[{"index":1,"id":"b","function":{"name":"second","arguments":"{\"value\":2}"}}]}"#,
            #"{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}"#,
        ])
        #expect(deltas.map(\.type) == [.toolCall, .toolCall, .done])
        let calls = deltas.compactMap(\.toolCall)
        #expect(calls.map(\.id) == ["a", "b"])
        #expect(calls.map(\.name) == ["first", "second"])
        #expect(calls.map { $0.arguments["value"]?.intValue } == [1, 2])
    }

    @Test(arguments: [false, true])
    func `Malformed events cannot silently alter tool arguments`(malformedFirst: Bool) async throws {
        let first = #"{"tool_calls":[{"index":0,"id":"a","function":{"name":"lookup","arguments":"{\"query\":\""}}]}"#
        let malformed = #"{"tool_calls":invalid}"#
        let final = #"{"tool_calls":[{"index":0,"function":{"arguments":"\"}"}}]}"#
        let deltas = malformedFirst ? [malformed, first, final] : [first, malformed, final]
        let observation = try await self.compatibleStreamObservation(deltas)
        #expect(observation.error is TachikomaError)
        #expect(observation.deltas.isEmpty)
    }

    private func compatibleStreamObservation(
        _ deltas: [String],
        terminal: String? = "tool_calls",
    ) async throws
        -> (deltas: [TextStreamDelta], error: (any Error)?)
    {
        var frames = deltas.enumerated().map { index, delta in
            #"data: {"id":"chunk_"# + String(index) + #"","choices":[{"index":0,"delta":"# + delta + "}]}"
        }
        if let terminal {
            if terminal == "[DONE]" {
                frames.append("data: [DONE]")
            } else {
                frames.append(
                    #"data: {"id":"terminal","choices":[{"index":0,"delta":{},"finish_reason":""# + terminal + #""}]}"#,
                )
            }
            frames += [
                #"data: {"id":"late","choices":[{"index":0,"delta":{"content":"not delivered","# +
                    #""tool_calls":[{"index":2,"id":"late","function":{"name":"late","arguments":"{}"}}]}}]}"#,
                "data: [DONE]",
            ]
        }
        let payload = (frames + [""]).joined(separator: "\n\n").utf8Data()
        return try await self.withMockedSession { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"],
            ))
            return (response, payload)
        } operation: { session in
            let provider = try OpenAICompatibleProvider(
                modelId: "compatible-fixture",
                baseURL: "https://mock.compatible/v1",
                configuration: TachikomaConfiguration(apiKeys: ["openai_compatible": "fixture-key"]),
                session: session,
            )
            let stream = try await provider.streamText(request: ProviderRequest(messages: [.user("Synthetic fixture")]))
            var result: [TextStreamDelta] = []
            do {
                for try await delta in stream {
                    result.append(delta)
                }
                return (result, nil)
            } catch {
                return (result, error)
            }
        }
    }

    private static let quietContractStream = [
        #"data: {"id":"c1","choices":[{"delta":{"content":"Fixture answer\n"},"index":0}]}"#,
        #"data: {"id":"c2","choices":[{"delta":{"content":"  with whitespace 😀"},"index":0}]}"#,
        #"data: {"id":"c3","choices":[{"delta":{"tool_calls":[{"id":"f","type":"function","function":{"name":"quiet_tool","# +
            #""arguments":"{\"query\":\"synthetic-value\"}"}}]},"index":0}]}"#,
        #"data: {"id":"c4","choices":[{"delta":{},"index":0,"finish_reason":"tool_calls"}]}"#,
        #"data: {"id":"c5","choices":[{"delta":{"content":"UNDELIVERED_POST_TERMINAL"},"index":0}]}"#,
        "data: [DONE]",
        "",
    ].joined(separator: "\n\n").utf8Data()

    @Test
    func `streamText emits Kimi reasoning content`() async throws {
        let request = ProviderRequest(messages: [.user("stream")])

        let deltas = try await self.withMockedSession { urlRequest in
            let sse = """
            data: {"id":"chunk_1","choices":[{"delta":{"reasoning_content":"thinking"},"index":0,"finish_reason":null}]}

            data: {"id":"chunk_2","choices":[{"delta":{"content":"answer"},"index":0,"finish_reason":null}]}

            data: {"id":"chunk_3","choices":[{"delta":{},"index":0,"finish_reason":"stop"}]}

            data: [DONE]

            """.utf8Data()
            let response = HTTPURLResponse(
                url: urlRequest.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"],
            )!
            return (response, sse)
        } operation: { session in
            let stream = try await OpenAICompatibleHelper.streamText(
                request: request,
                modelId: "kimi-k2.7-code",
                baseURL: "https://api.moonshot.cn/v1",
                apiKey: "sk-test",
                providerName: "Kimi",
                session: session,
            )

            var deltas: [TextStreamDelta] = []
            for try await delta in stream {
                deltas.append(delta)
            }
            return deltas
        }

        #expect(deltas.contains {
            $0.type == .reasoning && $0.content == "thinking" && $0.reasoningType == "kimi_reasoning_content"
        })
        #expect(deltas.contains { $0.type == .textDelta && $0.content == "answer" })
    }

    @Test
    func `OpenAI-compatible provider forwards configured headers`() async throws {
        let request = ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("ping")])],
        )

        try await self.withMockedSession { urlRequest in
            #expect(urlRequest.value(forHTTPHeaderField: "client_id") == "proxy-client")
            #expect(urlRequest.value(forHTTPHeaderField: "client_secret") == "proxy-secret")
            return self.jsonResponse(for: urlRequest, data: Self.chatCompletionPayload(text: "pong"))
        } operation: { session in
            let configuration = TachikomaConfiguration(apiKeys: ["openai_compatible": "sk-test"])
            let provider = try OpenAICompatibleProvider(
                modelId: "compatible-model",
                baseURL: "https://mock.compatible",
                configuration: configuration,
                additionalHeaders: [
                    "client_id": "proxy-client",
                    "client_secret": "proxy-secret",
                ],
                session: session,
            )

            let response = try await provider.generateText(request: request)
            #expect(response.text == "pong")
        }
    }

    @Test
    func `generateText decodes OpenRouter reasoning details`() async throws {
        let response = try await withMockedSession { urlRequest in
            let reasoningDetails: [[String: String]] = [["type": "reasoning.encrypted", "data": "sealed"]]
            let toolCall: [String: Any] = [
                "id": "call-1",
                "type": "function",
                "function": ["name": "lookup", "arguments": "{}"],
            ]
            let toolCalls = [toolCall]
            let choice: [String: Any] = [
                "index": 0,
                "message": [
                    "role": "assistant",
                    "content": NSNull(),
                    "reasoning_details": reasoningDetails,
                    "tool_calls": toolCalls,
                ],
                "finish_reason": "tool_calls",
            ]
            let payload: [String: Any] = [
                "id": "chatcmpl-test",
                "object": "chat.completion",
                "created": 1_700_000_000,
                "model": "anthropic/claude-fable-5",
                "choices": [choice],
            ]
            return try self.jsonResponse(for: urlRequest, data: JSONSerialization.data(withJSONObject: payload))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: ProviderRequest(messages: [.user("hi")]),
                modelId: "anthropic/claude-fable-5",
                baseURL: "https://mock.compatible",
                apiKey: "sk-test",
                providerName: "OpenRouter",
                session: session,
            )
        }

        let reasoning = try #require(response.reasoning.first)
        #expect(reasoning.type == "openrouter_reasoning_details")
        #expect(reasoning.rawJSON?.contains("reasoning.encrypted") == true)
        #expect(response.toolCalls?.first?.id == "call-1")
    }

    @Test
    func `generateText decodes Kimi reasoning content`() async throws {
        let response = try await self.withMockedSession { urlRequest in
            let payload: [String: Any] = [
                "id": "chatcmpl-kimi",
                "choices": [
                    [
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": NSNull(),
                            "reasoning_content": "native Kimi thought",
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
            ]
            return try self.jsonResponse(for: urlRequest, data: JSONSerialization.data(withJSONObject: payload))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: ProviderRequest(messages: [.user("hi")]),
                modelId: "kimi-k2.7-code",
                baseURL: "https://api.moonshot.cn/v1",
                apiKey: "sk-test",
                providerName: "Kimi",
                session: session,
            )
        }

        let reasoning = try #require(response.reasoning.first)
        #expect(reasoning.type == "kimi_reasoning_content")
        #expect(reasoning.text == "native Kimi thought")
        #expect(response.toolCalls?.first?.id == "call-1")
    }

    @Test
    func `generateText replays Kimi reasoning only for matching model and endpoint`() async throws {
        let capture = CapturedRequest()
        let call = AgentToolCall(id: "call-1", name: "lookup", arguments: [:])
        let endpoint = "https://api.moonshot.cn/v1"
        let request = try ProviderRequest(messages: [
            .user("hi"),
            ModelMessage(
                role: .assistant,
                content: [.text("native Kimi thought")],
                channel: .thinking,
                metadata: .init(customData: [
                    "kimi.reasoning_content": "native Kimi thought",
                    "tachikoma.reasoning.provider": "kimi",
                    "tachikoma.reasoning.model": "kimi-k2.7-code",
                    "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity.canonical(endpoint)),
                ]),
            ),
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(
                role: .tool,
                content: [.toolResult(.success(toolCallId: "call-1", result: AnyAgentToolValue(string: "ok")))],
            ),
        ])

        _ = try await self.withMockedSession { urlRequest in
            capture.body = self.bodyData(from: urlRequest)
            return self.jsonResponse(for: urlRequest, data: Self.chatCompletionPayload(text: "done"))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: request,
                modelId: "kimi-k2.7-code",
                baseURL: endpoint,
                apiKey: "sk-test",
                providerName: "Kimi",
                session: session,
            )
        }

        let bodyJSON = try #require(capture.body).jsonObject()
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        #expect(assistant["reasoning_content"] as? String == "native Kimi thought")
        #expect(assistant["tool_calls"] != nil)
        #expect(bodyJSON["thinking"] == nil)
    }

    @Test
    func `generateText enables preserved thinking when replaying Kimi K2_6 reasoning`() async throws {
        let capture = CapturedRequest()
        let endpoint = "https://api.moonshot.cn/v1"
        let request = try ProviderRequest(messages: [
            .user("first"),
            ModelMessage(
                role: .assistant,
                content: [.text("native Kimi thought")],
                channel: .thinking,
                metadata: .init(customData: [
                    "kimi.reasoning_content": "native Kimi thought",
                    "tachikoma.reasoning.provider": "kimi",
                    "tachikoma.reasoning.model": "kimi-k2.6",
                    "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity.canonical(endpoint)),
                ]),
            ),
            .assistant("answer"),
            .user("continue"),
        ])

        _ = try await self.withMockedSession { urlRequest in
            capture.body = self.bodyData(from: urlRequest)
            return self.jsonResponse(for: urlRequest, data: Self.chatCompletionPayload(text: "done"))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: request,
                modelId: "kimi-k2.6",
                baseURL: endpoint,
                apiKey: "sk-test",
                providerName: "Kimi",
                session: session,
            )
        }

        let bodyJSON = try #require(capture.body).jsonObject()
        let thinking = try #require(bodyJSON["thinking"] as? [String: String])
        #expect(thinking["type"] == "enabled")
        #expect(thinking["keep"] == "all")
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        #expect(assistant["reasoning_content"] as? String == "native Kimi thought")
    }

    @Test
    func `generateText strips unsupported Fable sampling for OpenRouter route`() async throws {
        let capture = CapturedRequest()
        let request = ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("ping")])],
            settings: GenerationSettings(maxTokens: 128, temperature: 0.7),
        )

        _ = try await self.withMockedSession { urlRequest in
            capture.body = self.bodyData(from: urlRequest)
            return self.jsonResponse(for: urlRequest, data: Self.chatCompletionPayload(text: "pong"))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: request,
                modelId: "anthropic/claude-fable-5",
                baseURL: "https://mock.compatible",
                apiKey: "sk-test",
                providerName: "OpenRouter",
                session: session,
            )
        }

        let bodyJSON = try #require(capture.body).jsonObject()
        #expect(bodyJSON["temperature"] == nil)
        #expect(bodyJSON["max_tokens"] as? Int == 128)
    }

    @Test
    func `generateText replays OpenRouter reasoning details on assistant tool messages`() async throws {
        let capture = CapturedRequest()
        let rawReasoning = #"[{"type":"reasoning.encrypted","data":"sealed"}]"#
        let call = AgentToolCall(id: "call-1", name: "lookup", arguments: [:])
        let request = try ProviderRequest(messages: [
            .user("hi"),
            ModelMessage(
                role: .assistant,
                content: [.text("")],
                channel: .thinking,
                metadata: .init(customData: [
                    "openrouter.reasoning_details": rawReasoning,
                    "tachikoma.reasoning.provider": "openrouter",
                    "tachikoma.reasoning.model": "anthropic/claude-fable-5",
                    "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity
                        .canonical("https://mock.compatible")),
                ]),
            ),
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(
                role: .tool,
                content: [.toolResult(.success(toolCallId: "call-1", result: AnyAgentToolValue(string: "ok")))],
            ),
        ])

        _ = try await self.withMockedSession { urlRequest in
            capture.body = self.bodyData(from: urlRequest)
            return self.jsonResponse(for: urlRequest, data: Self.chatCompletionPayload(text: "done"))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: request,
                modelId: "anthropic/claude-fable-5",
                baseURL: "https://mock.compatible",
                apiKey: "sk-test",
                providerName: "OpenRouter",
                session: session,
            )
        }

        let bodyJSON = try #require(capture.body).jsonObject()
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let details = try #require(assistant["reasoning_details"] as? [[String: Any]])
        #expect(details.first?["type"] as? String == "reasoning.encrypted")
        #expect(details.first?["data"] as? String == "sealed")
        #expect(assistant["tool_calls"] != nil)
    }

    @Test
    func `generateText replays OpenRouter reasoning details on reasoning-only assistant boundary`() async throws {
        let capture = CapturedRequest()
        let rawReasoning = #"[{"type":"reasoning.encrypted","data":"sealed"}]"#
        let request = try ProviderRequest(messages: [
            .user("first"),
            ModelMessage(
                role: .assistant,
                content: [.text("")],
                channel: .thinking,
                metadata: .init(customData: [
                    "openrouter.reasoning_details": rawReasoning,
                    "tachikoma.reasoning.provider": "openrouter",
                    "tachikoma.reasoning.model": "anthropic/claude-fable-5",
                    "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity
                        .canonical("https://mock.compatible")),
                ]),
            ),
            ModelMessage(
                role: .assistant,
                content: [.text("")],
                metadata: .init(customData: ["tachikoma.internal.boundary": "reasoning_only"]),
            ),
            .user("next"),
        ])

        _ = try await self.withMockedSession { urlRequest in
            capture.body = self.bodyData(from: urlRequest)
            return self.jsonResponse(for: urlRequest, data: Self.chatCompletionPayload(text: "done"))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: request,
                modelId: "anthropic/claude-fable-5",
                baseURL: "https://mock.compatible",
                apiKey: "sk-test",
                providerName: "OpenRouter",
                session: session,
            )
        }

        let bodyJSON = try #require(capture.body).jsonObject()
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])
        let assistantIndex = try #require(messages.firstIndex { $0["role"] as? String == "assistant" })
        let assistant = messages[assistantIndex]
        let details = try #require(assistant["reasoning_details"] as? [[String: Any]])
        #expect(details.first?["data"] as? String == "sealed")
        let nextMessage = try #require(messages.indices
            .contains(assistantIndex + 1) ? messages[assistantIndex + 1] : nil)
        #expect(nextMessage["role"] as? String == "user")
    }

    @Test
    func `generateText does not replay OpenRouter reasoning from another endpoint`() async throws {
        let capture = CapturedRequest()
        let rawReasoning = #"[{"type":"reasoning.encrypted","data":"sealed"}]"#
        let call = AgentToolCall(id: "call-1", name: "lookup", arguments: [:])
        let request = try ProviderRequest(messages: [
            .user("hi"),
            ModelMessage(
                role: .assistant,
                content: [.text("")],
                channel: .thinking,
                metadata: .init(customData: [
                    "openrouter.reasoning_details": rawReasoning,
                    "tachikoma.reasoning.provider": "openrouter",
                    "tachikoma.reasoning.model": "anthropic/claude-fable-5",
                    "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity
                        .canonical("https://other.example.test")),
                ]),
            ),
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(
                role: .tool,
                content: [.toolResult(.success(toolCallId: "call-1", result: AnyAgentToolValue(string: "ok")))],
            ),
        ])

        _ = try await self.withMockedSession { urlRequest in
            capture.body = self.bodyData(from: urlRequest)
            return self.jsonResponse(for: urlRequest, data: Self.chatCompletionPayload(text: "done"))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: request,
                modelId: "anthropic/claude-fable-5",
                baseURL: "https://mock.compatible",
                apiKey: "sk-test",
                providerName: "OpenRouter",
                session: session,
            )
        }

        let bodyJSON = try #require(capture.body).jsonObject()
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])
        let assistantMessages = messages.filter { $0["role"] as? String == "assistant" }
        #expect(assistantMessages.allSatisfy { $0["reasoning_details"] == nil })
    }

    @Test
    func `generateText drops unmatched OpenRouter reasoning instead of serializing it as text`() async throws {
        let capture = CapturedRequest()
        let request = try ProviderRequest(messages: [
            .user("hi"),
            ModelMessage(
                role: .assistant,
                content: [.text("private reasoning")],
                channel: .thinking,
                metadata: .init(customData: [
                    "openrouter.reasoning": "private reasoning",
                    "tachikoma.reasoning.provider": "openrouter",
                    "tachikoma.reasoning.model": "other-model",
                    "tachikoma.reasoning.base_url": #require(ReasoningEndpointIdentity
                        .canonical("https://mock.compatible")),
                ]),
            ),
            .assistant("visible"),
        ])

        _ = try await self.withMockedSession { urlRequest in
            capture.body = self.bodyData(from: urlRequest)
            return self.jsonResponse(for: urlRequest, data: Self.chatCompletionPayload(text: "done"))
        } operation: { session in
            try await OpenAICompatibleHelper.generateText(
                request: request,
                modelId: "anthropic/claude-fable-5",
                baseURL: "https://mock.compatible",
                apiKey: "sk-test",
                providerName: "OpenRouter",
                session: session,
            )
        }

        let bodyJSON = try #require(capture.body).jsonObject()
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])
        let assistantMessages = messages.filter { $0["role"] as? String == "assistant" }
        #expect(assistantMessages.count == 1)
        #expect(assistantMessages.first?["content"] as? String == "visible")
        #expect(try String(data: #require(capture.body), encoding: .utf8)?.contains("private reasoning") == false)
    }

    @Test(arguments: ["", "{}"])
    func `generateText keeps a no-argument tool call`(arguments: String) async throws {
        let response = try await self.generateToolCallResponse(arguments: [arguments])
        #expect(response.finishReason == .toolCalls)
        let calls = try #require(response.toolCalls)
        #expect(calls.map(\.id) == ["c1"])
        #expect(calls.map(\.name) == ["ping"])
        #expect(calls[0].arguments.isEmpty)
    }

    @Test
    func `generateText keeps every tool call when one has empty arguments`() async throws {
        let response = try await self.generateToolCallResponse(arguments: ["", #"{"ok":true}"#])
        let calls = try #require(response.toolCalls)
        #expect(response.finishReason == .toolCalls)
        #expect(calls.map(\.id) == ["c1", "c2"])
        #expect(calls.map(\.name) == ["ping", "lookup"])
        #expect(calls[0].arguments.isEmpty)
        #expect(calls[1].arguments["ok"] == AnyAgentToolValue(bool: true))
    }

    @Test(arguments: ["{", "[]", "null", "true", "42"])
    func `generateText rejects invalid tool call arguments instead of dropping the call`(
        arguments: String,
    ) async {
        await self.withMockedSession { urlRequest in
            self.jsonResponse(for: urlRequest, data: Self.toolCallsPayload(arguments: ["{}", arguments]))
        } operation: { session in
            do {
                _ = try await self.generateText(session: session)
                Issue.record("Expected invalid tool-call arguments to fail")
            } catch let error as TachikomaError {
                guard case let .apiError(message) = error else {
                    Issue.record("Unexpected TachikomaError: \(error)")
                    return
                }
                #expect(message.contains("invalid or incomplete tool-call arguments"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func `non-200 responses surface TachikomaError.apiError`() async {
        await self.withMockedSession { urlRequest in
            let errorJSON = """
            {"error":{"message":"bad request","type":"invalid_request_error"}}
            """.utf8Data()
            let response = HTTPURLResponse(
                url: urlRequest.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            )!
            return (response, errorJSON)
        } operation: { session in
            do {
                _ = try await OpenAICompatibleHelper.generateText(
                    request: ProviderRequest(messages: [ModelMessage(role: .user, content: [.text("fail")])]),
                    modelId: "compatible-model",
                    baseURL: "https://mock.compatible",
                    apiKey: "sk-test",
                    providerName: "TestProvider",
                    session: session,
                )
                Issue.record("Expected error to be thrown")
            } catch let error as TachikomaError {
                switch error {
                case let .apiError(message):
                    #expect(message.contains("bad request"))
                default:
                    Issue.record("Unexpected TachikomaError: \(error)")
                }
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func withMockedSession<T>(
        handler: @Sendable @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
        operation: (URLSession) async throws -> T,
    ) async rethrows
        -> T
    {
        let previousHandler = OpenAIHelperURLProtocol.handler
        OpenAIHelperURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        var classes = configuration.protocolClasses ?? []
        classes.insert(OpenAIHelperURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
        let session = URLSession(configuration: configuration)

        defer {
            session.invalidateAndCancel()
            OpenAIHelperURLProtocol.handler = previousHandler
        }

        return try await operation(session)
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
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

    private func jsonResponse(for request: URLRequest, data: Data, status: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://mock.compatible/chat/completions")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
        return (response, data)
    }

    private func generateToolCallResponse(arguments: [String]) async throws -> ProviderResponse {
        try await self.withMockedSession { urlRequest in
            self.jsonResponse(for: urlRequest, data: Self.toolCallsPayload(arguments: arguments))
        } operation: { session in
            try await self.generateText(session: session)
        }
    }

    private func generateText(session: URLSession) async throws -> ProviderResponse {
        try await OpenAICompatibleHelper.generateText(
            request: ProviderRequest(messages: [ModelMessage(role: .user, content: [.text("ping")])]),
            modelId: "compatible-model",
            baseURL: "https://mock.compatible",
            apiKey: "sk-test",
            providerName: "TestProvider",
            session: session,
        )
    }

    private static func toolCallsPayload(arguments: [String]) -> Data {
        let names = ["ping", "lookup", "third"]
        let toolCalls: [[String: Any]] = arguments.enumerated().map { index, encoded in
            [
                "id": "c\(index + 1)",
                "type": "function",
                "function": [
                    "name": names[index],
                    "arguments": encoded,
                ],
            ]
        }
        let dict: [String: Any] = [
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "created": 1_700_000_000,
            "model": "compatible-model",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "",
                        "tool_calls": toolCalls,
                    ],
                    "finish_reason": "tool_calls",
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private static func chatCompletionPayload(text: String) -> Data {
        let dict: [String: Any] = [
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "created": 1_700_000_000,
            "model": "compatible-model",
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": text],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 12,
                "completion_tokens": 3,
                "total_tokens": 15,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }
}

extension Data {
    fileprivate func jsonObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: self) as? [String: Any] ?? [:]
    }
}

private final class CapturedRequest: @unchecked Sendable {
    var body: Data?
}

private final class OpenAIHelperURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
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
#endif
