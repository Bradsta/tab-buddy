//
//  MetronomeEngine.swift
//  TabBuddy
//
//  Audible beat click using AVAudioEngine. Uses .playAndRecord category
//  to support future microphone input for live guitar detection (Phase 4).
//

import AVFoundation

@MainActor
final class MetronomeEngine: ObservableObject {

    // MARK: - Published state

    @Published var isEnabled: Bool = true
    @Published var volume: Float = 0.7

    // MARK: - Audio engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// Pre-rendered click buffers (accent + normal)
    private var accentBuffer: AVAudioPCMBuffer?
    private var normalBuffer: AVAudioPCMBuffer?

    /// Audio format for click synthesis
    private let sampleRate: Double = 44100
    private let format: AVAudioFormat

    // MARK: - Init

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        accentBuffer = synthesizeClick(frequency: 1200, duration: 0.03, amplitude: 0.8)
        normalBuffer = synthesizeClick(frequency: 800, duration: 0.025, amplitude: 0.5)
        setupEngine()
    }

    // MARK: - Setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    /// Configure audio session. Uses .playAndRecord to support future mic input.
    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("MetronomeEngine: audio session setup failed: \(error)")
        }
    }

    func start() {
        guard !engine.isRunning else { return }
        configureAudioSession()
        do {
            try engine.start()
        } catch {
            print("MetronomeEngine: engine start failed: \(error)")
        }
    }

    func stop() {
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Click Playback

    /// Play a click. Called by PlaybackCoordinator on each beat.
    /// - Parameters:
    ///   - beatInMeasure: 0-based beat index within the measure
    ///   - beatsPerMeasure: total beats in the measure
    func playClick(beatInMeasure: Int, beatsPerMeasure: Int) {
        guard isEnabled, engine.isRunning else { return }

        let buffer = (beatInMeasure == 0) ? accentBuffer : normalBuffer
        guard let buf = buffer else { return }

        playerNode.volume = volume
        // Schedule immediately for lowest latency
        playerNode.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    // MARK: - Click Synthesis

    /// Generate a short click/tick sound as a PCM buffer.
    /// Uses a sine wave with exponential decay envelope.
    private func synthesizeClick(
        frequency: Double,
        duration: Double,
        amplitude: Float
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData?[0] else { return nil }

        let twoPi = 2.0 * Double.pi
        let decayRate = 10.0 / duration  // decay to near-zero over the duration

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let sine = sin(twoPi * frequency * t)
            let envelope = exp(-decayRate * t)
            data[i] = Float(sine * envelope) * amplitude
        }

        return buffer
    }
}
