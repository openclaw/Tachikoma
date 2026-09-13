import Foundation

// MARK: - AI SDK Core Functions (Following Vercel AI SDK Patterns)

/// Generate text using AI models following the Vercel AI SDK generateText pattern
///
/// This function provides a clean, type-safe API for text generation with support for
/// tools, multi-step execution, and rich result types.
///
/// - Parameters:
///   - model: The language model to use
///   - messages: Array of conversation messages
///   - tools: Optional tools the model can call
///   - settings: Generation settings (temperature, maxTokens, etc.)
///   - maxSteps: Maximum number of tool calling steps (default: 1)
/// - Returns: Complete generation result with text, usage, and execution steps
/// - Throws: TachikomaError for any failures
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@discardableResult
public func generateText(
    model: LanguageModel,
    messages: [ModelMessage],
    tools: [AgentTool]? = nil,
    settings: GenerationSettings = .default,
    maxSteps: Int = 1,
    timeout: TimeInterval? = nil,
    configuration: TachikomaConfiguration = .current,
    sessionId: String? = nil,
) async throws
    -> GenerateTextResult
{
    let resolvedConfiguration = TachikomaConfiguration.resolve(configuration)
    let provider = try resolvedConfiguration.makeProvider(for: model)

    var currentMessages = messages
    var allSteps: [GenerationStep] = []
    var totalUsage = Usage(inputTokens: 0, outputTokens: 0)
    var finalResponseStartIndex = messages.count

    for stepIndex in 0..<maxSteps {
        let request = ProviderRequest(
            messages: currentMessages.sanitizedForProvider(
                model,
                provider: provider,
                configuration: resolvedConfiguration,
            ),
            tools: tools,
            settings: settings,
        )

        let response: ProviderResponse = if let timeout {
            try await withTimeout(timeout) {
                try await provider.generateText(request: request)
            }
        } else {
            try await provider.generateText(request: request)
        }

        let isContentFiltered = response.finishReason == .contentFilter
        let responseText = isContentFiltered ? "" : response.text
        let responseToolCalls = isContentFiltered ? [] : (response.toolCalls ?? [])
        let responseReasoning = isContentFiltered ? [] : response.reasoning
        let responseAssistantMessages = isContentFiltered ? [] : response.assistantMessages
        // Providers historically may omit a finish reason for valid tool calls.
        // Explicit non-tool terminal reasons must never trigger or persist side effects.
        let canExecuteToolCalls = response.finishReason == nil || response.finishReason == .toolCalls
        let historyAssistantMessages = canExecuteToolCalls
            ? responseAssistantMessages
            : responseAssistantMessages.compactMap { message in
                let safeContent = message.content.filter { part in
                    if case .toolCall = part {
                        false
                    } else {
                        true
                    }
                }
                guard !safeContent.isEmpty else { return nil }
                return ModelMessage(
                    id: message.id,
                    role: message.role,
                    content: safeContent,
                    timestamp: message.timestamp,
                    channel: message.channel,
                    metadata: message.metadata,
                )
            }
        let responseMessageStartIndex = currentMessages.count
        finalResponseStartIndex = responseMessageStartIndex
        let responseHistoryMessages = model.responseHistoryMessages(
            nativeMessages: historyAssistantMessages,
            text: responseText,
            reasoning: responseReasoning,
            toolCalls: canExecuteToolCalls ? responseToolCalls : [],
            provider: provider,
            configuration: resolvedConfiguration,
        )

        // Track billable usage with proper session management.
        if response.isBillable, let usage = response.usage {
            let actualSessionId = sessionId ?? "generation-\(UUID().uuidString)"

            // Start session if not already started
            if sessionId == nil {
                _ = UsageTracker.shared.startSession(actualSessionId)
            }

            let operationType: OperationType = tools?.isEmpty == false ? .toolCall : .textGeneration
            UsageTracker.shared.recordUsage(
                sessionId: actualSessionId,
                model: model,
                usage: usage,
                operation: operationType,
            )

            // Only end session if we created it
            if sessionId == nil {
                _ = UsageTracker.shared.endSession(actualSessionId)
            }
        }

        // Update total usage
        if let usage = response.usage {
            totalUsage = Usage(
                inputTokens: totalUsage.inputTokens + usage.inputTokens,
                outputTokens: totalUsage.outputTokens + usage.outputTokens,
                cost: usage.cost, // Could combine costs here
            )
        }

        // Create step record
        let step = GenerationStep(
            stepIndex: stepIndex,
            text: responseText,
            toolCalls: responseToolCalls,
            toolResults: [],
            usage: response.usage,
            finishReason: response.finishReason,
        )

        allSteps.append(step)

        if isContentFiltered {
            break
        }

        if !responseHistoryMessages.isEmpty {
            currentMessages.append(contentsOf: responseHistoryMessages)
            if responseHistoryMessages.allSatisfy({ $0.channel == .thinking }) {
                currentMessages.append(ModelMessage(
                    role: .assistant,
                    content: [.text("")],
                    metadata: .init(customData: ["tachikoma.internal.boundary": "reasoning_only"]),
                ))
            }
        }

        if !responseToolCalls.isEmpty, canExecuteToolCalls {
            // Execute tools
            var toolResults: [AgentToolResult] = []
            for toolCall in responseToolCalls {
                if let tool = tools?.first(where: { $0.name == toolCall.name }) {
                    let toolResult: AgentToolResult
                    do {
                        // Debug: Log tool call details in verbose mode
                        if
                            ProcessInfo.processInfo.arguments.contains("--verbose") ||
                            ProcessInfo.processInfo.arguments.contains("-v")
                        {
                            print(
                                "DEBUG Generation.swift: Executing tool '\(toolCall.name)' with \(toolCall.arguments.count) arguments:",
                            )
                            for (key, value) in toolCall.arguments {
                                print("DEBUG   \(key): \(value)")
                            }
                        }

                        // Create execution context with full conversation and model info
                        let context = ToolExecutionContext(
                            messages: currentMessages.sanitizedForToolContext(),
                            model: model,
                            settings: settings,
                            sessionId: sessionId ?? "generation-\(UUID().uuidString)",
                            stepIndex: stepIndex,
                            metadata: ["toolCallId": toolCall.id],
                        )

                        // Convert arguments to AgentToolArguments
                        let toolArguments = AgentToolArguments(toolCall.arguments)
                        let result = try await tool.execute(toolArguments, context: context)
                        toolResult = AgentToolResult.success(toolCallId: toolCall.id, result: result)
                    } catch let failure as AgentToolExecutionFailure {
                        toolResult = AgentToolResult.error(
                            toolCallId: toolCall.id,
                            failure: failure,
                        )
                    } catch {
                        toolResult = AgentToolResult.error(
                            toolCallId: toolCall.id,
                            error: error.localizedDescription,
                        )
                    }
                    toolResults.append(toolResult)
                    currentMessages.append(ModelMessage(
                        role: .tool,
                        content: [.toolResult(toolResult)],
                    ))
                }
            }

            // Update step with tool results
            allSteps[stepIndex] = GenerationStep(
                stepIndex: stepIndex,
                text: responseText,
                toolCalls: responseToolCalls,
                toolResults: toolResults,
                usage: response.usage,
                finishReason: response.finishReason,
            )
        } else {
            // Providers can expose partial calls alongside length or error-like
            // terminal reasons. Preserve them for diagnostics without executing.
            break
        }
    }

    // Extract final text from last step
    var finalText = allSteps.last?.text ?? ""
    let originalFinalText = finalText
    var finalFinishReason = allSteps.last?.finishReason ?? .other

    // Apply stop conditions if configured
    if finalFinishReason != .contentFilter, let stopCondition = settings.stopConditions {
        // Check if we should stop and truncate the text
        if await stopCondition.shouldStop(text: finalText, delta: nil) {
            // Truncate text based on the type of stop condition
            if let stringStop = stopCondition as? StringStopCondition {
                // For string stop conditions, truncate at the stop string
                if
                    let range = finalText.range(
                        of: stringStop.stopString,
                        options: stringStop.caseSensitive ? [] : .caseInsensitive,
                    )
                {
                    finalText = String(finalText[..<range.lowerBound])
                }
                finalFinishReason = .stop
            } else if
                stopCondition is TokenCountStopCondition ||
                stopCondition is TimeoutStopCondition
            {
                // For token/time limits, the text is already at the right length
                finalFinishReason = .length
            } else if let regexStop = stopCondition as? RegexStopCondition {
                // For regex conditions, truncate at the first match
                if let matchRange = regexStop.matchLocation(in: finalText) {
                    finalText = String(finalText[..<matchRange.lowerBound])
                }
                finalFinishReason = .stop
            } else {
                // For other conditions, just mark as stopped
                finalFinishReason = .stop
            }
        }
    }
    let finalMessages = finalText == originalFinalText
        ? currentMessages
        : currentMessages.replacingGeneratedAssistantText(after: finalResponseStartIndex, with: finalText)

    return GenerateTextResult(
        text: finalText,
        usage: totalUsage,
        finishReason: finalFinishReason,
        steps: allSteps,
        messages: finalMessages,
    )
}

