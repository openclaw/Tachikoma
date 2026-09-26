import Foundation

// MARK: - Usage Tracking and Cost Calculation

/// Usage tracking and cost calculation system for Tachikoma AI SDK
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class UsageTracker: @unchecked Sendable {
    /// Shared usage tracker instance
    public static let shared = UsageTracker()

    private let lock = NSLock()
    private var _sessions: [String: UsageSession] = [:]
    private var _totalUsage = TotalUsage()
    private var _costCalculator = ModelCostCalculator()

    private init() {}

    /// Create a new usage tracker instance for testing
    /// - Note: This initializer is primarily intended for testing to avoid shared state issues
    public init(forTesting _: Bool) {
        // Same as private init but allows creating separate instances for tests
    }

    // MARK: - Session Management

    /// Start a new usage session
    /// - Parameter sessionId: Optional session ID. If nil, generates a new UUID
    /// - Returns: The session ID for tracking
    public func startSession(_ sessionId: String? = nil) -> String {
        // Start a new usage session
        let id = sessionId ?? UUID().uuidString
        let session = UsageSession(id: id, startTime: Date())

        self.lock.withLock {
            self._sessions[id] = session
        }

        return id
    }

    /// End a usage session
    /// - Parameter sessionId: The session ID to end
    /// - Returns: The final session usage data
    @discardableResult
    public func endSession(_ sessionId: String) -> UsageSession? {
        self.lock.withLock {
            guard let session = _sessions[sessionId] else { return nil }

            let finalSession = session.ended()
            self._sessions[sessionId] = finalSession

            // Add to total usage
            self._totalUsage.addSession(finalSession)

            return finalSession
        }
    }

    /// Record usage for a session
    /// - Parameters:
    ///   - sessionId: The session ID
    ///   - model: The model used
    ///   - usage: The usage statistics
    ///   - operation: The type of operation performed
    public func recordUsage(
        sessionId: String,
        model: LanguageModel,
        usage: Usage,
        operation: OperationType = .textGeneration,
    ) {
        // Record usage for a session
        self.lock.withLock {
            guard let session = _sessions[sessionId] else { return }

            let cost = self._costCalculator.calculateCost(for: model, usage: usage)
            let enhancedUsage = Usage(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cost: cost,
            )

            let updatedSession = session.addingUsage(
                model: model,
                usage: enhancedUsage,
                operation: operation,
            )

            self._sessions[sessionId] = updatedSession
        }
    }

    /// Get current session data
    /// - Parameter sessionId: The session ID
    /// - Returns: The current session data if it exists
    public func getSession(_ sessionId: String) -> UsageSession? {
        // Get current session data
        self.lock.withLock {
            self._sessions[sessionId]
        }
    }

    /// Get all active sessions
    public var activeSessions: [UsageSession] {
        self.lock.withLock {
            Array(self._sessions.values.filter { !$0.isComplete })
        }
    }

    /// Get all completed sessions
    public var completedSessions: [UsageSession] {
        self.lock.withLock {
            Array(self._sessions.values.filter(\.isComplete))
        }
    }

    // MARK: - Total Usage

    /// Get total usage across all sessions
    public var totalUsage: TotalUsage {
        self.lock.withLock {
            self._totalUsage
        }
    }

    /// Reset all usage data
    public func reset() {
        // Reset all usage data
        self.lock.withLock {
            self._sessions.removeAll()
            self._totalUsage = TotalUsage()
        }
    }

    // MARK: - Reporting

    /// Generate a usage report for a date range
    /// - Parameters:
    ///   - startDate: Start date for the report
    ///   - endDate: End date for the report
    /// - Returns: Usage report for the specified period
    public func generateReport(from startDate: Date, to endDate: Date) -> UsageReport {
        // Generate a usage report for a date range
        let sessions = self.lock.withLock {
            Array(self._sessions.values.filter { session in
                session.startTime >= startDate && session.startTime <= endDate
            })
        }

        return UsageReport(
            startDate: startDate,
            endDate: endDate,
            sessions: sessions,
            costCalculator: self._costCalculator,
        )
    }

    /// Generate a usage report for today
    public func generateTodayReport() -> UsageReport {
        // Generate a usage report for today
        let calendar = Calendar.current
        let today = Date()
        let startOfDay = calendar.startOfDay(for: today)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? today

        return self.generateReport(from: startOfDay, to: endOfDay)
    }

    /// Generate a usage report for this month
    public func generateMonthReport() -> UsageReport {
        // Generate a usage report for this month
        let calendar = Calendar.current
        let today = Date()
        let startOfMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let endOfMonth = calendar.dateInterval(of: .month, for: today)?.end ?? today

        return self.generateReport(from: startOfMonth, to: endOfMonth)
    }
}

