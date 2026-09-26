//
//  Pitch.swift
//  TabBuddy
//
//  Letters, pitch classes, spelled notes, and pitches in scientific pitch
//  notation (C4 = MIDI 60, A4 = 440 Hz). Spelling is kept: C#4 and Db4 are
//  different `Pitch` values with the same `midi`.
//

import Foundation

// MARK: - NoteLetter

enum NoteLetter: Int, CaseIterable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    case C, D, E, F, G, A, B

    /// Pitch class of the natural note (C = 0).
    var naturalPitchClass: Int { [0, 2, 4, 5, 7, 9, 11][rawValue] }

    var name: String { ["C", "D", "E", "F", "G", "A", "B"][rawValue] }
    var description: String { name }

    /// Position on the circle of fifths relative to C (F = -1, G = 1 … B = 5).
    var fifthsFromC: Int { [0, 2, 4, -1, 1, 3, 5][rawValue] }

    /// Letter `steps` letters above (negative = below), wrapping.
    func advanced(by steps: Int) -> NoteLetter {
        NoteLetter(rawValue: ((rawValue + steps) % 7 + 7) % 7)!
    }

    init?(character: Character) {
        switch character.uppercased() {
        case "C": self = .C
        case "D": self = .D
        case "E": self = .E
        case "F": self = .F
        case "G": self = .G
        case "A": self = .A
        case "B": self = .B
        default: return nil
        }
    }

    static func < (lhs: NoteLetter, rhs: NoteLetter) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - PitchClass

/// One of the 12 pitch classes, C = 0 … B = 11. Encodes as its integer.
struct PitchClass: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    let value: Int

    /// Wraps any integer into 0...11.
    init(_ value: Int) { self.value = ((value % 12) + 12) % 12 }

    init(midi: Int) { self.init(midi) }

    /// Parses a note name without octave ("C", "F#", "Bb").
    init(parsing string: String) throws {
        do {
            self = try SpelledNote(parsing: string).pitchClass
        } catch let error as TheoryParseError {
            throw TheoryParseError(kind: .pitchClass, input: string, reason: error.reason)
        }
    }

    init?(_ string: String) { try? self.init(parsing: string) }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    static let all: [PitchClass] = (0..<12).map { PitchClass($0) }

    func transposed(by semitones: Int) -> PitchClass { PitchClass(value + semitones) }

    /// Ascending distance in semitones from `self` up to `other` (0...11).
    func semitones(upTo other: PitchClass) -> Int { ((other.value - value) % 12 + 12) % 12 }

    var isBlackKey: Bool { [1, 3, 6, 8, 10].contains(value) }

    /// Common spelling: sharps or flats for black keys, naturals otherwise.
    func spelled(preferSharps: Bool = true) -> SpelledNote {
        SpelledNote.common(for: self, preferSharps: preferSharps)
    }

    /// Both spellings of a black key ("C#/Db"), or the natural name.
    var enharmonicLabel: String {
        isBlackKey ? "\(spelled(preferSharps: true).name)/\(spelled(preferSharps: false).name)"
                   : spelled().name
    }

    var description: String { spelled().name }

    static func < (lhs: PitchClass, rhs: PitchClass) -> Bool { lhs.value < rhs.value }
}

// MARK: - SpelledNote

/// A note name: letter plus accidental offset (F# = F +1, Bb = B -1, Cx = C +2).
/// Encodes as its ASCII name ("F#", "Bb", "Cx", "Ebb").
struct SpelledNote: Hashable, Sendable, CustomStringConvertible {
    var letter: NoteLetter
    /// Semitone offset from the natural letter: -2 = double flat … +2 = double sharp.
    var accidental: Int

    init(_ letter: NoteLetter, _ accidental: Int = 0) {
        self.letter = letter
        self.accidental = accidental
    }

    init(letter: NoteLetter, accidental: Int = 0) {
        self.init(letter, accidental)
    }

    var pitchClass: PitchClass { PitchClass(letter.naturalPitchClass + accidental) }

    /// ASCII name: "C", "F#", "Bb", "Cx" (double sharp), "Ebb" (double flat).
    var name: String { letter.name + Self.asciiAccidental(accidental) }

    /// Display name with music symbols: "F♯", "B♭", "C𝄪", "E𝄫".
    var displayName: String { letter.name + Self.symbolAccidental(accidental) }

    var description: String { name }

    var isNatural: Bool { accidental == 0 }

    /// Circle-of-fifths position relative to C (Gb = -6, F# = 6, Cb = -7).
    var fifthsFromC: Int { letter.fifthsFromC + 7 * accidental }

    func isEnharmonic(with other: SpelledNote) -> Bool { pitchClass == other.pitchClass }

