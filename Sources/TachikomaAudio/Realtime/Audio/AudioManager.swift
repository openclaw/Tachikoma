#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation
import Tachikoma

// MARK: - Audio Manager

/// Manages audio capture and playback for the Realtime API
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
@MainActor
public final class RealtimeAudioManager: NSObject {
    // MARK: - Properties

    /// Audio engine for processing
    private let audioEngine = AVAudioEngine()

    /// Input node for capturing audio
    private var inputNode: AVAudioInputNode {
        self.audioEngine.inputNode
    }

    /// Output node for playback
    private var outputNode: AVAudioOutputNode {
        self.audioEngine.outputNode
    }

    /// Player node for audio playback
    private let playerNode = AVAudioPlayerNode()

    /// Audio processor for format conversion
    private let processor: RealtimeAudioProcessor

    /// Current recording state
    public private(set) var isRecording = false

    /// Current playback state
    public private(set) var isPlaying = false

    /// Audio level for UI feedback
    public private(set) var audioLevel: Float = 0

    /// Callback for captured audio data
    public var onAudioCaptured: ((Data) async -> Void)?

    /// Callback for audio level updates
    public var onAudioLevelUpdate: ((Float) -> Void)?

    // Audio session configuration
    #if os(iOS) || os(watchOS) || os(tvOS)
    private let audioSession = AVAudioSession.sharedInstance()
    #endif

