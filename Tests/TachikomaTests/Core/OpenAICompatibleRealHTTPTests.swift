import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import Tachikoma

struct OpenAICompatibleRealHTTPTests {
    @Test
    func `Public provider preserves complete tool arguments over HTTP`() async throws {
        let server = try LocalCompatibleServer()
        defer { server.stop() }

        for terminal in ["tool_calls", "stop", "omitted"] {
            let response = try await Self.generate(server: server, modelId: terminal)
            let calls = try #require(response.toolCalls)
            #expect(response.text == "fixture text")
            #expect(response.usage?.inputTokens == 7)
            #expect(response.usage?.outputTokens == 3)
            #expect(response.finishReason == (terminal == "omitted" ? nil : terminal == "stop" ? .stop : .toolCalls))
            #expect(calls.map(\.id) == ["call-0", "call-1", "call-2"])
            #expect(calls.map(\.name) == ["ping", "ping", "ping"])
            try #require(calls.count == 3)
            #expect(calls[0].arguments.isEmpty)
            #expect(calls[1].arguments.isEmpty)
            #expect(calls[2].arguments["nested"] == AnyAgentToolValue(object: [
                "flag": AnyAgentToolValue(bool: true),
                "count": AnyAgentToolValue(int: 1),
                "items": AnyAgentToolValue(array: [AnyAgentToolValue(null: ()), AnyAgentToolValue(string: "ok")]),
            ]))
        }
    }

    @Test
    func `Public provider suppresses all calls on unsuccessful terminals over HTTP`() async throws {
        let server = try LocalCompatibleServer()
        defer { server.stop() }

        for (terminal, expected) in [
            ("length", FinishReason.length),
            ("content_filter", .contentFilter),
            ("unknown", .other),
        ] {
            let response = try await Self.generate(server: server, modelId: terminal)
            #expect(response.finishReason == expected)
            #expect(response.text == "fixture text")
            #expect(response.usage?.inputTokens == 7)
            #expect(response.usage?.outputTokens == 3)
            #expect(response.toolCalls == nil)
        }
    }

    @Test
    func `Public provider omits malformed calls without losing valid calls over HTTP`() async throws {
        let server = try LocalCompatibleServer()
        defer { server.stop() }
        let response = try await Self.generate(server: server, modelId: "malformed")
        #expect(response.finishReason == .toolCalls)
        #expect(response.text == "fixture text")
        #expect(response.toolCalls?.map(\.id) == ["call-0", "call-6"])
    }

    private static func generate(server: LocalCompatibleServer, modelId: String) async throws -> ProviderResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = try OpenAICompatibleProvider(
            modelId: modelId,
            baseURL: "http://127.0.0.1:\(server.port)",
            configuration: TachikomaConfiguration(loadFromEnvironment: false),
            apiKey: "synthetic-test-key",
            session: session,
        )
        return try await provider.generateText(
            request: ProviderRequest(messages: [ModelMessage(role: .user, content: [.text("ping")])]),
        )
    }
}

private final class LocalCompatibleServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)

    init() throws {
        #if os(Linux)
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listener >= 0 else { throw Self.failure() }
        do {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(listener, 8) == 0 else { throw Self.failure() }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(listener, $0, &size)
                }
            }
            guard named == 0 else { throw Self.failure() }
            self.port = Int(UInt16(bigEndian: address.sin_port))
            self.listener = listener
        } catch {
            close(listener)
            throw error
        }
        DispatchQueue(label: "tachikoma-loopback-http").async { self.serve() }
    }

    func stop() {
        self.lock.withLock { self.stopped = true }
        self.finished.wait()
    }

    private func serve() {
        defer {
            close(self.listener)
            self.finished.signal()
        }
        while !self.lock.withLock({ self.stopped }) {
            var descriptor = pollfd(fd: self.listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let client = accept(self.listener, nil, nil)
            guard client >= 0 else { continue }
            self.respond(to: client)
            close(client)
        }
    }

    private func respond(to client: Int32) {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        guard
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { return }
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 65536, !self.lock.withLock({ self.stopped }) {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            request.append(contentsOf: buffer.prefix(count))
            guard
                let separator = request.range(of: Data("\r\n\r\n".utf8)),
                let headers = String(data: request[..<separator.lowerBound], encoding: .utf8),
                let lengthLine = headers.components(separatedBy: "\r\n").first(where: {
                    $0.lowercased().hasPrefix("content-length:")
                }),
                let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                length >= 0, length <= 65536 else { continue }
            let body = request[separator.upperBound...]
            guard body.count >= length else { continue }
            guard
                let payload = try? JSONSerialization.jsonObject(with: Data(body.prefix(length))) as? [String: Any],
                let model = payload["model"] as? String,
                let response = try? Self.response(model: model) else { return }
            var bytes = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(response.count)\r\nConnection: close\r\n\r\n"
                    .utf8,
            )
            bytes.append(response)
            bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    #if os(Linux)
                    let sent = send(
                        client,
                        raw.baseAddress!.advanced(by: offset),
                        raw.count - offset,
                        Int32(MSG_NOSIGNAL),
                    )
                    #else
                    let sent = send(client, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    #endif
                    guard sent > 0 else { return }
                    offset += sent
                }
            }
            return
        }
    }

    private static func response(model: String) throws -> Data {
        var terminal = model
        var arguments = ["", "{}", #"{"nested":{"flag":true,"count":1,"items":[null,"ok"]}}"#]
        if ["length", "content_filter", "unknown"].contains(terminal) {
            arguments.append("{")
        }
        if terminal == "malformed" {
            terminal = "tool_calls"
            arguments = ["{}", "{", "[]", "null", "true", "42", ""]
        }
        var choice: [String: Any] = [
            "index": 0,
            "message": [
                "role": "assistant",
                "content": "fixture text",
                "tool_calls": arguments.enumerated().map { index, value in
                    ["id": "call-\(index)", "type": "function", "function": ["name": "ping", "arguments": value]]
                },
            ],
        ]
        if terminal != "omitted" {
            choice["finish_reason"] = terminal
        }
        return try JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl-local", "choices": [choice],
            "usage": ["prompt_tokens": 7, "completion_tokens": 3],
        ])
    }

    private static func failure() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
