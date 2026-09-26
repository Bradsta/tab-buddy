//
//  Chord.swift
//  TabBuddy
//
//  Chord qualities, spelled chord tones, and a chord-symbol parser. Tones are
//  stacked from the root by interval, so Bbm7b5 = Bb Db Fb Ab and F#dim7 =
//  F# A C Eb.
//

import Foundation

enum ChordQuality: String, CaseIterable, Codable, Hashable, Sendable {
    case major = "maj"
    case minor = "min"
    case diminished = "dim"
    case augmented = "aug"
    case sus2
    case sus4
    case power = "5"
    case sixth = "6"
    case minorSixth = "m6"
    case dominantSeventh = "7"
    case majorSeventh = "maj7"
    case minorSeventh = "m7"
    case halfDiminishedSeventh = "m7b5"
    case diminishedSeventh = "dim7"
    case addNine = "add9"
    case dominantNinth = "9"
    case minorNinth = "m9"
    case majorNinth = "maj9"
    case dominantSeventhSus4 = "7sus4"

    /// Intervals above the root, in stacking order.
    var intervals: [Interval] {
        switch self {
        case .major: return [.P1, .M3, .P5]
        case .minor: return [.P1, .m3, .P5]
        case .diminished: return [.P1, .m3, .d5]
        case .augmented: return [.P1, .M3, .A5]
        case .sus2: return [.P1, .M2, .P5]
        case .sus4: return [.P1, .P4, .P5]
        case .power: return [.P1, .P5]
        case .sixth: return [.P1, .M3, .P5, .M6]
        case .minorSixth: return [.P1, .m3, .P5, .M6]
        case .dominantSeventh: return [.P1, .M3, .P5, .m7]
        case .majorSeventh: return [.P1, .M3, .P5, .M7]
        case .minorSeventh: return [.P1, .m3, .P5, .m7]
        case .halfDiminishedSeventh: return [.P1, .m3, .d5, .m7]
        case .diminishedSeventh: return [.P1, .m3, .d5, .d7]
        case .addNine: return [.P1, .M3, .P5, .M9]
        case .dominantNinth: return [.P1, .M3, .P5, .m7, .M9]
        case .minorNinth: return [.P1, .m3, .P5, .m7, .M9]
        case .majorNinth: return [.P1, .M3, .P5, .M7, .M9]
        case .dominantSeventhSus4: return [.P1, .P4, .P5, .m7]
        }
    }

