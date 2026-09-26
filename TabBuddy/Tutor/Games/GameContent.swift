//
//  GameContent.swift
//  TabBuddy
//
//  Generated material for the games, built on the theory core: hunt targets,
//  ear-training rounds, rhythm patterns, scale runs, chord pairs, and
//  sight-reading notes. Everything is seeded so tests can check validity.
//

import Foundation

enum GameContent {

    // MARK: - Hunt (fretboard / keyboard)

    /// Guitar: standard tuning, frets 0–12. Piano: C2–C7, the register the
    /// microphone hears reliably.
    static func huntRange(_ instrument: TutorInstrument) -> ClosedRange<Int> {
        switch instrument {
        case .guitar:
            let layout = FretboardLayout.standardGuitar
            return (layout.tuningMIDI.min() ?? 40)...((layout.tuningMIDI.max() ?? 64) + 12)
        case .piano:
            return 36...96
        }
    }

    /// Every pitch of the class inside the hunt range, ascending.
    static func huntTargets(_ pc: PitchClass, instrument: TutorInstrument) -> [Int] {
        huntRange(instrument).filter { PitchClass($0) == pc }
    }

    /// Level 1: natural notes. Level 2: all twelve.
    static func huntPitchClasses(level: Int) -> [PitchClass] {
        level <= 1 ? NoteLetter.allCases.map { PitchClass($0.naturalPitchClass) } : PitchClass.all
    }

    /// Fret positions (frets 0–12) of a guitar pitch.
    static func guitarPositions(_ midi: Int) -> [FretPosition] {
        FretboardLayout.standardGuitar.positions(ofMIDI: midi, fretRange: 0...12)
    }

    static func pitchClassName(_ pc: PitchClass) -> String {
        pc.isBlackKey ? NoteNaming.bothSpellings(pc) : pc.spelled().displayName
    }

    // MARK: - Ear rounds

    struct EarRound: Hashable {
        var sequence: PlaybackSequence
        var choices: [String]
        var correctIndex: Int
        /// Shown after answering.
        var explanation: String
        /// Interval Duel: the given root and the note to play back.
        var root: Int?
        var target: Int?
        var correctAnswer: String { choices[correctIndex] }
    }

    static func intervalPool(level: Int) -> [Interval] {
        switch level {
        case ...1: return [.M3, .P5, .P8]
        case 2: return [.m3, .M3, .P4, .P5, .P8]
        default: return [.m2, .M2, .m3, .M3, .P4, .A4, .P5, .m6, .M6, .m7, .M7, .P8]
        }
    }

    static func intervalLevelDetail(_ level: Int) -> String {
        switch level {
        case ...1: return "Major third, fifth, octave"
        case 2: return "Adds minor third and fourth"
        default: return "All intervals to the octave, some played together"
        }
    }

    /// Answer range for playing back: guitar C3–C5, piano C4–G5.
    static func intervalRange(_ instrument: TutorInstrument) -> ClosedRange<Int> {
        instrument == .guitar ? 48...72 : 60...79
    }

    static func intervalRounds(level: Int, instrument: TutorInstrument, count: Int = 10, seed: UInt64) -> [EarRound] {
        var rng = SeededRandom(seed: seed)
        let pool = intervalPool(level: level)
        let range = intervalRange(instrument)
        var rounds: [EarRound] = []
        var last: Interval?
        for _ in 0..<count {
            var interval = pool.randomElement(using: &rng)!
            if interval == last, pool.count > 1 { interval = pool.filter { $0 != last }.randomElement(using: &rng)! }
            last = interval
            let top = range.upperBound - interval.semitones
            let root = Int.random(in: range.lowerBound...max(range.lowerBound, top), using: &rng)
            let upper = root + interval.semitones
            let harmonic = level >= 3 && Int.random(in: 0..<3, using: &rng) == 0
            let notes: [PlaybackNote] = harmonic
                ? [PlaybackNote(pitches: [root, upper], startBeat: 0, durationBeats: 2),
                   PlaybackNote(pitches: [root], startBeat: 2.5, durationBeats: 1),
                   PlaybackNote(pitches: [upper], startBeat: 3.5, durationBeats: 1.5)]
                : [PlaybackNote(pitches: [root], startBeat: 0, durationBeats: 1),
                   PlaybackNote(pitches: [upper], startBeat: 1, durationBeats: 1.5)]
            // Correct answer plus the closest other sizes from the level pool (four at most).
            let others = pool.filter { $0 != interval }
                .sorted { abs($0.semitones - interval.semitones) < abs($1.semitones - interval.semitones) }
            var options = [interval] + others.prefix(3)
            options.sort { $0.semitones < $1.semitones }
            let rootName = TutorAudioHelpers.name(root)
            let upperName = TutorAudioHelpers.name(upper)
            let explanation = "\(rootName) up to \(upperName) is a \(interval.name): \(interval.semitones) half step\(interval.semitones == 1 ? "" : "s")."
            rounds.append(EarRound(sequence: PlaybackSequence(notes: notes, bpm: 72, style: .sequence),
                                   choices: options.map(QuizGenerator.intervalLabel),
                                   correctIndex: options.firstIndex(of: interval)!,
                                   explanation: explanation, root: root, target: upper))
        }
        return rounds
    }

