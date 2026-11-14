import Foundation
import Tachikoma

extension FileManager {
    var userDirectory: URL {
        #if os(macOS)
        homeDirectoryForCurrentUser
        #elseif os(iOS)
        urls(for: .documentDirectory, in: .userDomainMask).first ?? temporaryDirectory
        #else
        temporaryDirectory
        #endif
    }
}

/// Modern AI agent integrated with the Tachikoma enum-based model system
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class Agent<Context>: @unchecked Sendable {
    /// Agent's unique identifier
    public let name: String

    /// System instructions for the agent
    public let instructions: String

    /// Available tools for the agent
    public private(set) var tools: [AgentTool]

    /// Language model used by this agent
    public var model: LanguageModel {
        didSet {
            self.usesImplicitDefaultModel = false
        }
    }

    /// Generation settings for the agent
    public var settings: GenerationSettings

    /// Provider configuration for generation and streaming
    private let configuration: TachikomaConfiguration

    /// The context instance passed to tool executions
    private let context: Context

    /// Current conversation history
    public private(set) var conversation: Conversation
    private var usesImplicitDefaultModel: Bool

    public init(
        name: String,
        instructions: String,
        model: LanguageModel? = nil,
        tools: [AgentTool] = [],
        settings: GenerationSettings = .default,
        configuration: TachikomaConfiguration = .current,
        context: Context,
    ) {
        self.name = name
        self.instructions = instructions
        self.usesImplicitDefaultModel = model == nil
        self.model = model ?? .default
        self.tools = tools
        self.settings = settings
        self.configuration = configuration
        self.context = context
        self.conversation = Conversation(configuration: configuration)

        // Add system message with instructions
        self.conversation.addSystemMessage(instructions)
    }

    /// Add a tool to the agent
    public func addTool(_ tool: AgentTool) {
        // Add a tool to the agent
        self.tools.append(tool)
    }

    /// Remove a tool from the agent
    public func removeTool(named name: String) {
        // Remove a tool from the agent
        self.tools.removeAll { $0.name == name }
    }

    /// Execute a single message with the agent
    public func execute(_ message: String) async throws -> AgentResponse {
        let conversation = self.conversation
        let model = self.model
        let tools = self.tools
        let settings = self.settings

        return try await conversation.withContinuationLock {
            conversation.addUserMessage(message)
            let conversationMessages = conversation.messages
            let modelMessages = conversationMessages.map { $0.toModelMessage() }
            let snapshotIDs = conversationMessages.map(\.id)
            let anchorID = conversationMessages.last?.id
            let result = try await generateText(
                model: model,
                messages: modelMessages,
                tools: tools.isEmpty ? nil : tools,
                settings: settings,
                maxSteps: 5, // Allow multi-step tool execution
                configuration: self.configuration,
            )

            let didMerge: Bool
            if result.finishReason == .contentFilter {
                didMerge = conversation.mergeContentFilterResult(
                    result.messages,
                    originalMessages: modelMessages,
                    afterMessageID: anchorID,
                    validatingSnapshotIDs: snapshotIDs,
                )
            } else if let anchorID {
                let generatedMessages = Array(result.messages.dropFirst(modelMessages.count))
                let didMerge = conversation.appendGeneratedMessages(
                    generatedMessages,
                    afterMessageID: anchorID,
                    validatingSnapshotIDs: snapshotIDs,
                )
                guard didMerge else {
                    throw TachikomaError.invalidConfiguration(
                        "Conversation changed during generation; refusing to merge response",
                    )
                }
                return AgentResponse(
                    text: result.text,
                    usage: result.usage,
                    finishReason: result.finishReason ?? .other,
                    steps: result.steps,
                    conversationLength: conversation.messages.count,
                )
            } else {
                didMerge = conversation.messages.isEmpty
            }

            guard didMerge else {
                throw TachikomaError.invalidConfiguration(
                    "Conversation changed during generation; refusing to merge response",
                )
            }

            return AgentResponse(
                text: result.text,
                usage: result.usage,
                finishReason: result.finishReason ?? .other,
                steps: result.steps,
                conversationLength: conversation.messages.count,
            )
        }
    }

    /// Stream a response from the agent
    public func stream(_ message: String) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        let streamingModel = if self.usesImplicitDefaultModel {
            LanguageModel.defaultStreaming
        } else if self.model.supportsStreaming {
            self.model
        } else {
            self.model
        }
        guard streamingModel.supportsStreaming else {
            throw TachikomaError.invalidConfiguration("\(self.model.modelId) does not support streaming")
        }

        let conversation = self.conversation
        try await conversation.acquireContinuationLock()
        let gateRelease = AsyncReleaseOnce {
            await conversation.releaseContinuationLock()
        }

        // Add user message to conversation
        conversation.addUserMessage(message)
        let conversationMessages = conversation.messages
        let modelMessages = conversationMessages.map { $0.toModelMessage() }
        let snapshotIDs = conversationMessages.map(\.id)
        let buffersUntilDone = self.settings.streamBuffering == .untilTerminal

        // Stream response
        let streamResult: StreamTextResult
        do {
            streamResult = try await streamText(
                model: streamingModel,
                messages: modelMessages,
                tools: self.tools.isEmpty ? nil : self.tools,
                settings: self.settings,
                maxSteps: 5,
                configuration: self.configuration,
            )
        } catch {
            gateRelease.release()
            throw error
        }

        // Track final message in conversation (this is approximate for streaming)
        return AsyncThrowingStream<TextStreamDelta, Error> { continuation in
            let producer = Task {
                defer {
                    gateRelease.release()
                }
                do {
                    var assistantText = ""
                    var bufferedDeltas: [TextStreamDelta] = []
                    var didReceiveTerminal = false

                    for try await delta in streamResult.stream {
                        try Task.checkCancellation()
                        if buffersUntilDone {
                            bufferedDeltas.append(delta)
                        } else {
                            continuation.yield(delta)
                        }

                        // Collect assistant text
                        if case .textDelta = delta.type, let content = delta.content {
                            assistantText += content
                        }

                        if case .done = delta.type {
                            didReceiveTerminal = true
                            guard delta.finishReason != .contentFilter else {
                                let didRollback = conversation.replaceModelMessages(
                                    modelMessages.droppingLastUserTurn(),
                                    validatingSnapshotIDs: snapshotIDs,
                                )
                                guard didRollback else {
                                    throw TachikomaError.invalidConfiguration(
                                        "Conversation changed during streaming; refusing to merge response",
                                    )
                                }
                                assistantText = ""
                                bufferedDeltas.removeAll()
                                if buffersUntilDone {
                                    continuation.yield(delta)
                                }
                                continue
                            }
                            if buffersUntilDone {
                                for bufferedDelta in bufferedDeltas {
                                    continuation.yield(bufferedDelta)
                                }
                                bufferedDeltas.removeAll()
                            }
                            // Add final assistant message to conversation
                            if !assistantText.isEmpty {
                                conversation.addAssistantMessage(assistantText)
                                assistantText = ""
                            }
                        }
                    }
                    if buffersUntilDone, !didReceiveTerminal, !bufferedDeltas.isEmpty {
                        throw TachikomaError.apiError("Stream ended before provider completion status was received")
                    }
                    if !buffersUntilDone, !assistantText.isEmpty {
                        try Task.checkCancellation()
                        conversation.addAssistantMessage(assistantText)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    /// Reset the agent's conversation history
    public func resetConversation() {
        // Reset the agent's conversation history
        self.conversation = Conversation(configuration: self.configuration)
        self.conversation.addSystemMessage(self.instructions)
    }

    /// Get the current conversation history
    public var messages: [ModelMessage] {
        self.conversation.getModelMessages()
    }

    /// Update the agent's instructions
    public func updateInstructions(_ newInstructions: String) {
        // Create new conversation with updated instructions
        let oldMessages = self.conversation.getModelMessages().filter { $0.role != .system }
        self.conversation = Conversation(configuration: self.configuration)
        self.conversation.addSystemMessage(newInstructions)

        // Re-add non-system messages
        for message in oldMessages {
            self.conversation.addModelMessage(message)
        }
    }
}

final class AsyncReleaseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didRelease = false
    private let operation: @Sendable () async -> Void

    init(operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    func release() {
        self.lock.lock()
        guard !self.didRelease else {
            self.lock.unlock()
            return
        }
        self.didRelease = true
        self.lock.unlock()

        Task {
            await self.operation()
        }
    }
}

/// Response from an agent execution
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct AgentResponse: Sendable {
    public let text: String
    public let usage: Usage?
    public let finishReason: FinishReason
    public let steps: [GenerationStep]
    public let conversationLength: Int

    public init(
        text: String,
        usage: Usage?,
        finishReason: FinishReason,
        steps: [GenerationStep],
        conversationLength: Int,
    ) {
        self.text = text
        self.usage = usage
        self.finishReason = finishReason
        self.steps = steps
        self.conversationLength = conversationLength
    }
}

/// Session management for agents
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class AgentSessionManager: @unchecked Sendable {
    public static let shared = AgentSessionManager()

    private var sessions: [String: AgentSessionData] = [:]
    private let lock = NSLock()
    private let fileManager = FileManager.default

    private init() {}

    /// Helper function to extract text from content part
    private func extractTextFromContentPart(_ contentPart: ModelMessage.ContentPart?) -> String? {
        // Helper function to extract text from content part
        guard let contentPart else { return nil }
        switch contentPart {
        case let .text(text):
            return text
        case .image:
            return "[Image]"
        case .reasoning:
            return nil
        case let .toolCall(toolCall):
            return "Tool: \(toolCall.name)"
        case let .toolResult(toolResult):
            return "Result: \(toolResult.toolCallId)"
        }
    }

    /// Get the sessions storage directory
    private func getSessionsDirectory() -> URL {
        // Get the sessions storage directory
        let url = self.fileManager.userDirectory
            .appendingPathComponent(".peekaboo/agent_sessions")

        // Ensure the directory exists
        try? self.fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        return url
    }

    /// Get the file path for a specific session
    private func getSessionFilePath(for sessionId: String) -> URL {
        // Get the file path for a specific session
        self.getSessionsDirectory().appendingPathComponent("\(sessionId).json")
    }

    /// Create a new agent session
    public func createSession(
        sessionId: String,
        agent: Agent<some Any>,
    ) {
        // Create a new agent session
        self.lock.lock()
        defer { lock.unlock() }

        self.sessions[sessionId] = AgentSessionData(
            id: sessionId,
            modelName: agent.model.description,
            createdAt: Date(),
            lastAccessedAt: Date(),
            messageCount: agent.messages.count,
            status: .active,
        )
    }

    /// Update session data
    public func updateSession(
        sessionId: String,
        agent: Agent<some Any>,
    ) {
        // Update session data
        self.lock.lock()
        defer { lock.unlock() }

        if var sessionData = sessions[sessionId] {
            sessionData.lastAccessedAt = Date()
            sessionData.messageCount = agent.messages.count
            self.sessions[sessionId] = sessionData
        }
    }

    /// Complete a session
    public func completeSession(sessionId: String) {
        // Complete a session
        self.lock.lock()
        defer { lock.unlock() }

        if var sessionData = sessions[sessionId] {
            sessionData.status = .completed
            sessionData.lastAccessedAt = Date()
            self.sessions[sessionId] = sessionData
        }
    }

    /// Get session summary
    public func getSessionSummary(sessionId: String) -> SessionSummary? {
        // Get session summary
        self.lock.lock()
        defer { lock.unlock() }

        guard let sessionData = sessions[sessionId] else { return nil }

        return SessionSummary(
            id: sessionData.id,
            modelName: sessionData.modelName,
            createdAt: sessionData.createdAt,
            lastAccessedAt: sessionData.lastAccessedAt,
            messageCount: sessionData.messageCount,
            status: sessionData.status,
            summary: nil, // Could be enhanced to generate summaries
        )
    }

    /// List all sessions from disk
    public func listSessions() -> [SessionSummary] {
        // List all sessions from disk
        let sessionsDir = self.getSessionsDirectory()

        guard
            let sessionFiles = try? fileManager.contentsOfDirectory(
                at: sessionsDir,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: .skipsHiddenFiles,
            ) else
        {
            return []
        }

        var summaries: [SessionSummary] = []

        for sessionFile in sessionFiles where sessionFile.pathExtension == "json" {
            _ = sessionFile.deletingPathExtension().lastPathComponent

            do {
                let data = try Data(contentsOf: sessionFile)
                let session = try JSONDecoder().decode(AgentSession.self, from: data)

                let summary = SessionSummary(
                    id: session.id,
                    modelName: session.modelName,
                    createdAt: session.createdAt,
                    lastAccessedAt: session.lastAccessedAt,
                    messageCount: session.messages.count,
                    status: .active, // All loaded sessions are considered active
                    summary: extractTextFromContentPart(session.messages.last?.content.first),
                )
                summaries.append(summary)
            } catch {
                // Skip corrupted session files
                try? fileManager.removeItem(at: sessionFile)
            }
        }

        return summaries.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    /// Remove a session
    public func removeSession(sessionId: String) {
        // Remove a session
        self.lock.lock()
        defer { lock.unlock() }

        self.sessions.removeValue(forKey: sessionId)
    }

    /// Clear old sessions (older than specified days)
    public func clearOldSessions(olderThanDays days: Int = 30) {
        // Clear old sessions (older than specified days)
        self.lock.lock()
        defer { lock.unlock() }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        self.sessions = self.sessions.filter { _, sessionData in
            sessionData.lastAccessedAt >= cutoffDate
        }
    }

    /// Load a session from disk
    public func loadSession(id: String) async throws -> AgentSession? {
        // Load a session from disk
        let filePath = self.getSessionFilePath(for: id)

        guard self.fileManager.fileExists(atPath: filePath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: filePath)
            let session = try JSONDecoder().decode(AgentSession.self, from: data)

            // Update in-memory cache
            self.lock.withLock {
                let sessionData = AgentSessionData(
                    id: session.id,
                    modelName: session.modelName,
                    createdAt: session.createdAt,
                    lastAccessedAt: session.lastAccessedAt,
                    messageCount: session.messages.count,
                    status: .active,
                )
                self.sessions[session.id] = sessionData
            }

            return session
        } catch {
            // Remove corrupted session file
            try? self.fileManager.removeItem(at: filePath)
            return nil
        }
    }

    /// Delete a session from disk and memory
    public func deleteSession(id: String) async throws {
        // Remove from memory
        _ = self.lock.withLock {
            self.sessions.removeValue(forKey: id)
        }

        // Remove from disk
        let filePath = self.getSessionFilePath(for: id)
        try? self.fileManager.removeItem(at: filePath)
    }

    /// Save a session to disk and memory
    public func saveSession(_ session: AgentSession) async throws {
        // Save to disk
        let filePath = self.getSessionFilePath(for: session.id)
        let data = try JSONEncoder().encode(session)
        try data.write(to: filePath, options: .atomic)

        // Update in-memory cache
        self.lock.withLock {
            let sessionData = AgentSessionData(
                id: session.id,
                modelName: session.modelName,
                createdAt: session.createdAt,
                lastAccessedAt: session.lastAccessedAt,
                messageCount: session.messages.count,
                status: .active,
            )
            self.sessions[session.id] = sessionData
        }
    }
}

/// Public session data for external consumption
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct AgentSession: Codable {
    public let id: String
    public let modelName: String
    public let messages: [ModelMessage]
    public let createdAt: Date
    public let lastAccessedAt: Date
    public let metadata: [String: String]

    public init(
        id: String,
        modelName: String,
        messages: [ModelMessage],
        createdAt: Date,
        lastAccessedAt: Date,
        metadata: [String: String] = [:],
    ) {
        self.id = id
        self.modelName = modelName
        self.messages = messages
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.metadata = metadata
    }
}

/// Internal session data structure
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private struct AgentSessionData {
    let id: String
    let modelName: String
    let createdAt: Date
    var lastAccessedAt: Date
    var messageCount: Int
    var status: SessionStatus
}

/// Session summary information
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct SessionSummary: Sendable, Codable {
    /// Unique session identifier
    public let id: String

    /// Model name used in this session
    public let modelName: String

    /// When the session was created
    public let createdAt: Date

    /// When the session was last accessed
    public let lastAccessedAt: Date

    /// Number of messages in the session
    public let messageCount: Int

    /// Session status
    public let status: SessionStatus

    /// Brief description of the session
    public let summary: String?

    public init(
        id: String,
        modelName: String,
        createdAt: Date,
        lastAccessedAt: Date,
        messageCount: Int,
        status: SessionStatus,
        summary: String? = nil,
    ) {
        self.id = id
        self.modelName = modelName
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.messageCount = messageCount
        self.status = status
        self.summary = summary
    }
}

/// Status of an agent session
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case active
    case completed
    case failed
    case cancelled
}

extension LanguageModel {
    var requiresTerminalRefusalBuffering: Bool {
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
            guard
                let parsed = ProviderParser.parse(provider.modelId),
                let registeredProvider = CustomProviderRegistry.shared.get(parsed.provider) else
            {
                return LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: provider.modelId)
            }
            switch registeredProvider.kind {
            case .openai:
                return false
            case .anthropic:
                return LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: parsed.model)
            }
        default:
            return false
        }
    }
}
