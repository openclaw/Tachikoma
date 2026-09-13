import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import MCP

/// Internal state for SSE transport
actor SSEState {
    var transport: HTTPClientTransport?
    var baseURL: URL?
    var endpointURL: URL?
    var headers: [String: String] = [:]
    var nextId: Int = 1
    var pendingRequests: [Int: CheckedContinuation<Data, Swift.Error>] = [:]
    var timeoutTasks: [Int: Task<Void, Never>] = [:]
    var readingTask: Task<Void, Never>?
    var readingGeneration: UInt64 = 0
    var requestTimeoutNs: UInt64 = 30_000_000_000 // default 30s

    func getTransport() -> HTTPClientTransport? {
        self.transport
    }

    @discardableResult
    func setEndpoint(_ url: URL?, readerGeneration: UInt64? = nil) -> Bool {
        if let readerGeneration, readerGeneration != self.readingGeneration {
            return false
        }
        self.endpointURL = url
        return true
    }

    func getEndpoint() -> URL? {
        self.endpointURL
    }

    func getBaseURL() -> URL? {
        self.baseURL
    }

    func getNextId() -> Int {
        defer { nextId += 1 }
        return self.nextId
    }

    func addPending(_ id: Int, _ cont: CheckedContinuation<Data, Swift.Error>) {
        self.pendingRequests[id] = cont
    }

    func removePending(_ id: Int) -> CheckedContinuation<Data, Swift.Error>? {
        self.pendingRequests
            .removeValue(forKey: id)
    }

    private func setTimeout(_ seconds: TimeInterval) {
        self.requestTimeoutNs = UInt64((seconds > 0 ? seconds : 30) * 1_000_000_000)
    }

    func addTimeoutTask(_ id: Int, _ task: Task<Void, Never>) {
        self.timeoutTasks[id] = task
    }

    @discardableResult
    func cancelAll(_ error: Swift.Error, readerGeneration: UInt64? = nil) -> Bool {
        if let readerGeneration, readerGeneration != self.readingGeneration {
            return false
        }
        for (_, c) in self.pendingRequests {
            c.resume(throwing: error)
        }
        self.pendingRequests.removeAll()
        for (_, t) in self.timeoutTasks {
            t.cancel()
        }
        self.timeoutTasks.removeAll()
        return true
    }

    func installConnection(
        transport: HTTPClientTransport,
        baseURL: URL,
        headers: [String: String],
        timeout: TimeInterval,
        read: @escaping @Sendable (HTTPClientTransport, UInt64) async -> Void,
    )
        -> HTTPClientTransport?
    {
        let previousTransport = self.transport
        self.readingTask?.cancel()
        self.readingGeneration &+= 1
        let generation = self.readingGeneration
        self.cancelAll(MCPError.connectionFailed("SSE transport reconnected"))
        self.transport = transport
        self.baseURL = baseURL
        self.endpointURL = baseURL
        self.headers = headers
        self.setTimeout(timeout)
        self.readingTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await read(transport, generation)
            await self?.finishReading(generation: generation)
        }
        return previousTransport
    }

    func removeConnection(
        _ error: Swift.Error,
        readerGeneration: UInt64? = nil,
    )
        -> (removed: Bool, transport: HTTPClientTransport?)
    {
        if let readerGeneration, readerGeneration != self.readingGeneration {
            return (false, nil)
        }
        let previousTransport = self.transport
        self.readingGeneration &+= 1
        self.readingTask?.cancel()
        self.readingTask = nil
        self.cancelAll(error)
        self.transport = nil
        self.baseURL = nil
        self.endpointURL = nil
        self.headers = [:]
        return (true, previousTransport)
    }

    private func finishReading(generation: UInt64) {
        guard generation == self.readingGeneration else { return }
        self.readingTask = nil
    }

    func isActiveReader(generation: UInt64) -> Bool {
        generation == self.readingGeneration
    }

    func takePendingResponse(id: Int, readerGeneration: UInt64) -> CheckedContinuation<Data, Swift.Error>? {
        guard readerGeneration == self.readingGeneration else { return nil }
        self.timeoutTasks.removeValue(forKey: id)?.cancel()
        return self.pendingRequests.removeValue(forKey: id)
    }

    func pendingRequestCount() -> Int {
        self.pendingRequests.count
    }
}

/// SSE (HTTP streaming) transport using swift-sdk HTTPClientTransport
public final class SSETransport: MCPTransport {
    private let logger = Logger(label: "tachikoma.mcp.sse")
    private let state = SSEState()
    private let urlSession = URLSession(configuration: .ephemeral)

    public init() {}

