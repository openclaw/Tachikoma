import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Tachikoma

@Suite("Stream cancellation")
struct StreamCancellationTests {
    enum TransformMode: CaseIterable, Sendable {
        case map, filter, tap, buffer, stopCondition
    }

    enum ProviderMode: CaseIterable, Sendable {
        case compatible, responses, anthropic
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `UI convenience streams propagate cancellation`(uiMessages: Bool) async throws {
        let (source, continuation) = AsyncThrowingStream<TextStreamDelta, Error>.makeStream()
        let stopped = CancellationEvent()
        continuation.onTermination = { _ in stopped.signal() }
        defer { continuation.finish() }
        let result = StreamTextResult(stream: source, model: .openai(.gpt55), settings: .default)
        let consumed = CancellationEvent()
        let consumer = Task {
            if uiMessages {
                for await _ in result.toUIMessageStream() {
                    consumed.signal()
                }
            } else {
                for await _ in result.toTextStream() {
                    consumed.signal()
                }
            }
        }
        defer { consumer.cancel() }
        continuation.yield(.text("hello"))
        try #require(await consumed.wait())
        consumer.cancel()
        try #require(await stopped.wait())
        await consumer.value
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `UI convenience streams finish on upstream EOF without a terminal delta`(uiMessages: Bool) async {
        let (source, continuation) = AsyncThrowingStream<TextStreamDelta, Error>.makeStream()
        continuation.yield(.text("hello"))
        continuation.finish()
        let result = StreamTextResult(stream: source, model: .openai(.gpt55), settings: .default)
        var text: [String] = []
        if uiMessages {
            for await chunk in result.toUIMessageStream() {
                if case let .text(value) = chunk {
                    text.append(value)
                }
            }
        } else {
            for await value in result.toTextStream() {
                text.append(value)
            }
        }
        #expect(text == ["hello"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: TransformMode.allCases)
    func `Cancelling a transformed consumer terminates its upstream`(_ mode: TransformMode) async throws {
        let (source, continuation) = AsyncThrowingStream<TextStreamDelta, Error>.makeStream()
        let stopped = CancellationEvent()
        continuation.onTermination = { _ in stopped.signal() }
        defer { continuation.finish() }

        let output: AsyncThrowingStream<TextStreamDelta, Error> = switch mode {
        case .map: source.map(\.self)
        case .filter: source.filter { _ in true }
        case .tap: source.tap { _ in }
        case .buffer: source.buffer(size: 1).map { $0[0] }
        case .stopCondition: source.stopWhen(StringStopCondition("not-found"))
        }
        let consumed = CancellationEvent()
        let consumer = Task {
            for try await _ in output {
                consumed.signal()
            }
        }
        defer { consumer.cancel() }
        continuation.yield(.text("hello"))
        try #require(await consumed.wait())
        consumer.cancel()
        try #require(await stopped.wait())
        _ = await consumer.result
    }

    @Test(.timeLimit(.minutes(1)))
    func `Cancelling object generation terminates the provider stream`() async throws {
        struct Payload: Codable, Sendable { let value: Int }
        let (source, continuation) = AsyncThrowingStream<TextStreamDelta, Error>.makeStream()
        let stopped = CancellationEvent()
        continuation.onTermination = { _ in stopped.signal() }
        defer { continuation.finish() }
        let result = try await streamObject(
            model: .custom(provider: HoldingStreamProvider(stream: source)),
            messages: [.user("fixture")],
            schema: Payload.self,
            configuration: TachikomaConfiguration(loadFromEnvironment: false),
        )
        let consumed = CancellationEvent()
        let consumer = Task {
            for try await delta in result where delta.type == .partial {
                consumed.signal()
            }
        }
        defer { consumer.cancel() }
        continuation.yield(.text(#"{"value":1}"#))
        try #require(await consumed.wait())
        consumer.cancel()
        try #require(await stopped.wait())
        _ = await consumer.result
    }

    @Test(.timeLimit(.minutes(1)), arguments: ProviderMode.allCases)
    func `Cancelling a provider stream cancels the HTTP request`(_ mode: ProviderMode) async throws {
        let id = UUID().uuidString
        let probe = CancellationNetworkProbe()
        CancellationURLProtocol.register(probe, id: id)
        defer { CancellationURLProtocol.remove(id: id) }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CancellationURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        let baseURL = "https://cancel-fixture.test/\(id)"
        configuration.setAPIKey("test-key", for: .openai)
        configuration.setAPIKey("test-key", for: .anthropic)
        configuration.setBaseURL(baseURL, for: .openai)
        configuration.setBaseURL(baseURL, for: .anthropic)

        let provider: any ModelProvider = switch mode {
        case .compatible:
            try OpenAICompatibleProvider(
                modelId: "fixture", baseURL: baseURL, configuration: configuration, session: session,
            )
        case .responses:
            try OpenAIResponsesProvider(model: .gpt55, configuration: configuration, session: session)
        case .anthropic:
            try AnthropicProvider(model: .sonnet45, configuration: configuration, urlSession: session)
        }
        let consumer = Task {
            let stream = try await provider.streamText(request: ProviderRequest(
                messages: [.user("fixture")], tools: nil, settings: .default,
            ))
            for try await _ in stream {}
        }
        defer { consumer.cancel() }
        try #require(await probe.started.wait())
        consumer.cancel()
        try #require(await probe.stopped.wait())
        _ = await consumer.result
    }
}

private struct CancellationEvent: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (self.stream, self.continuation) = AsyncStream.makeStream()
    }

    func signal() {
        self.continuation.yield(())
        self.continuation.finish()
    }

    func wait() async -> Bool {
        await self.stream.contains { _ in true }
    }
}

private struct HoldingStreamProvider: ModelProvider {
    let stream: AsyncThrowingStream<TextStreamDelta, Error>
    let modelId = "fixture"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        throw TachikomaError.unsupportedOperation("fixture only streams")
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        self.stream
    }
}

private struct CancellationNetworkProbe: Sendable {
    let started = CancellationEvent()
    let stopped = CancellationEvent()
}

private final class CancellationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var probes: [String: CancellationNetworkProbe] = [:]

    static func register(_ probe: CancellationNetworkProbe, id: String) {
        self.lock.withLock { self.probes[id] = probe }
    }

    static func remove(id: String) {
        self.lock.withLock { _ = self.probes.removeValue(forKey: id) }
    }

    private var probe: CancellationNetworkProbe? {
        guard let id = self.request.url?.pathComponents.dropFirst().first else { return nil }
        return Self.lock.withLock { Self.probes[id] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cancel-fixture.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = self.request.url, let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"],
            ) else { return }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.probe?.started.signal()
    }

    override func stopLoading() {
        self.probe?.stopped.signal()
    }
}