/// Stream text generation following the Vercel AI SDK streamText pattern
///
/// Provides real-time streaming of AI responses with support for tool calling
/// and multi-step execution within the stream.
///
/// - Parameters:
///   - model: The language model to use
///   - messages: Array of conversation messages
///   - tools: Optional tools the model can call
///   - settings: Generation settings (temperature, maxTokens, etc.)
///   - maxSteps: Maximum number of tool calling steps (default: 1)
/// - Returns: StreamTextResult with async sequence and metadata
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func streamText(
    model: LanguageModel,
    messages: [ModelMessage],
    tools: [AgentTool]? = nil,
    settings: GenerationSettings = .default,
    maxSteps: Int = 1,
    timeout: TimeInterval? = nil,
    configuration: TachikomaConfiguration = .current,
    sessionId: String? = nil,
) async throws
    -> StreamTextResult
{
    guard model.supportsStreaming else {
        throw TachikomaError.invalidConfiguration("\(model.modelId) does not support streaming")
    }
    let resolvedConfiguration = TachikomaConfiguration.resolve(configuration)
    let provider = try resolvedConfiguration.makeProvider(for: model)
    return try await streamText(
        model: model,
        provider: provider,
        messages: messages,
        tools: tools,
        settings: settings,
        maxSteps: maxSteps,
        timeout: timeout,
        configuration: resolvedConfiguration,
        sessionId: sessionId,
    )
}

