import Foundation
import Testing
@testable import Tachikoma

struct EmbeddingBatchTests {
    private let inputs: [EmbeddingInput] = (0..<4).map { .text(String($0)) }

    @Test(arguments: [0, -1, Int.min])
    func `invalid concurrency is rejected`(_ concurrency: Int) async {
        await #expect(throws: TachikomaError.self) {
            try await generateEmbeddingsBatch(
                model: .openai(.small3), inputs: [], concurrency: concurrency,
                configuration: TachikomaConfiguration(loadFromEnvironment: false),
            )
        }
    }

    @Test
    func `failure does not start queued requests`() async {
        let provider = BatchFixture(mode: .failure)
        await #expect(throws: BatchFixture.Failure.self) {
            try await generateEmbeddingsBatch(provider: provider, inputs: self.inputs, concurrency: 1)
        }
        #expect(await provider.requestCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `cancellation does not start queued requests`() async throws {
        let provider = BatchFixture(mode: .cancellation)
        let task = Task { try await generateEmbeddingsBatch(provider: provider, inputs: self.inputs, concurrency: 1) }
        defer { task.cancel() }
        var starts = provider.starts.makeAsyncIterator()
        _ = try #require(await starts.next())
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await provider.requestCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `concurrency is bounded and results follow input order`() async throws {
        let provider = BatchFixture(mode: .gated)
        let task = Task { try await generateEmbeddingsBatch(provider: provider, inputs: self.inputs, concurrency: 2) }
        defer {
            task.cancel()
            Task { await provider.releaseAll() }
        }
        var starts = provider.starts.makeAsyncIterator()
        let first = try #require(await starts.next())
        let second = try #require(await starts.next())
        await provider.release(second)
        let third = try #require(await starts.next())
        await provider.release(third)
        let fourth = try #require(await starts.next())
        await provider.release(fourth)
        await provider.release(first)
        let results = try await task.value
        #expect(results.map(\.embeddings) == (0..<4).map { [[Double($0)]] })
        #expect(await provider.maximumActive == 2)
        #expect(await provider.requestCount == 4)
    }

    @Test
    func `empty batch does not call provider`() async throws {
        let provider = BatchFixture(mode: .failure)
        let result = try await generateEmbeddingsBatch(provider: provider, inputs: [], concurrency: 5)
        #expect(result.isEmpty)
        #expect(await provider.requestCount == 0)
    }

    @Test
    func `cancelled caller does not call provider`() async {
        let provider = BatchFixture(mode: .failure)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await generateEmbeddingsBatch(provider: provider, inputs: self.inputs, concurrency: 2)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await provider.requestCount == 0)
    }
}

private actor BatchFixture: EmbeddingProvider {
    enum Mode { case failure, cancellation, gated }
    struct Failure: Error {}
    let mode: Mode
    nonisolated let starts: AsyncStream<Int>
    private let startSignal: AsyncStream<Int>.Continuation
    private let gates: [AsyncStream<Void>]
    private let releases: [AsyncStream<Void>.Continuation]
    private(set) var requestCount = 0
    private(set) var maximumActive = 0
    private var active = 0

    init(mode: Mode) {
        self.mode = mode
        (self.starts, self.startSignal) = AsyncStream<Int>.makeStream()
        let pairs = (0..<4).map { _ in AsyncStream<Void>.makeStream() }
        self.gates = pairs.map(\.stream)
        self.releases = pairs.map(\.continuation)
    }

    func generateEmbedding(request: EmbeddingRequest) async throws -> EmbeddingResult {
        guard case let .text(text) = request.input, let index = Int(text) else { throw Failure() }
        self.requestCount += 1
        self.active += 1
        self.maximumActive = max(self.maximumActive, self.active)
        self.startSignal.yield(index)
        defer { self.active -= 1 }
        switch self.mode {
        case .failure: throw Failure()
        case .cancellation: try await Task.sleep(for: .seconds(600))
        case .gated:
            for await _ in self.gates[index] {
                break
            }
            try Task.checkCancellation()
        }
        return EmbeddingResult(embeddings: [[Double(index)]], model: "fixture")
    }

    func release(_ index: Int) {
        self.releases[index].finish()
    }

    func releaseAll() {
        self.releases.forEach { $0.finish() }
    }
}
