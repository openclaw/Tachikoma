import Foundation
import Testing
@testable import Tachikoma
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class IncrementalOllamaTransportURLProtocol: URLProtocol {
    private static let terminalGate = DispatchSemaphore(value: 0)

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: self.request.url ?? URL(string: "http://localhost:11434/api/chat")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"],
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"first"},"done":false}

        """.utf8))

        _ = Self.terminalGate.wait(timeout: .now() + 2)
        self.client?.urlProtocol(self, didLoad: Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":" second"},"done":true,"done_reason":"stop"}

        """.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func releaseTerminalChunk() {
        self.terminalGate.signal()
    }
}

private final class DelegatedOllamaTransportURLProtocol: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let challengeSender = OllamaAuthenticationChallengeSender()
        let protectionSpace = URLProtectionSpace(
            host: "localhost",
            port: 11434,
            protocol: "http",
            realm: "ollama-test",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: challengeSender,
        )
        self.client?.urlProtocol(self, didReceive: challenge)

        let response = HTTPURLResponse(
            url: self.request.url ?? URL(string: "http://localhost:11434/api/chat")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"],
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data("""
        {"model":"llama3.3","message":{"role":"assistant","content":"delegated"},\
        "done":true,"done_reason":"stop"}

        """.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OllamaAuthenticationChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}

    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}

    func cancel(_: URLAuthenticationChallenge) {}

    func performDefaultHandling(for _: URLAuthenticationChallenge) {}

    func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {}
}

