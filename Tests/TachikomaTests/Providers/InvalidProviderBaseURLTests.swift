import Foundation
import Testing
@testable import Tachikoma
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct InvalidProviderBaseURLTests {
    /// Space in the host makes `URL(string:)` return nil. Force-unwrap used to crash.
    private static let malformedBaseURL = "https://exa mple.com"

    @Test
    func `Responses generate throws on malformed base URL`() async throws {
        let provider = try self.responsesProvider(baseURL: Self.malformedBaseURL)

        await self.expectInvalidBaseURL {
            _ = try await provider.generateText(request: self.sampleRequest)
        }
    }

    @Test
    func `Responses generate throws on empty base URL`() async throws {
        let provider = try self.responsesProvider(baseURL: "")

        await self.expectInvalidBaseURL {
            _ = try await provider.generateText(request: self.sampleRequest)
        }
    }

    @Test
    func `Responses stream throws on malformed base URL`() async throws {
        let provider = try self.responsesProvider(baseURL: Self.malformedBaseURL)

        await self.expectInvalidBaseURL {
            _ = try await provider.streamText(request: self.sampleRequest)
        }
    }

    @Test
    func `Embedding generate throws on malformed base URL`() async {
        let provider = OpenAIEmbeddingProvider(
            model: .small3,
            apiKey: "sk-test",
            baseURL: Self.malformedBaseURL,
        )

        await self.expectInvalidBaseURL {
            _ = try await provider.generateEmbedding(request: self.embeddingRequest)
        }
    }

    @Test
    func `Embedding generate throws on empty base URL`() async {
        let provider = OpenAIEmbeddingProvider(
            model: .small3,
            apiKey: "sk-test",
            baseURL: "",
        )

        await self.expectInvalidBaseURL {
            _ = try await provider.generateEmbedding(request: self.embeddingRequest)
        }
    }

    @Test
    func `LM Studio health check throws on malformed base URL`() async {
        let provider = LMStudioProvider(baseURL: Self.malformedBaseURL)

        await self.expectInvalidBaseURL {
            _ = try await provider.healthCheck()
        }
    }

    @Test
    func `LM Studio health check throws on empty base URL`() async {
        let provider = LMStudioProvider(baseURL: "")

        await self.expectInvalidBaseURL {
            _ = try await provider.healthCheck()
        }
    }

    @Test
    func `LM Studio list models throws on malformed base URL`() async {
        let provider = LMStudioProvider(baseURL: Self.malformedBaseURL)

        await self.expectInvalidBaseURL {
            _ = try await provider.listModels()
        }
    }

    @Test
    func `LM Studio generate throws on malformed base URL`() async {
        let provider = LMStudioProvider(baseURL: Self.malformedBaseURL)

        await self.expectInvalidBaseURL {
            _ = try await provider.generateText(request: self.sampleRequest)
        }
    }

    @Test
    func `LM Studio stream throws on malformed base URL`() async {
        let provider = LMStudioProvider(baseURL: Self.malformedBaseURL)

        await self.expectInvalidBaseURL {
            _ = try await provider.streamText(request: self.sampleRequest)
        }
    }

    @Test
    func `Google generate throws on empty base URL`() async throws {
        let provider = try self.googleProvider(baseURL: "")

        await self.expectInvalidBaseURL {
            _ = try await provider.generateText(request: self.sampleRequest)
        }
    }

    @Test
    func `Google stream throws on empty base URL`() async throws {
        let provider = try self.googleProvider(baseURL: "")

        await self.expectInvalidBaseURL {
            try await self.consumeGoogleStream(provider)
        }
    }

    @Test
    func `Google stream throws on whitespace-only base URL`() async throws {
        let provider = try self.googleProvider(baseURL: "   ")

        await self.expectInvalidBaseURL {
            try await self.consumeGoogleStream(provider)
        }
    }

    @Test
    func `Google stream throws on malformed base URL`() async throws {
        let provider = try self.googleProvider(baseURL: Self.malformedBaseURL)

        await self.expectInvalidBaseURL {
            try await self.consumeGoogleStream(provider)
        }
    }

    private func googleProvider(baseURL: String) throws -> GoogleProvider {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("test-key", for: .google)
        config.setBaseURL(baseURL, for: .google)
        return try GoogleProvider(model: .gemini25Flash, configuration: config)
    }

    @Test(arguments: [
        ("https://generativelanguage.googleapis.com/v1beta", "/v1beta/models/gemini-2.5-flash:streamGenerateContent"),
        ("https://proxy.example.test/team%2Fblue/v1/", "/team%2Fblue/v1/models/gemini-2.5-flash:streamGenerateContent"),
        ("https://proxy.example.test/a%25b/%23route", "/a%25b/%23route/models/gemini-2.5-flash:streamGenerateContent"),
    ])
    func `Endpoint URL preserves encoded base path`(baseURL: String, expectedPath: String) throws {
        let url = try OpenAICompatibleHelper.endpointURL(
            baseURL: baseURL,
            path: "/models/gemini-2.5-flash:streamGenerateContent",
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == expectedPath)
    }

    @Test
    func `Endpoint URL encodes suffix and preserves base query`() throws {
        let url = try OpenAICompatibleHelper.buildURL(
            baseURL: "https://proxy.example.test/team%2Fblue?tenant=one",
            path: "models/a b%/#tag",
            queryItems: [URLQueryItem(name: "alt", value: "sse")],
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/team%2Fblue/models/a%20b%25/%23tag")
        #expect(components.queryItems == [
            URLQueryItem(name: "tenant", value: "one"),
            URLQueryItem(name: "alt", value: "sse"),
        ])
    }

    private func consumeGoogleStream(_ provider: GoogleProvider) async throws {
        let stream = try await provider.streamText(request: self.sampleRequest)
        for try await _ in stream {}
    }

    private func responsesProvider(baseURL: String) throws -> OpenAIResponsesProvider {
        let config = TachikomaConfiguration(loadFromEnvironment: false)
        config.setAPIKey("sk-test", for: .openai)
        config.setBaseURL(baseURL, for: .openai)
        return try OpenAIResponsesProvider(model: .gpt5, configuration: config)
    }

    private var sampleRequest: ProviderRequest {
        ProviderRequest(
            messages: [ModelMessage(role: .user, content: [.text("ping")])],
            settings: .init(maxTokens: 32),
        )
    }

    private var embeddingRequest: EmbeddingRequest {
        EmbeddingRequest(input: .text("hello"), settings: .default)
    }

    private func expectInvalidBaseURL(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected TachikomaError.invalidConfiguration for a bad base URL")
        } catch let error as TachikomaError {
            guard case let .invalidConfiguration(message) = error else {
                Issue.record("Expected invalidConfiguration, got \(error)")
                return
            }
            #expect(message.contains("Invalid base URL"))
        } catch {
            Issue.record("Expected TachikomaError, got \(error)")
        }
    }
}
