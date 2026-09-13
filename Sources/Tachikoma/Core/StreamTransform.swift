import Foundation

// MARK: - Stream Transform Pipeline

/// Protocol for transforming stream elements
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public protocol StreamTransform: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    func transform(_ input: Input) async throws -> Output?
}

/// A transform that filters stream elements
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct FilterTransform<T: Sendable>: StreamTransform {
    public typealias Input = T
    public typealias Output = T

    private let predicate: @Sendable (T) async -> Bool

    public init(predicate: @escaping @Sendable (T) async -> Bool) {
        self.predicate = predicate
    }

    public func transform(_ input: T) async throws -> T? {
        await self.predicate(input) ? input : nil
    }
}

/// A transform that maps stream elements
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct MapTransform<Input: Sendable, Output: Sendable>: StreamTransform {
    private let mapper: @Sendable (Input) async throws -> Output

    public init(mapper: @escaping @Sendable (Input) async throws -> Output) {
        self.mapper = mapper
    }

    public func transform(_ input: Input) async throws -> Output? {
        try await self.mapper(input)
    }
}

/// A transform that buffers and batches stream elements
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public actor BufferTransform<T: Sendable>: StreamTransform {
    public typealias Input = T
    public typealias Output = [T]

    private let bufferSize: Int
    private let flushInterval: TimeInterval?
    private var buffer: [T] = []
    private var lastFlush = Date()

    public init(bufferSize: Int, flushInterval: TimeInterval? = nil) {
        self.bufferSize = bufferSize
        self.flushInterval = flushInterval
    }

    public func transform(_ input: T) async throws -> [T]? {
        self.buffer.append(input)

        let shouldFlush = self.buffer.count >= self.bufferSize ||
            (self.flushInterval != nil && Date().timeIntervalSince(self.lastFlush) >= self.flushInterval!)

        if shouldFlush {
            let result = self.buffer
            self.buffer = []
            self.lastFlush = Date()
            return result
        }

        return nil
    }

    public func flush() async -> [T]? {
        guard !self.buffer.isEmpty else { return nil }
        let result = self.buffer
        self.buffer = []
        self.lastFlush = Date()
        return result
    }
}

/// A transform that throttles stream elements
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public actor ThrottleTransform<T: Sendable>: StreamTransform {
    public typealias Input = T
    public typealias Output = T

    private let interval: TimeInterval
    private var lastEmit: Date?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    public func transform(_ input: T) async throws -> T? {
        let now = Date()

        if let lastEmit, now.timeIntervalSince(lastEmit) < interval {
            return nil
        }

        lastEmit = now
        return input
    }
}

/// A transform that adds side effects without changing the stream
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TapTransform<T: Sendable>: StreamTransform {
    public typealias Input = T
    public typealias Output = T

    private let action: @Sendable (T) async -> Void

    public init(action: @escaping @Sendable (T) async -> Void) {
        self.action = action
    }

    public func transform(_ input: T) async throws -> T? {
        await self.action(input)
        return input
    }
}

// MARK: - Stream Extensions

