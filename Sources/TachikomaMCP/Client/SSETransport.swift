import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import MCP

final class SSERequestOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    var isCancelled: Bool {
        self.lock.withLock { self.cancelled }
    }

    func install(_ task: Task<Void, Never>) {
        let cancelled = self.lock.withLock {
            self.task = task
            return self.cancelled
        }
        if cancelled {
            task.cancel()
        }
    }

    func cancel() {
        let task = self.lock.withLock {
            self.cancelled = true
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
    }
}

actor SSEState {
    private var transport: HTTPClientTransport?
    private var nextId = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Swift.Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var operations: [Int: SSERequestOperation] = [:]
    private var readingTask: Task<Void, Never>?
    private var readingGeneration: UInt64 = 0
    private var timeoutNanoseconds: UInt64 = 30_000_000_000

    func getTransport(readerGeneration: UInt64? = nil) -> HTTPClientTransport? {
        if let readerGeneration, readerGeneration != self.readingGeneration {
            return nil
        }
        return self.transport
    }

    func connection() -> (transport: HTTPClientTransport, generation: UInt64)? {
        self.transport.map { ($0, self.readingGeneration) }
    }

    func getNextId() -> Int {
        defer { self.nextId += 1 }
        return self.nextId
    }

    func addPending(_ id: Int, _ continuation: CheckedContinuation<Data, Swift.Error>) {
        self.pendingRequests[id] = continuation
    }

    func registerPending(
        _ id: Int, continuation: CheckedContinuation<Data, Swift.Error>,
        generation: UInt64, operation: SSERequestOperation,
    )
        -> Bool
    {
        guard generation == self.readingGeneration, self.transport != nil else {
            continuation.resume(throwing: MCPError.notConnected)
            return false
        }
        guard !operation.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.pendingRequests[id] = continuation
        self.operations[id] = operation
        let timeout = self.timeoutNanoseconds
        self.timeoutTasks[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            await self?.failPending(
                id,
                generation: generation,
                error: MCPError.executionFailed("SSE request timed out"),
            )
        }
        return true
    }

    func failPending(_ id: Int, generation: UInt64, error: Swift.Error) {
        self.takePendingResponse(id: id, readerGeneration: generation)?.resume(throwing: error)
    }

    @discardableResult
    func cancelAll(_ error: Swift.Error, readerGeneration: UInt64? = nil) -> Bool {
        if let readerGeneration, readerGeneration != self.readingGeneration {
            return false
        }
        let pending = self.pendingRequests
        self.pendingRequests.removeAll()
        self.timeoutTasks.values.forEach { $0.cancel() }
        self.timeoutTasks.removeAll()
        self.operations.values.forEach { $0.cancel() }
        self.operations.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
        return true
    }

    func installConnection(
        transport: HTTPClientTransport, timeoutNanoseconds: UInt64,
        read: @escaping @Sendable (HTTPClientTransport, UInt64) async -> Void,
    )
        -> HTTPClientTransport?
    {
        let previous = self.transport
        self.readingTask?.cancel()
        self.readingGeneration &+= 1
        let generation = self.readingGeneration
        self.cancelAll(MCPError.connectionFailed("SSE transport reconnected"))
        self.transport = transport
        self.timeoutNanoseconds = timeoutNanoseconds
        self.readingTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await read(transport, generation)
            await self?.finishReading(generation: generation)
        }
        return previous
    }

    func removeConnection(
        _ error: Swift.Error, readerGeneration: UInt64? = nil,
    )
        -> (removed: Bool, transport: HTTPClientTransport?)
    {
        if let readerGeneration, readerGeneration != self.readingGeneration {
            return (false, nil)
        }
        let previous = self.transport
        self.readingGeneration &+= 1
        self.readingTask?.cancel()
        self.readingTask = nil
        self.cancelAll(error)
        self.transport = nil
        return (true, previous)
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
        self.operations.removeValue(forKey: id)?.cancel()
        return self.pendingRequests.removeValue(forKey: id)
    }

    func pendingRequestCount() -> Int {
        self.pendingRequests.count
    }
}

/// Streamable HTTP/SSE transport using one SDK-owned connection for sending and receiving.
public final class SSETransport: MCPTransport {
    private let logger = Logger(label: "tachikoma.mcp.sse")
    private let state = SSEState()
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    public init() {
        self.makeConfiguration = { .default }
    }