// MARK: - Usage Session

/// Represents a single usage session
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct UsageSession: Sendable, Codable {
    public let id: String
    public let startTime: Date
    public let endTime: Date?
    public let operations: [UsageOperation]

    public var isComplete: Bool {
        self.endTime != nil
    }

    public var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(self.startTime)
    }

    public var totalTokens: Int {
        self.operations.reduce(0) { $0 + $1.usage.totalTokens }
    }

    public var totalCost: Double {
        self.operations.compactMap { $0.usage.cost?.total }.reduce(0, +)
    }

    init(id: String, startTime: Date) {
        self.id = id
        self.startTime = startTime
        self.endTime = nil
        self.operations = []
    }

    private init(id: String, startTime: Date, endTime: Date?, operations: [UsageOperation]) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.operations = operations
    }

    /// Create a new session with an operation added
    func addingUsage(model: LanguageModel, usage: Usage, operation: OperationType) -> UsageSession {
        // Create a new session with an operation added
        let newOperation = UsageOperation(
            timestamp: Date(),
            model: model,
            usage: usage,
            type: operation,
        )

        return UsageSession(
            id: self.id,
            startTime: self.startTime,
            endTime: self.endTime,
            operations: self.operations + [newOperation],
        )
    }

    /// Create a new session marked as ended
    func ended() -> UsageSession {
        // Create a new session marked as ended
        UsageSession(
            id: self.id,
            startTime: self.startTime,
            endTime: Date(),
            operations: self.operations,
        )
    }
}

// MARK: - Usage Operation

/// Represents a single operation within a session
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct UsageOperation: Sendable, Codable {
    public let timestamp: Date
    public let modelId: String
    public let providerName: String
    public let usage: Usage
    public let type: OperationType

    public init(timestamp: Date, model: LanguageModel, usage: Usage, type: OperationType) {
        self.timestamp = timestamp
        self.modelId = model.modelId
        self.providerName = model.providerName
        self.usage = usage
        self.type = type
    }

    /// For backward compatibility, provide a computed property to reconstruct model info
    public var modelDescription: String {
        "\(self.providerName)/\(self.modelId)"
    }
}

// MARK: - Operation Type

/// Types of operations that can be tracked
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum OperationType: String, Sendable, Codable, CaseIterable {
    case textGeneration = "text_generation"
    case textStreaming = "text_streaming"
    case imageAnalysis = "image_analysis"
    case objectGeneration = "object_generation"
    case toolCall = "tool_call"
    case embedding
    case transcription
    case speechSynthesis = "speech_synthesis"

    public var displayName: String {
        switch self {
        case .textGeneration: "Text Generation"
        case .textStreaming: "Text Streaming"
        case .imageAnalysis: "Image Analysis"
        case .objectGeneration: "Object Generation"
        case .toolCall: "Tool Call"
        case .embedding: "Embedding"
        case .transcription: "Transcription"
        case .speechSynthesis: "Speech Synthesis"
        }
    }
}

// MARK: - Total Usage

