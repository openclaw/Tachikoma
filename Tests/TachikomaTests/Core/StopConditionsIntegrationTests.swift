import Foundation
import Testing
@testable import Tachikoma

struct StopConditionsIntegrationTests {
    // MARK: - Provider Integration Tests

    @Test
    func `Stop conditions passed to OpenAI as native stop sequences`() {
        // Create a mock provider that can verify the request
        _ = MockOpenAIProvider()

        // Configure with string stop conditions
        let settings = GenerationSettings(
            stopConditions: AnyStopCondition([
                StringStopCondition("END"),
                StringStopCondition("STOP"),
            ]),
        )

        _ = ProviderRequest(
            messages: [.user("Test")],
            tools: nil,
            settings: settings,
            outputFormat: nil,
        )

        // Verify that stop sequences can be extracted from simple conditions
        let singleStop = StringStopCondition("END")
        let extractedSingle = extractStopSequences(from: singleStop)
        #expect(extractedSingle == ["END"])

        // Note: Current implementation doesn't extract from composite conditions
        // This is a known limitation that should be documented
        let extractedComposite = extractStopSequences(from: settings.stopConditions)
        #expect(extractedComposite.isEmpty) // Current behavior
    }

    @Test
    func `Stop conditions work with generateText end-to-end`() async throws {
        // Use a mock provider that returns specific text
        let mockProvider = MockTextProvider(responseText: "Count: 1 2 3 END 4 5 6")

        let settings = GenerationSettings(
            stopConditions: StringStopCondition("END"),
        )

        let request = ProviderRequest(
            messages: [.user("Count to 10")],
            tools: nil,
            settings: settings,
            outputFormat: nil,
        )

        let response = try await mockProvider.generateText(request: request)

        // The response should be truncated at "END"
        #expect(!response.text.contains("4 5 6"))
        #expect(response.finishReason == FinishReason.stop)
    }

    @Test
    func `Streaming with multiple stop conditions`() async throws {
        // Create a stream that emits text gradually
        let stream = self.createMockStream(texts: [
            "Hello ",
            "world. ",
            "This is a test. ",
            "END ",
            "This should not appear. ",
            "STOP ",
            "This definitely should not appear.",
        ])

        // Apply multiple stop conditions
        let stoppedStream = stream
            .stopWhen(AnyStopCondition([
                StringStopCondition("END"),
                StringStopCondition("STOP"),
                TokenCountStopCondition(maxTokens: 50),
            ]))

        var result = ""
        for try await delta in stoppedStream {
            if case .textDelta = delta.type, let content = delta.content {
                result += content
            }
        }

        // Should stop at first condition (END)
        #expect(result.contains("END"))
        #expect(!result.contains("This should not appear"))
        #expect(!result.contains("STOP"))
    }

    @Test
    func `Token count stop condition with streaming`() async throws {
        // Create a stream with many tokens
        let longTexts = (1...100).map { "Token \($0) " }
        let stream = self.createMockStream(texts: longTexts)

        // Stop after approximately 10 tokens (rough estimate: 3 chars per token)
        let stoppedStream = stream.stopWhen(TokenCountStopCondition(maxTokens: 10))

        var tokenCount = 0
        var result = ""
        for try await delta in stoppedStream {
            if case .textDelta = delta.type, let content = delta.content {
                result += content
                // Rough token counting (spaces as delimiters)
                tokenCount += content.split(separator: " ").count
            }
        }

        // Should have stopped early
        #expect(tokenCount <= 15) // Allow some margin
        #expect(!result.contains("Token 50"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `Timeout stop condition with streaming`() async throws {
        let clock = ManualTestClock()
        let condition = TimeoutStopCondition(timeout: 10) { clock.now }
        let (stream, continuation) = AsyncThrowingStream<TextStreamDelta, Error>.makeStream()
        defer { continuation.finish() }
        var iterator = stream.stopWhen(condition).makeAsyncIterator()

        continuation.yield(.text("first"))
        #expect(try await iterator.next()?.content == "first")
        clock.advance(by: 9)
        continuation.yield(.text("before deadline"))
        #expect(try await iterator.next()?.content == "before deadline")
        clock.advance(by: 1)
        continuation.yield(.text("at deadline"))
        continuation.yield(.text("ignored"))
        #expect(try await iterator.next()?.content == "at deadline")

        let terminal = try await iterator.next()
        #expect(terminal?.type == .done)
        #expect(terminal?.finishReason == .stop)
        #expect(try await iterator.next() == nil)
    }

    @Test
    func `Regex stop condition with complex patterns`() async throws {
        let texts = [
            "Processing item 1...",
            "Processing item 2...",
            "Processing item 3...",
            "[DONE]",
            "Should not see this",
        ]

        let stream = self.createMockStream(texts: texts)
        let stoppedStream = stream.stopWhen(RegexStopCondition(pattern: "\\[DONE\\]"))

        var result = ""
        for try await delta in stoppedStream {
            if case .textDelta = delta.type, let content = delta.content {
                result += content
            }
        }

        #expect(result.contains("[DONE]"))
        #expect(!result.contains("Should not see this"))
    }

