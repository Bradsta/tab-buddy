//
//  Rhythm.swift
//  TabBuddy
//
//  Note values and rhythm patterns written as tokens. Lengths are in quarter-
//  note beats (quarter = 1).
//
//  Grammar (tokens separated by spaces or commas; "|" bar lines are ignored):
//
//      token    := [t] base [t] dots [r]      (modifiers may appear in any order after base)
//      base     := w | h | q | e | s          whole, half, quarter, eighth, sixteenth
//      dots     := "." | ".."                 dotted (x1.5) or double-dotted (x1.75)
//      t        := triplet (x2/3)             "te" or "et" = triplet eighth
//      r        := rest                       "qr" = quarter rest, "e.r" = dotted-eighth rest
//
//  Examples: "q q e e q", "h. q", "te te te q", "q qr h", "e.r s q".
//  Tokens are case-insensitive.
//

import Foundation

/// A note or rest length. Encodes as its token ("q.", "te").
struct NoteValue: Hashable, Sendable, CustomStringConvertible {
    enum Base: String, CaseIterable, Codable, Hashable, Sendable {
        case whole = "w", half = "h", quarter = "q", eighth = "e", sixteenth = "s"

        /// Length in quarter-note beats.
        var beats: Double {
            switch self {
            case .whole: return 4
            case .half: return 2
            case .quarter: return 1
            case .eighth: return 0.5
            case .sixteenth: return 0.25
            }
        }

        var name: String {
            switch self {
            case .whole: return "whole"
            case .half: return "half"
            case .quarter: return "quarter"
            case .eighth: return "eighth"
            case .sixteenth: return "sixteenth"
            }
        }
    }

    var base: Base
    /// 0, 1 (dotted), or 2 (double-dotted).
    var dots: Int
    var isTriplet: Bool

    init(_ base: Base, dots: Int = 0, triplet: Bool = false) {
        self.base = base
        self.dots = max(0, min(2, dots))
        self.isTriplet = triplet
    }

    var isDotted: Bool { dots > 0 }

    /// Length in quarter-note beats.
    var beats: Double {
        var b = base.beats
        if dots == 1 { b *= 1.5 } else if dots == 2 { b *= 1.75 }
        if isTriplet { b *= 2.0 / 3.0 }
        return b
    }

    /// Token form: "q", "h.", "te".
    var token: String { (isTriplet ? "t" : "") + base.rawValue + String(repeating: ".", count: dots) }
    var description: String { token }

    /// "dotted quarter", "triplet eighth", "whole".
    var name: String {
        var parts: [String] = []
        if dots == 1 { parts.append("dotted") } else if dots == 2 { parts.append("double-dotted") }
        if isTriplet { parts.append("triplet") }
        parts.append(base.name)
        return parts.joined(separator: " ")
    }

    static let whole = NoteValue(.whole), half = NoteValue(.half), quarter = NoteValue(.quarter)
    static let eighth = NoteValue(.eighth), sixteenth = NoteValue(.sixteenth)
    static let dottedHalf = NoteValue(.half, dots: 1), dottedQuarter = NoteValue(.quarter, dots: 1)
    static let dottedEighth = NoteValue(.eighth, dots: 1), tripletEighth = NoteValue(.eighth, triplet: true)
}

extension NoteValue: Codable {
    init(from decoder: Decoder) throws {
        self = try decoder.singleValueContainer().decodeTheoryString { text in
            let event = try RhythmEvent(parsing: text)
            guard !event.isRest else {
                throw TheoryParseError(kind: .rhythm, input: text, reason: "a note value cannot be a rest")
            }
            return event.value
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(token)
    }
}

/// One token of a rhythm pattern: a note value that is sounded or rested.
struct RhythmEvent: Codable, Hashable, Sendable, CustomStringConvertible {
    var value: NoteValue
    var isRest: Bool

    init(_ value: NoteValue, isRest: Bool = false) {
        self.value = value
        self.isRest = isRest
    }

    var beats: Double { value.beats }
    var token: String { value.token + (isRest ? "r" : "") }
    var description: String { token }