    /// Suffix written after the root in a chord symbol ("" for major, "m" for minor).
    var symbolSuffix: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        default: return rawValue
        }
    }

    /// Prose name: "major", "minor seventh", "half-diminished seventh".
    var name: String {
        switch self {
        case .major: return "major"
        case .minor: return "minor"
        case .diminished: return "diminished"
        case .augmented: return "augmented"
        case .sus2: return "suspended second"
        case .sus4: return "suspended fourth"
        case .power: return "power chord"
        case .sixth: return "major sixth"
        case .minorSixth: return "minor sixth"
        case .dominantSeventh: return "dominant seventh"
        case .majorSeventh: return "major seventh"
        case .minorSeventh: return "minor seventh"
        case .halfDiminishedSeventh: return "half-diminished seventh"
        case .diminishedSeventh: return "diminished seventh"
        case .addNine: return "added ninth"
        case .dominantNinth: return "dominant ninth"
        case .minorNinth: return "minor ninth"
        case .majorNinth: return "major ninth"
        case .dominantSeventhSus4: return "dominant seventh suspended fourth"
        }
    }

    /// True when the chord has a minor third above the root.
    var hasMinorThird: Bool { intervals.contains(.m3) }

    var isTriad: Bool { [.major, .minor, .diminished, .augmented].contains(self) }

    /// Suffix → quality. Case matters: "M7" = major seventh, "m7" = minor seventh.
    fileprivate static let suffixes: [String: ChordQuality] = [
        "": .major, "M": .major, "maj": .major, "major": .major, "Maj": .major,
        "m": .minor, "min": .minor, "minor": .minor, "-": .minor, "mi": .minor,
        "dim": .diminished, "°": .diminished, "o": .diminished, "º": .diminished,
        "aug": .augmented, "+": .augmented, "#5": .augmented, "(#5)": .augmented,
        "sus2": .sus2, "sus4": .sus4, "sus": .sus4,
        "5": .power, "(no3)": .power,
        "6": .sixth, "maj6": .sixth, "M6": .sixth,
        "m6": .minorSixth, "min6": .minorSixth, "-6": .minorSixth,
        "7": .dominantSeventh, "dom7": .dominantSeventh,
        "maj7": .majorSeventh, "M7": .majorSeventh, "Maj7": .majorSeventh, "ma7": .majorSeventh,
        "Δ": .majorSeventh, "Δ7": .majorSeventh, "∆": .majorSeventh, "∆7": .majorSeventh,
        "m7": .minorSeventh, "min7": .minorSeventh, "-7": .minorSeventh, "mi7": .minorSeventh,
        "m7b5": .halfDiminishedSeventh, "m7(b5)": .halfDiminishedSeventh, "min7b5": .halfDiminishedSeventh,
        "-7b5": .halfDiminishedSeventh, "ø": .halfDiminishedSeventh, "ø7": .halfDiminishedSeventh,
        "m7♭5": .halfDiminishedSeventh, "-7♭5": .halfDiminishedSeventh,
        "dim7": .diminishedSeventh, "°7": .diminishedSeventh, "o7": .diminishedSeventh, "º7": .diminishedSeventh,
        "add9": .addNine, "add2": .addNine, "(add9)": .addNine,
        "9": .dominantNinth,
        "m9": .minorNinth, "min9": .minorNinth, "-9": .minorNinth,
        "maj9": .majorNinth, "M9": .majorNinth, "Maj9": .majorNinth, "Δ9": .majorNinth, "∆9": .majorNinth,
        "7sus4": .dominantSeventhSus4, "7sus": .dominantSeventhSus4,
    ]

    /// Parses a symbol suffix ("m7", "M7", "-7", "ø7", "sus"). Nil if unknown.
    init?(suffix: String) {
        guard let q = Self.suffixes[suffix] else { return nil }
        self = q
    }

    /// Quality whose intervals match exactly (compared by semitones above the root).
    static func matching(semitones: Set<Int>) -> ChordQuality? {
        allCases.first { Set($0.intervals.map { $0.semitones % 12 }) == semitones }
    }
}

/// A chord: spelled root, quality, and optional bass for slash chords.
/// Encodes as its symbol ("Am7", "C/G").
struct Chord: Hashable, Sendable, CustomStringConvertible {
    var root: SpelledNote
    var quality: ChordQuality
    /// Bass note of a slash chord; nil = root in the bass.
    var bass: SpelledNote?

    init(root: SpelledNote, quality: ChordQuality = .major, bass: SpelledNote? = nil) {
        self.root = root
        self.quality = quality
        self.bass = bass == root ? nil : bass
    }

    /// Parses symbols like "A", "Am", "A7", "Amaj7", "AM7", "A-7", "Asus4", "A5",
    /// "C/G", "D/F#", "Bbm7b5", "F#dim7", "Bø7", "C°", "Caug", "C+", "Cadd9".
    init(parsing string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        func fail(_ reason: String) -> TheoryParseError {
            TheoryParseError(kind: .chord, input: string, reason: reason)
        }
        guard !trimmed.isEmpty else { throw fail("empty chord symbol") }
        var main = Substring(trimmed)
        var bass: SpelledNote?
        if let slash = trimmed.lastIndex(of: "/") {
            let bassText = String(trimmed[trimmed.index(after: slash)...])
            guard let b = SpelledNote(bassText) else {
                throw fail("bass note after \"/\" must be a note name, got \"\(bassText)\"")
            }
            bass = b
            main = trimmed[..<slash]
        }
        guard let first = main.first, let letter = NoteLetter(character: first), first.isUppercase else {
            throw fail("a chord symbol starts with an uppercase root letter A–G")
        }
        var rest = main.dropFirst()
        var accidental = 0
        while let c = rest.first {
            if c == "#" || c == "♯" { accidental += 1 } else if c == "b" || c == "♭" { accidental -= 1 } else { break }
            rest = rest.dropFirst()
        }
        guard abs(accidental) <= 2 else { throw fail("too many accidentals on the root") }
        let suffix = String(rest).replacingOccurrences(of: " ", with: "")
        guard let quality = ChordQuality(suffix: suffix) else {
            throw fail("unknown chord suffix \"\(suffix)\"; supported: m, dim, aug, sus2, sus4, 5, 6, m6, 7, maj7 (M7), m7 (-7), m7b5 (ø7), dim7, add9, 9, m9, maj9, 7sus4")
        }
        self.init(root: SpelledNote(letter, accidental), quality: quality, bass: bass)
    }