/// Stream text generation through an already-resolved provider.
///
/// Use this overload when the caller must pin one verified provider instance across
/// multiple turns while retaining the standard message sanitization and usage tracking.
///
/// - Parameters:
///   - model: The language model represented by the supplied provider
///   - provider: The exact provider instance to use without rebuilding it from configuration
///   - messages: Array of conversation messages
///   - tools: Optional tools the model can call
///   - settings: Generation settings (temperature, maxTokens, etc.)
///   - maxSteps: Maximum number of tool calling steps (default: 1)
/// - Returns: StreamTextResult with async sequence and metadata
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func streamText(
    model: LanguageModel,
    provider: any ModelProvider,
    messages: [ModelMessage],
    tools: [AgentTool]? = nil,
    settings: GenerationSettings = .default,
    maxSteps _: Int = 1,
    timeout: TimeInterval? = nil,
    configuration: TachikomaConfiguration = .current,
    sessionId: String? = nil,
) async throws
    -> StreamTextResult
{
    // Debug logging only when explicitly enabled via environment variable or verbose flag
    let resolvedConfiguration = TachikomaConfiguration.resolve(configuration)
    guard model.supportsStreaming else {
        throw TachikomaError.invalidConfiguration("\(model.modelId) does not support streaming")
    }
    let debugEnabled = ProcessInfo.processInfo.environment["DEBUG_TACHIKOMA"] != nil ||
        resolvedConfiguration.verbose
    if debugEnabled {
        print("\n🔵 DEBUG streamText: Using provider for model: \(model)")
        print("🔵 DEBUG streamText: Model details: \(model.description)")
        if case let .openai(openaiModel) = model {
            print("🔵 DEBUG streamText: OpenAI model enum case: \(openaiModel)")
            print("🔵 DEBUG streamText: OpenAI model modelId: \(openaiModel.modelId)")
        }
    }
    if debugEnabled {
        print("🔵 DEBUG streamText: Provider created: \(type(of: provider))")
        print("🔵 DEBUG streamText: Provider modelId: \(model.modelId)")
    }

    let request = ProviderRequest(
        messages: messages.sanitizedForProvider(
            model,
            provider: provider,
            configuration: resolvedConfiguration,
        ),
        tools: tools,
        settings: settings,
    )

    var stream: AsyncThrowingStream<TextStreamDelta, Error>
    if let timeout {
        // Wrap stream with timeout for initial connection
        if debugEnabled {
            print("🔵 DEBUG streamText: Calling provider.streamText with timeout and \(request.tools?.count ?? 0) tools")
        }
        stream = try await withTimeout(timeout) {
            try await provider.streamText(request: request)
        }
    } else {
        if debugEnabled {
            print("🔵 DEBUG streamText: Calling provider.streamText with \(request.tools?.count ?? 0) tools")
        }
        stream = try await provider.streamText(request: request)
    }

    // Use provided session or create a new one for tracking streaming usage
    let actualSessionId = sessionId ?? "streaming-\(UUID().uuidString)"
    if sessionId == nil {
        _ = UsageTracker.shared.startSession(actualSessionId)
    }

    // Wrap the stream to track usage when it completes
    let capturedModel = model
    let capturedSessionId = actualSessionId
    let shouldEndSession = sessionId == nil
    let buffersUntilDone = model.buffersTextStreamUntilDone(settings: settings)
    if !buffersUntilDone, let stopCondition = settings.stopConditions {
        stream = stream.stopWhen(stopCondition)
    }
    let capturedStream = stream
    let capturedStopCondition = buffersUntilDone ? settings.stopConditions : nil

    let trackedStream = AsyncThrowingStream<TextStreamDelta, Error> { continuation in
        let forwardingTask = Task {
            defer {
                if shouldEndSession {
                    _ = UsageTracker.shared.endSession(capturedSessionId)
                }
            }

            do {
                let totalInputTokens = 0
                var totalOutputTokens = 0
                var bufferedDeltas: [TextStreamDelta] = []
                var bufferedVisibleText = ""
                var didReceiveTerminal = false
                var didTriggerLocalStop = false

                func track(_ delta: TextStreamDelta) {
                    // Track tokens as they come in (approximate)
                    if case .textDelta = delta.type, let content = delta.content {
                        // Rough approximation: ~4 characters per token
                        totalOutputTokens += max(1, content.count / 4)
                    }
                }

                func yieldAndTrack(_ delta: TextStreamDelta) {
                    track(delta)
                    continuation.yield(delta)
                }

                if let capturedStopCondition {
                    await capturedStopCondition.reset()
                }

                for try await delta in capturedStream {
                    if buffersUntilDone, delta.type != .done {
                        if !didTriggerLocalStop {
                            bufferedDeltas.append(delta)
                            track(delta)
                            if
                                let capturedStopCondition,
                                case .textDelta = delta.type,
                                let content = delta.content
                            {
                                bufferedVisibleText += content
                                didTriggerLocalStop = await capturedStopCondition.shouldStop(
                                    text: bufferedVisibleText,
                                    delta: content,
                                )
                            }
                        }
                        continue
                    }

                    if case .done = delta.type {
                        didReceiveTerminal = true
                        if buffersUntilDone {
                            if delta.finishReason == .contentFilter {
                                bufferedDeltas.removeAll()
                                yieldAndTrack(delta)
                            } else {
                                for bufferedDelta in bufferedDeltas {
                                    continuation.yield(bufferedDelta)
                                }
                                bufferedDeltas.removeAll()
                                if didTriggerLocalStop {
                                    yieldAndTrack(TextStreamDelta.done(usage: delta.usage, finishReason: .stop))
                                } else {
                                    yieldAndTrack(delta)
                                }
                            }
                        } else {
                            yieldAndTrack(delta)
                        }
                    } else {
                        yieldAndTrack(delta)
                    }

                    if case .done = delta.type {
                        // Record final usage (this is approximate for streaming)
                        let usage = Usage(
                            inputTokens: totalInputTokens,
                            outputTokens: totalOutputTokens,
                        )

                        UsageTracker.shared.recordUsage(
                            sessionId: capturedSessionId,
                            model: capturedModel,
                            usage: usage,
                            operation: .textStreaming,
                        )
                    }
                }

                if buffersUntilDone, !didReceiveTerminal {
                    throw TachikomaError.apiError("Stream ended before provider completion status was received")
                }

                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in forwardingTask.cancel() }
    }

    return StreamTextResult(
        stream: trackedStream,
        model: model,
        settings: settings,
    )
}

/// Generate structured objects using AI following the generateObject pattern
///
/// This function constrains the AI output to a specific schema, ensuring type-safe
/// structured data generation.
///
/// - Parameters:
///   - model: The language model to use
///   - messages: Array of conversation messages
///   - schema: The expected output schema (Codable type)
///   - settings: Generation settings
/// - Returns: GenerateObjectResult with parsed object
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@discardableResult
public func generateObject<T: Codable & Sendable>(
    model: LanguageModel,
    messages: [ModelMessage],
    schema _: T.Type,
    settings: GenerationSettings = .default,
    timeout: TimeInterval? = nil,
    configuration: TachikomaConfiguration = .current,
) async throws
    -> GenerateObjectResult<T>
{
    let resolvedConfiguration = TachikomaConfiguration.resolve(configuration)
    let provider = try resolvedConfiguration.makeProvider(for: model)

    let request = ProviderRequest(
        messages: messages.sanitizedForProvider(
            model,
            provider: provider,
            configuration: resolvedConfiguration,
        ),
        tools: nil,
        settings: settings,
        outputFormat: .json,
    )

    let response: ProviderResponse = if let timeout {
        try await withTimeout(timeout) {
            try await provider.generateText(request: request)
        }
    } else {
        try await provider.generateText(request: request)
    }

    if response.finishReason == .contentFilter {
        throw TachikomaError.apiError("Response was blocked by the provider content filter")
    }

    // Parse the JSON response into the expected type
    guard let jsonData = response.text.data(using: .utf8) else {
        throw TachikomaError.invalidInput("Response text is not valid UTF-8")
    }

    do {
        let object = try JSONDecoder().decode(T.self, from: jsonData)
        return GenerateObjectResult(
            object: object,
            usage: response.usage,
            finishReason: response.finishReason ?? .other,
        )
    } catch {
        throw TachikomaError.invalidInput("Failed to parse response as \(T.self): \(error.localizedDescription)")
    }
}

/// Stream structured objects using AI following the streamObject pattern
///
/// This function streams partial object updates as the AI generates structured data,
/// allowing for real-time UI updates and progressive rendering.
///
/// - Parameters:
///   - model: The language model to use
///   - messages: Array of conversation messages
///   - schema: The expected output schema (Codable type)
///   - settings: Generation settings
///   - configuration: Tachikoma configuration
/// - Returns: StreamObjectResult with partial object stream
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func streamObject<T: Codable & Sendable>(
    model: LanguageModel,
    messages: [ModelMessage],
    schema: T.Type,
    settings: GenerationSettings = .default,
    configuration: TachikomaConfiguration = .current,
) async throws
    -> StreamObjectResult<T>
{
    let resolvedConfiguration = TachikomaConfiguration.resolve(configuration)
    guard model.supportsStreaming else {
        throw TachikomaError.invalidConfiguration("\(model.modelId) does not support streaming")
    }
    let provider = try resolvedConfiguration.makeProvider(for: model)

    // Create request with JSON output format
    let request = ProviderRequest(
        messages: messages.sanitizedForProvider(
            model,
            provider: provider,
            configuration: resolvedConfiguration,
        ),
        tools: nil,
        settings: settings,
        outputFormat: .json,
    )

    // Get the text stream from the provider
    let stream = try await provider.streamText(request: request)
    let buffersUntilDone = model.buffersObjectStreamUntilDone(settings: settings)

    // Create a new stream that attempts to parse partial JSON objects
    let objectStream = AsyncThrowingStream<ObjectStreamDelta<T>, Error> { continuation in
        let producer = Task {
            do {
                var accumulatedText = ""
                var lastValidObject: T?
                var hasStarted = false
                var bufferedStartDelta: ObjectStreamDelta<T>?
                var didFinishObject = false

                func publishCompleteObject(allowLastValidObjectFallback: Bool) throws {
                    if buffersUntilDone, let bufferedStartDelta {
                        continuation.yield(bufferedStartDelta)
                    }
                    if
                        let jsonData = accumulatedText.data(using: .utf8),
                        let finalObject = try? JSONDecoder().decode(T.self, from: jsonData)
                    {
                        continuation.yield(ObjectStreamDelta(
                            type: .complete,
                            object: finalObject,
                            rawText: accumulatedText,
                        ))
                    } else if allowLastValidObjectFallback, let lastValidObject {
                        // If we have a last valid object, use it as complete
                        continuation.yield(ObjectStreamDelta(
                            type: .complete,
                            object: lastValidObject,
                            rawText: accumulatedText,
                        ))
                    } else {
                        throw TachikomaError.invalidInput(
                            "Failed to parse complete object from stream",
                        )
                    }
                    continuation.yield(ObjectStreamDelta(type: .done))
                    didFinishObject = true
                }

                for try await delta in stream {
                    try Task.checkCancellation()
                    if case .textDelta = delta.type, let content = delta.content {
                        accumulatedText += content

                        // Signal stream start
                        if !hasStarted {
                            hasStarted = true
                            let startDelta = ObjectStreamDelta<T>(type: .start)
                            if buffersUntilDone {
                                bufferedStartDelta = startDelta
                            } else {
                                continuation.yield(startDelta)
                            }
                        }

                        if buffersUntilDone {
                            continue
                        }

                        // Attempt to parse the accumulated JSON
                        if let jsonData = accumulatedText.data(using: .utf8) {
                            // Try to parse as complete object
                            if let object = try? JSONDecoder().decode(T.self, from: jsonData) {
                                lastValidObject = object
                                let objectDelta = ObjectStreamDelta(
                                    type: .partial,
                                    object: object,
                                    rawText: accumulatedText,
                                )
                                continuation.yield(objectDelta)
                            } else if let partialObject = attemptPartialParse(T.self, from: accumulatedText) {
                                // Attempt to parse as partial object
                                lastValidObject = partialObject
                                let objectDelta = ObjectStreamDelta(
                                    type: .partial,
                                    object: partialObject,
                                    rawText: accumulatedText,
                                )
                                continuation.yield(objectDelta)
                            }
                        }
                    } else if case .done = delta.type {
                        if delta.finishReason == .contentFilter {
                            throw TachikomaError.apiError("Response was blocked by the provider content filter")
                        }
                        try publishCompleteObject(allowLastValidObjectFallback: delta.finishReason == .stop || delta
                            .finishReason == nil)
                    }
                }

                if !didFinishObject, hasStarted {
                    if buffersUntilDone {
                        throw TachikomaError.apiError("Stream ended before provider completion status was received")
                    } else if
                        let jsonData = accumulatedText.data(using: .utf8),
                        let finalObject = try? JSONDecoder().decode(T.self, from: jsonData)
                    {
                        continuation.yield(ObjectStreamDelta(
                            type: .complete,
                            object: finalObject,
                            rawText: accumulatedText,
                        ))
                        continuation.yield(ObjectStreamDelta(type: .done))
                    } else if let lastValidObject {
                        continuation.yield(ObjectStreamDelta(
                            type: .complete,
                            object: lastValidObject,
                            rawText: accumulatedText,
                        ))
                        continuation.yield(ObjectStreamDelta(type: .done))
                    }
                }

                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
    }

    return StreamObjectResult(
        objectStream: objectStream,
        model: model,
        settings: settings,
        schema: schema,
    )
}

/// Attempt to parse a partial JSON object by fixing common issues
private func attemptPartialParse<T: Codable>(_: T.Type, from json: String) -> T? {
    // Try various strategies to parse partial JSON
    let strategies = [
        json, // Original
        json + "}", // Missing closing brace
        json + "\"}", // Missing quote and brace
        json + "]", // Missing closing bracket
        json + "]}", // Missing bracket and brace
        fixPartialJSON(json), // Custom fix attempt
    ]

    for strategy in strategies {
        if
            let data = strategy.data(using: .utf8),
            let object = try? JSONDecoder().decode(T.self, from: data)
        {
            return object
        }
    }

    return nil
}

/// Fix common issues in partial JSON
private func fixPartialJSON(_ json: String) -> String {
    // Fix common issues in partial JSON
    var fixed = json.trimmingCharacters(in: .whitespacesAndNewlines)

    // Count brackets and braces
    let openBraces = fixed.count { $0 == "{" }
    let closeBraces = fixed.count { $0 == "}" }
    let openBrackets = fixed.count { $0 == "[" }
    let closeBrackets = fixed.count { $0 == "]" }

    // Add missing closing characters
    if openBrackets > closeBrackets {
        fixed += String(repeating: "]", count: openBrackets - closeBrackets)
    }
    if openBraces > closeBraces {
        fixed += String(repeating: "}", count: openBraces - closeBraces)
    }

    // Fix trailing comma
    if fixed.hasSuffix(",") {
        fixed.removeLast()
    }

    // Ensure quotes are balanced for the last property
    if let lastQuoteIndex = fixed.lastIndex(of: "\"") {
        let afterQuote = String(fixed[fixed.index(after: lastQuoteIndex)...])
        if afterQuote.contains(":"), !afterQuote.contains("\"") {
            // Likely missing closing quote for string value
            fixed += "\""
        }
    }

    return fixed
}

extension LanguageModel {
    fileprivate func buffersTextStreamUntilDone(settings: GenerationSettings) -> Bool {
        self.hasAnthropicStreamingRefusalRisk ||
            settings.streamBuffering == .untilTerminal ||
            (settings.stopConditions != nil && self.canEmitTerminalContentFilterAfterText)
    }

    fileprivate func buffersObjectStreamUntilDone(settings: GenerationSettings) -> Bool {
        settings.streamBuffering == .untilTerminal ||
            self.hasAnthropicStreamingRefusalRisk
    }

    private var hasAnthropicStreamingRefusalRisk: Bool {
        switch self {
        case let .anthropic(model):
            return LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: model.modelId)
        case let .anthropicCompatible(modelId, _):
            return LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: modelId)
        case let .openRouter(modelId), let .together(modelId):
            return LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: modelId)
        case let .openaiCompatible(modelId, _):
            return LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: modelId)
        case let .custom(provider):
            if
                let parsed = ProviderParser.parse(provider.modelId),
                CustomProviderRegistry.shared.get(parsed.provider)?.kind == .anthropic
            {
                return LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: parsed.model)
            }
            return LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: provider.modelId)
        default:
            return false
        }
    }

    private var canEmitTerminalContentFilterAfterText: Bool {
        switch self {
        case .openai,
             .openaiCompatible,
             .openRouter,
             .together,
             .replicate,
             .google,
             .mistral,
             .groq,
             .grok,
             .kimi,
             .azureOpenAI:
            return true
        case let .custom(provider):
            guard
                let parsed = ProviderParser.parse(provider.modelId),
                let registeredProvider = CustomProviderRegistry.shared.get(parsed.provider) else
            {
                return false
            }
            switch registeredProvider.kind {
            case .openai:
                return true
            case .anthropic:
                return false
            }
        default:
            return false
        }
    }
}

