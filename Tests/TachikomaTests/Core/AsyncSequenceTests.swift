import Testing
@testable import Tachikoma

struct AsyncSequenceTests {
    @Test
    func `StreamTextResult exposes an AsyncSequence`() async throws {
        // Create a test stream
        let testStream = AsyncThrowingStream<TextStreamDelta, Error> { continuation in
            Task {
                continuation.yield(TextStreamDelta(type: .textDelta, content: "Hello"))
                continuation.yield(TextStreamDelta(type: .textDelta, content: " "))
                continuation.yield(TextStreamDelta(type: .textDelta, content: "World"))
                continuation.yield(TextStreamDelta(type: .done))
                continuation.finish()
            }
        }

        let result = StreamTextResult(
            stream: testStream,
            model: .openai(.gpt55),
            settings: .default,
        )

        // Test AsyncSequence iteration
        var contents: [String] = []
        for try await delta in result.stream {
            if case .textDelta = delta.type, let content = delta.content {
                contents.append(content)
            }
        }

        #expect(contents == ["Hello", " ", "World"])
    }

    @Test
    func `StreamTextResult stream yields terminal events`() async throws {
        let testStream = AsyncThrowingStream<TextStreamDelta, Error> { continuation in
            Task {
                for i in 1...3 {
                    continuation.yield(TextStreamDelta(type: .textDelta, content: "Item \(i)"))
                }
                continuation.yield(TextStreamDelta(type: .done))
                continuation.finish()
            }
        }

        let result = StreamTextResult(
            stream: testStream,
            model: .anthropic(.opus4),
            settings: .default,
        )

        // Test with for-await-in loop
        var count = 0
        for try await _ in result.stream {
            count += 1
        }
        #expect(count == 4) // 3 text deltas + 1 done
    }

    @Test
    func `StreamObjectResult conforms to AsyncSequence`() async throws {
        struct TestData: Codable, Sendable, Equatable {
            let value: Int
        }

        let testStream = AsyncThrowingStream<ObjectStreamDelta<TestData>, Error> { continuation in
            Task {
                continuation.yield(ObjectStreamDelta(type: .start))
                continuation.yield(ObjectStreamDelta(
                    type: .partial,
                    object: TestData(value: 1),
                ))
                continuation.yield(ObjectStreamDelta(
                    type: .partial,
                    object: TestData(value: 2),
                ))
                continuation.yield(ObjectStreamDelta(
                    type: .complete,
                    object: TestData(value: 3),
                ))
                continuation.yield(ObjectStreamDelta(type: .done))
                continuation.finish()
            }
        }

        let result = StreamObjectResult(
            objectStream: testStream,
            model: .openai(.gpt55),
            settings: .default,
            schema: TestData.self,
        )

        // Test AsyncSequence iteration
        var deltaTypes: [ObjectStreamDelta<TestData>.DeltaType] = []
        for try await delta in result {
            deltaTypes.append(delta.type)
        }

        #expect(deltaTypes == [.start, .partial, .partial, .complete, .done])
    }

    @Test
    func `AsyncSequence works with standard operators`() async throws {
        let testStream = AsyncThrowingStream<TextStreamDelta, Error> { continuation in
            Task {
                for i in 1...5 {
                    continuation.yield(TextStreamDelta(
                        type: .textDelta,
                        content: String(i),
                    ))
                }
                continuation.yield(TextStreamDelta(type: .done))
                continuation.finish()
            }
        }

        let result = StreamTextResult(
            stream: testStream,
            model: .openai(.gpt55),
            settings: .default,
        )

        // Test with compactMap
        let numbers = try await result.stream.compactMap { delta -> Int? in
            guard
                case .textDelta = delta.type,
                let content = delta.content,
                let num = Int(content) else
            {
                return nil
            }
            return num
        }.reduce(0, +)

        #expect(numbers == 15) // 1+2+3+4+5
    }

