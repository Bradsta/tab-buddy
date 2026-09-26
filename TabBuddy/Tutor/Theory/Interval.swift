//
//  Interval.swift
//  TabBuddy
//
//  Intervals as quality + number (P1 … M13, up to a double octave). Spelled
//  transposition moves the letter by the number and fixes the accidental from
//  the semitone count, so C + M3 = E, E + m3 = G, F# + M3 = A#.
//

import Foundation

enum IntervalQuality: String, CaseIterable, Codable, Hashable, Sendable {
    case diminished = "d"
    case minor = "m"
    case perfect = "P"
    case major = "M"
    case augmented = "A"

    var name: String {
        switch self {
        case .diminished: return "diminished"
        case .minor: return "minor"
        case .perfect: return "perfect"
        case .major: return "major"
        case .augmented: return "augmented"
        }
    }
}

/// Encodes as its short name ("M3").
struct Interval: Hashable, Sendable, CustomStringConvertible {
    let quality: IntervalQuality
    /// 1 = unison, 8 = octave, up to 15 (double octave).
    let number: Int

    /// Returns nil for combinations that do not exist (e.g. "M5", "P3").
    init?(quality: IntervalQuality, number: Int) {
        guard (1...15).contains(number) else { return nil }
        let perfectType = Self.isPerfectType(number)
        switch quality {
        case .perfect: guard perfectType else { return nil }
        case .major, .minor: guard !perfectType else { return nil }
        case .diminished: guard number != 1 else { return nil }
        case .augmented: break
        }
        self.quality = quality
        self.number = number
    }

    private init(unchecked quality: IntervalQuality, _ number: Int) {
        self.quality = quality
        self.number = number
    }

    static func isPerfectType(_ number: Int) -> Bool { [1, 4, 5].contains((number - 1) % 7 + 1) }

    /// Unison … seventh (1...7) of the reduced interval.
    var simpleNumber: Int { (number - 1) % 7 + 1 }
    var isCompound: Bool { number > 8 }

    var semitones: Int {
        let base = [0, 2, 4, 5, 7, 9, 11][simpleNumber - 1] + 12 * ((number - 1) / 7)
        switch quality {
        case .perfect, .major: return base
        case .minor: return base - 1
        case .augmented: return base + 1
        case .diminished: return base - (Self.isPerfectType(number) ? 1 : 2)
        }
    }

    /// Letter steps spanned (number - 1).
    var diatonicSteps: Int { number - 1 }

    /// "M3", "P5", "m7", "A4", "d5".
    var shortName: String { quality.rawValue + String(number) }
    var description: String { shortName }

    /// "major third", "perfect fifth", "augmented fourth".
    var name: String { "\(quality.name) \(Self.ordinal(number))" }

    /// Everyday alternative, e.g. "tritone" for A4/d5.
    var alternateName: String? {
        if (quality == .augmented && number == 4) || (quality == .diminished && number == 5) { return "tritone" }
        if quality == .minor && number == 2 { return "half step" }
        if quality == .major && number == 2 { return "whole step" }
        return nil
    }

