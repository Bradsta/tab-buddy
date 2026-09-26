//
//  QuizGenerator.swift
//  TabBuddy
//
//  Generated multiple-choice questions for every `QuizGeneratorKind`. Each
//  question has exactly one correct choice, distractors chosen to be
//  plausible (neighbouring notes, related qualities, nearby keys), an
//  explanation, and playback or a diagram where the kind needs one.
//
//  Supported `params` (all values are strings; lists are comma-separated):
//
//  | kind              | keys                                                                 |
//  |-------------------|----------------------------------------------------------------------|
//  | noteOnFretboard   | strings ("6", "5,6"; 1 = high E; default all), fretMin (0), fretMax (12), accidentals |
//  | noteOnKeyboard    | range ("C4-B4", default), accidentals                                |
//  | noteOnStaff       | clef (treble | bass | grand), range (written pitch), accidentals (default none), guitarOctave ("true": written an octave above sounding) |
//  | intervalByEar     | intervals ("m3,M3,P5"; default m3,M3,P4,P5,P8), range ("C3-C6"), direction (up | down | harmonic | mixed) |
//  | intervalByName    | intervals, range                                                     |
//  | chordQualityByEar | qualities ("maj,min,dim", "maj7,7,m7,m7b5"; default maj,min), roots ("C,D,E") |
//  | chordSpelling     | qualities, roots                                                     |
//  | keySignature      | keys ("C,G,D", "Am,Em"), mode (major | minor | "major,minor")        |
//  | romanNumeral      | keys, mode, numerals ("I,IV,V,vi"; default the seven diatonic triads) |
//  | scaleDegreeByEar  | keys ("C major,G major"), degrees ("1,2,3,5")                       |
//  | scaleSpelling     | scales ("A minor pentatonic,E blues") or keys + type ("major", "harmonic minor") |
//  | rhythmCount       | values or tokens ("w,h.,q,e,qr"), rests ("true" adds rest forms), timeSignature ("4/4,3/4") |
//
//  accidentals: none (naturals only) | both | sharpsAndFlats (default for keyboard and fretboard) | sharps | flats.
//

import Foundation

struct QuizGenerationError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    var message: String
    var description: String { message }
    var errorDescription: String? { message }
}

enum QuizGenerator {
    /// Recognized params per kind (unknown keys are reported by the validator).
    static let knownParams: [QuizGeneratorKind: Set<String>] = [
        .noteOnFretboard: ["strings", "fretMin", "fretMax", "accidentals"],
        .noteOnKeyboard: ["range", "accidentals"],
        .noteOnStaff: ["clef", "range", "accidentals", "guitarOctave"],
        .intervalByEar: ["intervals", "range", "direction"],
        .intervalByName: ["intervals", "range"],
        .chordQualityByEar: ["qualities", "roots"],
        .chordSpelling: ["qualities", "roots"],
        .keySignature: ["keys", "mode"],
        .romanNumeral: ["keys", "mode", "numerals"],
        .scaleDegreeByEar: ["keys", "degrees"],
        .scaleSpelling: ["scales", "keys", "type"],
        .rhythmCount: ["values", "tokens", "rests", "timeSignature"],
    ]

    /// Fixed questions first, then `count` generated ones.
    static func questions(for step: QuizStep, instrument: TutorInstrument, seed: UInt64) throws -> [QuizQuestion] {
        var result = step.questions ?? []
        if let generator = step.generator {
            var rng = SeededRandom(seed: seed)
            result += try questions(for: generator, count: step.count, context: .standard(instrument), using: &rng)
        }
        return result
    }

    static func questions(for spec: QuizGeneratorSpec, count: Int, instrument: TutorInstrument,
                          seed: UInt64) throws -> [QuizQuestion] {
        var rng = SeededRandom(seed: seed)
        return try questions(for: spec, count: count, context: .standard(instrument), using: &rng)
    }

    /// Generates `count` questions, avoiding repeats while the pool allows.
    static func questions<R: RandomNumberGenerator>(for spec: QuizGeneratorSpec, count: Int,
                                                    context: InstrumentContext,
                                                    using rng: inout R) throws -> [QuizQuestion] {
        var result: [QuizQuestion] = []
        var seen = Set<String>()
        var attempts = 0
        while result.count < count {
            let q = try question(for: spec, context: context, using: &rng)
            attempts += 1
            let key = q.prompt + "|" + q.choices[q.answerIndex] + "|" + (q.playback.map { "\($0)" } ?? "") + "|" + (q.diagram.map { "\($0)" } ?? "")
            if seen.insert(key).inserted || attempts > count * 12 {
                result.append(q)
            }
        }
        return result
    }

    static func question<R: RandomNumberGenerator>(for spec: QuizGeneratorSpec, context: InstrumentContext,
                                                   using rng: inout R) throws -> QuizQuestion {
        let p = Params(spec.params)
        switch spec.kind {
        case .noteOnFretboard: return try noteOnFretboard(p, context, &rng)
        case .noteOnKeyboard: return try noteOnKeyboard(p, context, &rng)
        case .noteOnStaff: return try noteOnStaff(p, context, &rng)
        case .intervalByEar: return try intervalByEar(p, context, &rng)
        case .intervalByName: return try intervalByName(p, context, &rng)
        case .chordQualityByEar: return try chordQualityByEar(p, context, &rng)
        case .chordSpelling: return try chordSpelling(p, context, &rng)
        case .keySignature: return try keySignature(p, &rng)
        case .romanNumeral: return try romanNumeral(p, &rng)
        case .scaleDegreeByEar: return try scaleDegreeByEar(p, context, &rng)
        case .scaleSpelling: return try scaleSpelling(p, &rng)
        case .rhythmCount: return try rhythmCount(p, &rng)
        }
    }