    /// Audio format for API (24kHz PCM16)
    private let apiFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: true,
    )!

    // Buffer for audio playback queue
    private var playbackQueue: [AVAudioPCMBuffer] = []
    private let playbackQueueLock = NSLock()

    // MARK: - Initialization

    override public init() {
        do {
            self.processor = try RealtimeAudioProcessor()
        } catch {
            fatalError("Failed to initialize audio processor: \(error)")
        }

        super.init()
        self.setupAudioEngine()
    }

    // MARK: - Setup

    private func setupAudioEngine() {
        // Attach player node
        self.audioEngine.attach(self.playerNode)

        // Connect player to output
        self.audioEngine.connect(
            self.playerNode,
            to: self.outputNode,
            format: self.apiFormat,
        )

        // Configure audio session for iOS
        #if os(iOS) || os(watchOS) || os(tvOS)
        do {
            try self.audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth],
            )
            try self.audioSession.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
        #endif
    }

    // MARK: - Recording

    /// Start recording audio
    public func startRecording() async throws {
        // Start recording audio
        guard !self.isRecording else { return }

        // Request microphone permission if needed
        #if os(iOS) || os(watchOS) || os(tvOS)
        let permission = AVAudioSession.sharedInstance().recordPermission
        if permission == .undetermined {
            await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { _ in
                    continuation.resume()
                }
            }
        }

        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            throw TachikomaError.permissionDenied("Microphone permission denied")
        }
        #endif

        // Install tap on input node
        let inputFormat = self.inputNode.outputFormat(forBus: 0)
        self.inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat,
        ) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                await self?.processAudioBuffer(buffer)
            }
        }

        // Start audio engine
        if !self.audioEngine.isRunning {
            try self.audioEngine.start()
        }

        self.isRecording = true
    }

    /// Stop recording audio
    public func stopRecording() {
        // Stop recording audio
        guard self.isRecording else { return }

        // Remove tap
        self.inputNode.removeTap(onBus: 0)

        // Stop engine if not playing
        if !self.isPlaying, self.audioEngine.isRunning {
            self.audioEngine.stop()
        }

        self.isRecording = false
        self.audioLevel = 0
        self.onAudioLevelUpdate?(0)
    }

    // MARK: - Playback

    /// Play audio data
    public func playAudio(_ data: Data) async throws {
        // Convert data to buffer
        let buffer = try processor.processOutput(data)

        // Add to playback queue
        await MainActor.run {
            self.playbackQueueLock.withLock {
                self.playbackQueue.append(buffer)
            }
        }

        // Start playback if not already playing
        if !self.isPlaying {
            await self.startPlayback()
        }
    }

    /// Start audio playback
    private func startPlayback() async {
        // Start audio playback
        guard !self.isPlaying else { return }

        // Start engine if needed
        if !self.audioEngine.isRunning {
            do {
                try self.audioEngine.start()
            } catch {
                print("Failed to start audio engine: \(error)")
                return
            }
        }

        self.isPlaying = true
        self.playerNode.play()

        // Process playback queue
        Task {
            await self.processPlaybackQueue()
        }
    }

    /// Stop audio playback
    public func stopPlayback() {
        // Stop audio playback
        guard self.isPlaying else { return }

        self.playerNode.stop()

        // Clear playback queue
        self.playbackQueueLock.lock()
        self.playbackQueue.removeAll()
        self.playbackQueueLock.unlock()

        // Stop engine if not recording
        if !self.isRecording, self.audioEngine.isRunning {
            self.audioEngine.stop()
        }

        self.isPlaying = false
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async {
        // Calculate audio level
        let level = self.processor.calculateRMS(buffer)
        self.audioLevel = level
        self.onAudioLevelUpdate?(level)

        // Check for silence
        if self.processor.detectSilence(buffer) {
            // Don't send silent audio to save bandwidth
            return
        }

        // Process buffer to API format
        do {
            let data = try processor.processInput(buffer)
            await self.onAudioCaptured?(data)
        } catch {
            print("Failed to process audio buffer: \(error)")
        }
    }

    private func processPlaybackQueue() async {
        while self.isPlaying {
            // Get next buffer from queue
            let buffer = await MainActor.run {
                self.playbackQueueLock.withLock {
                    self.playbackQueue.isEmpty ? nil : self.playbackQueue.removeFirst()
                }
            }

            if let buffer {
                // Schedule buffer for playback
                await self.playerNode.scheduleBuffer(buffer)

                // Wait a bit before checking next buffer
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            } else {
                // No more buffers, wait a bit
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }
    }

    // MARK: - Utility

    /// Reset audio manager
    public func reset() {
        // Reset audio manager
        self.stopRecording()
        self.stopPlayback()

        // Reset audio level
        self.audioLevel = 0
        self.onAudioLevelUpdate?(0)
    }

    /// Get current audio devices
    public func getAudioDevices() -> (input: String?, output: String?) {
        // Get current audio devices
        #if os(macOS)
        // Get device names (simplified - would need Core Audio for full implementation)
        ("Default Input", "Default Output")
        #else
        ("Built-in Microphone", "Built-in Speaker")
        #endif
    }

    // Set audio input device (macOS only)
    #if os(macOS)
    public func setInputDevice(_: AudioDeviceID) throws {
        // Note: Setting audio device on macOS requires more complex Core Audio API
        // This is a simplified placeholder implementation
        // In production, you would need to:
        // 1. Stop the audio engine
        // 2. Configure the audio session/unit
        // 3. Restart the audio engine
        throw TachikomaError.unsupportedOperation("Setting input device not yet implemented")
    }
    #endif
}

// MARK: - Audio Manager Extensions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension RealtimeAudioManager {
    /// Configure for voice chat optimized settings
    public func configureForVoiceChat() {
        // Configure for voice chat optimized settings
        #if os(iOS) || os(watchOS) || os(tvOS)
        do {
            try self.audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers],
            )

            // Optimize for low latency
            try self.audioSession.setPreferredIOBufferDuration(0.005) // 5ms buffer
            try self.audioSession.setPreferredSampleRate(48000) // Device native rate
        } catch {
            print("Failed to configure audio session for voice chat: \(error)")
        }
        #endif
    }

    /// Enable echo cancellation
    public func setEchoCancellation(_: Bool) {
        // Enable echo cancellation
        #if os(iOS) || os(watchOS) || os(tvOS)
        // Echo cancellation is typically enabled by default in .voiceChat mode
        // This is a placeholder for more advanced configuration
        #endif
    }

    /// Set voice processing (noise suppression, etc.)
    public func setVoiceProcessing(_ enabled: Bool) {
        // Set voice processing (noise suppression, etc.)
        #if os(iOS) || os(watchOS) || os(tvOS)
        do {
            if enabled {
                try self.audioSession.setMode(.voiceChat)
            } else {
                try self.audioSession.setMode(.default)
            }
        } catch {
            print("Failed to set voice processing: \(error)")
        }
        #endif
    }
}

#endif // canImport(AVFoundation)
