import Foundation
import Tachikoma

// MARK: - Event Protocol

/// Base protocol for all Realtime API events
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public protocol RealtimeEventProtocol: Sendable, Codable {
    var type: String { get }
    var eventId: String? { get }
}

// MARK: - Client Events (Events sent from client to server)

/// Client event wrapper for type-safe event handling
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum RealtimeClientEvent: RealtimeEventProtocol {
    case sessionUpdate(SessionUpdateEvent)
    case inputAudioBufferAppend(InputAudioBufferAppendEvent)
    case inputAudioBufferCommit
    case inputAudioBufferClear
    case conversationItemCreate(ConversationItemCreateEvent)
    case conversationItemTruncate(ConversationItemTruncateEvent)
    case conversationItemDelete(ConversationItemDeleteEvent)
    case responseCreate(ResponseCreateEvent)
    case responseCancel

    public var type: String {
        switch self {
        case .sessionUpdate: "session.update"
        case .inputAudioBufferAppend: "input_audio_buffer.append"
        case .inputAudioBufferCommit: "input_audio_buffer.commit"
        case .inputAudioBufferClear: "input_audio_buffer.clear"
        case .conversationItemCreate: "conversation.item.create"
        case .conversationItemTruncate: "conversation.item.truncate"
        case .conversationItemDelete: "conversation.item.delete"
        case .responseCreate: "response.create"
        case .responseCancel: "response.cancel"
        }
    }

    public var eventId: String? {
        UUID().uuidString
    }
}

// MARK: - Server Events (Events sent from server to client)

/// Server event wrapper for type-safe event handling
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum RealtimeServerEvent: RealtimeEventProtocol {
    case error(RealtimeErrorEvent)
    case sessionCreated(SessionCreatedEvent)
    case sessionUpdated(SessionUpdatedEvent)
    case conversationCreated
    case conversationItemCreated(ConversationItemCreatedEvent)
    case conversationItemInputAudioTranscriptionCompleted(TranscriptionCompletedEvent)
    case conversationItemInputAudioTranscriptionFailed(TranscriptionFailedEvent)
    case conversationItemTruncated(ConversationItemTruncatedEvent)
    case conversationItemDeleted(ConversationItemDeletedEvent)
    case inputAudioBufferCommitted
    case inputAudioBufferCleared
    case inputAudioBufferSpeechStarted
    case inputAudioBufferSpeechStopped
    case responseCreated(ResponseCreatedEvent)
    case responseInProgress
    case responseDone(ResponseDoneEvent)
    case responseOutputItemAdded(ResponseOutputItemAddedEvent)
    case responseOutputItemDone(ResponseOutputItemDoneEvent)
    case responseContentPartAdded(ResponseContentPartAddedEvent)
    case responseContentPartDone(ResponseContentPartDoneEvent)
    case responseTextDelta(ResponseTextDeltaEvent)
    case responseTextDone(ResponseTextDoneEvent)
    case responseAudioTranscriptDelta(ResponseAudioTranscriptDeltaEvent)
    case responseAudioTranscriptDone(ResponseAudioTranscriptDoneEvent)
    case responseAudioDelta(ResponseAudioDeltaEvent)
    case responseAudioDone(ResponseAudioDoneEvent)
    case responseFunctionCallArgumentsDelta(ResponseFunctionCallArgumentsDeltaEvent)
    case responseFunctionCallArgumentsDone(ResponseFunctionCallArgumentsDoneEvent)
    case rateLimitsUpdated(RateLimitsUpdatedEvent)

    public var type: String {
        switch self {
        case .error: "error"
        case .sessionCreated: "session.created"
        case .sessionUpdated: "session.updated"
        case .conversationCreated: "conversation.created"
        case .conversationItemCreated: "conversation.item.created"
        case .conversationItemInputAudioTranscriptionCompleted: "conversation.item.input_audio_transcription.completed"
        case .conversationItemInputAudioTranscriptionFailed: "conversation.item.input_audio_transcription.failed"
        case .conversationItemTruncated: "conversation.item.truncated"
        case .conversationItemDeleted: "conversation.item.deleted"
        case .inputAudioBufferCommitted: "input_audio_buffer.committed"
        case .inputAudioBufferCleared: "input_audio_buffer.cleared"
        case .inputAudioBufferSpeechStarted: "input_audio_buffer.speech_started"
        case .inputAudioBufferSpeechStopped: "input_audio_buffer.speech_stopped"
        case .responseCreated: "response.created"
        case .responseInProgress: "response.in_progress"
        case .responseDone: "response.done"
        case .responseOutputItemAdded: "response.output_item.added"
        case .responseOutputItemDone: "response.output_item.done"
        case .responseContentPartAdded: "response.content_part.added"
        case .responseContentPartDone: "response.content_part.done"
        case .responseTextDelta: "response.text.delta"
        case .responseTextDone: "response.text.done"
        case .responseAudioTranscriptDelta: "response.audio_transcript.delta"
        case .responseAudioTranscriptDone: "response.audio_transcript.done"
        case .responseAudioDelta: "response.audio.delta"
        case .responseAudioDone: "response.audio.done"
        case .responseFunctionCallArgumentsDelta: "response.function_call_arguments.delta"
        case .responseFunctionCallArgumentsDone: "response.function_call_arguments.done"
        case .rateLimitsUpdated: "rate_limits.updated"
        }
    }

    public var eventId: String? {
        nil
    }
}