    @Test
    func `AsyncSequence handles errors properly`() async throws {
        struct TestError: Error {}

        let testStream = AsyncThrowingStream<TextStreamDelta, Error> { continuation in
            Task {
                continuation.yield(TextStreamDelta(type: .textDelta, content: "Start"))
                continuation.finish(throwing: TestError())
            }
        }

        let result = StreamTextResult(
            stream: testStream,
            model: .openai(.gpt55),
            settings: .default,
        )

        var receivedError = false
        do {
            for try await _ in result.stream {
                // Process deltas
            }
        } catch {
            receivedError = true
        }

        #expect(receivedError)
    }

    @Test
    func `AsyncSequence can be cancelled mid-iteration`() async {
        let testStream = AsyncThrowingStream<TextStreamDelta, Error> { continuation in
            let producer = Task {
                do {
                    for i in 1...100 {
                        try await Task.sleep(nanoseconds: 1_000_000) // 1ms
                        continuation.yield(TextStreamDelta(
                            type: .textDelta,
                            content: "Item \(i)",
                        ))
                    }
                    continuation.yield(TextStreamDelta(type: .done))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }

        let result = StreamTextResult(
            stream: testStream,
            model: .openai(.gpt55),
            settings: .default,
        )

        // Start iteration and cancel after a few items
        let task = Task {
            var count = 0
            for try await _ in result.stream {
                count += 1
                if count >= 5 {
                    break // Early termination
                }
            }
            return count
        }

        let count = await (try? task.value) ?? 0
        #expect(count == 5)
    }

    @Test
    func `StreamTextResult extension methods work with AsyncSequence`() async throws {
        let testStream = AsyncThrowingStream<TextStreamDelta, Error> { continuation in
            Task {
                continuation.yield(TextStreamDelta(type: .textDelta, content: "Hello"))
                continuation.yield(TextStreamDelta(type: .reasoning, content: "Thinking...", channel: .thinking))
                continuation.yield(TextStreamDelta(type: .textDelta, content: " World", channel: .thinking))
                continuation.yield(TextStreamDelta(type: .textDelta, content: " Done", channel: .final))
                continuation.yield(TextStreamDelta(type: .done))
                continuation.finish()
            }
        }

        let result = StreamTextResult(
            stream: testStream,
            model: .openai(.gpt55),
            settings: .default,
        )

        // Test collectText extension
        var texts: [String] = []
        for try await text in result.collectText() {
            texts.append(text)
        }

        #expect(texts.contains("Hello"))
        #expect(texts.contains(" Done"))
        #expect(texts.contains(" World")) // From thinking channel
    }

    @Test
    func `StreamObjectResult extension methods work with AsyncSequence`() async throws {
        struct TestItem: Codable, Sendable, Equatable {
            let id: Int
            let name: String
        }

        let testStream = AsyncThrowingStream<ObjectStreamDelta<TestItem>, Error> { continuation in
            Task {
                continuation.yield(ObjectStreamDelta(type: .start))
                continuation.yield(ObjectStreamDelta(
                    type: .partial,
                    object: TestItem(id: 1, name: "First"),
                ))
                continuation.yield(ObjectStreamDelta(
                    type: .partial,
                    object: TestItem(id: 2, name: "Second"),
                ))
                continuation.yield(ObjectStreamDelta(
                    type: .complete,
                    object: TestItem(id: 3, name: "Final"),
                ))
                continuation.yield(ObjectStreamDelta(type: .done))
                continuation.finish()
            }
        }

        let result = StreamObjectResult(
            objectStream: testStream,
            model: .openai(.gpt55),
            settings: .default,
            schema: TestItem.self,
        )

        // Test partialObjects extension
        var partialItems: [TestItem] = []
        for try await item in result.partialObjects() {
            partialItems.append(item)
        }

        #expect(partialItems.count == 2)
        #expect(partialItems[0].name == "First")
        #expect(partialItems[1].name == "Second")
    }
}