    public func connect(config: MCPServerConfig) async throws {
        guard let url = URL(string: config.command) else {
            throw MCPError.connectionFailed("Invalid URL: \(config.command)")
        }
        // Per AI SDK, the SSE GET uses Accept: text/event-stream. Also forward any custom headers (e.g., Authorization)
        var getHeaders = [
            "Accept": "text/event-stream",
        ]
        if let custom = config.headers {
            for (k, v) in custom {
                getHeaders[k] = v
            }
        }
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.httpAdditionalHeaders = getHeaders
        let transport = HTTPClientTransport(
            endpoint: url,
            configuration: sessionConfiguration,
            streaming: true,
            sseInitializationTimeout: min(max(config.timeout, 1), 60),
        )
        try await transport.connect()
        let previousTransport = await self.state.installConnection(
            transport: transport,
            baseURL: url,
            headers: config.headers ?? [:],
            timeout: config.timeout,
        ) { [weak self] transport, generation in
            await self?.readEvents(transport: transport, generation: generation)
        }
        if let previousTransport {
            await previousTransport.disconnect()
        }
        let verifyEndpoint = await state.getEndpoint()
        self.logger.info("SSE transport connected: \(url), endpoint set to: \(verifyEndpoint?.absoluteString ?? "nil")")
    }

    public func disconnect() async {
        self.logger.info("Disconnecting SSE transport")
        let removal = await state.removeConnection(MCPError.notConnected)
        if let t = removal.transport {
            await t.disconnect()
        }
    }

    /// Expose underlying swift-sdk HTTP transport for advanced usage
    public func underlyingSDKTransport() async -> HTTPClientTransport? {
        await self.state.getTransport()
    }

