//
//  InstrumentVoicing.swift
//  TabBuddy
//
//  Register and voicing choices shared by the exercise, playback, and quiz
//  generators: playable ranges, chord voicings (open/barre shapes on guitar,
//  close position on piano), scale start octaves, and guitar fingering hints.
//

import Foundation

/// Instrument geometry used to turn curriculum specs into concrete pitches.
struct InstrumentContext: Hashable, Sendable {
    var instrument: TutorInstrument
    var fretboard: FretboardLayout
    var keyboard: KeyboardLayout

    init(instrument: TutorInstrument,
         fretboard: FretboardLayout = .standardGuitar,
         keyboard: KeyboardLayout = .piano88) {
        self.instrument = instrument
        self.fretboard = fretboard
        self.keyboard = keyboard
    }

    static let guitar = InstrumentContext(instrument: .guitar)
    static let piano = InstrumentContext(instrument: .piano)

    static func standard(_ instrument: TutorInstrument) -> InstrumentContext {
        instrument == .guitar ? .guitar : .piano
    }

    /// Lowest and highest sounding MIDI notes.
    var playableRange: ClosedRange<Int> {
        switch instrument {
        case .guitar:
            let lo = (fretboard.tuningMIDI.min() ?? 40) + fretboard.capo
            let hi = (fretboard.tuningMIDI.max() ?? 64) + fretboard.capo + fretboard.maxFret
            return lo...hi
        case .piano:
            return keyboard.range
        }
    }

    /// Range a beginner reaches easily: guitar frets 0–12, piano C2–C7.
    var comfortableRange: ClosedRange<Int> {
        switch instrument {
        case .guitar:
            let lo = (fretboard.tuningMIDI.min() ?? 40) + fretboard.capo
            let hi = (fretboard.tuningMIDI.max() ?? 64) + fretboard.capo + min(12, fretboard.maxFret)
            return lo...hi
        case .piano:
            return max(36, keyboard.lowestMIDI)...min(96, keyboard.highestMIDI)
        }
    }

    // MARK: Chords

    /// Sounding chord pitches (low to high) plus guitar fret positions when known.
    struct Voicing: Hashable, Sendable {
        var midi: [Int]
        var fretting: [FretPosition]?
        var fingering: ChordFingering?
    }

    /// Piano hand register for chord voicings.
    enum Hand: String, Hashable, Sendable { case right, left }

    /// Guitar: open shape, else the lower E-/A-form barre, else close position
    /// from the lowest playable root. Piano: close position around C4 (right
    /// hand) or C3 (left hand); slash chords become inversions with the bass lowest.
    func voicing(for chord: Chord, hand: Hand = .right) -> Voicing {
        switch instrument {
        case .guitar:
            if let open = ChordFingering.open(for: chord) {
                return Voicing(midi: fretboard.midi(for: open), fretting: open.positions, fingering: open)
            }
            let barres = ChordFingering.BarreForm.allCases.compactMap { ChordFingering.barre(chord, form: $0) }
            if let best = barres.min(by: { ($0.barre?.fret ?? 99) < ($1.barre?.fret ?? 99) }) {
                return Voicing(midi: fretboard.midi(for: best), fretting: best.positions, fingering: best)
            }
            let midi = closePosition(chord, rootIn: playableRange.lowerBound...(playableRange.lowerBound + 11))
            let fretting = GuitarFingerer(layout: fretboard).chordPositions(midi)
            return Voicing(midi: midi, fretting: fretting, fingering: nil)
        case .piano:
            let window = hand == .right ? 55...66 : 43...54
            if let bass = chord.bass {
                return Voicing(midi: inversion(chord, bass: bass, bassIn: window), fretting: nil, fingering: nil)
            }
            return Voicing(midi: closePosition(chord, rootIn: window), fretting: nil, fingering: nil)
        }
    }

    /// Bass note inside `bassIn`, remaining chord tones stacked closely above it.
    func inversion(_ chord: Chord, bass: SpelledNote, bassIn window: ClosedRange<Int>) -> [Int] {
        let bassMIDI = Pitch(bass, octave: Self.octave(placing: bass, in: window)).midi
        var midi = [bassMIDI]
        for tone in chord.tones where tone.pitchClass != bass.pitchClass {
            midi.append(bassMIDI + PitchClass(bassMIDI).semitones(upTo: tone.pitchClass))
        }
        return Array(Set(midi)).sorted()
    }

