import Testing
@testable import Tachikoma

/// Mutable counter for sequential cache fixture calls.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(value: T) {
        self.value = value
    }
}

struct ResponseCacheTests {
    @Test
    func `ResponseCache initialization`() async {
        let config = CacheConfiguration(maxEntries: 50, defaultTTL: 1800)
        let cache = ResponseCache(configuration: config)
        let statistics = await cache.getStatistics()
        #expect(statistics.currentEntries == 0)
        #expect(statistics.maxEntries == 50)
        let probeRequest = ProviderRequest(
            messages: [ModelMessage.user("ping")],
            tools: nil,
            settings: .default,
        )
        let cached = await cache.get(for: probeRequest)
        #expect(cached == nil)
    }

    @Test
    func `ResponseCache store and retrieve`() async {
        let cache = ResponseCache()

        let request = ProviderRequest(
            messages: [ModelMessage.user("Hello")],
            tools: nil,
            settings: .default,
        )

        let response = ProviderResponse(
            text: "Hi there!",
            usage: Usage(inputTokens: 5, outputTokens: 10),
            finishReason: .stop,
        )

        // Store response
        await cache.store(response, for: request)

        // Retrieve response
        let cached = await cache.get(for: request)

        #expect(cached?.text == "Hi there!")
        #expect(cached?.usage?.inputTokens == 5)
        #expect(cached?.usage?.outputTokens == 10)
        #expect(cached?.finishReason == .stop)
    }

    @Test
    func `ResponseCache keys include reasoning metadata`() async {
        let cache = ResponseCache()
        let response = ProviderResponse(text: "cached", usage: nil, finishReason: .stop)

        func request(signature: String) -> ProviderRequest {
            ProviderRequest(
                messages: [
                    .user("Hello"),
                    ModelMessage(
                        role: .assistant,
                        content: [.text("thinking")],
                        channel: .thinking,
                        metadata: .init(customData: [
                            "anthropic.thinking.signature": signature,
                            "anthropic.thinking.type": "thinking",
                        ]),
                    ),
                    .assistant("Hi"),
                ],
                tools: nil,
                settings: .default,
            )
        }

        await cache.store(response, for: request(signature: "sig-a"))

        #expect(await cache.get(for: request(signature: "sig-a"))?.text == "cached")
        #expect(await cache.get(for: request(signature: "sig-b")) == nil)
    }

    @Test
    func `CacheEntry size includes reasoning and assistant messages`() {
        let small = CacheEntry(response: ProviderResponse(text: "ok"))
        let largePayload = String(repeating: "x", count: 4096)
        let large = CacheEntry(response: ProviderResponse(
            text: "ok",
            reasoning: [
                ProviderReasoningBlock(text: largePayload, signature: largePayload, type: "thinking"),
                ProviderReasoningBlock(
                    text: "",
                    type: "openrouter_reasoning_details",
                    rawJSON: largePayload,
                ),
            ],
            assistantMessages: [
                ModelMessage(
                    role: .assistant,
                    content: [.text(largePayload)],
                    channel: .thinking,
                    metadata: .init(customData: [
                        "anthropic.thinking.model": "claude-fable-5",
                        "anthropic.thinking.signature": largePayload,
                    ]),
                ),
            ],
        ))

        #expect(large.estimatedMemorySize() > small.estimatedMemorySize() + 12000)
    }

    @Test
    func `ResponseCache cache miss`() async {
        let cache = ResponseCache()

        let request = ProviderRequest(
            messages: [ModelMessage.user("Test")],
            tools: nil,
            settings: .default,
        )

        // Should return nil for uncached request
        let cached = await cache.get(for: request)
        #expect(cached == nil)
    }

    @Test
    func `ResponseCache TTL expiration`() async throws {
        let config = CacheConfiguration(defaultTTL: 0.1) // 100ms TTL
        let cache = ResponseCache(configuration: config)

        let request = ProviderRequest(
            messages: [ModelMessage.user("Temporary")],
            tools: nil,
            settings: .default,
        )

        let response = ProviderResponse(text: "Will expire", usage: nil, finishReason: .stop)

        await cache.store(response, for: request)

        // Should retrieve immediately
        let cached1 = await cache.get(for: request)
        #expect(cached1?.text == "Will expire")

        // Wait for expiration
        try await Task.sleep(for: .milliseconds(150))

        // Should be expired
        let cached2 = await cache.get(for: request)
        #expect(cached2 == nil)
    }

