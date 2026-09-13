import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class OllamaNDJSONStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var buffer = Data()
    private var errorBody = Data()
    private var responseStatusCode: Int?
    private var responseError: Error?
    private var isFinished = false

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            self.responseError = TachikomaError.networkError(
                NSError(domain: "Invalid response", code: 0),
            )
            dataTask.cancel()
            completionHandler(.cancel)
            return
        }

        self.responseStatusCode = httpResponse.statusCode
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !self.isFinished else { return }
        guard self.responseStatusCode == 200 else {
            self.errorBody.append(data)
            return
        }

        self.buffer.append(data)
        while let newlineIndex = self.buffer.firstIndex(of: 0x0A) {
            let lineData = self.buffer[..<newlineIndex]
            self.buffer.removeSubrange(self.buffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else {
                self.finish(
                    throwing: TachikomaError.apiError("Ollama Error: stream response was not valid UTF-8"),
                )
                dataTask.cancel()
                return
            }
            self.continuation.yield(line)
        }
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        guard !self.isFinished else { return }

        if let responseError {
            self.finish(throwing: responseError)
            return
        }
        if let responseStatusCode, responseStatusCode != 200 {
            let errorText = String(data: self.errorBody, encoding: .utf8) ?? "Unknown error"
            self.finish(
                throwing: TachikomaError.apiError(
                    "Ollama Error (HTTP \(responseStatusCode)): \(errorText)",
                ),
            )
            return
        }
        if let error {
            self.finish(throwing: error)
            return
        }
        guard self.responseStatusCode == 200 else {
            self.finish(
                throwing: TachikomaError.networkError(NSError(domain: "Invalid response", code: 0)),
            )
            return
        }

        if !self.buffer.isEmpty {
            guard let line = String(data: self.buffer, encoding: .utf8) else {
                self.finish(
                    throwing: TachikomaError.apiError("Ollama Error: stream response was not valid UTF-8"),
                )
                return
            }
            self.continuation.yield(line)
        }
        self.finish()
    }

    private func finish(throwing error: Error? = nil) {
        guard !self.isFinished else { return }
        self.isFinished = true
        if let error {
            self.continuation.finish(throwing: error)
        } else {
            self.continuation.finish()
        }
    }
}