    // MARK: - Params

    struct Params {
        var raw: [String: String]
        init(_ raw: [String: String]) { self.raw = raw }

        func string(_ key: String) -> String? {
            raw[key].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }

        func list(_ key: String) -> [String]? {
            guard let s = string(key) else { return nil }
            let items = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return items.isEmpty ? nil : items
        }

        func int(_ key: String) throws -> Int? {
            guard let s = string(key) else { return nil }
            guard let v = Int(s) else { throw QuizGenerationError(message: "\(key) must be a whole number, got \"\(s)\"") }
            return v
        }

        func bool(_ key: String) -> Bool? {
            string(key).map { ["true", "yes", "1"].contains($0.lowercased()) }
        }

        /// "C4-B4" → MIDI range (pitches may carry flats, so split on the last "-" before a letter).
        func pitchRange(_ key: String) throws -> (low: Pitch, high: Pitch)? {
            guard let s = string(key) else { return nil }
            let parts = splitRange(s)
            guard parts.count == 2 else {
                throw QuizGenerationError(message: "\(key) must look like \"C4-B4\", got \"\(s)\"")
            }
            let lo = try parse(parts[0], Pitch.init(parsing:)), hi = try parse(parts[1], Pitch.init(parsing:))
            guard lo.midi <= hi.midi else { throw QuizGenerationError(message: "\(key) \"\(s)\" runs high to low") }
            return (lo, hi)
        }

        private func splitRange(_ s: String) -> [String] {
            // Split at a "-" that follows a digit (keeps "C-1" style octaves intact when written first).
            let chars = Array(s)
            for i in chars.indices where chars[i] == "-" && i > 0 && chars[i - 1].isNumber {
                return [String(chars[..<i]), String(chars[(i + 1)...])].map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return [s]
        }

        func accidentals(default value: AccidentalMode) throws -> AccidentalMode {
            guard let s = string("accidentals") else { return value }
            guard let mode = AccidentalMode(rawValue: s) else {
                throw QuizGenerationError(message: "accidentals must be none, both, sharpsAndFlats, sharps, or flats; got \"\(s)\"")
            }
            return mode
        }
    }

    enum AccidentalMode: String {
        case none, both, sharpsAndFlats, sharps, flats

        var allowsBlackKeys: Bool { self != .none }

        /// Name for a pitch class shown without written spelling.
        func label(_ pc: PitchClass) -> String {
            switch self {
            case .sharps: return pc.spelled(preferSharps: true).name
            case .flats: return pc.spelled(preferSharps: false).name
            default: return pc.isBlackKey ? "\(pc.spelled(preferSharps: true).name)/\(pc.spelled(preferSharps: false).name)" : pc.spelled().name
            }
        }
    }

    static func parse<T>(_ text: String, _ make: (String) throws -> T) throws -> T {
        do { return try make(text) } catch let e as TheoryParseError {
            throw QuizGenerationError(message: e.description)
        }
    }

    static func quality(_ text: String) throws -> ChordQuality {
        if let q = ChordQuality(rawValue: text) ?? ChordQuality(suffix: text) { return q }
        switch text.lowercased() {
        case "major": return .major
        case "minor": return .minor
        case "diminished": return .diminished
        case "augmented": return .augmented
        default: throw QuizGenerationError(message: "unknown chord quality \"\(text)\"")
        }
    }

    static func intervals(_ p: Params) throws -> [Interval] {
        guard let list = p.list("intervals") else { return ExerciseGenerator.defaultIntervals }
        return try list.map { try parse($0, Interval.init(parsing:)) }
    }

    static func modes(_ p: Params) throws -> [KeyMode] {
        guard let list = p.list("mode") else { return [.major] }
        return try list.map {
            guard let m = KeyMode(rawValue: $0.lowercased()) else {
                throw QuizGenerationError(message: "mode must be major or minor, got \"\($0)\"")
            }
            return m
        }
    }

    /// Keys from `keys`: entries with an explicit mode ("Am", "E minor") keep
    /// it; bare tonics take each mode in `mode`.
    static func keys(_ p: Params, defaults: [String]) throws -> [Key] {
        let modes = try modes(p)
        var result: [Key] = []
        for entry in p.list("keys") ?? defaults {
            let key = try parse(entry, Key.init(parsing:))
            let explicit = entry.contains(" ") || (entry.count > 1 && entry.hasSuffix("m"))
            if explicit { result.append(key) } else { result += modes.map { Key(tonic: key.tonic, mode: $0) } }
        }
        guard !result.isEmpty else { throw QuizGenerationError(message: "no keys") }
        return result
    }

    // MARK: - Question assembly

    /// Shuffles the correct answer among up to `choiceCount - 1` distinct distractors (taken in order).
    static func makeQuestion<R: RandomNumberGenerator>(prompt: String, correct: String, distractors: [String],
                                                       explanation: String, playback: PlaybackSpec? = nil,
                                                       diagram: Diagram? = nil, choiceCount: Int = 4,
                                                       using rng: inout R) -> QuizQuestion {
        var seen: Set<String> = [correct]
        var picked: [String] = []
        for d in distractors where picked.count < choiceCount - 1 && seen.insert(d).inserted {
            picked.append(d)
        }
        var choices = picked + [correct]
        choices.shuffle(using: &rng)
        return QuizQuestion(prompt: prompt, choices: choices, answerIndex: choices.firstIndex(of: correct)!,
                            explanation: explanation, playback: playback, diagram: diagram)
    }

