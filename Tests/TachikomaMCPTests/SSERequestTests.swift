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

    @Test(.timeLimit(.minutes(1)))
    func `POST responses arrive through the same SDK connection`() async throws {
        SSEFixtureProtocol.reset()
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

    @Test
    func `SDK JSON and buffered Linux SSE preserve complete messages`() throws {
        let message = Data(#"{"jsonrpc":"2.0","id":1,"result":{"text":"event: data: text"}}"#.utf8)
        #expect(SSEMessageDecoder.messages(from: message) == [message])
        let text = try #require(String(data: message, encoding: .utf8))
        let framed = Data("event: message\r\ndata: \(text)\r\n\r\n".utf8)
        #expect(SSEMessageDecoder.messages(from: framed) == [message])
        let multiline = Data("data: {\"id\":1,\ndata: \"result\":{}}\n\n".utf8)
        let decoded = try #require(SSEMessageDecoder.messages(from: multiline).first)
        #expect(try JSONSerialization.jsonObject(with: decoded) is [String: Any])
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
        if self.request.httpMethod == "GET" {
            code = 405
            data = Data()
        } else if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let id = json["id"] {
            code = 200
            data = (try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": ["text": "event: and data: are ordinary response text"],
            ])) ?? Data()
        } else {
            code = 202
            data = Data()
        }
        guard
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: [
                "Content-Type": "application/json", "Mcp-Session-Id": "fixture-session",
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
