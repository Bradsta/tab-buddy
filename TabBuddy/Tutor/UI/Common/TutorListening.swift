//
//  TutorListening.swift
//  TabBuddy
//
//  Seams between the lesson UI and audio so view models are testable without
//  a microphone or speaker: `TutorListening` (live input, implemented by
//  `TutorListener`) and `TutorSequencePlaying` (demo/reference playback,
//  implemented by `TutorSequencePlayer` over `TutorSynth`).
//
//  Rule for every caller: output is muted while listening, so stop listening
//  before playing anything and restart afterwards.
//

import Foundation
import UIKit

// MARK: - Listening seam

@MainActor
protocol TutorListening: AnyObject {
    var isListening: Bool { get }
    var permissionDenied: Bool { get }
    var inputLevel: Float { get }
    /// Current take time for visual cues and timed arming (host clock mapped
    /// onto the take clock). Detection times are latency-corrected into the
    /// same frame.
    var takeClock: TimeInterval { get }
    var onVerification: ((VerificationResult) -> Void)? { get set }
    var onDetected: ((DetectedEvent) -> Void)? { get set }
    var detectionSources: TutorListener.DetectionSources { get set }

    func start(profile: InstrumentProfile, recordTake: Bool) async throws
    @discardableResult func stop() -> URL?
    func arm(_ events: [ExpectedEvent], window: ExpectedNoteVerifier.Window)
    func armTimed(_ passage: ExpectedPassage, passageStart: TimeInterval, tempoScale: Double, tolerance: TimeInterval)
    func disarm()
}

extension TutorListener: TutorListening {}

extension TutorListening {
    /// Observes `.tutorListenerDidStopUnexpectedly` for this listener
    /// (interruption, route or audio configuration change). Test fakes post
    /// the same notification with themselves as the object.
    func observeUnexpectedStop(_ handler: @escaping @MainActor () -> Void) -> TutorObserverToken {
        TutorObserverToken(NotificationCenter.default.addObserver(
            forName: .tutorListenerDidStopUnexpectedly, object: self, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
    }

    /// True when the error (or the listener's state) means microphone access is off.
    func isPermissionError(_ error: Error) -> Bool {
        if permissionDenied { return true }
        if let audio = error as? TutorAudioError, case .permissionDenied = audio { return true }
        return false
    }
}

// MARK: - Playback seam

@MainActor
protocol TutorSequencePlaying: AnyObject {
    var isPlaying: Bool { get }
    /// Plays the sequence; `onStep` reports the index into `sequence.notes` as
    /// each event sounds, `completion` runs after the last note (or at once
    /// when playback could not start). Returns false when nothing will sound.
    @discardableResult
    func play(_ sequence: PlaybackSequence, instrument: TutorInstrument,
              onStep: ((Int) -> Void)?, completion: (() -> Void)?) -> Bool
    func stop()
}

/// `TutorSynth`-backed player that honours per-note durations (the synth's own
/// API uses one duration for every step).
@MainActor
final class TutorSequencePlayer: ObservableObject, TutorSequencePlaying {
    static let shared = TutorSequencePlayer()

    @Published private(set) var isPlaying = false
    private var task: Task<Void, Never>?
    private var synth: TutorSynth { TutorSynth.shared }

    @discardableResult
    func play(_ sequence: PlaybackSequence, instrument: TutorInstrument,
              onStep: ((Int) -> Void)? = nil, completion: (() -> Void)? = nil) -> Bool {
        stop()
        guard !TutorAudioSession.outputMuted, !sequence.soundedNotes.isEmpty else {
            completion?()
            return false
        }
        synth.instrument = instrument
        let spb = 60 / max(20, min(300, sequence.bpm))
        let notes = sequence.notes.enumerated().sorted { $0.element.startBeat < $1.element.startBeat }
        isPlaying = true
        task = Task { @MainActor [weak self] in
            let start = Date()
            var ok = true
            for (index, note) in notes {
                let due = note.startBeat * spb
                let wait = due - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                guard let self, !Task.isCancelled else { return }
                onStep?(index)
                guard !note.pitches.isEmpty else { continue }
                // The synth rolls guitar chords by itself; hold each event for its length.
                if !self.synth.play(chords: [note.pitches], style: .block, bpm: sequence.bpm,
                                    beatsPerChord: max(0.25, note.durationBeats)) {
                    ok = false
                    break
                }
            }
            if ok {
                let end = sequence.totalBeats * spb
                let wait = end - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
            guard let self, !Task.isCancelled else { return }
            self.isPlaying = false
            self.task = nil
            completion?()
        }
        return true
    }

    /// Plays pitches together (tap-to-hear on diagrams).
    func playPitches(_ pitches: [Int], instrument: TutorInstrument) {
        guard !pitches.isEmpty else { return }
        let seq = PlaybackSequence(notes: [PlaybackNote(pitches: pitches.sorted(), startBeat: 0, durationBeats: 2)],
                                   bpm: 90, style: .block)
        play(seq, instrument: instrument)
    }

    func stop() {
        task?.cancel()
        task = nil
        synth.stop()
        isPlaying = false
    }
}

/// Removes a block-based notification observer when released.
final class TutorObserverToken {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

// MARK: - Copy

enum TutorListeningCopy {
    /// Neutral status after an interruption, route change, or audio reset.
    static let stoppedUnexpectedly = "Listening stopped. Tap Start to listen again."
}

// MARK: - Helpers

enum TutorAudioHelpers {
    static func profile(for instrument: TutorInstrument) -> InstrumentProfile {
        InstrumentProfile.preset(for: instrument)
    }

    static var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }

    static func openSettings() {
        guard let url = settingsURL else { return }
        UIApplication.shared.open(url)
    }

    /// Readable name for a MIDI note ("F♯3").
    static func name(_ midi: Int, key: Key? = nil) -> String {
        NoteNaming.displayName(midi: midi, in: key)
    }

    /// Stable seed from a string (FNV-1a), for repeatable generated content.
    static func seed(_ text: String, salt: UInt64 = 0) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash ^ salt
    }
}
