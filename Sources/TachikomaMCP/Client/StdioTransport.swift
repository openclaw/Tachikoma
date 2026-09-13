import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Logging
import MCP
import Tachikoma

private struct StdioConnectionResources: Sendable {
    let process: Process?
    let inputPipe: Pipe?
    let outputPipe: Pipe?
    let errorPipe: Pipe?
}

private struct StdioConnectionCloseResult: Sendable {
    let closed: Bool
    let resources: StdioConnectionResources?
    let pendingRequests: [CheckedContinuation<Data, Swift.Error>]
    let timeoutTasks: [Task<Void, Never>]
}

private enum StdioRequestRegistration: Equatable {
    case awaitingContinuation
    case cancelled
}

private enum StdioRequestRegistrationResult {
    case added
    case cancelled
    case closed
}

struct StdioTransportDebugSnapshot: Sendable, Equatable {
    let isConnected: Bool
    let pendingRequestCount: Int
    let timeoutTaskCount: Int
}

/// Actor to manage mutable state for Sendable conformance
private actor StdioTransportState {
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    var process: Process?
    var inputPipe: Pipe?
    var outputPipe: Pipe?
    var errorPipe: Pipe?
    var nextId: Int = 1
    private var requestRegistrations: [Int: StdioRequestRegistration] = [:]
    var pendingRequests: [String: CheckedContinuation<Data, Swift.Error>] = [:]
    var timeoutTasks: [Int: Task<Void, Never>] = [:]
    var requestTimeoutNs: UInt64 = 30_000_000_000 // default 30s

    func beginConnection(timeout: TimeInterval) -> UInt64 {
        self.generation &+= 1
        self.activeGeneration = self.generation
        self.requestTimeoutNs = UInt64((timeout > 0 ? timeout : 30) * 1_000_000_000)
        return self.generation
    }

    func installResources(
        process: Process,
        input: Pipe,
        output: Pipe,
        error: Pipe,
        generation: UInt64,
    )
        -> Bool
    {
        guard self.activeGeneration == generation else { return false }
        self.process = process
        self.inputPipe = input
        self.outputPipe = output
        self.errorPipe = error
        return true
    }

    func reserveRequest() -> (id: Int, generation: UInt64)? {
        guard let activeGeneration else { return nil }
        let id = self.nextId
        self.nextId += 1
        return (id, activeGeneration)
    }

    func beginRequestRegistration(id: Int, generation: UInt64) -> Bool {
        guard self.activeGeneration == generation else { return false }
        self.requestRegistrations[id] = .awaitingContinuation
        return true
    }

    func addPendingRequest(
        id: Int,
        generation: UInt64,
        continuation: CheckedContinuation<Data, Swift.Error>,
    )
        -> StdioRequestRegistrationResult
    {
        guard self.activeGeneration == generation else {
            self.requestRegistrations.removeValue(forKey: id)
            return .closed
        }
        switch self.requestRegistrations.removeValue(forKey: id) {
        case .awaitingContinuation:
            break
        case .cancelled:
            return .cancelled
        case nil:
            return .closed
        }
        self.pendingRequests[String(id)] = continuation
        return .added
    }

    func cancelRequest(
        id: Int,
        generation: UInt64,
    )
        -> CheckedContinuation<Data, Swift.Error>?
    {
        guard self.activeGeneration == generation else { return nil }
        self.timeoutTasks.removeValue(forKey: id)?.cancel()
        if let continuation = self.pendingRequests.removeValue(forKey: String(id)) {
            return continuation
        }
        if self.requestRegistrations[id] == .awaitingContinuation {
            self.requestRegistrations[id] = .cancelled
        }
        return nil
    }

    func failRequest(
        id: Int,
        generation: UInt64,
    )
        -> CheckedContinuation<Data, Swift.Error>?
    {
        guard self.activeGeneration == generation else { return nil }
        self.timeoutTasks.removeValue(forKey: id)?.cancel()
        return self.pendingRequests.removeValue(forKey: String(id))
    }

    func takePendingResponse(
        id: String,
        numericID: Int,
        generation: UInt64,
    )
        -> CheckedContinuation<Data, Swift.Error>?
    {
        guard self.activeGeneration == generation else { return nil }
        self.timeoutTasks.removeValue(forKey: numericID)?.cancel()
        return self.pendingRequests.removeValue(forKey: id)
    }

    func expireRequest(
        id: Int,
        generation: UInt64,
    )
        -> CheckedContinuation<Data, Swift.Error>?
    {
        guard self.activeGeneration == generation else { return nil }
        self.timeoutTasks.removeValue(forKey: id)
        return self.pendingRequests.removeValue(forKey: String(id))
    }

    func addTimeoutTask(id: Int, generation: UInt64, task: Task<Void, Never>) -> Bool {
        guard self.activeGeneration == generation, self.pendingRequests[String(id)] != nil else {
            task.cancel()
            return false
        }
        self.timeoutTasks[id] = task
        return true
    }

    func currentGeneration() -> UInt64? {
        self.activeGeneration
    }

    func isActive(generation: UInt64) -> Bool {
        self.activeGeneration == generation
    }

    func closeConnection(generation: UInt64? = nil) -> StdioConnectionCloseResult {
        if let generation, generation != self.activeGeneration {
            return StdioConnectionCloseResult(
                closed: false,
                resources: nil,
                pendingRequests: [],
                timeoutTasks: [],
            )
        }
        guard self.activeGeneration != nil else {
            return StdioConnectionCloseResult(
                closed: false,
                resources: nil,
                pendingRequests: [],
                timeoutTasks: [],
            )
        }

        self.activeGeneration = nil
        self.requestRegistrations.removeAll()
        let pendingRequests = Array(self.pendingRequests.values)
        self.pendingRequests.removeAll()
        let timeoutTasks = Array(self.timeoutTasks.values)
        self.timeoutTasks.removeAll()

        let resources = StdioConnectionResources(
            process: self.process,
            inputPipe: self.inputPipe,
            outputPipe: self.outputPipe,
            errorPipe: self.errorPipe,
        )
        self.process = nil
        self.inputPipe = nil
        self.outputPipe = nil
        self.errorPipe = nil
        return StdioConnectionCloseResult(
            closed: true,
            resources: resources,
            pendingRequests: pendingRequests,
            timeoutTasks: timeoutTasks,
        )
    }

    func debugSnapshot() -> StdioTransportDebugSnapshot {
        StdioTransportDebugSnapshot(
            isConnected: self.activeGeneration != nil,
            pendingRequestCount: self.pendingRequests.count,
            timeoutTaskCount: self.timeoutTasks.count,
        )
    }
}

