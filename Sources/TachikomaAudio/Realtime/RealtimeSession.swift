import CoreFoundation
import Foundation
import Tachikoma

// MARK: - Session State

/// Current state of a Realtime API session
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum SessionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error
}

// MARK: - Realtime Session

/// Manages a WebSocket session with the OpenAI Realtime API
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@MainActor
public final class RealtimeSession {
    // MARK: - Properties

    /// Unique session identifier
    public let id: String

    /// Current session state
    public private(set) var state: SessionState = .disconnected

    /// Session configuration
    public private(set) var configuration: SessionConfiguration

    /// Transport layer
    private let transport: RealtimeTransport

    /// API key for authentication
    private let apiKey: String

    /// Base URL for the Realtime API
    private let baseURL: String

    /// Event handlers
    private var eventHandlers: [String: [(RealtimeServerEvent) -> Void]] = [:]

    /// Active event stream continuation
    private var eventStreamContinuation: AsyncThrowingStream<RealtimeServerEvent, Error>.Continuation?

    /// Background tasks
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    /// Event processing queue
    private let eventQueue = DispatchQueue(label: "com.tachikoma.realtime.events", qos: .userInitiated)

    // MARK: - Initialization

    public init(
        apiKey: String,
        baseURL: String = "wss://api.openai.com/v1/realtime",
        configuration: SessionConfiguration = SessionConfiguration(),
        transport: RealtimeTransport? = nil,
    ) {
        self.id = UUID().uuidString
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.configuration = configuration
        self.transport = transport ?? WebSocketTransportFactory.createLowLatency()
    }

    // MARK: - Connection Management

    /// Connect to the Realtime API
    public func connect() async throws {
        // Connect to the Realtime API
        guard self.state == .disconnected || self.state == .error else {
            throw TachikomaError.invalidConfiguration("Already connected or connecting")
        }

        let trimmedBaseURL = self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else {
            throw TachikomaError.invalidConfiguration("Invalid base URL: <empty>")
        }

        guard var urlComponents = URLComponents(string: trimmedBaseURL) else {
            throw TachikomaError.invalidConfiguration("Invalid base URL: \(self.baseURL)")
        }
        urlComponents.queryItems = [
            URLQueryItem(name: "model", value: self.configuration.model),
        ]

        guard let url = urlComponents.url else {
            throw TachikomaError.invalidConfiguration("Invalid base URL: \(self.baseURL)")
        }

        self.state = .connecting

        // Build headers
        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "OpenAI-Beta": "realtime=v1",
        ]