    static func ordinal(_ number: Int) -> String {
        ["unison", "second", "third", "fourth", "fifth", "sixth", "seventh", "octave",
         "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "double octave"][number - 1]
    }

    /// Inversion within the octave (M3 ↔ m6, P4 ↔ P5, A4 ↔ d5). Compound intervals are reduced first.
    var inverted: Interval {
        let simple = number == 1 ? 1 : ((number - 1) % 7 == 0 ? 8 : simpleNumber)
        let q: IntervalQuality
        switch quality {
        case .perfect: q = .perfect
        case .major: q = .minor
        case .minor: q = .major
        case .augmented: q = .diminished
        case .diminished: q = .augmented
        }
        let n = 9 - simple
        return Interval(quality: q, number: n) ?? Interval(unchecked: q, n)
    }

    /// Reduced to within an octave (M9 → M2). Octaves stay P8.
    var simple: Interval {
        guard number > 8 else { return self }
        let n = simpleNumber == 1 ? 8 : simpleNumber
        return Interval(quality: quality, number: n) ?? self
    }

    // MARK: Constants

    static let P1 = Interval(unchecked: .perfect, 1)
    static let A1 = Interval(unchecked: .augmented, 1)
    static let m2 = Interval(unchecked: .minor, 2)
    static let M2 = Interval(unchecked: .major, 2)
    static let A2 = Interval(unchecked: .augmented, 2)
    static let m3 = Interval(unchecked: .minor, 3)
    static let M3 = Interval(unchecked: .major, 3)
    static let d4 = Interval(unchecked: .diminished, 4)
    static let P4 = Interval(unchecked: .perfect, 4)
    static let A4 = Interval(unchecked: .augmented, 4)
    static let d5 = Interval(unchecked: .diminished, 5)
    static let P5 = Interval(unchecked: .perfect, 5)
    static let A5 = Interval(unchecked: .augmented, 5)
    static let m6 = Interval(unchecked: .minor, 6)
    static let M6 = Interval(unchecked: .major, 6)
    static let A6 = Interval(unchecked: .augmented, 6)
    static let d7 = Interval(unchecked: .diminished, 7)
    static let m7 = Interval(unchecked: .minor, 7)
    static let M7 = Interval(unchecked: .major, 7)
    static let P8 = Interval(unchecked: .perfect, 8)
    static let m9 = Interval(unchecked: .minor, 9)
    static let M9 = Interval(unchecked: .major, 9)
    static let A9 = Interval(unchecked: .augmented, 9)
    static let P11 = Interval(unchecked: .perfect, 11)
    static let A11 = Interval(unchecked: .augmented, 11)
    static let m13 = Interval(unchecked: .minor, 13)
    static let M13 = Interval(unchecked: .major, 13)

    /// The simple intervals a beginner course names, in semitone order (tritone as A4).
    static let common: [Interval] = [.P1, .m2, .M2, .m3, .M3, .P4, .A4, .P5, .m6, .M6, .m7, .M7, .P8]

    /// Default spelling for a semitone count 0...12 (6 = A4 unless `tritoneAsD5`).
    static func standard(semitones: Int, tritoneAsD5: Bool = false) -> Interval? {
        guard (0...12).contains(semitones) else { return nil }
        if semitones == 6 && tritoneAsD5 { return .d5 }
        return common[semitones]
    }

    // MARK: Measuring

    /// Ascending interval from `lower` up to `upper` within one octave (C → E = M3,
    /// E → C = m6). Nil if the spelling gives no named quality.
    static func between(_ lower: SpelledNote, _ upper: SpelledNote) -> Interval? {
        let steps = ((upper.letter.rawValue - lower.letter.rawValue) % 7 + 7) % 7
        let semis = ((upper.pitchClass.value - lower.pitchClass.value) % 12 + 12) % 12
        return from(steps: steps, semitones: semis, wrapSemitones: true)
    }

    /// Interval between two pitches (compound when wider than an octave). Order-independent.
    static func between(_ a: Pitch, _ b: Pitch) -> Interval? {
        let (lo, hi) = a.diatonicIndex <= b.diatonicIndex ? (a, b) : (b, a)
        return from(steps: hi.diatonicIndex - lo.diatonicIndex, semitones: hi.midi - lo.midi, wrapSemitones: false)
    }

    private static func from(steps: Int, semitones: Int, wrapSemitones: Bool) -> Interval? {
        let number = steps + 1
        guard (1...15).contains(number) else { return nil }
        let base = [0, 2, 4, 5, 7, 9, 11][steps % 7] + 12 * (steps / 7)
        var diff = semitones - base
        if wrapSemitones {
            diff = ((diff % 12) + 12) % 12
            if diff > 6 { diff -= 12 }
        }
        let quality: IntervalQuality
        if isPerfectType(number) {
            switch diff {
            case -1: quality = .diminished
            case 0: quality = .perfect
            case 1: quality = .augmented
            default: return nil
            }
        } else {
            switch diff {
            case -2: quality = .diminished
            case -1: quality = .minor
            case 0: quality = .major
            case 1: quality = .augmented
            default: return nil
            }
        }
        return Interval(quality: quality, number: number)
    }

    // MARK: Parsing

    /// Parses short names ("M3", "P5", "m7", "A4", "d5"), long abbreviations
    /// ("maj3", "min7", "aug4", "dim5", "perf5"), and words ("major third",
    /// "perfect 5th", "tritone", "octave", "unison", "half step", "whole step").
    init(parsing string: String) throws {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        switch lower {
        case "tritone", "tt": self = .A4; return
        case "octave": self = .P8; return
        case "unison": self = .P1; return
        case "half step", "semitone": self = .m2; return
        case "whole step", "whole tone", "tone": self = .M2; return
        default: break
        }
        func fail(_ reason: String) -> TheoryParseError {
            TheoryParseError(kind: .interval, input: string, reason: reason)
        }
        // Short form: quality letter(s) followed by a number. "M" and "m" are case-sensitive.
        var qualityText = ""
        var numberText = ""
        for ch in raw where !ch.isWhitespace {
            if ch.isNumber { numberText.append(ch) } else if numberText.isEmpty { qualityText.append(ch) } else {
                qualityText = "?" // letters after digits: try the word form below
                break
            }
        }
        if qualityText != "?", let n = Int(numberText) {
            let q: IntervalQuality?
            switch qualityText {
            case "P", "p", "perf", "perfect": q = .perfect
            case "M", "maj", "Maj", "major": q = .major
            case "m", "min", "Min", "minor": q = .minor
            case "A", "aug", "Aug", "augmented", "+": q = .augmented
            case "d", "dim", "Dim", "diminished", "°": q = .diminished
            default: q = nil
            }
            guard let q else { throw fail("unknown quality \"\(qualityText)\"; use P, M, m, A, or d") }
            guard let interval = Interval(quality: q, number: n) else {
                throw fail("\(q.name) \(n) does not exist (1, 4, 5, 8 take P/A/d; 2, 3, 6, 7 take M/m/A/d; max 15)")
            }
            self = interval
            return
        }
        // Word form: "<quality> <ordinal>".
        let words = lower.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard words.count == 2 else {
            throw fail("expected a name like \"M3\", \"P5\", \"m7\", or \"major third\"")
        }
        let qMap: [String: IntervalQuality] = ["perfect": .perfect, "major": .major, "minor": .minor,
                                               "augmented": .augmented, "diminished": .diminished]
        let ordinals = ["unison": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4,
                        "fifth": 5, "5th": 5, "sixth": 6, "6th": 6, "seventh": 7, "7th": 7, "octave": 8, "8th": 8,
                        "ninth": 9, "9th": 9, "tenth": 10, "10th": 10, "eleventh": 11, "11th": 11,
                        "twelfth": 12, "12th": 12, "thirteenth": 13, "13th": 13]
        guard let q = qMap[words[0]] else { throw fail("unknown quality \"\(words[0])\"") }
        guard let n = ordinals[words[1]] else { throw fail("unknown interval size \"\(words[1])\"") }
        guard let interval = Interval(quality: q, number: n) else {
            throw fail("\(q.name) \(Self.ordinal(n)) does not exist")
        }
        self = interval
    }

    init?(_ string: String) { try? self.init(parsing: string) }
}

extension Interval: Codable {
    init(from decoder: Decoder) throws {
        self = try decoder.singleValueContainer().decodeTheoryString { try Interval(parsing: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(shortName)
    }
}

// MARK: - Spelled transposition

extension SpelledNote {
    /// Transposes keeping correct letters (C + M3 = E, F# + M3 = A#, B + m2 = C).
    /// Compound intervals transpose like their simple form.
    func transposed(by interval: Interval, down: Bool = false) -> SpelledNote {
        let steps = interval.diatonicSteps * (down ? -1 : 1)
        let newLetter = letter.advanced(by: steps)
        let target = pitchClass.value + interval.semitones * (down ? -1 : 1)
        var acc = ((target - newLetter.naturalPitchClass) % 12 + 12) % 12
        if acc > 6 { acc -= 12 }
        return SpelledNote(newLetter, acc)
    }

    /// Ascending simple interval from `self` up to `other`.
    func interval(to other: SpelledNote) -> Interval? { Interval.between(self, other) }
}

extension Array where Element == Interval {
    /// Semitone offsets of each interval.
    var semitones: [Int] { map(\.semitones) }
}