    /// The same pitch class spelled with the neighbouring letter above or below,
    /// choosing the spelling with the smallest accidental (C# ↔ Db, E# → F, Cb → B).
    func enharmonicEquivalents() -> [SpelledNote] {
        var result: [SpelledNote] = []
        for step in [-1, 1, -2, 2] {
            let l = letter.advanced(by: step)
            var acc = pitchClass.value - l.naturalPitchClass
            acc = ((acc % 12) + 12) % 12
            if acc > 6 { acc -= 12 }
            if abs(acc) <= 2 { result.append(SpelledNote(l, acc)) }
        }
        return result
    }

    /// Parses "C", "c", "F#", "F♯", "Bb", "B♭", "Cx", "C##", "C𝄪", "Ebb", "E𝄫",
    /// "Fn"/"F♮" (natural), and the word forms "F sharp", "B flat".
    init(parsing string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let letter = NoteLetter(character: first) else {
            throw TheoryParseError(kind: .note, input: string,
                                   reason: "expected a letter A–G followed by an optional accidental (#, b, x, bb)")
        }
        let rest = String(trimmed.dropFirst())
        guard let acc = Self.parseAccidental(rest) else {
            throw TheoryParseError(kind: .note, input: string,
                                   reason: "unrecognized accidental \"\(rest)\"; use #, b, x (double sharp), or bb")
        }
        self.init(letter, acc)
    }

    init?(_ string: String) { try? self.init(parsing: string) }

    /// Accidental text to offset; nil if unrecognized. Empty = natural.
    static func parseAccidental(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "", "n", "♮", "natural": return 0
        case "sharp", "-sharp": return 1
        case "flat", "-flat": return -1
        case "double sharp", "double-sharp": return 2
        case "double flat", "double-flat": return -2
        default: break
        }
        var total = 0
        var sharps = false, flats = false
        for c in t {
            switch c {
            case "#", "♯": total += 1; sharps = true
            case "b", "♭": total -= 1; flats = true
            case "x", "𝄪": total += 2; sharps = true
            case "𝄫": total -= 2; flats = true
            default: return nil
            }
        }
        // Mixed sharps and flats ("#b") are rejected rather than cancelled.
        guard abs(total) <= 2, !(sharps && flats) else { return nil }
        return total
    }

    static func asciiAccidental(_ acc: Int) -> String {
        switch acc {
        case 0: return ""
        case 2: return "x"
        case let a where a > 0: return String(repeating: "#", count: a)
        default: return String(repeating: "b", count: -acc)
        }
    }

    static func symbolAccidental(_ acc: Int) -> String {
        switch acc {
        case 0: return ""
        case 1: return "♯"
        case 2: return "𝄪"
        case -1: return "♭"
        case -2: return "𝄫"
        case let a where a > 0: return String(repeating: "♯", count: a)
        default: return String(repeating: "♭", count: -acc)
        }
    }

    /// Common spelling of a pitch class: naturals for white keys; C#/D#/F#/G#/A#
    /// or Db/Eb/Gb/Ab/Bb for black keys.
    static func common(for pc: PitchClass, preferSharps: Bool = true) -> SpelledNote {
        let sharps: [SpelledNote] = [.init(.C), .init(.C, 1), .init(.D), .init(.D, 1), .init(.E), .init(.F),
                                     .init(.F, 1), .init(.G), .init(.G, 1), .init(.A), .init(.A, 1), .init(.B)]
        let flats: [SpelledNote] = [.init(.C), .init(.D, -1), .init(.D), .init(.E, -1), .init(.E), .init(.F),
                                    .init(.G, -1), .init(.G), .init(.A, -1), .init(.A), .init(.B, -1), .init(.B)]
        return (preferSharps ? sharps : flats)[pc.value]
    }

    // Convenience constants for naturals.
    static let C = SpelledNote(.C), D = SpelledNote(.D), E = SpelledNote(.E), F = SpelledNote(.F)
    static let G = SpelledNote(.G), A = SpelledNote(.A), B = SpelledNote(.B)
}

