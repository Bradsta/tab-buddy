//
//  Key.swift
//  TabBuddy
//
//  Major and minor keys: signatures, diatonic chords, Roman numerals, and the
//  circle of fifths. Minor keys use the natural minor scale for their diatonic
//  chords; Roman-numeral parsing also accepts the harmonic-minor V, V7, vii°,
//  and vii°7 (raised leading tone).
//

import Foundation

enum KeyMode: String, CaseIterable, Codable, Hashable, Sendable {
    case major, minor
}

struct KeySignature: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Sharps positive, flats negative (D major = 2, Eb major = -3).
    var fifths: Int

    var sharps: Int { max(0, fifths) }
    var flats: Int { max(0, -fifths) }

    /// Order in which sharps are added (F C G D A E B); flats use the reverse.
    static let sharpOrder: [NoteLetter] = [.F, .C, .G, .D, .A, .E, .B]
    static let flatOrder: [NoteLetter] = [.B, .E, .A, .D, .G, .C, .F]

    /// Accidental the signature applies to a letter (+1 sharp, -1 flat, ±2 in theoretical keys).
    func accidental(for letter: NoteLetter) -> Int {
        if fifths >= 0 {
            let i = Self.sharpOrder.firstIndex(of: letter)!
            return fifths / 7 + (i < fifths % 7 ? 1 : 0)
        } else {
            let n = -fifths
            let i = Self.flatOrder.firstIndex(of: letter)!
            return -(n / 7 + (i < n % 7 ? 1 : 0))
        }
    }

    /// Altered notes in signature order: [F#, C#] for D major, [Bb, Eb, Ab] for Eb major.
    var accidentals: [SpelledNote] {
        let order = fifths >= 0 ? Self.sharpOrder : Self.flatOrder
        let count = min(7, abs(fifths))
        var result = order.prefix(count).map { SpelledNote($0, accidental(for: $0)) }
        if abs(fifths) > 7 {
            // Theoretical keys: letters with double accidentals, in the same order.
            result = order.compactMap { l in
                let a = accidental(for: l)
                return a == 0 ? nil : SpelledNote(l, a)
            }
        }
        return result
    }

    /// "no sharps or flats", "1 sharp", "3 flats".
    var description: String {
        switch fifths {
        case 0: return "no sharps or flats"
        case 1: return "1 sharp"
        case -1: return "1 flat"
        case let f where f > 0: return "\(f) sharps"
        default: return "\(-fifths) flats"
        }
    }
}

/// A key: tonic plus mode. Encodes as "G major" / "E minor".
struct Key: Hashable, Sendable, CustomStringConvertible {
    var tonic: SpelledNote
    var mode: KeyMode

    init(tonic: SpelledNote, mode: KeyMode = .major) {
        self.tonic = tonic
        self.mode = mode
    }

    /// Parses "G major", "E minor", "Bb major", "F# minor", "C# min", "Eb maj",
    /// and chord-style short forms "G", "Em", "Bbm". Case-insensitive mode words.
    init(parsing string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        func fail(_ reason: String) -> TheoryParseError {
            TheoryParseError(kind: .key, input: string, reason: reason)
        }
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { throw fail("expected \"<tonic> major\" or \"<tonic> minor\"") }
        var tonicText = parts[0]
        var mode = KeyMode.major
        if parts.count == 1 {
            // Short form: "Em", "Bbm", "F#m", "G".
            if tonicText.count > 1, tonicText.hasSuffix("m") {
                tonicText = String(tonicText.dropLast())
                mode = .minor
            }
        } else if parts.count == 2 {
            switch parts[1].lowercased() {
            case "major", "maj", "ionian": mode = .major
            case "minor", "min", "aeolian": mode = .minor
            default: throw fail("mode must be \"major\" or \"minor\", got \"\(parts[1])\"")
            }
        } else {
            throw fail("expected \"<tonic> major\" or \"<tonic> minor\"")
        }
        guard let tonic = SpelledNote(tonicText) else {
            throw fail("tonic \"\(tonicText)\" is not a note name")
        }
        self.init(tonic: tonic, mode: mode)
    }

    init?(_ string: String) { try? self.init(parsing: string) }

    var name: String { "\(tonic.name) \(mode.rawValue)" }
    var displayName: String { "\(tonic.displayName) \(mode.rawValue)" }
    var description: String { name }

    var signature: KeySignature {
        KeySignature(fifths: tonic.fifthsFromC - (mode == .minor ? 3 : 0))
    }

    /// Keys needing more than seven sharps or flats (G# major, Fb major, D# minor is fine).
    var isTheoretical: Bool { abs(signature.fifths) > 7 }

    /// Major scale or natural minor scale.
    var scale: Scale { Scale(root: tonic, type: mode == .major ? .major : .naturalMinor) }

    var relative: Key {
        mode == .major ? Key(tonic: tonic.transposed(by: .M6), mode: .minor)
                       : Key(tonic: tonic.transposed(by: .m3), mode: .major)
    }

