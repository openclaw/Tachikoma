import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

private struct HTTPConnection: Sendable {
    let id = UUID()
    let session: URLSession
    let url: URL
    let headers: [String: String]
    var sessionID: String?
    var protocolVersion: String?
}

private actor HTTPTransportState {
    var connection: HTTPConnection?

    func replaceConnection(_ connection: HTTPConnection?) -> HTTPConnection? {
        defer { self.connection = connection }
        return self.connection
    }

    func setSessionID(_ sessionID: String, connectionID: UUID) {
        guard self.connection?.id == connectionID else { return }
        self.connection?.sessionID = sessionID
    }

    func setProtocolVersion(_ version: String) {
        self.connection?.protocolVersion = version
    }
}

/// HTTP transport for MCP communication.
public final class HTTPTransport: MCPTransport {
    private let logger = Logger(label: "tachikoma.mcp.http")
    private let state = HTTPTransportState()
    private let makeSession: @Sendable (URLSessionConfiguration) -> URLSession

    public init() {
        self.makeSession = { URLSession(configuration: $0) }
    }

    init(makeSession: @escaping @Sendable (URLSessionConfiguration) -> URLSession) {
        self.makeSession = makeSession
    }

    public func connect(config: MCPServerConfig) async throws {
        guard let url = URL(string: config.command) else {
            throw MCPError.connectionFailed("Invalid URL: \(config.command)")
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = max(1, config.timeout)
        configuration.timeoutIntervalForResource = max(1, config.timeout)
        let connection = HTTPConnection(
            session: self.makeSession(configuration), url: url, headers: config.headers ?? [:],
        )
        let previous = await self.state.replaceConnection(connection)
        previous?.session.invalidateAndCancel()
        self.logger.info("HTTP transport connected")
    }

    public func disconnect() async {
        let previous = await self.state.replaceConnection(nil)
        previous?.session.invalidateAndCancel()
        self.logger.info("HTTP transport disconnected")
    }

    func updateProtocolVersion(_ version: String) async {
        await self.state.setProtocolVersion(version)
    }

    public func sendRequest<R: Decodable>(method: String, params: some Encodable) async throws -> R {
        let request = HTTPJSONRPCRequest(method: method, params: params, id: Int.random(in: 1...Int(Int32.max)))
        let (data, response) = try await self.post(body: JSONEncoder().encode(request))
        let payloads: [Data] = if
            response.value(forHTTPHeaderField: "Content-Type")?.lowercased()
                .contains("text/event-stream") == true
        {
            SSEMessageDecoder.messages(from: data)
        } else {
            SSEMessageDecoder.jsonMessages(from: data)
        }
        let decoder = JSONDecoder()
        for payload in payloads {
            let header = try decoder.decode(JSONRPCResponseHeader.self, from: payload)
            guard header.responseID == .int(request.id) else { continue }
            let decoded = try decoder.decode(JSONRPCResponse<R>.self, from: payload)
            if let error = decoded.error {
                throw MCPError.executionFailed(error.message)
            }
            guard let result = decoded.result else { throw MCPError.invalidResponse }
            return result
        }
        throw MCPError.invalidResponse
    }

    public func sendNotification(method: String, params: some Encodable) async throws {
        let notification = JSONRPCNotification(jsonrpc: "2.0", method: method, params: params)
        _ = try await self.post(body: JSONEncoder().encode(notification))
    }

    private func post(body: Data) async throws -> (Data, HTTPURLResponse) {
        guard let connection = await self.state.connection else { throw MCPError.notConnected }
        var request = URLRequest(url: connection.url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID = connection.sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in connection.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let version = connection.protocolVersion {
            request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await connection.session.data(for: request)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw MCPError.executionFailed("HTTP request failed: \(error)")
        }
        guard let response = response as? HTTPURLResponse else {
            throw MCPError.executionFailed("Invalid HTTP response")
        }
        guard (200...299).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw MCPError.executionFailed("HTTP \(response.statusCode): \(message)")
        }
        if let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            await self.state.setSessionID(sessionID, connectionID: connection.id)
        }
        return (data, response)
    }
}
