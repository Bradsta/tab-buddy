//
//  TutorSynth.swift
//  TabBuddy
//
//  Demo playback for lessons and ear training: AVAudioUnitSampler with the
//  bundled SoundFont (GuitarProAssets/soundfont/sonivox.sf2; program 0 =
//  acoustic grand piano, 25 = steel-string guitar) plus a synthesized click.
//  Refuses to sound while `TutorAudioSession.outputMuted` is set and stops
//  when listening starts. The engine stops a few seconds after the last
//  sound so the audio session is not held open.
//

import AVFoundation
import AudioToolbox
import Combine

@MainActor
final class TutorSynth: ObservableObject {
    enum Style: String, Sendable {
        /// All pitches together (guitar: a quick 20 ms strum), held two beats.
        case block
        /// One pitch per eighth note, all ringing to the end.
        case arpeggio
        /// One pitch per beat, each released at the next (a melody).
        case sequence
    }

    static let shared = TutorSynth()

    @Published private(set) var isPlaying = false
    /// Last load error, if the SoundFont could not be loaded.
    @Published private(set) var loadError: String?

    var instrument: TutorInstrument {
        didSet { if oldValue != instrument { programLoaded = false } }
    }

    /// Bundled SoundFont (GuitarProAssets is a folder reference in the app bundle).
    static var soundFontURL: URL? {
        Bundle.main.url(forResource: "sonivox", withExtension: "sf2", subdirectory: "GuitarProAssets/soundfont")
            ?? Bundle.main.url(forResource: "GuitarProAssets", withExtension: nil)?
                .appendingPathComponent("soundfont/sonivox.sf2")
    }

    static func program(for instrument: TutorInstrument) -> UInt8 {
        instrument == .piano ? 0 : 25
    }

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let clickNode = AVAudioPlayerNode()
    private var configured = false
    private var programLoaded = false
    private var sounding: Set<UInt8> = []
    private var playTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    /// Seconds of silence before the engine stops.
    static let idleStopDelay: TimeInterval = 4

