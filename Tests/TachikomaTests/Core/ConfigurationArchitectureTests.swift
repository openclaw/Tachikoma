import Foundation
import Testing
@testable import Tachikoma
@testable import TachikomaAgent

extension TachikomaConfigurationTests {
    struct ConfigurationArchitectureTests {
        @Test
        func `Auto instance is a true singleton`() throws {
            // Clear any existing default
            TachikomaConfiguration.default = nil

            // Get auto instance many times
            let instances = (0..<1000).map { _ in
                TachikomaConfiguration.current
            }

            // All should be exactly the same instance
            let first = try #require(instances.first)
            for instance in instances {
                #expect(instance === first, "All auto instances must be identical")
            }
        }

        @Test
        func `Configuration priority chain`() {
            // Clear default
            TachikomaConfiguration.default = nil

            // 1. No default, no explicit -> auto instance
            let auto = TachikomaConfiguration.resolve()
            #expect(auto === TachikomaConfiguration.current)

            // 2. Set default
            let defaultConfig = TachikomaConfiguration(loadFromEnvironment: false)
            defaultConfig.setAPIKey("default-key", for: .openai)
            TachikomaConfiguration.default = defaultConfig

            // Should use default now
            #expect(TachikomaConfiguration.resolve() === defaultConfig)
            #expect(TachikomaConfiguration.current === defaultConfig)

            // 3. Explicit config overrides
            let explicit = TachikomaConfiguration(loadFromEnvironment: false)
            explicit.setAPIKey("explicit-key", for: .openai)

            #expect(TachikomaConfiguration.resolve(explicit) === explicit)

            // Clean up
            TachikomaConfiguration.default = nil
        }

        @Test
        func `README examples work correctly`() {
            // Example 1: Zero configuration
            let zeroConfiguration: @Sendable () async throws -> String = {
                try await generate("What is 2+2?", using: .openai(.gpt55))
            }
            _ = zeroConfiguration

            // Example 2: App sets default once
            let defaultConfiguration: @Sendable () async throws -> String = {
                TachikomaConfiguration.default = TachikomaConfiguration(
                    apiKeys: ["openai": "app-key"],
                )
                return try await generate("Hello", using: .openai(.gpt55))
            }
            _ = defaultConfiguration

            // Example 3: Explicit configuration
            let explicitConfiguration: @Sendable () async throws -> String = {
                let testConfig = TachikomaConfiguration(
                    apiKeys: ["openai": "test-key"],
                )

                return try await generate(
                    "Test prompt",
                    using: .openai(.gpt55),
                    configuration: testConfig,
                )
            }
            _ = explicitConfiguration

            // Example 4: Conversation
            _ = Conversation() // Uses default
            _ = Conversation(configuration: TachikomaConfiguration())

            #expect(Bool(true), "All README examples compile successfully")

            // Clean up
            TachikomaConfiguration.default = nil
        }

        @Test
        func `Thread safety under high concurrency`() async {
            TachikomaConfiguration.default = nil

            // Concurrent writes and reads
            await withTaskGroup(of: Void.self) { group in
                // Many writers
                for i in 0..<500 {
                    group.addTask {
                        if i % 3 == 0 {
                            let config = TachikomaConfiguration(loadFromEnvironment: false)
                            TachikomaConfiguration.default = config
                        }
                    }
                }

                // Many readers
                for _ in 0..<500 {
                    group.addTask {
                        _ = TachikomaConfiguration.current
                        _ = TachikomaConfiguration.default
                    }
                }
            }

            // Should not crash and have valid state
            let current = TachikomaConfiguration.current
            #expect(current === current) // Valid instance check

            // Clean up
            TachikomaConfiguration.default = nil
        }

        @Test
        func `Conversation maintains its configuration`() {
            TachikomaConfiguration.default = nil

            let config1 = TachikomaConfiguration(loadFromEnvironment: false)
            config1.setAPIKey("key1", for: .openai)

            let config2 = TachikomaConfiguration(loadFromEnvironment: false)
            config2.setAPIKey("key2", for: .anthropic)

            // Set default
            TachikomaConfiguration.default = config1

            // Create conversations
            let conv1 = Conversation() // Uses default (config1)
            let conv2 = Conversation(configuration: config2)

            #expect(conv1.configuration === config1, "conv1 should retain default configuration")
            #expect(conv2.configuration === config2)

            // Change default
            TachikomaConfiguration.default = nil

            // Existing conversations should keep their config
            #expect(conv1.configuration === config1, "conv1 should still reference original configuration")
            #expect(conv2.configuration === config2)

            // New conversation uses auto instance
            let conv3 = Conversation()
            #expect(conv3.configuration === TachikomaConfiguration.current)
        }
    }
}
