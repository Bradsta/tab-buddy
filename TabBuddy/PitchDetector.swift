//
//  PitchDetector.swift
//  TabBuddy
//
//  Microphone front-end for note detection. All DSP lives in
//  NoteTranscriberCore (onset-segmented pitch voting — see that file);
//  this class owns the audio session/tap and publishes results for SwiftUI.
//

import AVFoundation
import Combine

/// A single note detected from microphone input.
struct DetectedNote: Identifiable {
    let id = UUID()
    let midi: Int
    let noteName: String
    let frequency: Double
    let timestamp: Date
    let guitarString: Int?   // 0 = high E, 5 = low E (nil if ambiguous)
    let fret: Int?           // fret number on that string
    /// How the note was detected: "onset", "legato", or "recovered".
    let kind: String
}

@MainActor
final class PitchDetector: ObservableObject {

    // MARK: - Published state

    @Published var currentFrequency: Double = 0
    @Published var currentNote: String = "-"
    @Published var currentMIDI: Int = 0
    /// Cents offset from the nearest equal-tempered note (-50...+50).
    @Published var currentCents: Double = 0
    @Published var confidence: Double = 0
    @Published var isListening: Bool = false
    @Published var permissionDenied: Bool = false
    @Published var detectedNotes: [DetectedNote] = []

    // MARK: - Audio engine

    private let engine = AVAudioEngine()
    private var core: NoteTranscriberCore?

    // Standard tuning open-string MIDI notes (low E to high E)
    private static let openStringMIDI: [Int] = [40, 45, 50, 55, 59, 64]
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F",
                                     "F#", "G", "G#", "A", "A#", "B"]

    // MARK: - Lifecycle

    func startListening() {
        guard !isListening else { return }

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.permissionDenied = true
                    return
                }
                self?.permissionDenied = false
                self?.setupAndStart()
            }
        }
    }

    func stopListening() {
        guard isListening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isListening = false
    }

    func clearNotes() {
        detectedNotes.removeAll()
    }

    // MARK: - Setup

    private func setupAndStart() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            // Small IO buffers → mic chunks arrive often → snappier detection/tuner.
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
            return
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let core = NoteTranscriberCore(sampleRate: inputFormat.sampleRate)
        self.core = core

        // Buffers arrive on a background thread, serially per bus.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            self?.processBuffer(buffer, core: core)
        }

        do {
            try engine.start()
            isListening = true
        } catch {
            print("Engine start error: \(error)")
        }
    }

    // MARK: - Buffer processing (background thread)

    private nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer, core: NoteTranscriberCore) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let data = Array(UnsafeBufferPointer(start: channelData[0], count: frames))

        let events = core.process(data)
        let live = core.livePitch

        DispatchQueue.main.async { [weak self] in
            self?.publish(events: events, live: live)
        }
    }

    // MARK: - Publishing (main thread)

    private func publish(events: [NoteTranscriberCore.Event],
                         live: (frequency: Double, midi: Int, confidence: Double)?) {
        if let live {
            currentFrequency = live.frequency
            currentMIDI = live.midi
            currentNote = Self.midiToNoteName(live.midi)
            confidence = live.confidence
            let midiF = 69.0 + 12.0 * log2(live.frequency / 440.0)
            currentCents = (midiF - midiF.rounded()) * 100.0
        } else {
            currentFrequency = 0
            currentNote = "-"
            confidence = 0
            currentCents = 0
        }

        guard !events.isEmpty else { return }
        let now = Date()
        for e in events {
            let guitar = mapToGuitar(e.midi)
            detectedNotes.append(DetectedNote(
                midi: e.midi,
                noteName: Self.midiToNoteName(e.midi),
                frequency: e.frequency,
                timestamp: now,
                guitarString: guitar?.string,
                fret: guitar?.fret,
                kind: e.kind.rawValue
            ))
        }
    }

    // MARK: - Pitch utilities

    static func midiToNoteName(_ midi: Int) -> String {
        let name = noteNames[((midi % 12) + 12) % 12]
        let octave = (midi / 12) - 1
        return "\(name)\(octave)"
    }

    /// Map a MIDI note to the most natural guitar string + fret position.
    /// Prefers lower fret numbers; breaks ties by favoring middle strings.
    func mapToGuitar(_ midi: Int) -> (string: Int, fret: Int)? {
        // openStringMIDI is [40, 45, 50, 55, 59, 64] (low E to high E)
        // We store strings as 0=high E, 5=low E (matching NoteEvent convention)
        var best: (string: Int, fret: Int)? = nil
        var bestScore = Int.max

        for (physIdx, openMIDI) in Self.openStringMIDI.enumerated() {
            let fret = midi - openMIDI
            guard fret >= 0 && fret <= 24 else { continue }

            let stringIdx = 5 - physIdx
            let fretPenalty = fret * 10
            let stringPenalty = abs(physIdx - 3) * 2  // middle strings preferred
            let score = fretPenalty + stringPenalty

            if score < bestScore {
                bestScore = score
                best = (string: stringIdx, fret: fret)
            }
        }

        return best
    }
}