    /// Close-position MIDI with the root inside `rootIn`, raised an octave if a slash bass falls out of range.
    func closePosition(_ chord: Chord, rootIn window: ClosedRange<Int>) -> [Int] {
        var octave = Self.octave(placing: chord.root, in: window)
        var midi = chord.midiNotes(rootOctave: octave)
        while let low = midi.min(), low < playableRange.lowerBound, octave < 8 {
            octave += 1
            midi = chord.midiNotes(rootOctave: octave)
        }
        return midi.sorted()
    }

    /// Octave number that puts `note` inside `window` (or as close as possible above its start).
    static func octave(placing note: SpelledNote, in window: ClosedRange<Int>) -> Int {
        for octave in -1...9 {
            let midi = Pitch(note, octave: octave).midi
            if window.contains(midi) { return octave }
            if midi > window.upperBound { return octave }
        }
        return 4
    }

    // MARK: Scales

    /// Scale start pitch. Guitar: the lowest playable root that fits all
    /// octaves. Piano: root in C4–B4 for one octave, one octave lower for two or more.
    func scaleStart(_ scale: Scale, octaves: Int) -> Pitch {
        let span = 12 * max(1, octaves)
        switch instrument {
        case .guitar:
            let range = playableRange
            var octave = Self.octave(placing: scale.root, in: range.lowerBound...(range.lowerBound + 11))
            if Pitch(scale.root, octave: octave).midi + span > range.upperBound { octave -= 1 }
            return Pitch(scale.root, octave: octave)
        case .piano:
            let window = octaves >= 2 ? 48...59 : 60...71
            return Pitch(scale.root, octave: Self.octave(placing: scale.root, in: window))
        }
    }

    /// Scale pitches, up then down when `upAndDown`.
    func scalePitches(_ scale: Scale, octaves: Int, upAndDown: Bool) -> [Pitch] {
        scale.pitches(from: scaleStart(scale, octaves: octaves), octaves: max(1, octaves), upAndDown: upAndDown)
    }

    // MARK: Fingering hints

    /// One fret position per single-note event (nil for chords, rests, piano).
    func fretting(forLine midiLine: [[Int]]) -> [[FretPosition]?] {
        guard instrument == .guitar else { return midiLine.map { _ in nil } }
        let singles = midiLine.map { $0.count == 1 ? $0[0] : nil }
        let positions = GuitarFingerer(layout: fretboard).linePositions(singles.compactMap { $0 })
        var iterator = positions.makeIterator()
        return singles.map { single in
            guard single != nil, let p = iterator.next() else { return nil }
            return p.map { [$0] }
        }
    }
}

/// Picks fret positions for single-note lines inside a moving four-fret window.
struct GuitarFingerer {
    var layout: FretboardLayout

    private static func window(around fret: Int) -> ClosedRange<Int> {
        fret <= 4 ? 0...4 : (fret - 1)...(fret + 3)
    }

    /// Positions for a melody or scale: stays in position (first position when
    /// the line starts low), preferring the lowest fret inside the window.
    func linePositions(_ midis: [Int]) -> [FretPosition?] {
        var window: ClosedRange<Int>?
        var result: [FretPosition?] = []
        for midi in midis {
            let candidates = layout.positions(ofMIDI: midi)
            guard !candidates.isEmpty else { result.append(nil); continue }
            let current = window ?? Self.window(around: candidates.map(\.fret).min() ?? 0)
            let inside = candidates.filter { current.contains($0.fret) }
            let pick: FretPosition
            if let best = inside.min(by: { ($0.fret, -$0.string) < ($1.fret, -$1.string) }) {
                pick = best
                window = current
            } else {
                func distance(_ p: FretPosition) -> Int {
                    p.fret < current.lowerBound ? current.lowerBound - p.fret : p.fret - current.upperBound
                }
                pick = candidates.min { distance($0) < distance($1) }!
                window = Self.window(around: pick.fret)
            }
            result.append(pick)
        }
        return result
    }

    /// Positions for chord tones on separate strings (fallback voicings).
    func chordPositions(_ midis: [Int]) -> [FretPosition]? {
        var used = Set<Int>()
        var result: [FretPosition] = []
        for midi in midis.sorted() {
            let options = layout.positions(ofMIDI: midi, fretRange: 0...12)
                .filter { !used.contains($0.string) }
                .sorted { ($0.string, $0.fret) > ($1.string, $1.fret) }
            guard let pick = options.first else { return nil }
            used.insert(pick.string)
            result.append(pick)
        }
        return result
    }
}

// MARK: - Seedable randomness

/// Deterministic generator (SplitMix64) so quizzes and interval rounds can be reproduced.
struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