    private static func notesPlayback(_ groups: [[Int]], style: PlaybackSpec.Style = .sequence, bpm: Double = 72) -> PlaybackSpec {
        PlaybackSpec(notes: groups.map { $0.map { Pitch(midi: $0).name } }, bpm: bpm, style: style)
    }

    /// Pitch name spelled as the chord tone of the same pitch class (C7 → "Bb4", not "A#4").
    private static func chordToneName(_ midi: Int, in chord: Chord) -> String {
        let tone = (chord.tones + [chord.bass].compactMap { $0 }).first { $0.pitchClass == PitchClass(midi) }
        return (tone.flatMap { Pitch(midi: midi, spelled: $0) } ?? Pitch(midi: midi)).name
    }

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private static func pick<T, R: RandomNumberGenerator>(_ items: [T], _ rng: inout R, _ what: String) throws -> T {
        guard let item = items.randomElement(using: &rng) else { throw QuizGenerationError(message: "empty \(what) pool") }
        return item
    }

    // MARK: - Notes

    /// Distractor pitch classes near `pc`, nearest first.
    private static func neighbourClasses(_ pc: PitchClass, allowBlack: Bool) -> [PitchClass] {
        [1, -1, 2, -2, 3, -3, 4, -4, 5].map { pc.transposed(by: $0) }.filter { allowBlack || !$0.isBlackKey }
    }

    static func noteOnFretboard<R: RandomNumberGenerator>(_ p: Params, _ context: InstrumentContext, _ rng: inout R) throws -> QuizQuestion {
        let layout = context.fretboard
        let strings = try (p.list("strings") ?? (1...layout.stringCount).map(String.init)).map { s -> Int in
            guard let n = Int(s), (1...layout.stringCount).contains(n) else {
                throw QuizGenerationError(message: "strings must be 1–\(layout.stringCount), got \"\(s)\"")
            }
            return n
        }
        let fretMin = try p.int("fretMin") ?? 0, fretMax = try p.int("fretMax") ?? 12
        guard fretMin >= 0, fretMin <= fretMax, fretMax <= layout.maxFret else {
            throw QuizGenerationError(message: "fret range \(fretMin)–\(fretMax) is invalid")
        }
        let mode = try p.accidentals(default: .sharpsAndFlats)
        var positions: [FretPosition] = []
        for s in strings {
            for f in fretMin...fretMax {
                let pos = FretPosition(guitarString: s, fret: f)
                if let m = layout.midi(at: pos), mode.allowsBlackKeys || !PitchClass(m).isBlackKey { positions.append(pos) }
            }
        }
        let pos = try pick(positions, &rng, "fretboard position")
        let midi = layout.midi(at: pos)!
        let pc = PitchClass(midi)
        let openPC = PitchClass(layout.midi(string: pos.string, fret: 0)!)
        let correct = mode.label(pc)
        let distractors = neighbourClasses(pc, allowBlack: mode.allowsBlackKeys).map(mode.label)
        let open = mode.label(openPC)
        let explanation = pos.fret == 0
            ? "String \(pos.guitarString) played open is \(correct)."
            : "String \(pos.guitarString) is \(open) when open; fret \(pos.fret) is \(pos.fret) half step\(pos.fret == 1 ? "" : "s") higher, which is \(correct)."
        let hi = max(fretMax, fretMin + 4)
        let diagram = Diagram(kind: .fretboard, notes: [pos.notation], labels: .none,
                              fretRange: [fretMin, min(layout.maxFret, hi)])
        return makeQuestion(prompt: "Name the marked note.", correct: correct, distractors: distractors,
                            explanation: explanation, playback: notesPlayback([[midi]]), diagram: diagram, using: &rng)
    }

    private static func keyboardLandmark(_ pc: PitchClass) -> String {
        switch pc.value {
        case 0: return "the white key just left of the group of two black keys"
        case 2: return "the white key between the two black keys"
        case 4: return "the white key just right of the group of two black keys"
        case 5: return "the white key just left of the group of three black keys"
        case 7: return "the white key between the first and second of the three black keys"
        case 9: return "the white key between the second and third of the three black keys"
        case 11: return "the white key just right of the group of three black keys"
        default:
            let below = pc.transposed(by: -1).spelled().name, above = pc.transposed(by: 1).spelled().name
            return "the black key between \(below) and \(above)"
        }
    }

    static func noteOnKeyboard<R: RandomNumberGenerator>(_ p: Params, _ context: InstrumentContext, _ rng: inout R) throws -> QuizQuestion {
        let range = try p.pitchRange("range") ?? (Pitch(.C, octave: 4), Pitch(.B, octave: 4))
        let mode = try p.accidentals(default: .sharpsAndFlats)
        let pool = (range.low.midi...range.high.midi).filter { mode.allowsBlackKeys || !PitchClass($0).isBlackKey }
        let midi = try pick(pool, &rng, "keyboard note")
        let pc = PitchClass(midi)
        let correct = mode.label(pc)
        let distractors = neighbourClasses(pc, allowBlack: mode.allowsBlackKeys).map(mode.label)
        let diagram = Diagram(kind: .keyboard, notes: [Pitch(midi: midi).name], labels: .none,
                              pitchRange: [range.low.name, range.high.name])
        return makeQuestion(prompt: "Name the highlighted key.", correct: correct, distractors: distractors,
                            explanation: "\(correct) is \(keyboardLandmark(pc)). This one is \(Pitch(midi: midi).name).",
                            playback: notesPlayback([[midi]]), diagram: diagram, using: &rng)
    }

