//
//  FretboardLayout.swift
//  TabBuddy
//
//  Fretted-instrument geometry. String index 0 is the highest-pitched string
//  (MeasureMap / FretPosition order), which equals guitarist numbering minus
//  one: guitar string 1 (high E) = index 0, string 6 (low E) = index 5.
//  Frets are counted from the capo (fret 0 = open or capo), matching tabs.
//

import Foundation

// MARK: - String numbering

extension FretPosition {
    /// Position from guitarist numbering (1 = highest string).
    init(guitarString number: Int, fret: Int) {
        self.init(string: number - 1, fret: fret)
    }

    /// Guitarist string number (1 = highest string).
    var guitarString: Int { string + 1 }

    /// Parses "string:fret" in guitarist numbering: "6:3" = low E string, fret 3.
    init(parsing text: String) throws {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let s = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let f = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            throw TheoryParseError(kind: .fretPosition, input: text,
                                   reason: "expected \"string:fret\" with string 1 = high E, e.g. \"6:3\"")
        }
        guard s >= 1, f >= 0 else {
            throw TheoryParseError(kind: .fretPosition, input: text,
                                   reason: "string numbers start at 1 (high E) and frets at 0 (open)")
        }
        self.init(guitarString: s, fret: f)
    }

    /// "6:3" form (guitarist numbering).
    var notation: String { "\(guitarString):\(fret)" }
}

// MARK: - FretboardLayout

struct FretboardLayout: Codable, Hashable, Sendable {
    /// Open-string MIDI, index 0 = highest-pitched string.
    var tuningMIDI: [Int]
    /// Frets above the nut.
    var fretCount: Int
    /// Capo fret (0 = none). Sounding pitch = open + capo + fret.
    var capo: Int

    init(tuningMIDI: [Int], fretCount: Int = 20, capo: Int = 0) {
        self.tuningMIDI = tuningMIDI
        self.fretCount = fretCount
        self.capo = max(0, capo)
    }

    /// Six-string standard tuning E2 A2 D3 G3 B3 E4 (from `GuitarTuning.standard`).
    static let standardGuitar = FretboardLayout(tuningMIDI: GuitarTuning.standard.midiNotes)

    static func guitar(_ tuning: GuitarTuning, capo: Int = 0) -> FretboardLayout {
        FretboardLayout(tuningMIDI: tuning.midiNotes, capo: capo)
    }

    var stringCount: Int { tuningMIDI.count }

    /// Highest playable fret relative to the capo.
    var maxFret: Int { max(0, fretCount - capo) }

    /// Open string pitches (with capo), spelled with common names.
    var openStringPitches: [Pitch] { tuningMIDI.map { Pitch(midi: $0 + capo) } }

    /// Sounding MIDI, or nil when the string or fret is out of range.
    func midi(string: Int, fret: Int) -> Int? {
        guard tuningMIDI.indices.contains(string), (0...maxFret).contains(fret) else { return nil }
        return tuningMIDI[string] + capo + fret
    }

    func midi(at position: FretPosition) -> Int? { midi(string: position.string, fret: position.fret) }

    /// Every position that sounds `midi`, highest string first.
    func positions(ofMIDI midi: Int, fretRange: ClosedRange<Int>? = nil) -> [FretPosition] {
        let range = clamp(fretRange)
        return tuningMIDI.indices.compactMap { s in
            let fret = midi - tuningMIDI[s] - capo
            return range.contains(fret) ? FretPosition(string: s, fret: fret) : nil
        }
    }

    func positions(of pitch: Pitch, fretRange: ClosedRange<Int>? = nil) -> [FretPosition] {
        positions(ofMIDI: pitch.midi, fretRange: fretRange)
    }

    /// Every position of a pitch class in all octaves, by string then fret.
    func positions(of pitchClass: PitchClass, fretRange: ClosedRange<Int>? = nil) -> [FretPosition] {
        positions(where: { PitchClass($0) == pitchClass }, fretRange: fretRange)
    }

    /// Every position whose note is in the scale, by string then fret.
    func positions(in scale: Scale, fretRange: ClosedRange<Int>? = nil) -> [FretPosition] {
        let set = scale.pitchClassSet
        return positions(where: { set.contains(PitchClass($0)) }, fretRange: fretRange)
    }

    func positions(where include: (Int) -> Bool, fretRange: ClosedRange<Int>? = nil) -> [FretPosition] {
        let range = clamp(fretRange)
        var result: [FretPosition] = []
        for s in tuningMIDI.indices {
            for f in range where include(tuningMIDI[s] + capo + f) {
                result.append(FretPosition(string: s, fret: f))
            }
        }
        return result
    }

