import Foundation
import Testing
@testable import TachikomaAudio

@Suite("Realtime handled event fields")
@MainActor
struct RealtimeHandledEventFieldTests {
    @Test
    func `response done keeps usage and status details`() async throws {
        let payload = Data(
            """
            {
              "type": "response.done",
              "event_id": "event_2",
              "response": {
                "id": "resp_1",
                "object": "realtime.response",
                "status": "completed",
                "status_details": {"type": "completed"},
                "output": [],
                "usage": {
                  "total_tokens": 12,
                  "input_tokens": 3,
                  "output_tokens": 9,
                  "input_token_details": {
                    "cached_tokens": 1,
                    "text_tokens": 2,
                    "audio_tokens": 0
                  },
                  "output_token_details": {"text_tokens": 9, "audio_tokens": 0}
                }
              }
            }
            """.utf8,
        )
        let event = try await Self.firstEvent(payload)
        guard case let .responseDone(done) = event else {
            Issue.record("Expected response.done, got \(String(describing: event))")
            return
        }
        #expect(done.response.id == "resp_1")
        #expect(done.response.statusDetails?.type == "completed")
        #expect(done.response.usage?.totalTokens == 12)
        #expect(done.response.usage?.inputTokens == 3)
        #expect(done.response.usage?.outputTokens == 9)
        #expect(done.response.usage?.inputTokenDetails?.cachedTokens == 1)
        #expect(done.response.usage?.outputTokenDetails?.textTokens == 9)
    }

    @Test
    func `conversation item keeps the function call id`() async throws {
        let payload = Data(
            """
            {
              "type": "conversation.item.created",
              "event_id": "event_3",
              "item": {
                "id": "item_1",
                "type": "function_call",
                "name": "calculate",
                "call_id": "call_1",
                "arguments": "{\\"expression\\":\\"2 + 2\\"}"
              }
            }
            """.utf8,
        )
        let event = try await Self.firstEvent(payload)
        guard case let .conversationItemCreated(created) = event else {
            Issue.record("Expected conversation.item.created, got \(String(describing: event))")
            return
        }
        #expect(created.item.id == "item_1")
        #expect(created.item.name == "calculate")
        #expect(created.item.callId == "call_1")
        #expect(created.item.arguments == "{\"expression\":\"2 + 2\"}")
    }

    private static func firstEvent(_ payload: Data) async throws -> RealtimeServerEvent? {
        let session = RealtimeSession(
            apiKey: "local-proof",
            baseURL: "ws://127.0.0.1:9/v1/realtime",
            configuration: SessionConfiguration(
                instructions: nil,
                tools: nil,
                temperature: nil,
            ),
            transport: OneShotFieldTransport(payload: payload),
        )
        let stream = session.eventStream()
        try await session.connect()
        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        await session.disconnect()
        return event
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct OneShotFieldTransport: RealtimeTransport {
    let payload: Data

    func connect(url _: URL, headers _: [String: String]) async throws {}

    func send(_: Data) async throws {}

    func receive() -> AsyncThrowingStream<Data, Error> {
        let payload = self.payload
        return AsyncThrowingStream { continuation in
            continuation.yield(payload)
            continuation.finish()
        }
    }

    func disconnect() async {}

    var isConnected: Bool {
        true
    }
}
