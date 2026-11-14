import Foundation
import Logging
import MCP
import Tachikoma
#if canImport(os)
import os.log
#endif

#if canImport(Darwin)
private typealias MCPOverrideLock = OSAllocatedUnfairLock<Bool?>
#else
private final class MCPOverrideLock: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Bool?

    init(initialState: Bool?) {
        self.state = initialState
    }

    func withLock<T>(_ operation: (inout Bool?) -> T) -> T {
        self.lock.lock()
        defer { lock.unlock() }
        return operation(&self.state)
    }
}
#endif

public struct ServerProbeResult: Sendable {
    public let isConnected: Bool
    public let toolCount: Int
    public let responseTime: TimeInterval
    public let error: String?

    public init(isConnected: Bool, toolCount: Int, responseTime: TimeInterval, error: String?) {
        self.isConnected = isConnected
        self.toolCount = toolCount
        self.responseTime = responseTime
        self.error = error
    }
}

enum ProbeTimeoutNanoseconds {
    private static let nanosecondsPerMillisecond: UInt64 = 1_000_000

    static func fromMilliseconds(_ timeoutMs: Int) -> UInt64? {
        guard timeoutMs >= 0 else { return nil }
        let milliseconds = UInt64(timeoutMs)
        guard milliseconds <= UInt64.max / self.nanosecondsPerMillisecond else {
            return nil
        }
        return milliseconds * self.nanosecondsPerMillisecond
    }
}

private enum AutoConnectPolicy {
    private static let overrideLock = MCPOverrideLock(initialState: nil)
    private static let forceEnable =
        ProcessInfo.processInfo.environment["PEEKABOO_FORCE_MCP_AUTOCONNECT"] == "true"
    private static let forceDisable =
        ProcessInfo.processInfo.environment["PEEKABOO_DISABLE_MCP_AUTOCONNECT"] == "true"
    private static let isTestEnvironment: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["PEEKABOO_DISABLE_MCP_AUTOCONNECT"] == "true" {
            return true
        }
        if env["SWIFT_PACKAGE_TESTING"] == "1" {
            return true
        }
        if env["XCTestConfigurationFilePath"] != nil {
            return true
        }
        let processName = ProcessInfo.processInfo.processName.lowercased()
        let argv0 = CommandLine.arguments.first?.lowercased() ?? ""
        return processName.contains("xctest")
            || processName.contains("swiftpm-test")
            || processName.contains("swiftpm-testing-helper")
            || argv0.contains(".xctest")
    }()

    static var shouldConnect: Bool {
        if let override = overrideLock.withLock({ $0 }) {
            return override
        }
        if forceEnable {
            return true
        }
        if forceDisable {
            return false
        }
        return !isTestEnvironment
    }

    static func setOverride(_ value: Bool?) {
        self.overrideLock.withLock { $0 = value }
    }
}

/// Instantiable manager for MCP client connections and configuration.
/// Owns parsing of mcpClients from the host profile config.json (JSONC) and
/// merges host-provided defaults with user overrides.
@MainActor
public final class TachikomaMCPClientManager {
    // MARK: Shared (optional)

    public static let shared = TachikomaMCPClientManager()

    // MARK: Profile/config wiring

    /// Name of the profile directory under $HOME (defaults to TachikomaConfiguration.profileDirectoryName)
    public var profileDirectoryName: String {
        get { TachikomaConfiguration.profileDirectoryName }
        set { TachikomaConfiguration.profileDirectoryName = newValue }
    }

    // MARK: Internal state

    #if canImport(os)
    private let logger = os.Logger(subsystem: "tachikoma.mcp", category: "client-manager")
    #else
    private let logger = Logger(label: "tachikoma.mcp.client-manager")
    #endif
    private var connections: [String: MCPClient] = [:]
    private var effectiveConfigs: [String: MCPServerConfig] = [:]
    private var defaultConfigs: [String: MCPServerConfig] = [:]

    public init() {}

    // MARK: Default registration

    public func registerDefaultServers(_ defaults: [String: MCPServerConfig]) {
        self.defaultConfigs = defaults
    }

    // MARK: Initialization

    public func initializeFromProfile(connect: Bool = true) async {
        let fileConfigs = self.loadFileConfigs()
        let merged = self.merge(defaults: self.defaultConfigs, file: fileConfigs)
        await self.apply(configs: merged, connect: connect && AutoConnectPolicy.shouldConnect)
    }

    public func initialize(with userConfigs: [String: MCPServerConfig], connect: Bool = true) async {
        let merged = self.merge(defaults: self.defaultConfigs, file: userConfigs)
        await self.apply(configs: merged, connect: connect && AutoConnectPolicy.shouldConnect)
    }

    // MARK: Lifecycle