    init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.makeConfiguration = makeConfiguration
    }

    public func connect(config: MCPServerConfig) async throws {
        guard
            let url = URL(string: config.command),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else
        {
            throw MCPError.connectionFailed("Invalid SSE URL")
        }
        guard config.timeout.isFinite else { throw MCPError.connectionFailed("Invalid SSE timeout") }
        let timeout = config.timeout > 0 ? config.timeout : 30
        guard timeout <= Double(UInt64.max / 1_000_000_000) else {
            throw MCPError.connectionFailed("Invalid SSE timeout")
        }
        let configuration = self.makeConfiguration()
        let headers = config.headers ?? [:]
        let transport = HTTPClientTransport(
            endpoint: url, configuration: configuration, streaming: true,
            sseInitializationTimeout: min(max(timeout, 1), 60), protocolVersion: "2025-03-26",
        ) { request in
            var request = request
            for (name, value) in headers where request.value(forHTTPHeaderField: name) == nil {
                request.setValue(value, forHTTPHeaderField: name)
            }
            return request
        }
        try await transport.connect()
        let previous = await self.state.installConnection(
            transport: transport, timeoutNanoseconds: UInt64(timeout * 1_000_000_000),
        ) { [weak self] transport, generation in
            await self?.readEvents(transport: transport, generation: generation)
        }
        await previous?.disconnect()
        self.logger.info("SSE transport connected")
    }

    public func disconnect() async {
        let removal = await self.state.removeConnection(MCPError.notConnected)
        await removal.transport?.disconnect()
    }

    public func underlyingSDKTransport() async -> HTTPClientTransport? {
        await self.state.getTransport()
    }

    func updateProtocolVersion(_ version: String) async {
        await self.state.getTransport()?.updateNegotiatedProtocolVersion(version)
    }

    public func sendRequest<R: Decodable>(method: String, params: some Encodable) async throws -> R {
        try Task.checkCancellation()
        guard let connection = await self.state.connection() else { throw MCPError.notConnected }
        let id = await self.state.getNextId()
        let data = try JSONEncoder().encode(HTTPJSONRPCRequest(method: method, params: params, id: id))
        let operation = SSERequestOperation()
        let responseData: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = Task {
                    guard
                        await self.state.registerPending(
                            id, continuation: continuation, generation: connection.generation, operation: operation,
                        ) else { return }
                    do {
                        try Task.checkCancellation()
                        try await connection.transport.send(data)
                    } catch {
                        await self.state.failPending(id, generation: connection.generation, error: error)
                    }
                }
                operation.install(task)
            }
        } onCancel: {
            operation.cancel()
            Task { await self.state.failPending(id, generation: connection.generation, error: CancellationError()) }
        }
        let response = try JSONDecoder().decode(JSONRPCResponse<R>.self, from: responseData)
        if let error = response.error {
            throw MCPError.executionFailed(error.message)
        }
        guard let result = response.result else { throw MCPError.invalidResponse }
        return result
    }

    public func sendNotification(method: String, params: some Encodable) async throws {
        guard let connection = await self.state.connection() else { throw MCPError.notConnected }
        try await connection.transport.send(JSONEncoder().encode(
            JSONRPCNotification(jsonrpc: "2.0", method: method, params: params),
        ))
    }

    private func readEvents(transport: HTTPClientTransport, generation: UInt64) async {
        let stream = await transport.receive()
        do {
            for try await data in stream {
                try Task.checkCancellation()
                guard await self.state.isActiveReader(generation: generation) else { return }
                for message in SSEMessageDecoder.messages(from: data) {
                    guard
                        let id = try? JSONDecoder().decode(JSONRPCResponseHeader.self, from: message).responseID else { continue }
                    let requestID: Int? = switch id {
                    case let .int(value): value
                    case let .string(value): Int(value)
                    case .null: nil
                    }
                    if let requestID {
                        await self.state.takePendingResponse(id: requestID, readerGeneration: generation)?
                            .resume(returning: message)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            await self.failConnection(MCPError.connectionFailed("SSE transport stream ended"), generation: generation)
        } catch is CancellationError {
            return
        } catch {
            await self.failConnection(error, generation: generation)
        }
    }

    private func failConnection(_ error: Swift.Error, generation: UInt64) async {
        let removal = await self.state.removeConnection(error, readerGeneration: generation)
        await removal.transport?.disconnect()
    }
}
