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
    /// One voice per guitar string (index 0 = high E … 5 = low E). A new note
    /// interrupts only its own string's voice, so the other strings keep
    /// ringing — chords and arpeggios sustain like a real guitar instead of
    /// the old single-voice monophonic playback.
    private var stringNodes: [AVAudioPlayerNode] = [AVAudioPlayerNode()]
    /// Sums the string voices before the shared reverb (an effect node
    /// accepts only one input).
    private let stringMixer = AVAudioMixerNode()
    /// A small room reverb gives the dry plucked-string synth some natural space
    /// and a soft tail (which keeps ringing after a note is interrupted), which
    /// is most of the perceived quality jump over the bare Karplus-Strong sound.
    private let reverb = AVAudioUnitReverb()

    private var engineConfigured = false
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
    /// Covers MIDI 21–96, including extended bass and guitar ranges.
    private var noteCache: [Int: AVAudioPCMBuffer] = [:]

    // MARK: - Init

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    // MARK: - Setup

    private func setupEngine() {
        engine.attach(stringMixer)
        engine.attach(reverb)
        for node in stringNodes {
            engine.attach(node)
            engine.connect(node, to: stringMixer, format: format)
        }
        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 22  // mostly dry, a touch of room
        // strings → mixer → reverb → main. The reverb tail survives
        // `.interrupts` (which only replaces a dry voice's buffer), giving a
        // natural release.
        engine.connect(stringMixer, to: reverb, format: format)
        // Reverb output must be stereo: the Mac reverb (MatrixReverb, used when
        // running Designed-for-iPad) has no mono output bus. Mono in is fine.
        let reverbOutput = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.connect(reverb, to: engine.mainMixerNode, format: reverbOutput)
    }

    /// Build plucked-string samples only when audio is first requested.
    private func buildNoteCache() {
        let frameCount = Int(sampleRate * noteDuration)
        for midi in 21...96 {
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
        if !engineConfigured {
            setupEngine()
            buildNoteCache()
            engineConfigured = true
        }
        do {
            try engine.start()
        } catch {
            print("NotePlaybackEngine: engine start failed: \(error)")
        }
    }

    func stop() {
        for node in stringNodes { node.stop() }
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Immediately silence any playing notes (used on seek/stop).
    func stopNotes() {
        guard engine.isRunning else { return }
        for node in stringNodes {
            node.stop()
            node.play()  // re-arm for next schedule
        }
    }

    // MARK: - Direct MIDI Playback

    /// Play a single MIDI note directly, bypassing fret-to-MIDI conversion.
    /// Used by the tab maker for instant audio feedback during note placement.
    func playMIDI(_ midi: Int) {
        guard engine.isRunning else { return }
        guard let buffer = noteCache[midi] else { return }

        let node = stringNodes[0]
        node.volume = Self.stringGain(volume)
        node.scheduleBuffer(buffer, at: nil, options: .interrupts,
                            completionHandler: nil)
        if !node.isPlaying {
            node.play()
        }
    }

    /// Per-voice gain: six freely ringing voices sum, so each is scaled to
    /// leave headroom (typical simultaneous ring is 2–3 strings).
    private static func stringGain(_ volume: Float) -> Float { volume * 0.6 }

    // MARK: - Note Playback

    /// Play a chord or single note from parsed fret data, one voice per
    /// string. A new note on a string interrupts only that string (like a
    /// fretting hand landing on it); everything else keeps ringing.
    /// Scheduling runs off the display-link/main thread.
    private nonisolated static let scheduleQueue = DispatchQueue(label: "NotePlaybackEngine.schedule",
                                                                 qos: .userInteractive)

    func playNotes(_ frets: [Int?], tuningMIDI: [Int]? = nil) {
        guard isEnabled, engine.isRunning else { return }

        guard let openStrings = tuningMIDI ?? (frets.count == 6 ? Self.standardTuningMIDI : nil) else { return }
        if stringNodes.count < frets.count {
            for _ in stringNodes.count..<frets.count {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: stringMixer, format: format)
                stringNodes.append(node)
            }
        }
        var toPlay: [(string: Int, midi: Int)] = []
        for (stringIndex, fret) in frets.enumerated() {
            guard let f = fret, stringIndex < openStrings.count,
                  stringIndex < stringNodes.count else { continue }
            toPlay.append((stringIndex, openStrings[stringIndex] + f))
        }

        guard !toPlay.isEmpty else { return }

        let gain = Self.stringGain(volume)
        let cache = noteCache
        let nodes = stringNodes
        Self.scheduleQueue.async {
            for (string, midi) in toPlay {
                guard let buffer = cache[midi] else { continue }
                let node = nodes[string]
                node.volume = gain
                node.scheduleBuffer(buffer, at: nil, options: .interrupts,
                                    completionHandler: nil)
                if !node.isPlaying {
                    node.play()
                }
            }
        }
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