    /// Where a written pitch sits on a clef: "on the second line of the treble staff", "just below the bass staff".
    static func staffPosition(_ pitch: Pitch, treble: Bool) -> String {
        let staff = treble ? "treble staff" : "bass staff"
        let bottomLine = treble ? Pitch(.E, octave: 4) : Pitch(.G, octave: 2)
        let steps = pitch.diatonicIndex - bottomLine.diatonicIndex
        let ordinals = ["bottom", "second", "middle", "fourth", "top"]
        let spaces = ["first", "second", "third", "top"]
        switch steps {
        case 0...8:
            return (steps % 2 == 0 ? "on the \(ordinals[steps / 2]) line" : "in the \(spaces[steps / 2]) space") + " of the \(staff)"
        case -1: return "just below the \(staff)"
        case 9: return "just above the \(staff)"
        case ..<(-1): return "below the \(staff), on ledger lines"
        default: return "above the \(staff), on ledger lines"
        }
    }

    static func noteOnStaff<R: RandomNumberGenerator>(_ p: Params, _ context: InstrumentContext, _ rng: inout R) throws -> QuizQuestion {
        let clef = p.string("clef")?.lowercased() ?? "treble"
        guard ["treble", "bass", "grand"].contains(clef) else {
            throw QuizGenerationError(message: "clef must be treble, bass, or grand; got \"\(clef)\"")
        }
        let defaultRange: (Pitch, Pitch) = clef == "treble" ? (Pitch(.C, octave: 4), Pitch(.A, octave: 5))
            : clef == "bass" ? (Pitch(.E, octave: 2), Pitch(.C, octave: 4)) : (Pitch(.G, octave: 2), Pitch(.G, octave: 5))
        let range = try p.pitchRange("range") ?? defaultRange
        let mode = try p.accidentals(default: .none)
        let writtenOffset = (p.bool("guitarOctave") ?? false) ? 12 : 0
        var pool: [Pitch] = []
        for midi in range.low.midi...range.high.midi {
            let pc = PitchClass(midi)
            if !pc.isBlackKey { pool.append(Pitch(midi: midi)); continue }
            switch mode {
            case .none: break
            case .sharps: pool.append(Pitch(midi: midi, preferSharps: true))
            case .flats: pool.append(Pitch(midi: midi, preferSharps: false))
            case .both, .sharpsAndFlats:
                pool.append(Pitch(midi: midi, preferSharps: true))
                pool.append(Pitch(midi: midi, preferSharps: false))
            }
        }
        let written = try pick(pool, &rng, "staff note")
        let treble = clef == "treble" || (clef == "grand" && written.midi >= 60)
        let correct = written.note.name
        // Distractors: neighbouring letters with the same accidental (line/space mix-ups), then the natural.
        var distractors: [String] = []
        for step in [1, -1, 2, -2, 3] {
            let note = SpelledNote(written.letter.advanced(by: step), written.note.accidental)
            // Skip unusual spellings such as E# or Cb.
            if note.accidental == 0 || note.pitchClass.isBlackKey { distractors.append(note.name) }
        }
        if written.note.accidental != 0 { distractors.insert(SpelledNote(written.letter).name, at: 1) }
        let clefName = treble ? "treble" : "bass"
        var explanation = "\(written.note.name) (\(written.name)) sits \(staffPosition(written, treble: treble))."
        if writtenOffset != 0 {
            explanation += " Guitar music is written an octave above the sound, so it sounds as \(Pitch(midi: written.midi - 12, spelled: written.note)?.name ?? written.name)."
        }
        let diagram = Diagram(kind: .staff, notes: [written.name], labels: .none,
                              pitchRange: [range.low.name, range.high.name],
                              caption: clef == "grand" ? "Grand staff" : "\(capitalized(clefName)) clef")
        let sounding = written.midi - writtenOffset
        return makeQuestion(prompt: "Name the note on the staff.", correct: correct, distractors: distractors,
                            explanation: explanation, playback: PlaybackSpec(notes: [[(Pitch(midi: sounding, spelled: written.note) ?? Pitch(midi: sounding)).name]], bpm: 72, style: .sequence),
                            diagram: diagram, using: &rng)
    }

    // MARK: - Intervals

    static func intervalLabel(_ interval: Interval) -> String { capitalized(interval.name) }

    /// Other intervals, closest in size first: the set's own members, then common ones.
    private static func intervalDistractors(_ interval: Interval, pool: [Interval]) -> [String] {
        let byDistance: ([Interval]) -> [Interval] = { list in
            list.filter { $0 != interval && $0.semitones != interval.semitones }
                .sorted { abs($0.semitones - interval.semitones) < abs($1.semitones - interval.semitones) }
        }
        return (byDistance(pool) + byDistance(Interval.common)).map(intervalLabel)
    }