    static func qualityPool(level: Int) -> [ChordQuality] {
        switch level {
        case ...1: return [.major, .minor]
        case 2: return [.major, .minor, .diminished, .augmented]
        default: return [.major, .minor, .diminished, .augmented, .dominantSeventh]
        }
    }

    static func qualityLevelDetail(_ level: Int) -> String {
        switch level {
        case ...1: return "Major or minor"
        case 2: return "Adds diminished and augmented"
        default: return "Adds dominant seventh"
        }
    }

    static let qualityRoots: [SpelledNote] = ["C", "D", "E", "F", "G", "A", "Bb"].compactMap { SpelledNote($0) }

    static func qualityRounds(level: Int, instrument: TutorInstrument, count: Int = 10, seed: UInt64) -> [EarRound] {
        var rng = SeededRandom(seed: seed)
        let pool = qualityPool(level: level)
        let context = InstrumentContext.standard(instrument)
        var rounds: [EarRound] = []
        var last: ChordQuality?
        for _ in 0..<count {
            var quality = pool.randomElement(using: &rng)!
            if quality == last, pool.count > 2 { quality = pool.filter { $0 != last }.randomElement(using: &rng)! }
            last = quality
            let chord = Chord(root: qualityRoots.randomElement(using: &rng)!, quality: quality)
            let midi = context.voicing(for: chord).midi
            // Block chord, then the notes low to high.
            var notes = [PlaybackNote(pitches: midi, startBeat: 0, durationBeats: 2)]
            for (i, m) in midi.enumerated() {
                notes.append(PlaybackNote(pitches: [m], startBeat: 2.5 + Double(i) * 0.6, durationBeats: 0.6))
            }
            let spelled = chord.tones.map(\.displayName).joined(separator: " ")
            let explanation = "That was \(chord.displaySymbol) (\(spelled)): \(qualityFormula(quality))."
            rounds.append(EarRound(sequence: PlaybackSequence(notes: notes, bpm: 72, style: .sequence),
                                   choices: pool.map(QuizGenerator.qualityLabel),
                                   correctIndex: pool.firstIndex(of: quality)!,
                                   explanation: explanation))
        }
        return rounds
    }

    static func qualityFormula(_ q: ChordQuality) -> String {
        switch q {
        case .major: return "a major third, then a minor third. Bright and settled"
        case .minor: return "a minor third, then a major third. Darker"
        case .diminished: return "two minor thirds. Tense, wants to move"
        case .augmented: return "two major thirds. Unresolved, dreamy"
        case .dominantSeventh: return "a major triad plus a minor seventh. Bluesy, pulls home"
        default: return q.intervals.dropFirst().map(\.name).joined(separator: ", ")
        }
    }

    // MARK: - Rhythm

    /// One 4/4 measure per pattern. Level 1: quarters and halves. Level 2:
    /// eighths. Level 3: dotted notes and rests. Level 4: syncopation.
    static let rhythmPatterns: [[String]] = [
        ["q q q q", "h q q", "q q h", "h h", "q qr q q", "q h q"],
        ["e e q q q", "q e e q q", "q q e e e e", "e e e e q q", "q e e h", "e e q e e q"],
        ["q. e q q", "q. e h", "q qr e e q", "q. e q. e", "e e qr q. e", "h qr e e"],
        ["e q e q q", "q e q e q", "e q q q e", "er e er e er e er e", "q. q. q", "e q e er e q"],
    ]

