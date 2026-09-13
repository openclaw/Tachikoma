import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TachikomaMCP

@Suite("HTTP transport", .serialized)
struct HTTPTransportTests {
    struct Params: Encodable { let value = "fixture" }
    struct Reply: Decodable { let ok: Bool }

    @Test(.timeLimit(.minutes(1)))
    func `Disconnect cancels a pending network request`() async throws {
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (stopped, stoppedSignal) = AsyncStream<Void>.makeStream()
        HTTPFixtureProtocol.handler = { _ in
            startedSignal.yield(())
            startedSignal.finish()
            return nil
        }
        HTTPFixtureProtocol.onStop = {
            stoppedSignal.yield(())
            stoppedSignal.finish()
        }
        defer {
            HTTPFixtureProtocol.handler = nil
            HTTPFixtureProtocol.onStop = nil
        }
        let transport = self.transport()
        try await transport.connect(config: MCPServerConfig(
            transport: "http",
            command: "https://http-fixture.test/mcp",
        ))
        let request = Task {
            let _: Reply = try await transport.sendRequest(method: "fixture", params: Params())
        }
        defer { request.cancel() }
        try #require(await started.contains { _ in true })
        await transport.disconnect()
        try #require(await stopped.contains { _ in true })
        await #expect(throws: MCPError.self) { try await request.value }
    }