    private static func randomRoot<R: RandomNumberGenerator>(for interval: Interval, in range: ClosedRange<Int>,
                                                             _ rng: inout R) throws -> Pitch {
        let top = range.upperBound - interval.semitones
        guard top >= range.lowerBound else {
            throw QuizGenerationError(message: "range is too small for a \(interval.name)")
        }
        let midi = Int.random(in: range.lowerBound...top, using: &rng)
        // Keep spellings readable: flats for flat-side black keys half the time.
        let root = Pitch(midi: midi, preferSharps: Bool.random(using: &rng))
        let upper = root.transposed(by: interval)
        return abs(upper.note.accidental) > 1 ? Pitch(midi: midi, preferSharps: !(root.note.accidental > 0)) : root
    }

    static func intervalByEar<R: RandomNumberGenerator>(_ p: Params, _ context: InstrumentContext, _ rng: inout R) throws -> QuizQuestion {
        let pool = try intervals(p)
        let range = try p.pitchRange("range").map { $0.low.midi...$0.high.midi } ?? (context.instrument == .guitar ? 48...72 : 60...79)
        let interval = try pick(pool, &rng, "interval")
        let root = try randomRoot(for: interval, in: range, &rng)
        let upper = root.transposed(by: interval)
        var direction = p.string("direction")?.lowercased() ?? "up"
        guard ["up", "down", "harmonic", "mixed"].contains(direction) else {
            throw QuizGenerationError(message: "direction must be up, down, harmonic, or mixed; got \"\(direction)\"")
        }
        if direction == "mixed" { direction = ["up", "down", "harmonic"].randomElement(using: &rng)! }
        let playback: PlaybackSpec
        let prompt: String
        switch direction {
        case "down":
            playback = PlaybackSpec(notes: [[upper.name], [root.name]], bpm: 60, style: .sequence)
            prompt = "Listen: two notes, going down. Which interval is it?"
        case "harmonic":
            playback = PlaybackSpec(notes: [[root.name, upper.name]], bpm: 60, style: .block)
            prompt = "Listen: two notes together. Which interval is it?"
        default:
            playback = PlaybackSpec(notes: [[root.name], [upper.name]], bpm: 60, style: .sequence)
            prompt = "Listen: two notes, going up. Which interval is it?"
        }
        var explanation = "\(root.name) to \(upper.name) is a \(interval.name): \(interval.semitones) half step\(interval.semitones == 1 ? "" : "s")"
        if let alt = interval.alternateName { explanation += " (a \(alt))" }
        return makeQuestion(prompt: prompt, correct: intervalLabel(interval),
                            distractors: intervalDistractors(interval, pool: pool),
                            explanation: explanation + ".", playback: playback, using: &rng)
    }

    static func intervalByName<R: RandomNumberGenerator>(_ p: Params, _ context: InstrumentContext, _ rng: inout R) throws -> QuizQuestion {
        let pool = try intervals(p)
        let range = try p.pitchRange("range").map { $0.low.midi...$0.high.midi } ?? 60...72
        let interval = try pick(pool, &rng, "interval")
        let root = try randomRoot(for: interval, in: range, &rng)
        let upper = root.transposed(by: interval)
        // Same-number distractors first (major vs minor third), then nearby sizes.
        var distractors: [String] = []
        switch interval.quality {
        case .major: distractors.append(intervalLabel(Interval(quality: .minor, number: interval.number)!))
        case .minor: distractors.append(intervalLabel(Interval(quality: .major, number: interval.number)!))
        default:
            if interval.simpleNumber == 4 || interval.simpleNumber == 5 { distractors.append(intervalLabel(.A4)) }
        }
        distractors += intervalDistractors(interval, pool: pool)
        let diagram = context.instrument == .piano
            ? Diagram(kind: .keyboard, notes: [root.name, upper.name], labels: .noteNames,
                      pitchRange: [Pitch(midi: KeyboardLayout.fitting([root.midi, upper.midi]).lowestMIDI).name,
                                   Pitch(midi: KeyboardLayout.fitting([root.midi, upper.midi]).highestMIDI).name])
            : nil
        let steps = interval.number
        let explanation = "\(root.note.name) up to \(upper.note.name) spans \(steps) letter names (\(interval.number == 8 ? "an octave" : "a \(Interval.ordinal(steps))")) and \(interval.semitones) half steps, so it is a \(interval.name)."
        return makeQuestion(prompt: "What is the interval from \(root.name) up to \(upper.name)?", correct: intervalLabel(interval),
                            distractors: distractors, explanation: explanation,
                            playback: PlaybackSpec(notes: [[root.name], [upper.name]], bpm: 60, style: .sequence),
                            diagram: diagram, using: &rng)
    }

    // MARK: - Chords

    static func qualityLabel(_ q: ChordQuality) -> String { capitalized(q.name) }

    private static let relatedQualities: [ChordQuality] = [.major, .minor, .diminished, .augmented, .dominantSeventh,
                                                           .majorSeventh, .minorSeventh, .halfDiminishedSeventh, .sus4]

    private static func roots(_ p: Params, defaults: [String]) throws -> [SpelledNote] {
        try (p.list("roots") ?? defaults).map { try parse($0, SpelledNote.init(parsing:)) }
    }

    private static func qualities(_ p: Params) throws -> [ChordQuality] {
        try (p.list("qualities") ?? ["maj", "min"]).map(quality)
    }

    private static func qualityFormula(_ q: ChordQuality) -> String {
        q.intervals.dropFirst().map(\.name).joined(separator: ", ")
    }