/// Aggregated usage statistics across all sessions
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TotalUsage: Sendable, Codable {
    public var totalSessions: Int = 0
    public var totalOperations: Int = 0
    public var totalTokens: Int = 0
    public var totalCost: Double = 0.0
    public var providerBreakdown: [String: ProviderUsage] = [:]
    public var modelBreakdown: [String: ModelUsage] = [:]
    public var operationBreakdown: [String: OperationUsage] = [:]

    mutating func addSession(_ session: UsageSession) {
        self.totalSessions += 1
        self.totalOperations += session.operations.count
        self.totalTokens += session.totalTokens
        self.totalCost += session.totalCost

        for operation in session.operations {
            let providerName = operation.providerName
            let modelName = operation.modelId
            let operationType = operation.type.rawValue

            // Update provider breakdown
            var providerUsage = self.providerBreakdown[providerName] ?? ProviderUsage()
            providerUsage.addOperation(operation)
            self.providerBreakdown[providerName] = providerUsage

            // Update model breakdown
            var modelUsage = self.modelBreakdown[modelName] ?? ModelUsage()
            modelUsage.addOperation(operation)
            self.modelBreakdown[modelName] = modelUsage

            // Update operation type breakdown
            var opUsage = self.operationBreakdown[operationType] ?? OperationUsage()
            opUsage.addOperation(operation)
            self.operationBreakdown[operationType] = opUsage
        }
    }
}