    private func clamp(_ range: ClosedRange<Int>?) -> ClosedRange<Int> {
        let lo = max(0, range?.lowerBound ?? 0)
        let hi = min(maxFret, range?.upperBound ?? maxFret)
        return lo <= hi ? lo...hi : lo...lo
    }

    /// Sounding MIDI of a fingering, low string first.
    func midi(for fingering: ChordFingering) -> [Int] {
        fingering.positions.compactMap { midi(at: $0) }.sorted()
    }

    /// Lowest-string-first playable position of `midi` near `nearFret`, preferring
    /// open strings when `nearFret` is 0. Used to map sequences to one position.
    func bestPosition(ofMIDI midi: Int, nearFret: Int = 0) -> FretPosition? {
        positions(ofMIDI: midi).min { a, b in
            let da = abs(a.fret - nearFret), db = abs(b.fret - nearFret)
            return da != db ? da < db : a.string > b.string
        }
    }
}

// MARK: - Chord fingerings

/// A chord voicing on a six-string guitar in standard tuning.
/// `frets` and `fingers` use FretPosition order (index 0 = high E).
struct ChordFingering: Codable, Hashable, Sendable, CustomStringConvertible {
    struct Barre: Codable, Hashable, Sendable {
        var fret: Int
        /// Lowest string index covered (index 0 = high E).
        var fromString: Int
        /// Highest string index covered (the lowest-pitched string of the barre).
        var toString: Int
        var finger: Int = 1
    }

    /// Chord symbol, e.g. "Am".
    var symbol: String
    /// Fret per string; nil = muted/not played.
    var frets: [Int?]
    /// Finger per string: 0 = open, 1 index … 4 pinky, nil = muted.
    var fingers: [Int?]
    var barre: Barre? = nil

    var chord: Chord? { Chord(symbol) }

    /// Played strings as positions.
    var positions: [FretPosition] {
        frets.enumerated().compactMap { i, f in f.map { FretPosition(string: i, fret: $0) } }
    }

    /// Chart in the conventional low-to-high form: "x32010". Frets above 9 are
    /// written in parentheses: "x(10)(12)(12)(12)(10)".
    var chart: String {
        frets.reversed().map { f -> String in
            guard let f else { return "x" }
            return f > 9 ? "(\(f))" : String(f)
        }.joined()
    }

    var description: String { "\(symbol) \(chart)" }

    /// Lowest fretted (non-open) fret, or 1 when all open.
    var baseFret: Int { frets.compactMap { $0 }.filter { $0 > 0 }.min() ?? 1 }

    /// Builds a fingering from a low-to-high fret chart ("x32010") and an optional
    /// low-to-high finger chart in the same format (C: "x32010").
    init(symbol: String, chart: String, fingers fingerChart: String? = nil, barre: Barre? = nil) throws {
        let frets = try Self.parseChart(chart)
        var fingers: [Int?] = frets.map { $0 == nil ? nil : ($0 == 0 ? 0 : nil) }
        if let fingerChart {
            let parsed = try Self.parseChart(fingerChart)
            guard parsed.count == frets.count else {
                throw TheoryParseError(kind: .fingering, input: fingerChart, reason: "finger chart length differs from fret chart")
            }
            fingers = parsed
        }
        self.symbol = symbol
        self.frets = frets
        self.fingers = fingers
        self.barre = barre
    }

    init(symbol: String, frets: [Int?], fingers: [Int?], barre: Barre? = nil) {
        self.symbol = symbol
        self.frets = frets
        self.fingers = fingers
        self.barre = barre
    }

    /// Parses a low-to-high chart ("x32010", "x(10)(12)...") into high-to-low frets.
    static func parseChart(_ chart: String) throws -> [Int?] {
        var result: [Int?] = []
        var chars = Array(chart.replacingOccurrences(of: " ", with: ""))
        while !chars.isEmpty {
            let c = chars.removeFirst()
            if c == "x" || c == "X" || c == "-" {
                result.append(nil)
            } else if c == "(" {
                guard let close = chars.firstIndex(of: ")"), let n = Int(String(chars[..<close])) else {
                    throw TheoryParseError(kind: .fingering, input: chart, reason: "unclosed \"(\" in chart")
                }
                result.append(n)
                chars.removeFirst(close + 1)
            } else if let n = c.wholeNumberValue {
                result.append(n)
            } else {
                throw TheoryParseError(kind: .fingering, input: chart,
                                       reason: "use digits, x for muted strings, and (10) for frets above 9")
            }
        }
        return result.reversed()
    }