    @Test
    func `ResponseCache LRU eviction`() async {
        let config = CacheConfiguration(maxEntries: 2) // Small cache
        let cache = ResponseCache(configuration: config)

        let request1 = ProviderRequest(
            messages: [ModelMessage.user("First")],
            tools: nil,
            settings: .default,
        )
        let response1 = ProviderResponse(text: "Response 1", usage: nil, finishReason: .stop)

        let request2 = ProviderRequest(
            messages: [ModelMessage.user("Second")],
            tools: nil,
            settings: .default,
        )
        let response2 = ProviderResponse(text: "Response 2", usage: nil, finishReason: .stop)

        let request3 = ProviderRequest(
            messages: [ModelMessage.user("Third")],
            tools: nil,
            settings: .default,
        )
        let response3 = ProviderResponse(text: "Response 3", usage: nil, finishReason: .stop)

        // Store first two
        await cache.store(response1, for: request1)
        await cache.store(response2, for: request2)

        // Access first to make it more recently used
        _ = await cache.get(for: request1)

        // Store third - should evict second (LRU)
        await cache.store(response3, for: request3)

        // First should still be cached (recently accessed)
        let cached1 = await cache.get(for: request1)
        #expect(cached1?.text == "Response 1")

        // Second should be evicted
        let cached2 = await cache.get(for: request2)
        #expect(cached2 == nil)

        // Third should be cached
        let cached3 = await cache.get(for: request3)
        #expect(cached3?.text == "Response 3")
    }

    @Test
    func `ResponseCache clear`() async {
        let cache = ResponseCache()

        // Store multiple entries
        for i in 1...5 {
            let request = ProviderRequest(
                messages: [ModelMessage.user("Message \(i)")],
                tools: nil,
                settings: .default,
            )
            let response = ProviderResponse(text: "Response \(i)", usage: nil, finishReason: .stop)
            await cache.store(response, for: request)
        }

        #expect(await cache.getStatistics().currentEntries == 5)
        await cache.clear()
        let statistics = await cache.getStatistics()
        #expect(statistics.currentEntries == 0)
        #expect(statistics.evictions[.cleared] == 5)
    }

    @Test
    func `ResponseCache statistics`() async {
        let cache = ResponseCache(configuration: CacheConfiguration(maxEntries: 100))
        let initial = await cache.getStatistics()
        #expect(initial.currentEntries == 0)
        #expect(initial.maxEntries == 100)
        #expect(initial.stores == 0)
        for i in 1...3 {
            let request = ProviderRequest(messages: [.user("Test \(i)")])
            await cache.store(ProviderResponse(text: "Response \(i)"), for: request)
        }
        let statistics = await cache.getStatistics()
        #expect(statistics.currentEntries == 3)
        #expect(statistics.stores == 3)
    }

    @Test
    func `CacheKey generation deterministic`() {
        let messages = [
            ModelMessage.user("Hello"),
            ModelMessage.assistant("Hi there"),
        ]

        let request1 = ProviderRequest(
            messages: messages,
            tools: nil,
            settings: GenerationSettings(temperature: 0.7),
        )

        let request2 = ProviderRequest(
            messages: messages,
            tools: nil,
            settings: GenerationSettings(temperature: 0.7),
        )

        let key1 = CacheKey(from: request1)
        let key2 = CacheKey(from: request2)

        // Same requests should generate same keys
        #expect(key1.hash == key2.hash)
        #expect(key1.model == key2.model)
    }

    @Test
    func `CacheKey differs for different requests`() {
        let request1 = ProviderRequest(
            messages: [ModelMessage.user("Hello")],
            tools: nil,
            settings: .default,
        )

        let request2 = ProviderRequest(
            messages: [ModelMessage.user("Hi")],
            tools: nil,
            settings: .default,
        )

        let request3 = ProviderRequest(
            messages: [ModelMessage.user("Hello")],
            tools: nil,
            settings: GenerationSettings(temperature: 0.5),
        )

        let key1 = CacheKey(from: request1)
        let key2 = CacheKey(from: request2)
        let key3 = CacheKey(from: request3)

        // Different messages = different keys
        #expect(key1.hash != key2.hash)

        // Different settings = different keys
        #expect(key1.hash != key3.hash)
    }