// MARK: - Breakdown Structures

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ProviderUsage: Sendable, Codable {
    public var operations: Int = 0
    public var tokens: Int = 0
    public var cost: Double = 0.0

    mutating func addOperation(_ operation: UsageOperation) {
        self.operations += 1
        self.tokens += operation.usage.totalTokens
        self.cost += operation.usage.cost?.total ?? 0.0
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ModelUsage: Sendable, Codable {
    public var operations: Int = 0
    public var tokens: Int = 0
    public var cost: Double = 0.0

    mutating func addOperation(_ operation: UsageOperation) {
        self.operations += 1
        self.tokens += operation.usage.totalTokens
        self.cost += operation.usage.cost?.total ?? 0.0
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct OperationUsage: Sendable, Codable {
    public var operations: Int = 0
    public var tokens: Int = 0
    public var cost: Double = 0.0

    mutating func addOperation(_ operation: UsageOperation) {
        self.operations += 1
        self.tokens += operation.usage.totalTokens
        self.cost += operation.usage.cost?.total ?? 0.0
    }
}

// MARK: - Usage Report

/// Comprehensive usage report for a specific time period
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct UsageReport: Sendable {
    public let startDate: Date
    public let endDate: Date
    public let sessions: [UsageSession]

    public var totalSessions: Int {
        self.sessions.count
    }

    public var totalOperations: Int {
        self.sessions.reduce(0) { $0 + $1.operations.count }
    }

    public var totalTokens: Int {
        self.sessions.reduce(0) { $0 + $1.totalTokens }
    }

    public var totalCost: Double {
        self.sessions.reduce(0) { $0 + $1.totalCost }
    }

    public let providerBreakdown: [String: ProviderUsage]
    public let modelBreakdown: [String: ModelUsage]
    public let operationBreakdown: [String: OperationUsage]

    init(startDate: Date, endDate: Date, sessions: [UsageSession], costCalculator _: ModelCostCalculator) {
        self.startDate = startDate
        self.endDate = endDate
        self.sessions = sessions

        // Calculate breakdowns
        var providers: [String: ProviderUsage] = [:]
        var models: [String: ModelUsage] = [:]
        var operations: [String: OperationUsage] = [:]

        for session in sessions {
            for operation in session.operations {
                let providerName = operation.providerName
                let modelName = operation.modelId
                let operationType = operation.type.rawValue

                var providerUsage = providers[providerName] ?? ProviderUsage()
                providerUsage.addOperation(operation)
                providers[providerName] = providerUsage

                var modelUsage = models[modelName] ?? ModelUsage()
                modelUsage.addOperation(operation)
                models[modelName] = modelUsage

                var opUsage = operations[operationType] ?? OperationUsage()
                opUsage.addOperation(operation)
                operations[operationType] = opUsage
            }
        }

        self.providerBreakdown = providers
        self.modelBreakdown = models
        self.operationBreakdown = operations
    }

    /// Generate a formatted text report
    public func formattedReport() -> String {
        // Generate a formatted text report
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        lines.append("Usage Report")
        lines.append("============")
        lines.append("Period: \(formatter.string(from: self.startDate)) - \(formatter.string(from: self.endDate))")
        lines.append("")

        lines.append("Summary:")
        lines.append("  Sessions: \(self.totalSessions)")
        lines.append("  Operations: \(self.totalOperations)")
        lines.append("  Total Tokens: \(self.totalTokens)")
        lines.append("  Total Cost: $\(String(format: "%.4f", self.totalCost))")
        lines.append("")

        if !self.providerBreakdown.isEmpty {
            lines.append("By Provider:")
            for (provider, usage) in self.providerBreakdown.sorted(by: { $0.value.cost > $1.value.cost }) {
                lines
                    .append(
                        "  \(provider): \(usage.operations) ops, \(usage.tokens) tokens, $\(String(format: "%.4f", usage.cost))",
                    )
            }
            lines.append("")
        }

        if !self.modelBreakdown.isEmpty {
            lines.append("By Model:")
            for (model, usage) in self.modelBreakdown.sorted(by: { $0.value.cost > $1.value.cost }) {
                lines
                    .append(
                        "  \(model): \(usage.operations) ops, \(usage.tokens) tokens, $\(String(format: "%.4f", usage.cost))",
                    )
            }
            lines.append("")
        }

        if !self.operationBreakdown.isEmpty {
            lines.append("By Operation Type:")
            for (operation, usage) in self.operationBreakdown.sorted(by: { $0.value.cost > $1.value.cost }) {
                let displayName = OperationType(rawValue: operation)?.displayName ?? operation
                lines
                    .append(
                        "  \(displayName): \(usage.operations) ops, \(usage.tokens) tokens, $\(String(format: "%.4f", usage.cost))",
                    )
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Model Cost Calculator

/// Calculates costs for different AI models
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ModelCostCalculator: Sendable {
    private static let sonnet5StandardPricingStart = Date(
        timeIntervalSince1970: 1_788_220_800,
    ) // 2026-09-01 00:00:00 UTC

    private let now: @Sendable () -> Date

    public init() {
        self.now = { Date() }
    }

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// Calculate cost for a model usage
    public func calculateCost(for model: LanguageModel, usage: Usage) -> Usage.Cost {
        // Calculate cost for a model usage
        var pricing = self.getPricing(for: model)
        if case let .openai(openai) = model, openai.isGPT6, usage.inputTokens > 272_000 {
            pricing.input *= 2
            pricing.output *= 1.5
        }

        let inputCost = Double(usage.inputTokens) * pricing.input / 1_000_000.0
        let outputCost = Double(usage.outputTokens) * pricing.output / 1_000_000.0

        return Usage.Cost(input: inputCost, output: outputCost)
    }

    /// Get pricing information for a model (per million tokens)
    private func getPricing(for model: LanguageModel) -> (input: Double, output: Double) {
        // Get pricing information for a model (per million tokens)
        switch model {
        // OpenAI Pricing (as of 2025)
        case let .openai(openaiModel):
            switch openaiModel {
            case .chatLatest: (5.00, 30.00) // ChatGPT Instant alias pricing estimate
            case .gpt5ChatLatest: (1.25, 10.00)
            case .gpt6Astra: (10.00, 50.00)
            case .gpt6Sol: (2.00, 10.00)
            case .gpt6Luna: (0.10, 0.50)
            case .gpt56Sol: (5.00, 30.00)
            case .gpt56Terra: (2.50, 15.00)
            case .gpt56Luna: (1.00, 6.00)
            case .gpt55: (5.00, 20.00) // GPT-5.5 pricing estimate
            case .gpt54: (5.00, 20.00) // GPT-5.4 pricing estimate
            case .gpt54Mini: (1.00, 4.00)
            case .gpt54Nano: (0.50, 2.00)
            case .gpt5: (5.00, 20.00) // GPT-5 pricing estimate
            case .gpt5Pro: (12.00, 48.00) // Higher reasoning budget
            case .gpt5Mini: (1.00, 4.00) // GPT-5 Mini pricing estimate
            case .gpt5Nano: (0.50, 2.00) // GPT-5 Nano pricing estimate
            case let .custom(id):
                switch LanguageModel.parse(from: id) {
                case .openai(.gpt6Astra): (10.00, 50.00)
                case .openai(.gpt6Sol): (2.00, 10.00)
                case .openai(.gpt6Luna): (0.10, 0.50)
                case .openai(.gpt56Sol): (5.00, 30.00)
                case .openai(.gpt56Terra): (2.50, 15.00)
                case .openai(.gpt56Luna): (1.00, 6.00)
                default: (2.50, 10.00) // Default estimate
                }
            }
        // Anthropic Pricing (as of 2026)
        case let .anthropic(anthropicModel):
            switch anthropicModel {
            case .opus5: (5.00, 25.00)
            case .fable5: (10.00, 50.00)
            case .sonnet5: self.sonnet5Pricing()
            case .opus48: (5.00, 25.00)
            case .opus47: (5.00, 25.00)
            case .opus45: (5.00, 25.00)
            case .opus4: (15.00, 75.00)
            case .sonnet46: (3.00, 15.00)
            case .sonnet45: (4.00, 18.00)
            case .haiku45: (1.20, 6.00)
            case let .custom(id):
                if LanguageModel.Anthropic.isOpus5(modelId: id) {
                    (5.00, 25.00)
                } else if LanguageModel.Anthropic.isFable(modelId: id) {
                    (10.00, 50.00)
                } else if LanguageModel.Anthropic.isSonnet5(modelId: id) {
                    self.sonnet5Pricing()
                } else {
                    (3.00, 15.00)
                }
            }
        // Google Pricing (standard tier, as of 2026)
        case let .google(googleModel):
            switch googleModel {
            case .gemini35Flash: (1.50, 9.00)
            case .gemini31ProPreview: (1.25, 10.00)
            case .gemini31FlashLite: (0.10, 0.40)
            case .gemini3Flash: (0.50, 3.00)
            case .gemini25Pro: (1.25, 10.00)
            case .gemini25Flash: (0.30, 2.50)
            case .gemini25FlashLite: (0.10, 0.40)
            }
        // Other providers - estimates
        case .mistral: (2.00, 6.00)
        case .groq: (0.27, 0.27) // Groq has very low pricing
        case let .grok(grokModel):
            switch grokModel {
            case .grok43, .grok420MultiAgent, .grok420Reasoning, .grok420NonReasoning: (1.25, 2.50)
            case .custom: (2.00, 8.00)
            }
        case .minimax, .minimaxCN: (0.30, 1.20)
        case let .kimi(kimiModel):
            switch kimiModel {
            case .k27CodeHighspeed: (1.90, 8.00)
            case .k27Code, .k26: (0.95, 4.00)
            }
        case .ollama: (0.00, 0.00) // Local inference
        case .lmstudio: (0.00, 0.00) // Local inference
        case .openRouter, .together, .replicate: (1.00, 3.00) // Typical aggregator pricing
        case .openaiCompatible, .anthropicCompatible, .azureOpenAI: (2.00, 6.00)
        case .custom: (2.00, 6.00)
        }
    }

    private func sonnet5Pricing() -> (input: Double, output: Double) {
        self.now() < Self.sonnet5StandardPricingStart ? (2.00, 10.00) : (3.00, 15.00)
    }
}
