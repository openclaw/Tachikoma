import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OpenAI-Compatible Helper

/// Shared helper for OpenAI-compatible APIs (OpenAI, Grok, etc.)
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
struct OpenAICompatibleHelper {
    static func generateText(
        request: ProviderRequest,
        modelId: String,
        baseURL: String,
        apiKey: String,
        providerName: String,
        path: String = "/chat/completions",
        queryItems: [URLQueryItem] = [],
        authHeaderName: String = "Authorization",
        authHeaderValuePrefix: String = "Bearer ",
        additionalHeaders: [String: String] = [:],
        session: URLSession = .shared,
    ) async throws
        -> ProviderResponse
    {
        let url = try self.buildURL(baseURL: baseURL, path: path, queryItems: queryItems)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        let headerValue = authHeaderValuePrefix.isEmpty ? apiKey : "\(authHeaderValuePrefix)\(apiKey)"
        urlRequest.setValue(headerValue, forHTTPHeaderField: authHeaderName)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add any additional headers (for specific providers)
        for (key, value) in additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Extract stop sequences from stop conditions
        let settings = Self.validatedSettings(
            request.settings,
            providerName: providerName,
            modelId: modelId,
            baseURL: baseURL,
        )
        let stopSequences = Self.extractStopSequences(from: settings.stopConditions)

        // Convert request to OpenAI-compatible format
        let messages = try self.convertMessages(
            request.messages,
            replayOpenRouterReasoningForModel: providerName == "OpenRouter" ? modelId : nil,
            replayOpenRouterReasoningForBaseURL: providerName == "OpenRouter" ? baseURL : nil,
            replayKimiReasoningForModel: providerName == "Kimi" ? modelId : nil,
            replayKimiReasoningForBaseURL: providerName == "Kimi" ? baseURL : nil,
        )
        let openAIRequest = try OpenAIChatRequest(
            model: modelId,
            messages: messages,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            tools: request.tools?.compactMap { try self.convertTool($0) },
            stream: false,
            stop: stopSequences.isEmpty ? nil : stopSequences,
            thinking: Self.kimiThinkingConfiguration(providerName: providerName, modelId: modelId, messages: messages),
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted // For debugging
        urlRequest.httpBody = try encoder.encode(openAIRequest)

        // Debug: Log the request JSON for verbose mode
        if
            ProcessInfo.processInfo.arguments.contains("--verbose") ||
            ProcessInfo.processInfo.arguments.contains("-v")
        {
            if let jsonString = String(data: urlRequest.httpBody ?? Data(), encoding: .utf8) {
                // Find and log just the tools section to avoid massive output
                if let toolsRange = jsonString.range(of: "\"tools\"") {
                    let startIndex = toolsRange.lowerBound
                    let endIndex = jsonString.index(
                        startIndex,
                        offsetBy: min(500, jsonString.distance(from: startIndex, to: jsonString.endIndex)),
                    )
                    let toolsSubstring = String(jsonString[startIndex..<endIndex])
                    print("DEBUG OpenAI Request Tools (first 500 chars): \(toolsSubstring)")
                }
            }
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"

            // Try to parse OpenAI error format
            if let errorData = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                throw TachikomaError.apiError("\(providerName) Error: \(errorData.error.message)")
            }

            throw TachikomaError.apiError("\(providerName) Error (HTTP \(httpResponse.statusCode)): \(errorText)")
        }

        let decoder = JSONDecoder()
        let openAIResponse = try decoder.decode(OpenAIChatResponse.self, from: data)

        guard let choice = openAIResponse.choices?.first else {
            throw TachikomaError.apiError("\(providerName) returned no choices")
        }

        let text = choice.message.content ?? ""
        let usage = openAIResponse.usage.map {
            Usage(inputTokens: $0.promptTokens ?? 0, outputTokens: $0.completionTokens ?? 0)
        }
        let reasoning = Self.reasoningBlocks(from: choice.message, providerName: providerName)

        let finishReason = Self.mapFinishReason(choice.finishReason)

        // Convert tool calls if present
        let toolCalls = choice.message.toolCalls?.compactMap { openAIToolCall -> AgentToolCall? in
            // Parse JSON string to dictionary and convert to AnyAgentToolValue format
            guard
                let data = openAIToolCall.function.arguments.data(using: String.Encoding.utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else
            {
                return nil
            }

            var arguments: [String: AnyAgentToolValue] = [:]
            for (key, value) in json {
                do {
                    arguments[key] = try AnyAgentToolValue.fromJSON(value)
                } catch {
                    // Log warning and skip arguments that can't be converted
                    print("[WARNING] Failed to convert tool argument '\(key)': \(error)")
                    continue
                }
            }

            return AgentToolCall(
                id: openAIToolCall.id,
                name: openAIToolCall.function.name,
                arguments: arguments,
            )
        }

        return ProviderResponse(
            text: text,
            usage: usage,
            finishReason: finishReason,
            toolCalls: toolCalls,
            reasoning: reasoning,
        )
    }

    static func streamText(
        request: ProviderRequest,
        modelId: String,
        baseURL: String,
        apiKey: String,
        providerName: String,
        path: String = "/chat/completions",
        queryItems: [URLQueryItem] = [],
        authHeaderName: String = "Authorization",
        authHeaderValuePrefix: String = "Bearer ",
        additionalHeaders: [String: String] = [:],
        session: URLSession = .shared,
    ) async throws
        -> AsyncThrowingStream<TextStreamDelta, Error>
    {
        let url = try self.buildURL(baseURL: baseURL, path: path, queryItems: queryItems)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        let headerValue = authHeaderValuePrefix.isEmpty ? apiKey : "\(authHeaderValuePrefix)\(apiKey)"
        urlRequest.setValue(headerValue, forHTTPHeaderField: authHeaderName)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add any additional headers (for specific providers)
        for (key, value) in additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Extract stop sequences from stop conditions
        guard !LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: modelId) else {
            throw TachikomaError.invalidConfiguration("\(modelId) does not support streaming")
        }
        let settings = Self.validatedSettings(
            request.settings,
            providerName: providerName,
            modelId: modelId,
            baseURL: baseURL,
        )
        let stopSequences = Self.extractStopSequences(from: settings.stopConditions)

        // Convert request to OpenAI-compatible format
        let messages = try self.convertMessages(
            request.messages,
            replayOpenRouterReasoningForModel: providerName == "OpenRouter" ? modelId : nil,
            replayOpenRouterReasoningForBaseURL: providerName == "OpenRouter" ? baseURL : nil,
            replayKimiReasoningForModel: providerName == "Kimi" ? modelId : nil,
            replayKimiReasoningForBaseURL: providerName == "Kimi" ? baseURL : nil,
        )
        let openAIRequest = try OpenAIChatRequest(
            model: modelId,
            messages: messages,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            tools: request.tools?.compactMap { try self.convertTool($0) },
            stream: true,
            stop: stopSequences.isEmpty ? nil : stopSequences,
            thinking: Self.kimiThinkingConfiguration(providerName: providerName, modelId: modelId, messages: messages),
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        urlRequest.httpBody = try encoder.encode(openAIRequest)

        // Debug logging for GPT-5 and other models
        if modelId.contains("gpt-5") || ProcessInfo.processInfo.environment["DEBUG_OPENAI"] != nil {
            print("🔵 DEBUG OpenAI Request to \(url.absoluteString):")
            print("   Model: \(modelId)")
            print("   Tools count: \(openAIRequest.tools?.count ?? 0)")
            if let toolNames = openAIRequest.tools?.map(\.function.name) {
                print("   Tool names: \(toolNames.joined(separator: ", "))")
            }
            if
                let jsonData = urlRequest.httpBody,
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                let preview = String(jsonString.prefix(2000))
                print("   Request JSON (first 2000 chars):\n\(preview)")
            }
        }

        // Create a copy to avoid capturing mutable reference
        let finalRequest = urlRequest

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    #if canImport(FoundationNetworking)
                    // Linux buffers the body; the async API still propagates cancellation.
                    let (data, response) = try await session.data(for: finalRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
                    }

                    guard httpResponse.statusCode == 200 else {
                        let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                        throw TachikomaError
                            .apiError("\(providerName) Error (HTTP \(httpResponse.statusCode)): \(errorText)")
                    }

                    // Process the entire response for Linux
                    let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
                    #else
                    // macOS/iOS: Use streaming API
                    let (bytes, response) = try await session.bytes(for: finalRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
                    }

                    guard httpResponse.statusCode == 200 else {
                        // Try to read error message from response
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 1000 {
                                break
                            }
                        }
                        let errorText = errorBody.isEmpty ? "Unknown error" : errorBody
                        throw TachikomaError
                            .apiError("\(providerName) Error (HTTP \(httpResponse.statusCode)): \(errorText)")
                    }
                    #endif