    static func chordQualityByEar<R: RandomNumberGenerator>(_ p: Params, _ context: InstrumentContext, _ rng: inout R) throws -> QuizQuestion {
        let pool = try qualities(p)
        let rootPool = try roots(p, defaults: ["C", "D", "E", "F", "G", "A", "Bb"])
        let q = try pick(pool, &rng, "quality")
        let chord = Chord(root: try pick(rootPool, &rng, "root"), quality: q)
        let voicing = context.voicing(for: chord)
        let groups = [voicing.midi] + voicing.midi.map { [$0] }
        let playback = PlaybackSpec(notes: groups.map { $0.map { chordToneName($0, in: chord) } }, bpm: 60, style: .sequence)
        let distractors = (pool + relatedQualities).filter { $0 != q }.map(qualityLabel)
        let spelled = chord.tones.map(\.name).joined(separator: " ")
        return makeQuestion(prompt: "Listen to the chord, then its notes one by one. What quality is it?",
                            correct: qualityLabel(q), distractors: distractors,
                            explanation: "That was \(chord.symbol) (\(spelled)). A \(q.name) chord stacks a \(qualityFormula(q)) above the root.",
                            playback: playback, using: &rng)
    }

    static func chordSpelling<R: RandomNumberGenerator>(_ p: Params, _ context: InstrumentContext, _ rng: inout R) throws -> QuizQuestion {
        let pool = try qualities(p)
        let rootPool = try roots(p, defaults: ["C", "D", "E", "F", "G", "A"])
        let chord = Chord(root: try pick(rootPool, &rng, "root"), quality: try pick(pool, &rng, "quality"))
        let others = (pool + relatedQualities).filter { $0 != chord.quality }.map { Chord(root: chord.root, quality: $0) }
            .filter { $0.pitchClasses != chord.pitchClasses }
        let spell: (Chord) -> String = { $0.tones.map(\.name).joined(separator: " ") }
        let explanation = "\(chord.symbol) is \(spell(chord)): root \(chord.root.name) with a \(qualityFormula(chord.quality)) above it."
        if Bool.random(using: &rng) {
            return makeQuestion(prompt: "Which notes are in \(chord.symbol)?", correct: spell(chord),
                                distractors: others.map(spell), explanation: explanation, using: &rng)
        }
        return makeQuestion(prompt: "Which chord is spelled \(spell(chord))?", correct: chord.symbol,
                            distractors: others.map(\.symbol), explanation: explanation,
                            playback: PlaybackSpec(notes: [context.voicing(for: chord).midi.map { chordToneName($0, in: chord) }],
                                                   bpm: 60, style: .block), using: &rng)
    }

    // MARK: - Keys

    static func keySignature<R: RandomNumberGenerator>(_ p: Params, _ rng: inout R) throws -> QuizQuestion {
        let pool = try keys(p, defaults: ["C", "G", "D", "F", "Bb"])
        let key = try pick(pool, &rng, "key")
        let fifths = key.signature.fifths
        let accidentals = key.signature.accidentals.map(\.name).joined(separator: " ")
        let explanation = "\(key.name.capitalizedFirst) has \(key.signature.description)" + (accidentals.isEmpty ? "." : ": \(accidentals).")
        if Bool.random(using: &rng) {
            let near = [1, -1, 2, -2, -fifths * 2, 3].map { fifths + $0 }.filter { $0 != fifths && abs($0) <= 7 }
            return makeQuestion(prompt: "How many sharps or flats are in \(key.name)?", correct: key.signature.description,
                                distractors: near.map { KeySignature(fifths: $0).description }, explanation: explanation, using: &rng)
        }
        let sameMode = pool.filter { $0.mode == key.mode && $0.signature.fifths != fifths }
            .sorted { abs($0.signature.fifths - fifths) < abs($1.signature.fifths - fifths) }
        let neighbours = [1, -1, 2, -2].compactMap { Key(fifths: fifths + $0, mode: key.mode) }
        return makeQuestion(prompt: "Which \(key.mode.rawValue) key has \(key.signature.description)?", correct: key.name,
                            distractors: (sameMode + neighbours).map(\.name), explanation: explanation, using: &rng)
    }

    static func romanNumeral<R: RandomNumberGenerator>(_ p: Params, _ rng: inout R) throws -> QuizQuestion {
        let key = try pick(try keys(p, defaults: ["C", "G", "D", "F"]), &rng, "key")
        let numerals = p.list("numerals") ?? key.triadNumerals
        let chords = try numerals.map { n -> (String, Chord) in
            do { return (n, try key.chord(forRoman: n)) } catch let e as TheoryParseError {
                throw QuizGenerationError(message: e.description)
            }
        }
        let (numeral, chord) = try pick(chords, &rng, "numeral")
        let diatonic = zip(key.triadNumerals, key.diatonicTriads).map { ($0, $1) }
        let scale = key.scale.notes.enumerated().map { "\($1.name) (\(key.triadNumerals[$0]))" }.joined(separator: ", ")
        let explanation = "In \(key.name), the degrees are \(scale). \(numeral) is \(chord.symbol)."
        if Bool.random(using: &rng) {
            let others = (chords + diatonic).map(\.1).filter { $0 != chord }.map(\.symbol)
            return makeQuestion(prompt: "In \(key.name), which chord is \(numeral)?", correct: chord.symbol,
                                distractors: others, explanation: explanation, using: &rng)
        }
        let others = (chords + diatonic).map(\.0).filter { $0 != numeral }
        return makeQuestion(prompt: "In \(key.name), what is the Roman numeral for \(chord.symbol)?", correct: numeral,
                            distractors: others, explanation: explanation, using: &rng)
    }

