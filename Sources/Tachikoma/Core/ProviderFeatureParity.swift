import Algorithms
import Foundation

// MARK: - Enhanced Provider Protocol

/// Enhanced provider protocol with full feature support
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public protocol EnhancedModelProvider: ModelProvider {
    /// Generate text with full feature support
    func generateText(request: ProviderRequest) async throws -> ProviderResponse

    /// Stream text with proper backpressure handling
    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error>

    /// Validate and transform messages for provider-specific requirements
    func validateMessages(_ messages: [ModelMessage]) throws -> [ModelMessage]

    /// Check if a specific feature is supported
    func isFeatureSupported(_ feature: ProviderFeature) -> Bool

    /// Get provider-specific configuration
    var configuration: ProviderConfiguration {
        // Generate text with full feature support
        get
    }
}

// MARK: - Provider Features

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum ProviderFeature: String, Sendable, CaseIterable {
    case streaming
    case toolCalling
    case systemMessages
    case visionInputs
    case multiModal
    case jsonMode
    case functionCalling
    case parallelToolCalls
    case contextCaching
    case longContext
}

// MARK: - Provider Configuration

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct ProviderConfiguration: Sendable {
    public let maxTokens: Int
    public let maxContextLength: Int
    public let supportedImageFormats: [String]
    public let maxImageSize: Int?
    public let maxToolCalls: Int
    public let supportsSystemRole: Bool
    public let requiresAlternatingRoles: Bool
    public let customHeaders: [String: String]

    public init(
        maxTokens: Int = 4096,
        maxContextLength: Int = 128_000,
        supportedImageFormats: [String] = ["jpeg", "png", "gif", "webp"],
        maxImageSize: Int? = 20 * 1024 * 1024, // 20MB
        maxToolCalls: Int = 10,
        supportsSystemRole: Bool = true,
        requiresAlternatingRoles: Bool = false,
        customHeaders: [String: String] = [:],
    ) {
        self.maxTokens = maxTokens
        self.maxContextLength = maxContextLength
        self.supportedImageFormats = supportedImageFormats
        self.maxImageSize = maxImageSize
        self.maxToolCalls = maxToolCalls
        self.supportsSystemRole = supportsSystemRole
        self.requiresAlternatingRoles = requiresAlternatingRoles
        self.customHeaders = customHeaders
    }

    /// Common configurations for providers
    public static let openAI = ProviderConfiguration(
        maxTokens: 4096,
        maxContextLength: 128_000,
        supportsSystemRole: true,
    )

    public static let anthropic = ProviderConfiguration(
        maxTokens: 4096,
        maxContextLength: 200_000,
        supportsSystemRole: true,
        requiresAlternatingRoles: true,
    )

    public static let google = ProviderConfiguration(
        maxTokens: 8192,
        maxContextLength: 1_048_576, // 1M tokens for Gemini 1.5
        supportsSystemRole: false, // Uses "user" role for system
        requiresAlternatingRoles: true,
    )

    public static let ollama = ProviderConfiguration(
        maxTokens: 2048,
        maxContextLength: 32000,
        maxToolCalls: 0, // No tool support by default
        supportsSystemRole: true,
    )
}

// MARK: - Provider Adapter