    @Test
    func `CacheKey includes reasoning effort and Anthropic thinking options`() {
        let messages = [ModelMessage.user("Hello")]
        let lowEffort = ProviderRequest(
            messages: messages,
            settings: GenerationSettings(
                reasoningEffort: .low,
                providerOptions: .init(anthropic: .init(thinking: .adaptive)),
            ),
        )
        let highEffort = ProviderRequest(
            messages: messages,
            settings: GenerationSettings(
                reasoningEffort: .high,
                providerOptions: .init(anthropic: .init(thinking: .adaptive)),
            ),
        )
        let disabledThinking = ProviderRequest(
            messages: messages,
            settings: GenerationSettings(
                reasoningEffort: .low,
                providerOptions: .init(anthropic: .init(thinking: .disabled)),
            ),
        )

        #expect(CacheKey(from: lowEffort).hash != CacheKey(from: highEffort).hash)
        #expect(CacheKey(from: lowEffort).hash != CacheKey(from: disabledThinking).hash)
    }

    @Test
    func `CacheKey includes string stop condition values`() {
        let endRequest = ProviderRequest(
            messages: [ModelMessage.user("Hello")],
            settings: GenerationSettings(stopConditions: StringStopCondition("END")),
        )
        let stopRequest = ProviderRequest(
            messages: [ModelMessage.user("Hello")],
            settings: GenerationSettings(stopConditions: StringStopCondition("STOP")),
        )

        #expect(CacheKey(from: endRequest).hash != CacheKey(from: stopRequest).hash)
    }

    @Test
    func `CacheKey encodes composite stop conditions without delimiter collisions`() async {
        let cache = ResponseCache()
        let splitRequest = ProviderRequest(
            messages: [ModelMessage.user("Hello")],
            settings: GenerationSettings(stopConditions: AnyStopCondition(
                StringStopCondition("a"),
                StringStopCondition("b"),
            )),
        )
        let joinedRequest = ProviderRequest(
            messages: [ModelMessage.user("Hello")],
            settings: GenerationSettings(stopConditions: AnyStopCondition(
                StringStopCondition("a,string:true:b"),
            )),
        )

        #expect(CacheKey(from: splitRequest).hash != CacheKey(from: joinedRequest).hash)

        await cache.store(ProviderResponse(text: "split", finishReason: .stop), for: splitRequest)
        let joinedCached = await cache.get(for: joinedRequest)

        #expect(joinedCached == nil)
    }

    @Test
    func `CacheKey marks custom stop conditions uncacheable`() {
        let request = ProviderRequest(
            messages: [ModelMessage.user("Hello")],
            settings: GenerationSettings(stopConditions: PredicateStopCondition { _, _ in false }),
        )

        let key = CacheKey(from: request)
        #expect(key.isCacheable == false)
    }

    @Test
    func `ResponseCache skips custom stop condition entries`() async {
        let cache = ResponseCache()
        let request = ProviderRequest(
            messages: [ModelMessage.user("Hello")],
            settings: GenerationSettings(stopConditions: PredicateStopCondition { _, _ in false }),
        )

        await cache.store(ProviderResponse(text: "cached", finishReason: .stop), for: request)
        let cached = await cache.get(for: request)

        #expect(cached == nil)
    }

    @Test
    func `CacheKey includes tools in hash`() {
        let tool1 = AgentTool(
            name: "tool1",
            description: "First tool",
            parameters: AgentToolParameters(properties: [:], required: []),
            namespace: "test",
        ) { _ in AnyAgentToolValue(string: "") }

        let tool2 = AgentTool(
            name: "tool2",
            description: "Second tool",
            parameters: AgentToolParameters(properties: [:], required: []),
            namespace: "test",
        ) { _ in AnyAgentToolValue(string: "") }

        let request1 = ProviderRequest(
            messages: [ModelMessage.user("Test")],
            tools: [tool1],
            settings: .default,
        )

        let request2 = ProviderRequest(
            messages: [ModelMessage.user("Test")],
            tools: [tool2],
            settings: .default,
        )

        let request3 = ProviderRequest(
            messages: [ModelMessage.user("Test")],
            tools: nil,
            settings: .default,
        )

        let key1 = CacheKey(from: request1)
        let key2 = CacheKey(from: request2)
        let key3 = CacheKey(from: request3)

        // Different tools = different keys
        #expect(key1.hash != key2.hash)
        #expect(key1.hash != key3.hash)
        #expect(key2.hash != key3.hash)
    }

