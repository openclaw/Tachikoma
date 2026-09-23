import Foundation
import Testing
@testable import TachikomaMCP

@Suite("MCP probe timeouts")
@MainActor
struct ProbeTimeoutTests {
    @Test
    func `Probe timeout nanoseconds converts finite positive milliseconds`() {
        #expect(ProbeTimeoutNanoseconds.fromMilliseconds(0) == 0)
        #expect(ProbeTimeoutNanoseconds.fromMilliseconds(1) == 1_000_000)
        #expect(ProbeTimeoutNanoseconds.fromMilliseconds(5000) == 5_000_000_000)
    }

    @Test(arguments: [-1, Int.min, Int.max])
    func `Probe timeout nanoseconds rejects values that trap UInt64`(timeoutMs: Int) {
        #expect(ProbeTimeoutNanoseconds.fromMilliseconds(timeoutMs) == nil)
    }

    @Test(arguments: [-1, Int.max])
    func `probeServer rejects invalid timeoutMs before sleeping`(timeoutMs: Int) async {
        let manager = TachikomaMCPClientManager()
        await manager.initialize(
            with: ["probe": MCPServerConfig(command: "never-executed")],
            connect: false,
        )

        let result = await manager.probeServer(name: "probe", timeoutMs: timeoutMs)

        #expect(result.isConnected == false)
        #expect(result.toolCount == 0)
        #expect(result.error?.contains("invalid timeout") == true)
    }

    @Test
    func `probeServer preserves zero as an immediate deadline`() async {
        let manager = TachikomaMCPClientManager()
        await manager.initialize(
            with: ["probe": MCPServerConfig(command: "/tachikoma-nonexistent-command")],
            connect: false,
        )

        let result = await manager.probeServer(name: "probe", timeoutMs: 0)

        #expect(result.isConnected == false)
        #expect(result.error != nil)
        #expect(result.error?.contains("invalid timeout") == false)
    }
}