    /// Parses a single token (see the grammar at the top of this file).
    init(parsing token: String) throws {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        func fail(_ reason: String) -> TheoryParseError {
            TheoryParseError(kind: .rhythm, input: token, reason: reason)
        }
        var base: NoteValue.Base?
        var dots = 0
        var triplet = false
        var rest = false
        for ch in t {
            switch ch {
            case "w", "h", "q", "e", "s":
                guard base == nil else { throw fail("more than one note value letter; separate tokens with spaces") }
                base = NoteValue.Base(rawValue: String(ch))
            case ".":
                guard base != nil else { throw fail("the dot goes after the value letter, e.g. \"q.\"") }
                dots += 1
            case "t":
                guard !triplet else { throw fail("repeated triplet marker") }
                triplet = true
            case "r":
                guard base != nil, !rest else { throw fail("the rest marker goes after the value, e.g. \"qr\"") }
                rest = true
            default:
                throw fail("unexpected \"\(ch)\"; use w h q e s with optional . (dotted), t (triplet), r (rest)")
            }
        }
        guard let base else { throw fail("missing a value letter (w h q e s)") }
        guard dots <= 2 else { throw fail("at most two dots") }
        self.init(NoteValue(base, dots: dots, triplet: triplet), isRest: rest)
    }
}

/// A sequence of rhythm events. Encodes as its token string ("q q e e q").
struct RhythmPattern: Hashable, Sendable, CustomStringConvertible {
    var events: [RhythmEvent]

    init(_ events: [RhythmEvent]) { self.events = events }

    /// Parses a token string such as "q q e e q", "h. q", "te te te q", "q qr h".
    init(parsing string: String) throws {
        let tokens = string
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "|" })
            .map(String.init)
        guard !tokens.isEmpty else {
            throw TheoryParseError(kind: .rhythm, input: string, reason: "empty rhythm; write tokens like \"q q e e q\"")
        }
        var events: [RhythmEvent] = []
        for (i, token) in tokens.enumerated() {
            do {
                events.append(try RhythmEvent(parsing: token))
            } catch let error as TheoryParseError {
                throw TheoryParseError(kind: .rhythm, input: string,
                                       reason: "token \(i + 1) \"\(token)\": \(error.reason)")
            }
        }
        self.events = events
    }

    init?(_ string: String) { try? self.init(parsing: string) }

    var tokens: String { events.map(\.token).joined(separator: " ") }
    var description: String { tokens }

    /// Total length in quarter-note beats.
    var totalBeats: Double { events.reduce(0) { $0 + $1.beats } }

    /// Start beat of every event (rests included).
    var startBeats: [Double] {
        var t = 0.0
        return events.map { e in defer { t += e.beats }; return t }
    }

    /// Start beats of sounded events only.
    var onsetBeats: [Double] {
        zip(events, startBeats).filter { !$0.0.isRest }.map(\.1)
    }

    /// Number of sounded (non-rest) events.
    var noteCount: Int { events.filter { !$0.isRest }.count }

    /// Number of whole measures covered, or nil if the length is not a whole number
    /// of `beatsPerMeasure` (quarter-note beats).
    func measureCount(beatsPerMeasure: Double) -> Int? {
        let m = totalBeats / beatsPerMeasure
        let r = m.rounded()
        return abs(m - r) < 1e-6 ? Int(r) : nil
    }

    /// Spoken count for each event in 4/4-style counting ("1", "&", "2 e", "3 a",
    /// "trip", "let"), using sixteenth and triplet subdivisions.
    func countLabels(beatsPerMeasure: Int = 4) -> [String] {
        startBeats.map { start in
            let inMeasure = start.truncatingRemainder(dividingBy: Double(max(1, beatsPerMeasure)))
            let beat = Int(inMeasure.rounded(.down))
            let frac = inMeasure - Double(beat)
            let label: String
            switch frac {
            case let f where abs(f) < 1e-6: label = String(beat + 1)
            case let f where abs(f - 0.25) < 1e-6: label = "e"
            case let f where abs(f - 0.5) < 1e-6: label = "&"
            case let f where abs(f - 0.75) < 1e-6: label = "a"
            case let f where abs(f - 1.0 / 3) < 1e-6: label = "trip"
            case let f where abs(f - 2.0 / 3) < 1e-6: label = "let"
            default: label = "·"
            }
            return label
        }
    }
}

extension RhythmPattern: Codable {
    init(from decoder: Decoder) throws {
        self = try decoder.singleValueContainer().decodeTheoryString { try RhythmPattern(parsing: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(tokens)
    }
}
