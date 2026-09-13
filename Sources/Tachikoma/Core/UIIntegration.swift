import Foundation

// MARK: - UI Message Types

/// Message format optimized for UI display
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct UIMessage: Sendable, Codable {
    public let id: String
    public let role: ModelMessage.Role
    public let content: String
    public let attachments: [UIAttachment]
    public let toolCalls: [AgentToolCall]?
    public let metadata: [String: String]
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        role: ModelMessage.Role,
        content: String,
        attachments: [UIAttachment] = [],
        toolCalls: [AgentToolCall]? = nil,
        metadata: [String: String] = [:],
        timestamp: Date = Date(),
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.metadata = metadata
        self.timestamp = timestamp
    }
}

/// Attachment in UI messages
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct UIAttachment: Sendable, Codable {
    public let id: String
    public let type: AttachmentType
    public let url: URL?
    public let data: Data?
    public let mimeType: String
    public let name: String?

    public enum AttachmentType: String, Sendable, Codable {
        case image
        case document
        case audio
        case video
        case file
    }

    public init(
        id: String = UUID().uuidString,
        type: AttachmentType,
        url: URL? = nil,
        data: Data? = nil,
        mimeType: String,
        name: String? = nil,
    ) {
        self.id = id
        self.type = type
        self.url = url
        self.data = data
        self.mimeType = mimeType
        self.name = name
    }
}

/// Streaming chunk for UI updates
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum UIMessageChunk: Sendable {
    case text(String)
    case toolCallStart(id: String, name: String)
    case toolCallArgument(id: String, argument: String)
    case toolCallEnd(id: String)
    case attachment(UIAttachment)
    case metadata([String: String])
    case error(Error)
    case done
}

