# TachikomaMCP

Optional MCP (Model Context Protocol) extension for Tachikoma that enables connection to external tool servers.

## Installation

TachikomaMCP is an optional module. You can use Tachikoma without it for a lightweight experience, or import both for full MCP support.

### Lightweight (No MCP)
```swift
import Tachikoma

// Use Tachikoma normally without MCP
let result = try await generateText(
    model: .openai(.gpt55),
    messages: messages,
    tools: staticTools
)
```

### With MCP Support
```swift
import Tachikoma
import TachikomaMCP

// Now you can use MCP tools alongside static tools
let mcpTools = try await MCPToolDiscovery.withFilesystem()
let result = try await generateText(
    model: .openai(.gpt55),
    messages: messages,
    tools: staticTools + mcpTools
)
```

## Quick Start

### Connect to Common MCP Servers

```swift
import TachikomaMCP

// Filesystem access
let fsTools = try await MCPToolDiscovery.withFilesystem(path: "/path/to/files")

// GitHub API
let githubTools = try await MCPToolDiscovery.withGitHub()  // Uses GITHUB_TOKEN env var

// Browser automation
let browserTools = try await MCPToolDiscovery.withChromeDevTools()
```

### Custom MCP Server

```swift
// Configure custom server
let config = MCPServerConfig(
    transport: "stdio",
    command: "npx",
    args: ["-y", "@your/mcp-server"],
    env: ["API_KEY": "your-key"]
)

// Connect and discover tools
let tools = try await MCPToolDiscovery.discover(from: config, name: "custom-server")
```

### Using MCP Provider

```swift
// Create provider
let provider = MCPToolProvider(
    name: "my-server",
    config: MCPServerConfig(
        command: "npx",
        args: ["my-mcp-server"]
    )
)

// Connect and get tools
try await provider.connect()
let tools = try await provider.getAgentTools()

// Use with Tachikoma generation
let result = try await generateText(
    model: .anthropic(.opus4),
    messages: messages,
    tools: tools
)
```

### Multiple MCP Servers

```swift
// Define servers
let configs = [
    "filesystem": MCPServerConfig(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem"]
    ),
    "github": MCPServerConfig(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-github"],
        env: ["GITHUB_PERSONAL_ACCESS_TOKEN": githubToken]
    )
]

// Connect to all
let providers = try await MCPToolDiscovery.connectServers(configs)

// Get all tools
var allTools: [AgentTool] = []
for provider in providers.values {
    let tools = try await provider.getAgentTools()
    allTools.append(contentsOf: tools)
}
```

## Architecture

### Modular Design

- **Core Tachikoma**: Lightweight, no MCP dependencies (~500KB)
- **TachikomaMCP**: Optional MCP support (~1MB additional)
- **Pay for what you use**: Only include MCP if needed

### Components

- **MCPClient**: Core client for connecting to MCP servers
- **Transports**: Stdio, SSE, and HTTP transport implementations
- **MCPToolProvider**: Implements Tachikoma's DynamicToolProvider
- **MCPToolAdapter**: Converts between MCP and Tachikoma formats
- **MCPToolDiscovery**: Utility functions for easy setup

## MCP Servers

MCP servers are external processes that expose tools via the Model Context Protocol. Popular servers include:

- `@modelcontextprotocol/server-filesystem` - File system operations
- `@modelcontextprotocol/server-github` - GitHub API access
- `chrome-devtools-mcp` - Chrome DevTools automation
- `@modelcontextprotocol/server-postgres` - PostgreSQL database
- Custom servers for your specific needs

## Advanced Usage

### Custom Transport

```swift
enum MyTransportError: Error {
    case notImplemented
}

// Implement the complete transport lifecycle.
actor MyCustomTransport: MCPTransport {
    func connect(config: MCPServerConfig) async throws {
        // Custom connection logic
    }

    func disconnect() async {
        // Release transport resources and fail pending requests.
    }
    
    func sendRequest<R: Decodable>(
        method: String,
        params: some Encodable
    ) async throws -> R {
        // Encode the request, await its matching response, and decode R.
        throw MyTransportError.notImplemented
    }

    func sendNotification(
        method: String,
        params: some Encodable
    ) async throws {
        // Encode and send without waiting for a response.
    }
}
```

`MCPClient` selects the bundled stdio, HTTP, or SSE transport from `MCPServerConfig`. The protocol is public for wrappers and alternate clients that need the same request/notification contract.

### Tool Filtering

```swift
// Discover and filter tools
let provider = try await MCPToolDiscovery.connectServer(config, name: "server")
let tools = try await provider.getAgentTools()

// Filter tools by name or description
let filteredTools = tools.filter { tool in
    tool.name.contains("read") || tool.description.contains("file")
}
```

### Schema Fidelity

MCP tool adapters retain the original input schema for provider serialization and also expose a typed recursive view
for Agent runtimes that need to inspect request grammar without flattening it:

```swift
let parameters = MCPToolSchemaBridge.agentParameters(from: mcpTool.inputSchema)
let schema = try parameters.typedSchema()
let defaultValue = schema.keywords?.properties?["max_steps"]?.keywords?.defaultValue
```

The typed view preserves boolean schemas, lossless integer and floating-point bounds, scalar and collection defaults,
type unions, modern single-schema and legacy tuple-form array items (including `additionalItems`), nested object/array
schemas, modern and legacy dependencies, `const` and `enum` values, numeric/string/collection constraints,
`allOf`/`anyOf`/`oneOf`, `not`, and
`if`/`then`/`else`. Unknown extension keywords remain available through `unrecognizedKeywords`, while `rawValue`
retains a semantically complete canonical schema; JSON-equivalent integral floating-point values normalize to integers
so natural `Codable` round trips are stable. `AgentToolParameters.sourceSchema` remains the exact adapter-owned value.
References are preserved as `$ref` strings but are not resolved or evaluated; runtime argument validation remains the
tool owner's responsibility.

### Error Handling

```swift
do {
    let tools = try await MCPToolDiscovery.withFilesystem()
    // Use tools
} catch MCPError.connectionFailed(let reason) {
    print("Failed to connect: \(reason)")
} catch MCPError.notConnected {
    print("Server disconnected")
} catch {
    print("Unexpected error: \(error)")
}
```

## Requirements

- Swift 6.2+
- macOS 14+, iOS 17+, watchOS 10+, tvOS 17+, visionOS 1+
- MCP servers require Node.js for `npx` commands

## License

Same as Tachikoma - see main LICENSE file.

## HTTP transport lifecycle

HTTP notifications omit JSON-RPC IDs and accept successful empty acknowledgements. HTTP connections retain server session headers and cancel pending network work on disconnect. The SSE adapter uses the SDK's streamable HTTP connection for both POST responses and SSE messages; custom headers and negotiated protocol versions stay with that connection. Caller cancellation clears pending requests. Non-finite or overflowing SSE timeouts are rejected before connecting; nonpositive finite values retain the 30-second default.

HTTP responses match the outgoing request ID. Streamed response bodies may include progress notifications or other messages before the matching result, including JSON split across multiple SSE data lines.

For `transport: "sse"`, configure a streamable HTTP endpoint that accepts POST requests at the configured URL, with optional SSE delivery. Legacy servers that advertise a separate POST URL through an `endpoint` event are not supported by this adapter.
