import Foundation
import Testing
@testable import Tachikoma
@testable import TachikomaAudio

@Suite("Realtime session base URL")
@MainActor
struct RealtimeSessionBaseURLTests {
    /// Space in the host makes `URLComponents(string:)` return nil. Force-unwrap used to crash.
    private static let malformedBaseURL = "https://exa mple.com"

    @Test
    func `connect throws on malformed base URL`() async {
        let session = RealtimeSession(
            apiKey: "sk-test",
            baseURL: Self.malformedBaseURL,
            transport: NeverConnectTransport(),
        )

        await self.expectInvalidBaseURL {
            try await session.connect()
        }
    }

    @Test
    func `connect throws on empty base URL`() async {
        let session = RealtimeSession(
            apiKey: "sk-test",
            baseURL: "",
            transport: NeverConnectTransport(),
        )

        await self.expectInvalidBaseURL {
            try await session.connect()
        }
    }

    @Test
    func `connect throws on whitespace-only base URL`() async {
        let session = RealtimeSession(
            apiKey: "sk-test",
            baseURL: "   ",
            transport: NeverConnectTransport(),
        )

        await self.expectInvalidBaseURL {
            try await session.connect()
        }
    }

    @Test
    func `connect still reaches transport for a well-formed websocket URL`() async {
        let session = RealtimeSession(
            apiKey: "sk-test",
            baseURL: "wss://api.openai.com/v1/realtime",
            transport: NeverConnectTransport(),
        )

        do {
            try await session.connect()
            Issue.record("Expected the transport to be invoked after URL validation")
        } catch let error as TachikomaError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected transport apiError, got \(error)")
                return
            }
            #expect(message.contains("transport connect invoked"))
        } catch {
            Issue.record("Expected TachikomaError, got \(error)")
        }
    }

    private func expectInvalidBaseURL(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected TachikomaError.invalidConfiguration for a bad base URL")
        } catch let error as TachikomaError {
            guard case let .invalidConfiguration(message) = error else {
                Issue.record("Expected invalidConfiguration, got \(error)")
                return
            }
            #expect(message.contains("Invalid base URL"))
        } catch {
            Issue.record("Expected TachikomaError, got \(error)")
        }
    }

    @Test
    func `https chat base keeps the default realtime socket`() {
        let base = realtimeSocketBaseURL(configuredOpenAIBase: "https://api.openai.com/v1")
        #expect(base == "wss://api.openai.com/v1/realtime")
    }

    @Test
    func `blank configured base keeps the default realtime socket`() {
        #expect(realtimeSocketBaseURL(configuredOpenAIBase: nil) == "wss://api.openai.com/v1/realtime")
        #expect(realtimeSocketBaseURL(configuredOpenAIBase: "   ") == "wss://api.openai.com/v1/realtime")
    }

    @Test
    func `websocket configured base is the realtime socket`() {
        let local = "ws://127.0.0.1:9/v1/realtime"
        #expect(realtimeSocketBaseURL(configuredOpenAIBase: local) == local)
        #expect(realtimeSocketBaseURL(configuredOpenAIBase: "WSS://relay.example/v1/realtime") ==
            "WSS://relay.example/v1/realtime")
    }

    @Test
    func `snake case function call reaches the session stream`() async throws {
        let payload = Data(
            [
                #"{"type":"response.function_call_arguments.done","#,
                #""response_id":"resp_1","item_id":"item_1","#,
                #""output_index":0,"call_id":"call_1","name":"calculate","#,
                #""arguments":"{\"expression\":\"2 +\"}"}"#,
            ].joined().utf8,
        )
        let session = RealtimeSession(
            apiKey: "local-proof",
            baseURL: "ws://127.0.0.1:9/v1/realtime",
            transport: ScriptedEventTransport(payload: payload),
        )
        let stream = session.eventStream()
        try await session.connect()

        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        guard case let .responseFunctionCallArgumentsDone(done) = event else {
            Issue.record("Expected a function-call event, got \(String(describing: event))")
            await session.disconnect()
            return
        }
        #expect(done.name == "calculate")
        #expect(done.callId == "call_1")
        #expect(done.arguments == "{\"expression\":\"2 +\"}")
        await session.disconnect()
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private final class NeverConnectTransport: RealtimeTransport, @unchecked Sendable {
    func connect(url _: URL, headers _: [String: String]) async throws {
        throw TachikomaError.apiError("transport connect invoked")
    }

    func send(_: Data) async throws {}

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func disconnect() async {}

    var isConnected: Bool {
        false
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ScriptedEventTransport: RealtimeTransport {
    let payload: Data

    func connect(url _: URL, headers _: [String: String]) async throws {}

    func send(_: Data) async throws {}

    func receive() -> AsyncThrowingStream<Data, Error> {
        let payload = self.payload
        return AsyncThrowingStream { continuation in
            continuation.yield(payload)
            let created = Data(#"{"type":"conversation.created"}"#.utf8)
            continuation.yield(created)
            continuation.finish()
        }
    }

    func disconnect() async {}

    var isConnected: Bool {
        true
    }
}
