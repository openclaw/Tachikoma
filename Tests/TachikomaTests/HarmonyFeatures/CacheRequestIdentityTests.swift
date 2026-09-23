import Testing
@testable import Tachikoma

struct CacheRequestIdentityTests {
    @Test
    func `Different image suffixes never reuse a cached response`() async {
        let prefix = String(repeating: "a", count: 100)
        await self.expectSeparate(
            self.request(.image(.init(data: prefix + "first"))),
            self.request(.image(.init(data: prefix + "second"))),
        )
    }

    @Test
    func `Tool arguments results and error status distinguish cache entries`() async {
        let call = AgentToolCall(id: "call", name: "lookup", arguments: ["value": AnyAgentToolValue(int: 1)])
        let changed = AgentToolCall(id: "call", name: "lookup", arguments: ["value": AnyAgentToolValue(int: 2)])
        await self.expectSeparate(self.request(.toolCall(call)), self.request(.toolCall(changed)))
        let result = AgentToolResult(toolCallId: "call", result: AnyAgentToolValue(string: "first"))
        let changedResult = AgentToolResult(toolCallId: "call", result: AnyAgentToolValue(string: "second"))
        let failed = AgentToolResult(toolCallId: "call", result: result.result, isError: true)
        await self.expectSeparate(self.request(.toolResult(result)), self.request(.toolResult(changedResult)))
        await self.expectSeparate(self.request(.toolResult(result)), self.request(.toolResult(failed)))
    }

    @Test
    func `Tool schemas descriptions and routing distinguish cache entries`() async {
        func request(
            description: String = "Lookup",
            required: [String] = [],
            namespace: String? = nil,
            recipient: String? = nil,
        )
            -> ProviderRequest
        {
            let tool = AgentTool(
                name: "lookup", description: description,
                parameters: AgentToolParameters(properties: [:], required: required),
                namespace: namespace, recipient: recipient,
            ) { _ in AnyAgentToolValue(string: "fixture") }
            return ProviderRequest(messages: [.user("Lookup")], tools: [tool])
        }
        await self.expectSeparate(request(), request(description: "Changed"))
        await self.expectSeparate(request(), request(required: ["value"]))
        await self.expectSeparate(request(), request(namespace: "other"))
        await self.expectSeparate(request(), request(recipient: "other"))
    }

    @Test
    func `JSON and text output formats distinguish cache entries`() async {
        await self.expectSeparate(
            ProviderRequest(messages: [.user("Answer")], outputFormat: .text),
            ProviderRequest(messages: [.user("Answer")], outputFormat: .json),
        )
    }

    @Test
    func `Equivalent messages ignore local IDs timestamps and dictionary insertion order`() async {
        let first = AgentToolCall(id: "call", name: "lookup", arguments: [
            "a": AnyAgentToolValue(int: 1), "b": AnyAgentToolValue(int: 2),
        ])
        let second = AgentToolCall(id: "call", name: "lookup", arguments: [
            "b": AnyAgentToolValue(int: 2), "a": AnyAgentToolValue(int: 1),
        ])
        let cache = ResponseCache()
        await cache.store(ProviderResponse(text: "cached"), for: self.request(.toolCall(first)))
        #expect(await cache.get(for: self.request(.toolCall(second)))?.text == "cached")
    }

    @Test
    func `Unencodable settings are never cached`() async {
        let request = ProviderRequest(
            messages: [.user("Answer")],
            settings: GenerationSettings(providerOptions: .init(openai: .init(frequencyPenalty: .nan))),
        )
        let cache = ResponseCache()
        await cache.store(ProviderResponse(text: "cached"), for: request)
        #expect(await cache.get(for: request) == nil)
    }

    private func request(_ content: ModelMessage.ContentPart) -> ProviderRequest {
        ProviderRequest(messages: [ModelMessage(role: .user, content: [content])])
    }

    private func expectSeparate(_ first: ProviderRequest, _ second: ProviderRequest) async {
        let cache = ResponseCache()
        await cache.store(ProviderResponse(text: "cached"), for: first)
        #expect(await cache.get(for: first)?.text == "cached")
        #expect(await cache.get(for: second) == nil)
    }
}