/// Serializes complete JSON-line frames onto the stdio request pipe.
///
/// A single MCP connection can execute tools concurrently. Keeping payload and delimiter
/// construction inside this actor prevents request bytes from interleaving across callers.
actor StdioFrameWriter {
    private var handle: FileHandle?
    private var generation: UInt64?

    func install(_ handle: FileHandle, generation: UInt64) {
        self.handle = handle
        self.generation = generation
    }

    func removeHandle(generation: UInt64? = nil) {
        if let generation, generation != self.generation {
            return
        }
        self.handle = nil
        self.generation = nil
    }

    func write(payload: Data, generation: UInt64) throws {
        guard generation == self.generation, let handle else {
            throw MCPError.transportClosed
        }

        var frame = payload
        frame.append(0x0A)
        try handle.write(contentsOf: frame)
    }
}

/// Standard I/O transport for MCP communication
public final class StdioTransport: MCPTransport {
    private let state = StdioTransportState()
    private let frameWriter = StdioFrameWriter()
    private let connectionClosed: @Sendable (MCPError) async -> Void
    private let logger = Logger(label: "tachikoma.mcp.stdio")
    private static let _sigpipeHandlerInstalled: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private let debugStdoutHandle: FileHandle?
    private let debugStderrHandle: FileHandle?
    private let debugQueue = DispatchQueue(label: "tachikoma.mcp.stdio.debug")
    private let stdoutQueue = DispatchQueue(label: "tachikoma.mcp.stdio.stdout")
    private let stderrQueue = DispatchQueue(label: "tachikoma.mcp.stdio.stderr")
    private let sourceLock = NSLock()
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    public convenience init() {
        self.init { _ in }
    }