    init(instrument: TutorInstrument = .piano) {
        self.instrument = instrument
        observer = NotificationCenter.default.addObserver(
            forName: .tutorListeningWillStart, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                    self?.stopEngine()
                }
            }
    }

    // MARK: Playback

    /// Plays pitches (sounding MIDI). Returns false when output is muted or
    /// the synth could not start. `onStep` reports each onset's index.
    @discardableResult
    func play(pitches: [Int], style: Style = .block, bpm: Double = 90, velocity: UInt8 = 90,
              onStep: ((Int) -> Void)? = nil) -> Bool {
        guard !pitches.isEmpty else { return false }
        switch style {
        case .block:
            return play(chords: [pitches], style: .block, bpm: bpm, beatsPerChord: 2,
                        velocity: velocity, onStep: onStep)
        case .arpeggio, .sequence:
            return schedule(steps: pitches.map { [$0] }, style: style, bpm: bpm,
                            beatsPerStep: style == .arpeggio ? 0.5 : 1, velocity: velocity, onStep: onStep)
        }
    }

    /// Plays a sequence of chords, `beatsPerChord` each. `.arpeggio` spreads
    /// each chord across its duration; `.block`/`.sequence` sound it at once.
    @discardableResult
    func play(chords: [[Int]], style: Style = .block, bpm: Double = 90, beatsPerChord: Double = 1,
              velocity: UInt8 = 90, onStep: ((Int) -> Void)? = nil) -> Bool {
        if style == .arpeggio {
            // Flatten into eighth-note arpeggios per chord.
            var steps: [[Int]] = []
            var owners: [Int] = []
            for (ci, chord) in chords.enumerated() {
                let per = max(1, Int((beatsPerChord * 2).rounded()))
                for k in 0..<per {
                    steps.append([chord.sorted()[k % max(1, chord.count)]])
                    owners.append(ci)
                }
            }
            return schedule(steps: steps, style: .arpeggio, bpm: bpm, beatsPerStep: 0.5, velocity: velocity,
                            onStep: { i in if i == 0 || owners[i] != owners[i - 1] { onStep?(owners[i]) } })
        }
        return schedule(steps: chords, style: .block, bpm: bpm, beatsPerStep: beatsPerChord,
                        velocity: velocity, onStep: onStep)
    }

    /// A single metronome click (accent for downbeats).
    @discardableResult
    func playClick(accent: Bool = false) -> Bool {
        guard prepare() else { return false }
        let format = clickNode.outputFormat(forBus: 0)
        guard let buf = TutorClickSound.buffer(format: format, accent: accent) else { return false }
        clickNode.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !clickNode.isPlaying { clickNode.play() }
        scheduleIdleStop()
        return true
    }

    /// Stops all sound immediately.
    func stop() {
        playTask?.cancel()
        playTask = nil
        allNotesOff()
        if configured { clickNode.stop() }
        isPlaying = false
        scheduleIdleStop()
    }

    /// Stops the engine once nothing has sounded for `idleStopDelay`.
    private func scheduleIdleStop() {
        idleTask?.cancel()
        guard engine.isRunning else { return }
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleStopDelay * 1e9))
            guard let self, !Task.isCancelled, !self.isPlaying else { return }
            self.stopEngine()
        }
    }

    private func stopEngine() {
        idleTask?.cancel()
        idleTask = nil
        guard engine.isRunning else { return }
        allNotesOff()
        if configured { clickNode.stop() }
        engine.stop()
    }

    // MARK: Internals

    private func schedule(steps: [[Int]], style: Style, bpm: Double, beatsPerStep: Double,
                          velocity: UInt8, onStep: ((Int) -> Void)?) -> Bool {
        guard prepare() else { return false }
        stop()
        let spb = 60 / max(20, min(300, bpm))
        let stepSeconds = spb * beatsPerStep
        let strum = instrument == .guitar ? 0.02 : 0.0
        isPlaying = true
        playTask = Task { @MainActor [weak self] in
            for (i, step) in steps.enumerated() {
                guard let self, !Task.isCancelled, !TutorAudioSession.outputMuted else { break }
                if style == .sequence { self.allNotesOff() }
                if style == .block, i > 0 { self.allNotesOff() }
                onStep?(i)
                for (k, p) in step.sorted().enumerated() {
                    if k > 0 && strum > 0 { try? await Task.sleep(nanoseconds: UInt64(strum * 1e9)) }
                    // stop() may have silenced the chord mid-strum; don't restart its strings.
                    guard !Task.isCancelled else { break }
                    self.noteOn(p, velocity: velocity)
                }
                try? await Task.sleep(nanoseconds: UInt64(max(0, stepSeconds - strum * Double(step.count - 1)) * 1e9))
            }
            // Let the last step ring one beat.
            if !Task.isCancelled { try? await Task.sleep(nanoseconds: UInt64(spb * 1e9)) }
            guard let self, !Task.isCancelled else { return }
            self.allNotesOff()
            self.isPlaying = false
            self.scheduleIdleStop()
        }
        return true
    }

    private func noteOn(_ midi: Int, velocity: UInt8) {
        guard (0...127).contains(midi), !TutorAudioSession.outputMuted else { return }
        let n = UInt8(midi)
        sampler.startNote(n, withVelocity: velocity, onChannel: 0)
        sounding.insert(n)
    }

    private func allNotesOff() {
        for n in sounding { sampler.stopNote(n, onChannel: 0) }
        sounding.removeAll()
    }

    /// Configures the engine, loads the program, and starts output. False while muted.
    private func prepare() -> Bool {
        guard !TutorAudioSession.outputMuted else { return false }
        idleTask?.cancel()
        idleTask = nil
        if !configured {
            engine.attach(sampler)
            engine.attach(clickNode)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48000, channels: 1)!
            engine.connect(clickNode, to: engine.mainMixerNode, format: fmt)
            configured = true
        }
        if !programLoaded {
            guard let url = Self.soundFontURL else {
                loadError = "The bundled SoundFont is missing."
                return false
            }
            do {
                try sampler.loadSoundBankInstrument(at: url, program: Self.program(for: instrument),
                                                    bankMSB: 0x79,   // kAUSampleBankMSB_Melodic
                                                    bankLSB: 0)
                programLoaded = true
                loadError = nil
            } catch {
                loadError = error.localizedDescription
                return false
            }
        }
        if !engine.isRunning {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                try? session.setCategory(.playAndRecord, mode: .default,
                                         options: [.defaultToSpeaker, .allowBluetoothA2DP])
            }
            try? session.setActive(true)
            do { try engine.start() } catch {
                loadError = error.localizedDescription
                return false
            }
        }
        return true
    }
}
