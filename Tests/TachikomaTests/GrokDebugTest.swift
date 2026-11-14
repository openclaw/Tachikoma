import Foundation
import Testing
@testable import Tachikoma

@Test
func `Debug Grok streaming issue`() async throws {
    guard ProcessInfo.processInfo.environment["RUN_GROK_DEBUG_TESTS"] == "1" else {
        print("Skipping Grok debug stream: RUN_GROK_DEBUG_TESTS not set")
        return
    }

    if ProcessInfo.processInfo.environment["TACHIKOMA_TEST_MODE"] == "mock" {
        print("Skipping Grok streaming debug in mock mode")
        return
    }

    // Skip if no API key
    guard
        ProcessInfo.processInfo.environment["X_AI_API_KEY"] != nil ||
        ProcessInfo.processInfo.environment["XAI_API_KEY"] != nil else
    {
        print("Skipping: No Grok API key")
        return
    }

    print("Testing Grok-3 streaming...")

    // Enable debug output
    setenv("DEBUG_GROK", "1", 1)

    // Test with minimal setup
    let stream = try await stream(
        "Say hello",
        using: .grok(.grok43),
    )

    var receivedContent = false
    var content = ""

    for try await delta in stream {
        print("Received delta: \(delta.type)")
        if delta.type == .textDelta, let text = delta.content {
            content += text
            receivedContent = true
        }
        if delta.type == .done {
            print("Stream completed")
            break
        }
    }

    print("Final content: \(content)")
    #expect(receivedContent, "Should receive some content")
}
