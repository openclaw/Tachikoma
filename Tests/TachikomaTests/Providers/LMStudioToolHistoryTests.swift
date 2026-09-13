import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Tachikoma

@Suite("LM Studio tool history", .serialized)
struct LMStudioToolHistoryTests {
    @Test
    func `A tool result is replayed with its original call id`() async throws {
        LMToolProtocol.reset()
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [LMToolProtocol.self]
        let provider = LMStudioProvider(
            baseURL: "https://lm-tool-fixture.test/v1", modelId: "fixture", sessionConfiguration: session,
        )
        let tool = createTool(
            name: "echo", description: "Echo a boolean",
            parameters: [.init(name: "flag", type: .boolean, description: "Flag")], required: ["flag"],
        ) { arguments in
            let flag = try #require(arguments["flag"]?.boolValue as Bool?)
            return AnyAgentToolValue(object: ["flag": AnyAgentToolValue(bool: flag)])
        }
        let result = try await generateText(
            model: .custom(provider: provider), messages: [.user("Call echo")], tools: [tool],
            maxSteps: 3, configuration: TachikomaConfiguration(loadFromEnvironment: false),
        )
        #expect(result.text == "done")
        let bodies = LMToolProtocol.bodies
        #expect(bodies.count == 2)
        let second = try #require(bodies.last)
        let json = try #require(JSONSerialization.jsonObject(with: second) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "call-fixture")
        let function = try #require(calls.first?["function"] as? [String: Any])
        let arguments = try #require(function["arguments"] as? String)
        struct Flag: Decodable { let flag: Bool }
        #expect(try JSONDecoder().decode(Flag.self, from: Data(arguments.utf8)).flag)
        let toolMessage = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(toolMessage["tool_call_id"] as? String == "call-fixture")
        let content = try #require(toolMessage["content"] as? String)
        #expect(try JSONDecoder().decode(Flag.self, from: Data(content.utf8)).flag)
    }
}

private final class LMToolProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests: [Data] = []
    static var bodies: [Data] {
        self.lock.withLock { self.requests }
    }

    static func reset() {
        self.lock.withLock { self.requests.removeAll() }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "lm-tool-fixture.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body(self.request)
        let count = Self.lock.withLock {
            Self.requests.append(body)
            return Self.requests.count
        }
        let payload = if count == 1 {
            #"""
            {"id":"fixture","object":"chat.completion","created":0,"choices":[
              {"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
                {"id":"call-fixture","type":"function","function":{"name":"echo","arguments":"{\"flag\":true}"}}
              ]},"finish_reason":"tool_calls"}
            ]}
            """#
        } else {
            #"""
            {"id":"fixture","object":"chat.completion","created":0,"choices":[
              {"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}
            ]}
            """#
        }
        guard
            let url = self.request.url, let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"],
            ) else { return }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(payload.utf8))
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