private struct ReasoningReplayTarget {
    let provider: String
    let modelId: String
    let endpointIdentity: String?
    let allowsLegacyUnknown: Bool

    init(
        provider: String,
        modelId: String,
        baseURL: String?,
        allowsLegacyUnknown: Bool,
    ) {
        self.provider = provider
        self.modelId = modelId
        self.endpointIdentity = ReasoningEndpointIdentity.canonical(baseURL)
        self.allowsLegacyUnknown = allowsLegacyUnknown
    }

    init(
        provider: String,
        modelId: String,
        endpointIdentity: String?,
        allowsLegacyUnknown: Bool,
    ) {
        self.provider = provider
        self.modelId = modelId
        self.endpointIdentity = endpointIdentity
        self.allowsLegacyUnknown = allowsLegacyUnknown
    }

    func matches(_ customData: [String: String]) -> Bool {
        guard let endpointIdentity = self.endpointIdentity else { return false }
        guard customData["tachikoma.reasoning.provider"] == self.provider else {
            return false
        }
        guard customData["tachikoma.reasoning.model"] == self.modelId else {
            return false
        }
        return customData["tachikoma.reasoning.base_url"] == endpointIdentity
    }
}

extension [ModelMessage] {
    fileprivate func replacingGeneratedAssistantText(after prefixCount: Int, with text: String) -> [ModelMessage] {
        guard self.indices.contains(prefixCount) else {
            return self
        }

        var messages = self
        var cursor = text.startIndex
        for messageIndex in prefixCount..<messages.count {
            let message = messages[messageIndex]
            guard message.role == .assistant, message.channel != .thinking else {
                continue
            }

            var content: [ModelMessage.ContentPart] = []
            for part in message.content {
                guard case let .text(originalText) = part else {
                    content.append(part)
                    continue
                }

                guard cursor < text.endIndex else {
                    continue
                }

                let remainingCount = text.distance(from: cursor, to: text.endIndex)
                let takeCount = Swift.min(originalText.count, remainingCount)
                let endIndex = text.index(cursor, offsetBy: takeCount)
                content.append(.text(String(text[cursor..<endIndex])))
                cursor = endIndex
            }

            messages[messageIndex] = ModelMessage(
                id: message.id,
                role: message.role,
                content: content,
                timestamp: message.timestamp,
                channel: message.channel,
                metadata: message.metadata,
            )
        }
        return messages
    }
}