    var parallel: Key { Key(tonic: tonic, mode: mode == .major ? .minor : .major) }

    /// Key a fifth above (one more sharp).
    var dominant: Key { Key(tonic: tonic.transposed(by: .P5), mode: mode) }
    /// Key a fifth below (one more flat).
    var subdominant: Key { Key(tonic: tonic.transposed(by: .P4), mode: mode) }

    // MARK: Diatonic chords

    /// Triads on each scale degree (C major: C Dm Em F G Am Bdim; A minor: Am Bdim C Dm Em F G).
    var diatonicTriads: [Chord] { diatonicChords(size: 3) }

    /// Seventh chords on each degree (C major: Cmaj7 Dm7 Em7 Fmaj7 G7 Am7 Bm7b5).
    var diatonicSevenths: [Chord] { diatonicChords(size: 4) }

    private func diatonicChords(size: Int) -> [Chord] {
        let notes = scale.notes
        return (0..<7).map { i in
            let root = notes[i]
            let stack = (0..<size).map { notes[(i + 2 * $0) % 7] }
            let semis = Set(stack.map { root.pitchClass.semitones(upTo: $0.pitchClass) })
            let quality = ChordQuality.matching(semitones: semis) ?? .major
            return Chord(root: root, quality: quality)
        }
    }

    /// Roman numerals for `diatonicTriads` (I ii iii IV V vi vii°).
    var triadNumerals: [String] { diatonicTriads.map { romanNumeral(for: $0) ?? "?" } }
    var seventhNumerals: [String] { diatonicSevenths.map { romanNumeral(for: $0) ?? "?" } }

    // MARK: Roman numerals

    private static let numerals = ["I", "II", "III", "IV", "V", "VI", "VII"]

    private static let dimFamily: Set<ChordQuality> = [.diminished, .diminishedSeventh, .halfDiminishedSeventh]

    /// Roman numeral for a chord in this key: "V7", "ii", "vii°", "bVII", "iiø7".
    /// Accidental prefixes are relative to this key's scale (natural minor for
    /// minor keys), except the raised leading-tone diminished chords in minor
    /// ("vii°", "vii°7", "viiø7"). The slash bass is ignored. Nil when the root
    /// is more than one semitone from a scale degree.
    func romanNumeral(for chord: Chord) -> String? {
        let notes = scale.notes
        guard let degree = notes.firstIndex(where: { $0.letter == chord.root.letter }) else { return nil }
        let diff = chord.root.accidental - notes[degree].accidental
        guard abs(diff) <= 1 else { return nil }
        let q = chord.quality
        var prefix = diff > 0 ? "#" : (diff < 0 ? "b" : "")
        if mode == .minor, degree == 6, diff == 1, Self.dimFamily.contains(q) { prefix = "" }
        let base = Self.numerals[degree]
        let numeral = q.hasMinorThird ? base.lowercased() : base
        return prefix + numeral + Self.romanSuffix(for: q)
    }

    private static func romanSuffix(for q: ChordQuality) -> String {
        switch q {
        case .major, .minor: return ""
        case .diminished: return "°"
        case .augmented: return "+"
        case .dominantSeventh, .minorSeventh: return "7"
        case .majorSeventh: return "maj7"
        case .halfDiminishedSeventh: return "ø7"
        case .diminishedSeventh: return "°7"
        case .sixth, .minorSixth: return "6"
        case .dominantNinth, .minorNinth: return "9"
        case .majorNinth: return "maj9"
        default: return q.rawValue
        }
    }