/// Provider for Ollama models
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class OllamaProvider: ModelProvider {
    public let modelId: String
    public let baseURL: String?
    public let apiKey: String?
    public let capabilities: ModelCapabilities

    private let model: LanguageModel.Ollama
    private let urlSession: URLSession

    public var reasoningReplayIdentity: String? {
        guard let baseURL else { return nil }
        return Self.reasoningReplayIdentity(
            baseURL: baseURL,
            apiKey: self.apiKey,
            urlSession: self.urlSession,
        )
    }

    public init(
        model: LanguageModel.Ollama,
        configuration: TachikomaConfiguration,
        urlSession: URLSession = .shared,
    ) throws {
        self.model = model
        self.modelId = model.modelId
        self.urlSession = urlSession

        let baseURL = Self.resolvedBaseURL(configuration: configuration)
        let apiKey = configuration.getAPIKey(for: .ollama)
        self.baseURL = baseURL

        // Ollama doesn't typically require an API key for local usage, but allow configuration
        self.apiKey = apiKey

        self.capabilities = ModelCapabilities(
            supportsVision: model.supportsVision,
            supportsTools: model.supportsTools,
            supportsStreaming: true,
            supportsAudioInput: model.supportsAudioInput,
            supportsAudioOutput: model.supportsAudioOutput,
            contextLength: model.contextLength,
            maxOutputTokens: 4096,
        )
    }

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        guard let baseURL else {
            throw TachikomaError.invalidConfiguration("Ollama base URL not configured")
        }

        let url = try Self.ollamaChatURL(baseURL: baseURL)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        self.applyAuthentication(to: &urlRequest)
        urlRequest.timeoutInterval = 300 // 5 minutes for local processing

        let messages = try self.convertMessagesToOllama(request.messages)

        var options: OllamaChatRequest.OllamaOptions?
        if request.settings.temperature != nil || request.settings.maxTokens != nil {
            options = OllamaChatRequest.OllamaOptions(
                temperature: request.settings.temperature,
                numCtx: nil, // Context length managed by model
                numPredict: request.settings.maxTokens,
            )
        }

        let ollamaRequest = try OllamaChatRequest(
            model: modelId,
            messages: messages,
            tools: request.tools?.map { try self.convertToolToOllama($0) },
            stream: false,
            think: Self.ollamaThink(for: request.settings.reasoningEffort, model: self.model),
            options: options,
        )

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(ollamaRequest)

        let (data, response) = try await self.urlSession.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"

            // Try to parse Ollama error format
            if let errorData = try? JSONDecoder().decode(OllamaErrorResponse.self, from: data) {
                throw TachikomaError.apiError("Ollama Error: \(errorData.error)")
            }

            throw TachikomaError.apiError("Ollama Error (HTTP \(httpResponse.statusCode)): \(errorText)")
        }

        let decoder = JSONDecoder()
        let ollamaResponse = try decoder.decode(OllamaChatResponse.self, from: data)
        guard ollamaResponse.done else {
            throw TachikomaError.apiError("Ollama Error: response ended before terminal done status")
        }

        let text = ollamaResponse.message.content

        // Ollama doesn't provide detailed token usage, estimate based on content
        let usage = Usage(
            inputTokens: request.messages.map { $0.content.compactMap { part in
                if case let .text(text) = part {
                    return text
                }
                return nil
            }.joined().count / 4 }.reduce(0, +),
            outputTokens: text.count / 4,
        )

        // Handle tool calls - Ollama might return them in different formats
        var toolCalls: [AgentToolCall]?
        if let messageCalls = ollamaResponse.message.toolCalls {
            toolCalls = messageCalls.map { Self.convertOllamaToolCall($0) }
        }

        // Some Ollama models output tool calls as JSON in the content
        if toolCalls == nil, text.contains("{"), text.contains("\"function\"") {
            // Try to parse tool calls from content
            if
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let functionName = json["function"] as? String
            {
                // Convert arguments to AnyAgentToolValue format
                var arguments: [String: AnyAgentToolValue] = [:]
                for (key, value) in json {
                    if key != "function" {
                        do {
                            arguments[key] = try AnyAgentToolValue.fromJSON(value)
                        } catch {
                            // Log warning and skip arguments that can't be converted
                            print("[WARNING] Failed to convert tool argument '\(key)': \(error)")
                            continue
                        }
                    }
                }

                toolCalls = [
                    AgentToolCall(
                        id: "ollama_\(UUID().uuidString)",
                        name: functionName,
                        arguments: arguments,
                    ),
                ]
            }
        }

        let finishReason = Self.mapFinishReason(
            done: ollamaResponse.done,
            doneReason: ollamaResponse.doneReason,
            hasToolCalls: toolCalls?.isEmpty == false,
        )
        let reasoning = ollamaResponse.message.thinking.flatMap { thinking in
            thinking.isEmpty ? nil : ProviderReasoningBlock(text: thinking, type: "ollama_thinking")
        }

        return ProviderResponse(
            text: text,
            usage: usage,
            finishReason: finishReason,
            toolCalls: toolCalls,
            reasoning: reasoning.map { [$0] } ?? [],
        )
    }

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        guard let baseURL else {
            throw TachikomaError.invalidConfiguration("Ollama base URL not configured")
        }

        let url = try Self.ollamaChatURL(baseURL: baseURL)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        self.applyAuthentication(to: &urlRequest)
        urlRequest.timeoutInterval = 300 // 5 minutes for local processing

        let messages = try self.convertMessagesToOllama(request.messages)

        var options: OllamaChatRequest.OllamaOptions?
        if request.settings.temperature != nil || request.settings.maxTokens != nil {
            options = OllamaChatRequest.OllamaOptions(
                temperature: request.settings.temperature,
                numCtx: nil,
                numPredict: request.settings.maxTokens,
            )
        }

        let ollamaRequest = try OllamaChatRequest(
            model: modelId,
            messages: messages,
            tools: request.tools?.map { try self.convertToolToOllama($0) },
            stream: true,
            think: Self.ollamaThink(for: request.settings.reasoningEffort, model: self.model),
            options: options,
        )

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(ollamaRequest)

        return Self.ollamaStream(lines: self.ollamaResponseLines(for: urlRequest))
    }

    // MARK: - Helper Methods

    private struct OllamaStreamState {
        var sawToolCall = false
        var sawDone = false
    }

    static func resolvedBaseURL(configuration: TachikomaConfiguration) -> String {
        if let configuredURL = configuration.configuredBaseURL(for: .ollama) {
            return configuredURL
        }
        if
            let legacyURL = ProcessInfo.processInfo.environment["PEEKABOO_OLLAMA_BASE_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !legacyURL.isEmpty
        {
            return legacyURL
        }
        return Provider.ollama.defaultBaseURL ?? "http://localhost:11434"
    }

    private static func ollamaChatURL(baseURL: String) throws -> URL {
        guard
            var components = URLComponents(string: baseURL),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false else
        {
            throw TachikomaError.invalidConfiguration("Ollama base URL is invalid")
        }

        components.scheme = scheme
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        if basePath.hasSuffix("/api/chat") {
            components.percentEncodedPath = basePath
        } else if basePath.hasSuffix("/api") {
            components.percentEncodedPath = "\(basePath)/chat"
        } else {
            components.percentEncodedPath = "\(basePath)/api/chat"
        }
        components.fragment = nil

        guard let url = components.url else {
            throw TachikomaError.invalidConfiguration("Ollama base URL is invalid")
        }
        return url
    }

    private static func reasoningReplayIdentity(
        baseURL: String,
        apiKey: String?,
        urlSession: URLSession,
    )
        -> String?
    {
        // Delegate challenge handling can select credentials dynamically. Without
        // an inspectable auth boundary, fail closed and omit replay metadata.
        guard urlSession.delegate == nil else { return nil }

        let configuration = urlSession.configuration
        if
            let requestURL = try? self.ollamaChatURL(baseURL: baseURL),
            configuration.httpCookieStorage?.cookies(for: requestURL)?.isEmpty == false
        {
            return nil
        }
        guard !self.hasStoredCredentials(for: baseURL, configuration: configuration) else {
            return nil
        }

        return ReasoningEndpointIdentity.bindingAuthentication(
            to: ReasoningEndpointIdentity.canonical(baseURL),
            apiKey: apiKey,
            headers: configuration.httpAdditionalHeaders,
        )
    }

    private static func hasStoredCredentials(
        for baseURL: String,
        configuration: URLSessionConfiguration,
    )
        -> Bool
    {
        guard
            let components = URLComponents(string: baseURL),
            let host = components.host,
            let scheme = components.scheme else
        {
            return true
        }
        let port = components.port ?? (scheme.lowercased() == "https" ? 443 : 80)
        return configuration.urlCredentialStorage?.allCredentials.keys.contains { protectionSpace in
            protectionSpace.host.caseInsensitiveCompare(host) == .orderedSame &&
                protectionSpace.protocol?.caseInsensitiveCompare(scheme) == .orderedSame &&
                protectionSpace.port == port
        } == true
    }

    private func applyAuthentication(to request: inout URLRequest) {
        guard let apiKey, !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private static func ollamaThink(
        for effort: ReasoningEffort?,
        model: LanguageModel.Ollama,
    )
        -> OllamaChatRequest.OllamaThink?
    {
        guard let effort else { return nil }

        let modelId = model.modelId.lowercased()
        let usesThinkingLevels = switch model {
        case .gptOSS120B, .gptOSS20B:
            true
        case .custom:
            modelId.contains("gpt-oss")
        default:
            false
        }
        if usesThinkingLevels {
            let level = switch effort {
            case .low: "low"
            case .medium: "medium"
            case .high, .xhigh, .max: "high"
            }
            return .level(level)
        }

        let supportsBooleanThinking = switch model {
        case .deepseekR18b, .deepseekR1671b:
            true
        case .custom:
            // The Ollama registry is open-ended. Keep custom models fail-closed
            // except for documented thinking families, because unsupported
            // templates return HTTP 400 when `think` is present.
            modelId.contains("deepseek-r1") ||
                modelId.contains("deepseek-v3.1") ||
                modelId.contains("deepseek-v3-1") ||
                modelId.contains("deepseek-v3_1") ||
                modelId.contains("qwen3") ||
                modelId.contains("qwq")
        default:
            false
        }
        guard supportsBooleanThinking else {
            return nil
        }
        return .enabled(true)
    }

    private func ollamaResponseLines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationNetworking)
        // Corelibs Foundation has no AsyncBytes API. Keep custom-delegate sessions
        // intact even though their safe fallback must buffer the response.
        if self.urlSession.delegate != nil {
            return self.bufferedOllamaResponseLines(for: request)
        }

        let configuration = self.urlSession.configuration
        return AsyncThrowingStream { continuation in
            let delegate = OllamaNDJSONStreamDelegate(continuation: continuation)
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: delegateQueue,
            )
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
        #else
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let taskDelegate = self.urlSession.delegate as? URLSessionTaskDelegate
                    let (bytes, response) = try await self.urlSession.bytes(
                        for: request,
                        delegate: taskDelegate,
                    )
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
                    }
                    guard httpResponse.statusCode == 200 else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        let errorText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        throw TachikomaError.apiError(
                            "Ollama Error (HTTP \(httpResponse.statusCode)): \(errorText)",
                        )
                    }

                    var buffer = Data()
                    for try await byte in bytes {
                        if byte == 0x0A {
                            try continuation.yield(Self.decodeOllamaStreamLine(buffer))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        try continuation.yield(Self.decodeOllamaStreamLine(buffer))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #endif
    }

    #if canImport(FoundationNetworking)
    private func bufferedOllamaResponseLines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (data, response) = try await self.urlSession.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
                    }
                    guard httpResponse.statusCode == 200 else {
                        let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                        throw TachikomaError.apiError(
                            "Ollama Error (HTTP \(httpResponse.statusCode)): \(errorText)",
                        )
                    }
                    let text = try Self.decodeOllamaStreamLine(data)
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        continuation.yield(String(line))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif

    private static func decodeOllamaStreamLine(_ data: Data) throws -> String {
        guard let line = String(data: data, encoding: .utf8) else {
            throw TachikomaError.apiError("Ollama Error: stream response was not valid UTF-8")
        }
        return line
    }

    private static func ollamaStream<Lines: AsyncSequence & Sendable>(lines: Lines)
        -> AsyncThrowingStream<TextStreamDelta, Error>
        where Lines.Element == String
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var state = OllamaStreamState()
                    for try await line in lines {
                        try Self.processOllamaStreamLine(line, state: &state, continuation: continuation)
                        if state.sawDone {
                            continuation.finish()
                            return
                        }
                    }

                    throw TachikomaError.apiError("Ollama Error: stream ended before terminal done response")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func processOllamaStreamLine(
        _ line: String,
        state: inout OllamaStreamState,
        continuation: AsyncThrowingStream<TextStreamDelta, Error>.Continuation,
    ) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8) else {
            throw TachikomaError.apiError("Ollama Error: stream contained a non-UTF-8 chunk")
        }

        let decoder = JSONDecoder()
        if let errorResponse = try? decoder.decode(OllamaErrorResponse.self, from: data) {
            throw TachikomaError.apiError("Ollama Error: \(errorResponse.error)")
        }

        let chunk: OllamaStreamChunk
        do {
            chunk = try decoder.decode(OllamaStreamChunk.self, from: data)
        } catch {
            throw TachikomaError.apiError(
                "Ollama Error: malformed NDJSON stream chunk (\(error.localizedDescription))",
            )
        }

        if let thinking = chunk.message.thinking, !thinking.isEmpty {
            continuation.yield(.reasoning(thinking, type: "ollama_thinking"))
        }
        if let content = chunk.message.content, !content.isEmpty {
            continuation.yield(.text(content))
        }

        for ollamaCall in chunk.message.toolCalls ?? [] {
            state.sawToolCall = true
            continuation.yield(.tool(Self.convertOllamaToolCall(ollamaCall)))
        }

        if chunk.done {
            state.sawDone = true
            continuation.yield(.done(finishReason: Self.mapFinishReason(
                done: true,
                doneReason: chunk.doneReason,
                hasToolCalls: state.sawToolCall,
            )))
        }
    }

    static func mapFinishReason(done: Bool, doneReason: String?, hasToolCalls: Bool) -> FinishReason {
        guard done else {
            return .other
        }

        switch doneReason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "stop":
            return hasToolCalls ? .toolCalls : .stop
        case "length":
            return .length
        default:
            return .other
        }
    }

    /// Shared by the streaming and non-streaming paths so both surface Ollama's
    /// native tool calls identically.
    static func convertOllamaToolCall(_ ollamaCall: OllamaToolCall) -> AgentToolCall {
        AgentToolCall(
            id: "ollama_\(UUID().uuidString)",
            name: ollamaCall.function.name,
            arguments: ollamaCall.function.arguments,
        )
    }

    private func convertMessagesToOllama(_ messages: [ModelMessage]) throws -> [OllamaChatMessage] {
        var toolNamesByCallID: [String: String] = [:]
        var converted: [OllamaChatMessage] = []
        var pendingThinking = ""

        for message in messages {
            let text = message.content.compactMap { part in
                if case let .text(text) = part {
                    return text
                }
                return nil
            }.joined()
            let images = message.content.compactMap { part in
                if case let .image(image) = part {
                    return image.data
                }
                return nil
            }

            if message.role == .assistant, message.channel == .thinking {
                guard self.canReplayThinking(message) else { continue }
                pendingThinking.append(text)
                continue
            }

            if message.role != .assistant, !pendingThinking.isEmpty {
                converted.append(OllamaChatMessage(
                    role: ModelMessage.Role.assistant.rawValue,
                    content: "",
                    thinking: pendingThinking,
                ))
                pendingThinking = ""
            }

            let toolCalls = message.content.compactMap { part -> AgentToolCall? in
                if case let .toolCall(call) = part {
                    return call
                }
                return nil
            }
            for call in toolCalls {
                toolNamesByCallID[call.id] = call.name
            }

            if message.role == .tool {
                let toolResults = message.content.compactMap { part -> AgentToolResult? in
                    if case let .toolResult(result) = part {
                        return result
                    }
                    return nil
                }

                if !toolResults.isEmpty {
                    for result in toolResults {
                        guard let toolName = toolNamesByCallID[result.toolCallId] else {
                            throw TachikomaError.invalidInput(
                                "Ollama tool result references unknown call ID '\(result.toolCallId)'",
                            )
                        }
                        try converted.append(OllamaChatMessage(
                            role: message.role.rawValue,
                            content: Self.ollamaToolResultContent(result.result),
                            toolName: toolName,
                        ))
                    }
                    continue
                }
            }

            let ollamaCalls = toolCalls.enumerated().map { index, call in
                OllamaToolCall(
                    function: OllamaToolCall.Function(
                        index: index,
                        name: call.name,
                        arguments: call.arguments,
                    ),
                )
            }
            let thinking = message.role == .assistant && !pendingThinking.isEmpty ? pendingThinking : nil
            converted.append(OllamaChatMessage(
                role: message.role.rawValue,
                content: text,
                thinking: thinking,
                images: images.isEmpty ? nil : images,
                toolCalls: ollamaCalls.isEmpty ? nil : ollamaCalls,
            ))
            if thinking != nil {
                pendingThinking = ""
            }
        }

        if !pendingThinking.isEmpty {
            converted.append(OllamaChatMessage(
                role: ModelMessage.Role.assistant.rawValue,
                content: "",
                thinking: pendingThinking,
            ))
        }

        return converted
    }

    private func canReplayThinking(_ message: ModelMessage) -> Bool {
        guard
            let endpointIdentity = self.reasoningReplayIdentity,
            let customData = message.metadata?.customData,
            customData["ollama.thinking"] != nil,
            customData["tachikoma.reasoning.provider"] == "ollama",
            customData["tachikoma.reasoning.model"] == self.modelId,
            customData["tachikoma.reasoning.base_url"] == endpointIdentity else
        {
            return false
        }
        return true
    }

    private static func ollamaToolResultContent(_ result: AnyAgentToolValue) throws -> String {
        if let string = result.stringValue {
            return string
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        guard let content = String(bytes: data, encoding: .utf8) else {
            throw TachikomaError.invalidInput("Could not encode Ollama tool result as UTF-8")
        }
        return content
    }

    private func convertToolToOllama(_ tool: AgentTool) throws -> OllamaTool {
        let schema = try tool.parameters.jsonSchema()
        var parameters: [String: AnyAgentToolValue] = [:]
        for (key, value) in schema {
            parameters[key] = try AnyAgentToolValue.fromJSON(value)
        }

        return OllamaTool(
            type: "function",
            function: OllamaTool.Function(
                name: tool.name,
                description: tool.description,
                parameters: parameters,
            ),
        )
    }
}

extension OllamaProvider: ResponseCacheSafetyProviding {
    var isResponseCacheSafe: Bool {
        // URLSession authentication state can change after provider creation.
        // Never place Ollama responses in a shared cache without a stable auth boundary.
        false
    }
}