        do {
            // Connect transport
            try await self.transport.connect(url: url, headers: headers)
            self.state = .connected

            // Start receiving events
            self.startReceiving()

            // Send initial session update if configured
            if self.hasNonDefaultConfiguration() {
                try await self.update(self.configuration)
            }
        } catch {
            self.state = .error
            throw error
        }
    }

    /// Disconnect from the Realtime API
    public func disconnect() async {
        // Disconnect from the Realtime API
        self.state = .disconnected

        // Cancel background tasks
        self.receiveTask?.cancel()
        self.heartbeatTask?.cancel()

        // Disconnect transport
        await self.transport.disconnect()

        // Complete event stream
        self.eventStreamContinuation?.finish()
        self.eventStreamContinuation = nil
    }

    /// Update session configuration
    public func update(_ config: SessionConfiguration) async throws {
        // Update session configuration
        guard self.state == .connected else {
            throw TachikomaError.invalidConfiguration("Not connected")
        }

        let event = RealtimeClientEvent.sessionUpdate(SessionUpdateEvent(session: RealtimeSessionConfig(from: config)))
        try await self.sendEvent(event)

        // Update local configuration
        self.configuration = config
    }

    // MARK: - Audio Management

    /// Append audio data to the input buffer
    public func appendAudio(_ data: Data) async throws {
        // Append audio data to the input buffer
        guard self.state == .connected else {
            throw TachikomaError.invalidConfiguration("Not connected")
        }

        let event = RealtimeClientEvent.inputAudioBufferAppend(
            InputAudioBufferAppendEvent(audio: data),
        )
        try await self.sendEvent(event)
    }

    /// Commit the audio buffer to create a user message
    public func commitAudio() async throws {
        // Commit the audio buffer to create a user message
        guard self.state == .connected else {
            throw TachikomaError.invalidConfiguration("Not connected")
        }

        let event = RealtimeClientEvent.inputAudioBufferCommit
        try await self.sendEvent(event)
    }

    /// Clear the audio buffer
    public func clearAudioBuffer() async throws {
        // Clear the audio buffer
        guard self.state == .connected else {
            throw TachikomaError.invalidConfiguration("Not connected")
        }

        let event = RealtimeClientEvent.inputAudioBufferClear
        try await self.sendEvent(event)
    }

    // MARK: - Conversation Management

    /// Create a conversation item
    public func createItem(_ item: ConversationItem) async throws {
        // Create a conversation item
        guard self.state == .connected else {
            throw TachikomaError.invalidConfiguration("Not connected")
        }

        let event = RealtimeClientEvent.conversationItemCreate(
            ConversationItemCreateEvent(item: item),
        )
        try await self.sendEvent(event)
    }

    /// Delete a conversation item
    public func deleteItem(id: String) async throws {
        // Delete a conversation item
        guard self.state == .connected else {
            throw TachikomaError.invalidConfiguration("Not connected")
        }

        let event = RealtimeClientEvent.conversationItemDelete(
            ConversationItemDeleteEvent(itemId: id),
        )
        try await self.sendEvent(event)
    }

    /// Truncate a conversation item
    public func truncateItem(id: String, contentIndex: Int, audioEndMs: Int) async throws {
        // Truncate a conversation item
        guard self.state == .connected else {
            throw TachikomaError.invalidConfiguration("Not connected")
        }

        let event = RealtimeClientEvent.conversationItemTruncate(
            ConversationItemTruncateEvent(
                itemId: id,
                contentIndex: contentIndex,
                audioEndMs: audioEndMs,
            ),
        )
        try await self.sendEvent(event)
    }

    // MARK: - Response Generation

    /// Create a response
    public func createResponse(_ config: ResponseCreateEvent? = nil) async throws {
        // Create a response
        guard self.state == .connected else {
            throw TachikomaError.invalidConfiguration("Not connected")
        }

        let event = RealtimeClientEvent.responseCreate(config ?? ResponseCreateEvent())
        try await self.sendEvent(event)
    }

    /// Cancel the current response
    public func cancelResponse() async throws {
        // Cancel the current response
        guard self.state == .connected else {
            throw TachikomaError.invalidConfiguration("Not connected")
        }

        let event = RealtimeClientEvent.responseCancel
        try await self.sendEvent(event)
    }

    // MARK: - Event Handling

    /// Subscribe to server events
    public func on(_ eventType: String, handler: @escaping (RealtimeServerEvent) -> Void) {
        // Subscribe to server events
        if self.eventHandlers[eventType] == nil {
            self.eventHandlers[eventType] = []
        }
        self.eventHandlers[eventType]?.append(handler)
    }

    /// Get an async stream of server events
    public func eventStream() -> AsyncThrowingStream<RealtimeServerEvent, Error> {
        // Get an async stream of server events
        AsyncThrowingStream { continuation in
            self.eventStreamContinuation = continuation
        }
    }

    // MARK: - Private Methods

    private func hasNonDefaultConfiguration() -> Bool {
        self.configuration.instructions != nil ||
            self.configuration.tools != nil ||
            self.configuration.temperature != nil ||
            self.configuration.turnDetection != nil
    }

    private func sendEvent(_ event: RealtimeClientEvent) async throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try self.encodedFrame(for: event, encoder: encoder)
        try await self.transport.send(data)
    }

    /// Encode the associated payload, not the Swift enum case name.
    /// `session.update` carries `session`. `conversation.item.create` carries `item`.
    private func encodedFrame(for event: RealtimeClientEvent, encoder: JSONEncoder) throws -> Data {
        let type = event.type
        let eventId = event.eventId
        switch event {
        case let .sessionUpdate(value):
            return try encoder.encode(EventWrapper(type: type, eventId: eventId, event: value))
        case let .inputAudioBufferAppend(value):
            return try encoder.encode(EventWrapper(type: type, eventId: eventId, event: value))
        case .inputAudioBufferCommit, .inputAudioBufferClear, .responseCancel:
            return try encoder.encode(EventWrapper(type: type, eventId: eventId, event: EmptyClientPayload()))
        case let .conversationItemCreate(value):
            return try encoder.encode(EventWrapper(type: type, eventId: eventId, event: value))
        case let .conversationItemTruncate(value):
            return try encoder.encode(EventWrapper(type: type, eventId: eventId, event: value))
        case let .conversationItemDelete(value):
            return try encoder.encode(EventWrapper(type: type, eventId: eventId, event: value))
        case let .responseCreate(value):
            let envelope = ResponseCreateEnvelope(response: value)
            return try encoder.encode(EventWrapper(type: type, eventId: eventId, event: envelope))
        }
    }

    private func startReceiving() {
        self.receiveTask = Task {
            let stream = self.transport.receive()

            do {
                for try await data in stream {
                    await self.handleReceivedData(data)
                }
            } catch {
                await self.handleConnectionError(error)
            }
        }
    }

    private func handleReceivedData(_ data: Data) async {
        do {
            // Parse the event
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            // First decode just the type
            let typeWrapper = try decoder.decode(EventTypeWrapper.self, from: data)

            // Then decode the full event based on type
            let event = try decodeServerEvent(type: typeWrapper.type, data: data)

            // Notify handlers
            await MainActor.run {
                // Send to event stream
                self.eventStreamContinuation?.yield(event)

                // Call registered handlers
                if let handlers = eventHandlers[event.type] {
                    for handler in handlers {
                        handler(event)
                    }
                }

                // Call wildcard handlers
                if let handlers = eventHandlers["*"] {
                    for handler in handlers {
                        handler(event)
                    }
                }
            }
        } catch {
            print("RealtimeSession: Failed to decode event: \(error)")
        }
    }

    private func decodeServerEvent(type: String, data: Data) throws -> RealtimeServerEvent {
        let decoder = JSONDecoder()
        // convertFromSnakeCase rewrites response_id to responseId before
        // CodingKeys are matched. Wrapper keys use those camelCase names.
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        switch type {
        case "error":
            let event = try decoder.decode(ErrorEventWrapper.self, from: data)
            return .error(RealtimeErrorEvent(error: event.error))

        case "session.created":
            let event = try decoder.decode(SessionEventWrapper.self, from: data)
            return .sessionCreated(SessionCreatedEvent(session: RealtimeSessionConfig(from: event.session)))

        case "session.updated":
            let event = try decoder.decode(SessionEventWrapper.self, from: data)
            return .sessionUpdated(SessionUpdatedEvent(session: RealtimeSessionConfig(from: event.session)))

        case "conversation.created":
            return .conversationCreated

        case "conversation.item.created":
            let event = try decoder.decode(ConversationItemEventWrapper.self, from: data)
            return .conversationItemCreated(ConversationItemCreatedEvent(item: event.item))

        case "response.created":
            let event = try decoder.decode(ResponseEventWrapper.self, from: data)
            return .responseCreated(ResponseCreatedEvent(response: event.response))

        case "response.done":
            let event = try decoder.decode(ResponseEventWrapper.self, from: data)
            return .responseDone(ResponseDoneEvent(response: event.response))

        case "response.text.delta":
            let event = try decoder.decode(ResponseTextDeltaEventWrapper.self, from: data)
            return .responseTextDelta(event.event)

        case "response.text.done":
            let event = try decoder.decode(ResponseTextDoneEventWrapper.self, from: data)
            return .responseTextDone(event.event)

        case "response.audio.delta":
            let event = try decoder.decode(ResponseAudioDeltaEventWrapper.self, from: data)
            return .responseAudioDelta(event.event)

        case "response.audio.done":
            let event = try decoder.decode(ResponseAudioDoneEventWrapper.self, from: data)
            return .responseAudioDone(event.event)

        case "response.function_call_arguments.done":
            let event = try decoder.decode(ResponseFunctionCallArgumentsDoneEventWrapper.self, from: data)
            return .responseFunctionCallArgumentsDone(event.event)

        case "input_audio_buffer.speech_started":
            return .inputAudioBufferSpeechStarted

        case "input_audio_buffer.speech_stopped":
            return .inputAudioBufferSpeechStopped

        case "input_audio_buffer.committed":
            return .inputAudioBufferCommitted

        case "input_audio_buffer.cleared":
            return .inputAudioBufferCleared

        default:
            // For unhandled events, just print a warning
            print("RealtimeSession: Unhandled event type: \(type)")
            // Return a placeholder event (we could add an .unknown case)
            return .conversationCreated
        }
    }

    private func handleConnectionError(_ error: Error) async {
        await MainActor.run {
            self.state = .error
            self.eventStreamContinuation?.finish(throwing: error)
        }
    }
}

