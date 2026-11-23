import Foundation
import Testing
@testable import Tachikoma
@testable import TachikomaAudio

@Suite("Realtime client event wire format")
@MainActor
struct RealtimeClientEventWireTests {
    @Test
    func `connect sends the session object at the top level`() async throws {
        let transport = CapturingRealtimeTransport()
        let session = RealtimeSession(
            apiKey: "local-proof",
            baseURL: "ws://127.0.0.1:9/v1/realtime",
            configuration: SessionConfiguration(
                model: "gpt-realtime",
                voice: .alloy,
                instructions: "be brief",
                tools: [
                    RealtimeTool(
                        name: "weather",
                        description: "Look up weather",
                        parameters: AgentToolParameters(),
                    ),
                ],
                toolChoice: .auto,
                temperature: 0.8,
            ),
            transport: transport,
        )

        try await session.connect()
        let frame = try Self.object(transport.frames().first)
        #expect(frame["type"] as? String == "session.update")
        #expect(frame["session_update"] == nil)
        let sessionObject = try #require(frame["session"] as? [String: Any])
        #expect(sessionObject["model"] as? String == "gpt-realtime")
        #expect(sessionObject["instructions"] as? String == "be brief")
        #expect(sessionObject["voice"] as? String == "alloy")
        #expect(sessionObject["tool_choice"] as? String == "auto")
        #expect(Self.number(sessionObject["temperature"]) == 0.8)
        let tools = try #require(sessionObject["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "weather")
        #expect(tools.first?["type"] as? String == "function")
        await session.disconnect()
    }

    @Test
    func `text item audio append and response create use api keys`() async throws {
        let transport = CapturingRealtimeTransport()
        let session = RealtimeSession(
            apiKey: "local-proof",
            baseURL: "ws://127.0.0.1:9/v1/realtime",
            configuration: SessionConfiguration(
                instructions: nil,
                turnDetection: nil,
                tools: nil,
                temperature: nil,
            ),
            transport: transport,
        )
        try await session.connect()
        #expect(transport.frames().isEmpty)

        try await session.createItem(
            ConversationItem(
                type: "message",
                role: "user",
                content: [ConversationContent(type: "input_text", text: "hi")],
            ),
        )
        try await session.appendAudio(Data("hi".utf8))
        try await session.createResponse()
        try await session.cancelResponse()

        let frames = transport.frames()
        #expect(frames.count == 4)

        let itemFrame = try Self.object(frames.first)
        #expect(itemFrame["type"] as? String == "conversation.item.create")
        #expect(itemFrame["conversation_item_create"] == nil)
        let item = try #require(itemFrame["item"] as? [String: Any])
        #expect(item["role"] as? String == "user")
        let content = try #require(item["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == "hi")

        let audioFrame = try Self.object(frames.dropFirst().first)
        #expect(audioFrame["type"] as? String == "input_audio_buffer.append")
        #expect(audioFrame["input_audio_buffer_append"] == nil)
        #expect(audioFrame["audio"] as? String == Data("hi".utf8).base64EncodedString())

        let responseFrame = try Self.object(frames.dropFirst(2).first)
        #expect(responseFrame["type"] as? String == "response.create")
        #expect(responseFrame["response_create"] == nil)
        let response = try #require(responseFrame["response"] as? [String: Any])
        #expect(response["modalities"] as? [String] == ["text", "audio"])

        let cancelFrame = try Self.object(frames.dropFirst(3).first)
        #expect(cancelFrame["type"] as? String == "response.cancel")
        #expect(cancelFrame["response_cancel"] == nil)
        #expect(cancelFrame["event_id"] is String)
        await session.disconnect()
    }