/// Base adapter that ensures feature parity across all providers
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class ProviderAdapter: EnhancedModelProvider {
    private let baseProvider: ModelProvider
    public let configuration: ProviderConfiguration

    public var modelId: String {
        self.baseProvider.modelId
    }

    public var baseURL: String? {
        self.baseProvider.baseURL
    }

    public var apiKey: String? {
        self.baseProvider.apiKey
    }

    public var capabilities: ModelCapabilities {
        self.baseProvider.capabilities
    }

    public init(provider: ModelProvider, configuration: ProviderConfiguration) {
        self.baseProvider = provider
        self.configuration = configuration
    }

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        let validatedRequest = try validateRequest(request)
        return try await self.baseProvider.generateText(request: validatedRequest)
    }

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        // Check if streaming is supported
        guard self.capabilities.supportsStreaming else {
            // Fallback to non-streaming and simulate stream
            return self.simulateStream(from: request)
        }

        let validatedRequest = try validateRequest(request)
        return try await self.baseProvider.streamText(request: validatedRequest)
    }

    public func validateMessages(_ messages: [ModelMessage]) throws -> [ModelMessage] {
        var validated = messages

        // Handle system messages if not supported
        if !self.configuration.supportsSystemRole {
            validated = self.transformSystemMessages(messages)
        }

        // Ensure alternating roles if required
        if self.configuration.requiresAlternatingRoles {
            validated = self.ensureAlternatingRoles(validated)
        }

        // Validate vision inputs
        validated = try self.validateVisionInputs(validated)

        return validated
    }

    public func isFeatureSupported(_ feature: ProviderFeature) -> Bool {
        switch feature {
        case .streaming:
            self.capabilities.supportsStreaming
        case .toolCalling, .functionCalling:
            self.capabilities.supportsTools
        case .systemMessages:
            self.configuration.supportsSystemRole
        case .visionInputs, .multiModal:
            self.capabilities.supportsVision
        case .parallelToolCalls:
            self.capabilities.supportsTools && self.configuration.maxToolCalls > 1
        case .jsonMode:
            false // Not yet implemented in ModelCapabilities
        case .contextCaching:
            false // Most providers don't support this yet
        case .longContext:
            self.configuration.maxContextLength > 100_000
        }
    }

    // MARK: - Private Helpers

    private func validateRequest(_ request: ProviderRequest) throws -> ProviderRequest {
        // Validate messages
        let validatedMessages = try validateMessages(request.messages)

        // Validate tools
        var validatedTools = request.tools
        if let tools = request.tools, !tools.isEmpty {
            guard self.capabilities.supportsTools else {
                throw TachikomaError.unsupportedOperation("This model doesn't support tool calling")
            }

            if tools.count > self.configuration.maxToolCalls {
                // Truncate to max allowed
                validatedTools = Array(tools.prefix(self.configuration.maxToolCalls))
            }
        }

        // Apply token limits
        let validatedSettings = request.settings
        if let maxTokens = request.settings.maxTokens, maxTokens > configuration.maxTokens {
            // Would need to create new settings with updated maxTokens
            // For now, just use the original settings
        }

        return ProviderRequest(
            messages: validatedMessages,
            tools: validatedTools,
            settings: validatedSettings,
            outputFormat: request.outputFormat,
        )
    }

    private func transformSystemMessages(_ messages: [ModelMessage]) -> [ModelMessage] {
        messages.map { message in
            if message.role == .system {
                // Convert system message to user message with prefix
                var content = message.content
                if case let .text(text) = content.first {
                    content = [.text("System: \(text)")]
                }
                return ModelMessage(role: .user, content: content)
            }
            return message
        }
    }

    private func ensureAlternatingRoles(_ messages: [ModelMessage]) -> [ModelMessage] {
        messages
            .chunked { $0.role == $1.role }
            .map { chunk in
                guard let first = chunk.first else { return ModelMessage(role: .user, content: []) }
                let combinedContent = chunk.flatMap(\.content)
                return ModelMessage(
                    id: first.id,
                    role: first.role,
                    content: combinedContent,
                    timestamp: first.timestamp,
                    channel: first.channel,
                    metadata: first.metadata,
                )
            }
    }

    private func validateVisionInputs(_ messages: [ModelMessage]) throws -> [ModelMessage] {
        guard self.capabilities.supportsVision else {
            // Strip image content if not supported
            return messages.map { message in
                let filteredContent = message.content.compactMap { part -> ModelMessage.ContentPart? in
                    if case .image = part {
                        return nil // Remove image parts
                    }
                    return part
                }
                return ModelMessage(role: message.role, content: filteredContent)
            }
        }

        // Validate image formats and sizes
        return try messages.map { message in
            let validatedContent = try message.content.map { part -> ModelMessage.ContentPart in
                if case let .image(imageContent) = part {
                    // Convert ImageContent to data URL for validation
                    let dataURL = "data:image/\(imageContent.mimeType);base64,\(imageContent.data)"
                    try self.validateImageURL(dataURL)
                }
                return part
            }
            return ModelMessage(role: message.role, content: validatedContent)
        }
    }

    private func validateImageURL(_ url: String) throws {
        if url.starts(with: "data:") {
            // Validate data URL
            let components = url.split(separator: ",", maxSplits: 1)
            guard components.count == 2 else {
                throw TachikomaError.invalidInput("Invalid image data URL")
            }

            let metadata = String(components[0])
            let format = metadata
                .replacingOccurrences(of: "data:image/", with: "")
                .replacingOccurrences(of: ";base64", with: "")

            guard self.configuration.supportedImageFormats.contains(format) else {
                throw TachikomaError.invalidInput("Unsupported image format: \(format)")
            }

            // Check size if configured
            if let maxSize = configuration.maxImageSize {
                let base64Data = String(components[1])
                let dataSize = base64Data.count * 3 / 4 // Approximate decoded size
                guard dataSize <= maxSize else {
                    throw TachikomaError.invalidInput("Image size exceeds limit: \(dataSize) > \(maxSize)")
                }
            }
        }
    }

    private func simulateStream(from request: ProviderRequest) -> AsyncThrowingStream<TextStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let response = try await self.generateText(request: request)

                    // Simulate streaming by chunking the response
                    let chunks = response.text.split(by: 20) // Split into word chunks
                    for chunk in chunks {
                        continuation.yield(TextStreamDelta(type: .textDelta, content: chunk))
                        try await Task<Never, Never>.sleep(nanoseconds: 50_000_000) // 50ms delay
                    }

                    // Send final delta with usage and finish reason
                    continuation.yield(TextStreamDelta(
                        type: .done,
                        usage: response.usage,
                        finishReason: response.finishReason ?? .stop,
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

// MARK: - String Extension for Chunking

extension String {
    fileprivate func split(by wordCount: Int) -> [String] {
        let words = self.split(separator: " ")
        let grouped = words
            .chunks(ofCount: wordCount)
            .map { $0.joined(separator: " ") }

        return grouped.indexed().map { index, chunk in
            index == grouped.count - 1 ? chunk : "\(chunk) "
        }
    }
}

// MARK: - Provider Extensions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension ModelProvider {
    /// Wrap any provider with feature parity adapter
    public func withFeatureParity(configuration: ProviderConfiguration? = nil) -> EnhancedModelProvider {
        // Wrap any provider with feature parity adapter
        if let enhanced = self as? EnhancedModelProvider {
            return enhanced
        }

        // Auto-detect configuration based on provider type
        let config = configuration ?? self.detectConfiguration()
        return ProviderAdapter(provider: self, configuration: config)
    }

    private func detectConfiguration() -> ProviderConfiguration {
        // Try to detect provider type from model ID or base URL
        let modelLower = modelId.lowercased()
        let urlLower = baseURL?.lowercased() ?? ""

        if modelLower.contains("gpt") || urlLower.contains("openai") {
            return .openAI
        } else if modelLower.contains("claude") || urlLower.contains("anthropic") {
            return .anthropic
        } else if modelLower.contains("gemini") || urlLower.contains("google") {
            return .google
        } else if urlLower.contains("localhost") || urlLower.contains("ollama") {
            return .ollama
        }

        // Default configuration
        return ProviderConfiguration()
    }
}
