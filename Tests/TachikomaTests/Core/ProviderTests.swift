#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import Tachikoma

private func withTemporaryEnvironment<T: Sendable>(
    _ updates: [String: String?],
    _ body: @Sendable () throws -> T,
) async rethrows
    -> T
{
    try await TestEnvironmentMutex.shared.withLock {
        let saved = updates.keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        }

        for (key, value) in updates {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }

        defer {
            for (key, value) in saved {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        return try body()
    }
}

enum ProviderTests {
    struct ProviderPropertiesTests {
        @Test
        func `Standard providers have correct identifiers`() {
            #expect(Provider.openai.identifier == "openai")
            #expect(Provider.anthropic.identifier == "anthropic")
            #expect(Provider.grok.identifier == "grok")
            #expect(Provider.groq.identifier == "groq")
            #expect(Provider.mistral.identifier == "mistral")
            #expect(Provider.google.identifier == "google")
            #expect(Provider.minimax.identifier == "minimax")
            #expect(Provider.minimaxCN.identifier == "minimax-cn")
            #expect(Provider.kimi.identifier == "kimi")
            #expect(Provider.ollama.identifier == "ollama")
            #expect(Provider.azureOpenAI.identifier == "azure-openai")
        }

        @Test
        func `Custom provider has correct identifier`() {
            let customProvider = Provider.custom("my-custom-provider")
            #expect(customProvider.identifier == "my-custom-provider")
        }

        @Test
        func `Display names are human-readable`() {
            #expect(Provider.openai.displayName == "OpenAI")
            #expect(Provider.anthropic.displayName == "Anthropic")
            #expect(Provider.grok.displayName == "Grok")
            #expect(Provider.groq.displayName == "Groq")
            #expect(Provider.mistral.displayName == "Mistral")
            #expect(Provider.google.displayName == "Google")
            #expect(Provider.minimax.displayName == "MiniMax")
            #expect(Provider.minimaxCN.displayName == "MiniMax China")
            #expect(Provider.kimi.displayName == "Kimi")
            #expect(Provider.ollama.displayName == "Ollama")
            #expect(Provider.azureOpenAI.displayName == "Azure OpenAI")
            #expect(Provider.custom("test").displayName == "Test")
        }

        @Test
        func `Environment variables are correct`() {
            #expect(Provider.openai.environmentVariable == "OPENAI_API_KEY")
            #expect(Provider.anthropic.environmentVariable == "ANTHROPIC_API_KEY")
            #expect(Provider.grok.environmentVariable == "X_AI_API_KEY")
            #expect(Provider.groq.environmentVariable == "GROQ_API_KEY")
            #expect(Provider.mistral.environmentVariable == "MISTRAL_API_KEY")
            #expect(Provider.google.environmentVariable == "GEMINI_API_KEY")
            #expect(Provider.minimax.environmentVariable == "MINIMAX_API_KEY")
            #expect(Provider.minimaxCN.environmentVariable == "MINIMAX_CN_API_KEY")
            #expect(Provider.kimi.environmentVariable == "MOONSHOT_API_KEY")
            #expect(Provider.ollama.environmentVariable == "OLLAMA_API_KEY")
            #expect(Provider.azureOpenAI.environmentVariable == "AZURE_OPENAI_API_KEY")
            #expect(Provider.custom("test").environmentVariable.isEmpty)
        }

        @Test
        func `Alternative environment variables`() {
            #expect(Provider.grok.alternativeEnvironmentVariables == ["XAI_API_KEY", "GROK_API_KEY"])
            #expect(Provider.google.alternativeEnvironmentVariables == ["GOOGLE_API_KEY"])
            #expect(Provider.minimaxCN.alternativeEnvironmentVariables == ["MINIMAX_API_KEY"])
            #expect(Provider.kimi.alternativeEnvironmentVariables == ["KIMI_API_KEY"])
            #expect(Provider.openai.alternativeEnvironmentVariables.isEmpty)
            #expect(Provider.anthropic.alternativeEnvironmentVariables.isEmpty)
            #expect(Provider.azureOpenAI.alternativeEnvironmentVariables == [
                "AZURE_OPENAI_TOKEN",
                "AZURE_OPENAI_BEARER_TOKEN",
            ])
        }

        @Test
        func `Default base URLs`() {
            #expect(Provider.openai.defaultBaseURL == "https://api.openai.com/v1")
            #expect(Provider.anthropic.defaultBaseURL == "https://api.anthropic.com")
            #expect(Provider.grok.defaultBaseURL == "https://api.x.ai/v1")
            #expect(Provider.groq.defaultBaseURL == "https://api.groq.com/openai/v1")
            #expect(Provider.mistral.defaultBaseURL == "https://api.mistral.ai/v1")
            #expect(Provider.google.defaultBaseURL == "https://generativelanguage.googleapis.com/v1beta")
            #expect(Provider.minimax.defaultBaseURL == "https://api.minimax.io/anthropic")
            #expect(Provider.minimaxCN.defaultBaseURL == "https://api.minimaxi.com/anthropic")
            #expect(Provider.kimi.defaultBaseURL == "https://api.moonshot.ai/v1")
            #expect(Provider.ollama.defaultBaseURL == "http://localhost:11434")
            #expect(Provider.azureOpenAI.defaultBaseURL == nil)
            #expect(Provider.custom("test").defaultBaseURL == nil)
        }

        @Test
        func `API key requirements`() {
            #expect(Provider.openai.requiresAPIKey == true)
            #expect(Provider.anthropic.requiresAPIKey == true)
            #expect(Provider.grok.requiresAPIKey == true)
            #expect(Provider.groq.requiresAPIKey == true)
            #expect(Provider.mistral.requiresAPIKey == true)
            #expect(Provider.google.requiresAPIKey == true)
            #expect(Provider.minimax.requiresAPIKey == true)
            #expect(Provider.minimaxCN.requiresAPIKey == true)
            #expect(Provider.kimi.requiresAPIKey == true)
            #expect(Provider.ollama.requiresAPIKey == false) // Ollama typically doesn't require API key
            #expect(Provider.azureOpenAI.requiresAPIKey == true)
            #expect(Provider.custom("test").requiresAPIKey == true) // Assume custom providers need keys
        }
    }

    struct ProviderFactoryTests {
        @Test
        func `Create provider from identifier - standard providers`() {
            #expect(Provider.from(identifier: "openai") == .openai)
            #expect(Provider.from(identifier: "anthropic") == .anthropic)
            #expect(Provider.from(identifier: "grok") == .grok)
            #expect(Provider.from(identifier: "groq") == .groq)
            #expect(Provider.from(identifier: "mistral") == .mistral)
            #expect(Provider.from(identifier: "google") == .google)
            #expect(Provider.from(identifier: "minimax") == .minimax)
            #expect(Provider.from(identifier: "minimax-cn") == .minimaxCN)
            #expect(Provider.from(identifier: "minimaxi") == .minimaxCN)
            #expect(Provider.from(identifier: "kimi") == .kimi)
            #expect(Provider.from(identifier: "moonshot") == .kimi)
            #expect(Provider.from(identifier: "ollama") == .ollama)
            #expect(Provider.from(identifier: "azure-openai") == .azureOpenAI)
        }

        @Test
        func `Create provider from identifier - case insensitive`() {
            #expect(Provider.from(identifier: "OpenAI") == .openai)
            #expect(Provider.from(identifier: "ANTHROPIC") == .anthropic)
            #expect(Provider.from(identifier: "Grok") == .grok)
        }

        @Test
        func `Create provider from identifier - custom providers`() {
            let provider1 = Provider.from(identifier: "custom-provider")
            let provider2 = Provider.from(identifier: "unknown-provider")

            if case let .custom(id1) = provider1 {
                #expect(id1 == "custom-provider")
            } else {
                Issue.record("Expected custom provider")
            }

            if case let .custom(id2) = provider2 {
                #expect(id2 == "unknown-provider")
            } else {
                Issue.record("Expected custom provider")
            }
        }

        @Test
        func `Standard providers list`() {
            let expected: [Provider] = [
                .openai,
                .anthropic,
                .grok,
                .groq,
                .mistral,
                .google,
                .minimax,
                .minimaxCN,
                .kimi,
                .ollama,
                .lmstudio,
                .azureOpenAI,
            ]
            #expect(Provider.standardProviders == expected)
        }
    }

    struct EnvironmentVariableTests {
        @Test
        func `Load API key from primary environment variable`() {
            // We can't easily mock ProcessInfo.processInfo.environment in tests,
            // so we'll test the logic indirectly through TachikomaConfiguration
        }

        @Test
        func `Load API key from alternative environment variable`() {
            // Test that Grok provider loads from XAI_API_KEY when X_AI_API_KEY is not available
            let provider = Provider.grok
            #expect(provider.environmentVariable == "X_AI_API_KEY")
            #expect(provider.alternativeEnvironmentVariables == ["XAI_API_KEY", "GROK_API_KEY"])
        }

        @Test
        func `MiniMax China falls back to MiniMax environment variable`() async {
            let resolved = await withTemporaryEnvironment([
                "MINIMAX_CN_API_KEY": nil,
                "MINIMAX_API_KEY": "shared-minimax-key",
            ]) {
                Provider.minimaxCN.loadAPIKeyFromEnvironment()
            }

            #expect(resolved == "shared-minimax-key")
        }

        @Test
        func `Custom providers don't have environment variables`() {
            let customProvider = Provider.custom("test")
            #expect(customProvider.environmentVariable.isEmpty)
            #expect(customProvider.alternativeEnvironmentVariables.isEmpty)
        }

        @Test
        func `Google ignores ADC credential paths as API keys`() async {
            let resolved = await withTemporaryEnvironment([
                "GEMINI_API_KEY": nil,
                "GOOGLE_API_KEY": nil,
                "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/fake-google-adc.json",
            ]) {
                Provider.google.loadAPIKeyFromEnvironment()
            }

            #expect(resolved == nil)
        }
    }

    struct CodableTests {
        @Test
        func `Provider encodes to identifier string`() throws {
            let encoder = JSONEncoder()

            let openaiData = try encoder.encode(Provider.openai)
            let openaiString = String(data: openaiData, encoding: .utf8)
            #expect(openaiString == "\"openai\"")

            let customData = try encoder.encode(Provider.custom("my-provider"))
            let customString = String(data: customData, encoding: .utf8)
            #expect(customString == "\"my-provider\"")
        }

        @Test
        func `Provider decodes from identifier string`() throws {
            let decoder = JSONDecoder()

            let openaiData = "\"openai\"".utf8Data()
            let openaiProvider = try decoder.decode(Provider.self, from: openaiData)
            #expect(openaiProvider == .openai)

            let customData = "\"my-provider\"".utf8Data()
            let customProvider = try decoder.decode(Provider.self, from: customData)
            if case let .custom(id) = customProvider {
                #expect(id == "my-provider")
            } else {
                Issue.record("Expected custom provider")
            }
        }
    }

    struct EqualityTests {
        @Test
        func `Standard providers equality`() {
            #expect(Provider.openai == Provider.openai)
            #expect(Provider.anthropic == Provider.anthropic)
            #expect(Provider.openai != Provider.anthropic)
        }

        @Test
        func `Custom providers equality`() {
            let custom1 = Provider.custom("test")
            let custom2 = Provider.custom("test")
            let custom3 = Provider.custom("different")

            #expect(custom1 == custom2)
            #expect(custom1 != custom3)
            #expect(custom1 != Provider.openai)
        }
    }

    struct HashableTests {
        @Test
        func `Provider hashable implementation`() {
            let providers: Set<Provider> = [
                .openai,
                .anthropic,
                .grok,
                .custom("test1"),
                .custom("test2"),
            ]

            #expect(providers.count == 5)
            #expect(providers.contains(.openai))
            #expect(providers.contains(.custom("test1")))
            #expect(!providers.contains(.custom("test3")))
        }
    }
}