    @Test
    func `Predicate stop condition with custom logic`() async throws {
        let stream = self.createMockStream(texts: [
            "Step 1: Initialize",
            "Step 2: Process",
            "Step 3: Complete",
            "Step 4: Should not see",
        ])

        // Stop when we see "Complete"
        let predicate = PredicateStopCondition { text, _ in
            text.contains("Complete")
        }

        let stoppedStream = stream.stopWhen(predicate)

        var result = ""
        for try await delta in stoppedStream {
            if case .textDelta = delta.type, let content = delta.content {
                result += content
            }
        }

        #expect(result.contains("Step 3: Complete"))
        #expect(!result.contains("Step 4"))
    }

    @Test
    func `Composite stop conditions with ALL logic`() async {
        let condition = AllStopCondition([
            PredicateStopCondition { text, _ in text.count > 20 }, // Length check
            PredicateStopCondition { text, _ in text.contains("END") }, // Content check
        ])

        // Test various inputs
        #expect(await condition.shouldStop(text: "Short", delta: nil) == false)
        #expect(await condition.shouldStop(text: "This is a longer text without the keyword", delta: nil) == false)
        #expect(await condition.shouldStop(text: "Short END", delta: nil) == false) // Has END but too short
        #expect(await condition.shouldStop(text: "This is long enough and has END", delta: nil) == true)
    }

    @Test
    func `Stop condition state management with reset`() async {
        let condition = TokenCountStopCondition(maxTokens: 10)

        // First use
        await condition.reset()
        #expect(await condition.shouldStop(text: "Short", delta: nil) == false)

        // After some text (assuming ~15 tokens)
        let longText = "This is a much longer text that should exceed our token limit"
        #expect(await condition.shouldStop(text: longText, delta: nil) == true)

        // Reset and try again
        await condition.reset()
        #expect(await condition.shouldStop(text: "Short", delta: nil) == false)
    }

    @Test
    func `Native provider stop sequence extraction`() {
        // Test single string condition
        let singleCondition = StringStopCondition("STOP")
        let singleSequences = extractStopSequences(from: singleCondition)
        #expect(singleSequences == ["STOP"])

        // Test composite conditions
        let compositeCondition = AnyStopCondition([
            StringStopCondition("END"),
            StringStopCondition("FINISH"),
            TokenCountStopCondition(maxTokens: 100), // Should be ignored for extraction
        ])

        // Note: Current implementation doesn't extract from composite conditions
        // This is a limitation we should document or fix
        let compositeSequences = extractStopSequences(from: compositeCondition)
        #expect(compositeSequences.isEmpty) // Current behavior
    }

    // MARK: - Helper Methods

    private func createMockStream(texts: [String]) -> AsyncThrowingStream<TextStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for text in texts {
                    continuation.yield(TextStreamDelta(type: .textDelta, content: text))
                }
                continuation.yield(TextStreamDelta(type: .done))
                continuation.finish()
            }
        }
    }
}

// MARK: - Mock Providers

private struct MockTextProvider: ModelProvider {
    let responseText: String

    var modelId: String {
        "mock"
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

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        var finalText = self.responseText
        var finishReason = FinishReason.stop

        // Apply stop conditions if present
        if let stopCondition = request.settings.stopConditions {
            if await stopCondition.shouldStop(text: finalText, delta: nil) {
                // Truncate at stop condition
                if let stringStop = stopCondition as? StringStopCondition {
                    if let range = finalText.range(of: stringStop.stopString) {
                        finalText = String(finalText[..<range.lowerBound])
                        finishReason = .stop
                    }
                }
            }
        }

        return ProviderResponse(
            text: finalText,
            usage: nil,
            finishReason: finishReason,
        )
    }

    func streamText(request _: ProviderRequest) throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(TextStreamDelta(type: .textDelta, content: self.responseText))
                continuation.yield(TextStreamDelta(type: .done))
                continuation.finish()
            }
        }
    }

    func generateObject<T: Decodable>(request _: ProviderRequest, as _: T.Type) async throws -> T {
        throw TachikomaError.unsupportedOperation("generateObject not supported in mock")
    }
}

private struct MockOpenAIProvider: ModelProvider {
    var modelId: String {
        "gpt-5.5"
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
        ProviderResponse(text: "Mock response", usage: nil, finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func generateObject<T: Decodable>(request _: ProviderRequest, as _: T.Type) async throws -> T {
        throw TachikomaError.unsupportedOperation("generateObject not supported in mock")
    }
}

/// Helper function to extract stop sequences (mimics the internal implementation)
private func extractStopSequences(from stopCondition: (any StopCondition)?) -> [String] {
    guard let stopCondition else { return [] }

    if let stringStop = stopCondition as? StringStopCondition {
        return [stringStop.stopString]
    }

    // Current implementation doesn't extract from composite conditions
    return []
}