    @Test
    func `CachedProvider wraps provider correctly`() async {
        let cache = ResponseCache()

        // Create a mock provider
        let mockProvider = ResponseCacheMockProvider(
            model: .openai(.gpt55),
            response: ProviderResponse(text: "Cached response", usage: nil, finishReason: .stop),
        )

        let cachedProvider = await cache.wrapProvider(mockProvider)

        #expect(cachedProvider.modelId == mockProvider.modelId)
        // Skip capabilities comparison as it doesn't have Equatable
        #expect(cachedProvider.baseURL == mockProvider.baseURL)
        #expect(cachedProvider.apiKey == mockProvider.apiKey)
    }

    @Test
    func `CachedProvider caches generateText`() async throws {
        let cache = ResponseCache()

        // Use a simple counter that can be modified in the closure
        let callCount = Box(value: 0)
        var mockProvider = ResponseCacheMockProvider(
            model: .openai(.gpt55),
            response: ProviderResponse(text: "Response", usage: nil, finishReason: .stop),
        )
        mockProvider.onGenerateText = { _ in
            callCount.value += 1
        }

        let cachedProvider = await cache.wrapProvider(mockProvider)

        let request = ProviderRequest(
            messages: [ModelMessage.user("Test")],
            tools: nil,
            settings: .default,
        )

        // First call - should hit provider
        let response1 = try await cachedProvider.generateText(request: request)
        #expect(response1.text == "Response")
        #expect(callCount.value == 1)

        // Second call - should hit cache
        let response2 = try await cachedProvider.generateText(request: request)
        #expect(response2.text == "Response") // Same response
        #expect(callCount.value == 1) // Provider not called again
    }

    @Test
    func `CachedProvider bypasses cache for query-bearing endpoints`() async throws {
        let cache = ResponseCache()
        let callCountA = Box(value: 0)
        let callCountB = Box(value: 0)
        var providerA = ResponseCacheMockProvider(
            model: .openaiCompatible(modelId: "shared-model", baseURL: "https://gateway.test/v1?tenant=a"),
            response: ProviderResponse(text: "tenant-a", usage: nil, finishReason: .stop),
            mockModelId: "shared-model",
            mockBaseURL: "https://gateway.test/v1?tenant=a",
        )
        var providerB = ResponseCacheMockProvider(
            model: .openaiCompatible(modelId: "shared-model", baseURL: "https://gateway.test/v1?tenant=b"),
            response: ProviderResponse(text: "tenant-b", usage: nil, finishReason: .stop),
            mockModelId: "shared-model",
            mockBaseURL: "https://gateway.test/v1?tenant=b",
        )
        providerA.onGenerateText = { _ in callCountA.value += 1 }
        providerB.onGenerateText = { _ in callCountB.value += 1 }

        let cachedA = await cache.wrapProvider(providerA)
        let cachedB = await cache.wrapProvider(providerB)
        let request = ProviderRequest(messages: [ModelMessage.user("Test")], tools: nil, settings: .default)

        #expect(try await cachedA.generateText(request: request).text == "tenant-a")
        #expect(try await cachedB.generateText(request: request).text == "tenant-b")
        #expect(try await cachedA.generateText(request: request).text == "tenant-a")
        #expect(try await cachedB.generateText(request: request).text == "tenant-b")
        #expect(callCountA.value == 2)
        #expect(callCountB.value == 2)
    }

    @Test
    func `CachedProvider bypasses cache for credential-bearing endpoint URLs`() async throws {
        let cache = ResponseCache()
        let callCount = Box(value: 0)
        var provider = ResponseCacheMockProvider(
            model: .openaiCompatible(modelId: "shared-model", baseURL: "https://user:secret@gateway.test/v1"),
            response: ProviderResponse(text: "uncached", usage: nil, finishReason: .stop),
            mockModelId: "shared-model",
            mockBaseURL: "https://user:secret@gateway.test/v1",
        )
        provider.onGenerateText = { _ in callCount.value += 1 }

        let cachedProvider = await cache.wrapProvider(provider)
        let request = ProviderRequest(messages: [ModelMessage.user("Test")], tools: nil, settings: .default)

        #expect(try await cachedProvider.generateText(request: request).text == "uncached")
        #expect(try await cachedProvider.generateText(request: request).text == "uncached")
        #expect(callCount.value == 2)
    }