    // MARK: - Scales

    private static let degreeNames = ["tonic", "supertonic", "mediant", "subdominant", "dominant", "submediant", "leading tone"]

    private static func degreeLabel(_ degree: Int, mode: KeyMode) -> String {
        let name = degree == 7 && mode == .minor ? "subtonic" : degreeNames[degree - 1]
        return "\(degree) (\(name))"
    }

    static func scaleDegreeByEar<R: RandomNumberGenerator>(_ p: Params, _ context: InstrumentContext, _ rng: inout R) throws -> QuizQuestion {
        let keyPool = try keys(p, defaults: ["C major", "G major"])
        let degrees = try (p.list("degrees") ?? (1...7).map(String.init)).map { s -> Int in
            guard let d = Int(s), (1...7).contains(d) else { throw QuizGenerationError(message: "degrees must be 1–7, got \"\(s)\"") }
            return d
        }
        let key = try pick(keyPool, &rng, "key")
        let degree = try pick(degrees, &rng, "degree")
        let start = context.scaleStart(key.scale, octaves: 1)
        let tonicChord = Chord(root: key.tonic, quality: key.mode == .major ? .major : .minor)
        let triad = context.instrument == .piano
            ? context.voicing(for: tonicChord).midi
            : [0, 2, 4].map { start.transposed(by: key.scale.intervals[$0]).midi }
        let target = start.transposed(by: key.scale.intervals[degree - 1])
        let playback = PlaybackSpec(notes: [triad.map { Pitch(midi: $0).name }, [target.name]], bpm: 50, style: .sequence)
        let others = (degrees + Array(1...7)).filter { $0 != degree }
            .sorted { abs($0 - degree) < abs($1 - degree) }.map { degreeLabel($0, mode: key.mode) }
        return makeQuestion(prompt: "Hear the \(key.name) tonic chord, then one note. Which scale degree is the note?",
                            correct: degreeLabel(degree, mode: key.mode), distractors: others,
                            explanation: "In \(key.name), degree \(degree) is \(key.scale.note(degree: degree).name).",
                            playback: playback, using: &rng)
    }

    private static func stepPattern(_ scale: Scale) -> String {
        let pcs = scale.pitchClasses + [scale.root.pitchClass]
        return zip(pcs, pcs.dropFirst()).map { a, b -> String in
            switch a.semitones(upTo: b) {
            case 1: return "H"
            case 2: return "W"
            case 3: return "W+H"
            default: return "\(a.semitones(upTo: b))"
            }
        }.joined(separator: " ")
    }

    static func scaleSpelling<R: RandomNumberGenerator>(_ p: Params, _ rng: inout R) throws -> QuizQuestion {
        var pool: [Scale] = []
        if let scales = p.list("scales") {
            pool = try scales.map { try parse($0, Scale.init(parsing:)) }
        } else {
            let typeText = p.string("type") ?? "major"
            guard let type = ScaleType(name: typeText) else {
                throw QuizGenerationError(message: "unknown scale type \"\(typeText)\"")
            }
            pool = try (p.list("keys") ?? ["C", "G", "D", "F"]).map {
                Scale(root: try parse($0, SpelledNote.init(parsing:)), type: type)
            }
        }
        let scale = try pick(pool, &rng, "scale")
        let spell: ([SpelledNote]) -> String = { $0.map(\.name).joined(separator: " ") }
        let correct = spell(scale.notes)
        var distractors: [String] = []
        // One note raised or lowered by a half step (keeps the letter, wrong pitch).
        var indices = Array(scale.notes.indices.dropFirst())
        indices.shuffle(using: &rng)
        for i in indices.prefix(2) {
            var notes = scale.notes
            let shift = notes[i].accidental > 0 ? -1 : (notes[i].accidental < 0 ? 1 : (Bool.random(using: &rng) ? 1 : -1))
            notes[i] = SpelledNote(notes[i].letter, notes[i].accidental + shift)
            distractors.append(spell(notes))
        }
        // Related scale types on the same root.
        let related: [ScaleType] = [.major, .naturalMinor, .harmonicMinor, .majorPentatonic, .minorPentatonic, .blues, .mixolydian]
        distractors += related.filter { $0 != scale.type && $0.intervals.count == scale.type.intervals.count }
            .map { spell(Scale(root: scale.root, type: $0).notes) }
        distractors += related.filter { $0 != scale.type }.map { spell(Scale(root: scale.root, type: $0).notes) }
        return makeQuestion(prompt: "Which notes make up \(scale.name)?", correct: correct, distractors: distractors,
                            explanation: "\(scale.name.capitalizedFirst): \(correct). Steps from the root: \(stepPattern(scale)).",
                            using: &rng)
    }

    // MARK: - Rhythm