    public func addServer(name: String, config: MCPServerConfig) async throws {
        self.effectiveConfigs[name] = config
        if self.connections[name] == nil {
            self.connections[name] = MCPClient(name: name, config: config)
        }
        if config.enabled, AutoConnectPolicy.shouldConnect {
            try await self.connections[name]?.connect()
        }
    }

    public func removeServer(name: String) async {
        if let client = connections[name] {
            await client.disconnect()
            self.connections.removeValue(forKey: name)
        }
        self.effectiveConfigs.removeValue(forKey: name)
    }

    public func enableServer(name: String) async throws {
        guard var cfg = effectiveConfigs[name] else { return }
        cfg.enabled = true
        self.effectiveConfigs[name] = cfg
        if self.connections[name] == nil {
            self.connections[name] = MCPClient(name: name, config: cfg)
        }
        if AutoConnectPolicy.shouldConnect {
            try await self.connections[name]?.connect()
        }
    }

    public func disableServer(name: String) async {
        guard var cfg = effectiveConfigs[name] else { return }
        cfg.enabled = false
        self.effectiveConfigs[name] = cfg
        if let client = connections[name] {
            await client.disconnect()
        }
    }

    public func listServerNames() -> [String] {
        Array(self.effectiveConfigs.keys).sorted()
    }

    public func getServerConfig(name: String) -> MCPServerConfig? {
        self.effectiveConfigs[name]
    }

    public func getAllServerConfigs() -> [String: MCPServerConfig] {
        self.effectiveConfigs
    }

    // MARK: Queries

    public func isServerConnected(name: String) async -> Bool {
        guard let client = connections[name] else { return false }
        return await client.isConnected
    }

    public func getServerTools(name: String) async -> [Tool] {
        guard let client = connections[name] else { return [] }
        return await client.tools
    }

    public func getAllTools() async -> [Tool] {
        var all: [Tool] = []
        for name in self.listServerNames() {
            let tools = await getServerTools(name: name)
            if !tools.isEmpty {
                all.append(contentsOf: tools)
            }
        }
        return all
    }

    /// Execute a tool on a specific server
    public func executeTool(
        serverName: String,
        toolName: String,
        arguments: [String: Any],
    ) async throws
        -> ToolResponse
    {
        guard let client = connections[serverName] else {
            throw MCPError.executionFailed("Server '\(serverName)' not found")
        }
        // Bridge via TachikomaMCP's adapter to ensure Sendable arguments
        let agentArgs = AgentToolArguments(arguments.mapValues { AnyAgentToolValue.from($0) })
        return try await client.executeTool(name: toolName, arguments: agentArgs)
    }

    /// Get external tools grouped by server name
    public func getExternalToolsByServer() async -> [String: [Tool]] {
        // Get external tools grouped by server name
        var result: [String: [Tool]] = [:]
        for (name, client) in self.connections {
            let tools = await client.tools
            if !tools.isEmpty {
                result[name] = tools
            }
        }
        return result
    }

    // MARK: Health/Info (lightweight)

    public func getServerNames() -> [String] {
        Array(self.effectiveConfigs.keys).sorted()
    }

    public func getServerInfo(name: String) async -> (config: MCPServerConfig, connected: Bool)? {
        guard let cfg = effectiveConfigs[name] else { return nil }
        let isConnected = await connections[name]?.isConnected ?? false
        return (cfg, isConnected)
    }

    /// Build Tachikoma AgentTools for all connected servers
    public func getAllAgentTools() async -> [AgentTool] {
        // Build Tachikoma AgentTools for all connected servers
        var all: [AgentTool] = []
        for (_, client) in self.connections {
            // Only attempt if connected
            if await client.isConnected {
                let provider = MCPToolProvider(client: client)
                if let tools = try? await provider.getAgentTools() {
                    all.append(contentsOf: tools)
                }
            } else {
                // Try to connect quickly and then fetch
                do {
                    try await client.connect()
                    let provider = MCPToolProvider(client: client)
                    if let tools = try? await provider.getAgentTools() {
                        all.append(contentsOf: tools)
                    }
                } catch {
                    continue
                }
            }
        }
        return all
    }

    // MARK: Health checks

