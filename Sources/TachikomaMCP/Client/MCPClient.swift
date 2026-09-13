import Foundation
import Logging
import MCP
import Tachikoma

/// Configuration for an MCP server connection
public struct MCPServerConfig: Sendable, Codable {
    public var transport: String // "stdio", "http", "sse"
    public var command: String // executable path or URL for HTTP/SSE
    public var args: [String] // command arguments (stdio) or unused
    public var env: [String: String] // environment variables
    public var headers: [String: String]? // optional HTTP headers (HTTP/SSE)
    public var enabled: Bool // enable/disable server
    public var timeout: TimeInterval // connection timeout
    public var autoReconnect: Bool // auto-reconnect on failure
    public var description: String? // human-readable description

    public init(
        transport: String = "stdio",
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        headers: [String: String]? = nil,
        enabled: Bool = true,
        timeout: TimeInterval = 30,
        autoReconnect: Bool = true,
        description: String? = nil,
    ) {
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.headers = headers
        self.enabled = enabled
        self.timeout = timeout
        self.autoReconnect = autoReconnect
        self.description = description
    }
}

/// Actor to manage mutable state for Sendable conformance
private actor MCPClientState {
    var transport: (any MCPTransport)?
    var connectionID: UUID?
    var tools: [Tool] = []
    var isConnected: Bool = false
    var connectionError: MCPError?

    func beginConnection(id: UUID, transport: any MCPTransport) -> (any MCPTransport)? {
        let previousTransport = self.transport
        self.connectionID = id
        self.transport = transport
        self.tools = []
        self.isConnected = false
        self.connectionError = nil
        return previousTransport
    }

    func completeConnection(id: UUID, tools: [Tool]) -> Bool {
        guard self.connectionID == id else { return false }
        self.tools = tools
        self.isConnected = true
        self.connectionError = nil
        return true
    }

    func connectionClosed(id: UUID, error: MCPError) {
        guard self.connectionID == id else { return }
        self.connectionID = nil
        self.transport = nil
        self.tools = []
        self.isConnected = false
        self.connectionError = error
    }

    func takeConnection() -> (any MCPTransport)? {
        let previousTransport = self.transport
        self.connectionID = nil
        self.transport = nil
        self.tools = []
        self.isConnected = false
        self.connectionError = nil
        return previousTransport
    }

    func transportForRequest() throws -> any MCPTransport {
        guard self.isConnected, let transport else {
            throw self.connectionError ?? MCPError.notConnected
        }
        return transport
    }
}

/// Main MCP client for connecting to MCP servers
public final class MCPClient: Sendable {
    private let config: MCPServerConfig
    private let logger: Logger
    private let state = MCPClientState()
    private let name: String

    public init(name: String, config: MCPServerConfig) {
        self.name = name
        self.config = config
        self.logger = Logger(label: "tachikoma.mcp.client.\(name)")
    }

    /// Connect to the MCP server
    public func connect() async throws {
        // Connect to the MCP server
        guard self.config.enabled else {
            throw MCPError.serverDisabled
        }

        self.logger.info("Connecting to MCP server '\(self.name)'")

        // Create appropriate transport based on config
        let connectionID = UUID()
        let transport: any MCPTransport
        switch self.config.transport.lowercased() {
        case "stdio":
            transport = StdioTransport { [state] error in
                await state.connectionClosed(id: connectionID, error: error)
            }
        case "sse":
            transport = SSETransport()
        case "http":
            transport = HTTPTransport()
        default:
            throw MCPError.unsupportedTransport(self.config.transport)
        }

        let previousTransport = await self.state.beginConnection(id: connectionID, transport: transport)
        if let previousTransport {
            await previousTransport.disconnect()
        }

        do {
            // Connect transport
            try await transport.connect(config: self.config)

            // Initialize MCP handshake
            let initParams = InitializeParams(
                protocolVersion: "2025-03-26",
                clientInfo: ClientInfo(name: "tachikoma-mcp-client", version: "1.0.0"),
                capabilities: ClientCapabilities(),
            )
            let initResponse = try await self.initialize(using: transport, params: initParams)

            self.logger.debug("Initialized MCP connection: \(initResponse)")

            // Send initialized notification (per spec name)
            // Some servers (like Context7) may not support this notification
            do {
                try await transport.sendNotification(method: "notifications/initialized", params: EmptyParams())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.logger.debug("Server may not support notifications/initialized: \(error)")
            }

            let tools = try await self.discoverTools(using: transport)
            guard await self.state.completeConnection(id: connectionID, tools: tools) else {
                throw MCPError.transportClosed
            }
        } catch {
            await transport.disconnect()
            await self.state.connectionClosed(
                id: connectionID,
                error: (error as? MCPError) ?? .connectionFailed(error.localizedDescription),
            )
            throw error
        }
    }

