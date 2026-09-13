import Foundation
import Testing
@testable import TachikomaMCP

@Suite("Stdio frame writer")
struct StdioFrameWriterTests {
    @Test(.timeLimit(.minutes(1)))
    func `Concurrent sends preserve complete JSON lines`() async throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let (outputStream, outputContinuation) = AsyncStream<Data>.makeStream()
        // Drain concurrently: a pipe cannot buffer the entire batch before the first read.
        DispatchQueue.global().async {
            outputContinuation.yield(pipe.fileHandleForReading.readDataToEndOfFile())
            outputContinuation.finish()
        }
        let writer = StdioFrameWriter()
        let generation: UInt64 = 42
        await writer.install(pipe.fileHandleForWriting, generation: generation)

        let padding = String(repeating: "x", count: 1024)
        let payloads = (0..<512).map { Data("{\"id\":\($0),\"padding\":\"\(padding)\"}".utf8) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    try await writer.write(payload: payload, generation: generation)
                }
            }
            try await group.waitForAll()
        }

        await writer.removeHandle()
        try pipe.fileHandleForWriting.close()
        let capturedOutput = await outputStream.first { _ in true }
        let output = try #require(capturedOutput)
        let outputString = try #require(String(bytes: output, encoding: .utf8))
        let components = outputString.components(separatedBy: "\n")
        let lines = components.dropLast().map { Data($0.utf8) }

        #expect(output.last == 0x0A)
        #expect(components.last?.isEmpty == true)
        #expect(lines.count == payloads.count)
        #expect(Set(lines) == Set(payloads))
    }

    @Test
    func `Writes fail when no request pipe is installed`() async {
        let writer = StdioFrameWriter()

        await #expect(throws: MCPError.self) {
            try await writer.write(payload: Data("{}".utf8), generation: 42)
        }
    }

    @Test
    func `Superseded generation cannot write into replacement pipe`() async throws {
        let firstPipe = Pipe()
        let secondPipe = Pipe()
        let writer = StdioFrameWriter()
        await writer.install(firstPipe.fileHandleForWriting, generation: 1)
        await writer.install(secondPipe.fileHandleForWriting, generation: 2)

        await #expect(throws: MCPError.transportClosed) {
            try await writer.write(payload: Data("old".utf8), generation: 1)
        }
        try await writer.write(payload: Data("new".utf8), generation: 2)

        await writer.removeHandle(generation: 1)
        try await writer.write(payload: Data("current".utf8), generation: 2)
        await writer.removeHandle(generation: 2)
        try secondPipe.fileHandleForWriting.close()
        let output = secondPipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(bytes: output, encoding: .utf8) == "new\ncurrent\n")
    }
}