// MARK: - Session Events

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct SessionUpdateEvent: Codable, Sendable {
    public let session: RealtimeSessionConfig

    public init(session: RealtimeSessionConfig) {
        self.session = session
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct SessionCreatedEvent: Codable, Sendable {
    public let session: RealtimeSessionConfig
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct SessionUpdatedEvent: Codable, Sendable {
    public let session: RealtimeSessionConfig
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct RealtimeSessionConfig: Codable, Sendable {
    public var id: String?
    public var model: String?
    public var modalities: [String]?
    public var instructions: String?
    public var voice: RealtimeVoice?

    /// Convert from SessionConfiguration
    public init(from config: SessionConfiguration) {
        self.id = nil
        self.model = config.model
        // Convert modalities from OptionSet to string array
        var modalityStrings: [String] = []
        if let modalities = config.modalities {
            if modalities.contains(.text) {
                modalityStrings.append("text")
            }
            if modalities.contains(.audio) {
                modalityStrings.append("audio")
            }
        }
        modalities = modalityStrings.isEmpty ? ["text", "audio"] : modalityStrings
        self.instructions = config.instructions
        self.voice = config.voice
    }

    public var inputAudioFormat: RealtimeAudioFormat?
    public var outputAudioFormat: RealtimeAudioFormat?
    public var inputAudioTranscription: TranscriptionConfig?
    public var turnDetection: TurnDetection?
    public var tools: [RealtimeTool]?
    public var toolChoice: String?
    public var temperature: Double?
    public var maxResponseOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case id, model, modalities, instructions, voice
        case inputAudioFormat = "input_audio_format"
        case outputAudioFormat = "output_audio_format"
        case inputAudioTranscription = "input_audio_transcription"
        case turnDetection = "turn_detection"
        case tools
        case toolChoice = "tool_choice"
        case temperature
        case maxResponseOutputTokens = "max_response_output_tokens"
    }

    public init(
        model: String = "gpt-realtime",
        voice: RealtimeVoice = .alloy,
        instructions: String? = nil,
        tools: [RealtimeTool]? = nil,
        temperature: Double = 0.8,
    ) {
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.tools = tools
        self.temperature = temperature
        self.modalities = ["text", "audio"]
        self.inputAudioFormat = .pcm16
        self.outputAudioFormat = .pcm16
    }
}

// MARK: - Audio Events

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct InputAudioBufferAppendEvent: Codable, Sendable {
    public let audio: String // Base64 encoded audio data

    public init(audio: Data) {
        self.audio = audio.base64EncodedString()
    }
}

// MARK: - Conversation Events

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ConversationItemCreateEvent: Codable, Sendable {
    public let item: ConversationItem

    public init(item: ConversationItem) {
        self.item = item
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ConversationItemCreatedEvent: Codable, Sendable {
    public let item: ConversationItem
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ConversationItemTruncateEvent: Codable, Sendable {
    public let itemId: String
    public let contentIndex: Int
    public let audioEndMs: Int

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case contentIndex = "content_index"
        case audioEndMs = "audio_end_ms"
    }

    public init(itemId: String, contentIndex: Int, audioEndMs: Int) {
        self.itemId = itemId
        self.contentIndex = contentIndex
        self.audioEndMs = audioEndMs
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ConversationItemDeleteEvent: Codable, Sendable {
    public let itemId: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
    }

    public init(itemId: String) {
        self.itemId = itemId
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ConversationItemTruncatedEvent: Codable, Sendable {
    public let itemId: String
    public let contentIndex: Int
    public let audioEndMs: Int

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case contentIndex = "content_index"
        case audioEndMs = "audio_end_ms"
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ConversationItemDeletedEvent: Codable, Sendable {
    public let itemId: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ConversationItem: Codable, Sendable {
    public let id: String
    public let type: String // "message", "function_call", "function_call_result"
    public let role: String? // "user", "assistant", "system"
    public let content: [ConversationContent]?
    public let callId: String?
    public let name: String?
    public let arguments: String?
    public let output: String?

    enum CodingKeys: String, CodingKey {
        case id, type, role, content
        case callId = "call_id"
        case name, arguments, output
    }

    public init(
        id: String = UUID().uuidString,
        type: String,
        role: String? = nil,
        content: [ConversationContent]? = nil,
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.content = content
        self.callId = nil
        self.name = nil
        self.arguments = nil
        self.output = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleEventKey.self)
        self.id = try container.decode(String.self, forKey: FlexibleEventKey("id"))
        self.type = try container.decode(String.self, forKey: FlexibleEventKey("type"))
        self.role = try container.decodeIfPresent(String.self, forKey: FlexibleEventKey("role"))
        self.content = try container.decodeIfPresent(
            [ConversationContent].self,
            forKey: FlexibleEventKey("content"),
        )
        let camelCallID = try container.decodeIfPresent(String.self, forKey: FlexibleEventKey("callId"))
        let snakeCallID = try container.decodeIfPresent(String.self, forKey: FlexibleEventKey("call_id"))
        self.callId = camelCallID ?? snakeCallID
        self.name = try container.decodeIfPresent(String.self, forKey: FlexibleEventKey("name"))
        self.arguments = try container.decodeIfPresent(String.self, forKey: FlexibleEventKey("arguments"))
        self.output = try container.decodeIfPresent(String.self, forKey: FlexibleEventKey("output"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.type, forKey: .type)
        try container.encodeIfPresent(self.role, forKey: .role)
        try container.encodeIfPresent(self.content, forKey: .content)
        try container.encodeIfPresent(self.callId, forKey: .callId)
        try container.encodeIfPresent(self.name, forKey: .name)
        try container.encodeIfPresent(self.arguments, forKey: .arguments)
        try container.encodeIfPresent(self.output, forKey: .output)
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct FlexibleEventKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue _: Int) {
        nil
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ConversationContent: Codable, Sendable {
    public let type: String // "text", "audio"
    public let text: String?
    public let audio: String? // Base64 encoded
    public let transcript: String?

    public init(type: String, text: String? = nil, audio: String? = nil, transcript: String? = nil) {
        self.type = type
        self.text = text
        self.audio = audio
        self.transcript = transcript
    }
}

// MARK: - Response Events

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseCreateEvent: Codable, Sendable {
    public let modalities: [String]?
    public let instructions: String?
    public let voice: RealtimeVoice?
    public let outputAudioFormat: RealtimeAudioFormat?
    public let tools: [RealtimeTool]?
    public let toolChoice: String?
    public let temperature: Double?
    public let maxOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case modalities, instructions, voice
        case outputAudioFormat = "output_audio_format"
        case tools
        case toolChoice = "tool_choice"
        case temperature
        case maxOutputTokens = "max_output_tokens"
    }

    public init(
        modalities: [String]? = ["text", "audio"],
        instructions: String? = nil,
        voice: RealtimeVoice? = nil,
        temperature: Double? = nil,
    ) {
        self.modalities = modalities
        self.instructions = instructions
        self.voice = voice
        self.outputAudioFormat = .pcm16
        self.tools = nil
        self.toolChoice = nil
        self.temperature = temperature
        self.maxOutputTokens = nil
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseCreatedEvent: Codable, Sendable {
    public let response: ResponseObject
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseDoneEvent: Codable, Sendable {
    public let response: ResponseObject
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseObject: Codable, Sendable {
    public let id: String
    public let object: String
    public let status: String
    public let statusDetails: StatusDetails?
    public let output: [ResponseOutput]
    public let usage: ResponseUsage?

    enum CodingKeys: String, CodingKey {
        case id, object, status, statusDetails, output, usage
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct StatusDetails: Codable, Sendable {
    public let type: String?
    public let reason: String?
    public let error: ResponseError?
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseError: Codable, Sendable {
    public let type: String
    public let code: String?
    public let message: String
    public let param: String?
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseOutput: Codable, Sendable {
    public let id: String
    public let object: String
    public let type: String
    public let role: String?
    public let content: [ResponseContent]?
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseContent: Codable, Sendable {
    public let type: String
    public let text: String?
    public let audio: String?
    public let transcript: String?
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseUsage: Codable, Sendable {
    public let totalTokens: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let inputTokenDetails: TokenDetails?
    public let outputTokenDetails: TokenDetails?

    enum CodingKeys: String, CodingKey {
        case totalTokens, inputTokens, outputTokens, inputTokenDetails, outputTokenDetails
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TokenDetails: Codable, Sendable {
    public let cachedTokens: Int?
    public let textTokens: Int?
    public let audioTokens: Int?

    enum CodingKeys: String, CodingKey {
        case cachedTokens, textTokens, audioTokens
    }
}

// MARK: - Streaming Response Events

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseOutputItemAddedEvent: Codable, Sendable {
    public let responseId: String
    public let outputIndex: Int
    public let item: ResponseOutput

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case outputIndex = "output_index"
        case item
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseOutputItemDoneEvent: Codable, Sendable {
    public let responseId: String
    public let outputIndex: Int
    public let item: ResponseOutput

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case outputIndex = "output_index"
        case item
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseContentPartAddedEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let part: ResponseContent

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case part
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseContentPartDoneEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let part: ResponseContent

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case part
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseTextDeltaEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let delta: String

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case delta
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseTextDoneEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let text: String

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case text
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseAudioTranscriptDeltaEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let delta: String

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case delta
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseAudioTranscriptDoneEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let transcript: String

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case transcript
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseAudioDeltaEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let delta: String // Base64 encoded audio

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case delta
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseAudioDoneEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
}

// MARK: - Function Calling Events

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseFunctionCallArgumentsDeltaEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let callId: String
    public let delta: String

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case callId = "call_id"
        case delta
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ResponseFunctionCallArgumentsDoneEvent: Codable, Sendable {
    public let responseId: String
    public let itemId: String
    public let outputIndex: Int
    public let callId: String
    public let name: String
    public let arguments: String

    enum CodingKeys: String, CodingKey {
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case callId = "call_id"
        case name, arguments
    }
}

// MARK: - Transcription Events

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TranscriptionCompletedEvent: Codable, Sendable {
    public let itemId: String
    public let contentIndex: Int
    public let transcript: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case contentIndex = "content_index"
        case transcript
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TranscriptionFailedEvent: Codable, Sendable {
    public let itemId: String
    public let contentIndex: Int
    public let error: ResponseError

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case contentIndex = "content_index"
        case error
    }
}

// MARK: - Rate Limits

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct RateLimitsUpdatedEvent: Codable, Sendable {
    public let rateLimits: [RateLimit]

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct RateLimit: Codable, Sendable {
    public let name: String
    public let limit: Int
    public let remaining: Int
    public let resetSeconds: Double

    enum CodingKeys: String, CodingKey {
        case name, limit, remaining
        case resetSeconds = "reset_seconds"
    }
}

// MARK: - Error Event

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct RealtimeErrorEvent: Codable, Sendable {
    public let error: ResponseError
}

// MARK: - Client Event Extensions (already defined in enum)

// MARK: - Supporting Types

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum RealtimeAudioFormat: String, Codable, Sendable {
    case pcm16
    case g711Ulaw = "g711_ulaw"
    case g711Alaw = "g711_alaw"
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum RealtimeVoice: String, Codable, Sendable {
    case alloy
    case echo
    case fable
    case onyx
    case nova
    case shimmer
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TurnDetection: Codable, Sendable {
    public let type: String
    public let threshold: Double?
    public let prefixPaddingMs: Int?
    public let silenceDurationMs: Int?

    enum CodingKeys: String, CodingKey {
        case type, threshold
        case prefixPaddingMs = "prefix_padding_ms"
        case silenceDurationMs = "silence_duration_ms"
    }

    public init(
        type: String = "server_vad",
        threshold: Double = 0.5,
        prefixPaddingMs: Int = 300,
        silenceDurationMs: Int = 200,
    ) {
        self.type = type
        self.threshold = threshold
        self.prefixPaddingMs = prefixPaddingMs
        self.silenceDurationMs = silenceDurationMs
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TranscriptionConfig: Codable, Sendable {
    public let model: String?

    public init(model: String = "whisper-1") {
        self.model = model
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct RealtimeTool: Codable, Sendable {
    public let type: String
    public let name: String
    public let description: String
    public let parameters: AgentToolParameters // Use the existing type-safe AgentToolParameters

    enum CodingKeys: String, CodingKey {
        case type, name, description, parameters
    }

    public init(name: String, description: String, parameters: AgentToolParameters) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        let sourceSchema = try container.decode(AnyAgentToolValue.self, forKey: .parameters)
        self.parameters = AgentToolParameters(sourceSchema: sourceSchema)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type, forKey: .type)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.description, forKey: .description)
        try container.encode(self.parameters.schemaValue(), forKey: .parameters)
    }
}
