import Algorithms
import Foundation

// MARK: - Stop Conditions for Generation Control

/// Protocol for conditions that can stop generation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public protocol StopCondition: Sendable {
    /// Check if generation should stop based on the current text
    func shouldStop(text: String, delta: String?) async -> Bool

    /// Reset any internal state
    func reset() async
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
protocol StableCacheKeyStopCondition {
    var stableCacheKey: String? { get }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
private func compositeStableCacheKey(kind: String, children: [String]) -> String {
    let encodedChildren = children.map { "\($0.utf8.count):\($0)" }.joined()
    return "\(kind):[\(encodedChildren)]"
}

// MARK: - Built-in Stop Conditions

/// Stop when a specific string is encountered
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct StringStopCondition: StopCondition {
    // Check if generation should stop based on the current text
    public let stopString: String
    public let caseSensitive: Bool

    public init(_ stopString: String, caseSensitive: Bool = true) {
        self.stopString = stopString
        self.caseSensitive = caseSensitive
    }

    public func shouldStop(text: String, delta: String?) async -> Bool {
        if self.caseSensitive {
            text.contains(self.stopString) || (delta?.contains(self.stopString) ?? false)
        } else {
            text.lowercased().contains(self.stopString.lowercased()) ||
                (delta?.lowercased().contains(self.stopString.lowercased()) ?? false)
        }
    }

    public func reset() async {}
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension StringStopCondition: StableCacheKeyStopCondition {
    var stableCacheKey: String? {
        "string:\(self.caseSensitive):\(self.stopString)"
    }
}

/// Stop when a regex pattern is matched
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct RegexStopCondition: StopCondition {
    private let pattern: String
    private let regex: NSRegularExpression?

    public init(pattern: String) {
        self.pattern = pattern
        self.regex = try? NSRegularExpression(pattern: pattern, options: [])
    }

    public func shouldStop(text: String, delta: String?) async -> Bool {
        guard let regex else { return false }

        let range = NSRange(location: 0, length: text.utf16.count)
        if regex.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }

        if let delta {
            let deltaRange = NSRange(location: 0, length: delta.utf16.count)
            return regex.firstMatch(in: delta, options: [], range: deltaRange) != nil
        }

        return false
    }

    public func reset() async {}

    /// Get the location of the first match in the text (for truncation)
    public func matchLocation(in text: String) -> Range<String.Index>? {
        // Get the location of the first match in the text (for truncation)
        guard let regex else { return nil }

        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        return Range(match.range, in: text)
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension RegexStopCondition: StableCacheKeyStopCondition {
    var stableCacheKey: String? {
        "regex:\(self.pattern)"
    }
}

/// Stop after a certain number of tokens
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public actor TokenCountStopCondition: StopCondition {
    private let maxTokens: Int
    private var currentTokens: Int = 0

    public init(maxTokens: Int) {
        self.maxTokens = maxTokens
    }

    public func shouldStop(text: String, delta: String?) async -> Bool {
        // Approximate token counting (4 chars ≈ 1 token)
        // This is a rough approximation that works for testing
        if let delta, !delta.isEmpty {
            // Count based on character count, with minimum of 1 token
            let tokenEstimate = max(1, (delta.count + 3) / 4) // Round up by adding 3
            self.currentTokens += tokenEstimate
        } else if !text.isEmpty {
            // For full text, recalculate from scratch
            self.currentTokens = max(1, text.count / 4)
        }
        return self.currentTokens >= self.maxTokens
    }

    public func reset() async {
        self.currentTokens = 0
    }
}

/// Stop after a certain duration
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public actor TimeoutStopCondition: StopCondition {
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private var startTime: Date?

    public init(timeout: TimeInterval) {
        self.timeout = timeout
        self.now = { Date() }
    }

    init(timeout: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.timeout = timeout
        self.now = now
    }

    public func shouldStop(text _: String, delta _: String?) async -> Bool {
        if startTime == nil {
            startTime = self.now()
        }

        guard let startTime else { return false }
        return self.now().timeIntervalSince(startTime) >= self.timeout
    }

    public func reset() async {
        self.startTime = nil
    }
}

/// Stop when a custom predicate returns true
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct PredicateStopCondition: StopCondition {
    private let predicate: @Sendable (String, String?) async -> Bool

    public init(predicate: @escaping @Sendable (String, String?) async -> Bool) {
        self.predicate = predicate
    }

    public func shouldStop(text: String, delta: String?) async -> Bool {
        await self.predicate(text, delta)
    }

    public func reset() async {}
}

// MARK: - Composite Stop Conditions

/// Stop when any of the conditions are met
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct AnyStopCondition: StopCondition {
    private let conditions: [any StopCondition]

    public init(_ conditions: [any StopCondition]) {
        self.conditions = conditions
    }

    public init(_ conditions: any StopCondition...) {
        self.conditions = conditions
    }

    public func shouldStop(text: String, delta: String?) async -> Bool {
        for condition in self.conditions {
            if await condition.shouldStop(text: text, delta: delta) {
                return true
            }
        }
        return false
    }

    public func reset() async {
        for condition in self.conditions {
            await condition.reset()
        }
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension AnyStopCondition: StableCacheKeyStopCondition {
    var stableCacheKey: String? {
        let keys = self.conditions.compactMap { ($0 as? StableCacheKeyStopCondition)?.stableCacheKey }
        guard keys.count == self.conditions.count else { return nil }
        return compositeStableCacheKey(kind: "any", children: keys)
    }
}

/// Stop when all conditions are met
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct AllStopCondition: StopCondition {
    private let conditions: [any StopCondition]

    public init(_ conditions: [any StopCondition]) {
        self.conditions = conditions
    }

    public init(_ conditions: any StopCondition...) {
        self.conditions = conditions
    }

    public func shouldStop(text: String, delta: String?) async -> Bool {
        for condition in self.conditions {
            if await !condition.shouldStop(text: text, delta: delta) {
                return false
            }
        }
        return true
    }

    public func reset() async {
        for condition in self.conditions {
            await condition.reset()
        }
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension AllStopCondition: StableCacheKeyStopCondition {
    var stableCacheKey: String? {
        let keys = self.conditions.compactMap { ($0 as? StableCacheKeyStopCondition)?.stableCacheKey }
        guard keys.count == self.conditions.count else { return nil }
        return compositeStableCacheKey(kind: "all", children: keys)
    }
}

// MARK: - Stateful Stop Conditions

/// Stop when a pattern appears consecutively N times
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public actor ConsecutivePatternStopCondition: StopCondition {
    private let pattern: String
    private let requiredCount: Int
    private var currentCount: Int = 0
    private var lastText: String = ""

    public init(pattern: String, count: Int) {
        self.pattern = pattern
        self.requiredCount = count
    }

    public func shouldStop(text: String, delta: String?) async -> Bool {
        // Count new occurrences in the delta
        if let delta {
            let newOccurrences = delta.components(separatedBy: self.pattern).count - 1
            self.currentCount += newOccurrences
        } else {
            // Full text check
            let occurrences = text.components(separatedBy: self.pattern).count - 1
            self.currentCount = occurrences
        }

        self.lastText = text
        return self.currentCount >= self.requiredCount
    }

    public func reset() async {
        self.currentCount = 0
        self.lastText = ""
    }
}

/// Stop when the model starts repeating itself
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public actor RepetitionStopCondition: StopCondition {
    private let windowSize: Int
    private let threshold: Double
    private var recentChunks: [String] = []

    public init(windowSize: Int = 50, threshold: Double = 0.8) {
        self.windowSize = windowSize
        self.threshold = threshold
    }

    public func shouldStop(text _: String, delta: String?) async -> Bool {
        guard let delta, !delta.isEmpty else { return false }

        // Add new chunk
        self.recentChunks.append(delta)

        // Keep only recent chunks (use windowSize for the window)
        while self.recentChunks.joined().count > self.windowSize, self.recentChunks.count > 1 {
            self.recentChunks.removeFirst()
        }

        // Check for repetition
        guard self.recentChunks.count >= 2 else { return false }

        // Check if the last chunk is exactly the same as any previous chunk
        let lastChunk = self.recentChunks.last!
        let priorChunks = self.recentChunks.dropLast()
        let exactMatchCount = priorChunks.count { $0 == lastChunk }

        // For exact repetition: if we see the same chunk twice in a row, it's repetition
        if exactMatchCount >= 1 {
            return true
        }

        // Also check for high similarity with flexible threshold
        let similarCount = priorChunks.count { self.similarity($0, lastChunk) >= self.threshold }

        // Stop if more than half of recent chunks are similar
        return priorChunks.count >= 2 && Double(similarCount) / Double(priorChunks.count) > 0.5
    }

    private func similarity(_ s1: String, _ s2: String) -> Double {
        guard !s1.isEmpty, !s2.isEmpty else { return 0 }

        // If strings are exactly the same, return 1.0
        if s1 == s2 {
            return 1.0
        }

        // Calculate Jaccard similarity based on characters
        let set1 = Set(s1)
        let set2 = Set(s2)
        let intersection = set1.intersection(set2).count
        let union = set1.union(set2).count

        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    public func reset() async {
        self.recentChunks = []
    }
}

// MARK: - Stop Condition Builder

/// Builder for creating stop conditions fluently
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct StopConditionBuilder {
    private var conditions: [any StopCondition] = []

    public init() {}

    /// Stop when a string is encountered
    public func whenContains(_ text: String, caseSensitive: Bool = true) -> StopConditionBuilder {
        // Stop when a string is encountered
        var builder = self
        builder.conditions.append(StringStopCondition(text, caseSensitive: caseSensitive))
        return builder
    }

    /// Stop when a regex pattern matches
    public func whenMatches(_ pattern: String) -> StopConditionBuilder {
        // Stop when a regex pattern matches
        var builder = self
        builder.conditions.append(RegexStopCondition(pattern: pattern))
        return builder
    }

    /// Stop after N tokens
    public func afterTokens(_ count: Int) -> StopConditionBuilder {
        // Stop after N tokens
        var builder = self
        builder.conditions.append(TokenCountStopCondition(maxTokens: count))
        return builder
    }

    /// Stop after a timeout
    public func afterTime(_ seconds: TimeInterval) -> StopConditionBuilder {
        // Stop after a timeout
        var builder = self
        builder.conditions.append(TimeoutStopCondition(timeout: seconds))
        return builder
    }

    /// Stop when custom predicate is true
    public func when(_ predicate: @escaping @Sendable (String, String?) async -> Bool) -> StopConditionBuilder {
        // Stop when custom predicate is true
        var builder = self
        builder.conditions.append(PredicateStopCondition(predicate: predicate))
        return builder
    }

    /// Build the final condition
    public func build() -> any StopCondition {
        // Build the final condition
        switch self.conditions.count {
        case 0:
            NeverStopCondition()
        case 1:
            self.conditions[0]
        default:
            AnyStopCondition(self.conditions)
        }
    }
}

/// A condition that never stops (used as default)
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct NeverStopCondition: StopCondition {
    public init() {}

    public func shouldStop(text _: String, delta _: String?) async -> Bool {
        false
    }

    public func reset() async {}
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension NeverStopCondition: StableCacheKeyStopCondition {
    var stableCacheKey: String? {
        "never"
    }
}

// MARK: - Integration with Generation Functions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension GenerationSettings {
    /// Create settings with stop conditions
    public static func withStopConditions(
        _ conditions: any StopCondition...,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        seed: Int? = nil,
    )
        -> GenerationSettings
    {
        // Create settings with stop conditions
        GenerationSettings(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            stopConditions: conditions.isEmpty ? nil : AnyStopCondition(conditions),
            seed: seed,
        )
    }
}

// MARK: - Stream Extensions for Stop Conditions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension AsyncThrowingStream where Element == TextStreamDelta {
    /// Apply stop conditions to a text stream
    public func stopWhen(_ condition: any StopCondition) -> AsyncThrowingStream<Element, Error> {
        // Apply stop conditions to a text stream
        AsyncThrowingStream<Element, Error> { continuation in
            Task {
                var accumulatedText = ""
                await condition.reset()

                do {
                    for try await delta in self {
                        // Accumulate text
                        if case .textDelta = delta.type, let content = delta.content {
                            accumulatedText += content

                            // Check stop condition
                            if await condition.shouldStop(text: accumulatedText, delta: content) {
                                continuation.yield(delta)
                                continuation.yield(TextStreamDelta.done(finishReason: .stop))
                                continuation.finish()
                                return
                            }
                        }

                        // Continue streaming
                        continuation.yield(delta)

                        // Check for natural end
                        if case .done = delta.type {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension StreamTextResult {
    /// Apply stop conditions to the stream
    public func stopWhen(_ condition: any StopCondition) -> StreamTextResult {
        // Apply stop conditions to the stream
        StreamTextResult(
            stream: stream.stopWhen(condition),
            model: model,
            settings: settings,
        )
    }

    /// Convenience method for common stop patterns
    public func stopOnString(_ text: String, caseSensitive: Bool = true) -> StreamTextResult {
        // Convenience method for common stop patterns
        self.stopWhen(StringStopCondition(text, caseSensitive: caseSensitive))
    }

    public func stopOnPattern(_ pattern: String) -> StreamTextResult {
        self.stopWhen(RegexStopCondition(pattern: pattern))
    }

    public func stopAfterTokens(_ count: Int) -> StreamTextResult {
        self.stopWhen(TokenCountStopCondition(maxTokens: count))
    }

    public func stopAfterTime(_ seconds: TimeInterval) -> StreamTextResult {
        self.stopWhen(TimeoutStopCondition(timeout: seconds))
    }
}