    init(onConnectionClosed: @escaping @Sendable (MCPError) async -> Void) {
        Self._sigpipeHandlerInstalled
        self.connectionClosed = onConnectionClosed
        self.debugStdoutHandle = Self.makeDebugHandle(for: "MCP_STDIO_STDOUT")
        self.debugStderrHandle = Self.makeDebugHandle(for: "MCP_STDIO_STDERR")
    }

    public func connect(config: MCPServerConfig) async throws {
        self.logger.info("Starting stdio transport with command: \(config.command)")
        await self.disconnect()

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        // Keep stderr separate; mixing can corrupt frame boundaries
        process.standardError = errorPipe

        // Parse command and arguments
        let components = config.command.split(separator: " ").map(String.init)
        guard !components.isEmpty else {
            throw MCPError.executionFailed("Invalid command")
        }

        // Set executable path
        if components[0].starts(with: "/") {
            process.executableURL = URL(fileURLWithPath: components[0])
            process.arguments = config.args.isEmpty ? Array(components.dropFirst()) : config.args
        } else {
            // Use which to find the executable
            let whichProcess = Process()
            let whichPipe = Pipe()
            whichProcess.standardOutput = whichPipe
            whichProcess.standardError = FileHandle.nullDevice
            whichProcess.launchPath = "/usr/bin/which"
            whichProcess.arguments = [components[0]]

            do {
                try whichProcess.run()
                whichProcess.waitUntilExit()

                if whichProcess.terminationStatus == 0 {
                    let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                    if
                        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !path.isEmpty
                    {
                        process.executableURL = URL(fileURLWithPath: path)
                        process.arguments = config.args.isEmpty ? Array(components.dropFirst()) : config.args
                    } else {
                        throw MCPError.connectionFailed("Command not found: \(components[0])")
                    }
                } else {
                    throw MCPError.connectionFailed("Command not found: \(components[0])")
                }
            } catch {
                throw MCPError.connectionFailed("Failed to locate command: \(components[0])")
            }
        }

        // Set environment - always inherit current environment and merge custom vars
        process.environment = ProcessInfo.processInfo.environment.merging(config.env) { _, new in new }
        let generation = await self.state.beginConnection(timeout: config.timeout)
        process.terminationHandler = { [weak self] _ in
            Task {
                await self?.closeConnection(generation: generation, terminateProcess: false)
            }
        }

        // Start process
        do {
            try process.run()
        } catch {
            let connectionError = MCPError.connectionFailed("Failed to start process: \(error)")
            await self.closeConnection(
                generation: generation,
                error: connectionError,
                terminateProcess: false,
            )
            throw connectionError
        }

        // Close parent's write ends for stdout/stderr so EOF is detected promptly
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        guard
            await self.state.installResources(
                process: process,
                input: inputPipe,
                output: outputPipe,
                error: errorPipe,
                generation: generation,
            ) else
        {
            self.closePipe(inputPipe)
            self.closePipe(outputPipe)
            self.closePipe(errorPipe)
            self.terminateProcess(process)
            throw MCPError.transportClosed
        }
        await self.frameWriter.install(inputPipe.fileHandleForWriting, generation: generation)
        guard await self.state.isActive(generation: generation) else {
            await self.frameWriter.removeHandle(generation: generation)
            throw MCPError.transportClosed
        }

        self.logger.info("About to start reading output")
        let stdoutSource = self.makeReadSource(for: outputPipe, isStderr: false, generation: generation)
        let stderrSource = self.makeReadSource(for: errorPipe, isStderr: true, generation: generation)
        self.sourceLock.withLock {
            self.stdoutSource = stdoutSource
            self.stderrSource = stderrSource
        }

        self.logger.info("Stdio transport connected")
    }

    public func disconnect() async {
        self.logger.info("Disconnecting stdio transport")
        await self.closeConnection(error: .transportClosed, terminateProcess: true)
    }