    public func sendRequest<R: Decodable>(
        method: String,
        params: some Encodable,
    ) async throws
        -> R
    {
        let id = await state.getNextId()
        // Build JSON-RPC request
        var dict: [String: Any] = [:]
        dict["jsonrpc"] = "2.0"
        dict["method"] = method
        let paramsData = try JSONEncoder().encode(params)
        let paramsObj = try JSONSerialization.jsonObject(with: paramsData)
        dict["params"] = paramsObj
        dict["id"] = id
        let postBody = try JSONSerialization.data(withJSONObject: dict)

        // Ensure endpoint is available - either from 'endpoint' event or base URL
        guard let endpoint = await state.getEndpoint() else {
            let baseURL = await state.getBaseURL()
            self.logger
                .error(
                    "SSE endpoint not established before send; method=\(method), baseURL=\(baseURL?.absoluteString ?? "nil")",
                )
            throw MCPError.connectionFailed("SSE endpoint not established")
        }
        self.logger.debug("Using endpoint: \(endpoint.absoluteString) for method=\(method)")

        // Register pending BEFORE POSTing
        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
            Data,
            Swift.Error,
        >) in
            Task {
                await self.state.addPending(id, continuation)
                // Schedule timeout
                let timeoutTask = Task { [logger] in
                    let ns = await state.requestTimeoutNs
                    try? await Task.sleep(nanoseconds: ns)
                    if let pending = await state.removePending(id) {
                        logger.error("MCP SSE request timed out: method=\(method), id=\(id)")
                        pending
                            .resume(throwing: MCPError.executionFailed("Request timed out after \(ns / 1_000_000)ms"))
                    }
                }
                await state.addTimeoutTask(id, timeoutTask)
                // Fire-and-forget POST to endpoint; responses arrive via SSE 'message'
                Task { [logger, endpoint] in
                    logger.info("[SSE] POSTing to endpoint: \(endpoint.absoluteString) method=\(method) id=\(id)")
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.httpBody = postBody
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // Context7 requires both application/json and text/event-stream in Accept header
                    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                    // Custom headers if any
                    let headers = await state.headers
                    for (k, v) in headers {
                        request.setValue(v, forHTTPHeaderField: k)
                    }
                    do {
                        let (respData, resp) = try await urlSession.data(for: request)
                        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                            let body = String(data: respData, encoding: .utf8) ?? "<non-utf8>"
                            logger
                                .error(
                                    "MCP SSE POST error: HTTP \(http.statusCode) for method=\(method), id=\(id) body=\(body)",
                                )
                        } else {
                            logger.debug("MCP SSE POST sent: method=\(method), id=\(id)")
                        }
                    } catch {
                        logger.error("MCP SSE POST failed: \(String(describing: error))")
                        // Do not fail continuation here; server might still deliver via SSE
                    }
                }
            }
        }

        // Decode JSON-RPC response when SSE delivers it
        let response = try JSONDecoder().decode(JSONRPCResponse<R>.self, from: responseData)
        if let error = response.error {
            throw MCPError.executionFailed(error.message)
        }
        guard let result = response.result else { throw MCPError.invalidResponse }
        return result
    }

    public func sendNotification(
        method: String,
        params: some Encodable,
    ) async throws {
        let note = JSONRPCNotification(jsonrpc: "2.0", method: method, params: params)
        let data = try JSONEncoder().encode(note)
        // Ensure endpoint
        guard let endpoint = await state.getEndpoint() else { throw MCPError.notConnected }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let headers = await state.headers
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        _ = try? await self.urlSession.data(for: request)
    }

    private func readEvents(transport: HTTPClientTransport, generation: UInt64) async {
        self.logger.debug("[SSE] Starting to read from transport stream")
        let stream = await transport.receive()
        var buffer = ""
        do {
            for try await data in stream {
                try Task.checkCancellation()
                guard await self.state.isActiveReader(generation: generation) else { return }
                guard let chunk = String(data: data, encoding: .utf8) else {
                    self.logger.debug("[SSE] Received non-UTF8 data of size \(data.count)")
                    continue
                }
                buffer += chunk
                // Process complete SSE events separated by double newlines
                while let range = buffer.range(of: "\n\n") {
                    let eventBlock = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    await self.processEventBlock(eventBlock, readerGeneration: generation)
                }
            }
            guard !Task.isCancelled else { return }
            guard await self.state.isActiveReader(generation: generation) else { return }
            self.logger.error("[SSE] Transport stream ended unexpectedly")
            await self.failConnection(
                MCPError.connectionFailed("SSE transport stream ended"),
                readerGeneration: generation,
            )
        } catch is CancellationError {
            self.logger.debug("[SSE] Reader stopped")
        } catch {
            guard await self.state.isActiveReader(generation: generation) else {
                self.logger.debug("[SSE] Superseded reader stopped")
                return
            }
            self.logger.error("[SSE] Reader failed: \(String(describing: error))")
            await self.failConnection(
                MCPError.connectionFailed("SSE transport stream failed: \(error.localizedDescription)"),
                readerGeneration: generation,
            )
        }
    }

    private func failConnection(_ error: Swift.Error, readerGeneration: UInt64) async {
        let removal = await state.removeConnection(error, readerGeneration: readerGeneration)
        if let transport = removal.transport {
            await transport.disconnect()
        }
    }

    private func processEventBlock(_ block: String, readerGeneration: UInt64) async {
        // Parse SSE block: lines like 'event: type' and 'data: payload'
        var eventType = "message" // default per SSE
        var dataLines: [String] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("event:") {
                let v = line.dropFirst("event:".count)
                eventType = v.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let v = line.dropFirst("data:".count)
                dataLines.append(v.trimmingCharacters(in: .whitespaces))
            }
        }
        let dataString = dataLines.joined(separator: "\n")
        self.logger.trace("[SSE] event=\(eventType) data=\(dataString)")
        switch eventType {
        case "endpoint":
            // Allow either a plain string URL or a JSON object: { "url": "/rpc" } or { "endpoint": "/rpc" }
            if let base = await state.baseURL {
                var endpointCandidate: String? = dataString
                if dataString.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                    if
                        let jsonData = dataString.data(using: .utf8),
                        let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                    {
                        if let urlValue = obj["url"] as? String {
                            endpointCandidate = urlValue
                        } else if let endpoint = obj["endpoint"] as? String {
                            endpointCandidate = endpoint
                        }
                    }
                }
                if let candidate = endpointCandidate, let url = URL(string: candidate, relativeTo: base) {
                    if url.host == base.host, url.scheme == base.scheme {
                        if await self.state.setEndpoint(url.absoluteURL, readerGeneration: readerGeneration) {
                            self.logger.info("[SSE] Endpoint established: \(url.absoluteString)")
                        }
                    } else {
                        self.logger.error("[SSE] Endpoint origin mismatch: \(url.absoluteString)")
                    }
                }
            }
        case "message":
            if let jsonData = dataString.data(using: .utf8) {
                await self.handleIncoming(jsonData, readerGeneration: readerGeneration)
            }
        default:
            // Ignore other events
            break
        }
    }

    private func handleIncoming(_ data: Data, readerGeneration: UInt64) async {
        // Try to parse as JSON object with id
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8) {
                self.logger.trace("[SSE] Received non-JSON event: \(text)")
            }
            return
        }
        // id may be int or string; we track by int ids we generate
        if let id = json["id"] as? Int {
            if let pending = await state.takePendingResponse(id: id, readerGeneration: readerGeneration) {
                pending.resume(returning: data)
            }
        } else if let idString = json["id"] as? String, let id = Int(idString) {
            if let pending = await state.takePendingResponse(id: id, readerGeneration: readerGeneration) {
                pending.resume(returning: data)
            }
        }
    }
}