    @Test(arguments: [200, 202, 204])
    func `Notifications omit ids and accept empty acknowledgements`(code: Int) async throws {
        let requests = HTTPRequestCapture()
        HTTPFixtureProtocol.handler = { request in
            requests.append(request)
            return (code, [:], Data())
        }
        defer { HTTPFixtureProtocol.handler = nil }
        let transport = self.transport()
        try await transport.connect(config: MCPServerConfig(
            transport: "http", command: "https://http-fixture.test/mcp", headers: ["X-Fixture": "present"],
        ))
        try await transport.sendNotification(method: "notifications/initialized", params: Params())
        await transport.disconnect()
        let request = try #require(requests.snapshot.first)
        let body = try #require(JSONSerialization.jsonObject(with: self.body(request)) as? [String: Any])
        #expect(body["id"] == nil)
        #expect(body["jsonrpc"] as? String == "2.0")
        #expect(body["method"] as? String == "notifications/initialized")
        #expect(request.value(forHTTPHeaderField: "X-Fixture") == "present")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func `Notification HTTP failures remain failures`() async throws {
        HTTPFixtureProtocol.handler = { _ in (403, [:], Data("denied".utf8)) }
        defer { HTTPFixtureProtocol.handler = nil }
        let transport = self.transport()
        try await transport.connect(config: MCPServerConfig(
            transport: "http",
            command: "https://http-fixture.test/mcp",
        ))
        await #expect(throws: MCPError.self) {
            try await transport.sendNotification(method: "notifications/initialized", params: Params())
        }
        await transport.disconnect()
    }

    @Test
    func `Requests decode responses and retain the negotiated session header`() async throws {
        let requests = HTTPRequestCapture()
        HTTPFixtureProtocol.handler = { request in
            requests.append(request)
            let body = try? JSONSerialization.jsonObject(with: self.body(request)) as? [String: Any]
            let id = body?["id"] as? Int ?? 0
            return (
                200,
                ["Content-Type": "application/json", "Mcp-Session-Id": "fixture-session"],
                Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"ok\":true}}".utf8),
            )
        }
        defer { HTTPFixtureProtocol.handler = nil }
        let transport = self.transport()
        try await transport.connect(config: MCPServerConfig(
            transport: "http",
            command: "https://http-fixture.test/mcp",
        ))
        let reply: Reply = try await transport.sendRequest(method: "fixture", params: Params())
        #expect(reply.ok)
        await transport.updateProtocolVersion("2025-06-18")
        try await transport.sendNotification(method: "notifications/initialized", params: Params())
        let snapshot = requests.snapshot
        #expect(snapshot.count == 2)
        #expect(snapshot.last?.value(forHTTPHeaderField: "Mcp-Session-Id") == "fixture-session")
        #expect(snapshot.first?.value(forHTTPHeaderField: "MCP-Protocol-Version") == nil)
        #expect(snapshot.last?.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
        try await transport.connect(config: MCPServerConfig(
            transport: "http",
            command: "https://http-fixture.test/replacement",
        ))
        try await transport.sendNotification(method: "notifications/initialized", params: Params())
        #expect(requests.snapshot.last?.value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
        #expect(requests.snapshot.last?.value(forHTTPHeaderField: "MCP-Protocol-Version") == nil)
        await transport.disconnect()
    }

    @Test(arguments: [false, true])
    func `HTTP SSE responses skip other messages and decode the matching multiline result`(batched: Bool) async throws {
        HTTPFixtureProtocol.handler = { request in
            let body = try? JSONSerialization.jsonObject(with: self.body(request)) as? [String: Any]
            guard let id = body?["id"] as? Int else { return nil }
            let messages = [
                #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#,
                "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"fixture/server\",\"params\":{}}",
                #"{"jsonrpc":"2.0","id":-1,"result":{"unrelated":"value"}}"#,
                "{\"jsonrpc\":\"2.0\",\"id\":\(id),\n\"result\":{\"ok\":true}}",
            ]
            let payloads = batched ? ["[\(messages.joined(separator: ","))]"] : messages
            let events = payloads.map { payload in
                "event: message\n" + payload.components(separatedBy: "\n").map { "data: \($0)" }
                    .joined(separator: "\n") + "\n\n"
            }.joined()
            return (200, ["Content-Type": "text/event-stream; charset=utf-8"], Data(events.utf8))
        }
        defer { HTTPFixtureProtocol.handler = nil }
        let transport = self.transport()
        try await transport.connect(config: MCPServerConfig(
            transport: "http",
            command: "https://http-fixture.test/mcp",
        ))
        let reply: Reply = try await transport.sendRequest(method: "fixture", params: Params())
        #expect(reply.ok)
        await transport.disconnect()
    }

    @Test
    func `HTTP responses must match the requested id`() async throws {
        HTTPFixtureProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"], Data(#"{"jsonrpc":"2.0","id":-1,"result":{"ok":true}}"#.utf8))
        }
        defer { HTTPFixtureProtocol.handler = nil }
        let transport = self.transport()
        try await transport.connect(config: MCPServerConfig(
            transport: "http",
            command: "https://http-fixture.test/mcp",
        ))
        await #expect(throws: MCPError.invalidResponse) {
            let _: Reply = try await transport.sendRequest(method: "fixture", params: Params())
        }
        await transport.disconnect()
    }

    @Test
    func `Empty request responses are still invalid`() async throws {
        HTTPFixtureProtocol.handler = { _ in (202, [:], Data()) }
        defer { HTTPFixtureProtocol.handler = nil }
        let transport = self.transport()
        try await transport.connect(config: MCPServerConfig(
            transport: "http",
            command: "https://http-fixture.test/mcp",
        ))
        await #expect(throws: DecodingError.self) {
            let _: Reply = try await transport.sendRequest(method: "fixture", params: Params())
        }
        await transport.disconnect()
    }

    private func transport() -> HTTPTransport {
        HTTPTransport { configuration in
            configuration.protocolClasses = [HTTPFixtureProtocol.self]
            return URLSession(configuration: configuration)
        }
    }

    private func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody {
            return data
        }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
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

private final class HTTPRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) {
        self.lock.withLock { self.requests.append(request) }
    }

    var snapshot: [URLRequest] {
        self.lock.withLock { self.requests }
    }
}

private final class HTTPFixtureProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)?
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storedHandler: Handler?
    private nonisolated(unsafe) static var storedOnStop: (@Sendable () -> Void)?
    static var onStop: (@Sendable () -> Void)? {
        get { self.lock.withLock { self.storedOnStop } }
        set { self.lock.withLock { self.storedOnStop = newValue } }
    }

    static var handler: Handler? {
        get { self.lock.withLock { self.storedHandler } }
        set { self.lock.withLock { self.storedHandler = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "http-fixture.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler, let url = self.request.url else { return }
        guard let (code, headers, data) = handler(self.request) else { return }
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers) else { return }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.onStop?()
    }
}
