import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
struct OpenAIEmbeddingProvider: EmbeddingProvider, ModelProvider {
    let model: EmbeddingModel.OpenAIEmbedding
    let apiKey: String?
    let baseURL: String?
    var session: URLSession = .shared

    var modelId: String {
        self.model.rawValue
    }

    var capabilities: ModelCapabilities {
        ModelCapabilities()
    }

    /// ModelProvider conformance (not used for embeddings)
    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        throw TachikomaError.unsupportedOperation("Text generation not supported for embedding models")
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        throw TachikomaError.unsupportedOperation("Streaming not supported for embedding models")
    }

    /// Call OpenAI's embeddings endpoint and translate the response into Tachikoma's embedding result.
    func generateEmbedding(request: EmbeddingRequest) async throws -> EmbeddingResult {
        guard let apiKey else {
            throw TachikomaError.authenticationFailed("OpenAI API key not configured")
        }

        let url = try OpenAICompatibleHelper.endpointURL(
            baseURL: self.baseURL ?? "https://api.openai.com/v1",
            path: "/embeddings",
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build request body
        var body: [String: Any] = [
            "model": model.rawValue,
        ]
        if case let .tokens(tokens) = request.input {
            body["input"] = tokens
        } else {
            body["input"] = request.input.asTexts
        }

        if let dimensions = request.settings.dimensions {
            body["dimensions"] = dimensions
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await self.session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TachikomaError.networkError(NSError(domain: "Invalid response", code: 0))
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TachikomaError.apiError("OpenAI Embedding Error (HTTP \(httpResponse.statusCode)): \(errorText)")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(EmbeddingResponse.self, from: data)
        let expectedCount = if case let .texts(texts) = request.input {
            texts.count
        } else {
            1
        }
        let expectedDimensions = request.settings.dimensions ?? payload.data.first?.embedding.count ?? 0
        guard
            payload.data.count == expectedCount,
            Set(payload.data.map(\.index)) == Set(0..<expectedCount),
            payload.data.allSatisfy({ !$0.embedding.isEmpty && $0.embedding.count == expectedDimensions }) else
        {
            throw TachikomaError.apiError("OpenAI embedding response has invalid vector count, indices, or dimensions")
        }
        let embeddings = payload.data.sorted { $0.index < $1.index }.map(\.embedding)

        let usage = payload.usage.map { Usage(inputTokens: $0.promptTokens, outputTokens: 0) }

        return EmbeddingResult(
            embeddings: embeddings,
            model: self.model.rawValue,
            usage: usage,
            metadata: EmbeddingMetadata(
                truncated: false,
                normalizedL2: request.settings.normalizeEmbeddings,
            ),
        )
    }

    private struct EmbeddingResponse: Decodable {
        struct Item: Decodable {
            let index: Int
            let embedding: [Double]
        }

        struct TokenUsage: Decodable {
            let promptTokens: Int
        }

        let data: [Item]
        let usage: TokenUsage?
    }
}

/// Placeholder providers for other services
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
struct CohereEmbeddingProvider: EmbeddingProvider, ModelProvider {
    let model: EmbeddingModel.CohereEmbedding
    let apiKey: String?

    var modelId: String {
        self.model.rawValue
    }

    var baseURL: String? {
        nil
    }

    var capabilities: ModelCapabilities {
        ModelCapabilities()
    }

    /// ModelProvider conformance (not used for embeddings)
    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        throw TachikomaError.unsupportedOperation("Text generation not supported for embedding models")
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        throw TachikomaError.unsupportedOperation("Streaming not supported for embedding models")
    }

    func generateEmbedding(request _: EmbeddingRequest) async throws -> EmbeddingResult {
        throw TachikomaError.unsupportedOperation("Cohere embeddings not yet implemented")
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
struct VoyageEmbeddingProvider: EmbeddingProvider, ModelProvider {
    let model: EmbeddingModel.VoyageEmbedding
    let apiKey: String?

    var modelId: String {
        self.model.rawValue
    }

    var baseURL: String? {
        nil
    }

    var capabilities: ModelCapabilities {
        ModelCapabilities()
    }

    /// ModelProvider conformance (not used for embeddings)
    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        throw TachikomaError.unsupportedOperation("Text generation not supported for embedding models")
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        throw TachikomaError.unsupportedOperation("Streaming not supported for embedding models")
    }

    func generateEmbedding(request _: EmbeddingRequest) async throws -> EmbeddingResult {
        throw TachikomaError.unsupportedOperation("Voyage embeddings not yet implemented")
    }
}