    static func rhythmLevelDetail(_ level: Int) -> String {
        switch level {
        case ...1: return "Quarter and half notes"
        case 2: return "Eighth notes"
        case 3: return "Dotted notes and rests"
        default: return "Off-beats and syncopation"
        }
    }

    static func rhythmBPM(level: Int) -> Double { [70, 72, 72, 76][max(0, min(3, level - 1))] }

    /// `count` different patterns from the level (repeats only when the level has fewer).
    static func rhythmRounds(level: Int, count: Int = 4, seed: UInt64) -> [RhythmPattern] {
        var rng = SeededRandom(seed: seed)
        let pool = rhythmPatterns[max(0, min(rhythmPatterns.count - 1, level - 1))].compactMap { RhythmPattern($0) }
        var picked: [RhythmPattern] = []
        var bag = pool.shuffled(using: &rng)
        while picked.count < count {
            if bag.isEmpty { bag = pool.shuffled(using: &rng) }
            picked.append(bag.removeFirst())
        }
        return picked
    }

    // MARK: - Scales

    struct ScaleOption: Hashable {
        var scale: Scale
        var octaves: Int
        var detail: String
    }

    static func scaleOptions(_ instrument: TutorInstrument) -> [ScaleOption] {
        let make: (String, Int, String) -> ScaleOption? = { name, octaves, detail in
            Scale(name).map { ScaleOption(scale: $0, octaves: octaves, detail: detail) }
        }
        switch instrument {
        case .guitar:
            return [make("C major", 1, "C major, one octave"),
                    make("G major", 1, "G major, one octave"),
                    make("A minor pentatonic", 1, "A minor pentatonic, one octave"),
                    make("E minor pentatonic", 2, "E minor pentatonic, two octaves")].compactMap { $0 }
        case .piano:
            return [make("C major", 1, "C major, right hand"),
                    make("G major", 1, "G major, right hand"),
                    make("F major", 1, "F major, right hand"),
                    make("A natural minor", 1, "A natural minor, right hand")].compactMap { $0 }
        }
    }

    /// Up and down, sounding MIDI.
    static func scaleRun(_ option: ScaleOption, instrument: TutorInstrument) -> [Int] {
        InstrumentContext.standard(instrument)
            .scalePitches(option.scale, octaves: option.octaves, upAndDown: true).map(\.midi)
    }

    static let scaleStartBPM: Double = 60
    static let scaleStepBPM: Double = 6
    static let scaleMaxBPM: Double = 160

    /// Quarter-note passage for a run; ids start at `idBase`.
    static func scalePassage(_ midi: [Int], bpm: Double, instrument: TutorInstrument, idBase: Int = 0) -> ExpectedPassage {
        let hints = InstrumentContext.standard(instrument).fretting(forLine: midi.map { [$0] })
        let events = midi.enumerated().map { i, m in
            ExpectedEvent(id: idBase + i, pitches: [m], beat: Double(i), durationBeats: 1,
                          measureIndex: i / 4, positionInMeasure: Double(i % 4) / 4,
                          fretting: hints.indices.contains(i) ? hints[i] : nil)
        }
        return ExpectedPassage(events: events, beatsPerMeasure: 4, bpm: bpm, instrument: instrument)
    }

    // MARK: - Chord pairs

    static func chordOptions(_ instrument: TutorInstrument) -> [String] {
        instrument == .guitar ? ["E", "A", "D", "G", "C", "Am", "Em", "Dm"] : ["C", "G", "F", "Am", "Dm", "Em", "D", "A"]
    }

    static func defaultChordPair(_ instrument: TutorInstrument) -> [String] {
        instrument == .guitar ? ["E", "A"] : ["C", "G"]
    }