extension [ModelMessage] {
    fileprivate func sanitizedForProvider(
        _ model: LanguageModel,
        provider: any ModelProvider,
        configuration: TachikomaConfiguration,
    )
        -> [ModelMessage]
    {
        if let target = model.ollamaReasoningReplayTarget(provider: provider) {
            var sanitized: [ModelMessage] = []
            for message in self {
                if message.isSyntheticReasoningBoundary {
                    if sanitized.last?.channel == .thinking {
                        sanitized.append(message)
                    }
                    continue
                }
                guard message.channel == .thinking else {
                    sanitized.append(message)
                    continue
                }
                guard message.hasOllamaThinkingReplayMetadata else {
                    continue
                }
                if target.matches(message.metadata?.customData ?? [:]) {
                    sanitized.append(message)
                }
            }
            return sanitized
        }

        if let target = model.anthropicThinkingReplayTarget(configuration: configuration) {
            var sanitized: [ModelMessage] = []
            for message in self {
                if message.isSyntheticReasoningBoundary {
                    if sanitized.last?.channel == .thinking {
                        sanitized.append(message)
                    }
                    continue
                }
                guard message.channel == .thinking else {
                    sanitized.append(message)
                    continue
                }
                guard !message.hasOpenRouterReasoningReplayMetadata else {
                    continue
                }
                guard let producerModel = message.metadata?.customData?["anthropic.thinking.model"] else {
                    if
                        target.allowsLegacyUnknown,
                        message.metadata?.customData?["anthropic.thinking.type"] != nil
                    {
                        sanitized.append(message)
                    }
                    continue
                }
                let customData = message.metadata?.customData ?? [:]
                if producerModel == target.modelId, target.matches(customData) {
                    sanitized.append(message)
                }
            }
            return sanitized
        }

        if let target = model.openRouterReasoningReplayTarget(configuration: configuration) {
            var sanitized: [ModelMessage] = []
            for message in self {
                if message.isSyntheticReasoningBoundary {
                    if sanitized.last?.channel == .thinking {
                        sanitized.append(message)
                    }
                    continue
                }
                guard message.channel == .thinking else {
                    sanitized.append(message)
                    continue
                }
                guard message.hasOpenRouterReasoningReplayMetadata else {
                    continue
                }
                if target.matches(message.metadata?.customData ?? [:]) {
                    sanitized.append(message)
                }
            }
            return sanitized
        }

        if let target = model.kimiReasoningReplayTarget(configuration: configuration) {
            var sanitized: [ModelMessage] = []
            for message in self {
                if message.isSyntheticReasoningBoundary {
                    if sanitized.last?.channel == .thinking {
                        sanitized.append(message)
                    }
                    continue
                }
                guard message.channel == .thinking else {
                    sanitized.append(message)
                    continue
                }
                guard message.hasKimiReasoningReplayMetadata else {
                    continue
                }
                if target.matches(message.metadata?.customData ?? [:]) {
                    sanitized.append(message)
                }
            }
            return sanitized
        }

        return self.filter { !$0.isSyntheticReasoningBoundary && $0.channel != .thinking }
    }
}

