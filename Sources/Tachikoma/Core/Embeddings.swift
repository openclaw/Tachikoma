import Foundation

// MARK: - Embeddings API

/// Generate embeddings for text or batch of texts
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func generateEmbedding(
    model: EmbeddingModel,
    input: EmbeddingInput,
    settings: EmbeddingSettings = .default,
    configuration: TachikomaConfiguration = TachikomaConfiguration(),
) async throws
    -> EmbeddingResult
{
    let provider = try EmbeddingProviderFactory.createProvider(for: model, configuration: configuration)

    let request = EmbeddingRequest(
        input: input,
        settings: settings,
    )

    let response = try await provider.generateEmbedding(request: request)

    // Track usage
    let sessionId = "embedding-\(UUID().uuidString)"
    _ = UsageTracker.shared.startSession(sessionId)

    if let usage = response.usage {
        UsageTracker.shared.recordUsage(
            sessionId: sessionId,
            model: model.toLanguageModel(),
            usage: usage,
            operation: .embedding,
        )
    }

    _ = UsageTracker.shared.endSession(sessionId)

    return response
}

/// Batch generate embeddings with concurrency control
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func generateEmbeddingsBatch(
    model: EmbeddingModel,
    inputs: [EmbeddingInput],
    settings: EmbeddingSettings = .default,
    concurrency: Int = 5,
    configuration: TachikomaConfiguration = TachikomaConfiguration(),
) async throws
    -> [EmbeddingResult]
{
    let provider = try EmbeddingProviderFactory.createProvider(for: model, configuration: configuration)

    return try await generateEmbeddingsBatch(
        provider: provider, inputs: inputs, settings: settings, concurrency: concurrency,
    )
}

func generateEmbeddingsBatch(
    provider: any EmbeddingProvider,
    inputs: [EmbeddingInput],
    settings: EmbeddingSettings = .default,
    concurrency: Int = 5,
) async throws
    -> [EmbeddingResult]
{
    guard concurrency > 0 else {
        throw TachikomaError.invalidInput("Embedding batch concurrency must be greater than zero")
    }
    try Task.checkCancellation()
    let generate: @Sendable (Int) async throws -> (Int, EmbeddingResult) = { index in
        try Task.checkCancellation()
        let request = EmbeddingRequest(input: inputs[index], settings: settings)
        let result = try await provider.generateEmbedding(request: request)
        return (index, result)
    }

    return try await withThrowingTaskGroup(of: (Int, EmbeddingResult).self) { group in
        let initialCount = min(concurrency, inputs.count)
        for index in 0..<initialCount {
            group.addTask { try await generate(index) }
        }

        var results: [(Int, EmbeddingResult)] = []
        results.reserveCapacity(inputs.count)
        var nextIndex = initialCount
        while let result = try await group.next() {
            try Task.checkCancellation()
            results.append(result)
            if nextIndex < inputs.count {
                let index = nextIndex
                nextIndex += 1
                group.addTask { try await generate(index) }
            }
        }

        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

// MARK: - Embedding Types

/// Embedding model selection
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum EmbeddingModel: Sendable {
    case openai(OpenAIEmbedding)
    case cohere(CohereEmbedding)
    case voyage(VoyageEmbedding)
    case custom(String)

    public enum OpenAIEmbedding: String, Sendable, CaseIterable {
        case ada002 = "text-embedding-ada-002"
        case small3 = "text-embedding-3-small"
        case large3 = "text-embedding-3-large"
    }

    public enum CohereEmbedding: String, Sendable, CaseIterable {
        case english3 = "embed-english-v3.0"
        case multilingual3 = "embed-multilingual-v3.0"
        case englishLight3 = "embed-english-light-v3.0"
        case multilingualLight3 = "embed-multilingual-light-v3.0"
    }

    public enum VoyageEmbedding: String, Sendable, CaseIterable {
        case voyage2 = "voyage-2"
        case voyage2Code = "voyage-code-2"
        case voyage2Large = "voyage-large-2"
    }

    /// Convert to LanguageModel for usage tracking
    func toLanguageModel() -> LanguageModel {
        // Convert to LanguageModel for usage tracking
        switch self {
        case .openai:
            .openai(.gpt55) // Placeholder for tracking
        case .cohere, .voyage, .custom:
            // Return a dummy model for tracking purposes
            .openai(.gpt55)
        }
    }
}

/// Input for embedding generation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum EmbeddingInput: Sendable {
    case text(String)
    case texts([String])
    case tokens([Int])

    var asTexts: [String] {
        switch self {
        case let .text(string):
            [string]
        case let .texts(strings):
            strings
        case .tokens:
            [] // Provider will handle token conversion
        }
    }
}

/// Settings for embedding generation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct EmbeddingSettings: Sendable, Codable {
    public let dimensions: Int?
    public let normalizeEmbeddings: Bool
    public let truncate: TruncationStrategy?

    public enum TruncationStrategy: String, Sendable, Codable {
        case start
        case end
        case none
    }

    public init(
        dimensions: Int? = nil,
        normalizeEmbeddings: Bool = true,
        truncate: TruncationStrategy? = nil,
    ) {
        self.dimensions = dimensions
        self.normalizeEmbeddings = normalizeEmbeddings
        self.truncate = truncate
    }

    public static let `default` = EmbeddingSettings()
}