private final class OllamaSessionDelegateProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var receivedChallenge = false

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive _: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        self.lock.withLock { self.receivedChallenge = true }
        completionHandler(
            .useCredential,
            URLCredential(user: "test-user", password: "pw", persistence: .none),
        )
    }

    func waitForChallenge() async -> Bool {
        for _ in 0..<100 {
            if self.lock.withLock({ self.receivedChallenge }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return self.lock.withLock { self.receivedChallenge }
    }
}

struct OllamaStreamingToolCallTests {
    /// Captured verbatim from a live `POST /api/chat` with `"stream": true` and a
    /// tools array (ollama 0.x, llama3.1:8b). Before this was decoded, the stream
    /// parser only read `content`/`done`, so tool calls were silently dropped and
    /// the agent reported success having executed nothing.
    private static let toolCallChunk = """
    {"model":"llama3.1:8b","created_at":"2026-07-10T09:40:30.514383Z","message":{"role":"assistant",\
    "content":"","tool_calls":[{"id":"call_icagibop","function":{"index":0,"name":"get_weather",\
    "arguments":{"city":"Paris"}}}]},"done":false}
    """

    private static let doneChunk = """
    {"model":"llama3.1:8b","created_at":"2026-07-10T09:40:30.52607Z",\
    "message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}
    """

    private static let recursiveToolCallChunk = """
    {"model":"llama3.1:8b","message":{"role":"assistant","content":"","tool_calls":[{"function":{
    "index":0,"name":"run_plan","arguments":{"enabled":true,"metadata":{"attempt":2,"note":null},
    "steps":["inspect",3,false,null,{"kind":"finish"}]}}}]},"done":false}
    """

    private static let zeroArgumentToolCallChunk = """
    {"model":"llama3.1:8b","message":{"role":"assistant","content":"","tool_calls":[{"function":{
    "index":0,"name":"get_status"}}]},"done":false}
    """

    @Test
    func `stream chunk decodes native tool calls`() throws {
        let data = try #require(Self.toolCallChunk.data(using: .utf8))
        let chunk = try JSONDecoder().decode(OllamaStreamChunk.self, from: data)

        #expect(chunk.done == false)
        // Ollama pairs an empty content string with the tool calls.
        #expect(chunk.message.content?.isEmpty == true)
        let calls = try #require(chunk.message.toolCalls)
        #expect(calls.count == 1)
        #expect(calls[0].function.name == "get_weather")
        #expect(calls[0].function.arguments["city"]?.stringValue == "Paris")
    }

    @Test
    func `stream chunk without tool calls still decodes`() throws {
        let data = try #require(Self.doneChunk.data(using: .utf8))
        let chunk = try JSONDecoder().decode(OllamaStreamChunk.self, from: data)

        #expect(chunk.done == true)
        #expect(chunk.doneReason == "stop")
        #expect(chunk.message.toolCalls == nil)
    }

    @Test
    func `decoded tool call converts to an AgentToolCall`() throws {
        let data = try #require(Self.toolCallChunk.data(using: .utf8))
        let chunk = try JSONDecoder().decode(OllamaStreamChunk.self, from: data)
        let ollamaCall = try #require(chunk.message.toolCalls?.first)

        let agentCall = OllamaProvider.convertOllamaToolCall(ollamaCall)

        #expect(agentCall.name == "get_weather")
        #expect(agentCall.arguments["city"]?.stringValue == "Paris")
        #expect(agentCall.id.hasPrefix("ollama_"))
    }

    @Test
    func `stream chunk preserves recursive tool arguments`() throws {
        let data = try #require(Self.recursiveToolCallChunk.data(using: .utf8))
        let chunk = try JSONDecoder().decode(OllamaStreamChunk.self, from: data)
        let call = try #require(chunk.message.toolCalls?.first)

        #expect(call.function.index == 0)
        #expect(call.function.arguments["enabled"]?.boolValue == true)
        #expect(call.function.arguments["metadata"]?.objectValue?["attempt"]?.intValue == 2)
        #expect(call.function.arguments["metadata"]?.objectValue?["note"]?.isNull == true)

        let steps = try #require(call.function.arguments["steps"]?.arrayValue)
        #expect(steps[0].stringValue == "inspect")
        #expect(steps[1].intValue == 3)
        #expect(steps[2].boolValue == false)
        #expect(steps[3].isNull)
        #expect(steps[4].objectValue?["kind"]?.stringValue == "finish")

        let converted = OllamaProvider.convertOllamaToolCall(call)
        #expect(converted.arguments == call.function.arguments)
    }

    @Test
    func `stream chunk defaults omitted tool arguments to empty`() throws {
        let data = try #require(Self.zeroArgumentToolCallChunk.data(using: .utf8))
        let chunk = try JSONDecoder().decode(OllamaStreamChunk.self, from: data)
        let call = try #require(chunk.message.toolCalls?.first)

        #expect(call.function.name == "get_status")
        #expect(call.function.arguments.isEmpty)
        #expect(OllamaProvider.convertOllamaToolCall(call).arguments.isEmpty)
    }

    @Test
    func `delegate transport emits a line before the response completes`() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IncrementalOllamaTransportURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }

        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setBaseURL("http://localhost:11434", for: .ollama)
        let provider = try OllamaProvider(model: .llama33, configuration: configuration, urlSession: session)
        let clock = ContinuousClock()
        let startedAt = clock.now
        let stream = try await provider.streamText(request: ProviderRequest(messages: [.user("Hello")]))
        var iterator = stream.makeAsyncIterator()

        let first = try #require(try await iterator.next())
        #expect(first.type == .textDelta)
        #expect(first.content == "first")
        #expect(startedAt.duration(to: clock.now) < .seconds(1))

        IncrementalOllamaTransportURLProtocol.releaseTerminalChunk()
        let second = try #require(try await iterator.next())
        let done = try #require(try await iterator.next())
        #expect(second.content == " second")
        #expect(done.finishReason == .stop)
        #expect(try await iterator.next() == nil)
    }

    @Test
    func `streaming preserves the supplied session delegate`() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [DelegatedOllamaTransportURLProtocol.self]
        let delegate = OllamaSessionDelegateProbe()
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setBaseURL("http://localhost:11434", for: .ollama)
        let provider = try OllamaProvider(model: .llama33, configuration: configuration, urlSession: session)
        #expect(provider.reasoningReplayIdentity == nil)

        let stream = try await provider.streamText(request: ProviderRequest(messages: [.user("Hello")]))
        var text = ""
        for try await delta in stream where delta.type == .textDelta {
            text += delta.content ?? ""
        }

        #expect(text == "delegated")
        let preservedDelegate = await delegate.waitForChallenge()
        #expect(preservedDelegate)
    }
}