extension ModelMessage {
    private var hasAnthropicThinkingReplayMetadata: Bool {
        guard let customData = metadata?.customData else { return false }
        return customData["anthropic.thinking.model"] != nil ||
            customData["anthropic.thinking.type"] != nil ||
            customData["anthropic.thinking.signature"] != nil
    }

    fileprivate var hasOpenRouterReasoningReplayMetadata: Bool {
        guard let customData = metadata?.customData else { return false }
        return customData["openrouter.reasoning_details"] != nil ||
            customData["openrouter.reasoning"] != nil
    }

    fileprivate var hasKimiReasoningReplayMetadata: Bool {
        self.metadata?.customData?["kimi.reasoning_content"] != nil
    }

    fileprivate var hasOllamaThinkingReplayMetadata: Bool {
        self.metadata?.customData?["ollama.thinking"] != nil
    }

    private var hasProviderReasoningReplayMetadata: Bool {
        self.hasAnthropicThinkingReplayMetadata || self.hasOpenRouterReasoningReplayMetadata ||
            self.hasKimiReasoningReplayMetadata || self.hasOllamaThinkingReplayMetadata
    }

    fileprivate var isSyntheticReasoningBoundary: Bool {
        metadata?.customData?["tachikoma.internal.boundary"] == "reasoning_only"
    }
}

extension [ModelMessage] {
    fileprivate func sanitizedForToolContext() -> [ModelMessage] {
        self.filter { $0.channel != .thinking && !$0.isSyntheticReasoningBoundary }
    }

    fileprivate func containsAssistantText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let assistantTexts = self.flatMap { message -> [String] in
            guard message.role == .assistant, message.channel != .thinking else {
                return []
            }
            return message.content.compactMap { part in
                if case let .text(value) = part {
                    return value
                }
                return nil
            }
        }
        return assistantTexts.contains(text) || assistantTexts.joined() == text
    }

    fileprivate func containsReasoningBlock(_ reasoning: ProviderReasoningBlock) -> Bool {
        self.contains { message in
            message.role == .assistant && message.channel == .thinking && message.content.contains { part in
                guard case let .text(value) = part else { return false }
                if let signature = reasoning.signature, !signature.isEmpty {
                    return message.metadata?.customData?["anthropic.thinking.signature"] == signature ||
                        message.metadata?.customData?["tachikoma.reasoning.signature"] == signature
                }
                return value == reasoning.text
            }
        }
    }

    fileprivate func containsToolCall(id: String) -> Bool {
        self.contains { message in
            message.role == .assistant && message.content.contains { part in
                if case let .toolCall(toolCall) = part {
                    return toolCall.id == id
                }
                return false
            }
        }
    }
}

extension LanguageModel {
    fileprivate func responseHistoryMessages(
        nativeMessages: [ModelMessage],
        text: String,
        reasoning: [ProviderReasoningBlock],
        toolCalls: [AgentToolCall],
        provider: any ModelProvider,
        configuration: TachikomaConfiguration,
    )
        -> [ModelMessage]
    {
        var history = nativeMessages

        for reasoningBlock in reasoning where !history.containsReasoningBlock(reasoningBlock) {
            history.append(ModelMessage(
                role: .assistant,
                content: [.text(reasoningBlock.text)],
                channel: .thinking,
                metadata: .init(customData: self.anthropicThinkingMetadata(
                    for: reasoningBlock,
                    provider: provider,
                    configuration: configuration,
                )),
            ))
        }

        let missingToolCalls = toolCalls.filter { !history.containsToolCall(id: $0.id) }
        let isMissingText = !history.containsAssistantText(text)
        let needsFallbackBoundary = nativeMessages.isEmpty && text.isEmpty && missingToolCalls.isEmpty

        guard isMissingText || !missingToolCalls.isEmpty || needsFallbackBoundary else {
            return history
        }

        var fallbackContent: [ModelMessage.ContentPart] = []
        if isMissingText || needsFallbackBoundary {
            fallbackContent.append(.text(text))
        }
        fallbackContent.append(contentsOf: missingToolCalls.map { .toolCall($0) })
        let fallbackMetadata = needsFallbackBoundary
            ? MessageMetadata(customData: ["tachikoma.internal.boundary": "reasoning_only"])
            : nil
        history.append(ModelMessage(role: .assistant, content: fallbackContent, metadata: fallbackMetadata))
        return history
    }