extension SpelledNote: Codable {
    init(from decoder: Decoder) throws {
        self = try decoder.singleValueContainer().decodeTheoryString { try SpelledNote(parsing: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

// MARK: - Pitch

/// A spelled note in a specific octave (scientific pitch notation, C4 = MIDI 60).
/// The octave number belongs to the letter, so Cb4 = MIDI 59 and B#3 = MIDI 60.
/// Encodes as its ASCII name ("C#4", "Bb3").
struct Pitch: Hashable, Sendable, Comparable, CustomStringConvertible {
    var note: SpelledNote
    var octave: Int

    init(_ note: SpelledNote, octave: Int) {
        self.note = note
        self.octave = octave
    }

    /// Spells a MIDI number with common black-key names.
    init(midi: Int, preferSharps: Bool = true) {
        let pc = PitchClass(midi)
        let note = SpelledNote.common(for: pc, preferSharps: preferSharps)
        self.init(note, octave: Self.octave(of: note, midi: midi))
    }

    /// Spells a MIDI number as the given note, choosing the matching octave.
    /// Returns nil when `note` is not that pitch class.
    init?(midi: Int, spelled note: SpelledNote) {
        guard note.pitchClass == PitchClass(midi) else { return nil }
        self.init(note, octave: Self.octave(of: note, midi: midi))
    }

    private static func octave(of note: SpelledNote, midi: Int) -> Int {
        // midi = (octave + 1) * 12 + natural + accidental
        let base = midi - note.letter.naturalPitchClass - note.accidental
        return Int((Double(base) / 12).rounded(.down)) - 1
    }

    /// Parses "E2", "C#4", "Bb3", "B♭3", "Cx5", "C-1". MIDI must be 0...127.
    init(parsing string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Octave: trailing digits with an optional leading minus sign.
        var digits = ""
        var body = Substring(trimmed)
        while let last = body.last, last.isASCII, last.isNumber {
            digits.insert(last, at: digits.startIndex)
            body = body.dropLast()
        }
        guard !digits.isEmpty else {
            throw TheoryParseError(kind: .pitch, input: string,
                                   reason: "missing octave number; write pitches like \"E2\", \"C#4\", \"Bb3\" (C4 = middle C)")
        }
        if body.last == "-" {
            digits = "-" + digits
            body = body.dropLast()
        }
        let note: SpelledNote
        do {
            note = try SpelledNote(parsing: String(body))
        } catch let error as TheoryParseError {
            throw TheoryParseError(kind: .pitch, input: string, reason: error.reason)
        }
        guard let octave = Int(digits), (-1...9).contains(octave) else {
            throw TheoryParseError(kind: .pitch, input: string, reason: "octave must be -1…9")
        }
        self.init(note, octave: octave)
        guard (0...127).contains(midi) else {
            throw TheoryParseError(kind: .pitch, input: string, reason: "outside the MIDI range C-1…G9")
        }
    }

    init?(_ string: String) { try? self.init(parsing: string) }

    var midi: Int { (octave + 1) * 12 + note.letter.naturalPitchClass + note.accidental }
    var pitchClass: PitchClass { note.pitchClass }
    var letter: NoteLetter { note.letter }

    /// Equal-tempered frequency in Hz.
    func frequency(referenceA4: Double = 440) -> Double { Self.frequency(midi: Double(midi), referenceA4: referenceA4) }
    var frequency: Double { frequency() }

    static func frequency(midi: Double, referenceA4: Double = 440) -> Double {
        referenceA4 * pow(2, (midi - 69) / 12)
    }

    /// Fractional MIDI number for a frequency (for tuner needles).
    static func midiValue(frequency: Double, referenceA4: Double = 440) -> Double {
        69 + 12 * log2(frequency / referenceA4)
    }

    /// ASCII name with octave: "C#4".
    var name: String { note.name + String(octave) }
    /// Display name with music symbols: "C♯4".
    var displayName: String { note.displayName + String(octave) }
    var description: String { name }

    /// Diatonic step index (octave * 7 + letter) used for staff placement.
    var diatonicIndex: Int { octave * 7 + note.letter.rawValue }

    func isEnharmonic(with other: Pitch) -> Bool { midi == other.midi }

    /// Transposes with correct spelling: E4 up m3 = G4, C4 down P5 = F3.
    func transposed(by interval: Interval, down: Bool = false) -> Pitch {
        let steps = (interval.number - 1) * (down ? -1 : 1)
        let index = diatonicIndex + steps
        let newOctave = Int((Double(index) / 7).rounded(.down))
        let newLetter = NoteLetter(rawValue: index - newOctave * 7)!
        let targetMIDI = midi + interval.semitones * (down ? -1 : 1)
        let naturalMIDI = (newOctave + 1) * 12 + newLetter.naturalPitchClass
        return Pitch(SpelledNote(newLetter, targetMIDI - naturalMIDI), octave: newOctave)
    }

    /// Pitch `semitones` away, respelled with common names.
    func transposed(semitones: Int, preferSharps: Bool = true) -> Pitch {
        Pitch(midi: midi + semitones, preferSharps: preferSharps)
    }

    static func < (lhs: Pitch, rhs: Pitch) -> Bool {
        lhs.midi != rhs.midi ? lhs.midi < rhs.midi : lhs.diatonicIndex < rhs.diatonicIndex
    }

    static let middleC = Pitch(.C, octave: 4)
    static let a440 = Pitch(.A, octave: 4)
}

extension Pitch: Codable {
    init(from decoder: Decoder) throws {
        self = try decoder.singleValueContainer().decodeTheoryString { try Pitch(parsing: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}
