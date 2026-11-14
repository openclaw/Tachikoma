import Foundation
import Logging
import Tachikoma // For TachikomaError
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

// MARK: - Recording Errors

/// Error types for audio recording operations
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum AudioRecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case microphonePermissionDenied
    case audioEngineError(String)
    case failedToCreateFile
    case noRecordingAvailable
    case recordingTooShort
    case recordingTooLong

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Already recording audio"
        case .notRecording:
            "Not currently recording"
        case .microphonePermissionDenied:
            "Microphone permission denied"
        case let .audioEngineError(message):
            "Audio engine error: \(message)"
        case .failedToCreateFile:
            "Failed to create recording file"
        case .noRecordingAvailable:
            "No recording available"
        case .recordingTooShort:
            "Recording is too short"
        case .recordingTooLong:
            "Recording exceeded maximum duration"
        }
    }
}

/// Protocol for audio recording functionality
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@MainActor
public protocol AudioRecorderProtocol: Sendable {
    var isRecording: Bool { get }
    var isAvailable: Bool { get }
    var recordingDuration: TimeInterval { get }

    /// Begin capturing audio input using the recorder's current configuration.
    func startRecording() async throws
    /// Stop capturing audio and return the recorded payload.
    func stopRecording() async throws -> AudioData
    /// Abort recording without producing an artifact.
    func cancelRecording() async
    /// Temporarily halt recording while preserving the existing capture.
    func pauseRecording() async
    /// Resume a paused recording session.
    func resumeRecording() async
}

#if canImport(AVFoundation)
private let logger = Logger(label: "tachikoma.audio.recorder")

/// Main audio recorder implementation using AVFoundation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@MainActor
public final class AudioRecorder: ObservableObject, AudioRecorderProtocol {
    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var isPaused = false

    private var recordingStartTime: Date?
    private var recordingTimer: Timer?
    private var pausedDuration: TimeInterval = 0
    private var pauseStartTime: Date?

    // Audio format settings
    private let sampleRate: Double = 44100
    private let channels: AVAudioChannelCount = 1
    private let bitDepth: Int = 16

    /// Maximum recording duration (5 minutes by default)
    public var maxRecordingDuration: TimeInterval = 300

    // MARK: - Initialization

    public init() {
        // Initialize with default settings
    }

    // MARK: - Public Properties

    /// Check if audio recording is available
    public var isAvailable: Bool {
        #if os(macOS)
        AVCaptureDevice.authorizationStatus(for: .audio) != .denied
        #elseif os(iOS) || os(tvOS) || os(watchOS)
        AVAudioSession.sharedInstance().recordPermission != .denied
        #else
        true
        #endif
    }

    // MARK: - Recording Methods

    /// Start recording audio from the microphone
    public func startRecording() async throws {
        // Start recording audio from the microphone
        guard !self.isRecording else {
            throw AudioRecordingError.alreadyRecording
        }

        // Check microphone permission
        let authorized = await checkMicrophonePermission()
        guard authorized else {
            throw AudioRecordingError.microphonePermissionDenied
        }

        // Configure audio session only after permission is granted
        configureAudioSession()

        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).wav"
        self.recordingURL = tempDir.appendingPathComponent(fileName)

        guard let url = recordingURL else {
            throw AudioRecordingError.failedToCreateFile
        }

        // Setup audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine else {
            throw AudioRecordingError.audioEngineError("Failed to create audio engine")
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Create audio file
        audioFile = try AVAudioFile(forWriting: url, settings: recordingFormat.settings)

        // Install tap on a background queue to avoid inheriting any actor/queue context
        guard let audioFile else {
            throw AudioRecordingError.failedToCreateFile
        }

        DispatchQueue.global(qos: .userInitiated).sync {
            installInputTapNonisolated(inputNode: inputNode, format: recordingFormat, audioFile: audioFile)
        }

        // Start the audio engine
        try audioEngine.start()

        // Update state
        self.isRecording = true
        self.isPaused = false
        self.recordingStartTime = Date()
        self.pausedDuration = 0

        // Start duration timer
        self.startDurationTimer()