    @Test
    func `tool schema keys booleans and nulls stay on the wire`() async throws {
        let source = AnyAgentToolValue(object: [
            "type": AnyAgentToolValue(string: "object"),
            "properties": AnyAgentToolValue(object: [
                "postalCode": AnyAgentToolValue(object: [
                    "type": AnyAgentToolValue(string: "string"),
                ]),
            ]),
            "required": AnyAgentToolValue(array: [AnyAgentToolValue(string: "postalCode")]),
            "additionalProperties": AnyAgentToolValue(bool: false),
            "oneOf": AnyAgentToolValue(array: [
                AnyAgentToolValue(object: [
                    "type": AnyAgentToolValue(string: "object"),
                ]),
            ]),
            "enum": AnyAgentToolValue(array: [
                AnyAgentToolValue(bool: true),
                AnyAgentToolValue(null: ()),
            ]),
        ])
        let connected = try await self.connect(SessionConfiguration(
            instructions: nil,
            tools: [
                RealtimeTool(
                    name: "weather",
                    description: "Look up weather",
                    parameters: AgentToolParameters(sourceSchema: source),
                ),
            ],
            temperature: nil,
        ))
        let frame = connected.frame
        let session = connected.session
        let text = try #require(String(bytes: frame, encoding: .utf8))
        #expect(text.contains("\"oneOf\""))
        #expect(text.contains("\"postalCode\""))
        #expect(text.contains("\"additionalProperties\":false"))
        #expect(!text.contains("one_of"))
        #expect(!text.contains("postal_code"))
        #expect(!text.contains("additional_properties"))
        let root = try Self.object(frame)
        let sessionObject = try #require(root["session"] as? [String: Any])
        let tools = try #require(sessionObject["tools"] as? [[String: Any]])
        let parameters = try #require(tools.first?["parameters"] as? [String: Any])
        let choices = try #require(parameters["enum"] as? [Any])
        #expect(choices.count == 2)
        #expect(choices.contains { $0 is NSNull })
        await session.disconnect()
    }

    @Test
    func `function choice is an object and disabled detection is null`() async throws {
        let named = try await self.connect(SessionConfiguration(
            toolChoice: .function(name: "weather"),
        ))
        let namedObject = try Self.object(named.frame)
        let sessionObject = try #require(namedObject["session"] as? [String: Any])
        let choice = try #require(sessionObject["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "function")
        #expect(choice["name"] as? String == "weather")
        await named.session.disconnect()

        let textOnly = try await self.connect(.textOnly())
        let text = try #require(String(bytes: textOnly.frame, encoding: .utf8))
        #expect(text.contains("\"turn_detection\":null"))
        await textOnly.session.disconnect()

        let manual = try await self.connect(SessionConfiguration(
            instructions: nil,
            turnDetection: RealtimeTurnDetection(type: .serverVad, createResponse: false),
            tools: nil,
            temperature: nil,
        ))
        let manualText = try #require(String(bytes: manual.frame, encoding: .utf8))
        #expect(manualText.contains("\"create_response\":false"))
        #expect(manualText.contains("\"type\":\"server_vad\""))
        await manual.session.disconnect()
    }

    @Test
    func `public property edits replace the original wire form`() throws {
        var named = RealtimeSessionConfig(from: SessionConfiguration(toolChoice: .function(name: "weather")))
        named.toolChoice = "auto"
        let namedObject = try Self.encoded(named)
        #expect(namedObject["tool_choice"] as? String == "auto")

        var textOnly = RealtimeSessionConfig(from: .textOnly())
        textOnly.turnDetection = TurnDetection()
        let textObject = try Self.encoded(textOnly)
        let detection = try #require(textObject["turn_detection"] as? [String: Any])
        #expect(detection["type"] as? String == "server_vad")
    }

    private static func encoded(_ config: RealtimeSessionConfig) throws -> [String: Any] {
        try self.object(JSONEncoder().encode(config))
    }

    private func connect(_ configuration: SessionConfiguration) async throws
        -> (session: RealtimeSession, frame: Data)
    {
        let transport = CapturingRealtimeTransport()
        let session = RealtimeSession(
            apiKey: "local-proof",
            baseURL: "ws://127.0.0.1:9/v1/realtime",
            configuration: configuration,
            transport: transport,
        )
        try await session.connect()
        let frame = try #require(transport.frames().first)
        return (session, frame)
    }

    private static func object(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private final class CapturingRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Data] = []

    func frames() -> [Data] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.sent
    }

    func connect(url _: URL, headers _: [String: String]) async throws {}

    func send(_ data: Data) async throws {
        self.record(data)
    }

    private func record(_ data: Data) {
        self.lock.lock()
        self.sent.append(data)
        self.lock.unlock()
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func disconnect() async {}

    var isConnected: Bool {
        true
    }
}
