import Foundation
import MCP
import Testing
@testable import TachikomaMCP

private actor AsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        guard !self.isOpen else { return }
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ReaderObservation {
    private(set) var firstGeneration: UInt64?
    private(set) var secondGeneration: UInt64?
    private(set) var firstReaderUsedExpectedTransport = false
    private(set) var secondReaderUsedExpectedTransport = false

    func recordFirst(transportMatches: Bool, generation: UInt64) {
        self.firstReaderUsedExpectedTransport = transportMatches
        self.firstGeneration = generation
    }

    func recordSecond(transportMatches: Bool, generation: UInt64) {
        self.secondReaderUsedExpectedTransport = transportMatches
        self.secondGeneration = generation
    }
}

@Suite("SSE transport lifecycle")
struct SSETransportTests {
    private enum TestFailure: Error {
        case streamClosed
    }

    @Test
    func `A superseded reader cannot mutate or fail replacement state`() async throws {
        let state = SSEState()
        let staleEndpoint = try #require(URL(string: "https://stale.example/rpc"))
        let currentEndpoint = try #require(URL(string: "https://current.example/rpc"))
        let firstTransport = HTTPClientTransport(endpoint: staleEndpoint, streaming: false)
        let secondTransport = HTTPClientTransport(endpoint: currentEndpoint, streaming: false)
        let firstStarted = AsyncLatch()
        let releaseFirst = AsyncLatch()
        let firstFinished = AsyncLatch()
        let secondFinished = AsyncLatch()
        let observation = ReaderObservation()

        let initialTransport = await state.installConnection(
            transport: firstTransport,
            timeoutNanoseconds: 30_000_000_000,
        ) { transport, generation in
            await firstStarted.open()
            await releaseFirst.wait()
            await observation.recordFirst(
                transportMatches: transport === firstTransport,
                generation: generation,
            )
            await firstFinished.open()
        }
        #expect(initialTransport == nil)
        await firstStarted.wait()

        let replacedTransport = await state.installConnection(
            transport: secondTransport,
            timeoutNanoseconds: 30_000_000_000,
        ) { transport, generation in
            await observation.recordSecond(
                transportMatches: transport === secondTransport,
                generation: generation,
            )
            await secondFinished.open()
        }
        #expect(replacedTransport === firstTransport)
        await releaseFirst.open()
        await firstFinished.wait()
        await secondFinished.wait()

        let firstGeneration = try #require(await observation.firstGeneration)
        let secondGeneration = try #require(await observation.secondGeneration)
        #expect(await observation.firstReaderUsedExpectedTransport)
        #expect(await observation.secondReaderUsedExpectedTransport)
        #expect(firstGeneration != secondGeneration)
        #expect(await state.getTransport(readerGeneration: firstGeneration) == nil)
        #expect(await state.getTransport(readerGeneration: secondGeneration) === secondTransport)

        let pendingRequest = Task<Data, Swift.Error> {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await state.addPending(42, continuation)
                }
            }
        }
        while await state.pendingRequestCount() == 0 {
            await Task.yield()
        }

        #expect(await state.cancelAll(TestFailure.streamClosed, readerGeneration: firstGeneration) == false)
        #expect(await state.pendingRequestCount() == 1)
        #expect(await state.cancelAll(TestFailure.streamClosed, readerGeneration: secondGeneration) == true)
        await #expect(throws: TestFailure.self) {
            try await pendingRequest.value
        }

        let staleRemoval = await state.removeConnection(
            TestFailure.streamClosed,
            readerGeneration: firstGeneration,
        )
        #expect(staleRemoval.removed == false)
        #expect(await state.getTransport() === secondTransport)

        let activeRemoval = await state.removeConnection(
            TestFailure.streamClosed,
            readerGeneration: secondGeneration,
        )
        #expect(activeRemoval.removed == true)
        #expect(activeRemoval.transport === secondTransport)
        #expect(await state.getTransport() == nil)
    }
}