    /// Probe a specific server with a timeout. Attempts to connect if not connected.
    public func probeServer(name: String, timeoutMs: Int = 5000) async -> ServerProbeResult {
        // Probe a specific server with a timeout. Attempts to connect if not connected.
        let start = Date()
        guard let client = connections[name], let cfg = effectiveConfigs[name], cfg.enabled else {
            return ServerProbeResult(
                isConnected: false,
                toolCount: 0,
                responseTime: 0,
                error: "Disabled or not configured",
            )
        }

        // If already connected, return quickly
        if await client.isConnected {
            let tools = await client.tools
            return ServerProbeResult(
                isConnected: true,
                toolCount: tools.count,
                responseTime: Date().timeIntervalSince(start),
                error: nil,
            )
        }

        guard let timeoutNanoseconds = ProbeTimeoutNanoseconds.fromMilliseconds(timeoutMs) else {
            return ServerProbeResult(
                isConnected: false,
                toolCount: 0,
                responseTime: Date().timeIntervalSince(start),
                error: "invalid timeout: \(timeoutMs)ms",
            )
        }

        // Try to connect with timeout using withTaskGroup for proper cancellation
        let result: (Bool, String?) = await withTaskGroup(of: (Bool, String?).self) { group in
            group.addTask {
                do {
                    try await client.connect()
                    return (true, nil)
                } catch {
                    return (false, error.localizedDescription)
                }
            }

            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return (false, "timeout after \(timeoutMs)ms")
                } catch {
                    // Task was cancelled (connection succeeded)
                    return (true, nil)
                }
            }

            // Wait for the first task to complete
            guard let firstResult = await group.next() else {
                return (false, "unknown error")
            }

            // Cancel all remaining tasks immediately
            group.cancelAll()

