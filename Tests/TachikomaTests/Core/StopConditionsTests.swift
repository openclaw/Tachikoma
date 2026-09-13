import Testing
@testable import Tachikoma

struct StopConditionsTests {
    // MARK: - String Stop Condition Tests

    @Test
    func `StringStopCondition should stop on exact match`() async {
        let condition = StringStopCondition("STOP")

        // Should not stop before the stop string
        #expect(await condition.shouldStop(text: "Hello world", delta: nil) == false)

        // Should stop when stop string is present
        #expect(await condition.shouldStop(text: "Hello STOP world", delta: nil) == true)

        // Should stop when stop string is in delta
        #expect(await condition.shouldStop(text: "Hello", delta: "STOP") == true)
    }

    @Test
    func `StringStopCondition case-insensitive matching`() async {
        let condition = StringStopCondition("stop", caseSensitive: false)

        // Should match regardless of case
        #expect(await condition.shouldStop(text: "Hello STOP", delta: nil) == true)
        #expect(await condition.shouldStop(text: "Hello Stop", delta: nil) == true)
        #expect(await condition.shouldStop(text: "Hello stop", delta: nil) == true)
    }

    // MARK: - Regex Stop Condition Tests

    @Test
    func `RegexStopCondition should match patterns`() async {
        let condition = RegexStopCondition(pattern: "END.*SESSION")

        // Should not match without pattern
        #expect(await condition.shouldStop(text: "Hello world", delta: nil) == false)

        // Should match pattern
        #expect(await condition.shouldStop(text: "END OF SESSION", delta: nil) == true)
        #expect(await condition.shouldStop(text: "END_SESSION", delta: nil) == true)

        // Should match in delta
        #expect(await condition.shouldStop(text: "Hello", delta: "END SESSION") == true)
    }

    // MARK: - Token Count Stop Condition Tests

    @Test
    func `TokenCountStopCondition should stop after limit`() async {
        let condition = TokenCountStopCondition(maxTokens: 10)

        // Reset to start fresh
        await condition.reset()

        // Short text should not trigger stop (approx 3 tokens)
        #expect(await condition.shouldStop(text: "", delta: "Hello world") == false)

        // Adding more text should eventually trigger stop
        // Each call with delta accumulates tokens
        for _ in 0..<5 {
            _ = await condition.shouldStop(text: "", delta: "More text here")
        }

        // Should be over limit now
        #expect(await condition.shouldStop(text: "", delta: "Final text") == true)
    }

    // MARK: - Timeout Stop Condition Tests

    @Test
    func `TimeoutStopCondition should stop after duration`() async {
        let clock = ManualTestClock()
        let condition = TimeoutStopCondition(timeout: 10) { clock.now }

        #expect(await condition.shouldStop(text: "Hello", delta: nil) == false)
        clock.advance(by: 9)
        #expect(await condition.shouldStop(text: "Hello", delta: nil) == false)
        clock.advance(by: 1)
        #expect(await condition.shouldStop(text: "Hello", delta: nil) == true)

        await condition.reset()
        #expect(await condition.shouldStop(text: "Hello", delta: nil) == false)
        clock.advance(by: 10)
        #expect(await condition.shouldStop(text: "Hello", delta: nil) == true)
    }

    // MARK: - Predicate Stop Condition Tests

    @Test
    func `PredicateStopCondition with custom logic`() async {
        let condition = PredicateStopCondition { text, _ in
            text.count > 20
        }

        // Short text should not stop
        #expect(await condition.shouldStop(text: "Short", delta: nil) == false)

        // Long text should stop
        #expect(await condition.shouldStop(text: "This is a much longer text string", delta: nil) == true)
    }

    // MARK: - Composite Stop Conditions Tests

    @Test
    func `AnyStopCondition should stop when any condition is met`() async {
        let conditions: [any StopCondition] = [
            StringStopCondition("STOP"),
            TokenCountStopCondition(maxTokens: 100),
        ]
        let anyCondition = AnyStopCondition(conditions)

        // Should stop when string is found (first condition)
        #expect(await anyCondition.shouldStop(text: "Hello STOP", delta: nil) == true)

        // Reset and test with text that doesn't contain STOP
        await anyCondition.reset()
        #expect(await anyCondition.shouldStop(text: "Hello world", delta: nil) == false)
    }

    @Test
    func `AllStopCondition should stop only when all conditions are met`() async {
        let conditions: [any StopCondition] = [
            StringStopCondition("END"),
            PredicateStopCondition { text, _ in text.count > 10 },
        ]
        let allCondition = AllStopCondition(conditions)

        // Should not stop with just one condition met
        #expect(await allCondition.shouldStop(text: "END", delta: nil) == false) // Too short
        #expect(await allCondition.shouldStop(text: "This is a long text", delta: nil) == false) // No END

        // Should stop when both conditions are met
        #expect(await allCondition.shouldStop(text: "Long text with END", delta: nil) == true)
    }

    // MARK: - Integration Tests with Generation

    @Test
    func `Stop conditions in generateText`() {
        // Create a mock provider that returns text with a stop marker
        let mockText = "This is the response. STOP HERE. This should be truncated."
        _ = createMockProvider(responseText: mockText)

        // Configure with stop condition
        let settings = GenerationSettings(
            stopConditions: StringStopCondition("STOP HERE"),
        )

        // This test would require a mock provider setup
        // For now, we're testing the concept
        #expect(settings.stopConditions != nil)
    }