    fileprivate func anthropicThinkingReplayTarget(configuration: TachikomaConfiguration) -> ReasoningReplayTarget? {
        switch self {
        case let .anthropic(model):
            return ReasoningReplayTarget(
                provider: "anthropic",
                modelId: model.modelId,
                baseURL: configuration.getBaseURL(for: .anthropic) ?? Provider.anthropic.defaultBaseURL,
                allowsLegacyUnknown: !LanguageModel.Anthropic.hasDefaultAdaptiveThinking(modelId: model.modelId),
            )
        case let .anthropicCompatible(modelId, baseURL):
            return ReasoningReplayTarget(
                provider: "anthropic-compatible",
                modelId: modelId,
                baseURL: baseURL,
                allowsLegacyUnknown: !LanguageModel.Anthropic.hasDefaultAdaptiveThinking(modelId: modelId),
            )
        case let .minimax(model):
            return ReasoningReplayTarget(
                provider: "minimax",
                modelId: model.modelId,
                baseURL: configuration.getBaseURL(for: .minimax) ?? Provider.minimax.defaultBaseURL,
                allowsLegacyUnknown: true,
            )
        case let .minimaxCN(model):
            return ReasoningReplayTarget(
                provider: "minimax-cn",
                modelId: model.modelId,
                baseURL: configuration.getBaseURL(for: .minimaxCN) ?? Provider.minimaxCN.defaultBaseURL,
                allowsLegacyUnknown: true,
            )
        case let .custom(provider):
            if let directAnthropicProvider = provider as? AnthropicProvider {
                return ReasoningReplayTarget(
                    provider: "anthropic",
                    modelId: directAnthropicProvider.modelId,
                    baseURL: directAnthropicProvider.baseURL ?? Provider.anthropic.defaultBaseURL,
                    allowsLegacyUnknown: !LanguageModel.Anthropic
                        .hasDefaultAdaptiveThinking(modelId: directAnthropicProvider.modelId),
                )
            }
            if let compatibleProvider = provider as? AnthropicCompatibleProvider {
                return ReasoningReplayTarget(
                    provider: "anthropic-compatible",
                    modelId: compatibleProvider.modelId,
                    baseURL: compatibleProvider.baseURL,
                    allowsLegacyUnknown: !LanguageModel.Anthropic
                        .hasDefaultAdaptiveThinking(modelId: compatibleProvider.modelId),
                )
            }
            guard
                let parsed = ProviderParser.parse(provider.modelId),
                let registeredProvider = CustomProviderRegistry.shared.get(parsed.provider),
                registeredProvider.kind == .anthropic else
            {
                return provider.modelId.contains("claude") || provider.modelId.contains("anthropic")
                    ? ReasoningReplayTarget(
                        provider: "custom-anthropic",
                        modelId: provider.modelId,
                        baseURL: provider.baseURL,
                        allowsLegacyUnknown: !LanguageModel.Anthropic
                            .hasDefaultAdaptiveThinking(modelId: provider.modelId),
                    )
                    : nil
            }
            return ReasoningReplayTarget(
                provider: "custom-anthropic",
                modelId: parsed.model,
                baseURL: registeredProvider.baseURL,
                allowsLegacyUnknown: !LanguageModel.Anthropic.hasDefaultAdaptiveThinking(modelId: parsed.model),
            )
        default:
            return nil
        }
    }

    fileprivate func openRouterReasoningReplayTarget(configuration: TachikomaConfiguration) -> ReasoningReplayTarget? {
        switch self {
        case let .openRouter(modelId):
            ReasoningReplayTarget(
                provider: "openrouter",
                modelId: modelId,
                baseURL: configuration.getBaseURL(for: .custom("openrouter")) ?? "https://openrouter.ai/api/v1",
                allowsLegacyUnknown: false,
            )
        default:
            nil
        }
    }

    fileprivate func kimiReasoningReplayTarget(configuration: TachikomaConfiguration) -> ReasoningReplayTarget? {
        switch self {
        case let .kimi(model):
            ReasoningReplayTarget(
                provider: "kimi",
                modelId: model.modelId,
                baseURL: configuration.getBaseURL(for: .kimi) ?? Provider.kimi.defaultBaseURL,
                allowsLegacyUnknown: false,
            )
        default:
            nil
        }
    }

    fileprivate func ollamaReasoningReplayTarget(provider: any ModelProvider) -> ReasoningReplayTarget? {
        switch self {
        case .ollama:
            guard
                let ollamaProvider = provider as? OllamaProvider,
                let endpointIdentity = ollamaProvider.reasoningReplayIdentity else
            {
                return nil
            }
            return ReasoningReplayTarget(
                provider: "ollama",
                modelId: provider.modelId,
                endpointIdentity: endpointIdentity,
                allowsLegacyUnknown: false,
            )
        default:
            return nil
        }
    }

    private func anthropicThinkingMetadata(
        for reasoning: ProviderReasoningBlock,
        provider: any ModelProvider,
        configuration: TachikomaConfiguration,
    )
        -> [String: String]
    {
        if
            reasoning.type == "ollama_thinking",
            let target = self.ollamaReasoningReplayTarget(provider: provider)
        {
            var metadata = [
                "ollama.thinking": reasoning.text,
                "tachikoma.reasoning.type": reasoning.type,
                "tachikoma.reasoning.provider": target.provider,
                "tachikoma.reasoning.model": target.modelId,
            ]
            if let endpointIdentity = target.endpointIdentity {
                metadata["tachikoma.reasoning.base_url"] = endpointIdentity
            }
            return metadata
        }
        if
            reasoning.type == "kimi_reasoning_content",
            let target = self.kimiReasoningReplayTarget(configuration: configuration)
        {
            var metadata = [
                "kimi.reasoning_content": reasoning.text,
                "tachikoma.reasoning.type": reasoning.type,
                "tachikoma.reasoning.provider": target.provider,
                "tachikoma.reasoning.model": target.modelId,
            ]
            if let endpointIdentity = target.endpointIdentity {
                metadata["tachikoma.reasoning.base_url"] = endpointIdentity
            }
            return metadata
        }
        if
            let rawJSON = reasoning.rawJSON,
            let target = self.openRouterReasoningReplayTarget(configuration: configuration)
        {
            var metadata = [
                "openrouter.reasoning_details": rawJSON,
                "tachikoma.reasoning.type": reasoning.type,
                "tachikoma.reasoning.provider": target.provider,
                "tachikoma.reasoning.model": target.modelId,
            ]
            if let endpointIdentity = target.endpointIdentity {
                metadata["tachikoma.reasoning.base_url"] = endpointIdentity
            }
            return metadata
        }
        if
            reasoning.type == "openrouter_reasoning",
            let target = self.openRouterReasoningReplayTarget(configuration: configuration)
        {
            var metadata = [
                "openrouter.reasoning": reasoning.text,
                "tachikoma.reasoning.type": reasoning.type,
                "tachikoma.reasoning.provider": target.provider,
                "tachikoma.reasoning.model": target.modelId,
            ]
            if let endpointIdentity = target.endpointIdentity {
                metadata["tachikoma.reasoning.base_url"] = endpointIdentity
            }
            return metadata
        }

        guard let target = self.anthropicThinkingReplayTarget(configuration: configuration) else {
            var customData = ["tachikoma.reasoning.type": reasoning.type]
            if let signature = reasoning.signature, !signature.isEmpty {
                customData["tachikoma.reasoning.signature"] = signature
            }
            return customData
        }

        var customData = [
            "anthropic.thinking.type": reasoning.type,
            "anthropic.thinking.model": target.modelId,
            "tachikoma.reasoning.provider": target.provider,
            "tachikoma.reasoning.model": target.modelId,
        ]
        if let endpointIdentity = target.endpointIdentity {
            customData["tachikoma.reasoning.base_url"] = endpointIdentity
        }
        if let signature = reasoning.signature, !signature.isEmpty {
            customData["anthropic.thinking.signature"] = signature
        }
        return customData
    }
}

