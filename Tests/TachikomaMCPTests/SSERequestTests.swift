import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TachikomaMCP

@Suite("SSE requests", .serialized)
struct SSERequestTests {
    struct Params: Encodable { let value = "fixture" }
    struct Reply: Decodable { let text: String }

    @Test(.timeLimit(.minutes(1)), arguments: [0, 1, 2])
    func `POST responses arrive through the same SDK connection`(framing: Int) async throws {
        SSEFixtureProtocol.reset()
        SSEFixtureProtocol.framing = framing
        let transport = self.transport()
        try await transport.connect(config: MCPServerConfig(
            transport: "sse", command: "https://sse-fixture.test/mcp",
            headers: ["X-Fixture": "present", "Content-Type": "unused-default"], timeout: 2,
        ))
        let reply: Reply = try await transport.sendRequest(method: "fixture", params: Params())
        #expect(reply.text == "event: and data: are ordinary response text")
        try await transport.sendNotification(method: "notifications/initialized", params: Params())
        await transport.disconnect()
        let requests = SSEFixtureProtocol.requests.filter { $0.method == "POST" }
        #expect(requests.count == 2)
        #expect(requests.first?.headers.first { $0.key.lowercased() == "x-fixture" }?.value == "present")
        #expect(requests.first?.headers.first { $0.key.lowercased() == "content-type" }?.value == "application/json")
        #expect(requests.last?.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value == "fixture-session")
        let notification = try #require(requests.last)
        let body = try #require(JSONSerialization.jsonObject(with: notification.body) as? [String: Any])
        #expect(body["id"] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Cancelling a request stops the HTTP operation and resolves the caller`() async throws {
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (stopped, stoppedSignal) = AsyncStream<Void>.makeStream()
        SSEFixtureProtocol.reset()
        SSEFixtureProtocol.hold = {
            startedSignal.yield(())
            startedSignal.finish()
        }
        SSEFixtureProtocol.onStop = {
            stoppedSignal.yield(())
            stoppedSignal.finish()
        }
        defer { SSEFixtureProtocol.reset() }
        let transport = self.transport()
        try await transport.connect(config: MCPServerConfig(
            transport: "sse", command: "https://sse-fixture.test/mcp", timeout: 30,
        ))
        let request = Task {
            let _: Reply = try await transport.sendRequest(method: "fixture", params: Params())
        }
        defer { request.cancel() }
        try #require(await started.contains { _ in true })
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        try #require(await stopped.contains { _ in true })
        await transport.disconnect()
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude])
    func `Invalid timeouts fail before creating a connection`(_ timeout: Double) async {
        let transport = self.transport()
        await #expect(throws: MCPError.self) {
            try await transport.connect(config: MCPServerConfig(
                transport: "sse", command: "https://sse-fixture.test/mcp", timeout: timeout,
            ))
        }
        #expect(await transport.underlyingSDKTransport() == nil)
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func `SDK JSON and buffered Linux SSE preserve complete messages`(lineEnding: String) throws {
        let message = Data(#"{"jsonrpc":"2.0","id":1,"result":{"text":"event: data: text"}}"#.utf8)
        #expect(SSEMessageDecoder.messages(from: message) == [message])
        let text = try #require(String(data: message, encoding: .utf8))
        let framed = Data("event: message\(lineEnding)data: \(text)\(lineEnding)\(lineEnding)".utf8)
        #expect(SSEMessageDecoder.messages(from: framed) == [message])
        let multiline = Data("data: {\"id\":1,\ndata: \"result\":{}}\n\n".utf8)
        let decoded = try #require(SSEMessageDecoder.messages(from: multiline).first)
        #expect(try JSONSerialization.jsonObject(with: decoded) is [String: Any])
    }

    @Test
    func `Batched messages preserve nested strings and numeric precision`() throws {
        let batch = Data(
            #"""
            [
              {"id":1,"result":{"text":"comma, quote: \" and slash: \\","nested":[1,{"value":"[x],y"}]}},
              {"id":2,"result":{"value":1.12345678901234567890123456789}}
            ]
            """#.utf8,
        )
        let messages = SSEMessageDecoder.jsonMessages(from: batch)
        try #require(messages.count == 2)
        struct TextResult: Decodable { let text: String }
        struct NumberResult: Decodable { let value: Decimal }
        struct Reply<T: Decodable>: Decodable { let id: Int
            let result: T
        }
        let first = try JSONDecoder().decode(Reply<TextResult>.self, from: messages[0])
        let second = try JSONDecoder().decode(Reply<NumberResult>.self, from: messages[1])
        #expect(first.id == 1)
        #expect(first.result.text == "comma, quote: \" and slash: \\")
        #expect(second.id == 2)
        #expect(second.result.value == Decimal(string: "1.12345678901234567890123456789"))
        #expect(SSEMessageDecoder.jsonMessages(from: Data("[]".utf8)).isEmpty)
    }

    private func transport() -> SSETransport {
        SSETransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SSEFixtureProtocol.self]
            return configuration
        }
    }
}

private final class SSEFixtureProtocol: URLProtocol {
    struct Request: Sendable {
        let method: String
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var storedRequests: [Request] = []
    private nonisolated(unsafe) static var storedHold: (@Sendable () -> Void)?
    private nonisolated(unsafe) static var storedStop: (@Sendable () -> Void)?
    private nonisolated(unsafe) static var storedFraming = 0
    static var framing: Int {
        get { self.lock.withLock { self.storedFraming } }
        set { self.lock.withLock { self.storedFraming = newValue } }
    }

    static var requests: [Request] {
        self.lock.withLock { self.storedRequests }
    }

    static var hold: (@Sendable () -> Void)? {
        get { self.lock.withLock { self.storedHold } }
        set { self.lock.withLock { self.storedHold = newValue } }
    }

    static var onStop: (@Sendable () -> Void)? {
        get { self.lock.withLock { self.storedStop } }
        set { self.lock.withLock { self.storedStop = newValue } }
    }

    static func reset() {
        self.lock.withLock { self.storedRequests.removeAll()
            self.storedHold = nil
            self.storedStop = nil
            self.storedFraming = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sse-fixture.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = self.request.url else { return }
        let body = Self.body(self.request)
        Self.lock.withLock {
            Self.storedRequests.append(Request(
                method: self.request.httpMethod ?? "GET",
                headers: self.request.allHTTPHeaderFields ?? [:],
                body: body,
            ))
        }
        if self.request.httpMethod == "POST", let hold = Self.hold {
            hold()
            return
        }
        let code: Int
        let data: Data
        var contentType = "application/json"
        if self.request.httpMethod == "GET" {
            code = 405
            data = Data()
        } else if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let id = json["id"] {
            code = 200
            let reply = (try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": ["text": "event: and data: are ordinary response text"],
            ])) ?? Data()
            if Self.framing == 0 {
                data = reply
            } else {
                let request = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"fixture/server\",\"params\":{}}"
                guard let response = String(data: reply, encoding: .utf8) else {
                    self.client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData))
                    return
                }
                let payloads = Self.framing == 1 ? [request, response] : ["[\(request),\(response)]"]
                data = Data(payloads.map { "event: message\ndata: \($0)\n\n" }.joined().utf8)
                contentType = "text/event-stream"
            }
        } else {
            code = 202
            data = Data()
        }
        guard
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: [
                "Content-Type": contentType, "Mcp-Session-Id": "fixture-session",
            ]) else { return }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.onStop?()
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