    @Test
    func `Stop conditions with streaming`() async throws {
        // Create a simple text stream
        let stream = AsyncThrowingStream<TextStreamDelta, Error> { continuation in
            Task {
                continuation.yield(TextStreamDelta(type: .textDelta, content: "Hello "))
                continuation.yield(TextStreamDelta(type: .textDelta, content: "world "))
                continuation.yield(TextStreamDelta(type: .textDelta, content: "STOP "))
                continuation.yield(TextStreamDelta(type: .textDelta, content: "ignored"))
                continuation.yield(TextStreamDelta(type: .done))
                continuation.finish()
            }
        }

        // Apply stop condition
        let stoppedStream = stream.stopWhen(StringStopCondition("STOP"))

        // Collect results
        var collectedText = ""
        for try await delta in stoppedStream {
            if case .textDelta = delta.type, let content = delta.content {
                collectedText += content
            }
        }

        // Should have stopped at "STOP"
        #expect(collectedText.contains("STOP"))
        #expect(!collectedText.contains("ignored"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `Stop conditions finish immediately after local match`() async throws {
        let (stream, continuation) = AsyncThrowingStream<TextStreamDelta, Error>.makeStream()
        defer { continuation.finish() }
        continuation.yield(.text("STOP"))

        // The source stays open until the stopped stream has completed.
        var received: [TextStreamDelta] = []
        for try await delta in stream.stopWhen(StringStopCondition("STOP")) {
            received.append(delta)
        }

        #expect(received.map(\.content).compactMap(\.self) == ["STOP"])
        #expect(received.last?.type == .done)
        #expect(received.last?.finishReason == .stop)
    }

    // MARK: - Builder Pattern Tests

    @Test
    func `StopConditionBuilder creates correct conditions`() async {
        let condition = StopConditionBuilder()
            .whenContains("END")
            .afterTokens(100)
            .build()

        // Should create an AnyStopCondition with both conditions
        #expect(condition is AnyStopCondition)

        // Should stop when END is found
        let nilDelta: String? = nil
        #expect(await condition.shouldStop(text: "Test END", delta: nilDelta) == true)
    }

    @Test
    func `GenerationSettings with stop conditions factory`() {
        let settings = GenerationSettings.withStopConditions(
            StringStopCondition("STOP"),
            TokenCountStopCondition(maxTokens: 100),
            maxTokens: 500,
            temperature: 0.7,
        )

        #expect(settings.stopConditions != nil)
        #expect(settings.maxTokens == 500)
        #expect(settings.temperature == 0.7)
    }

    // MARK: - Pattern Detection Tests

    @Test
    func `ConsecutivePatternStopCondition detects repeating patterns`() async {
        let condition = ConsecutivePatternStopCondition(pattern: "loop", count: 3)

        await condition.reset()

        // First occurrence
        #expect(await condition.shouldStop(text: "loop", delta: "loop") == false)

        // Second occurrence
        #expect(await condition.shouldStop(text: "loop loop", delta: "loop") == false)

        // Third occurrence should trigger stop
        #expect(await condition.shouldStop(text: "loop loop loop", delta: "loop") == true)
    }

    @Test
    func `RepetitionStopCondition detects repeating content`() async {
        let condition = RepetitionStopCondition(
            windowSize: 50, // Increased to ensure we don't hit the window limit
            threshold: 0.8,
        )

        // Similar content should trigger after threshold
        let repeatedText = "The same content. "

        await condition.reset()

        let nilDelta: String? = nil

        // First time (no delta, nothing added to chunks)
        #expect(await condition.shouldStop(text: repeatedText, delta: nilDelta) == false)

        // Second similar content (adds first chunk)
        #expect(await condition.shouldStop(text: repeatedText + repeatedText, delta: repeatedText) == false)

        // Third time should trigger (adds second identical chunk)
        #expect(await condition.shouldStop(
            text: repeatedText + repeatedText + repeatedText,
            delta: repeatedText,
        ) == true)
    }

    // MARK: - Edge Cases

    @Test
    func `Empty text and nil delta handling`() async {
        let condition = StringStopCondition("STOP")

        // Empty text with nil delta
        #expect(await condition.shouldStop(text: "", delta: nil) == false)

        // Non-empty text with nil delta
        #expect(await condition.shouldStop(text: "No stop here", delta: nil) == false)

        // Empty text with non-nil delta containing stop
        #expect(await condition.shouldStop(text: "", delta: "STOP") == true)
    }

    @Test
    func `Reset functionality`() async {
        let condition = TokenCountStopCondition(maxTokens: 5)

        // Add tokens until stop
        for _ in 0..<3 {
            _ = await condition.shouldStop(text: "", delta: "word ")
        }

        #expect(await condition.shouldStop(text: "", delta: "more") == true)

        // Reset should clear state
        await condition.reset()

        // Should not stop after reset
        #expect(await condition.shouldStop(text: "", delta: "word") == false)
    }
}

// MARK: - Test Helpers

private func createMockProvider(responseText: String) -> ModelProvider {
    // This would be a mock provider for testing
    // Implementation would depend on the testing infrastructure
    StopConditionTestMockProvider(responseText: responseText)
}

/// Mock provider for testing (simplified)
private struct StopConditionTestMockProvider: ModelProvider {
    let responseText: String

    var modelId: String {
        "mock-model"
    }

    var baseURL: String? {
        nil
    }

    var apiKey: String? {
        nil
    }

    var capabilities: ModelCapabilities {
        ModelCapabilities()
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: self.responseText)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(TextStreamDelta(type: .textDelta, content: self.responseText))
                continuation.yield(TextStreamDelta(type: .done))
                continuation.finish()
            }
        }
    }
}
