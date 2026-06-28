//
//  NotePlaybackEngine.swift
//  TabBuddy
//
//  Synthesizes guitar-like audio for parsed note events using
//  Karplus-Strong plucked string synthesis. Toggled independently
//  from the metronome during playback.
//

import AVFoundation

@MainActor
final class NotePlaybackEngine: ObservableObject {

    // MARK: - Published state

    /// Whether note playback is active (off by default)
    @Published var isEnabled: Bool = false

    /// Playback volume (0.0–1.0)
    @Published var volume: Float = 0.5

    // MARK: - Audio engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// A small room reverb gives the dry plucked-string synth some natural space
    /// and a soft tail (which keeps ringing after a note is interrupted), which
    /// is most of the perceived quality jump over the bare Karplus-Strong sound.
    private let reverb = AVAudioUnitReverb()

    private let sampleRate: Double = 44100
    private let format: AVAudioFormat

    /// Duration of each synthesized note buffer in seconds.
    /// Intentionally long — each note rings until the next one fires
    /// (via .interrupts), just like a real plucked guitar string.
    /// At 60 BPM with quarter notes, gap between notes = 1.0s.
    /// At 30 BPM, gap = 2.0s. 2.0s covers the slowest practical tempos.
    private let noteDuration: Double = 2.0

    // MARK: - Standard tuning MIDI base notes (high E to low E)
    // Index 0 = high E string (E4 = MIDI 64)
    // Index 5 = low E string  (E2 = MIDI 40)
    private static let standardTuningMIDI: [Int] = [64, 59, 55, 50, 45, 40]

    // MARK: - Note cache

    /// Pre-computed Karplus-Strong buffers for each MIDI note.
    /// Key: MIDI note number, Value: pre-rendered audio buffer.
    /// Covers MIDI 28 (E1, lowest possible) through 88 (E6, fret 24 on high E).
    private var noteCache: [Int: AVAudioPCMBuffer] = [:]

