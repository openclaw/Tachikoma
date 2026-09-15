import Foundation
import Testing
@testable import Tachikoma

struct RetryPolicyValidationTests {
    @Test(arguments: [
        RetryPolicy(baseDelay: -1), RetryPolicy(baseDelay: .nan), RetryPolicy(baseDelay: .infinity),
        RetryPolicy(maxDelay: -1), RetryPolicy(maxDelay: .infinity),
        RetryPolicy(exponentialBase: -1), RetryPolicy(exponentialBase: .nan),
        RetryPolicy(jitterRange: -1...1), RetryPolicy(jitterRange: 1...Double.infinity),
        RetryPolicy(jitterRange: 1e100...1e100),
    ])
    func `invalid duration policies fail before work`(_ policy: RetryPolicy) async {
        await self.expectRejectedBeforeWork(policy)
    }

    @Test(arguments: [0, -1, Int.min])
    func `invalid attempt counts fail before work`(_ attempts: Int) async {
        await self.expectRejectedBeforeWork(RetryPolicy(maxAttempts: attempts))
    }

    private func expectRejectedBeforeWork(_ policy: RetryPolicy) async {
        let calls = RetryHandlerTests.CallCounter()
        let handler = RetryHandler(policy: policy)
        await #expect(throws: TachikomaError.self) {
            try await handler.execute {
                await calls.increment()
                return 1
            }
        }
        await #expect(throws: TachikomaError.self) {
            try await handler.executeStream {
                await calls.increment()
                return AsyncThrowingStream<Int, Error> { $0.finish() }
            }
        }
        #expect(await calls.get() == 0)
    }

    @Test
    func `cancelled caller never starts work`() async {
        let calls = RetryHandlerTests.CallCounter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RetryHandler().execute {
                await calls.increment()
                return 1
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await calls.get() == 0)
    }

    @Test
    func `cancellation errors never reach retry callbacks`() async {
        let retries = RetryHandlerTests.CallCounter()
        let handler = RetryHandler(policy: RetryPolicy(baseDelay: 0) { _ in true })
        await #expect(throws: CancellationError.self) {
            try await handler.execute(
                operation: { () throws -> Int in throw CancellationError() },
                onRetry: { _, _, _ in await retries.increment() },
            )
        }
        #expect(await retries.get() == 0)
    }

    @Test(arguments: [Double.infinity, Double.nan, Double.greatestFiniteMagnitude])
    func `invalid retry after fails without sleeping`(_ retryAfter: Double) async {
        let retries = RetryHandlerTests.CallCounter()
        let handler = RetryHandler(policy: RetryPolicy(baseDelay: 0))
        do {
            let _: Int = try await handler.execute(
                operation: { throw TachikomaError.rateLimited(retryAfter: retryAfter) },
                onRetry: { _, _, _ in await retries.increment() },
            )
            Issue.record("Expected invalid retry delay")
        } catch let error as TachikomaError {
            guard case .invalidConfiguration = error else {
                Issue.record("Expected invalidConfiguration, got \(error)")
                return
            }
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(await retries.get() == 0)
    }

    @Test
    func `zero delay survives exponential overflow`() async throws {
        let calls = RetryHandlerTests.CallCounter()
        let handler = RetryHandler(policy: RetryPolicy(
            maxAttempts: 4, baseDelay: 0, exponentialBase: .greatestFiniteMagnitude,
        ) { _ in true })
        let result = try await handler.execute {
            await calls.increment()
            if await calls.count < 4 {
                throw TachikomaError.apiError("fixture")
            }
            return 1
        }
        #expect(result == 1)
        #expect(await calls.count == 4)
    }
}