            return firstResult
        }

        let responseTime = Date().timeIntervalSince(start)

        if result.0 {
            // Connection succeeded
            let tools = await client.tools
            return ServerProbeResult(isConnected: true, toolCount: tools.count, responseTime: responseTime, error: nil)
        } else {
            // Connection failed or timed out
            await client.disconnect()
            return ServerProbeResult(isConnected: false, toolCount: 0, responseTime: responseTime, error: result.1)
        }
    }

    /// Probe all servers in parallel
    public func probeAllServers(timeoutMs: Int = 5000) async -> [String: ServerProbeResult] {
        // Probe all servers in parallel
        var results: [String: ServerProbeResult] = [:]
        await withTaskGroup(of: (String, ServerProbeResult).self) { group in
            for name in self.listServerNames() {
                group.addTask { [weak self] in
                    let res = await self?.probeServer(name: name, timeoutMs: timeoutMs)
                        ?? ServerProbeResult(isConnected: false, toolCount: 0, responseTime: 0, error: "not found")
                    return (name, res)
                }
            }
            for await (name, res) in group {
                results[name] = res
            }
        }
        return results
    }

    // MARK: Persistence

    /// Persist the current effectiveConfigs back to the profile config file under mcpClients.
    public func persist() throws {
        // Persist the current effectiveConfigs back to the profile config file under mcpClients.
        var json = self.loadRawConfigJSON() ?? [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Build mcpClients object
        var mcpDict: [String: Any] = [:]
        for (name, cfg) in self.effectiveConfigs {
            let obj: [String: Any?] = [
                "transport": cfg.transport,
                "command": cfg.command,
                "args": cfg.args,
                "env": cfg.env,
                "headers": cfg.headers,
                "enabled": cfg.enabled,
                "timeout": cfg.timeout,
                "autoReconnect": cfg.autoReconnect,
                "description": cfg.description,
            ]
            mcpDict[name] = obj.compactMapValues { $0 }
        }
        json["mcpClients"] = mcpDict

        // Serialize back to JSON (comments will be lost for this section)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let path = self.profileConfigPath()
        try self.ensureProfileDirectoryExists()
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: Helpers

    private func apply(configs: [String: MCPServerConfig], connect: Bool = true) async {
        // Disconnect removed servers
        let toRemove = Set(connections.keys).subtracting(Set(configs.keys))
        for name in toRemove {
            await self.connections[name]?.disconnect()
            self.connections.removeValue(forKey: name)
        }

        // Create/Update and connect enabled
        self.effectiveConfigs = configs
        for (name, cfg) in configs {
            if self.connections[name] == nil {
                self.connections[name] = MCPClient(name: name, config: cfg)
            }
        }

        if connect, AutoConnectPolicy.shouldConnect {
            await withTaskGroup(of: Void.self) { group in
                for (name, cfg) in configs where cfg.enabled {
                    group.addTask { [weak self] in
                        do { try await self?.connections[name]?.connect() } catch {
                            self?.logger.error("Failed to connect to \(name): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func merge(
        defaults D: [String: MCPServerConfig],
        file F: [String: MCPServerConfig],
    )
        -> [String: MCPServerConfig]
    {
        var result: [String: MCPServerConfig] = [:]
        let keys = Set(D.keys).union(F.keys)
        for k in keys {
            if let f = F[k] {
                if f.enabled == false {
                    continue
                }
                if let d = D[k] {
                    // Fill missing fields from defaults
                    var merged = f
                    if merged.transport.isEmpty {
                        merged.transport = d.transport
                    }
                    if merged.command.isEmpty {
                        merged.command = d.command
                    }
                    if merged.args.isEmpty {
                        merged.args = d.args
                    }
                    if merged.env.isEmpty {
                        merged.env = d.env
                    }
                    if merged.timeout <= 0 {
                        merged.timeout = d.timeout
                    }
                    if merged.description == nil {
                        merged.description = d.description
                    }
                    result[k] = merged
                } else {
                    result[k] = f
                }
            } else if let d = D[k], d.enabled {
                result[k] = d
            }
        }
        return result
    }

    // MARK: File loading

    private func loadFileConfigs() -> [String: MCPServerConfig] {
        guard let json = loadRawConfigJSON(), let mcp = json["mcpClients"] as? [String: Any] else { return [:] }
        var out: [String: MCPServerConfig] = [:]
        for (name, value) in mcp {
            guard let dict = value as? [String: Any] else { continue }
            let transport = (dict["transport"] as? String) ?? "stdio"
            let command = (dict["command"] as? String) ?? ""
            let args = (dict["args"] as? [String]) ?? []
            let env = (dict["env"] as? [String: String]) ?? [:]
            let headers = (dict["headers"] as? [String: String])
            let enabled = (dict["enabled"] as? Bool) ?? true
            let timeout = (dict["timeout"] as? Double) ?? 30
            let autoReconnect = (dict["autoReconnect"] as? Bool) ?? true
            let description = dict["description"] as? String
            out[name] = MCPServerConfig(
                transport: transport,
                command: command,
                args: args,
                env: env,
                headers: headers,
                enabled: enabled,
                timeout: timeout,
                autoReconnect: autoReconnect,
                description: description,
            )
        }
        return out
    }

    private func loadRawConfigJSON() -> [String: Any]? {
        let path = self.profileConfigPath()
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            #if canImport(Darwin)
            // Preserve the legacy reader's malformed UTF-16 handling and read errors.
            let raw = try NSString(contentsOfFile: path, usedEncoding: nil) as String
            #else
            var encoding = String.Encoding.utf8
            let raw = try String(contentsOfFile: path, usedEncoding: &encoding)
            #endif
            let cleaned = Self.stripJSONComments(from: raw)
            let expanded = Self.expandEnvironmentVariables(in: cleaned)
            if let data = expanded.data(using: .utf8) {
                return try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        } catch {
            self.logger.error("Failed to load config.json: \(error.localizedDescription)")
        }
        return nil
    }

    private func ensureProfileDirectoryExists() throws {
        let dir = self.profileDirectoryPath()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private func profileDirectoryPath() -> String {
        TachikomaConfiguration.profileDirectoryPath
    }

    private func profileConfigPath() -> String {
        "\(self.profileDirectoryPath())/config.json"
    }

    // MARK: JSONC + ENV utilities (shared minimal)

    static func stripJSONComments(from json: String) -> String {
        var result = ""
        var inString = false
        var escapeNext = false
        var inSingle = false
        var inMulti = false
        let chars = Array(json)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let n: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if escapeNext {
                result.append(c)
                escapeNext = false
                i += 1
                continue
            }
            if c == "\\", inString {
                escapeNext = true
                result.append(c)
                i += 1
                continue
            }
            if c == "\"", !inSingle, !inMulti {
                inString.toggle()
                result.append(c)
                i += 1
                continue
            }
            if inString {
                result.append(c)
                i += 1
                continue
            }
            if c == "/", n == "/", !inMulti {
                inSingle = true
                i += 2
                continue
            }
            if c == "/", n == "*", !inSingle {
                inMulti = true
                i += 2
                continue
            }
            if c == "\n", inSingle {
                inSingle = false
                result.append(c)
                i += 1
                continue
            }
            if c == "*", n == "/", inMulti {
                inMulti = false
                i += 2
                continue
            }
            if !inSingle, !inMulti {
                result.append(c)
            }
            i += 1
        }
        return result
    }

    static func expandEnvironmentVariables(in text: String) -> String {
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches {
            let nameRange = m.range(at: 1)
            let fullRange = m.range(at: 0)
            if
                nameRange.location != NSNotFound, let swiftName = Range(nameRange, in: text), let swiftFull = Range(
                    fullRange,
                    in: text,
                )
            {
                let name = String(text[swiftName])
                if let val = ProcessInfo.processInfo.environment[name] {
                    result.replaceSubrange(swiftFull, with: val)
                }
            }
        }
        return result
    }
}

#if DEBUG
extension TachikomaMCPClientManager {
    public static func _setAutoConnectOverrideForTesting(_ value: Bool?) {
        AutoConnectPolicy.setOverride(value)
    }
}
#endif