// MARK: - Message Conversion

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension [UIMessage] {
    /// Convert UI messages to model messages for API calls
    public func toModelMessages() -> [ModelMessage] {
        // Convert UI messages to model messages for API calls
        map { uiMessage in
            var contentParts: [ModelMessage.ContentPart] = [.text(uiMessage.content)]

            // Add attachments as content parts
            for attachment in uiMessage.attachments {
                if attachment.type == .image {
                    if let data = attachment.data {
                        let base64 = data.base64EncodedString()
                        let imageContent = ModelMessage.ContentPart.ImageContent(
                            data: base64,
                            mimeType: attachment.mimeType,
                        )
                        contentParts.append(.image(imageContent))
                    } else if let url = attachment.url {
                        // For URL-based images, encode the URL as data
                        let urlString = url.absoluteString
                        let imageContent = ModelMessage.ContentPart.ImageContent(
                            data: urlString,
                            mimeType: attachment.mimeType,
                        )
                        contentParts.append(.image(imageContent))
                    }
                }
            }

            // Add tool calls
            if let toolCalls = uiMessage.toolCalls {
                for toolCall in toolCalls {
                    contentParts.append(.toolCall(toolCall))
                }
            }

            return ModelMessage(
                role: uiMessage.role,
                content: contentParts,
            )
        }
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension [ModelMessage] {
    /// Convert model messages to UI messages for display
    public func toUIMessages() -> [UIMessage] {
        // Convert model messages to UI messages for display
        compactMap { modelMessage in
            guard !modelMessage.isProviderNativeReasoningBlock else { return nil }
            guard !modelMessage.isSyntheticReasoningBoundary else { return nil }
            var content = ""
            var attachments: [UIAttachment] = []
            var toolCalls: [AgentToolCall] = []

            for part in modelMessage.content {
                switch part {
                case let .text(text):
                    content += text
                case let .image(imageContent):
                    // Check if it's base64 data or a URL
                    if imageContent.data.starts(with: "http") {
                        // It's a URL stored in the data field
                        if let imageUrl = URL(string: imageContent.data) {
                            attachments.append(UIAttachment(
                                type: .image,
                                url: imageUrl,
                                mimeType: imageContent.mimeType,
                            ))
                        }
                    } else {
                        // It's base64 data
                        if let data = Data(base64Encoded: imageContent.data) {
                            attachments.append(UIAttachment(
                                type: .image,
                                data: data,
                                mimeType: imageContent.mimeType,
                            ))
                        }
                    }
                case .reasoning:
                    continue
                case let .toolCall(call):
                    toolCalls.append(call)
                case let .toolResult(result):
                    content += "\n[Tool Result: \(result.result)]"
                }
            }

            return UIMessage(
                role: modelMessage.role,
                content: content,
                attachments: attachments,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            )
        }
    }
}

extension ModelMessage {
    fileprivate var isProviderNativeReasoningBlock: Bool {
        guard channel == .thinking, let customData = metadata?.customData else { return false }
        return customData["anthropic.thinking.model"] != nil ||
            customData["anthropic.thinking.type"] != nil ||
            customData["anthropic.thinking.signature"] != nil ||
            customData["tachikoma.reasoning.provider"] != nil
    }

    fileprivate var isSyntheticReasoningBoundary: Bool {
        metadata?.customData?["tachikoma.internal.boundary"] == "reasoning_only"
    }
}

// MARK: - Streaming Extensions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension StreamTextResult {
    /// Convert streaming result to UI message chunks for real-time updates
    public func toUIMessageStream() -> AsyncStream<UIMessageChunk> {
        // Convert streaming result to UI message chunks for real-time updates
        AsyncStream { continuation in
            let producer = Task {
                defer { continuation.finish() }
                do {
                    for try await delta in self.stream {
                        try Task.checkCancellation()
                        switch delta.type {
                        case .textDelta:
                            if let content = delta.content {
                                continuation.yield(.text(content))
                            }
                        case .toolCall:
                            if let toolCall = delta.toolCall {
                                continuation.yield(.toolCallStart(id: toolCall.id, name: toolCall.name))
                                // Note: Arguments might come in separate events
                            }
                        case .done:
                            continuation.yield(.done)
                            return
                        default:
                            // Handle other event types as needed
                            break
                        }
                    }
                } catch {
                    continuation.yield(.error(error))
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Convert streaming result to simple text stream
    public func toTextStream() -> AsyncStream<String> {
        // Convert streaming result to simple text stream
        AsyncStream { continuation in
            let producer = Task {
                defer { continuation.finish() }
                do {
                    for try await delta in self.stream {
                        try Task.checkCancellation()
                        if delta.type == .textDelta, let content = delta.content {
                            continuation.yield(content)
                        } else if delta.type == .done {
                            return
                        }
                    }
                } catch {
                    // This convenience stream intentionally omits provider errors.
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Collect all text from stream into a single string
    public func collectText() async throws -> String {
        // Collect all text from stream into a single string
        var result = ""
        for try await delta in stream {
            if delta.type == .textDelta, let content = delta.content {
                result += content
            }
        }
        return result
    }
}

// MARK: - Response Helpers

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct UIStreamResponse: Sendable {
    public let stream: AsyncStream<UIMessageChunk>
    public let messageId: String
    public let role: ModelMessage.Role

    public init(
        stream: AsyncStream<UIMessageChunk>,
        messageId: String = UUID().uuidString,
        role: ModelMessage.Role = .assistant,
    ) {
        self.stream = stream
        self.messageId = messageId
        self.role = role
    }

    /// Collect complete message from stream
    public func collectMessage() async -> UIMessage {
        // Collect complete message from stream
        var content = ""
        var toolCalls: [AgentToolCall] = []
        var currentToolCall: (id: String, name: String, arguments: String)?

        for await chunk in self.stream {
            switch chunk {
            case let .text(text):
                content += text
            case let .toolCallStart(id, name):
                currentToolCall = (id, name, "")
            case let .toolCallArgument(id, argument):
                if currentToolCall?.id == id {
                    currentToolCall?.arguments += argument
                }
            case let .toolCallEnd(id):
                if let tool = currentToolCall, tool.id == id {
                    let args: [String: Any] = (try? JSONSerialization.jsonObject(
                        with: tool.arguments.data(using: .utf8) ?? Data(),
                    ) as? [String: Any]) ?? [:]

                    do {
                        try toolCalls.append(AgentToolCall(
                            id: tool.id,
                            name: tool.name,
                            arguments: args,
                        ))
                    } catch {
                        // Skip invalid tool call
                        continue
                    }
                    currentToolCall = nil
                }
            case .done, .error:
                break
            default:
                break
            }
        }

        return UIMessage(
            id: self.messageId,
            role: self.role,
            content: content,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
        )
    }
}

// MARK: - Convenience Functions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func convertToModelMessages(_ uiMessages: [UIMessage]) -> [ModelMessage] {
    uiMessages.toModelMessages()
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func convertToUIMessages(_ modelMessages: [ModelMessage]) -> [UIMessage] {
    modelMessages.toUIMessages()
}
