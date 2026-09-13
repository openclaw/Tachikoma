import Foundation

// MARK: - Cancellation Token

/// Token for coordinating cancellation across multiple async operations
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public actor CancellationToken {
    private var isCancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    /// Check if cancelled
    public var cancelled: Bool {
        get async { self.isCancelled }
    }

    /// Cancel all operations
    public func cancel() {
        // Cancel all operations
        guard !self.isCancelled else { return }
        self.isCancelled = true

        // Call all handlers
        for handler in self.handlers.values {
            handler()
        }
        self.handlers.removeAll()
    }

    /// Register a cancellation handler
    @discardableResult
    public func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        // Register a cancellation handler
        if self.isCancelled {
            handler()
            return UUID()
        } else {
            let token = UUID()
            self.handlers[token] = handler
            return token
        }
    }

    /// Remove a previously registered cancellation handler
    public func removeHandler(_ token: UUID) {
        self.handlers.removeValue(forKey: token)
    }
}

// MARK: - Cancellable Task

/// A task that can be cancelled via token
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct CancellableTask<Success: Sendable> {
    public let task: Task<Success, Error>
    public let token: CancellationToken
}

// MARK: - Timeout Extensions

// MARK: - Timeout Functions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
enum TimeoutNanoseconds {
    static let maximumSeconds = Double(UInt64.max / 1_000_000_000)

    static func fromSeconds(_ timeout: TimeInterval) throws -> UInt64 {
        guard timeout.isFinite, timeout >= 0, timeout <= self.maximumSeconds else {
            throw TachikomaError.invalidConfiguration("Invalid timeout: \(timeout) seconds")
        }
        return UInt64(timeout * 1_000_000_000)
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func withTimeout<T: Sendable>(
    _ timeout: TimeInterval,
    operation: @escaping @Sendable () async throws -> T,
) async throws
    -> T
{
    let timeoutNanoseconds = try TimeoutNanoseconds.fromSeconds(timeout)
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task<Never, Never>.sleep(nanoseconds: timeoutNanoseconds)
            throw TimeoutError(timeout: timeout)
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Timeout error
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TimeoutError: Error, LocalizedError, Sendable {
    public let timeout: TimeInterval

    public var errorDescription: String? {
        "Operation timed out after \(self.timeout) seconds"
    }
}

// MARK: - Retry Configuration

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct RetryConfiguration: Sendable {
    public let maxAttempts: Int
    public let delay: TimeInterval
    public let backoffMultiplier: Double
    public let maxDelay: TimeInterval
    public let timeout: TimeInterval?

    public init(
        maxAttempts: Int = 3,
        delay: TimeInterval = 1.0,
        backoffMultiplier: Double = 2.0,
        maxDelay: TimeInterval = 60.0,
        timeout: TimeInterval? = nil,
    ) {
        self.maxAttempts = maxAttempts
        self.delay = delay
        self.backoffMultiplier = backoffMultiplier
        self.maxDelay = maxDelay
        self.timeout = timeout
    }

    public static let `default` = RetryConfiguration()
    public static let aggressive = RetryConfiguration(
        maxAttempts: 5,
        delay: 0.5,
        backoffMultiplier: 1.5,
        maxDelay: 30.0,
    )
    public static let conservative = RetryConfiguration(
        maxAttempts: 3,
        delay: 2.0,
        backoffMultiplier: 3.0,
        maxDelay: 120.0,
    )
}

// MARK: - Retry with Cancellation

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func retryWithCancellation<T: Sendable>(
    configuration: RetryConfiguration = .default,
    cancellationToken: CancellationToken? = nil,
    operation: @escaping @Sendable () async throws -> T,
) async throws
    -> T
{
    guard
        configuration.maxAttempts > 0,
        configuration.backoffMultiplier.isFinite,
        configuration.backoffMultiplier >= 0 else
    {
        throw TachikomaError.invalidConfiguration("Invalid retry configuration")
    }
    _ = try TimeoutNanoseconds.fromSeconds(configuration.delay)
    _ = try TimeoutNanoseconds.fromSeconds(configuration.maxDelay)
    if let timeout = configuration.timeout {
        _ = try TimeoutNanoseconds.fromSeconds(timeout)
    }
    var lastError: Error?
    var currentDelay = min(configuration.delay, configuration.maxDelay)

    for attempt in 1...configuration.maxAttempts {
        // Check cancellation
        if let token = cancellationToken, await token.cancelled {
            throw CancellationError()
        }

        do {
            let runOperation: () async throws -> T = {
                if let timeout = configuration.timeout {
                    try await withTimeout(timeout, operation: operation)
                } else {
                    try await operation()
                }
            }

            if let token = cancellationToken {
                let operationTask = Task {
                    try await runOperation()
                }

                let handlerToken = await token.onCancel {
                    operationTask.cancel()
                }

                do {
                    let value = try await withTaskCancellationHandler {
                        try await operationTask.value
                    } onCancel: {
                        operationTask.cancel()
                    }
                    await token.removeHandler(handlerToken)
                    return value
                } catch {
                    await token.removeHandler(handlerToken)
                    throw error
                }
            } else {
                return try await runOperation()
            }
        } catch {
            lastError = error

            // Don't retry on cancellation
            if error is CancellationError {
                throw error
            }

            // Don't retry on last attempt
            if attempt == configuration.maxAttempts {
                break
            }

            // Wait with backoff
            try await Task<Never, Never>.sleep(nanoseconds: TimeoutNanoseconds.fromSeconds(currentDelay))
            currentDelay = min(currentDelay * configuration.backoffMultiplier, configuration.maxDelay)
        }
    }

    throw lastError ?? TimeoutError(timeout: configuration.timeout ?? 0)
}

// MARK: - Async Stream Extensions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension AsyncThrowingStream where Failure == Error {
    /// Collect all elements into an array
    public func collect() async throws -> [Element] {
        // Collect all elements into an array
        var elements: [Element] = []
        for try await element in self {
            elements.append(element)
        }
        return elements
    }
}

// MARK: - Task Group Extensions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func withAutoCancellationTaskGroup<T: Sendable, Result>(
    of type: T.Type,
    returning _: Result.Type = Result.self,
    body: (inout ThrowingTaskGroup<T, Error>) async throws -> Result,
) async throws
    -> Result
{
    try await withThrowingTaskGroup(of: type) { group in
        defer { group.cancelAll() }
        return try await body(&group)
    }
}