    static func beatsLabel(_ beats: Double) -> String {
        let whole = Int(beats.rounded(.down))
        let frac = beats - Double(whole)
        let fracText: String
        switch frac {
        case let f where abs(f) < 1e-6: fracText = ""
        case let f where abs(f - 0.5) < 1e-6: fracText = "½"
        case let f where abs(f - 0.25) < 1e-6: fracText = "¼"
        case let f where abs(f - 0.75) < 1e-6: fracText = "¾"
        case let f where abs(f - 1.0 / 3) < 1e-6: fracText = "⅓"
        case let f where abs(f - 2.0 / 3) < 1e-6: fracText = "⅔"
        default: fracText = String(format: "%.2f", frac).replacingOccurrences(of: "0.", with: ".")
        }
        let number = whole == 0 && !fracText.isEmpty ? fracText : "\(whole)\(fracText)"
        return number + (beats > 1 + 1e-6 || beats < 1 - 1e-6 ? (beats < 1 ? " beat" : " beats") : " beat")
    }

    static func rhythmName(_ event: RhythmEvent) -> String {
        event.value.name + (event.isRest ? " rest" : " note")
    }

    static func rhythmCount<R: RandomNumberGenerator>(_ p: Params, _ rng: inout R) throws -> QuizQuestion {
        let tokens = p.list("values") ?? p.list("tokens") ?? ["w", "h", "q", "e"]
        var pool = try tokens.map { try parse($0, RhythmEvent.init(parsing:)) }
        if p.bool("rests") == true {
            pool += pool.filter { !$0.isRest }.map { RhythmEvent($0.value, isRest: true) }
        }
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0.token).inserted }
        let signatures = try (p.list("timeSignature") ?? ["4/4"]).map { text -> (String, Double) in
            let parts = text.split(separator: "/")
            guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), n > 0, [2, 4, 8].contains(d) else {
                throw QuizGenerationError(message: "timeSignature must look like 4/4 or 3/4, got \"\(text)\"")
            }
            return (text, Double(n) * 4 / Double(d))
        }
        let (signature, measure) = try pick(signatures, &rng, "time signature")
        let target = try pick(pool, &rng, "rhythm value")

        // Variant: fill the measure. Needs at least two values with different lengths.
        if Bool.random(using: &rng), target.beats < measure,
           Set(pool.map(\.beats)).count >= 2,
           let filler = fill(measure - target.beats, from: pool.filter { $0.beats <= measure - target.beats }, &rng) {
            var events = filler
            events.append(target)
            let wrong = pool.filter { abs($0.beats - target.beats) > 1e-6 }
                .sorted { abs($0.beats - target.beats) < abs($1.beats - target.beats) }
            if !wrong.isEmpty {
                let shown = RhythmPattern(Array(events.dropLast())).tokens
                let d = Diagram(kind: .rhythm, rhythm: shown, labels: .none,
                                caption: "\(signature): one value missing at the end")
                // Choice labels by length name only; rests and notes of the same length would both fit, so compare by beats.
                let correct = capitalized(target.value.name)
                let distractors = wrong.map { capitalized($0.value.name) }
                    .filter { name in !pool.contains { abs($0.beats - target.beats) < 1e-6 && capitalized($0.value.name) == name } }
                if !distractors.isEmpty {
                    return makeQuestion(prompt: "This \(signature) measure is one value short. Which length completes it?",
                                        correct: correct, distractors: distractors,
                                        explanation: "The measure holds \(beatsLabel(measure)); the values shown add up to \(beatsLabel(measure - target.beats)), so a \(target.value.name) (\(beatsLabel(target.beats))) completes it.",
                                        diagram: d, using: &rng)
                }
            }
        }
        let standard: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4]
        let distractorBeats = (pool.map(\.beats) + standard).filter { abs($0 - target.beats) > 1e-6 }
            .sorted { abs($0 - target.beats) < abs($1 - target.beats) }
        let diagram = Diagram(kind: .rhythm, rhythm: target.token, labels: .none)
        return makeQuestion(prompt: "In \(signature), how long is a \(rhythmName(target))?", correct: beatsLabel(target.beats),
                            distractors: distractorBeats.map(beatsLabel),
                            explanation: "A \(rhythmName(target)) lasts \(beatsLabel(target.beats)) when the quarter note gets the beat.",
                            diagram: diagram, using: &rng)
    }

    /// Random values summing exactly to `beats`, or nil.
    private static func fill<R: RandomNumberGenerator>(_ beats: Double, from pool: [RhythmEvent], _ rng: inout R) -> [RhythmEvent]? {
        guard beats > 1e-6 else { return [] }
        for _ in 0..<20 {
            var remaining = beats
            var events: [RhythmEvent] = []
            while remaining > 1e-6 {
                let options = pool.filter { $0.beats <= remaining + 1e-6 }
                guard let e = options.randomElement(using: &rng) else { break }
                events.append(e)
                remaining -= e.beats
            }
            if abs(remaining) < 1e-6, events.count <= 8 { return events }
        }
        return nil
    }

    // MARK: - Validation support

    /// Param problems for the validator: unknown keys (warnings) and values that
    /// fail to generate (errors, found by generating a sample).
    static func check(_ spec: QuizGeneratorSpec, instrument: TutorInstrument) -> (errors: [String], warnings: [String]) {
        let known = knownParams[spec.kind] ?? []
        let warnings = spec.params.keys.sorted().filter { !known.contains($0) }
            .map { "unknown param \"\($0)\" for \(spec.kind.rawValue)" }
        var errors: [String] = []
        do {
            var rng = SeededRandom(seed: 7)
            let sample = try questions(for: spec, count: 24, context: .standard(instrument), using: &rng)
            for q in sample where q.choices.count < 2 {
                errors.append("generated a question with fewer than two choices: \"\(q.prompt)\"")
                break
            }
        } catch {
            errors.append("\(error)")
        }
        return (errors, warnings)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
