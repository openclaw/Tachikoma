import Foundation

// MARK: - Retry Handler

/// Policy for automatic retry with exponential backoff
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let exponentialBase: Double
    public let jitterRange: ClosedRange<Double>
    public let shouldRetry: @Sendable (Error) -> Bool

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        exponentialBase: Double = 2.0,
        jitterRange: ClosedRange<Double> = 0.9...1.1,
        shouldRetry: @escaping @Sendable (Error) -> Bool = RetryPolicy.defaultShouldRetry,
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.exponentialBase = exponentialBase
        self.jitterRange = jitterRange
        self.shouldRetry = shouldRetry
    }

    /// Default retry policy
    public static let `default` = RetryPolicy()

    /// Aggressive retry policy for critical operations
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        baseDelay: 0.5,
        maxDelay: 60.0,
        exponentialBase: 1.5,
    )

    /// Conservative retry policy for non-critical operations
    public static let conservative = RetryPolicy(
        maxAttempts: 2,
        baseDelay: 2.0,
        maxDelay: 10.0,
        exponentialBase: 2.0,
    )

    /// Default retry logic - retries on rate limits and network errors
    public static let defaultShouldRetry: @Sendable (Error) -> Bool = { error in
        if let tachikomaError = error as? TachikomaError {
            switch tachikomaError {
            case .rateLimited:
                return true
            case .networkError:
                return true
            case let .apiError(message):
                // Retry on specific API errors
                let retryableMessages = [
                    "rate limit",
                    "too many requests",
                    "temporarily unavailable",
                    "service unavailable",
                    "gateway timeout",
                    "bad gateway",
                ]
                let lowercasedMessage = message.lowercased()
                return retryableMessages.contains { lowercasedMessage.contains($0) }
            default:
                return false
            }
        }

        // Retry on NSURLError network issues
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        return false
    }

    /// Calculate delay for a given attempt (0-indexed)
    func delay(for attempt: Int) -> TimeInterval {
        guard self.baseDelay != 0, self.maxDelay != 0 else { return 0 }
        let jitter = Double.random(in: self.jitterRange)
        guard jitter != 0 else { return 0 }
        // Exponential backoff with jitter
        let exponentialDelay = self.baseDelay * pow(self.exponentialBase, Double(attempt))
        let clampedDelay = min(exponentialDelay, maxDelay)
        return clampedDelay * jitter
    }

    func validate() throws {
        // An infinite cap is valid; effective delays are checked before each sleep.
        guard
            self.maxAttempts > 0,
            self.baseDelay.isFinite, self.baseDelay >= 0,
            self.maxDelay >= 0,
            self.exponentialBase.isFinite, self.exponentialBase >= 0,
            self.jitterRange.lowerBound.isFinite, self.jitterRange.lowerBound >= 0,
            self.jitterRange.upperBound.isFinite else
        {
            throw TachikomaError.invalidConfiguration("Invalid retry policy")
        }
    }
}

/// Handles automatic retries with configurable policies
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public actor RetryHandler {
    private let policy: RetryPolicy

    public init(policy: RetryPolicy = .default) {
        self.policy = policy
    }

    /// Execute an async operation with automatic retry
    public func execute<T: Sendable>(
        operation: @Sendable () async throws -> T,
        onRetry: (@Sendable (Int, TimeInterval, Error) async -> Void)? = nil,
    ) async throws
        -> T
    {
        try self.policy.validate()
        var lastError: Error?

        for attempt in 0..<self.policy.maxAttempts {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                if error is CancellationError {
                    throw error
                }
                try Task.checkCancellation()
                lastError = error

                // Check if we should retry
                guard self.policy.shouldRetry(error) else {
                    throw error
                }

                // Check if we have more attempts
                guard attempt < self.policy.maxAttempts - 1 else {
                    throw error
                }

                // Calculate delay
                var delay = self.policy.delay(for: attempt)

                // Check for rate limit with specific retry-after
                if
                    case let TachikomaError.rateLimited(retryAfter) = error,
                    let retryAfter
                {
                    _ = try TimeoutNanoseconds.fromSeconds(retryAfter)
                    delay = max(delay, retryAfter)
                }
                let delayNanoseconds = try TimeoutNanoseconds.fromSeconds(delay)

                // Notify about retry
                await onRetry?(attempt + 1, delay, error)

                // Wait before retrying
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        throw lastError ?? TachikomaError.apiError("Retry failed with unknown error")
    }

    /// Execute an async throwing stream operation with retry
    /// Note: Streaming operations are generally not retried mid-stream to avoid data corruption
    public func executeStream<T: Sendable>(
        operation: @escaping @Sendable () async throws -> AsyncThrowingStream<T, Error>,
        onRetry: (@Sendable (Int, TimeInterval, Error) async -> Void)? = nil,
    ) async throws
        -> AsyncThrowingStream<T, Error>
    {
        try await self.execute(operation: operation, onRetry: onRetry)
    }
}

// MARK: - Integration with Generation

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension RetryHandler {
    /// Create a retry handler based on generation settings
    public static func from(settings: GenerationSettings) -> RetryHandler {
        // Use aggressive retry for high reasoning effort (important queries)
        if let effort = settings.reasoningEffort, [.high, .xhigh, .max].contains(effort) {
            RetryHandler(policy: .aggressive)
        } else if settings.reasoningEffort == .low {
            RetryHandler(policy: .conservative)
        } else {
            RetryHandler(policy: .default)
        }
    }
}