    private static func make(_ symbol: String, _ chart: String, _ fingers: String, barre: Barre? = nil) -> ChordFingering {
        // Static tables are covered by tests; a malformed entry is a programming error.
        try! ChordFingering(symbol: symbol, chart: chart, fingers: fingers, barre: barre)
    }

    /// Standard first-position voicings, keyed by symbol.
    static let openChords: [ChordFingering] = [
        make("E", "022100", "023100"),
        make("A", "x02220", "x01230"),
        make("D", "xx0232", "xx0132"),
        make("G", "320003", "210003"),
        make("C", "x32010", "x32010"),
        make("Am", "x02210", "x02310"),
        make("Em", "022000", "023000"),
        make("Dm", "xx0231", "xx0231"),
        make("E7", "020100", "020100"),
        make("A7", "x02020", "x02030"),
        make("D7", "xx0212", "xx0213"),
        make("G7", "320001", "320001"),
        make("C7", "x32310", "x32410"),
        make("B7", "x21202", "x21304"),
        make("Fmaj7", "xx3210", "xx3210"),
        make("Cadd9", "x32033", "x21034"),
        // Common extras.
        make("Am7", "x02010", "x02010"),
        make("Em7", "022030", "012030"),
        make("Dmaj7", "xx0222", "xx0123"),
        make("Amaj7", "x02120", "x02130"),
        make("Cmaj7", "x32000", "x32000"),
        make("Dm7", "xx0211", "xx0211"),
        make("Asus2", "x02200", "x01200"),
        make("Asus4", "x02230", "x01230"),
        make("Dsus2", "xx0230", "xx0130"),
        make("Dsus4", "xx0233", "xx0134"),
        make("Esus4", "022200", "023400"),
        make("E5", "022xxx", "012xxx"),
        make("A5", "x022xx", "x012xx"),
    ]

    /// Open voicing for a symbol ("Am", "G7"); enharmonic roots are not matched.
    static func open(_ symbol: String) -> ChordFingering? {
        guard let chord = Chord(symbol) else { return nil }
        return open(for: chord)
    }

    static func open(for chord: Chord) -> ChordFingering? {
        openChords.first { $0.chord == chord }
    }

    enum BarreForm: String, Codable, CaseIterable, Sendable {
        /// Root on string 6 (E-form).
        case eRoot
        /// Root on string 5 (A-form).
        case aRoot
    }

    /// Movable barre voicing in standard tuning for major, minor, 7, m7, or maj7
    /// (A-form only) chords. The barre fret is 1...12.
    static func barre(_ chord: Chord, form: BarreForm) -> ChordFingering? {
        let openString = form == .eRoot ? 4 : 9   // pitch class of E / A
        var fret = chord.root.pitchClass.value - openString
        fret = ((fret % 12) + 12) % 12
        if fret == 0 { fret = 12 }
        // Offsets and fingers low-to-high, relative to the barre fret.
        let table: [ChordQuality: ([Int?], [Int?])]
        switch form {
        case .eRoot:
            table = [
                .major: ([0, 2, 2, 1, 0, 0], [1, 3, 4, 2, 1, 1]),
                .minor: ([0, 2, 2, 0, 0, 0], [1, 3, 4, 1, 1, 1]),
                .dominantSeventh: ([0, 2, 0, 1, 0, 0], [1, 3, 1, 2, 1, 1]),
                .minorSeventh: ([0, 2, 0, 0, 0, 0], [1, 3, 1, 1, 1, 1]),
            ]
        case .aRoot:
            table = [
                .major: ([nil, 0, 2, 2, 2, 0], [nil, 1, 3, 3, 3, 1]),
                .minor: ([nil, 0, 2, 2, 1, 0], [nil, 1, 3, 4, 2, 1]),
                .dominantSeventh: ([nil, 0, 2, 0, 2, 0], [nil, 1, 3, 1, 4, 1]),
                .minorSeventh: ([nil, 0, 2, 0, 1, 0], [nil, 1, 3, 1, 2, 1]),
                .majorSeventh: ([nil, 0, 2, 1, 2, 0], [nil, 1, 3, 2, 4, 1]),
            ]
        }
        guard chord.bass == nil, let entry = table[chord.quality] else { return nil }
        let (offsets, fingers) = entry
        let frets = offsets.map { $0.map { $0 + fret } }
        let lowString = form == .eRoot ? 5 : 4
        return ChordFingering(symbol: chord.symbol,
                              frets: Array(frets.reversed()),
                              fingers: Array(fingers.reversed()),
                              barre: Barre(fret: fret, fromString: 0, toString: lowString))
    }
}