                    // Process the streaming response
                    var hasReceivedContent = false

                    #if canImport(FoundationNetworking)
                    // Linux: Process all lines at once
                    for line in lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            if jsonString.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                                // If we haven't received any content yet and see [DONE],
                                // yield an empty text delta to prevent hanging
                                if !hasReceivedContent {
                                    continuation.yield(TextStreamDelta.text(""))
                                }
                                continuation.yield(TextStreamDelta.done())
                                break
                            }

                            guard let data = jsonString.data(using: .utf8) else { continue }

                            do {
                                let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
                                if let choice = chunk.choices.first {
                                    // Debug logging for Grok models
                                    if
                                        modelId.contains("grok"),
                                        ProcessInfo.processInfo.environment["DEBUG_GROK"] != nil
                                    {
                                        print("🔵 DEBUG Grok chunk: \(jsonString)")
                                    }

                                    if let content = choice.delta.content, !content.isEmpty {
                                        continuation.yield(TextStreamDelta.text(content))
                                        hasReceivedContent = true
                                    }

                                    if
                                        providerName == "Kimi",
                                        let reasoning = choice.delta.reasoningContent,
                                        !reasoning.isEmpty
                                    {
                                        continuation.yield(TextStreamDelta.reasoning(
                                            reasoning,
                                            type: "kimi_reasoning_content",
                                        ))
                                        hasReceivedContent = true
                                    }

                                    // Handle tool calls - Grok sends them all at once
                                    if let toolCalls = choice.delta.toolCalls {
                                        for toolCall in toolCalls {
                                            // For Grok, function data comes directly in the toolCall
                                            if let function = toolCall.function {
                                                // Grok always provides name and arguments together
                                                if let name = function.name, let argumentsStr = function.arguments {
                                                    // Parse arguments JSON string into dictionary
                                                    let argumentsDict: [String: AnyAgentToolValue] = if
                                                        !argumentsStr.isEmpty,
                                                        let data = argumentsStr.data(using: .utf8),
                                                        let json = try? JSONSerialization
                                                            .jsonObject(with: data) as? [String: Any]
                                                    {
                                                        // Convert JSON to AnyAgentToolValue dictionary
                                                        json.compactMapValues { value in
                                                            if let stringValue = value as? String {
                                                                return AnyAgentToolValue(string: stringValue)
                                                            } else if let intValue = value as? Int {
                                                                return AnyAgentToolValue(int: intValue)
                                                            } else if let doubleValue = value as? Double {
                                                                return AnyAgentToolValue(double: doubleValue)
                                                            } else if let boolValue = value as? Bool {
                                                                return AnyAgentToolValue(bool: boolValue)
                                                            }
                                                            return nil
                                                        }
                                                    } else {
                                                        [:]
                                                    }

                                                    let agentToolCall = AgentToolCall(
                                                        id: toolCall.id ?? UUID().uuidString,
                                                        name: name,
                                                        arguments: argumentsDict,
                                                    )
                                                    continuation.yield(TextStreamDelta.tool(agentToolCall))
                                                    hasReceivedContent = true
                                                }
                                            }
                                        }
                                    }

                                    if let finishReason = choice.finishReason {
                                        continuation.yield(TextStreamDelta.done(
                                            finishReason: Self.mapFinishReason(finishReason),
                                        ))
                                        break
                                    }
                                }
                            } catch {
                                // Log decoding errors for debugging
                                if modelId.contains("grok") {
                                    print("⚠️ Grok streaming decode error: \(error)")
                                    print("   Raw JSON: \(jsonString)")
                                }
                                // Skip malformed chunks
                                continue
                            }
                        }
                    } // End of Linux for loop
                    #else
                    // macOS/iOS: Stream lines
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            if jsonString.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                                // If we haven't received any content yet and see [DONE],
                                // yield an empty text delta to prevent hanging
                                if !hasReceivedContent {
                                    continuation.yield(TextStreamDelta.text(""))
                                }
                                continuation.yield(TextStreamDelta.done())
                                break
                            }

                            guard let data = jsonString.data(using: .utf8) else { continue }

                            do {
                                let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
                                if let choice = chunk.choices.first {
                                    // Debug logging for Grok models
                                    if
                                        modelId.contains("grok"),
                                        ProcessInfo.processInfo.environment["DEBUG_GROK"] != nil
                                    {
                                        print("🔵 DEBUG Grok chunk: \(jsonString)")
                                    }

                                    if let content = choice.delta.content, !content.isEmpty {
                                        continuation.yield(TextStreamDelta.text(content))
                                        hasReceivedContent = true
                                    }

                                    if
                                        providerName == "Kimi",
                                        let reasoning = choice.delta.reasoningContent,
                                        !reasoning.isEmpty
                                    {
                                        continuation.yield(TextStreamDelta.reasoning(
                                            reasoning,
                                            type: "kimi_reasoning_content",
                                        ))
                                        hasReceivedContent = true
                                    }

                                    // Handle tool calls - Grok sends them all at once
                                    if let toolCalls = choice.delta.toolCalls {
                                        for toolCall in toolCalls {
                                            // For Grok, function data comes directly in the toolCall
                                            if let function = toolCall.function {
                                                // Grok always provides name and arguments together
                                                if let name = function.name, let argumentsStr = function.arguments {
                                                    // Parse arguments JSON string into dictionary
                                                    let argumentsDict: [String: AnyAgentToolValue] = if
                                                        let data = argumentsStr.data(using: .utf8),
                                                        let parsed = try? JSONSerialization
                                                            .jsonObject(with: data) as? [String: Any]
                                                    {
                                                        parsed.mapValues { AnyAgentToolValue.from($0) }
                                                    } else {
                                                        [:]
                                                    }

                                                    let call = AgentToolCall(
                                                        id: toolCall.id ?? UUID().uuidString,
                                                        name: name,
                                                        arguments: argumentsDict,
                                                    )
                                                    continuation.yield(TextStreamDelta.tool(call))
                                                    hasReceivedContent = true
                                                }
                                            }
                                        }
                                    }

                                    if let finishReason = choice.finishReason {
                                        continuation.yield(TextStreamDelta.done(
                                            finishReason: Self.mapFinishReason(finishReason),
                                        ))
                                        break
                                    }
                                }
                            } catch {
                                // Log error in verbose mode
                                let config = TachikomaConfiguration.current
                                if config.verbose || modelId.contains("grok") {
                                    print("[\(providerName)] Failed to parse chunk: \(error)")
                                    print("   Raw JSON: \(jsonString)")
                                }
                                // Skip malformed chunks
                                continue
                            }
                        }
                    } // End of macOS for loop
                    #endif

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        } // End of AsyncThrowingStream closure
    } // End of streamText function

    // MARK: - Helper Methods

    private static func mapFinishReason(_ reason: String?) -> FinishReason? {
        switch reason {
        case "stop": .stop
        case "length": .length
        case "tool_calls": .toolCalls
        case "content_filter": .contentFilter
        case nil: nil
        default: .other
        }
    }

    private static func validatedSettings(
        _ settings: GenerationSettings,
        providerName: String,
        modelId: String,
        baseURL: String,
    )
        -> GenerationSettings
    {
        settings.validated(for: self.languageModel(providerName: providerName, modelId: modelId, baseURL: baseURL))
    }

    private static func languageModel(providerName: String, modelId: String, baseURL: String) -> LanguageModel {
        switch providerName.lowercased() {
        case "kimi":
            .kimi(LanguageModel.Kimi(rawValue: modelId) ?? .k26)
        case "openrouter":
            .openRouter(modelId: modelId)
        case "together":
            .together(modelId: modelId)
        default:
            .openaiCompatible(modelId: modelId, baseURL: baseURL)
        }
    }

    /// Extract native stop sequences from stop conditions
    private static func extractStopSequences(from stopCondition: (any StopCondition)?) -> [String] {
        // Extract native stop sequences from stop conditions
        guard let stopCondition else { return [] }

        // Check if it's a string stop condition
        if let stringStop = stopCondition as? StringStopCondition {
            return [stringStop.stopString]
        }

        // Check if it's a composite condition
        if stopCondition is AnyStopCondition {
            // Extract stop strings from all conditions
            // Note: We'd need to expose the conditions array in AnyStopCondition
            // For now, we can't extract from composite conditions
            return []
        }

        // For other types of stop conditions, we can't extract native sequences
        return []
    }

    private static func convertToolResultToString(_ result: AnyAgentToolValue) -> String {
        if result.isNull {
            return "null"
        } else if let value = result.boolValue {
            return String(value)
        } else if let value = result.intValue {
            return String(value)
        } else if let value = result.doubleValue {
            return String(value)
        } else if let value = result.stringValue {
            return value
        } else if let array = result.arrayValue {
            // Convert array to JSON string for complex results
            if
                let data = try? JSONEncoder().encode(array),
                let jsonString = String(data: data, encoding: .utf8)
            {
                return jsonString
            }
            return "[]"
        } else if let dict = result.objectValue {
            // Convert object to JSON string for complex results
            if
                let data = try? JSONEncoder().encode(dict),
                let jsonString = String(data: data, encoding: .utf8)
            {
                return jsonString
            }
            return "{}"
        } else {
            return "unknown"
        }
    }

    private static func kimiThinkingConfiguration(
        providerName: String,
        modelId: String,
        messages: [OpenAIChatMessage],
    )
        -> OpenAIThinkingConfiguration?
    {
        guard
            providerName == "Kimi",
            modelId == LanguageModel.Kimi.k26.modelId,
            messages.contains(where: { $0.reasoningContent?.isEmpty == false }) else
        {
            return nil
        }

        return OpenAIThinkingConfiguration(type: "enabled", keep: "all")
    }

    static func convertMessages(
        _ messages: [ModelMessage],
        replayOpenRouterReasoningForModel modelId: String? = nil,
        replayOpenRouterReasoningForBaseURL baseURL: String? = nil,
        replayKimiReasoningForModel kimiModelId: String? = nil,
        replayKimiReasoningForBaseURL kimiBaseURL: String? = nil,
    ) throws
        -> [OpenAIChatMessage]
    {
        var converted: [OpenAIChatMessage] = []
        var pendingReasoningDetails: [JSONValue] = []
        var pendingReasoningText: [String] = []
        let endpointIdentity = ReasoningEndpointIdentity.canonical(baseURL)
        var pendingKimiReasoningContent: [String] = []
        let kimiEndpointIdentity = ReasoningEndpointIdentity.canonical(kimiBaseURL)

        for message in messages {
            if
                message.channel == .thinking,
                let endpointIdentity,
                let customData = message.metadata?.customData,
                customData["tachikoma.reasoning.provider"] == "openrouter",
                customData["tachikoma.reasoning.model"] == modelId,
                customData["tachikoma.reasoning.base_url"] == endpointIdentity,
                let rawReasoningDetails = customData["openrouter.reasoning_details"]
            {
                pendingReasoningDetails.append(contentsOf: Self.decodeReasoningDetails(rawReasoningDetails))
                continue
            }
            if
                message.channel == .thinking,
                let kimiEndpointIdentity,
                let customData = message.metadata?.customData,
                customData["tachikoma.reasoning.provider"] == "kimi",
                customData["tachikoma.reasoning.model"] == kimiModelId,
                customData["tachikoma.reasoning.base_url"] == kimiEndpointIdentity,
                let reasoning = customData["kimi.reasoning_content"]
            {
                pendingKimiReasoningContent.append(reasoning)
                continue
            }
            if
                message.channel == .thinking,
                let endpointIdentity,
                let customData = message.metadata?.customData,
                customData["tachikoma.reasoning.provider"] == "openrouter",
                customData["tachikoma.reasoning.model"] == modelId,
                customData["tachikoma.reasoning.base_url"] == endpointIdentity,
                let reasoning = customData["openrouter.reasoning"]
            {
                pendingReasoningText.append(reasoning)
                continue
            }
            if message.channel == .thinking {
                continue
            }

            switch message.role {
            case .system:
                converted.append(OpenAIChatMessage(role: "system", content: message.content.compactMap { part in
                    if case let .text(text) = part {
                        return text
                    }
                    return nil
                }.joined()))
            case .user:
                if message.content.count == 1, case let .text(text) = message.content.first! {
                    // Simple text message
                    converted.append(OpenAIChatMessage(role: "user", content: text))
                } else {
                    // Multi-modal message
                    let content = message.content.compactMap { contentPart -> OpenAIChatMessageContent? in
                        switch contentPart {
                        case let .text(text):
                            return .text(OpenAIChatMessageContent.TextContent(type: "text", text: text))
                        case let .image(imageContent):
                            let base64URL = "data:\(imageContent.mimeType);base64,\(imageContent.data)"
                            return .imageUrl(OpenAIChatMessageContent.ImageUrlContent(
                                type: "image_url",
                                imageUrl: OpenAIChatMessageContent.ImageUrl(url: base64URL),
                            ))
                        case .reasoning, .toolCall, .toolResult:
                            return nil // Skip tool calls and results in user messages
                        }
                    }
                    converted.append(OpenAIChatMessage(role: "user", content: content))
                }
            case .assistant:
                // Check if this assistant message contains tool calls
                let toolCalls = message.content.compactMap { part -> OpenAIChatMessage.AgentToolCall? in
                    if case let .toolCall(toolCall) = part {
                        // Convert AgentToolCall to OpenAI format
                        // Convert arguments dictionary to JSON string
                        let jsonData = try? JSONEncoder().encode(toolCall.arguments)
                        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                        return OpenAIChatMessage.AgentToolCall(
                            id: toolCall.id,
                            type: "function",
                            function: OpenAIChatMessage.AgentToolCall.Function(
                                name: toolCall.name,
                                arguments: jsonString,
                            ),
                        )
                    }
                    return nil
                }

                // Extract text content
                let textContent = message.content.compactMap { part in
                    if case let .text(text) = part {
                        return text
                    }
                    return nil
                }.joined()

                // If we have tool calls, create a message with tool calls
                if !toolCalls.isEmpty {
                    converted.append(OpenAIChatMessage(
                        role: "assistant",
                        content: textContent.isEmpty ? nil : textContent,
                        toolCalls: toolCalls,
                        reasoning: pendingReasoningText.isEmpty ? nil : pendingReasoningText.joined(separator: "\n"),
                        reasoningDetails: pendingReasoningDetails.isEmpty ? nil : pendingReasoningDetails,
                        reasoningContent: pendingKimiReasoningContent.isEmpty
                            ? nil
                            : pendingKimiReasoningContent.joined(separator: "\n"),
                    ))
                } else {
                    // Regular text message
                    converted.append(OpenAIChatMessage(
                        role: "assistant",
                        content: textContent,
                        toolCalls: nil,
                        reasoning: pendingReasoningText.isEmpty ? nil : pendingReasoningText.joined(separator: "\n"),
                        reasoningDetails: pendingReasoningDetails.isEmpty ? nil : pendingReasoningDetails,
                        reasoningContent: pendingKimiReasoningContent.isEmpty
                            ? nil
                            : pendingKimiReasoningContent.joined(separator: "\n"),
                    ))
                }
                pendingReasoningText.removeAll()
                pendingReasoningDetails.removeAll()
                pendingKimiReasoningContent.removeAll()
            case .tool:
                // Extract tool call ID and result content from tool result
                var toolCallId: String?
                var resultContent = ""

                for part in message.content {
                    switch part {
                    case let .toolResult(result):
                        toolCallId = result.toolCallId
                        // Convert the result to a string representation
                        resultContent = self.convertToolResultToString(result.result)
                    case let .text(text):
                        resultContent = text
                    default:
                        break
                    }
                }

                converted.append(OpenAIChatMessage(role: "tool", content: resultContent, toolCallId: toolCallId))
            }
        }

        return converted
    }

    private static func reasoningBlocks(
        from message: OpenAIChatResponse.Message,
        providerName: String,
    )
        -> [ProviderReasoningBlock]
    {
        var blocks: [ProviderReasoningBlock] = []
        if
            providerName == "Kimi",
            let reasoningContent = message.reasoningContent,
            !reasoningContent.isEmpty
        {
            blocks.append(ProviderReasoningBlock(
                text: reasoningContent,
                type: "kimi_reasoning_content",
            ))
        }
        if let details = message.reasoningDetails, !details.isEmpty {
            blocks.append(ProviderReasoningBlock(
                text: message.reasoning ?? "",
                type: "openrouter_reasoning_details",
                rawJSON: Self.encodeReasoningDetails(details),
            ))
        } else if let reasoning = message.reasoning, !reasoning.isEmpty {
            blocks.append(ProviderReasoningBlock(
                text: reasoning,
                type: "openrouter_reasoning",
                rawJSON: nil,
            ))
        }
        return blocks
    }

    private static func encodeReasoningDetails(_ details: [JSONValue]) -> String? {
        guard let data = try? JSONEncoder().encode(details) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeReasoningDetails(_ rawJSON: String) -> [JSONValue] {
        guard
            let data = rawJSON.data(using: .utf8),
            let details = try? JSONDecoder().decode([JSONValue].self, from: data) else
        {
            return []
        }
        return details
    }

    private static func convertTool(_ tool: AgentTool) throws -> OpenAITool {
        let parameters = try tool.parameters.jsonSchema(options: [
            .defaultStringArrayItems,
            .omitEmptyRequired,
        ])

        // Debug logging
        if
            ProcessInfo.processInfo.arguments.contains("--verbose") ||
            ProcessInfo.processInfo.arguments.contains("-v")
        {
            let propertiesCount = tool.parameters.properties.count
            let requiredCount = tool.parameters.required.count
            print(
                "DEBUG: Converting tool '\(tool.name)' with \(propertiesCount) properties, " +
                    "\(requiredCount) required",
            )
            if tool.parameters.required.isEmpty {
                print("DEBUG: Omitting required field for '\(tool.name)' as it's empty")
            }
        }

        return OpenAITool(
            type: "function",
            function: OpenAITool.Function(
                name: tool.name,
                description: tool.description,
                parameters: parameters,
            ),
        )
    }

    // MARK: - URL Construction

    /// Build an endpoint URL from a configurable provider base URL.
    /// Empty and malformed values throw instead of crashing on `URL(string:)!`.
    static func endpointURL(baseURL: String?, path: String) throws -> URL {
        let trimmed = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TachikomaError.invalidConfiguration("Invalid base URL: <empty>")
        }
        return try self.buildURL(baseURL: trimmed, path: path, queryItems: [])
    }

    static func buildURL(baseURL: String, path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: baseURL) else {
            throw TachikomaError.invalidConfiguration("Invalid base URL: \(baseURL)")
        }

        let basePath = components.percentEncodedPath
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        var suffix = URLComponents()
        suffix.path = normalizedPath
        // Decoding the base path would turn an encoded slash into a route separator.
        components.percentEncodedPath = trimmedBase + suffix.percentEncodedPath

        var mergedQueryItems = components.queryItems ?? []
        mergedQueryItems.append(contentsOf: queryItems)
        components.queryItems = mergedQueryItems.isEmpty ? nil : mergedQueryItems

        guard let finalURL = components.url else {
            throw TachikomaError.invalidConfiguration("Failed to build URL from \(baseURL) and path \(path)")
        }
        return finalURL
    }
}