// MARK: - Convenience Functions

/// Simple text generation from a prompt (convenience wrapper) - with Model enum
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@discardableResult
public func generate(
    _ prompt: String,
    using _: Model? = nil,
    system _: String? = nil,
    tools _: [AgentTool]? = nil,
    timeout _: TimeInterval? = nil,
) async throws
    -> String
{
    // For now, just return a mock response since we don't have provider implementations
    "Mock response for prompt: \(prompt)"
}

/// Simple text generation from a prompt (convenience wrapper) - with LanguageModel enum
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@discardableResult
public func generate(
    _ prompt: String,
    using model: LanguageModel = .default,
    system: String? = nil,
    maxTokens: Int? = nil,
    temperature: Double? = nil,
    timeout: TimeInterval? = nil,
    configuration: TachikomaConfiguration = .current,
) async throws
    -> String
{
    var messages: [ModelMessage] = []

    if let system {
        messages.append(.system(system))
    }

    messages.append(.user(prompt))

    let settings = GenerationSettings(
        maxTokens: maxTokens,
        temperature: temperature,
    )

    let result = try await generateText(
        model: model,
        messages: messages,
        settings: settings,
        timeout: timeout,
        configuration: configuration,
    )

    return result.text
}

/// Analyze an image using an AI model
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func analyze(
    image: ImageInput,
    prompt: String,
    using model: Model? = nil,
    configuration: TachikomaConfiguration = .current,
) async throws
    -> String
{
    // Determine the model to use
    let selectedModel: LanguageModel = if let model {
        model
    } else {
        // Use a vision-capable model by default
        .openai(.gpt55)
    }

    // Ensure the model supports vision
    guard selectedModel.supportsVision else {
        throw TachikomaError.unsupportedOperation("Model \(selectedModel.description) does not support vision")
    }

    // Convert ImageInput to base64 string
    let base64Data: String
    let mimeType: String

    switch image {
    case let .base64(data):
        base64Data = data
        mimeType = "image/png" // Default assumption
    case .url:
        throw TachikomaError.unsupportedOperation("URL-based images not yet supported")
    case let .filePath(path):
        let url = URL(fileURLWithPath: path)
        let imageData = try Data(contentsOf: url)
        base64Data = imageData.base64EncodedString()

        // Determine MIME type from file extension
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "png":
            mimeType = "image/png"
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "gif":
            mimeType = "image/gif"
        case "webp":
            mimeType = "image/webp"
        default:
            mimeType = "image/png" // Default fallback
        }
    }

    // Create image content
    let imageContent = ModelMessage.ContentPart.ImageContent(data: base64Data, mimeType: mimeType)

    // Create messages with both text and image
    let messages = [
        ModelMessage.user(text: prompt, images: [imageContent]),
    ]

    // Generate text using the multimodal capabilities
    let result = try await generateText(
        model: selectedModel,
        messages: messages,
        settings: .default,
        configuration: configuration,
    )

    // Additional tracking for image analysis (the generateText call above already tracks usage)
    // This could be enhanced to track image-specific metrics
    if let usage = result.usage {
        let sessionId = "image-analysis-\(UUID().uuidString)"
        _ = UsageTracker.shared.startSession(sessionId)
        UsageTracker.shared.recordUsage(
            sessionId: sessionId,
            model: selectedModel,
            usage: usage,
            operation: .imageAnalysis,
        )
        _ = UsageTracker.shared.endSession(sessionId)
    }

    return result.text
}

/// Simple streaming from a prompt (convenience wrapper)
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func stream(
    _ prompt: String,
    using model: LanguageModel = .defaultStreaming,
    system: String? = nil,
    maxTokens: Int? = nil,
    temperature: Double? = nil,
    configuration: TachikomaConfiguration = .current,
) async throws
    -> AsyncThrowingStream<TextStreamDelta, Error>
{
    var messages: [ModelMessage] = []

    if let system {
        messages.append(.system(system))
    }

    messages.append(.user(prompt))

    let settings = GenerationSettings(
        maxTokens: maxTokens,
        temperature: temperature,
    )

    let result = try await streamText(
        model: model,
        messages: messages,
        settings: settings,
        configuration: configuration,
    )

    return result.stream
}

// MARK: - Result Types

/// Result type for streaming object generation with partial updates
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct StreamObjectResult<T: Codable & Sendable>: Sendable {
    public let objectStream: AsyncThrowingStream<ObjectStreamDelta<T>, Error>
    public let model: LanguageModel
    public let settings: GenerationSettings
    public let schema: T.Type

    public init(
        objectStream: AsyncThrowingStream<ObjectStreamDelta<T>, Error>,
        model: LanguageModel,
        settings: GenerationSettings,
        schema: T.Type,
    ) {
        self.objectStream = objectStream
        self.model = model
        self.settings = settings
        self.schema = schema
    }
}

// MARK: - AsyncSequence Conformance for StreamObjectResult

extension StreamObjectResult: AsyncSequence {
    public typealias Element = ObjectStreamDelta<T>

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncThrowingStream<ObjectStreamDelta<T>, Error>.AsyncIterator

        public mutating func next() async throws -> ObjectStreamDelta<T>? {
            try await self.iterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: self.objectStream.makeAsyncIterator())
    }
}

/// A delta in streaming object generation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ObjectStreamDelta<T: Codable & Sendable>: Sendable {
    public let type: DeltaType
    public let object: T?
    public let rawText: String?
    public let error: Error?

    public enum DeltaType: Sendable, Equatable {
        case start // Stream has started
        case partial // Partial object update
        case complete // Complete object received
        case done // Stream has finished
        case error // An error occurred
    }

    public init(
        type: DeltaType,
        object: T? = nil,
        rawText: String? = nil,
        error: Error? = nil,
    ) {
        self.type = type
        self.object = object
        self.rawText = rawText
        self.error = error
    }
}