    init?(_ string: String) { try? self.init(parsing: string) }

    /// Canonical symbol: "Am7", "Bbm7b5", "C/G".
    var symbol: String {
        root.name + quality.symbolSuffix + (bass.map { "/" + $0.name } ?? "")
    }

    /// Symbol with music symbols: "B♭m7♭5", "F♯dim7", "D/F♯".
    var displaySymbol: String {
        root.displayName + quality.symbolSuffix.replacingOccurrences(of: "b5", with: "♭5")
            + (bass.map { "/" + $0.displayName } ?? "")
    }

    var description: String { symbol }

    /// "A minor seventh", "C major over G".
    var name: String {
        root.displayName + " " + quality.name + (bass.map { " over " + $0.displayName } ?? "")
    }

    /// Spelled chord tones from the root (bass not included unless it is a chord tone).
    var tones: [SpelledNote] { quality.intervals.map { root.transposed(by: $0) } }

    /// Chord tones plus the bass.
    var pitchClasses: Set<PitchClass> {
        var set = Set(tones.map(\.pitchClass))
        if let bass { set.insert(bass.pitchClass) }
        return set
    }

    /// 0 = root position, 1 = third in bass, 2 = fifth, 3 = seventh; nil if the
    /// bass is not a chord tone.
    var inversion: Int? {
        guard let bass else { return 0 }
        guard let i = tones.firstIndex(of: bass) else { return nil }
        return i
    }

    /// Chord with the given tone (index into `tones`) in the bass.
    func inverted(_ inversion: Int) -> Chord {
        let t = tones
        guard inversion > 0, inversion < t.count else { return Chord(root: root, quality: quality) }
        return Chord(root: root, quality: quality, bass: t[inversion])
    }

    /// Close-position pitches with the root in `rootOctave`; a slash bass sits
    /// below the root.
    func pitches(rootOctave: Int = 3) -> [Pitch] {
        let r = Pitch(root, octave: rootOctave)
        var result = quality.intervals.map { r.transposed(by: $0) }
        if let bass {
            var b = Pitch(bass, octave: rootOctave)
            while b.midi >= r.midi { b = Pitch(bass, octave: b.octave - 1) }
            result.insert(b, at: 0)
        }
        return result
    }

    func midiNotes(rootOctave: Int = 3) -> [Int] { pitches(rootOctave: rootOctave).map(\.midi) }

    func transposed(by interval: Interval, down: Bool = false) -> Chord {
        Chord(root: root.transposed(by: interval, down: down), quality: quality,
              bass: bass?.transposed(by: interval, down: down))
    }

    /// Chords whose tones equal `pitchClasses` exactly, named with common spellings.
    /// A given `bass` produces a slash chord when it is not the root.
    static func identify(pitchClasses: Set<PitchClass>, bass: PitchClass? = nil, preferSharps: Bool = true) -> [Chord] {
        var result: [Chord] = []
        for rootPC in pitchClasses.sorted() {
            let semis = Set(pitchClasses.map { rootPC.semitones(upTo: $0) })
            guard let q = ChordQuality.matching(semitones: semis) else { continue }
            let root = SpelledNote.common(for: rootPC, preferSharps: preferSharps)
            let chord = Chord(root: root, quality: q)
            var bassNote: SpelledNote?
            if let bass, bass != rootPC {
                bassNote = chord.tones.first { $0.pitchClass == bass }
            }
            result.append(Chord(root: root, quality: q, bass: bassNote))
        }
        // Prefer the bass as root, then simpler qualities.
        let order = ChordQuality.allCases
        return result.sorted {
            let a = $0.root.pitchClass == bass, b = $1.root.pitchClass == bass
            if a != b { return a }
            return order.firstIndex(of: $0.quality)! < order.firstIndex(of: $1.quality)!
        }
    }

    static func identify(midi: [Int], preferSharps: Bool = true) -> [Chord] {
        guard let low = midi.min() else { return [] }
        return identify(pitchClasses: Set(midi.map { PitchClass($0) }), bass: PitchClass(low), preferSharps: preferSharps)
    }
}

extension Chord: Codable {
    init(from decoder: Decoder) throws {
        self = try decoder.singleValueContainer().decodeTheoryString { try Chord(parsing: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(symbol)
    }
}
