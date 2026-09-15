#if !os(Linux)
import Foundation
import Testing
@testable import Tachikoma

@Suite(.serialized)
struct OpenAIEmbeddingProviderTests {
    @Test
    func `token input is sent without text conversion`() async throws {
        let provider = self.provider(payload: #"{"data":[{"index":0,"embedding":[0.6,0.8]}]}"#)
        defer { provider.session.invalidateAndCancel() }
        _ = try await provider.generateEmbedding(request: EmbeddingRequest(
            input: .tokens([10, 20, 30]),
            settings: .default,
        ))
        let data = try #require(EmbeddingProtocol.lastBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["input"] as? [Int] == [10, 20, 30])
    }

    @Test
    func `embeddings follow response indices`() async throws {
        let provider = self
            .provider(
                payload: #"""
                {"data":[{"index":1,"embedding":[0,1]},{"index":0,"embedding":[1,0]}],
                 "usage":{"prompt_tokens":7,"total_tokens":7}}
                """#,
            )
        defer { provider.session.invalidateAndCancel() }
        let result = try await provider.generateEmbedding(request: EmbeddingRequest(
            input: .texts(["first", "second"]), settings: EmbeddingSettings(dimensions: 2),
        ))
        #expect(result.embeddings == [[1, 0], [0, 1]])
        #expect(result.usage?.inputTokens == 7)
        let data = try #require(EmbeddingProtocol.lastBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["input"] as? [String] == ["first", "second"])
        #expect(body["dimensions"] as? Int == 2)
    }

    @Test(arguments: [
        #"{"data":[{"index":0,"embedding":[1,0]}]}"#,
        #"{"data":[{"index":0,"embedding":[1,0]},{"index":0,"embedding":[0,1]}]}"#,
        #"{"data":[{"index":0,"embedding":[1,0]},{"index":2,"embedding":[0,1]}]}"#,
        #"{"data":[{"index":0,"embedding":[1,0]},{"index":1,"embedding":"bad"}]}"#,
        #"{"data":[{"index":0,"embedding":[1,0]},{"index":1,"embedding":[]}]}"#,
        #"{"data":[{"index":0,"embedding":[1,0]},{"index":1,"embedding":[1]}]}"#,
        #"{"data":[{"index":0,"embedding":[1,0]},{"embedding":[0,1]}]}"#,
        #"{"data":[{"index":0,"embedding":[1,0]},{"index":1,"embedding":[true,false]}]}"#,
    ])
    func `malformed embedding batches are rejected`(_ payload: String) async {
        let provider = self.provider(payload: payload)
        defer { provider.session.invalidateAndCancel() }
        await #expect(throws: (any Error).self) {
            try await provider.generateEmbedding(request: EmbeddingRequest(
                input: .texts(["first", "second"]),
                settings: .default,
            ))
        }
    }

    @Test(arguments: [
        #"{"data":[{"index":0,"embedding":[1]}]}"#,
        #"{"data":[{"index":0,"embedding":[1,0,0]}]}"#,
    ])
    func `requested dimensions must match`(_ payload: String) async {
        let provider = self.provider(payload: payload)
        defer { provider.session.invalidateAndCancel() }
        await #expect(throws: TachikomaError.self) {
            try await provider.generateEmbedding(request: EmbeddingRequest(
                input: .text("first"), settings: EmbeddingSettings(dimensions: 2),
            ))
        }
    }

    private func provider(payload: String) -> OpenAIEmbeddingProvider {
        EmbeddingProtocol.reset(payload: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmbeddingProtocol.self]
        return OpenAIEmbeddingProvider(
            model: .small3, apiKey: "fixture-key", baseURL: "https://embedding-fixture.test/v1",
            session: URLSession(configuration: configuration),
        )
    }
}

private final class EmbeddingProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var payload = Data()
    private nonisolated(unsafe) static var body: Data?
    static var lastBody: Data? {
        self.lock.withLock { self.body }
    }

    static func reset(payload: String) {
        self.lock.withLock {
            self.payload = Data(payload.utf8)
            self.body = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "embedding-fixture.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = self.readBody()
        let data = Self.lock.withLock {
            Self.body = body
            return Self.payload
        }
        let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBody() -> Data {
        if let body = self.request.httpBody {
            return body
        }
        guard let stream = self.request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
#endif