/// Extensions for applying transforms to streams
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension AsyncThrowingStream where Element: Sendable {
    /// Apply a transform to the stream
    public func transform<T: StreamTransform>(
        _ transform: T,
    )
        -> AsyncThrowingStream<T.Output, Error>
        where Element == T.Input
    {
        // Apply a transform to the stream
        AsyncThrowingStream<T.Output, Error> { continuation in
            let producer = Task {
                do {
                    for try await element in self {
                        try Task.checkCancellation()
                        if let output = try await transform.transform(element) {
                            continuation.yield(output)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Filter stream elements
    public func filter(
        _ predicate: @escaping @Sendable (Element) async -> Bool,
    )
        -> AsyncThrowingStream<Element, Error>
    {
        // Filter stream elements
        self.transform(FilterTransform(predicate: predicate))
    }

    /// Map stream elements
    public func map<Output: Sendable>(
        _ mapper: @escaping @Sendable (Element) async throws -> Output,
    )
        -> AsyncThrowingStream<Output, Error>
    {
        // Map stream elements
        self.transform(MapTransform(mapper: mapper))
    }

    /// Add side effects to stream
    public func tap(
        _ action: @escaping @Sendable (Element) async -> Void,
    )
        -> AsyncThrowingStream<Element, Error>
    {
        // Add side effects to stream
        self.transform(TapTransform(action: action))
    }

    /// Buffer and batch stream elements
    public func buffer(
        size: Int,
        flushInterval: TimeInterval? = nil,
    )
        -> AsyncThrowingStream<[Element], Error>
    {
        // Buffer and batch stream elements
        let bufferTransform = BufferTransform<Element>(
            bufferSize: size,
            flushInterval: flushInterval,
        )

        return AsyncThrowingStream<[Element], Error> { continuation in
            let producer = Task {
                do {
                    for try await element in self {
                        try Task.checkCancellation()
                        if let batch = try await bufferTransform.transform(element) {
                            continuation.yield(batch)
                        }
                    }
                    // Flush any remaining buffered elements
                    if let remaining = await bufferTransform.flush() {
                        continuation.yield(remaining)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Throttle stream elements
    public func throttle(
        interval: TimeInterval,
    )
        -> AsyncThrowingStream<Element, Error>
    {
        // Throttle stream elements
        self.transform(ThrottleTransform(interval: interval))
    }
}

// MARK: - StreamTextResult Extensions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension StreamTextResult {
    /// Filter text deltas
    public func filter(
        _ predicate: @escaping @Sendable (TextStreamDelta) async -> Bool,
    )
        -> StreamTextResult
    {
        // Filter text deltas
        StreamTextResult(
            stream: stream.filter(predicate),
            model: model,
            settings: settings,
        )
    }

    /// Map text deltas
    public func map<Output: Sendable>(
        _ mapper: @escaping @Sendable (TextStreamDelta) async throws -> Output,
    )
        -> AsyncThrowingStream<Output, Error>
    {
        // Map text deltas
        stream.map(mapper)
    }

    /// Add side effects to text stream
    public func tap(
        _ action: @escaping @Sendable (TextStreamDelta) async -> Void,
    )
        -> StreamTextResult
    {
        // Add side effects to text stream
        StreamTextResult(
            stream: stream.tap(action),
            model: model,
            settings: settings,
        )
    }

    /// Collect only text content from the stream
    public func collectText() -> AsyncThrowingStream<String, Error> {
        // Collect only text content from the stream
        stream
            .filter { delta in
                if case .textDelta = delta.type {
                    return delta.content != nil
                }
                return false
            }
            .map { delta in
                delta.content ?? ""
            }
    }

    /// Collect complete text once stream is done
    public func fullText() async throws -> String {
        // Collect complete text once stream is done
        var result = ""
        for try await delta in stream {
            if case .textDelta = delta.type, let content = delta.content {
                result += content
            }
        }
        return result
    }
}

// MARK: - StreamObjectResult Extensions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension StreamObjectResult {
    /// Filter object deltas
    public func filter(
        _ predicate: @escaping @Sendable (ObjectStreamDelta<T>) async -> Bool,
    )
        -> StreamObjectResult<T>
    {
        // Filter object deltas
        StreamObjectResult(
            objectStream: objectStream.filter(predicate),
            model: model,
            settings: settings,
            schema: schema,
        )
    }

    /// Map object deltas
    public func map<Output: Sendable>(
        _ mapper: @escaping @Sendable (ObjectStreamDelta<T>) async throws -> Output,
    )
        -> AsyncThrowingStream<Output, Error>
    {
        // Map object deltas
        objectStream.map(mapper)
    }

    /// Add side effects to object stream
    public func tap(
        _ action: @escaping @Sendable (ObjectStreamDelta<T>) async -> Void,
    )
        -> StreamObjectResult<T>
    {
        // Add side effects to object stream
        StreamObjectResult(
            objectStream: objectStream.tap(action),
            model: model,
            settings: settings,
            schema: schema,
        )
    }

    /// Collect only partial objects from the stream
    public func partialObjects() -> AsyncThrowingStream<T, Error> {
        // Collect only partial objects from the stream
        objectStream
            .filter { delta in
                delta.type == .partial && delta.object != nil
            }
            .map { delta in
                delta.object!
            }
    }

    /// Get the final complete object
    public func finalObject() async throws -> T {
        // Get the final complete object
        for try await delta in objectStream {
            if case .complete = delta.type, let object = delta.object {
                return object
            }
        }
        throw TachikomaError.invalidInput("No complete object received in stream")
    }
}

// MARK: - Composable Transform Chains

/// A composable chain of transforms
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TransformChain<Input: Sendable, Output: Sendable>: StreamTransform {
    private let transforms: [@Sendable (Input) async throws -> Output?]

    public init(transforms: [@Sendable (Input) async throws -> Output?]) {
        self.transforms = transforms
    }

    public func transform(_ input: Input) async throws -> Output? {
        var current: Any = input

        for transform in self.transforms {
            guard let transformInput = current as? Input else {
                return nil
            }

            if let result = try await transform(transformInput) {
                current = result
            } else {
                return nil
            }
        }

        return current as? Output
    }
}

// MARK: - Transform Builder

/// Result builder for composing stream transforms
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@resultBuilder
public struct TransformBuilder {
    public static func buildBlock<T: StreamTransform>(_ transform: T) -> T {
        transform
    }

    public static func buildBlock<T1: StreamTransform, T2: StreamTransform>(
        _ t1: T1,
        _ t2: T2,
    )
        -> some StreamTransform where T1.Output == T2.Input
    {
        CombinedTransform(first: t1, second: t2)
    }
}

/// A combination of two transforms
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct CombinedTransform<T1: StreamTransform, T2: StreamTransform>: StreamTransform
    where T1.Output == T2.Input
{
    public typealias Input = T1.Input
    public typealias Output = T2.Output

    private let first: T1
    private let second: T2

    public init(first: T1, second: T2) {
        self.first = first
        self.second = second
    }

    public func transform(_ input: Input) async throws -> Output? {
        guard let intermediate = try await first.transform(input) else {
            return nil
        }
        return try await self.second.transform(intermediate)
    }
}