        logger.info("Started audio recording")
    }

    /// Stop recording and return the recorded audio
    public func stopRecording() async throws -> AudioData {
        // Stop recording and return the recorded audio
        guard self.isRecording else {
            throw AudioRecordingError.notRecording
        }

        // Stop the audio engine
        self.audioEngine?.stop()
        self.audioEngine?.inputNode.removeTap(onBus: 0)
        self.audioEngine = nil

        // Close the audio file
        self.audioFile = nil

        // Stop the timer
        self.stopDurationTimer()

        // Update state
        self.isRecording = false
        self.isPaused = false
        self.recordingDuration = 0
        self.recordingStartTime = nil
        self.pausedDuration = 0

        logger.info("Stopped audio recording")

        // Read the recorded audio
        guard let url = recordingURL else {
            throw AudioRecordingError.noRecordingAvailable
        }

        defer {
            // Clean up the temporary file
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        return try AudioData(contentsOf: url)
    }

    /// Cancel recording without returning data
    public func cancelRecording() async {
        // Cancel recording without returning data
        guard self.isRecording else { return }

        // Stop the audio engine
        self.audioEngine?.stop()
        self.audioEngine?.inputNode.removeTap(onBus: 0)
        self.audioEngine = nil

        // Close the audio file
        self.audioFile = nil

        // Stop the timer
        self.stopDurationTimer()

        // Update state
        self.isRecording = false
        self.isPaused = false
        self.recordingDuration = 0
        self.recordingStartTime = nil
        self.pausedDuration = 0

        // Clean up the temporary file
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            self.recordingURL = nil
        }

        logger.info("Cancelled audio recording")
    }

    /// Pause the current recording
    public func pauseRecording() async {
        // Pause the current recording
        guard self.isRecording, !self.isPaused else { return }

        self.audioEngine?.pause()
        self.isPaused = true
        self.pauseStartTime = Date()

        logger.info("Paused audio recording")
    }

    /// Resume a paused recording
    public func resumeRecording() async {
        // Resume a paused recording
        guard self.isRecording, self.isPaused else { return }

        if let pauseStart = pauseStartTime {
            self.pausedDuration += Date().timeIntervalSince(pauseStart)
        }

        do {
            try self.audioEngine?.start()
            self.isPaused = false
            self.pauseStartTime = nil

            logger.info("Resumed audio recording")
        } catch {
            logger.error("Failed to resume recording: \(error)")
        }
    }

    // MARK: - Private Methods

    private func checkMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            #if os(macOS)
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            case .denied, .restricted:
                continuation.resume(returning: false)
            @unknown default:
                continuation.resume(returning: false)
            }
            #elseif os(iOS) || os(tvOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                continuation.resume(returning: true)
            case .denied:
                continuation.resume(returning: false)
            case .undetermined:
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            @unknown default:
                continuation.resume(returning: false)
            }
            #else
            continuation.resume(returning: true)
            #endif
        }
    }

    private func startDurationTimer() {
        self.stopDurationTimer()

        let startTime = self.recordingStartTime
        self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let startTime else { return }

            Task { @MainActor in
                let elapsed = Date().timeIntervalSince(startTime) - self.pausedDuration
                self.recordingDuration = elapsed

                // Check max duration
                if elapsed >= self.maxRecordingDuration {
                    logger.warning("Max recording duration reached")
                    _ = try? await self.stopRecording()
                }
            }
        }
    }

    private func stopDurationTimer() {
        self.recordingTimer?.invalidate()
        self.recordingTimer = nil
    }
}

// MARK: - Thread-safe audio file wrapper

/// Thread-safe wrapper for AVAudioFile to handle concurrent writes
private final class ThreadSafeAudioFile: @unchecked Sendable {
    private let audioFile: AVAudioFile
    private let lock = NSLock()

    init(audioFile: AVAudioFile) {
        self.audioFile = audioFile
    }

    func write(from buffer: AVAudioPCMBuffer) throws {
        self.lock.lock()
        defer { lock.unlock() }
        try self.audioFile.write(from: buffer)
    }
}

// MARK: - Realtime helper (free function, not MainActor-isolated)

private func installInputTapNonisolated(
    inputNode: AVAudioInputNode,
    format: AVAudioFormat,
    audioFile: AVAudioFile,
) {
    let threadSafeFile = ThreadSafeAudioFile(audioFile: audioFile)

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        do {
            try threadSafeFile.write(from: buffer)
        } catch {
            logger.error("Failed to write audio buffer: \(error)")
        }
    }
}

// MARK: - Platform-Specific Extensions

#if os(iOS) || os(watchOS) || os(tvOS)
import UIKit

@available(iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension AudioRecorder {
    /// Configure audio session for iOS/watchOS/tvOS
    private func configureAudioSession() {
        // Configure audio session for iOS/watchOS/tvOS
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }
}
#endif

#if os(macOS)
@available(macOS 13.0, *)
extension AudioRecorder {
    /// No-op on macOS where `AVAudioSession` is not used
    private func configureAudioSession() {
        // No-op on macOS where `AVAudioSession` is not used
    }
}
#endif
#endif // canImport(AVFoundation)

#if !canImport(AVFoundation)
private let logger = Logger(label: "tachikoma.audio.recorder")

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@MainActor
public final class AudioRecorder: AudioRecorderProtocol {
    public init() {}

    public var isRecording: Bool {
        false
    }

    public var isAvailable: Bool {
        false
    }

    public var recordingDuration: TimeInterval {
        0
    }

    public func startRecording() async throws {
        throw AudioRecordingError.audioEngineError("Audio recording is unavailable on this platform")
    }

    public func stopRecording() async throws -> AudioData {
        throw AudioRecordingError.audioEngineError("Audio recording is unavailable on this platform")
    }

    public func cancelRecording() async {}
    public func pauseRecording() async {}
    public func resumeRecording() async {}
}
#endif