    func initialize(
        using transport: any MCPTransport,
        params: InitializeParams,
    ) async throws
        -> InitializeResponse
    {
        do {
            return try await transport.sendRequest(method: "initialize", params: params)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let oldParams = InitializeParams(
                protocolVersion: "2024-11-05",
                clientInfo: params.clientInfo,
                capabilities: params.capabilities,
            )
            do {
                return try await transport.sendRequest(method: "initialize", params: oldParams)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let snake = InitializeParamsSnake(
                    protocolVersion: oldParams.protocolVersion,
                    clientInfo: params.clientInfo,
                    capabilities: params.capabilities,
                )
                return try await transport.sendRequest(method: "initialize", params: snake)
            }
        }
    }

    /// Disconnect from the MCP server
    public func disconnect() async {
        // Disconnect from the MCP server
        self.logger.info("Disconnecting from MCP server '\(self.name)'")
        if let transport = await state.takeConnection() {
            await transport.disconnect()
        }
    }

    /// Check if the client is connected
    public var isConnected: Bool {
        get async {
            await self.state.isConnected
        }
    }

    /// Get available tools
    public var tools: [Tool] {
        get async {
            await self.state.tools
        }
    }

    /// Discover available tools from the server
    private func discoverTools(using transport: any MCPTransport) async throws -> [Tool] {
        let response: ToolsListResponse = try await transport.sendRequest(
            method: "tools/list",
            params: EmptyParams(),
        )
        self.logger.info("Discovered \(response.tools.count) tools from '\(self.name)'")
        return response.tools
    }

    /// Execute a tool by name
    public func executeTool(name: String, arguments: [String: Any]) async throws -> ToolResponse {
        try await self.executeTool(name: name, arguments: ToolArguments(raw: arguments).rawValue)
    }

    func executeTool(name: String, arguments: AgentToolArguments) async throws -> ToolResponse {
        try await self.executeTool(name: name, arguments: arguments.toMCPValue())
    }

    private func executeTool(name: String, arguments: Value) async throws -> ToolResponse {
        // Execute a tool by name
        let transport = try await state.transportForRequest()

        // Send tool execution request
        let response: CallTool.Result = try await transport.sendRequest(
            method: "tools/call",
            params: ToolCallParams(
                name: name,
                arguments: arguments,
            ),
        )

        // Convert response to ToolResponse
        return ToolResponse(callToolResult: response)
    }
}

// MARK: - MCP Protocol Types

struct InitializeParams: Codable {
    let protocolVersion: String
    let clientInfo: ClientInfo
    let capabilities: ClientCapabilities
    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case clientInfo
        case capabilities
    }
}

/// Some servers use snake_case for protocol_version in initialize
struct InitializeParamsSnake: Codable {
    let protocolVersion: String
    let clientInfo: ClientInfo
    let capabilities: ClientCapabilities
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case clientInfo
        case capabilities
    }
}

struct InitializeResponse: Decodable {
    let serverInfo: ServerInfo?
    let capabilities: ServerCapabilities?

    struct ServerInfo: Decodable {
        let name: String
        let version: String?
    }

    struct ServerCapabilities: Decodable {
        // Simplified for now - can be expanded as needed
    }
}

struct ClientInfo: Codable {
    let name: String
    let version: String
}

struct ClientCapabilities: Codable {
    // Add capabilities as needed
}

struct EmptyParams: Codable {}
struct InitializedParams: Codable { let clientInfo: ClientInfo }

struct ToolsListResponse: Codable {
    let tools: [Tool]
}

struct ToolCallParams: Codable {
    let name: String
    let arguments: Value
}

// MARK: - Errors

public enum MCPError: LocalizedError, Equatable {
    case serverDisabled
    case unsupportedTransport(String)
    case notConnected
    case transportClosed
    case invalidResponse
    case connectionFailed(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .serverDisabled:
            "MCP server is disabled"
        case let .unsupportedTransport(transport):
            "Unsupported transport: \(transport)"
        case .notConnected:
            "MCP client is not connected"
        case .transportClosed:
            "MCP transport closed"
        case .invalidResponse:
            "Invalid response from MCP server"
        case let .connectionFailed(reason):
            "Connection failed: \(reason)"
        case let .executionFailed(reason):
            "Execution failed: \(reason)"
        }
    }
}
