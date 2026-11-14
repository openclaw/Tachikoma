import Foundation

struct AnthropicReasoningReplayTarget {
    let provider: String
    let modelId: String
    let endpointIdentity: String?
    let allowsLegacyUnknown: Bool

    func matches(_ customData: [String: String]) -> Bool {
        guard
            let endpointIdentity = self.endpointIdentity, customData["tachikoma.reasoning.provider"] == self.provider,
            customData["tachikoma.reasoning.model"] == self.modelId else
        {
            return false
        }
        return customData["tachikoma.reasoning.base_url"] == endpointIdentity
    }
}

enum AnthropicMessageConversion {
    static func convertMessagesToAnthropic(
        _ messages: [ModelMessage],
        thinkingEnabled: Bool,
        reasoningTarget: AnthropicReasoningReplayTarget? = nil,
    ) throws
        -> (String?, [AnthropicMessage])
    {
        var systemMessage: String?
        var anthropicMessages: [AnthropicMessage] = []
        var pendingThinkingBlocks: [(text: String, signature: String?, type: String)] = []
        let thinkingSignatureKey = "anthropic.thinking.signature"
        let thinkingTypeKey = "anthropic.thinking.type"

        func appendThinkingBlocks(
            _ pendingBlocks: [(text: String, signature: String?, type: String)],
            to content: inout [AnthropicContent],
        ) {
            for pending in pendingBlocks {
                if pending.type == "redacted_thinking" {
                    content.append(.redactedThinking(.init(
                        type: "redacted_thinking",
                        data: pending.text,
                    )))
                } else if let signature = pending.signature {
                    content.append(.thinking(.init(
                        type: "thinking",
                        thinking: pending.text,
                        signature: signature,
                    )))
                }
            }
        }

        for message in messages {
            switch message.role {
            case .system:
                // Anthropic uses a separate system field
                systemMessage = message.content.compactMap { part in
                    if case let .text(text) = part {
                        return text
                    }
                    return nil
                }.joined()
            case .user:
                let content = message.content.compactMap { contentPart -> AnthropicContent? in
                    switch contentPart {
                    case let .text(text):
                        .text(AnthropicContent.TextContent(type: "text", text: text))
                    case let .image(imageContent):
                        .image(AnthropicContent.ImageContent(
                            type: "image",
                            source: AnthropicContent.ImageSource(
                                type: "base64",
                                mediaType: imageContent.mimeType,
                                data: imageContent.data,
                            ),
                        ))
                    case .reasoning, .toolCall, .toolResult:
                        nil // Skip tool calls and results in user messages
                    }
                }
                anthropicMessages.append(AnthropicMessage(role: "user", content: content))
            case .assistant:
                if message.channel == .thinking {
                    let text = message.content.compactMap { part -> String? in
                        if case let .text(text) = part {
                            return text
                        }
                        return nil
                    }.joined()
                    let signature = message.metadata?.customData?[thinkingSignatureKey]
                    let type = message.metadata?.customData?[thinkingTypeKey] ?? "thinking"
                    let customData = message.metadata?.customData ?? [:]
                    if
                        customData["tachikoma.reasoning.provider"] != nil ||
                        customData["tachikoma.reasoning.model"] != nil ||
                        customData["tachikoma.reasoning.base_url"] != nil ||
                        customData["anthropic.thinking.model"] != nil
                    {
                        guard reasoningTarget?.matches(customData) == true else {
                            continue
                        }
                    } else if reasoningTarget?.allowsLegacyUnknown != true {
                        continue
                    }
                    if type == "redacted_thinking" {
                        pendingThinkingBlocks.append((text: text, signature: nil, type: type))
                    } else if let signature, !signature.isEmpty {
                        pendingThinkingBlocks.append((text: text, signature: signature, type: type))
                    }
                    continue
                }

                var content: [AnthropicContent] = []

                if thinkingEnabled, !pendingThinkingBlocks.isEmpty {
                    appendThinkingBlocks(pendingThinkingBlocks, to: &content)
                    pendingThinkingBlocks.removeAll()
                }

                // Process each content part
                for part in message.content {
                    switch part {
                    case let .text(text):
                        if !text.isEmpty {
                            content.append(.text(AnthropicContent.TextContent(type: "text", text: text)))
                        }
                    case let .toolCall(toolCall):
                        // Convert tool call to Anthropic format
                        var arguments: [String: Any] = [:]
                        for (key, value) in toolCall.arguments {
                            // Convert AnyAgentToolValue to Any using toJSON
                            if let jsonValue = try? value.toJSON() {
                                arguments[key] = jsonValue
                            }
                        }
                        content.append(.toolUse(AnthropicContent.ToolUseContent(
                            id: toolCall.id,
                            name: toolCall.name,
                            input: arguments,
                        )))
                    default:
                        continue
                    }
                }

                // Only add message if it has content
                if !content.isEmpty {
                    anthropicMessages.append(AnthropicMessage(role: "assistant", content: content))
                }
            case .tool:
                // Process tool results
                var content: [AnthropicContent] = []

                for part in message.content {
                    switch part {
                    case let .toolResult(result):
                        // Convert tool result to Anthropic format
                        let resultContent = AnthropicMessageEncoding.encodeToolResult(result.result)

                        // Tool results need to be sent as user messages with tool_result blocks
                        content.append(.toolResult(AnthropicContent.ToolResultContent(
                            toolUseId: result.toolCallId,
                            content: resultContent,
                            isError: result.isError ? true : nil,
                        )))
                    case let .text(text):
                        // Sometimes tool messages include text
                        if !text.isEmpty {
                            content.append(.text(AnthropicContent.TextContent(type: "text", text: text)))
                        }
                    default:
                        continue
                    }
                }

                // Tool results are sent as user messages in Anthropic's format
                if !content.isEmpty {
                    anthropicMessages.append(AnthropicMessage(role: "user", content: content))
                }
            }
        }

        if thinkingEnabled, !pendingThinkingBlocks.isEmpty {
            var content: [AnthropicContent] = []
            appendThinkingBlocks(pendingThinkingBlocks, to: &content)
            if !content.isEmpty {
                anthropicMessages.append(AnthropicMessage(role: "assistant", content: content))
            }
        }

        return (systemMessage, anthropicMessages)
    }
}

enum AnthropicMessageEncoding {
    static func encodeToolResult(_ value: AnyAgentToolValue) -> String {
        if let string = value.stringValue {
            return string
        }

        if let bool = value.boolValue {
            return bool ? "true" : "false"
        }

        if let int = value.intValue {
            return String(int)
        }

        if let double = value.doubleValue {
            return String(double)
        }

        if value.isNull {
            return "null"
        }

        if let jsonObject = try? value.toJSON(), JSONSerialization.isValidJSONObject(jsonObject) {
            if
                let data = try? JSONSerialization.data(
                    withJSONObject: jsonObject,
                    options: [.withoutEscapingSlashes, .sortedKeys],
                ),
                let string = String(data: data, encoding: .utf8)
            {
                return string
            }
        }

        return "Success"
    }
}
