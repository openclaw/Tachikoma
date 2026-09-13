import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider for OpenAI Responses API (GPT-5)
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class OpenAIResponsesProvider: ModelProvider, ResponseCacheSafetyProviding {
    public let modelId: String
    public let baseURL: String?
    public let apiKey: String?
    public let capabilities: ModelCapabilities

    private let model: LanguageModel.OpenAI
    private let configuration: TachikomaConfiguration
    private let session: URLSession
    private let transport: Transport

    private enum Transport {
        case platform(TKAuthValue)
        case codexOAuth
    }

    private struct RequestAuthentication {
        let baseURL: String
        let accessToken: String
        let accountID: String?
        let isCodex: Bool
    }

    private static let platformBaseURL = "https://api.openai.com/v1"
    private static let codexBaseURL = "https://chatgpt.com/backend-api/codex"

    private static let debugLogURL = URL(fileURLWithPath: "/tmp/tachikoma-gpt5.log")

    var isResponseCacheSafe: Bool {
        false
    }

    // Provider options (immutable for Sendable conformance)
    private let reasoningEffort: ReasoningEffort = .medium
    private let verbosity: TextVerbosity = .high // Set to high for preambles
    private let previousResponseId: String? = nil // For conversation persistence

    public init(
        model: LanguageModel.OpenAI,
        configuration: TachikomaConfiguration,
        session: URLSession = .shared,
    ) throws {
        guard !model.isUnsupportedLegacyFamily else {
            throw TachikomaError.unsupportedOperation("OpenAI model '\(model.modelId)' is no longer supported")
        }

        self.model = model
        self.modelId = model.modelId
        self.configuration = configuration
        self.session = session

        // Prefer API keys when explicitly configured. ChatGPT OAuth uses the Codex backend,
        // which is a different transport from the public OpenAI API.
        if let key = configuration.getAPIKey(for: .openai) {
            self.transport = .platform(.bearer(key, betaHeader: nil))
            self.apiKey = key
            self.baseURL = configuration.getBaseURL(for: .openai) ?? Self.platformBaseURL
        } else if let auth = TKAuthManager.shared.resolveAuth(for: .openai) {
            self.transport = .platform(auth)
            switch auth {
            case let .apiKey(key):
                self.apiKey = key
            case let .bearer(token, _):
                self.apiKey = token
            }
            self.baseURL = configuration.getBaseURL(for: .openai) ?? Self.platformBaseURL
        } else if TKAuthManager.shared.hasOpenAICodexCredentials() {
            self.transport = .codexOAuth
            self.apiKey = nil
            self.baseURL = Self.codexBaseURL
        } else {
            throw TachikomaError.authenticationFailed("OPENAI_API_KEY or OpenAI OAuth login not found")
        }

        // Set capabilities based on model
        let isReasoningModel = Self.isReasoningModel(model)
        let isGPT5 = Self.isGPT5Model(model)
        let hasLargeOutputWindow = isReasoningModel || isGPT5 || model == .chatLatest
        let maxOutputTokens = model == .gpt5ChatLatest ? 16384 : (hasLargeOutputWindow ? 128_000 : 4096)

        self.capabilities = ModelCapabilities(
            supportsVision: model.supportsVision,
            supportsTools: model.supportsTools,
            supportsStreaming: true,
            contextLength: model.contextLength,
            maxOutputTokens: maxOutputTokens,
        )
    }

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        if case .codexOAuth = self.transport {
            return try await self.generateCodexText(request: request)
        }

        // Build Responses API request
        let responsesRequest = try self.buildResponsesRequest(request: request)

        // Create URL for Responses API endpoint
        let url = try OpenAICompatibleHelper.endpointURL(baseURL: self.baseURL, path: "/responses")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        guard case let .platform(auth) = self.transport else {
            throw TachikomaError.authenticationFailed("Invalid OpenAI authentication transport")
        }
        let (authHeaderName, prefix, secret) = Self.authHeader(for: auth)
        urlRequest.setValue("\(prefix)\(secret)", forHTTPHeaderField: authHeaderName)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add OpenAI-specific headers
        if let orgId = ProcessInfo.processInfo.environment["OPENAI_ORG_ID"] {
            urlRequest.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
        }

        // Encode request
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(responsesRequest)

        // Log request in verbose mode (silent by default)

        let (data, response) = try await self.session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TachikomaError.apiError("OpenAI Responses API Error (HTTP \(httpResponse.statusCode)): \(errorText)")
        }

        // Decode response
        let decoder = JSONDecoder()
        let responsesResponse = try decoder.decode(OpenAIResponsesResponse.self, from: data)

        // TODO: Store response metadata for conversation persistence
        // Cannot mutate properties due to Sendable conformance
        // Need to implement a different approach for maintaining conversation state

        // Convert to ProviderResponse
        return try Self.convertToProviderResponse(responsesResponse)
    }

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        let requestAuthentication = try await self.resolveRequestAuthentication()

        // Build Responses API request with streaming enabled
        let responsesRequest = try self.buildResponsesRequest(
            request: request,
            streaming: true,
            codex: requestAuthentication.isCodex,
        )

        let url = try OpenAICompatibleHelper.endpointURL(
            baseURL: requestAuthentication.baseURL,
            path: "/responses",
        )
        let finalURLRequest: URLRequest = {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(
                "Bearer \(requestAuthentication.accessToken)",
                forHTTPHeaderField: "Authorization",
            )
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

            if requestAuthentication.isCodex {
                req.setValue(requestAuthentication.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
                req.setValue("peekaboo", forHTTPHeaderField: "originator")
                req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
                req.setValue("peekaboo", forHTTPHeaderField: "User-Agent")
            } else if let orgId = ProcessInfo.processInfo.environment["OPENAI_ORG_ID"] {
                req.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
            }

            // Encode request
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            req.httpBody = try? encoder.encode(responsesRequest)

            // Debug logging only when explicitly enabled
            if ProcessInfo.processInfo.environment["DEBUG_OPENAI"] != nil {
                print("🟢 DEBUG OpenAI Responses API Request to \(url.absoluteString):")
                print("   Model: \(responsesRequest.model)")
                print("   Tools count: \(responsesRequest.tools?.count ?? 0)")
                if let toolNames = responsesRequest.tools?.compactMap({ $0.function?.name }) {
                    print("   Tool names: \(toolNames.joined(separator: ", "))")
                }
            }

            return req
        }()

        // Create streaming response
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    #if canImport(FoundationNetworking)
                    // Linux buffers the body; the async API still propagates cancellation.
                    let (data, response) = try await self.session.data(for: finalURLRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw TachikomaError.apiError("Invalid response type")
                    }

                    if httpResponse.statusCode != 200 {
                        let errorBody = String(data: data, encoding: .utf8) ?? ""
                        let errorMessage = "HTTP \(httpResponse.statusCode): \(errorBody.prefix(1000))"
                        throw TachikomaError.apiError("OpenAI Responses API Error: \(errorMessage)")
                    }

                    // Parse the entire response for Linux
                    let responseText = String(data: data, encoding: .utf8) ?? ""
                    let lines = responseText.components(separatedBy: "\n")
                    var streamState = ResponsesStreamState()
                    for line in lines {
                        if
                            try Self.processResponsesStreamLine(
                                line,
                                model: self.model,
                                state: &streamState,
                                continuation: continuation,
                            )
                        {
                            return
                        }
                    }
                    continuation.finish()
                    return
                    #else
                    // macOS/iOS: Use streaming API
                    let (bytes, response) = try await self.session.bytes(for: finalURLRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw TachikomaError.apiError("Invalid response type")
                    }

                    if httpResponse.statusCode != 200 {
                        // Try to read error message from response
                        var errorMessage = "HTTP \(httpResponse.statusCode)"
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 1000 {
                                break
                            } // Limit error message size
                        }
                        if
                            let data = errorBody.data(using: .utf8),
                            let errorResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                            let error = errorResponse["error"] as? [String: Any],
                            let message = error["message"] as? String
                        {
                            errorMessage = "\(httpResponse.statusCode): \(message)"
                        } else if !errorBody.isEmpty {
                            errorMessage = "\(httpResponse.statusCode): \(errorBody.prefix(500))"
                        }
                        throw TachikomaError.apiError("Failed to start streaming: \(errorMessage)")
                    }

                    var streamState = ResponsesStreamState()

                    for try await line in bytes.lines {
                        if
                            try Self.processResponsesStreamLine(
                                line,
                                model: self.model,
                                state: &streamState,
                                continuation: continuation,
                            )
                        {
                            return
                        }
                    }

                    continuation.finish()
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func generateCodexText(request: ProviderRequest) async throws -> ProviderResponse {
        let stream = try await self.streamText(request: request)
        var text = ""
        var usage: Usage?
        var finishReason: FinishReason?
        var toolCalls: [AgentToolCall] = []
        var assistantContent: [ModelMessage.ContentPart] = []

        for try await delta in stream {
            switch delta.type {
            case .textDelta:
                let deltaText = delta.content ?? ""
                text.append(deltaText)
                if case let .text(existing)? = assistantContent.last {
                    assistantContent[assistantContent.count - 1] = .text(existing + deltaText)
                } else if !deltaText.isEmpty {
                    assistantContent.append(.text(deltaText))
                }
            case .toolCall:
                if let toolCall = delta.toolCall {
                    toolCalls.append(toolCall)
                    assistantContent.append(.toolCall(toolCall))
                }
            case .done:
                usage = delta.usage ?? usage
                finishReason = delta.finishReason ?? finishReason
            case .reasoning:
                if let reasoning = delta.reasoningContent {
                    assistantContent.append(.reasoning(reasoning))
                }
            case .toolResult:
                break
            }
        }

        return ProviderResponse(
            text: text,
            usage: usage,
            finishReason: finishReason,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            assistantMessages: assistantContent.isEmpty
                ? []
                : [ModelMessage(role: .assistant, content: assistantContent)],
        )
    }

    private func resolveRequestAuthentication() async throws -> RequestAuthentication {
        switch self.transport {
        case let .platform(auth):
            let (_, _, accessToken) = Self.authHeader(for: auth)
            return RequestAuthentication(
                baseURL: self.baseURL ?? Self.platformBaseURL,
                accessToken: accessToken,
                accountID: nil,
                isCodex: false,
            )
        case .codexOAuth:
            let auth = try await TKAuthManager.shared.resolveOpenAICodexAuth(session: self.session)
            return RequestAuthentication(
                baseURL: self.baseURL ?? Self.codexBaseURL,
                accessToken: auth.accessToken,
                accountID: auth.accountID,
                isCodex: true,
            )
        }
    }

    private struct ResponsesStreamState {
        struct PartialToolCall {
            var callId: String
            var name: String?
            var arguments: String
        }

        var previousContent = ""
        var pendingToolCalls: [String: PartialToolCall] = [:]
        var didYieldToolCall = false
        var didReceiveRefusal = false
        var yieldedReasoningItemIDs: Set<String> = []
    }

    private static func processResponsesStreamLine(
        _ line: String,
        model: LanguageModel.OpenAI,
        state: inout ResponsesStreamState,
        continuation: AsyncThrowingStream<TextStreamDelta, Error>.Continuation,
    ) throws
        -> Bool
    {
        guard line.hasPrefix("data: ") else {
            return false
        }

        let jsonString = String(line.dropFirst(6))
        if ProcessInfo.processInfo.environment["DEBUG_TACHIKOMA_STREAM"] != nil {
            Self.debugLog("raw stream: \(jsonString)")
        }

        if jsonString == "[DONE]" {
            continuation.finish()
            return true
        }

        guard let data = jsonString.data(using: .utf8) else {
            return false
        }

        if Self.usesResponsesEventStream(model) {
            guard
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let eventType = event["type"] as? String else
            {
                return false
            }

            if ProcessInfo.processInfo.environment["DEBUG_TACHIKOMA"] != nil {
                Self.debugLog("event: \(eventType) payload: \(event)")
            }

            switch eventType {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    continuation.yield(TextStreamDelta.text(delta))
                }

            case "response.output_item.added":
                if
                    let item = event["item"] as? [String: Any],
                    let itemType = item["type"] as? String
                {
                    if itemType == "reasoning", let reasoning = Self.reasoningContent(from: item) {
                        continuation.yield(.reasoning(reasoning))
                        state.yieldedReasoningItemIDs.insert(reasoning.id)
                    } else if itemType == "function_call" {
                        let itemID = (item["id"] as? String) ?? UUID().uuidString
                        var partial = state.pendingToolCalls[itemID] ?? ResponsesStreamState.PartialToolCall(
                            callId: (item["call_id"] as? String) ?? itemID,
                            name: nil,
                            arguments: "",
                        )
                        if let name = item["name"] as? String {
                            partial.name = name
                        }
                        state.pendingToolCalls[itemID] = partial
                    }
                }

            case "response.output_item.done":
                if
                    let item = event["item"] as? [String: Any],
                    item["type"] as? String == "reasoning",
                    let reasoning = Self.reasoningContent(from: item),
                    !state.yieldedReasoningItemIDs.contains(reasoning.id)
                {
                    continuation.yield(.reasoning(reasoning))
                    state.yieldedReasoningItemIDs.insert(reasoning.id)
                }

            case "response.function_call_arguments.delta":
                if
                    let itemId = event["item_id"] as? String,
                    let delta = event["delta"] as? String
                {
                    var partial = state.pendingToolCalls[itemId] ?? ResponsesStreamState.PartialToolCall(
                        callId: itemId,
                        name: nil,
                        arguments: "",
                    )
                    partial.arguments.append(delta)
                    state.pendingToolCalls[itemId] = partial
                }

            case "response.function_call_arguments.done":
                if
                    let itemId = event["item_id"] as? String,
                    let arguments = event["arguments"] as? String
                {
                    var partial = state.pendingToolCalls[itemId] ?? ResponsesStreamState.PartialToolCall(
                        callId: itemId,
                        name: nil,
                        arguments: "",
                    )
                    partial.arguments = arguments
                    state.pendingToolCalls[itemId] = partial

                    if
                        let name = partial.name,
                        let toolCall = Self.makeToolCall(
                            id: partial.callId,
                            name: name,
                            argumentsJSON: arguments,
                        )
                    {
                        continuation.yield(.tool(toolCall))
                        state.didYieldToolCall = true
                        state.pendingToolCalls.removeValue(forKey: itemId)
                    }
                }

            case "response.refusal.delta",
                 "response.refusal.done":
                state.didReceiveRefusal = true

            case "response.completed":
                let finishReason: FinishReason = state.didReceiveRefusal
                    ? .contentFilter
                    : (state.didYieldToolCall ? .toolCalls : .stop)
                continuation.yield(.done(
                    usage: Self.usageForResponseStreamEvent(event),
                    finishReason: finishReason,
                ))
                continuation.finish()
                return true

            case "response.incomplete":
                let finishReason = Self.finishReasonForIncompleteResponseEvent(event)
                continuation.yield(.done(
                    usage: Self.usageForResponseStreamEvent(event),
                    finishReason: finishReason,
                ))
                continuation.finish()
                return true

            case "response.failed",
                 "error":
                throw TachikomaError.apiError(Self.errorMessageForResponseStreamEvent(event))

            default:
                break
            }
            return false
        }

        do {
            let chunk = try JSONDecoder().decode(OpenAIResponsesStreamChunk.self, from: data)
            if
                let choice = chunk.choices.first,
                let content = choice.delta.content,
                !content.isEmpty
            {
                if content.hasPrefix(state.previousContent), !state.previousContent.isEmpty {
                    let delta = String(content.dropFirst(state.previousContent.count))
                    if !delta.isEmpty {
                        continuation.yield(TextStreamDelta.text(delta))
                        state.previousContent = content
                    }
                } else {
                    continuation.yield(TextStreamDelta.text(content))
                    state.previousContent += content
                }
            }

            if let choice = chunk.choices.first, let finishReason = choice.finishReason {
                continuation.yield(.done(finishReason: Self.finishReasonForChatStream(finishReason)))
                continuation.finish()
                return true
            }
        } catch {
            // Ignore parsing errors for incomplete chunks.
        }

        return false
    }

    private static func finishReasonForChatStream(_ reason: String) -> FinishReason {
        switch reason {
        case "stop": .stop
        case "length": .length
        case "tool_calls": .toolCalls
        case "content_filter": .contentFilter
        default: .other
        }
    }

    private static func usageForResponseStreamEvent(_ event: [String: Any]) -> Usage? {
        guard
            let response = event["response"] as? [String: Any],
            let usage = response["usage"] as? [String: Any],
            let inputTokens = (usage["input_tokens"] as? NSNumber)?.intValue,
            let outputTokens = (usage["output_tokens"] as? NSNumber)?.intValue else
        {
            return nil
        }
        return Usage(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    private static func errorMessageForResponseStreamEvent(_ event: [String: Any]) -> String {
        let eventType = event["type"] as? String ?? "error"
        let errorPayload = (event["error"] as? [String: Any]) ??
            (event["response"] as? [String: Any]).flatMap { $0["error"] as? [String: Any] }
        if let message = errorPayload?["message"] as? String, !message.isEmpty {
            return "OpenAI Responses API stream \(eventType): \(message)"
        }
        if let message = event["message"] as? String, !message.isEmpty {
            return "OpenAI Responses API stream \(eventType): \(message)"
        }
        return "OpenAI Responses API stream \(eventType)"
    }

    private static func reasoningContent(from item: [String: Any]) -> ModelMessage.ContentPart.ReasoningContent? {
        guard
            let id = item["id"] as? String,
            let encryptedContent = item["encrypted_content"] as? String else
        {
            return nil
        }
        let summary: [ModelMessage.ContentPart.ReasoningContent.Summary]? =
            (item["summary"] as? [[String: Any]])?.compactMap { entry in
                guard
                    let type = entry["type"] as? String,
                    let text = entry["text"] as? String else
                {
                    return nil
                }
                return ModelMessage.ContentPart.ReasoningContent.Summary(type: type, text: text)
            }
        return ModelMessage.ContentPart.ReasoningContent(
            id: id,
            encryptedContent: encryptedContent,
            summary: summary,
        )
    }

    private static func authHeader(for auth: TKAuthValue) -> (String, String, String) {
        switch auth {
        case let .apiKey(key):
            ("Authorization", "Bearer ", key)
        case let .bearer(token, _):
            ("Authorization", "Bearer ", token)
        }
    }

    // MARK: - Private Helpers

    private func buildResponsesRequest(
        request: ProviderRequest,
        streaming: Bool = false,
        codex: Bool = false,
    ) throws
        -> OpenAIResponsesRequest
    {
        // Convert messages to Responses API format
        let inputMessages = codex ? request.messages.filter { $0.role != .system } : request.messages
        let messages = try self.sanitizeInputs(self.convertMessages(inputMessages, codex: codex))

        // Convert tools if present
        let tools = try request.tools?.compactMap { tool in
            try self.convertTool(tool)
        }

        // Get validated settings and provider options
        let validatedSettings = request.settings.validated(for: .openai(self.model))
        let openaiOptions = validatedSettings.providerOptions.openai

        // Determine reasoning configuration
        let reasoning: ReasoningConfig?
        if Self.isReasoningModel(self.model) || Self.isGPT5Model(self.model) {
            if codex, openaiOptions?.reasoningEffort == nil {
                reasoning = nil
            } else {
                let effort: OpenAIReasoningEffort
                if let optionEffort = openaiOptions?.reasoningEffort {
                    if Self.isGPT56Model(self.model), optionEffort == .minimal {
                        throw TachikomaError.invalidConfiguration(
                            "GPT-5.6 does not support 'minimal' reasoning effort; use 'low' or higher",
                        )
                    }
                    // Convert from public API to internal type
                    effort = OpenAIReasoningEffort(rawValue: optionEffort.rawValue) ?? .medium
                } else {
                    effort = .medium // Public API default
                }
                reasoning = ReasoningConfig(
                    effort: effort,
                    summary: .auto,
                )
            }
        } else {
            reasoning = nil
        }

        // Determine text configuration for GPT-5 (enables preamble messages)
        let textConfig: TextConfig?
        if Self.isGPT5Model(self.model) {
            let verbosity: TextVerbosity = if let optionVerbosity = openaiOptions?.verbosity {
                // Convert from public API to internal type
                TextVerbosity(rawValue: optionVerbosity.rawValue) ?? .high
            } else {
                codex ? .low : .high
            }
            textConfig = TextConfig(verbosity: verbosity)
        } else {
            textConfig = nil
        }

        let hasTools = tools?.isEmpty == false
        let responsesRequest = OpenAIResponsesRequest(
            model: self.modelId,
            input: messages,
            temperature: validatedSettings.temperature,
            topP: validatedSettings.topP,
            maxOutputTokens: codex ? nil : validatedSettings.maxTokens,
            text: textConfig,
            tools: tools,
            toolChoice: codex && hasTools ? "auto" : nil,
            metadata: nil,
            parallelToolCalls: codex && !hasTools ? nil : (openaiOptions?.parallelToolCalls ?? true),
            previousResponseId: openaiOptions?.previousResponseId ?? self.previousResponseId,
            store: false,
            user: nil,
            instructions: codex ? self.codexInstructions(from: request.messages) : nil,
            serviceTier: nil,
            include: codex ? ["reasoning.encrypted_content"] : nil,
            reasoning: reasoning,
            truncation: !codex && Self.isReasoningModel(self.model) ? "auto" : nil,
            stream: streaming || codex,
        )

        if
            ProcessInfo.processInfo.environment["DEBUG_TACHIKOMA_STREAM"] != nil,
            let data = try? JSONEncoder().encode(responsesRequest),
            let jsonString = String(data: data, encoding: .utf8)
        {
            Self.debugLog("request payload: \(jsonString)")
        }

        return responsesRequest
    }

    private func codexInstructions(from messages: [ModelMessage]) -> String {
        let instructions = messages
            .filter { $0.role == .system }
            .flatMap(\.content)
            .compactMap { part -> String? in
                guard case let .text(text) = part, !text.isEmpty else { return nil }
                return text
            }
            .joined(separator: "\n\n")
        return instructions.isEmpty ? "You are a helpful assistant." : instructions
    }

    private func convertMessages(_ messages: [ModelMessage], codex: Bool) throws -> [ResponsesInputItem] {
        var inputs: [ResponsesInputItem] = []

        for message in messages {
            switch message.role {
            case .system, .user:
                if let entry = makeMessageEntry(role: message.role.rawValue, message: message) {
                    inputs.append(.message(entry))
                }
            case .assistant:
                if codex {
                    var bufferedContent: [ModelMessage.ContentPart] = []
                    for part in message.content {
                        switch part {
                        case let .reasoning(reasoning):
                            if let entry = makeMessageEntry(role: message.role.rawValue, content: bufferedContent) {
                                inputs.append(.message(entry))
                            }
                            bufferedContent.removeAll(keepingCapacity: true)
                            inputs.append(.reasoning(.init(
                                id: reasoning.id,
                                encryptedContent: reasoning.encryptedContent,
                                summary: reasoning.summary,
                            )))
                        case let .toolCall(call):
                            if let entry = makeMessageEntry(role: message.role.rawValue, content: bufferedContent) {
                                inputs.append(.message(entry))
                            }
                            bufferedContent.removeAll(keepingCapacity: true)
                            if let functionCall = makeFunctionCall(call) {
                                inputs.append(.functionCall(functionCall))
                            }
                        default:
                            bufferedContent.append(part)
                        }
                    }
                    if let entry = makeMessageEntry(role: message.role.rawValue, content: bufferedContent) {
                        inputs.append(.message(entry))
                    }
                } else {
                    if let entry = makeMessageEntry(role: message.role.rawValue, message: message) {
                        inputs.append(.message(entry))
                    }
                    for part in message.content {
                        guard case let .toolCall(call) = part else { continue }
                        if let functionCall = makeFunctionCall(call) {
                            inputs.append(.functionCall(functionCall))
                        }
                    }
                }
            case .tool:
                for part in message.content {
                    switch part {
                    case let .toolResult(result):
                        if let output = makeFunctionCallOutput(result) {
                            inputs.append(.functionCallOutput(output))
                        }
                    case let .text(text):
                        guard !text.isEmpty else { continue }
                        let entry = ResponsesMessage(
                            role: normalizedRole("user"),
                            content: .parts([ResponsesContentPart(type: "input_text", text: text, imageUrl: nil)]),
                        )
                        inputs.append(.message(entry))
                    default:
                        continue
                    }
                }
            }
        }

        return inputs
    }

    private func sanitizeInputs(_ inputs: [ResponsesInputItem]) -> [ResponsesInputItem] {
        inputs.map { item in
            switch item {
            case let .message(message):
                let normalized = self.normalizedRole(message.role)
                if normalized == message.role {
                    return item
                }
                let sanitized = ResponsesMessage(role: normalized, content: message.content)
                return .message(sanitized)
            default:
                return item
            }
        }
    }

    private static func finishReasonForIncompleteResponseEvent(_ event: [String: Any]) -> FinishReason {
        guard
            let response = event["response"] as? [String: Any],
            let incompleteDetails = response["incomplete_details"] as? [String: Any],
            let reason = incompleteDetails["reason"] as? String else
        {
            return .other
        }

        return Self.finishReasonForIncompleteReason(reason)
    }

    private static func finishReasonForIncompleteReason(_ reason: String?) -> FinishReason {
        switch reason {
        case "content_filter":
            .contentFilter
        case "max_output_tokens":
            .length
        default:
            .other
        }
    }

    private func makeMessageEntry(role: String, message: ModelMessage) -> ResponsesMessage? {
        let parts = self.convertContentParts(for: message)
        guard !parts.isEmpty else { return nil }

        return ResponsesMessage(
            role: self.normalizedRole(role),
            content: .parts(parts),
        )
    }

    private func makeMessageEntry(role: String, content: [ModelMessage.ContentPart]) -> ResponsesMessage? {
        guard !content.isEmpty else { return nil }
        return self.makeMessageEntry(role: role, message: ModelMessage(role: .assistant, content: content))
    }

    private func normalizedRole(_ role: String) -> String {
        switch role {
        case "assistant", "system", "developer", "user":
            role
        default:
            "user"
        }
    }

    private func convertContentParts(for message: ModelMessage) -> [ResponsesContentPart] {
        var parts: [ResponsesContentPart] = []

        switch message.role {
        case .system, .user, .assistant:
            for segment in message.content {
                switch segment {
                case let .text(text):
                    guard !text.isEmpty else { continue }
                    let type = message.role == .assistant ? "output_text" : "input_text"
                    parts.append(ResponsesContentPart(type: type, text: text, imageUrl: nil))
                case let .image(image):
                    let dataURL = "data:\(image.mimeType);base64,\(image.data)"
                    // Keep detail locally for compatibility, but encode as string-only.
                    let imageRef = ResponsesContentPart.ImageURL(url: dataURL, detail: "auto")
                    parts.append(ResponsesContentPart(type: "input_image", text: nil, imageUrl: imageRef))
                case let .toolResult(result):
                    let rendered = self.convertToolResultToString(result.result)
                    if !rendered.isEmpty {
                        parts.append(ResponsesContentPart(type: "input_text", text: rendered, imageUrl: nil))
                    }
                case .reasoning, .toolCall:
                    continue
                }
            }
        case .tool:
            let aggregated = message.content.compactMap { segment -> String? in
                switch segment {
                case let .toolResult(result):
                    let rendered = self.convertToolResultToString(result.result)
                    return rendered.isEmpty ? nil : rendered
                case let .text(text):
                    return text.isEmpty ? nil : text
                default:
                    return nil
                }
            }.joined(separator: "\n")

            if !aggregated.isEmpty {
                parts.append(ResponsesContentPart(type: "input_text", text: aggregated, imageUrl: nil))
            }
        }

        return parts
    }

    private func makeFunctionCall(_ toolCall: AgentToolCall) -> ResponsesInputItem.FunctionCall? {
        guard let argumentsJSON = encodeToolCallArguments(toolCall.arguments) else {
            return nil
        }

        return ResponsesInputItem.FunctionCall(
            callId: toolCall.id,
            name: toolCall.name,
            arguments: argumentsJSON,
        )
    }

    private func makeFunctionCallOutput(_ result: AgentToolResult) -> ResponsesInputItem.FunctionCallOutput? {
        // OpenAI Responses API requires a tool output for every function call.
        // Some tools succeed with an empty stdout/result (e.g. file writes), so ensure we still emit a payload.
        let outputText = self.convertToolResultToString(result.result)
        let safeOutput = outputText.isEmpty ? "ok" : outputText

        return ResponsesInputItem.FunctionCallOutput(
            callId: result.toolCallId,
            output: safeOutput,
        )
    }

    private func convertToolResultToString(_ result: AnyAgentToolValue) -> String {
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
            // Convert array to JSON string
            if
                let data = try? JSONEncoder().encode(array),
                let jsonString = String(data: data, encoding: .utf8)
            {
                return jsonString
            }
            return "[]"
        } else if let dict = result.objectValue {
            // Convert object to JSON string
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

    private func encodeToolCallArguments(_ arguments: [String: AnyAgentToolValue]) -> String? {
        var jsonObject: [String: Any] = [:]
        for (key, value) in arguments {
            do {
                jsonObject[key] = try value.toJSON()
            } catch {
                continue
            }
        }

        guard
            JSONSerialization.isValidJSONObject(jsonObject),
            let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]),
            let jsonString = String(data: data, encoding: .utf8) else
        {
            return nil
        }
        return jsonString
    }

    private func convertTool(_ tool: AgentTool) throws -> ResponsesTool {
        var parameters = try tool.parameters.jsonSchema()

        // Keep rejecting unknown root arguments without opting into the provider's recursive strict-schema dialect.
        parameters["additionalProperties"] = false

        return ResponsesTool(
            name: tool.name,
            type: "function",
            description: tool.description,
            parameters: parameters,
            inputSchema: nil,
            // AgentToolParameters represents optional fields by omitting them from `required`.
            // Responses otherwise attempts to normalize omitted strictness into strict mode,
            // where every property becomes required and optionals must explicitly allow null.
            strict: false,
            function: nil,
        )
    }

    static func convertToProviderResponse(_ response: OpenAIResponsesResponse) throws -> ProviderResponse {
        // Handle GPT-5 output arrays and alternate choices arrays.
        var text: String
        var toolCalls: [AgentToolCall]?
        var finishReason: FinishReason?
        var assistantMessages: [ModelMessage] = []

        if let outputs = response.output {
            // GPT-5 format with output array
            var collectedText = ""
            var collectedToolCalls: [AgentToolCall] = []
            var collectedAssistantContent: [ModelMessage.ContentPart] = []
            var didCollectRefusal = false

            for output in outputs {
                if
                    output.type == "reasoning",
                    let encryptedContent = output.encryptedContent
                {
                    collectedAssistantContent.append(.reasoning(.init(
                        id: output.id,
                        encryptedContent: encryptedContent,
                        summary: output.summary,
                    )))
                } else if output.type == "message" {
                    if let content = output.content {
                        for chunk in content {
                            switch chunk.type {
                            case "output_text":
                                if let textSegment = chunk.text {
                                    collectedText.append(textSegment)
                                    if case let .text(existing)? = collectedAssistantContent.last {
                                        collectedAssistantContent[collectedAssistantContent.count - 1] =
                                            .text(existing + textSegment)
                                    } else {
                                        collectedAssistantContent.append(.text(textSegment))
                                    }
                                }
                            case "refusal":
                                if chunk.refusal != nil || chunk.text != nil {
                                    didCollectRefusal = true
                                }
                            case "tool_call":
                                if
                                    let toolCall = chunk.toolCall,
                                    let converted = Self.convertToolCall(toolCall)
                                {
                                    collectedToolCalls.append(converted)
                                    collectedAssistantContent.append(.toolCall(converted))
                                }
                            default:
                                continue
                            }
                        }
                    }
                } else if
                    output.type == "tool_call", let toolCall = output.toolCall,
                    let converted = Self.convertToolCall(toolCall)
                {
                    collectedToolCalls.append(converted)
                    collectedAssistantContent.append(.toolCall(converted))
                } else if
                    output.type == "function_call",
                    let callID = output.callId,
                    let name = output.name,
                    let arguments = output.arguments,
                    let converted = Self.makeToolCall(id: callID, name: name, argumentsJSON: arguments)
                {
                    collectedToolCalls.append(converted)
                    collectedAssistantContent.append(.toolCall(converted))
                }
            }

            text = collectedText
            let incompleteFinishReason = response.status == "incomplete"
                ? Self.finishReasonForIncompleteReason(response.incompleteDetails?.reason)
                : nil
            if incompleteFinishReason == .contentFilter || didCollectRefusal {
                text = ""
                toolCalls = nil
                finishReason = .contentFilter
                collectedAssistantContent.removeAll()
            } else {
                toolCalls = collectedToolCalls.isEmpty ? nil : collectedToolCalls
            }
            if finishReason == nil, let toolCalls, !toolCalls.isEmpty {
                finishReason = .toolCalls
            }
            if finishReason == nil {
                finishReason = incompleteFinishReason ?? .stop
            }
            assistantMessages = collectedAssistantContent.isEmpty
                ? []
                : [ModelMessage(role: .assistant, content: collectedAssistantContent)]
        } else if let choices = response.choices, let choice = choices.first {
            // Alternate format with choices array.
            text = choice.message.content ?? ""

            // Convert tool calls
            toolCalls = choice.message.toolCalls?.compactMap { Self.convertToolCall($0) }

            // Map finish reason
            if let reason = choice.finishReason {
                switch reason {
                case "stop": finishReason = .stop
                case "length": finishReason = .length
                case "tool_calls": finishReason = .toolCalls
                case "content_filter": finishReason = .contentFilter
                default: finishReason = .stop
                }
            } else {
                finishReason = nil
            }
            if finishReason == .contentFilter || choice.message.refusal != nil {
                text = ""
                toolCalls = nil
                finishReason = .contentFilter
            }
        } else {
            throw TachikomaError.apiError("No output or choices in response")
        }

        // Convert usage across Responses API token field variants.
        let usage: Usage?
        if let apiUsage = response.usage {
            // GPT-5 uses input_tokens/output_tokens
            // Alternate responses can use prompt_tokens/completion_tokens.
            let inputTokens = apiUsage.inputTokens ?? apiUsage.promptTokens ?? 0
            let outputTokens = apiUsage.outputTokens ?? apiUsage.completionTokens ?? 0

            usage = Usage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
            )
        } else {
            usage = nil
        }

        return ProviderResponse(
            text: text,
            usage: usage,
            finishReason: finishReason,
            toolCalls: toolCalls,
            assistantMessages: assistantMessages,
        )
    }

    private static func convertToolCall(_ toolCall: OpenAIResponsesResponse.ResponsesToolCall) -> AgentToolCall? {
        if
            ProcessInfo.processInfo.arguments.contains("--verbose") ||
            ProcessInfo.processInfo.arguments.contains("-v")
        {
            print("DEBUG: Tool call \(toolCall.function.name) raw arguments: \(toolCall.function.arguments)")
        }

        guard let argumentsJSON = toolCall.function.arguments.data(using: .utf8) else {
            return nil
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            return nil
        }

        var arguments: [String: AnyAgentToolValue] = [:]
        for (key, value) in jsonObject {
            do {
                arguments[key] = try AnyAgentToolValue.fromJSON(value)
            } catch {
                continue
            }
        }

        return AgentToolCall(
            id: toolCall.id,
            name: toolCall.function.name,
            arguments: arguments,
        )
    }

    private static func makeToolCall(id: String, name: String, argumentsJSON: String) -> AgentToolCall? {
        if
            ProcessInfo.processInfo.arguments.contains("--verbose") ||
            ProcessInfo.processInfo.arguments.contains("-v")
        {
            print("DEBUG: Streaming tool call \(name) raw arguments: \(argumentsJSON)")
        }

        guard
            let data = argumentsJSON.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else
        {
            return nil
        }

        var arguments: [String: AnyAgentToolValue] = [:]
        for (key, value) in jsonObject {
            do {
                arguments[key] = try AnyAgentToolValue.fromJSON(value)
            } catch {
                continue
            }
        }

        return AgentToolCall(id: id, name: name, arguments: arguments)
    }

    private static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["DEBUG_TACHIKOMA_STREAM"] != nil else { return }
        let formatted = "🔵 DEBUG \(message)\n"
        if let data = formatted.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.debugLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: Self.debugLogURL)
            }
        }
    }

    private static func isReasoningModel(_: LanguageModel.OpenAI) -> Bool {
        false
    }

    private static func isGPT5Model(_ model: LanguageModel.OpenAI) -> Bool {
        switch model {
        case .gpt56Sol,
             .gpt56Terra,
             .gpt56Luna,
             .gpt55,
             .gpt54,
             .gpt54Mini,
             .gpt54Nano,
             .gpt5,
             .gpt5Pro,
             .gpt5Mini,
             .gpt5Nano:
            true
        default:
            false
        }
    }

    private static func isGPT56Model(_ model: LanguageModel.OpenAI) -> Bool {
        switch model {
        case .gpt56Sol, .gpt56Terra, .gpt56Luna:
            true
        default:
            false
        }
    }

    private static func usesResponsesEventStream(_ model: LanguageModel.OpenAI) -> Bool {
        model == .chatLatest || model == .gpt5ChatLatest || self.isGPT5Model(model)
    }
}

// Configuration extensions removed - properties are immutable for Sendable conformance
// TODO: Consider using a separate configuration object or factory pattern for customization