    deinit {
        self.closeDebugHandles()
    }

    public func sendRequest<R: Decodable>(
        method: String,
        params: some Encodable,
    ) async throws
        -> R
    {
        guard let request = await state.reserveRequest() else {
            throw MCPError.transportClosed
        }
        let id = request.id
        let generation = request.generation

        // Create JSON-RPC request with canonical key order
        var dict: [String: Any] = [:]
        dict["jsonrpc"] = "2.0"
        dict["method"] = method
        let paramsData = try JSONEncoder().encode(params)
        let paramsObj = try JSONSerialization.jsonObject(with: paramsData)
        dict["params"] = paramsObj
        dict["id"] = id
        let data = try JSONSerialization.data(withJSONObject: dict)
        if method == "initialize", let json = String(data: data, encoding: .utf8) {
            self.logger.info("[MCP stdio] → initialize payload: \(json)")
        }

        guard await self.state.beginRequestRegistration(id: id, generation: generation) else {
            throw MCPError.transportClosed
        }
        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    switch await self.state.addPendingRequest(
                        id: id,
                        generation: generation,
                        continuation: continuation,
                    ) {
                    case .added:
                        break
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                        return
                    case .closed:
                        continuation.resume(throwing: MCPError.transportClosed)
                        return
                    }
                    let timeoutTask = Task { [logger] in
                        let ns = await state.requestTimeoutNs
                        do {
                            try await Task.sleep(nanoseconds: ns)
                        } catch {
                            return
                        }
                        if let pending = await state.expireRequest(id: id, generation: generation) {
                            logger.error("MCP stdio request timed out: method=\(method), id=\(id)")
                            pending
                                .resume(
                                    throwing: MCPError.executionFailed(
                                        "Request timed out after \(ns / 1_000_000)ms",
                                    ),
                                )
                        }
                    }
                    guard await self.state.addTimeoutTask(id: id, generation: generation, task: timeoutTask) else {
                        return
                    }

                    do {
                        try await self.send(data, generation: generation)
                    } catch {
                        if let pending = await self.state.failRequest(id: id, generation: generation) {
                            pending.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            Task { [state] in
                if let pending = await state.cancelRequest(id: id, generation: generation) {
                    pending.resume(throwing: CancellationError())
                }
            }
        }

        // Decode response
        let response = try JSONDecoder().decode(JSONRPCResponse<R>.self, from: responseData)

        if let error = response.error {
            throw MCPError.executionFailed(error.message)
        }

        guard let result = response.result else {
            throw MCPError.invalidResponse
        }

        return result
    }

    public func sendNotification(
        method: String,
        params: some Encodable,
    ) async throws {
        // Create JSON-RPC notification (no id)
        let notification = JSONRPCNotification(
            jsonrpc: "2.0",
            method: method,
            params: params,
        )

        // Encode and send
        let data = try JSONEncoder().encode(notification)
        try await self.send(data)
    }

    private func send(_ data: Data) async throws {
        guard let generation = await self.state.currentGeneration() else {
            throw MCPError.transportClosed
        }
        try await self.send(data, generation: generation)
    }

    private func send(_ data: Data, generation: UInt64) async throws {
        guard await self.state.isActive(generation: generation) else {
            throw MCPError.transportClosed
        }
        // MCP TypeScript SDK uses simple newline-delimited JSON, NOT LSP-style framing
        try await self.frameWriter.write(payload: data, generation: generation)

        // Log what we sent for debugging
        if let json = String(data: data, encoding: .utf8) {
            self.logger.debug("[MCP stdio] → sent: \(json)")
        }
    }

    private func makeReadSource(
        for pipe: Pipe,
        isStderr: Bool,
        generation: UInt64,
    )
        -> DispatchSourceRead?
    {
        let fileHandle = pipe.fileHandleForReading
        let fd = fileHandle.fileDescriptor
        let currentFlags = fcntl(fd, F_GETFL)
        if currentFlags != -1 {
            _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        }

        let queue = isStderr ? self.stderrQueue : self.stdoutQueue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer[0..<count])
                    self.handleBytes(data, isStderr: isStderr, generation: generation)
                    continue
                }
                if count == 0 {
                    self.logger.debug("[MCP stdio] \(isStderr ? "stderr" : "stdout") pipe closed")
                    source.cancel()
                    if !isStderr {
                        Task {
                            await self.closeConnection(generation: generation, terminateProcess: true)
                        }
                    }
                    break
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                self.logger.error("[MCP stdio] Read error: \(String(cString: strerror(errno)))")
                source.cancel()
                if !isStderr {
                    Task {
                        await self.closeConnection(generation: generation, terminateProcess: true)
                    }
                }
                break
            }
        }
        source.resume()
        return source
    }

    private func handleBytes(_ chunk: Data, isStderr: Bool, generation: UInt64) {
        guard !chunk.isEmpty else { return }
        if isStderr {
            self.stderrBuffer.append(chunk)
            self.writeDebug(chunk, handle: self.debugStderrHandle)
            self.consumeBuffer(&self.stderrBuffer, isStderr: true)
        } else {
            self.stdoutBuffer.append(chunk)
            self.writeDebug(chunk, handle: self.debugStdoutHandle)
            self.consumeBuffer(&self.stdoutBuffer, isStderr: false, generation: generation)
        }
    }

    private func consumeBuffer(
        _ buffer: inout Data,
        isStderr: Bool,
        generation: UInt64? = nil,
    ) {
        if isStderr {
            while let line = Self.consumeLine(from: &buffer) {
                guard !line.isEmpty else { continue }
                if let message = String(data: line, encoding: .utf8), !message.isEmpty {
                    self.logger.debug("[MCP stdio][stderr] \(message)")
                }
            }
            return
        }

        while let framed = Self.extractFramedMessageBytes(from: &buffer) {
            if let json = String(data: framed, encoding: .utf8) {
                self.logger.debug("[MCP stdio] ← framed: \(json)")
            }
            if let generation {
                Task { await self.handleResponse(framed, generation: generation) }
            }
        }

        while let line = Self.consumeLine(from: &buffer) {
            guard !line.isEmpty else { continue }
            if let json = String(data: line, encoding: .utf8) {
                self.logger.debug("[MCP stdio] ← received: \(json)")
            }
            if let generation {
                Task { await self.handleResponse(line, generation: generation) }
            }
        }
    }

    private static func consumeLine(from buffer: inout Data) -> Data? {
        guard let newlineIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
            return nil
        }
        let line = buffer[..<newlineIndex]
        var removeEnd = buffer.index(after: newlineIndex)
        if
            buffer[newlineIndex] == 0x0D,
            removeEnd < buffer.endIndex,
            buffer[removeEnd] == 0x0A
        {
            removeEnd = buffer.index(after: removeEnd)
        }
        buffer.removeSubrange(buffer.startIndex..<removeEnd)
        return Data(line)
    }

    private static func extractFramedMessageBytes(from buffer: inout Data) -> Data? {
        guard
            let headerEndRange = buffer.range(of: Data([13, 10, 13, 10])) ??
            buffer.range(of: Data([10, 10])) else
        {
            return nil
        }

        let header = buffer[..<headerEndRange.lowerBound]
        guard let headerString = String(data: header, encoding: .utf8) else {
            return nil
        }
        let lowerHeader = headerString.lowercased()
        guard let tokenRange = lowerHeader.range(of: "content-length:") else {
            return nil
        }

        var digitIndex = tokenRange.upperBound
        while digitIndex < lowerHeader.endIndex, lowerHeader[digitIndex] == " " {
            digitIndex = lowerHeader.index(after: digitIndex)
        }

        var digitsEnd = digitIndex
        while digitsEnd < lowerHeader.endIndex, lowerHeader[digitsEnd].isNumber {
            digitsEnd = lowerHeader.index(after: digitsEnd)
        }

        guard digitsEnd > digitIndex else { return nil }
        let lengthSubstring = lowerHeader[digitIndex..<digitsEnd]
        guard let length = Int(lengthSubstring) else { return nil }

        let headerBytes = buffer.distance(from: buffer.startIndex, to: headerEndRange.upperBound)
        guard buffer.count >= headerBytes + length else { return nil }

        let bodyStart = buffer.index(buffer.startIndex, offsetBy: headerBytes)
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = buffer[bodyStart..<bodyEnd]
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return Data(body)
    }

    private func handleResponse(_ data: Data, generation: UInt64) async {
        // Try to parse as a response with ID
        if
            let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = response["id"] as? Int
        {
            if
                let continuation = await state.takePendingResponse(
                    id: String(id),
                    numericID: id,
                    generation: generation,
                )
            {
                continuation.resume(returning: data)
            }
        } else if
            let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let idString = response["id"] as? String,
            let idInt = Int(idString)
        {
            if
                let continuation = await state.takePendingResponse(
                    id: idString,
                    numericID: idInt,
                    generation: generation,
                )
            {
                continuation.resume(returning: data)
            }
        } else if
            let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let idNull = response["id"], idNull is NSNull
        {
            // Some servers return null id for notifications; ignore
        }
        // Otherwise it might be a notification or other message
    }

    var debugSnapshot: StdioTransportDebugSnapshot {
        get async {
            await self.state.debugSnapshot()
        }
    }

    private func closeConnection(
        generation: UInt64? = nil,
        error: MCPError = .transportClosed,
        terminateProcess: Bool,
    ) async {
        let closeResult = await self.state.closeConnection(generation: generation)
        guard closeResult.closed else { return }

        await self.frameWriter.removeHandle(generation: generation)
        await self.connectionClosed(error)
        closeResult.timeoutTasks.forEach { $0.cancel() }
        closeResult.pendingRequests.forEach { $0.resume(throwing: error) }
        self.cancelReadSources()
        self.stdoutQueue.sync { self.stdoutBuffer.removeAll(keepingCapacity: false) }
        self.stderrQueue.sync { self.stderrBuffer.removeAll(keepingCapacity: false) }
        self.closeDebugHandles()

        if let resources = closeResult.resources {
            self.closePipe(resources.inputPipe)
            self.closePipe(resources.outputPipe)
            self.closePipe(resources.errorPipe)
            if terminateProcess {
                self.terminateProcess(resources.process)
            }
        }
    }

    private func cancelReadSources() {
        let sources = self.sourceLock.withLock { () -> (DispatchSourceRead?, DispatchSourceRead?) in
            defer {
                self.stdoutSource = nil
                self.stderrSource = nil
            }
            return (self.stdoutSource, self.stderrSource)
        }
        sources.0?.cancel()
        sources.1?.cancel()
    }

    private func closePipe(_ pipe: Pipe?) {
        guard let pipe else { return }
        do {
            try pipe.fileHandleForWriting.close()
        } catch {
            // ignore
        }
        do {
            try pipe.fileHandleForReading.close()
        } catch {
            // ignore
        }
    }

    private func terminateProcess(_ process: Process?) {
        guard let process else { return }

        if process.isRunning {
            process.terminate()
        }

        if !self.waitForProcessExit(process, timeout: 0.7) {
            kill(process.processIdentifier, SIGTERM)
            if !self.waitForProcessExit(process, timeout: 0.7) {
                kill(process.processIdentifier, SIGKILL)
                _ = self.waitForProcessExit(process, timeout: 0.3)
            }
        }
    }

    private func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    private static func makeDebugHandle(for envKey: String) -> FileHandle? {
        guard let path = ProcessInfo.processInfo.environment[envKey], !path.isEmpty else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            return handle
        } catch {
            return nil
        }
    }

    private func writeDebug(_ data: Data, handle: FileHandle?) {
        guard let handle, !data.isEmpty else { return }
        self.debugQueue.async {
            do {
                try handle.write(contentsOf: data)
            } catch {
                // Ignore debug output failures entirely.
            }
        }
    }

    private func closeDebugHandles() {
        try? self.debugStdoutHandle?.close()
        try? self.debugStderrHandle?.close()
    }
}

extension StdioTransport: @unchecked Sendable {}
