import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Tachikoma

@Suite("Responses summaries", .serialized)
struct ResponsesSummaryTests {
    @Test(arguments: [false, true])
    func `Summary requests share response parsing and refusal handling`(filtered: Bool) async throws {
        SummaryURLProtocol.filtered = filtered
        SummaryURLProtocol.legacyFormat = 0
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SummaryURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("test-key", for: .openai)
        config.setBaseURL("https://summary-fixture.test/v1", for: .openai)
        let provider = try OpenAIResponsesProvider(model: .gpt55, configuration: config, session: session)
        let result = try await provider.generateTextWithSummary(request: ProviderRequest(
            messages: [.user("fixture")], tools: nil,
            settings: GenerationSettings(
                providerOptions: ProviderOptions(openai: OpenAIOptions(reasoningEffort: .high)),
            ),
        ))
        #expect(result.response.text == (filtered ? "" : "firstsecond"))
        #expect(result.summary == (filtered ? nil : "one\ntwo"))
        #expect(result.response.finishReason == (filtered ? .contentFilter : .stop))
        let body = try #require(SummaryURLProtocol.requestBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try #require(json["reasoning"] as? [String: String])
        #expect(reasoning == ["effort": "high", "summary": "auto"])
    }

    @Test(arguments: [1, 2])
    func `Legacy gateway reasoning content remains readable`(format: Int) async throws {
        SummaryURLProtocol.filtered = false
        SummaryURLProtocol.legacyFormat = format
        defer { SummaryURLProtocol.legacyFormat = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("test-key", for: .openai)
        config.setBaseURL("https://summary-fixture.test/v1", for: .openai)
        let provider = try OpenAIResponsesProvider(model: .gpt55, configuration: config, session: session)
        let result = try await provider.generateTextWithSummary(request: ProviderRequest(
            messages: [.user("fixture")], tools: nil, settings: .default,
        ))
        #expect(result.response.text == "firstsecond")
        #expect(result.summary == "legacy")
    }

    @Test
    func `Summary requests reject malformed endpoints before networking`() async {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("test-key", for: .openai)
        config.setBaseURL("http://[", for: .openai)
        do {
            let provider = try OpenAIResponsesProvider(model: .gpt55, configuration: config)
            _ = try await provider.generateTextWithSummary(request: ProviderRequest(
                messages: [.user("fixture")], tools: nil, settings: .default,
            ))
            Issue.record("Malformed endpoint was accepted")
        } catch let error as TachikomaError {
            guard case .invalidConfiguration = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private final class SummaryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storedFiltered = false
    private nonisolated(unsafe) static var storedLegacyFormat = 0
    private nonisolated(unsafe) static var storedRequestBody: Data?
    static var requestBody: Data? {
        self.lock.withLock { self.storedRequestBody }
    }

    static var legacyFormat: Int {
        get { self.lock.withLock { self.storedLegacyFormat } }
        set { self.lock.withLock { self.storedLegacyFormat = newValue } }
    }

    static var filtered: Bool {
        get { self.lock.withLock { self.storedFiltered } }
        set { self.lock.withLock { self.storedFiltered = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "summary-fixture.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body(self.request)
        Self.lock.withLock { Self.storedRequestBody = body }
        var output: [[String: Any]] = [
            [
                "id": "reasoning",
                "type": "reasoning",
                "summary": [
                    ["type": "summary_text", "text": "one"],
                    ["type": "summary_text", "text": "two"],
                ],
            ],
            [
                "id": "message",
                "type": "message",
                "role": "assistant",
                "content": [
                    ["type": "output_text", "text": "first"],
                    ["type": "output_text", "text": "second"],
                ],
            ],
        ]
        if Self.legacyFormat != 0 {
            output[0].removeValue(forKey: "summary")
            if Self.legacyFormat == 1 {
                output[0]["content"] = "legacy"
            } else {
                output[0]["content"] = [["type": "text", "text": "legacy"]]
            }
        }
        var payload: [String: Any] = [
            "id": "fixture", "object": "response", "created_at": 0, "model": "gpt-5.5",
            "status": Self.filtered ? "incomplete" : "completed", "output": output,
        ]
        if Self.filtered {
            payload["incomplete_details"] = ["reason": "content_filter"]
        }
        guard
            let url = self.request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]),
            let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
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
