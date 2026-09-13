import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider for Anthropic Claude models
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class AnthropicProvider: ModelProvider {
    public let modelId: String
    public let baseURL: String?
    public let apiKey: String?
    public let capabilities: ModelCapabilities

    private let model: LanguageModel.Anthropic
    private let auth: TKAuthValue
    private let betaHeader: String
    private let additionalHeaders: [String: String]
    private let reasoningProvider: String
    private let reasoningModelId: String
    private let reasoningBaseURL: String?
    private let urlSession: URLSession

    private static let requiredBetaFlags: [String] = [
        "interleaved-thinking-2025-05-14",
        "fine-grained-tool-streaming-2025-05-14",
    ]
    public init(
        model: LanguageModel.Anthropic,
        configuration: TachikomaConfiguration,
        additionalHeaders: [String: String] = [:],
        authOverride: TKAuthValue? = nil,
        reasoningProvider: String = "anthropic",
        reasoningModelId: String? = nil,
        reasoningBaseURL: String? = nil,
        urlSession: URLSession = .shared,
    ) throws {
        self.model = model
        self.modelId = model.modelId
        self.baseURL = configuration.getBaseURL(for: .anthropic) ?? "https://api.anthropic.com"
        self.additionalHeaders = additionalHeaders
        self.reasoningProvider = reasoningProvider
        self.reasoningModelId = reasoningModelId ?? model.modelId
        self.reasoningBaseURL = ReasoningEndpointIdentity.canonical(
            reasoningBaseURL ?? (reasoningProvider == "anthropic" ? self.baseURL : nil),
        )
        self.urlSession = urlSession

        if let authOverride {
            self.auth = authOverride
            switch authOverride {
            case let .apiKey(key):
                self.apiKey = key
            case let .bearer(token, _):
                self.apiKey = token
            }
        } else if let key = configuration.getAPIKey(for: .anthropic) {
            self.auth = .apiKey(key)
            self.apiKey = key
        } else if let auth = TKAuthManager.shared.resolveAuth(for: .anthropic) {
            self.auth = auth
            switch auth {
            case let .apiKey(key):
                self.apiKey = key
            case let .bearer(token, _):
                self.apiKey = token
            }
        } else {
            throw TachikomaError.authenticationFailed("ANTHROPIC_API_KEY not found")
        }

        self.betaHeader = Self.mergedBetaHeader(configuration: configuration, auth: self.auth, model: model)

        let isFable = Self.isFable(model: model)
        let supportsSafeStreaming = !Self.hasStreamingRefusalRisk(model: model)
        self.capabilities = ModelCapabilities(
            supportsVision: model.supportsVision,
            supportsTools: model.supportsTools,
            supportsStreaming: supportsSafeStreaming,
            supportsAudioInput: model.supportsAudioInput,
            supportsAudioOutput: model.supportsAudioOutput,
            contextLength: isFable ? 1_000_000 : model.contextLength,
            maxOutputTokens: isFable ? 128_000 : model.maxOutputTokens,
        )
    }

    static func mergedBetaHeader(existing: String?) -> String {
        var merged: [String] = []
        var seen = Set<String>()

        let existingParts = (existing ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for part in existingParts where seen.insert(part).inserted {
            merged.append(part)
        }
        for required in Self.requiredBetaFlags where seen.insert(required).inserted {
            merged.append(required)
        }

        return merged.joined(separator: ",")
    }

    private static func mergedBetaHeader(
        configuration: TachikomaConfiguration,
        auth: TKAuthValue,
        model: LanguageModel.Anthropic?,
    )
        -> String
    {
        var existing: String?
        if case let .bearer(_, betaHeader) = auth {
            existing = betaHeader
        }

        if existing?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            existing = configuration.credentialValue(for: "ANTHROPIC_BETA_HEADER")
        }

        if let model, Self.isFable(model: model) {
            return existing?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ",") ?? ""
        }

        return Self.mergedBetaHeader(existing: existing)
    }

    private func anthropicThinking(
        from mode: AnthropicOptions.ThinkingMode?,
        model: LanguageModel.Anthropic,
    )
        -> AnthropicThinking?
    {
        guard let mode else { return nil }
        switch mode {
        case .disabled:
            if LanguageModel.Anthropic.isSonnet5(modelId: model.modelId) {
                return AnthropicThinking(type: "disabled", budgetTokens: nil)
            }
            return nil
        case .adaptive:
            if Self.isFable(model: model) {
                return nil
            }
            guard self.usesAdaptiveThinking(model: model) else { return nil }
            return AnthropicThinking(type: "adaptive", budgetTokens: nil)
        case let .enabled(budgetTokens):
            if Self.isFable(model: model) {
                return nil
            }
            if LanguageModel.Anthropic.isSonnet5(modelId: model.modelId) {
                return AnthropicThinking(type: "adaptive", budgetTokens: nil)
            }
            if Self.isOpus5(model: model) {
                return AnthropicThinking(type: "adaptive", budgetTokens: nil)
            }
            if case .opus48 = model {
                return AnthropicThinking(type: "adaptive", budgetTokens: nil)
            }
            if case .opus47 = model {
                return AnthropicThinking(type: "adaptive", budgetTokens: nil)
            }
            return AnthropicThinking(type: "enabled", budgetTokens: budgetTokens)
        }
    }

    private func anthropicOutputConfig(
        from mode: AnthropicOptions.ThinkingMode?,
        settings: GenerationSettings,
        model: LanguageModel.Anthropic,
    )
        throws -> AnthropicOutputConfig?
    {
        guard self.supportsEffort(model: model) else { return nil }
        if let effort = settings.reasoningEffort {
            if !self.supports(effort: effort, model: model) {
                throw TachikomaError.invalidConfiguration(
                    "Reasoning effort '\(effort.rawValue)' is not supported by \(model.modelId)",
                )
            }
            return AnthropicOutputConfig(effort: effort.rawValue)
        }
        if case .disabled = mode {
            return nil
        }

        let effort = self.usesAdaptiveThinking(model: model) ? self.adaptiveEffort(from: mode) : nil
        return effort.map { AnthropicOutputConfig(effort: $0) }
    }

    private func supports(effort: ReasoningEffort, model: LanguageModel.Anthropic) -> Bool {
        switch effort {
        case .low, .medium, .high:
            true
        case .xhigh:
            Self.isFable(model: model) ||
                LanguageModel.Anthropic.isSonnet5(modelId: model.modelId) ||
                Self.isOpus5(model: model) || model == .opus48 || model == .opus47
        case .max:
            Self.isFable(model: model) ||
                LanguageModel.Anthropic.isSonnet5(modelId: model.modelId) ||
                Self.isOpus5(model: model) || model == .opus48 || model == .opus47 || model == .sonnet46
        }
    }

    private func usesAdaptiveThinking(model: LanguageModel.Anthropic) -> Bool {
        if Self.isFable(model: model) {
            return true
        }
        if LanguageModel.Anthropic.isSonnet5(modelId: model.modelId) {
            return true
        }
        if Self.isOpus5(model: model) {
            return true
        }
        if case .opus48 = model {
            return true
        }
        if case .opus47 = model {
            return true
        }
        if case .sonnet46 = model {
            return true
        }
        return false
    }

    private func supportsEffort(model: LanguageModel.Anthropic) -> Bool {
        if Self.isFable(model: model) {
            return true
        }
        if LanguageModel.Anthropic.isSonnet5(modelId: model.modelId) {
            return true
        }
        if Self.isOpus5(model: model) {
            return true
        }
        switch model {
        case .opus48, .opus47, .opus45, .sonnet46:
            return true
        default:
            return false
        }
    }

    private func adaptiveEffort(from mode: AnthropicOptions.ThinkingMode?) -> String? {
        guard case let .enabled(budgetTokens) = mode else { return nil }

        if budgetTokens <= 4096 {
            return ReasoningEffort.low.rawValue
        }
        if budgetTokens <= 12000 {
            return ReasoningEffort.medium.rawValue
        }
        return ReasoningEffort.high.rawValue
    }

    private func messagesEndpointURL() throws -> URL {
        guard let baseURL = self.baseURL, let url = URL(string: baseURL) else {
            throw TachikomaError.invalidConfiguration("Invalid Anthropic base URL: \(self.baseURL ?? "<nil>")")
        }

        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.hasSuffix("v1/messages") {
            return url
        }
        if trimmedPath.hasSuffix("v1") {
            return url.appendingPathComponent("messages")
        }
        return url.appendingPathComponent("v1").appendingPathComponent("messages")
    }

    func makeURLRequest(for request: ProviderRequest, stream: Bool) throws -> URLRequest {
        guard let apiKey else {
            throw TachikomaError.authenticationFailed("Anthropic API key not found")
        }

        let url = try self.messagesEndpointURL()
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        self.applyAuth(to: &urlRequest, secret: apiKey)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (key, value) in self.additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let validatedSettings = request.settings.validated(for: .anthropic(self.model))
        let thinkingMode = validatedSettings.providerOptions.anthropic?.thinking
        if
            Self.isFable(model: self.model),
            case .disabled = thinkingMode
        {
            throw TachikomaError.invalidConfiguration(
                "Claude Fable 5 always uses adaptive thinking; disabled thinking is not supported",
            )
        }
        if
            LanguageModel.Anthropic.hasDefaultAdaptiveThinking(modelId: self.model.modelId),
            request.messages.last?.role == .assistant
        {
            throw TachikomaError.invalidConfiguration(
                "This Claude model does not support assistant prefill requests",
            )
        }
        let requestedThinking = self.anthropicThinking(
            from: thinkingMode,
            model: self.model,
        )
        let outputConfig = try self.anthropicOutputConfig(
            from: thinkingMode,
            settings: validatedSettings,
            model: self.model,
        )
        var thinking: AnthropicThinking?
        let systemMessage: String?
        let messages: [AnthropicMessage]
        let thinkingDisabled = if case .disabled = thinkingMode {
            true
        } else {
            false
        }
        let requiresSignedThinkingReplay = self.requiresSignedThinkingReplay(model: self.model)
        let preserveSignedThinking = !thinkingDisabled && (requestedThinking != nil || requiresSignedThinkingReplay)
        let reasoningTarget = AnthropicReasoningReplayTarget(
            provider: self.reasoningProvider,
            modelId: self.reasoningModelId,
            endpointIdentity: self.reasoningBaseURL,
            allowsLegacyUnknown: !requiresSignedThinkingReplay,
        )
        do {
            thinking = requestedThinking
            (systemMessage, messages) = try AnthropicMessageConversion.convertMessagesToAnthropic(
                request.messages,
                thinkingEnabled: preserveSignedThinking,
                reasoningTarget: reasoningTarget,
            )
        } catch {
            // If we can't provide signed thinking blocks for a cached/history session, fall back to non-thinking mode.
            if requestedThinking != nil, !requiresSignedThinkingReplay {
                thinking = nil
                (systemMessage, messages) = try AnthropicMessageConversion.convertMessagesToAnthropic(
                    request.messages,
                    thinkingEnabled: false,
                    reasoningTarget: reasoningTarget,
                )
            } else {
                throw error
            }
        }
        let maxTokens = validatedSettings.maxTokens ?? self.defaultMaxTokens(for: self.model)
        if !stream, Self.requiresExtendedNonStreamingTimeout(model: self.model, maxTokens: maxTokens) {
            urlRequest.timeoutInterval = 1800
        }

        let anthropicRequest = try AnthropicMessageRequest(
            model: modelId,
            maxTokens: maxTokens,
            temperature: thinking == nil ? validatedSettings.temperature : nil,
            system: systemMessage,
            messages: messages,
            tools: request.tools?.map { try self.convertToolToAnthropic($0) },
            thinking: thinking,
            outputConfig: outputConfig,
            stream: stream,
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted // For debugging
        urlRequest.httpBody = try encoder.encode(anthropicRequest)
        return urlRequest
    }

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        let urlRequest = try self.makeURLRequest(for: request, stream: false)

        // Debug logging only when explicitly enabled
        let tachikomaConfig = TachikomaConfiguration.current
        if ProcessInfo.processInfo.environment["DEBUG_ANTHROPIC"] != nil || tachikomaConfig.verbose {
            if
                let requestData = urlRequest.httpBody,
                let jsonString = String(data: requestData, encoding: .utf8)
            {
                print("DEBUG AnthropicProvider: Request JSON (tools count: \(request.tools?.count ?? 0)):")
                // Only print the first part to avoid flooding
                let preview = String(jsonString.prefix(2000))
                print(preview)
                if jsonString.count > 2000 {
                    print("... (truncated, total \(jsonString.count) chars)")
                }
            }
        }

        let (data, response) = try await self.urlSession.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"

            // Try to parse Anthropic error format
            if let errorData = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
                throw TachikomaError.apiError("Anthropic Error: \(errorData.error.message)")
            }

            throw TachikomaError.apiError("Anthropic Error (HTTP \(httpResponse.statusCode)): \(errorText)")
        }

        let decoder = JSONDecoder()
        let anthropicResponse = try decoder.decode(AnthropicMessageResponse.self, from: data)

        // Debug: Print the response when verbose
        if TachikomaConfiguration.current.verbose {
            if let jsonString = String(data: data, encoding: .utf8) {
                print("DEBUG: Anthropic response JSON:")
                print(jsonString)
            }
        }

        let text = anthropicResponse.content.compactMap { content in
            switch content {
            case let .text(textContent):
                textContent.text
            case .thinking, .redactedThinking, .toolUse:
                nil
            }
        }.joined()

        let usage = Usage(
            inputTokens: anthropicResponse.usage.inputTokens,
            outputTokens: anthropicResponse.usage.outputTokens,
        )

        let finishReason = Self.mapFinishReason(anthropicResponse.stopReason)
        if finishReason == .contentFilter {
            let fallbackRefusalText = if let category = anthropicResponse.stopDetails?.category {
                "Request refused by Anthropic content filter (\(category))"
            } else {
                "Request refused by Anthropic content filter"
            }
            let refusalText = anthropicResponse.stopDetails?.explanation ?? fallbackRefusalText
            return ProviderResponse(
                text: refusalText,
                usage: usage,
                finishReason: finishReason,
                toolCalls: nil,
                reasoning: [],
                assistantMessages: [],
                isBillable: usage.outputTokens > 0,
            )
        }

        var reasoning: [ProviderReasoningBlock] = []
        var toolCalls: [AgentToolCall] = []
        var assistantMessages: [ModelMessage] = []

        for content in anthropicResponse.content {
            switch content {
            case let .text(textContent):
                if !textContent.text.isEmpty {
                    assistantMessages.append(.assistant(textContent.text))
                }
            case let .thinking(thinking):
                let block = ProviderReasoningBlock(
                    text: thinking.thinking,
                    signature: thinking.signature,
                    type: thinking.type,
                )
                reasoning.append(block)
                assistantMessages.append(ModelMessage(
                    role: .assistant,
                    content: [.text(thinking.thinking)],
                    channel: .thinking,
                    metadata: .init(customData: self.reasoningMetadata(
                        type: thinking.type,
                        signature: thinking.signature,
                    )),
                ))
            case let .redactedThinking(thinking):
                let block = ProviderReasoningBlock(
                    text: thinking.data,
                    type: thinking.type,
                )
                reasoning.append(block)
                assistantMessages.append(ModelMessage(
                    role: .assistant,
                    content: [.text(thinking.data)],
                    channel: .thinking,
                    metadata: .init(customData: self.reasoningMetadata(type: thinking.type)),
                ))
            case let .toolUse(toolUse):
                // Convert input to AnyAgentToolValue dictionary
                var arguments: [String: AnyAgentToolValue] = [:]
                if let inputDict = toolUse.input as? [String: Any] {
                    for (key, value) in inputDict {
                        do {
                            arguments[key] = try AnyAgentToolValue.fromJSON(value)
                        } catch {
                            // Log warning and skip arguments that can't be converted
                            print("[WARNING] Failed to convert tool argument '\(key)': \(error)")
                            continue
                        }
                    }
                }

                let toolCall = AgentToolCall(
                    id: toolUse.id,
                    name: toolUse.name,
                    arguments: arguments,
                )
                toolCalls.append(toolCall)
                assistantMessages.append(ModelMessage(role: .assistant, content: [.toolCall(toolCall)]))
            }
        }

        return ProviderResponse(
            text: text,
            usage: usage,
            finishReason: finishReason,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            reasoning: reasoning,
            assistantMessages: assistantMessages,
        )
    }

    private func reasoningMetadata(type: String, signature: String? = nil) -> [String: String] {
        var metadata = [
            "anthropic.thinking.model": self.reasoningModelId,
            "anthropic.thinking.type": type,
            "tachikoma.reasoning.provider": self.reasoningProvider,
            "tachikoma.reasoning.model": self.reasoningModelId,
        ]
        if let signature, !signature.isEmpty {
            metadata["anthropic.thinking.signature"] = signature
        }
        if let reasoningBaseURL {
            metadata["tachikoma.reasoning.base_url"] = reasoningBaseURL
        }
        return metadata
    }

    private func requiresSignedThinkingReplay(model: LanguageModel.Anthropic) -> Bool {
        LanguageModel.Anthropic.hasDefaultAdaptiveThinking(modelId: model.modelId)
    }

    private func defaultMaxTokens(for model: LanguageModel.Anthropic) -> Int {
        if LanguageModel.Anthropic.hasDefaultAdaptiveThinking(modelId: model.modelId) {
            return min(model.maxOutputTokens, 16384)
        }
        return 1024
    }

    private static func isFable(model: LanguageModel.Anthropic) -> Bool {
        LanguageModel.Anthropic.isFable(modelId: model.modelId)
    }

    private static func isOpus5(model: LanguageModel.Anthropic) -> Bool {
        LanguageModel.Anthropic.isOpus5(modelId: model.modelId)
    }

    private static func hasStreamingRefusalRisk(model: LanguageModel.Anthropic) -> Bool {
        LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: model.modelId)
    }

    private static func requiresExtendedNonStreamingTimeout(model: LanguageModel.Anthropic, maxTokens: Int) -> Bool {
        LanguageModel.Anthropic.hasDefaultAdaptiveThinking(modelId: model.modelId) || maxTokens >= 64000
    }

    static func mapFinishReason(_ stopReason: String?) -> FinishReason? {
        switch stopReason {
        case "end_turn": .stop
        case "max_tokens": .length
        case "tool_use": .toolCalls
        case "stop_sequence": .stop
        case "model_context_window_exceeded": .length
        case "refusal": .contentFilter
        case nil: nil
        default: .other
        }
    }

    private func applyAuth(to request: inout URLRequest, secret: String) {
        switch self.auth {
        case .apiKey:
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        }
        if !self.betaHeader.isEmpty {
            request.setValue(self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        }
    }

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        guard !Self.hasStreamingRefusalRisk(model: self.model) else {
            let message = "\(self.model.modelId) streaming is disabled because Anthropic refusals require rollback-aware handling"
            throw TachikomaError.invalidConfiguration(
                "\(message); use generateText instead",
            )
        }

        let urlRequest = try self.makeURLRequest(for: request, stream: true)

        // Debug logging only when explicitly enabled
        let config = TachikomaConfiguration.current
        if
            ProcessInfo.processInfo.environment["DEBUG_ANTHROPIC"] != nil ||
            config.verbose
        {
            print("\n🔴 DEBUG AnthropicProvider.streamText called with:")
            print("   Model: \(self.modelId)")
            print("   Tools count: \(request.tools?.count ?? 0)")
            if let tools = request.tools {
                print("   Tool names: \(tools.map(\.name).joined(separator: ", "))")
            }
            print("   Messages: \(request.messages.count)")

            // Debug: Log the actual messages being sent
            for (idx, msg) in request.messages.enumerated() {
                print("   Message \(idx): role=\(msg.role)")
                for content in msg.content {
                    switch content {
                    case let .text(text):
                        print("     - text: \(text.prefix(100))...")
                    case let .toolCall(call):
                        print("     - tool_call: id=\(call.id), name=\(call.name)")
                    case let .toolResult(result):
                        print("     - tool_result: tool_call_id=\(result.toolCallId)")
                    default:
                        print("     - other content")
                    }
                }
            }

            // Debug: Show first 2000 chars of JSON request
            if
                let requestData = urlRequest.httpBody,
                let jsonString = String(data: requestData, encoding: .utf8)
            {
                print("\n🔴 Anthropic Request JSON (first 2000 chars):")
                print(jsonString.prefix(2000))
            }
        }

        // Use URLSession's bytes API for proper streaming
        #if canImport(FoundationNetworking)
        // Linux buffers the body; the async API still propagates cancellation.
        let (data, response) = try await self.urlSession.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
        }

        guard httpResponse.statusCode == 200 else {
            // Return error data
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TachikomaError.apiError("Anthropic Error (HTTP \(httpResponse.statusCode)): \(errorText)")
        }

        // For Linux, parse the entire response at once
        let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
        #else
        // macOS/iOS: Use streaming API
        let (bytes, response) = try await self.urlSession.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
        }

        guard httpResponse.statusCode == 200 else {
            // Collect error data
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errorText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw TachikomaError.apiError("Anthropic Error (HTTP \(httpResponse.statusCode)): \(errorText)")
        }

        return AsyncThrowingStream { continuation in
            let producer = Task {
                var currentToolCall: (id: String, name: String, partialInput: String)?
                var accumulatedText = ""
                var accumulatedReasoning = ""
                var currentReasoningSignature: String?
                var currentReasoningType: String?
                var reasoningSignatureEmitted = false
                var finishReason: FinishReason?

                do {
                    for try await line in bytes.lines {
                        // Skip empty lines
                        guard !line.isEmpty else { continue }

                        // Process SSE events
                        if line.hasPrefix("event: ") {
                            // We'll use the event type in the next data line
                            continue
                        }

                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            // Check for stream end
                            if jsonString.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                                // Yield accumulated text if any
                                if !accumulatedText.isEmpty {
                                    continuation.yield(TextStreamDelta.text(accumulatedText))
                                    accumulatedText = ""
                                }
                                if !accumulatedReasoning.isEmpty {
                                    continuation.yield(TextStreamDelta.reasoning(
                                        accumulatedReasoning,
                                        signature: reasoningSignatureEmitted ? nil : currentReasoningSignature,
                                        type: currentReasoningType,
                                    ))
                                    accumulatedReasoning = ""
                                    currentReasoningSignature = nil
                                    currentReasoningType = nil
                                    reasoningSignatureEmitted = false
                                }
                                continuation.yield(.done(finishReason: finishReason))
                                break
                            }

                            guard let data = jsonString.data(using: .utf8) else { continue }

                            do {
                                let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)

                                switch event.type {
                                case "message_start":
                                    // Message is starting
                                    continue

                                case "content_block_start":
                                    if let block = event.contentBlock {
                                        if block.type == "tool_use" {
                                            // Starting a tool call
                                            currentToolCall = (
                                                id: block.id ?? "",
                                                name: block.name ?? "",
                                                partialInput: "",
                                            )
                                        } else if block.type == "text" {
                                            // Text block starting
                                            continue
                                        } else if block.type == "thinking" || block.type == "redacted_thinking" {
                                            // Reasoning block starting
                                            currentReasoningSignature = nil
                                            currentReasoningType = block.type
                                            reasoningSignatureEmitted = false
                                            if block.type == "redacted_thinking", let data = block.data {
                                                continuation.yield(TextStreamDelta.reasoning(
                                                    data,
                                                    type: "redacted_thinking",
                                                ))
                                            }
                                            continue
                                        }
                                    }

                                case "content_block_delta":
                                    if let delta = event.delta {
                                        if delta.type == "text_delta", let text = delta.text {
                                            // Accumulate text
                                            accumulatedText += text
                                            // Yield text in chunks
                                            if accumulatedText.count >= 20 {
                                                continuation.yield(TextStreamDelta.text(accumulatedText))
                                                accumulatedText = ""
                                            }
                                        } else if delta.type == "thinking_delta", let thinking = delta.thinking {
                                            accumulatedReasoning += thinking
                                            if accumulatedReasoning.count >= 20 {
                                                let signatureToSend = reasoningSignatureEmitted ? nil :
                                                    currentReasoningSignature
                                                continuation.yield(TextStreamDelta.reasoning(
                                                    accumulatedReasoning,
                                                    signature: signatureToSend,
                                                    type: currentReasoningType,
                                                ))
                                                accumulatedReasoning = ""
                                                if signatureToSend != nil {
                                                    reasoningSignatureEmitted = true
                                                }
                                            }
                                        } else if
                                            delta.type == "signature_delta", let signature = delta.signature,
                                            !signature.isEmpty
                                        {
                                            currentReasoningSignature = signature
                                            if !reasoningSignatureEmitted {
                                                continuation.yield(TextStreamDelta.reasoning(
                                                    "",
                                                    signature: signature,
                                                    type: currentReasoningType,
                                                ))
                                                reasoningSignatureEmitted = true
                                            }
                                        } else if
                                            delta.type == "input_json_delta",
                                            let partialJson = delta.partialJson
                                        {
                                            // Accumulate tool input
                                            if var toolCall = currentToolCall {
                                                toolCall.partialInput += partialJson
                                                currentToolCall = toolCall
                                            }
                                        }
                                    }

                                case "content_block_stop":
                                    // Yield any remaining text
                                    if !accumulatedText.isEmpty {
                                        continuation.yield(TextStreamDelta.text(accumulatedText))
                                        accumulatedText = ""
                                    }
                                    if !accumulatedReasoning.isEmpty {
                                        continuation.yield(TextStreamDelta.reasoning(
                                            accumulatedReasoning,
                                            signature: reasoningSignatureEmitted ? nil : currentReasoningSignature,
                                            type: currentReasoningType,
                                        ))
                                        accumulatedReasoning = ""
                                        currentReasoningSignature = nil
                                        currentReasoningType = nil
                                        reasoningSignatureEmitted = false
                                    }

                                    // Complete tool call if we have one
                                    if let toolCall = currentToolCall {
                                        // Parse the complete JSON input
                                        if
                                            let inputData = toolCall.partialInput.data(using: .utf8),
                                            let inputJson = try? JSONSerialization
                                                .jsonObject(with: inputData) as? [String: Any]
                                        {
                                            // Convert to AnyAgentToolValue arguments
                                            var arguments: [String: AnyAgentToolValue] = [:]
                                            for (key, value) in inputJson {
                                                do {
                                                    arguments[key] = try AnyAgentToolValue.fromJSON(value)
                                                } catch {
                                                    print(
                                                        "[WARNING] Failed to convert tool argument '\(key)': \(error)",
                                                    )
                                                }
                                            }

                                            let agentToolCall = AgentToolCall(
                                                id: toolCall.id,
                                                name: toolCall.name,
                                                arguments: arguments,
                                            )
                                            continuation.yield(TextStreamDelta.tool(agentToolCall))
                                        }
                                        currentToolCall = nil
                                    }

                                case "message_delta":
                                    // Message-level updates (usage, etc.)
                                    if let stopReason = event.delta?.stopReason {
                                        finishReason = Self.mapFinishReason(stopReason)
                                    }
                                    continue

                                case "message_stop":
                                    // Yield any final accumulated text
                                    if !accumulatedText.isEmpty {
                                        continuation.yield(TextStreamDelta.text(accumulatedText))
                                        accumulatedText = ""
                                    }
                                    if !accumulatedReasoning.isEmpty {
                                        continuation.yield(TextStreamDelta.reasoning(
                                            accumulatedReasoning,
                                            signature: reasoningSignatureEmitted ? nil : currentReasoningSignature,
                                            type: currentReasoningType,
                                        ))
                                        accumulatedReasoning = ""
                                        currentReasoningSignature = nil
                                        currentReasoningType = nil
                                        reasoningSignatureEmitted = false
                                    }
                                    continuation.yield(.done(finishReason: finishReason))

                                default:
                                    // Unknown event type, skip
                                    continue
                                }
                            } catch {
                                // Log parsing error in verbose mode
                                let config = TachikomaConfiguration.current
                                if config.verbose {
                                    print("[WARNING] Failed to parse stream event: \(error)")
                                    print("Raw JSON: \(jsonString)")
                                }
                                continue
                            }
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        #endif // End of macOS/iOS streaming implementation

        #if canImport(FoundationNetworking)
        // Linux implementation: Parse the entire response
        return AsyncThrowingStream { continuation in
            let producer = Task {
                var currentToolCall: (id: String, name: String, partialInput: String)?
                var accumulatedText = ""
                var accumulatedReasoning = ""
                var currentReasoningSignature: String?
                var currentReasoningType: String?
                var reasoningSignatureEmitted = false
                var finishReason: FinishReason?

                do {
                    for line in lines {
                        // Skip empty lines
                        guard !line.isEmpty else { continue }

                        // Process SSE events
                        if line.hasPrefix("event: ") {
                            continue
                        }

                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            // Check for stream end
                            if jsonString.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                                if !accumulatedText.isEmpty {
                                    continuation.yield(TextStreamDelta.text(accumulatedText))
                                }
                                if !accumulatedReasoning.isEmpty {
                                    continuation.yield(TextStreamDelta.reasoning(
                                        accumulatedReasoning,
                                        signature: reasoningSignatureEmitted ? nil : currentReasoningSignature,
                                        type: currentReasoningType,
                                    ))
                                }
                                continuation.yield(.done(finishReason: finishReason))
                                break
                            }

                            guard let data = jsonString.data(using: .utf8) else { continue }

                            do {
                                let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)

                                // Process events similar to macOS implementation
                                switch event.type {
                                case "content_block_start":
                                    if
                                        let block = event.contentBlock,
                                        block.type == "thinking" || block.type == "redacted_thinking"
                                    {
                                        currentReasoningSignature = nil
                                        currentReasoningType = block.type
                                        reasoningSignatureEmitted = false
                                        if block.type == "redacted_thinking", let data = block.data {
                                            continuation.yield(TextStreamDelta.reasoning(
                                                data,
                                                type: "redacted_thinking",
                                            ))
                                        }
                                    }
                                case "content_block_delta":
                                    if let delta = event.delta {
                                        if
                                            delta.type == "signature_delta", let signature = delta.signature,
                                            !signature.isEmpty
                                        {
                                            currentReasoningSignature = signature
                                            if !reasoningSignatureEmitted {
                                                continuation.yield(TextStreamDelta.reasoning(
                                                    "",
                                                    signature: signature,
                                                    type: currentReasoningType,
                                                ))
                                                reasoningSignatureEmitted = true
                                            }
                                        } else if let text = delta.text {
                                            accumulatedText += text
                                        } else if let thinking = delta.thinking {
                                            accumulatedReasoning += thinking
                                        }
                                    }
                                case "message_delta":
                                    if let stopReason = event.delta?.stopReason {
                                        finishReason = Self.mapFinishReason(stopReason)
                                    }
                                case "message_stop":
                                    if !accumulatedText.isEmpty {
                                        continuation.yield(TextStreamDelta.text(accumulatedText))
                                    }
                                    if !accumulatedReasoning.isEmpty {
                                        continuation.yield(TextStreamDelta.reasoning(
                                            accumulatedReasoning,
                                            signature: reasoningSignatureEmitted ? nil : currentReasoningSignature,
                                            type: currentReasoningType,
                                        ))
                                    }
                                    continuation.yield(.done(finishReason: finishReason))
                                default:
                                    continue
                                }
                            } catch {
                                continue
                            }
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        #endif
    }

    private func convertToolToAnthropic(_ tool: AgentTool) throws -> AnthropicTool {
        let schema = try tool.parameters.jsonSchema(options: [.defaultStringArrayItems])

        return try AnthropicTool(
            name: tool.name,
            description: tool.description,
            inputSchema: AnthropicInputSchema(schema),
        )
    }
}