    /// Expected event for one chord: open or barre fingering on guitar, close
    /// position on piano (graded by pitch class, any voicing).
    static func chordEvent(_ symbol: String, id: Int, instrument: TutorInstrument) -> ExpectedEvent? {
        guard let chord = Chord(symbol) else { return nil }
        let voicing = InstrumentContext.standard(instrument).voicing(for: chord)
        return ExpectedEvent(id: id, pitches: voicing.midi, beat: 0, durationBeats: 1, measureIndex: 0,
                             positionInMeasure: 0, chordName: chord.symbol, fretting: voicing.fretting,
                             octaveTolerant: instrument == .piano)
    }

    /// Beginner benchmark, changes per minute.
    static func chordBenchmark(_ instrument: TutorInstrument) -> (start: Int, goal: Int) {
        instrument == .guitar ? (8, 30) : (10, 40)
    }

    // MARK: - Note Rush

    struct RushNote: Hashable {
        /// Pitch as written on the staff (guitar: an octave above sounding).
        var written: Pitch
        var sounding: Int
        var choices: [String]
        var correctIndex: Int
    }

    static func rushLevelDetail(_ level: Int, instrument: TutorInstrument) -> String {
        switch (level, instrument) {
        case (...1, .guitar): return "Notes on the staff, any octave counts"
        case (...1, .piano): return "Middle C position, any octave counts"
        case (2, _): return "Ledger lines, exact octave"
        default: return "Sharps and flats, exact octave"
        }
    }

    /// Written pitches for a level. Guitar reads treble clef (sounds an
    /// octave lower); piano reads the grand staff.
    static func rushPool(level: Int, instrument: TutorInstrument) -> [Pitch] {
        let naturalsBetween: (String, String) -> [Pitch] = { lo, hi in
            guard let a = Pitch(lo), let b = Pitch(hi) else { return [] }
            return (a.midi...b.midi).filter { !PitchClass($0).isBlackKey }.map { Pitch(midi: $0) }
        }
        switch (level, instrument) {
        case (...1, .guitar): return naturalsBetween("E4", "F5")
        case (2, .guitar): return naturalsBetween("E3", "A5")
        case (_, .guitar): return withAccidentals(naturalsBetween("E3", "A5"))
        case (...1, .piano): return naturalsBetween("C3", "G3") + naturalsBetween("C4", "G4")
        case (2, .piano): return naturalsBetween("G2", "G5")
        default: return withAccidentals(naturalsBetween("G2", "G5"))
        }
    }

    /// Naturals plus sharp and flat spellings of the black keys inside the range.
    private static func withAccidentals(_ naturals: [Pitch]) -> [Pitch] {
        guard let lo = naturals.first?.midi, let hi = naturals.last?.midi else { return naturals }
        var result = naturals
        for m in lo...hi where PitchClass(m).isBlackKey {
            result.append(Pitch(midi: m, preferSharps: true))
            result.append(Pitch(midi: m, preferSharps: false))
        }
        return result
    }

    static func soundingMIDI(written: Pitch, instrument: TutorInstrument) -> Int {
        instrument == .guitar ? written.midi - 12 : written.midi
    }

    static func rushNote(level: Int, instrument: TutorInstrument, avoiding previous: Pitch?,
                         using rng: inout SeededRandom) -> RushNote {
        let pool = rushPool(level: level, instrument: instrument)
        var pick = pool.randomElement(using: &rng)!
        if pick == previous, pool.count > 1 { pick = pool.filter { $0 != previous }.randomElement(using: &rng)! }
        let correct = pick.note.displayName
        var distractors: [String] = []
        for step in [1, -1, 2, -2, 3, -3] {
            let note = SpelledNote(pick.letter.advanced(by: step), pick.note.accidental)
            // Skip spellings a beginner never meets (E♯, B♯, C♭, F♭).
            let rare = (note.accidental > 0 && [.E, .B].contains(note.letter))
                || (note.accidental < 0 && [.C, .F].contains(note.letter))
            let name = note.displayName
            if !rare, name != correct, !distractors.contains(name) { distractors.append(name) }
        }
        if pick.note.accidental != 0 {
            distractors.insert(SpelledNote(pick.letter).displayName, at: 0)
        }
        var choices = [correct] + distractors.prefix(3)
        choices.shuffle(using: &rng)
        return RushNote(written: pick, sounding: soundingMIDI(written: pick, instrument: instrument),
                        choices: choices, correctIndex: choices.firstIndex(of: correct)!)
    }
}
