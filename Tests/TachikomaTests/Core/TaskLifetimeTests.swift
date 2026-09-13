import Foundation
import Testing
@testable import Tachikoma

@Suite("Task lifetimes")
struct TaskLifetimeTests {
    @Test(.timeLimit(.minutes(1)))
    func `Discarding a cache releases its background cleanup owner`() async {
        var cache: ResponseCache? = ResponseCache()
        let reference = WeakLifetimeReference(cache)
        await cache?.clear()
        cache = nil
        while reference.value != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(reference.value == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Caller cancellation reaches a retry operation with a separate token`() async throws {
        let token = CancellationToken()
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (stopped, stopSignal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await retryWithCancellation(
                configuration: RetryConfiguration(maxAttempts: 1),
                cancellationToken: token,
            ) {
                startSignal.yield(())
                startSignal.finish()
                defer { stopSignal.yield(())
                    stopSignal.finish()
                }
                try await Task.sleep(for: .seconds(600))
                return "unexpected"
            }
        }
        defer { task.cancel()
            Task { await token.cancel() }
        }
        try #require(await started.contains { _ in true })
        task.cancel()
        try #require(await stopped.contains { _ in true })
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await token.cancelled == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Failed retry attempts release cancellation handlers`() async {
        final class Failure: Error {}
        let token = CancellationToken()
        var failure: Failure? = Failure()
        let reference = WeakLifetimeReference(failure)
        do {
            let _: String = try await retryWithCancellation(
                configuration: RetryConfiguration(maxAttempts: 1), cancellationToken: token,
            ) { [error = failure!] in throw error }
        } catch {}
        failure = nil
        while reference.value != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(reference.value == nil)
        #expect(await token.cancelled == false)
    }

    @Test(arguments: [
        RetryConfiguration(maxAttempts: 0),
        RetryConfiguration(maxAttempts: -1),
        RetryConfiguration(delay: -1),
        RetryConfiguration(delay: .nan),
        RetryConfiguration(delay: .infinity),
        RetryConfiguration(backoffMultiplier: .nan),
        RetryConfiguration(backoffMultiplier: -1),
        RetryConfiguration(maxDelay: .infinity),
        RetryConfiguration(timeout: .nan),
    ])
    func `Invalid retry settings fail before starting work`(_ configuration: RetryConfiguration) async {
        await #expect(throws: TachikomaError.self) {
            try await retryWithCancellation(configuration: configuration) {
                Issue.record("Invalid configuration started an operation")
                return 1
            }
        }
    }
}

private final class WeakLifetimeReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) {
        self.value = value
    }
}