    @Test
    func `CachedProvider bypasses cache for API-key-authenticated providers`() async throws {
        let cache = ResponseCache()
        let callCount = Box(value: 0)
        var provider = ResponseCacheMockProvider(
            model: .ollama(.llama33),
            response: ProviderResponse(text: "tenant response", usage: nil, finishReason: .stop),
            mockModelId: "llama3.3",
            mockBaseURL: "https://ollama.example.test",
            mockAPIKey: UUID().uuidString,
        )
        provider.onGenerateText = { _ in callCount.value += 1 }

        let cachedProvider = await cache.wrapProvider(provider)
        let request = ProviderRequest(messages: [ModelMessage.user("Test")], tools: nil, settings: .default)

        #expect(try await cachedProvider.generateText(request: request).text == "tenant response")
        #expect(try await cachedProvider.generateText(request: request).text == "tenant response")
        #expect(callCount.value == 2)
    }

    @Test
    func `CachedProvider bypasses providers without a stable authentication boundary`() async throws {
        let cache = ResponseCache()
        let callCount = Box(value: 0)
        var provider = ResponseCacheMockProvider(
            model: .ollama(.llama33),
            response: ProviderResponse(text: "uncached", usage: nil, finishReason: .stop),
            mockResponseCacheSafe: false,
        )
        provider.onGenerateText = { _ in callCount.value += 1 }

        let cachedProvider = await cache.wrapProvider(provider)
        let request = ProviderRequest(messages: [ModelMessage.user("Test")], tools: nil, settings: .default)

        #expect(try await cachedProvider.generateText(request: request).text == "uncached")
        #expect(try await cachedProvider.generateText(request: request).text == "uncached")
        #expect(callCount.value == 2)
    }

    @Test
    func `CachedProvider doesn't cache streaming`() async throws {
        let cache = ResponseCache()

        let callCount = Box(value: 0)
        var mockProvider = ResponseCacheMockProvider(
            model: .openai(.gpt55),
            response: ProviderResponse(text: "Test", usage: nil, finishReason: .stop),
        )
        mockProvider.onStreamText = { _ in
            callCount.value += 1
        }

        let cachedProvider = await cache.wrapProvider(mockProvider)

        let request = ProviderRequest(
            messages: [ModelMessage.user("Test")],
            tools: nil,
            settings: .default,
        )

        // Streaming should not use cache
        _ = try await cachedProvider.streamText(request: request)
        #expect(callCount.value == 1)

        _ = try await cachedProvider.streamText(request: request)
        #expect(callCount.value == 2) // Called again, not cached
    }
}

// MARK: - Mock Provider for Testing

private struct ResponseCacheMockProvider: ModelProvider, ResponseCacheSafetyProviding {
    let model: LanguageModel
    let response: ProviderResponse
    let mockModelId: String
    let mockBaseURL: String?
    let mockAPIKey: String?
    let mockResponseCacheSafe: Bool
    var onGenerateText: (@Sendable (ProviderRequest) -> Void)?
    var onStreamText: (@Sendable (ProviderRequest) -> Void)?

    var modelId: String {
        self.mockModelId
    }

    var baseURL: String? {
        self.mockBaseURL
    }

    var apiKey: String? {
        self.mockAPIKey
    }

    var capabilities: ModelCapabilities {
        ModelCapabilities()
    }

    var isResponseCacheSafe: Bool {
        self.mockResponseCacheSafe
    }

    init(
        model: LanguageModel,
        response: ProviderResponse,
        mockModelId: String = "mock-model",
        mockBaseURL: String? = nil,
        mockAPIKey: String? = nil,
        mockResponseCacheSafe: Bool = true,
        onGenerateText: (@Sendable (ProviderRequest) -> Void)? = nil,
        onStreamText: (@Sendable (ProviderRequest) -> Void)? = nil,
    ) {
        self.model = model
        self.response = response
        self.mockModelId = mockModelId
        self.mockBaseURL = mockBaseURL
        self.mockAPIKey = mockAPIKey
        self.mockResponseCacheSafe = mockResponseCacheSafe
        self.onGenerateText = onGenerateText
        self.onStreamText = onStreamText
    }

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        self.onGenerateText?(request)
        return self.response
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        self.onStreamText?(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(TextStreamDelta(type: .textDelta, content: "Stream"))
            continuation.finish()
        }
    }
}