// MARK: - Helper Types for JSON Decoding

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct EventWrapper<T: Encodable>: Encodable {
    let type: String
    let eventId: String?
    let event: T

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)

        try container.encode(self.type, forKey: DynamicCodingKey(stringValue: "type")!)
        if let eventId {
            try container.encode(eventId, forKey: DynamicCodingKey(stringValue: "event_id")!)
        }

        // Encode the event's properties directly into the container
        let eventData = try JSONEncoder().encode(self.event)
        if let eventDict = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] {
            for (key, value) in eventDict {
                if let codingKey = DynamicCodingKey(stringValue: key) {
                    try self.encodeAny(value, forKey: codingKey, container: &container)
                }
            }
        }
    }

    private func encodeAny(
        _ value: Any,
        forKey key: DynamicCodingKey,
        container: inout KeyedEncodingContainer<DynamicCodingKey>,
    ) throws {
        switch value {
        case let string as String:
            try container.encode(string, forKey: key)
        case let int as Int:
            try container.encode(int, forKey: key)
        case let double as Double:
            try container.encode(double, forKey: key)
        case let bool as Bool:
            try container.encode(bool, forKey: key)
        case let dict as [String: Any]:
            var nestedContainer = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key)
            for (nestedKey, nestedValue) in dict {
                if let nestedCodingKey = DynamicCodingKey(stringValue: nestedKey) {
                    try self.encodeAny(nestedValue, forKey: nestedCodingKey, container: &nestedContainer)
                }
            }
        case let array as [Any]:
            var nestedContainer = container.nestedUnkeyedContainer(forKey: key)
            for item in array {
                try self.encodeAnyArray(item, container: &nestedContainer)
            }
        case let number as NSNumber:
            try self.encodeNumber(number, forKey: key, container: &container)
        default:
            break
        }
    }

    private func encodeAnyArray(_ value: Any, container: inout UnkeyedEncodingContainer) throws {
        switch value {
        case let string as String:
            try container.encode(string)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let dict as [String: Any]:
            var nested = container.nestedContainer(keyedBy: DynamicCodingKey.self)
            for (key, item) in dict {
                guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
                try self.encodeAny(item, forKey: codingKey, container: &nested)
            }
        case let array as [Any]:
            var nested = container.nestedUnkeyedContainer()
            for item in array {
                try self.encodeAnyArray(item, container: &nested)
            }
        case let number as NSNumber:
            try self.encodeNumber(number, container: &container)
        default:
            break
        }
    }

    private func encodeNumber(
        _ number: NSNumber,
        forKey key: DynamicCodingKey,
        container: inout KeyedEncodingContainer<DynamicCodingKey>,
    ) throws {
        if Self.isBoolean(number) {
            try container.encode(number.boolValue, forKey: key)
        } else if Self.isWhole(number) {
            try container.encode(number.intValue, forKey: key)
        } else {
            try container.encode(number.doubleValue, forKey: key)
        }
    }

    private func encodeNumber(_ number: NSNumber, container: inout UnkeyedEncodingContainer) throws {
        if Self.isBoolean(number) {
            try container.encode(number.boolValue)
        } else if Self.isWhole(number) {
            try container.encode(number.intValue)
        } else {
            try container.encode(number.doubleValue)
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isWhole(_ number: NSNumber) -> Bool {
        let value = number.doubleValue
        return value.rounded(.towardZero) == value && value <= Double(Int.max) && value >= Double(Int.min)
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct EmptyClientPayload: Encodable {}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ResponseCreateEnvelope: Encodable {
    let response: ResponseCreateEvent
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct EventTypeWrapper: Decodable {
    let type: String
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ErrorEventWrapper: Decodable {
    let error: ResponseError
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct SessionEventWrapper: Decodable {
    let session: SessionConfiguration
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ConversationItemEventWrapper: Decodable {
    let item: ConversationItem
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ResponseEventWrapper: Decodable {
    let response: ResponseObject
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ResponseTextDeltaEventWrapper: Decodable {
    let event: ResponseTextDeltaEvent

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseId = try container.decode(String.self, forKey: .responseId)
        let itemId = try container.decode(String.self, forKey: .itemId)
        let outputIndex = try container.decode(Int.self, forKey: .outputIndex)
        let contentIndex = try container.decode(Int.self, forKey: .contentIndex)
        let delta = try container.decode(String.self, forKey: .delta)

        self.event = ResponseTextDeltaEvent(
            responseId: responseId,
            itemId: itemId,
            outputIndex: outputIndex,
            contentIndex: contentIndex,
            delta: delta,
        )
    }

    enum CodingKeys: String, CodingKey {
        case responseId
        case itemId
        case outputIndex
        case contentIndex
        case delta
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ResponseTextDoneEventWrapper: Decodable {
    let event: ResponseTextDoneEvent

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseId = try container.decode(String.self, forKey: .responseId)
        let itemId = try container.decode(String.self, forKey: .itemId)
        let outputIndex = try container.decode(Int.self, forKey: .outputIndex)
        let contentIndex = try container.decode(Int.self, forKey: .contentIndex)
        let text = try container.decode(String.self, forKey: .text)

        self.event = ResponseTextDoneEvent(
            responseId: responseId,
            itemId: itemId,
            outputIndex: outputIndex,
            contentIndex: contentIndex,
            text: text,
        )
    }

    enum CodingKeys: String, CodingKey {
        case responseId
        case itemId
        case outputIndex
        case contentIndex
        case text
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ResponseAudioDeltaEventWrapper: Decodable {
    let event: ResponseAudioDeltaEvent

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseId = try container.decode(String.self, forKey: .responseId)
        let itemId = try container.decode(String.self, forKey: .itemId)
        let outputIndex = try container.decode(Int.self, forKey: .outputIndex)
        let contentIndex = try container.decode(Int.self, forKey: .contentIndex)
        let delta = try container.decode(String.self, forKey: .delta)

        self.event = ResponseAudioDeltaEvent(
            responseId: responseId,
            itemId: itemId,
            outputIndex: outputIndex,
            contentIndex: contentIndex,
            delta: delta,
        )
    }

    enum CodingKeys: String, CodingKey {
        case responseId
        case itemId
        case outputIndex
        case contentIndex
        case delta
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ResponseAudioDoneEventWrapper: Decodable {
    let event: ResponseAudioDoneEvent

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseId = try container.decode(String.self, forKey: .responseId)
        let itemId = try container.decode(String.self, forKey: .itemId)
        let outputIndex = try container.decode(Int.self, forKey: .outputIndex)
        let contentIndex = try container.decode(Int.self, forKey: .contentIndex)

        self.event = ResponseAudioDoneEvent(
            responseId: responseId,
            itemId: itemId,
            outputIndex: outputIndex,
            contentIndex: contentIndex,
        )
    }

    enum CodingKeys: String, CodingKey {
        case responseId
        case itemId
        case outputIndex
        case contentIndex
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct ResponseFunctionCallArgumentsDoneEventWrapper: Decodable {
    let event: ResponseFunctionCallArgumentsDoneEvent

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseId = try container.decode(String.self, forKey: .responseId)
        let itemId = try container.decode(String.self, forKey: .itemId)
        let outputIndex = try container.decode(Int.self, forKey: .outputIndex)
        let callId = try container.decode(String.self, forKey: .callId)
        let name = try container.decode(String.self, forKey: .name)
        let arguments = try container.decode(String.self, forKey: .arguments)

        self.event = ResponseFunctionCallArgumentsDoneEvent(
            responseId: responseId,
            itemId: itemId,
            outputIndex: outputIndex,
            callId: callId,
            name: name,
            arguments: arguments,
        )
    }

    enum CodingKeys: String, CodingKey {
        case responseId
        case itemId
        case outputIndex
        case callId
        case name
        case arguments
    }
}
