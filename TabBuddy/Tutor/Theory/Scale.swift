//
//  Scale.swift
//  TabBuddy
//
//  Scale types as interval lists from the root. Heptatonic scales use one
//  letter per degree (F major has Bb, not A#); pentatonic and blues scales
//  keep the letters of their parent scale (A minor pentatonic = A C D E G,
//  A blues = A C D Eb E G).
//

import Foundation

enum ScaleType: String, CaseIterable, Codable, Hashable, Sendable {
    case major
    case naturalMinor
    case harmonicMinor
    case melodicMinor
    case majorPentatonic
    case minorPentatonic
    case blues
    case ionian, dorian, phrygian, lydian, mixolydian, aeolian, locrian
    case chromatic

    /// Intervals above the root, ascending, excluding the octave.
    /// Melodic minor is the ascending (jazz) form.
    var intervals: [Interval] {
        switch self {
        case .major, .ionian: return [.P1, .M2, .M3, .P4, .P5, .M6, .M7]
        case .naturalMinor, .aeolian: return [.P1, .M2, .m3, .P4, .P5, .m6, .m7]
        case .harmonicMinor: return [.P1, .M2, .m3, .P4, .P5, .m6, .M7]
        case .melodicMinor: return [.P1, .M2, .m3, .P4, .P5, .M6, .M7]
        case .majorPentatonic: return [.P1, .M2, .M3, .P5, .M6]
        case .minorPentatonic: return [.P1, .m3, .P4, .P5, .m7]
        case .blues: return [.P1, .m3, .P4, .d5, .P5, .m7]
        case .dorian: return [.P1, .M2, .m3, .P4, .P5, .M6, .m7]
        case .phrygian: return [.P1, .m2, .m3, .P4, .P5, .m6, .m7]
        case .lydian: return [.P1, .M2, .M3, .A4, .P5, .M6, .M7]
        case .mixolydian: return [.P1, .M2, .M3, .P4, .P5, .M6, .m7]
        case .locrian: return [.P1, .m2, .m3, .P4, .d5, .m6, .m7]
        case .chromatic: return [.P1, .A1, .M2, .A2, .M3, .P4, .A4, .P5, .A5, .M6, .A6, .M7]
        }
    }

    /// Lowercase name used in prose and parsing: "natural minor", "minor pentatonic".
    var name: String {
        switch self {
        case .major: return "major"
        case .naturalMinor: return "natural minor"
        case .harmonicMinor: return "harmonic minor"
        case .melodicMinor: return "melodic minor"
        case .majorPentatonic: return "major pentatonic"
        case .minorPentatonic: return "minor pentatonic"
        case .blues: return "blues"
        case .ionian: return "ionian"
        case .dorian: return "dorian"
        case .phrygian: return "phrygian"
        case .lydian: return "lydian"
        case .mixolydian: return "mixolydian"
        case .aeolian: return "aeolian"
        case .locrian: return "locrian"
        case .chromatic: return "chromatic"
        }
    }

    /// Title-case name: "Natural Minor", "Dorian".
    var displayName: String { name.capitalized }

    /// Degree labels relative to the major scale: ["1", "2", "b3", "4", "5", "b6", "b7"].
    var degreeLabels: [String] { intervals.map(Self.degreeLabel) }

    static func degreeLabel(_ interval: Interval) -> String {
        let n = interval.simpleNumber
        let majorRef = Interval(quality: Interval.isPerfectType(n) ? .perfect : .major, number: n)!
        let diff = interval.semitones - majorRef.semitones
        return SpelledNote.asciiAccidental(diff).replacingOccurrences(of: "x", with: "##") + String(n)
    }

    /// Whether each degree gets its own letter (seven-note scales).
    var isHeptatonic: Bool { intervals.count == 7 }

    /// Names accepted by the parser, longest first.
    fileprivate static let aliases: [(String, ScaleType)] = [
        ("natural minor", .naturalMinor), ("harmonic minor", .harmonicMinor), ("melodic minor", .melodicMinor),
        ("major pentatonic", .majorPentatonic), ("pentatonic major", .majorPentatonic),
        ("minor pentatonic", .minorPentatonic), ("pentatonic minor", .minorPentatonic),
        ("minor blues", .blues), ("blues", .blues), ("pentatonic", .majorPentatonic),
        ("major", .major), ("minor", .naturalMinor),
        ("ionian", .ionian), ("dorian", .dorian), ("phrygian", .phrygian), ("lydian", .lydian),
        ("mixolydian", .mixolydian), ("aeolian", .aeolian), ("locrian", .locrian), ("chromatic", .chromatic),
    ]

    /// Parses a type name ("major", "minor pentatonic", "Dorian"), case-insensitive;
    /// "minor" means natural minor and "pentatonic" alone means major pentatonic.
    init?(name: String) {
        let n = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let cleaned = n.hasSuffix(" scale") ? String(n.dropLast(6)) : (n == "scale" ? "" : n)
        guard let match = Self.aliases.first(where: { $0.0 == cleaned }) else {
            if let byRaw = ScaleType(rawValue: name) { self = byRaw; return }
            return nil
        }
        self = match.1
    }
}

