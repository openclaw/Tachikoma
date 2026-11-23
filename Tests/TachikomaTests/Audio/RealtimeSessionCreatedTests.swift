import Foundation
import Testing
@testable import TachikomaAudio

@Suite("Realtime session.created decoding")
@MainActor
struct RealtimeSessionCreatedTests {
    @Test
    func `documented beta session reaches the event stream`() async throws {
        let payload = Data(
            """
            {
              "type": "session.created",
              "event_id": "event_1",
              "session": {
                "id": "sess_1",
                "object": "realtime.session",
                "model": "gpt-realtime",
                "modalities": ["audio"],
                "instructions": "be brief",
                "voice": "marin",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": null,
                "turn_detection": {
                  "type": "server_vad",
                  "threshold": 0.5,
                  "prefix_padding_ms": 300,
                  "silence_duration_ms": 200,
                  "create_response": true
                },
                "tools": [],
                "tool_choice": "auto",
                "temperature": 0.7,
                "max_response_output_tokens": "inf"
              }
            }
            """.utf8,
        )
        let event = try await Self.firstEvent(payload)
        guard case let .sessionCreated(created) = event else {
            Issue.record("Expected session.created, got \(String(describing: event))")
            return
        }
        #expect(created.session.id == "sess_1")
        #expect(created.session.model == "gpt-realtime")
        #expect(created.session.modalities == ["audio"])
        #expect(created.session.instructions == "be brief")
        #expect(created.session.voice == nil)
        #expect(created.session.inputAudioFormat == .pcm16)
        #expect(created.session.temperature == 0.7)
        #expect(created.session.maxResponseOutputTokens == nil)
    }

    @Test
    func `numeric token limit and known voice are kept`() async throws {
        let payload = Data(
            """
            {
              "type": "session.updated",
              "event_id": "event_2",
              "session": {
                "id": "sess_2",
                "model": "gpt-realtime",
                "modalities": ["text", "audio"],
                "voice": "alloy",
                "max_response_output_tokens": 200
              }
            }
            """.utf8,
        )
        let event = try await Self.firstEvent(payload)
        guard case let .sessionUpdated(updated) = event else {
            Issue.record("Expected session.updated, got \(String(describing: event))")
            return
        }
        #expect(updated.session.id == "sess_2")
        #expect(updated.session.voice == .alloy)
        #expect(updated.session.modalities == ["text", "audio"])
        #expect(updated.session.maxResponseOutputTokens == 200)
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
            transport: OneShotRealtimeTransport(payload: payload),
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
private struct OneShotRealtimeTransport: RealtimeTransport {
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
