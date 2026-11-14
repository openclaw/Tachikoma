#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Tachikoma // For TachikomaError and TachikomaConfiguration
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private enum AudioProviderEnvironment {
    static func mockModeEnabled() -> Bool {
        if
            let disablePointer = getenv("TACHIKOMA_DISABLE_API_TESTS"),
            String(cString: disablePointer).lowercased() == "true"
        {
            return true
        }

        if
            let mockPointer = getenv("TACHIKOMA_TEST_MODE"),
            String(cString: mockPointer).lowercased() == "mock"
        {
            return true
        }

        return false
    }

    static func environmentValue(for key: String) -> String? {
        guard let pointer = getenv(key) else {
            return nil
        }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    static func isTestKey(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "test-key"
    }
}

// MARK: - Provider Protocols

/// Protocol for transcription providers
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public protocol TranscriptionProvider: Sendable {
    var modelId: String { get }
    var capabilities: TranscriptionCapabilities { get }

    /// Convert audio input into text (and metadata) using the provider's model.
    func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResult
}

/// Protocol for speech synthesis providers
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public protocol SpeechProvider: Sendable {
    var modelId: String { get }
    var capabilities: SpeechCapabilities { get }

    /// Generate speech audio for the provided request payload.
    func generateSpeech(request: SpeechRequest) async throws -> SpeechResult
}

// MARK: - Capability Types

/// Capabilities of a transcription provider
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TranscriptionCapabilities: Sendable {
    public let supportedFormats: [AudioFormat]
    public let supportsTimestamps: Bool
    public let supportsLanguageDetection: Bool
    public let supportsSpeakerDiarization: Bool
    public let supportsSummarization: Bool
    public let supportsWordTimestamps: Bool
    public let maxFileSize: Int? // in bytes
    public let maxDuration: TimeInterval? // in seconds
    public let supportedLanguages: [String]? // ISO 639-1 codes

    public init(
        supportedFormats: [AudioFormat] = AudioFormat.allCases,
        supportsTimestamps: Bool = false,
        supportsLanguageDetection: Bool = false,
        supportsSpeakerDiarization: Bool = false,
        supportsSummarization: Bool = false,
        supportsWordTimestamps: Bool = false,
        maxFileSize: Int? = nil,
        maxDuration: TimeInterval? = nil,
        supportedLanguages: [String]? = nil,
    ) {
        self.supportedFormats = supportedFormats
        self.supportsTimestamps = supportsTimestamps
        self.supportsLanguageDetection = supportsLanguageDetection
        self.supportsSpeakerDiarization = supportsSpeakerDiarization
        self.supportsSummarization = supportsSummarization
        self.supportsWordTimestamps = supportsWordTimestamps
        self.maxFileSize = maxFileSize
        self.maxDuration = maxDuration
        self.supportedLanguages = supportedLanguages
    }
}

/// Capabilities of a speech synthesis provider
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct SpeechCapabilities: Sendable {
    public let supportedFormats: [AudioFormat]
    public let supportedVoices: [VoiceOption]
    public let supportsVoiceInstructions: Bool
    public let supportsSpeedControl: Bool
    public let supportsLanguageSelection: Bool
    public let supportsEmotionalControl: Bool
    public let maxTextLength: Int? // in characters
    public let supportedLanguages: [String]? // ISO 639-1 codes

    public init(
        supportedFormats: [AudioFormat] = [.mp3, .wav],
        supportedVoices: [VoiceOption] = [.alloy, .echo, .fable, .onyx, .nova, .shimmer],
        supportsVoiceInstructions: Bool = false,
        supportsSpeedControl: Bool = true,
        supportsLanguageSelection: Bool = false,
        supportsEmotionalControl: Bool = false,
        maxTextLength: Int? = nil,
        supportedLanguages: [String]? = nil,
    ) {
        self.supportedFormats = supportedFormats
        self.supportedVoices = supportedVoices
        self.supportsVoiceInstructions = supportsVoiceInstructions
        self.supportsSpeedControl = supportsSpeedControl
        self.supportsLanguageSelection = supportsLanguageSelection
        self.supportsEmotionalControl = supportsEmotionalControl
        self.maxTextLength = maxTextLength
        self.supportedLanguages = supportedLanguages
    }
}

// MARK: - Provider Factories

/// Factory for creating transcription providers
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TranscriptionProviderFactory {
    /// Create a transcription provider for the specified model
    public static func createProvider(
        for model: TranscriptionModel,
        configuration: TachikomaConfiguration = TachikomaConfiguration(),
    ) throws
        -> any TranscriptionProvider
    {
        let providerName = model.providerName.lowercased()
        let configuredKey = configuration.getAPIKey(for: providerName)

        // Use mock provider when mock mode is enabled or when using the standard test key
        if AudioProviderEnvironment.mockModeEnabled() || AudioProviderEnvironment.isTestKey(configuredKey) {
            if configuredKey == nil {
                throw TachikomaError.authenticationFailed("\(providerName.uppercased())_API_KEY not found")
            }
            return MockTranscriptionProvider(model: model)
        }

        switch model {
        case let .openai(openaiModel):
            return try OpenAITranscriptionProvider(model: openaiModel, configuration: configuration)
        case let .groq(groqModel):
            return try GroqTranscriptionProvider(model: groqModel, configuration: configuration)
        case let .deepgram(deepgramModel):
            return try DeepgramTranscriptionProvider(model: deepgramModel, configuration: configuration)
        case let .elevenlabs(elevenlabsModel):
            return try ElevenLabsTranscriptionProvider(model: elevenlabsModel, configuration: configuration)
        }
    }
}

/// Factory for creating speech synthesis providers
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct SpeechProviderFactory {
    /// Create a speech provider for the specified model
    public static func createProvider(
        for model: SpeechModel,
        configuration: TachikomaConfiguration = TachikomaConfiguration(),
    ) throws
        -> any SpeechProvider
    {
        let providerName = model.providerName.lowercased()
        let configuredKey = configuration.getAPIKey(for: providerName)

        // Mock when in mock mode or using the standard test key
        if AudioProviderEnvironment.mockModeEnabled() || AudioProviderEnvironment.isTestKey(configuredKey) {
            if configuredKey == nil {
                throw TachikomaError.authenticationFailed("\(providerName.uppercased())_API_KEY not found")
            }
            return MockSpeechProvider(model: model)
        }

        switch model {
        case let .openai(openaiModel):
            return try OpenAISpeechProvider(model: openaiModel, configuration: configuration)
        case let .elevenlabs(elevenlabsModel):
            return try ElevenLabsSpeechProvider(model: elevenlabsModel, configuration: configuration)
        }
    }
}

// MARK: - Configuration Helper

/// Configuration helper for audio providers
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct AudioConfiguration {
    /// Get API key for a specific provider
    public static func getAPIKey(for provider: String, configuration: TachikomaConfiguration? = nil) -> String? {
        // Get API key for a specific provider
        let config = configuration ?? TachikomaConfiguration()

        // First check TachikomaConfiguration
        if let key = config.getAPIKey(for: provider) {
            return key
        }

        // Then check environment variables with common patterns
        let envKeys = self.environmentKeys(for: provider)
        for key in envKeys {
            if let value = AudioProviderEnvironment.environmentValue(for: key) {
                return value
            }
        }

        return nil
    }

    /// Get common environment variable names for a provider
    private static func environmentKeys(for provider: String) -> [String] {
        // Get common environment variable names for a provider
        let upperProvider = provider.uppercased()

        switch provider.lowercased() {
        case "openai":
            return ["OPENAI_API_KEY"]
        case "groq":
            return ["GROQ_API_KEY"]
        case "deepgram":
            return ["DEEPGRAM_API_KEY", "DEEPGRAM_TOKEN"]
        case "elevenlabs":
            return ["ELEVENLABS_API_KEY", "ELEVEN_LABS_API_KEY"]
        default:
            return ["\(upperProvider)_API_KEY", "\(upperProvider)_TOKEN"]
        }
    }
}

// MARK: - Provider Base Classes (Stubs)

// These are placeholder implementations that need to be filled in with actual API calls

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class OpenAITranscriptionProvider: TranscriptionProvider {
    public let modelId: String
    public let capabilities: TranscriptionCapabilities

    private let model: TranscriptionModel.OpenAI
    let apiKey: String

    public init(model: TranscriptionModel.OpenAI, configuration: TachikomaConfiguration) throws {
        self.model = model
        self.modelId = model.rawValue

        guard let key = AudioConfiguration.getAPIKey(for: "openai", configuration: configuration) else {
            throw TachikomaError.authenticationFailed("OPENAI_API_KEY not found")
        }
        self.apiKey = key

        self.capabilities = TranscriptionCapabilities(
            supportedFormats: [.mp3, .wav, .flac, .m4a, .opus, .pcm],
            supportsTimestamps: model.supportsTimestamps,
            supportsLanguageDetection: model.supportsLanguageDetection,
            supportsSpeakerDiarization: false,
            supportsSummarization: false,
            supportsWordTimestamps: model.supportsTimestamps,
            maxFileSize: 25 * 1024 * 1024, // 25MB
            maxDuration: nil,
        )
    }

    // Implementation is in OpenAIAudioProvider.swift extension
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class OpenAISpeechProvider: SpeechProvider {
    public let modelId: String
    public let capabilities: SpeechCapabilities

    private let model: SpeechModel.OpenAI
    let apiKey: String

    public init(model: SpeechModel.OpenAI, configuration: TachikomaConfiguration) throws {
        self.model = model
        self.modelId = model.rawValue

        guard let key = AudioConfiguration.getAPIKey(for: "openai", configuration: configuration) else {
            throw TachikomaError.authenticationFailed("OPENAI_API_KEY not found")
        }
        self.apiKey = key

        self.capabilities = SpeechCapabilities(
            supportedFormats: model.supportedFormats,
            supportedVoices: model.supportedVoices,
            supportsVoiceInstructions: model.supportsVoiceInstructions,
            supportsSpeedControl: true,
            supportsLanguageSelection: false,
            supportsEmotionalControl: false,
            maxTextLength: 4096,
        )
    }

    // Implementation is in OpenAIAudioProvider.swift extension
}

// MARK: - Other Provider Stubs

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class GroqTranscriptionProvider: TranscriptionProvider {
    public let modelId: String
    public let capabilities: TranscriptionCapabilities

    public init(model: TranscriptionModel.Groq, configuration _: TachikomaConfiguration) throws {
        self.modelId = model.rawValue
        self.capabilities = TranscriptionCapabilities(
            supportsTimestamps: model.supportsTimestamps,
            supportsLanguageDetection: model.supportsLanguageDetection,
        )
    }

    public func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResult {
        // Groq uses OpenAI-compatible Whisper API
        guard let apiKey = AudioConfiguration.getAPIKey(for: "groq", configuration: TachikomaConfiguration()) else {
            throw TachikomaError.authenticationFailed("Groq API key not configured")
        }

        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Create multipart form data
        let boundary = UUID().uuidString
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var formData = Data()

        // Add audio file
        formData.append("--\(boundary)\r\n".utf8Data())
        formData
            .append(
                "Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(request.audio.format.rawValue)\"\r\n"
                    .utf8Data(),
            )
        formData.append("Content-Type: \(request.audio.format.mimeType)\r\n\r\n".utf8Data())
        formData.append(request.audio.data)
        formData.append("\r\n".utf8Data())

        // Add model
        formData.append("--\(boundary)\r\n".utf8Data())
        formData.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8Data())
        formData.append("\(self.modelId)\r\n".utf8Data())

        // Add optional parameters
        if let language = request.language {
            formData.append("--\(boundary)\r\n".utf8Data())
            formData.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".utf8Data())
            formData.append("\(language)\r\n".utf8Data())
        }

        if let prompt = request.prompt {
            formData.append("--\(boundary)\r\n".utf8Data())
            formData.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".utf8Data())
            formData.append("\(prompt)\r\n".utf8Data())
        }

        if !request.timestampGranularities.isEmpty {
            for granularity in request.timestampGranularities {
                formData.append("--\(boundary)\r\n".utf8Data())
                formData
                    .append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n"
                        .utf8Data())
                formData.append("\(granularity.rawValue)\r\n".utf8Data())
            }
        }

        // Close boundary
        formData.append("--\(boundary)--\r\n".utf8Data())

        urlRequest.httpBody = formData

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard
            let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode) else
        {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TachikomaError.apiError("Groq API error: \(errorMessage)")
        }

        // Parse response
        struct GroqResponse: Codable {
            let text: String
            let language: String?
            let duration: Double?
            let segments: [Segment]?

            struct Segment: Codable {
                let id: Int
                let start: Double
                let end: Double
                let text: String
            }
        }

        let groqResponse = try JSONDecoder().decode(GroqResponse.self, from: data)

        return TranscriptionResult(
            text: groqResponse.text,
            language: groqResponse.language,
            duration: groqResponse.duration,
            segments: groqResponse.segments?.map { segment in
                TranscriptionSegment(
                    text: segment.text,
                    start: segment.start,
                    end: segment.end,
                    confidence: nil,
                )
            },
        )
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class DeepgramTranscriptionProvider: TranscriptionProvider {
    public let modelId: String
    public let capabilities: TranscriptionCapabilities

    public init(model: TranscriptionModel.Deepgram, configuration _: TachikomaConfiguration) throws {
        self.modelId = model.rawValue
        self.capabilities = TranscriptionCapabilities(
            supportsTimestamps: model.supportsTimestamps,
            supportsLanguageDetection: model.supportsLanguageDetection,
            supportsSummarization: model.supportsSummarization,
        )
    }

    public func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard let apiKey = AudioConfiguration.getAPIKey(for: "deepgram", configuration: TachikomaConfiguration()) else {
            throw TachikomaError.authenticationFailed("Deepgram API key not configured")
        }

        var urlComponents = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        urlComponents.queryItems = [
            URLQueryItem(name: "model", value: self.modelId),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
        ]

        if !request.timestampGranularities.isEmpty {
            urlComponents.queryItems?.append(URLQueryItem(name: "timestamps", value: "true"))
        }

        if let language = request.language {
            urlComponents.queryItems?.append(URLQueryItem(name: "language", value: language))
        }

        // Note: speakerDiarization and summarize are not available in current request model
        // These would need to be added to TranscriptionRequest if needed

        guard let url = urlComponents.url else {
            throw TachikomaError.invalidInput("Failed to construct Deepgram API URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(request.audio.format.mimeType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = request.audio.data

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard
            let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode) else
        {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TachikomaError.apiError("Deepgram API error: \(errorMessage)")
        }

        // Parse response
        struct DeepgramResponse: Codable {
            let results: Results

            struct Results: Codable {
                let channels: [Channel]
                let utterances: [Utterance]?
                let summary: Summary?

                struct Channel: Codable {
                    let alternatives: [Alternative]

                    struct Alternative: Codable {
                        let transcript: String
                        let confidence: Double
                        let words: [Word]?

                        struct Word: Codable {
                            let word: String
                            let start: Double
                            let end: Double
                            let confidence: Double
                        }
                    }
                }

                struct Utterance: Codable {
                    let start: Double
                    let end: Double
                    let confidence: Double
                    let transcript: String
                    let speaker: Int?
                }

                struct Summary: Codable {
                    let short: String?
                }
            }
        }

        let deepgramResponse = try JSONDecoder().decode(DeepgramResponse.self, from: data)

        guard
            let firstChannel = deepgramResponse.results.channels.first,
            let bestAlternative = firstChannel.alternatives.first else
        {
            throw TachikomaError.apiError("No transcription results from Deepgram")
        }

        let segments: [TranscriptionSegment]? = deepgramResponse.results.utterances?.map { utterance in
            TranscriptionSegment(
                text: utterance.transcript,
                start: utterance.start,
                end: utterance.end,
                confidence: utterance.confidence,
                // Note: Speaker diarization info (utterance.speaker) is not included in TranscriptionSegment
            )
        }

        return TranscriptionResult(
            text: bestAlternative.transcript,
            language: request.language,
            duration: nil,
            segments: segments,
            // Note: Confidence and summary from Deepgram are not included in current TranscriptionResult model
        )
    }
}

// Low-priority providers removed - not implementing AssemblyAI, RevAI, Azure, LMNT, Hume

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class ElevenLabsTranscriptionProvider: TranscriptionProvider {
    public let modelId: String
    public let capabilities: TranscriptionCapabilities

    public init(model: TranscriptionModel.ElevenLabs, configuration _: TachikomaConfiguration) throws {
        self.modelId = model.rawValue
        self.capabilities = TranscriptionCapabilities(
            supportsTimestamps: model.supportsTimestamps,
            supportsLanguageDetection: model.supportsLanguageDetection,
        )
    }

    public func transcribe(request _: TranscriptionRequest) async throws -> TranscriptionResult {
        // ElevenLabs doesn't have a transcription API yet
        // This is a placeholder for future implementation
        throw TachikomaError
            .unsupportedOperation(
                "ElevenLabs transcription is not available - ElevenLabs only supports speech generation",
            )
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class ElevenLabsSpeechProvider: SpeechProvider {
    public let modelId: String
    public let capabilities: SpeechCapabilities

    public init(model: SpeechModel.ElevenLabs, configuration _: TachikomaConfiguration) throws {
        self.modelId = model.rawValue
        self.capabilities = SpeechCapabilities(
            supportedFormats: model.supportedFormats,
            supportsVoiceInstructions: model.supportsVoiceCloning,
        )
    }

    private func mapVoiceToElevenLabsId(_ voice: VoiceOption) -> String {
        // Map standard voice options to ElevenLabs voice IDs
        // These are default ElevenLabs voices
        switch voice {
        case .alloy:
            "21m00Tcm4TlvDq8ikWAM" // Rachel
        case .echo:
            "AZnzlk1XvdvUeBnXmlld" // Domi
        case .fable:
            "ThT5KcBeYPX3keUQqHPh" // Nicole
        case .onyx:
            "pNInz6obpgDQGcFmaJgB" // Adam
        case .nova:
            "MF3mGyEYCl7XYWbV9V6O" // Elli
        case .shimmer:
            "LcfcDJNUP1GQjkzn1xUU" // Emily
        default:
            "21m00Tcm4TlvDq8ikWAM" // Default to Rachel
        }
    }

    public func generateSpeech(request: SpeechRequest) async throws -> SpeechResult {
        guard let apiKey = AudioConfiguration.getAPIKey(for: "elevenlabs", configuration: TachikomaConfiguration()) else {
            throw TachikomaError.authenticationFailed("ElevenLabs API key not configured")
        }

        // Default voice if not specified - map VoiceOption to ElevenLabs voice ID
        let voiceId = self.mapVoiceToElevenLabsId(request.voice)
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build request body
        struct ElevenLabsRequest: Codable {
            let text: String
            let model_id: String
            let voice_settings: VoiceSettings?

            struct VoiceSettings: Codable {
                let stability: Double
                let similarity_boost: Double
                let style: Double?
                let use_speaker_boost: Bool?
            }
        }

        let requestBody = ElevenLabsRequest(
            text: request.text,
            model_id: self.modelId,
            voice_settings: ElevenLabsRequest.VoiceSettings(
                stability: 0.5,
                similarity_boost: 0.75,
                style: nil,
                use_speaker_boost: nil,
            ),
        )

        urlRequest.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard
            let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode) else
        {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TachikomaError.apiError("ElevenLabs API error: \(errorMessage)")
        }

        // The response is raw audio data
        return SpeechResult(
            audioData: AudioData(data: data, format: .mp3),
            usage: nil,
        )
    }
}

// MARK: - Mock Providers for Testing

/// Mock transcription provider for testing
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class MockTranscriptionProvider: TranscriptionProvider {
    public let modelId: String
    public let capabilities: TranscriptionCapabilities

    private let model: TranscriptionModel

    public init(model: TranscriptionModel) {
        self.model = model
        self.modelId = model.modelId

        // Set capabilities based on the model
        switch model {
        case let .openai(openaiModel):
            self.capabilities = TranscriptionCapabilities(
                supportedFormats: [.flac, .m4a, .mp3, .opus, .aac, .ogg, .wav, .pcm],
                supportsTimestamps: openaiModel.supportsTimestamps,
                supportsLanguageDetection: openaiModel.supportsLanguageDetection,
                supportsWordTimestamps: openaiModel.supportsTimestamps,
                maxFileSize: 25 * 1024 * 1024, // 25MB
            )
        default:
            self.capabilities = TranscriptionCapabilities(
                supportedFormats: AudioFormat.allCases,
                supportsTimestamps: true,
                supportsLanguageDetection: true,
                supportsWordTimestamps: true,
            )
        }
    }

    public func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResult {
        // Check for abort signal
        try request.abortSignal?.throwIfCancelled()

        // Validate audio data
        if request.audio.data.isEmpty {
            throw TachikomaError.invalidInput("Audio data is empty")
        }

        // Check file size limits
        if let maxSize = capabilities.maxFileSize, request.audio.data.count > maxSize {
            throw TachikomaError
                .invalidInput("Audio file too large: \(request.audio.data.count) bytes (max: \(maxSize))")
        }

        // Simulate network delay
        try await Task.sleep(for: .milliseconds(100))

        // Check for abort signal again after delay
        try request.abortSignal?.throwIfCancelled()

        let mockText = "mock transcription"
        let mockDuration = request.audio.duration ?? 2.0

        // Create segments if timestamps are requested
        var segments: [TranscriptionSegment]?
        if request.timestampGranularities.contains(.segment) || request.responseFormat == .verbose {
            segments = [
                TranscriptionSegment(
                    text: mockText,
                    start: 0.0,
                    end: mockDuration,
                    words: request.timestampGranularities.contains(.word) ? [
                        TranscriptionWord(word: "mock", start: 0.0, end: mockDuration / 2),
                        TranscriptionWord(word: "transcription", start: mockDuration / 2, end: mockDuration),
                    ] : nil,
                ),
            ]
        }

        return TranscriptionResult(
            text: mockText,
            language: request.language ?? "en",
            duration: mockDuration,
            segments: segments,
            usage: TranscriptionUsage(durationSeconds: mockDuration),
        )
    }
}

/// Mock speech provider for testing
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class MockSpeechProvider: SpeechProvider {
    public let modelId: String
    public let capabilities: SpeechCapabilities

    private let model: SpeechModel

    public init(model: SpeechModel) {
        self.model = model
        self.modelId = model.modelId

        // Set capabilities based on the model
        switch model {
        case let .openai(openaiModel):
            self.capabilities = SpeechCapabilities(
                supportedFormats: openaiModel.supportedFormats,
                supportedVoices: openaiModel.supportedVoices,
                supportsVoiceInstructions: openaiModel.supportsVoiceInstructions,
                supportsSpeedControl: true,
                maxTextLength: 4096,
            )
        default:
            self.capabilities = SpeechCapabilities(
                supportedFormats: [.mp3, .wav],
                supportedVoices: [.alloy, .echo, .fable, .onyx, .nova, .shimmer],
                supportsSpeedControl: true,
            )
        }
    }

    public func generateSpeech(request: SpeechRequest) async throws -> SpeechResult {
        // Check for abort signal
        try request.abortSignal?.throwIfCancelled()

        // Validate text
        if request.text.isEmpty {
            throw TachikomaError.invalidInput("Text is empty")
        }

        // Check text length limits
        if let maxLength = capabilities.maxTextLength, request.text.count > maxLength {
            throw TachikomaError.invalidInput("Text too long: \(request.text.count) characters (max: \(maxLength))")
        }

        // Validate voice
        if !self.capabilities.supportedVoices.contains(request.voice) {
            throw TachikomaError.invalidInput("Unsupported voice: \(request.voice.stringValue)")
        }

        // Validate format
        if !self.capabilities.supportedFormats.contains(request.format) {
            throw TachikomaError.invalidInput("Unsupported format: \(request.format.rawValue)")
        }

        // Validate speed
        if request.speed < 0.25 || request.speed > 4.0 {
            throw TachikomaError.invalidInput("Speed must be between 0.25 and 4.0")
        }

        // Simulate network delay
        try await Task.sleep(for: .milliseconds(100))

        // Check for abort signal again after delay
        try request.abortSignal?.throwIfCancelled()

        // Generate minimal audio data (4 bytes)
        let mockAudioData = Data([0x00, 0x01, 0x02, 0x03])

        return SpeechResult(
            audioData: AudioData(data: mockAudioData, format: request.format),
            usage: SpeechUsage(charactersProcessed: request.text.count),
        )
    }
}