/// Result from embedding generation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct EmbeddingResult: Sendable {
    public let embeddings: [[Double]]
    public let model: String
    public let usage: Usage?
    public let metadata: EmbeddingMetadata?

    public init(
        embeddings: [[Double]],
        model: String,
        usage: Usage? = nil,
        metadata: EmbeddingMetadata? = nil,
    ) {
        self.embeddings = embeddings
        self.model = model
        self.usage = usage
        self.metadata = metadata
    }

    /// Get first embedding (convenience for single text input)
    public var embedding: [Double]? {
        self.embeddings.first
    }

    /// Number of dimensions in embeddings
    public var dimensions: Int? {
        self.embeddings.first?.count
    }
}

/// Metadata for embedding results
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct EmbeddingMetadata: Sendable, Codable {
    public let truncated: Bool
    public let normalizedL2: Bool

    public init(truncated: Bool = false, normalizedL2: Bool = false) {
        self.truncated = truncated
        self.normalizedL2 = normalizedL2
    }
}

// MARK: - Provider Protocol

/// Protocol for embedding providers
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
protocol EmbeddingProvider: Sendable {
    /// Produce embeddings for the given input using provider-specific settings.
    func generateEmbedding(request: EmbeddingRequest) async throws -> EmbeddingResult
}

/// Request for embedding generation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
struct EmbeddingRequest {
    let input: EmbeddingInput
    let settings: EmbeddingSettings
}

// MARK: - Provider Factory

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
struct EmbeddingProviderFactory {
    /// Instantiate the embedding provider that matches the requested model and configuration.
    static func createProvider(
        for model: EmbeddingModel,
        configuration: TachikomaConfiguration,
    ) throws
        -> EmbeddingProvider
    {
        switch model {
        case let .openai(openAIModel):
            return OpenAIEmbeddingProvider(
                model: openAIModel,
                apiKey: configuration.getAPIKey(for: "openai"),
                baseURL: configuration.getBaseURL(for: "openai"),
            )
        case let .cohere(cohereModel):
            return CohereEmbeddingProvider(
                model: cohereModel,
                apiKey: configuration.getAPIKey(for: "cohere") ?? ProcessInfo.processInfo.environment["COHERE_API_KEY"],
            )
        case let .voyage(voyageModel):
            return VoyageEmbeddingProvider(
                model: voyageModel,
                apiKey: configuration.getAPIKey(for: "voyage") ?? ProcessInfo.processInfo.environment["VOYAGE_API_KEY"],
            )
        case let .custom(modelId):
            throw TachikomaError.unsupportedOperation("Custom embedding model '\(modelId)' not implemented")
        }
    }
}