    // MARK: - Init

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        setupEngine()
        buildNoteCache()
    }

    // MARK: - Setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 22  // mostly dry, a touch of room
        // playerNode → reverb → mixer. The reverb tail survives `.interrupts`
        // (which only replaces the dry player buffer), giving a natural release.
        engine.connect(playerNode, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
    }

    /// Pre-compute Karplus-Strong buffers for all playable guitar notes.
    /// MIDI 28–88 covers everything from drop tunings through fret 24.
    /// ~60 notes × 15,435 frames × 4 bytes ≈ 3.6 MB — very manageable.
    private func buildNoteCache() {
        let frameCount = Int(sampleRate * noteDuration)
        for midi in 28...88 {
            let frequency = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
            if let buffer = synthesizeNote(frequency: frequency, frameCount: frameCount) {
                noteCache[midi] = buffer
            }
        }
    }

    func start() {
        guard !engine.isRunning else { return }
        // Configure audio session (shared with MetronomeEngine)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("NotePlaybackEngine: audio session setup failed: \(error)")
        }
        do {
            try engine.start()
        } catch {
            print("NotePlaybackEngine: engine start failed: \(error)")
        }
    }

    func stop() {
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Immediately silence any playing notes (used on seek/stop).
    func stopNotes() {
        guard engine.isRunning else { return }
        playerNode.stop()
        playerNode.play()  // re-arm for next schedule
    }

    // MARK: - Direct MIDI Playback

    /// Play a single MIDI note directly, bypassing fret-to-MIDI conversion.
    /// Used by the tab maker for instant audio feedback during note placement.
    func playMIDI(_ midi: Int) {
        guard engine.isRunning else { return }
        guard let buffer = noteCache[midi] else { return }

        playerNode.volume = volume
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts,
                                  completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    // MARK: - Note Playback

    /// Play a chord or single note from parsed fret data.
    /// Uses pre-cached buffers for zero-latency playback.
    /// Each call interrupts any currently playing note — just like a real guitar
    /// where new notes naturally mute previous strings.
    func playNotes(_ frets: [Int?], tuningMIDI: [Int]? = nil) {
        guard isEnabled, engine.isRunning else { return }

        let openStrings = tuningMIDI ?? Self.standardTuningMIDI
        var midiNotes: [Int] = []
        for (stringIndex, fret) in frets.enumerated() {
            guard let f = fret, stringIndex < openStrings.count else { continue }
            let midiNote = openStrings[stringIndex] + f
            midiNotes.append(midiNote)
        }

        guard !midiNotes.isEmpty else { return }

        // Look up cached buffers and mix into a single chord buffer
        guard let chordBuffer = mixCachedNotes(midiNotes) else { return }

        playerNode.volume = volume
        // .interrupts: immediately replace any currently playing buffer
        // This keeps audio in sync with the visual highlight
        playerNode.scheduleBuffer(chordBuffer, at: nil, options: .interrupts,
                                  completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    // MARK: - Buffer Mixing

    /// Mix pre-cached single-note buffers into one chord buffer.
    private func mixCachedNotes(_ midiNotes: [Int]) -> AVAudioPCMBuffer? {
        // Gather cached buffers
        let buffers = midiNotes.compactMap { noteCache[$0] }
        guard !buffers.isEmpty else { return nil }

        // If single note, return the cached buffer directly (no copy needed)
        if buffers.count == 1 {
            return buffers[0]
        }

        // Mix multiple notes into a new buffer
        let frameCount = buffers.map { $0.frameLength }.max() ?? 0
        guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        mixed.frameLength = frameCount
        guard let mixedData = mixed.floatChannelData?[0] else { return nil }

        // Zero
        for i in 0..<Int(frameCount) {
            mixedData[i] = 0
        }

        // Sum all buffers
        let scale = 1.0 / Float(buffers.count)
        for buf in buffers {
            guard let bufData = buf.floatChannelData?[0] else { continue }
            let len = min(Int(buf.frameLength), Int(frameCount))
            for i in 0..<len {
                mixedData[i] += bufData[i] * scale
            }
        }

        return mixed
    }

    // MARK: - Karplus-Strong Synthesis

    /// Synthesize a single note as a Karplus-Strong plucked string.
    ///
    /// Improvements over the bare algorithm for a more guitar-like, less buzzy
    /// tone: the excitation is a *shaped* pluck (low-passed noise with a
    /// pluck-position comb) rather than raw white noise; the loop decay is
    /// lightly pitch-dependent; and the output gets a short attack ramp plus a
    /// tail fade so notes start and end without clicks.
    private func synthesizeNote(frequency: Double, frameCount: Int) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let data = buffer.floatChannelData?[0] else { return nil }

        let delayLength = max(2, Int((sampleRate / frequency).rounded()))

        // –– Shaped pluck excitation ––
        var delayLine = [Float](repeating: 0, count: delayLength)
        for i in 0..<delayLength { delayLine[i] = Float.random(in: -1...1) }
        // Low-pass the noise burst → softer, warmer attack (less white-noise buzz).
        // Brighter for higher notes so they keep some sparkle.
        let brightness = Float(min(0.85, 0.35 + frequency / 1500.0))
        var lp: Float = 0
        for i in 0..<delayLength {
            lp += brightness * (delayLine[i] - lp)
            delayLine[i] = lp
        }
        // Pluck-position comb: subtract a delayed copy (~1/5 along the string) to
        // notch out a harmonic, the classic "plucked" colouration.
        let pluckPos = max(1, delayLength / 5)
        for i in stride(from: delayLength - 1, through: pluckPos, by: -1) {
            delayLine[i] -= delayLine[i - pluckPos]
        }
        // Normalise to a consistent level.
        var peak: Float = 0.0001
        for v in delayLine { peak = max(peak, abs(v)) }
        let norm = 0.6 / peak
        for i in 0..<delayLength { delayLine[i] *= norm }

        // –– Loop decay: slightly longer sustain on low strings ––
        let decay: Float = frequency < 200 ? 0.9990 : 0.9986

        // Envelope lengths (samples).
        let attack = min(frameCount, Int(sampleRate * 0.004))   // ~4ms attack ramp
        let fade = min(frameCount, Int(sampleRate * 0.06))      // ~60ms tail fade

        var readIndex = 0
        for i in 0..<frameCount {
            let current = delayLine[readIndex]
            let nextIndex = (readIndex + 1) % delayLength
            let filtered = (current + delayLine[nextIndex]) * 0.5 * decay
            delayLine[readIndex] = filtered

            var sample = current
            if i < attack {
                sample *= Float(i) / Float(attack)               // soft onset
            }
            if i > frameCount - fade {
                sample *= Float(frameCount - i) / Float(fade)     // tail fade-out
            }
            data[i] = sample

            readIndex = nextIndex
        }

        return buffer
    }
}