    /// Chord for a Roman numeral: "I", "ii", "V7", "vii°", "viiø7", "bVII",
    /// "IVmaj7", "iii7", "V/…" is not supported. Case sets the third (upper =
    /// major, lower = minor); suffixes: ° o dim, + aug, 7, maj7 M7 Δ7, ø7 ø m7b5,
    /// °7 o7 dim7, 6, 9, maj9, sus2, sus4, 5, add9, 7sus4. Figured-bass
    /// inversions (6, 64) are not supported; "6" means an added sixth.
    func chord(forRoman text: String) throws -> Chord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func fail(_ reason: String) -> TheoryParseError {
            TheoryParseError(kind: .romanNumeral, input: text, reason: reason)
        }
        var rest = Substring(trimmed)
        var accidental = 0
        while let c = rest.first, "b#♭♯".contains(c) {
            accidental += (c == "#" || c == "♯") ? 1 : -1
            rest = rest.dropFirst()
        }
        var numeralText = ""
        while let c = rest.first, "IViv".contains(c) {
            numeralText.append(c)
            rest = rest.dropFirst()
        }
        guard let degree = Self.numerals.firstIndex(of: numeralText.uppercased()) else {
            throw fail("expected a Roman numeral I–VII (upper case = major, lower case = minor)")
        }
        let isUpper = numeralText == numeralText.uppercased()
        guard isUpper || numeralText == numeralText.lowercased() else {
            throw fail("mixed-case numeral; write \"\(numeralText.uppercased())\" or \"\(numeralText.lowercased())\"")
        }
        let suffix = String(rest)
        let quality: ChordQuality?
        if isUpper {
            switch suffix {
            case "": quality = .major
            case "+", "aug": quality = .augmented
            case "7": quality = .dominantSeventh
            case "maj7", "M7", "Δ7", "Δ", "∆7", "∆": quality = .majorSeventh
            case "6": quality = .sixth
            case "9": quality = .dominantNinth
            case "maj9", "M9": quality = .majorNinth
            case "sus2": quality = .sus2
            case "sus4", "sus": quality = .sus4
            case "5": quality = .power
            case "add9": quality = .addNine
            case "7sus4": quality = .dominantSeventhSus4
            default: quality = nil
            }
        } else {
            switch suffix {
            case "": quality = .minor
            case "°", "o", "dim", "º": quality = .diminished
            case "7": quality = .minorSeventh
            case "ø7", "ø", "m7b5", "7b5": quality = .halfDiminishedSeventh
            case "°7", "o7", "dim7", "º7": quality = .diminishedSeventh
            case "6": quality = .minorSixth
            case "9": quality = .minorNinth
            default: quality = nil
            }
        }
        guard let quality else {
            throw fail("unsupported suffix \"\(suffix)\" for \(isUpper ? "an upper-case" : "a lower-case") numeral")
        }
        var root = scale.notes[degree]
        root.accidental += accidental
        if mode == .minor, degree == 6, accidental == 0, Self.dimFamily.contains(quality) {
            root.accidental += 1 // leading tone of harmonic minor
        }
        guard abs(root.accidental) <= 2 else { throw fail("root needs more than a double accidental") }
        return Chord(root: root, quality: quality)
    }

    // MARK: Spelling

    /// Spells a pitch class in this key: diatonic notes as in the scale; in minor,
    /// the raised 6th and 7th; otherwise the neighbour spelling with the smaller
    /// accidental, breaking ties toward the key's side (sharps for sharp keys,
    /// flats for flat keys; C major / A minor use C#, Eb, F#, G#, Bb).
    func spell(_ pc: PitchClass) -> SpelledNote {
        let notes = scale.notes
        if let n = notes.first(where: { $0.pitchClass == pc }) { return n }
        if mode == .minor {
            for i in [5, 6] {
                var raised = notes[i]
                raised.accidental += 1
                if raised.pitchClass == pc { return raised }
            }
        }
        let fifths = signature.fifths
        if fifths == 0 {
            let table: [Int: SpelledNote] = [1: .init(.C, 1), 3: .init(.E, -1), 6: .init(.F, 1),
                                             8: .init(.G, 1), 10: .init(.B, -1)]
            if let n = table[pc.value] { return n }
        }
        // Candidates: raise the scale note below or lower the scale note above.
        let below = notes.first { $0.pitchClass == pc.transposed(by: -1) }.map { SpelledNote($0.letter, $0.accidental + 1) }
        let above = notes.first { $0.pitchClass == pc.transposed(by: 1) }.map { SpelledNote($0.letter, $0.accidental - 1) }
        switch (below, above) {
        case let (b?, a?):
            if abs(b.accidental) != abs(a.accidental) { return abs(b.accidental) < abs(a.accidental) ? b : a }
            return fifths >= 0 ? b : a
        case let (b?, nil): return b
        case let (nil, a?): return a
        default: return SpelledNote.common(for: pc, preferSharps: fifths >= 0)
        }
    }

    // MARK: Circle of fifths

    /// Twelve keys clockwise from C (majors: C G D A E B F# Db Ab Eb Bb F;
    /// minors: A E B F# C# G# D# Bb F C G D), each paired with its relative.
    static func circleOfFifths(mode: KeyMode = .major) -> [Key] {
        let majors = ["C", "G", "D", "A", "E", "B", "F#", "Db", "Ab", "Eb", "Bb", "F"]
            .map { Key(tonic: SpelledNote($0)!, mode: .major) }
        return mode == .major ? majors : majors.map(\.relative)
    }

    /// The 15 conventional keys of a mode, from 7 flats to 7 sharps.
    static func allKeys(mode: KeyMode) -> [Key] {
        let majors = ["Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#"]
            .map { Key(tonic: SpelledNote($0)!, mode: .major) }
        return mode == .major ? majors : majors.map(\.relative)
    }

    /// Key with the given signature (fifths -7...7) and mode.
    init?(fifths: Int, mode: KeyMode) {
        guard let k = Self.allKeys(mode: mode).first(where: { $0.signature.fifths == fifths }) else { return nil }
        self = k
    }

    /// Enharmonically equivalent conventional key (F# major ↔ Gb major), if any.
    var enharmonicEquivalent: Key? {
        Self.allKeys(mode: mode).first { $0.tonic != tonic && $0.tonic.pitchClass == tonic.pitchClass }
    }
}

extension Key: Codable {
    init(from decoder: Decoder) throws {
        self = try decoder.singleValueContainer().decodeTheoryString { try Key(parsing: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}