/// A scale on a spelled root. Encodes as "<root> <type>" ("A minor pentatonic").
struct Scale: Hashable, Sendable, CustomStringConvertible {
    var root: SpelledNote
    var type: ScaleType

    init(root: SpelledNote, type: ScaleType) {
        self.root = root
        self.type = type
    }

    /// Parses "C major", "A minor pentatonic", "D dorian", "F# harmonic minor",
    /// "Bb blues", "E minor scale". The root is a note name; the rest is a type name.
    init(parsing string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else {
            throw TheoryParseError(kind: .scale, input: string,
                                   reason: "expected \"<root> <type>\", e.g. \"G major\" or \"A minor pentatonic\"")
        }
        let rootText = String(trimmed[..<space])
        let typeText = String(trimmed[space...])
        do {
            root = try SpelledNote(parsing: rootText)
        } catch let error as TheoryParseError {
            throw TheoryParseError(kind: .scale, input: string, reason: "root: \(error.reason)")
        }
        guard let t = ScaleType(name: typeText) else {
            let known = ScaleType.allCases.map(\.name).joined(separator: ", ")
            throw TheoryParseError(kind: .scale, input: string,
                                   reason: "unknown scale type \"\(typeText.trimmingCharacters(in: .whitespaces))\"; known types: \(known)")
        }
        type = t
    }

    init?(_ string: String) { try? self.init(parsing: string) }

    var name: String { "\(root.name) \(type.name)" }
    var displayName: String { "\(root.displayName) \(type.name)" }
    var description: String { name }

    var intervals: [Interval] { type.intervals }

    /// Spelled notes, ascending from the root, without the octave.
    var notes: [SpelledNote] {
        if type == .chromatic { return chromaticNotes }
        return type.intervals.map { root.transposed(by: $0) }
    }

    /// Degree labels relative to major ("1", "b3", …), aligned with `notes`.
    var degrees: [String] { type.degreeLabels }

    var pitchClasses: [PitchClass] { notes.map(\.pitchClass) }
    var pitchClassSet: Set<PitchClass> { Set(pitchClasses) }

    func contains(_ pc: PitchClass) -> Bool { pitchClassSet.contains(pc) }
    func contains(midi: Int) -> Bool { contains(PitchClass(midi)) }

    /// 1-based degree of a pitch class, or nil when outside the scale.
    func degree(of pc: PitchClass) -> Int? {
        pitchClasses.firstIndex(of: pc).map { $0 + 1 }
    }

    /// Note at a 1-based degree, wrapping past the octave (degree 8 = root).
    func note(degree: Int) -> SpelledNote {
        let count = notes.count
        return notes[((degree - 1) % count + count) % count]
    }

    /// Spelled pitches from `startOctave`: `octaves` octaves up including the top
    /// root, then back down when `upAndDown` is true.
    func pitches(startOctave: Int, octaves: Int = 1, upAndDown: Bool = false) -> [Pitch] {
        pitches(from: Pitch(root, octave: startOctave), octaves: octaves, upAndDown: upAndDown)
    }

    /// Spelled pitches starting on `start` (whose note should be the root).
    func pitches(from start: Pitch, octaves: Int = 1, upAndDown: Bool = false) -> [Pitch] {
        var up: [Pitch] = []
        let chromatic = type == .chromatic ? chromaticNotes : []
        for o in 0..<max(1, octaves) {
            let base = Pitch(start.note, octave: start.octave + o)
            for (i, iv) in type.intervals.enumerated() {
                if type == .chromatic, let p = Pitch(midi: base.midi + iv.semitones, spelled: chromatic[i]) {
                    up.append(p)
                } else {
                    up.append(base.transposed(by: iv))
                }
            }
        }
        up.append(Pitch(start.note, octave: start.octave + max(1, octaves)))
        guard upAndDown else { return up }
        return up + up.dropLast().reversed()
    }

    /// Chromatic spelling: the root keeps its spelling; other notes use sharps
    /// for sharp-side roots and flats for flat-side roots (F, Bb, Eb, …).
    private var chromaticNotes: [SpelledNote] {
        let preferSharps = root.fifthsFromC >= 0
        return (0..<12).map { i in
            i == 0 ? root : SpelledNote.common(for: root.pitchClass.transposed(by: i), preferSharps: preferSharps)
        }
    }

    /// The mode starting on a given degree of this scale's notes, when it names one
    /// (degree 2 of C major = D dorian). Only for major/ionian parents.
    func mode(onDegree degree: Int) -> Scale? {
        guard type == .major || type == .ionian, (1...7).contains(degree) else { return nil }
        let modes: [ScaleType] = [.ionian, .dorian, .phrygian, .lydian, .mixolydian, .aeolian, .locrian]
        return Scale(root: note(degree: degree), type: modes[degree - 1])
    }
}

extension Scale: Codable {
    init(from decoder: Decoder) throws {
        self = try decoder.singleValueContainer().decodeTheoryString { try Scale(parsing: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}
