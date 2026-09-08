//
//  ComposedNote.swift
//  TabBuddy
//
//  Value types for the tab maker: individual notes and tuning presets.
//

import Foundation

// MARK: - Composed Note

/// A single note placed on the staff by the user.
/// Stored as a JSON-encoded array in ComposedTab.notesData.
struct ComposedNote: Codable, Identifiable, Equatable {
    var id: UUID = UUID()

    /// Which measure this note belongs to (0-based)
    var measureIndex: Int

    /// Horizontal position within the measure (0.0 = start, 1.0 = end)
    var positionInMeasure: Double

    /// Duration in beats (quarter note = 1.0)
    var durationInBeats: Double

    /// Canonical MIDI pitch (e.g. 64 = E4)
    var midiPitch: Int

    /// Diatonic staff step relative to middle C (0 = C4, 1 = D4, -1 = B3, etc.)
    /// Encodes vertical position on the treble clef independently of accidentals.
    var staffStep: Int

    /// Accidental: -1 = flat, 0 = natural, +1 = sharp
    var accidental: Int

    /// User-chosen string override (0–5, high E first). nil = use auto-suggestion.
    var selectedString: Int?

    /// User-chosen fret override. nil = use auto-suggestion.
    var selectedFret: Int?
}

// MARK: - Guitar Tuning

/// A named guitar tuning with MIDI base notes for each string.
struct GuitarTuning: Identifiable, Hashable {
    var id: String { name }

    let name: String
    /// MIDI note numbers for each open string, index 0 = high E (string 1), index 5 = low E (string 6)
    let midiNotes: [Int]

    /// Note names for display (high to low)
    var noteNames: [String] {
        midiNotes.map { Self.midiToNoteName($0) }
    }

    /// Display string showing tuning from low to high (conventional order)
    var displayString: String {
        midiNotes.reversed().map { Self.midiToNoteName($0) }.joined(separator: " ")
    }

    private static func midiToNoteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[midi % 12]
    }

    // MARK: - Preset Tunings

    static let standard = GuitarTuning(
        name: "Standard",
        midiNotes: [64, 59, 55, 50, 45, 40]  // E4 B3 G3 D3 A2 E2
    )

    static let dropD = GuitarTuning(
        name: "Drop D",
        midiNotes: [64, 59, 55, 50, 45, 38]  // E4 B3 G3 D3 A2 D2
    )

    static let openG = GuitarTuning(
        name: "Open G",
        midiNotes: [62, 59, 55, 50, 43, 38]  // D4 B3 G3 D3 G2 D2
    )

    static let openD = GuitarTuning(
        name: "Open D",
        midiNotes: [62, 57, 54, 50, 45, 38]  // D4 A3 F#3 D3 A2 D2
    )

    static let dadgad = GuitarTuning(
        name: "DADGAD",
        midiNotes: [62, 57, 55, 50, 45, 38]  // D4 A3 G3 D3 A2 D2
    )

    static let halfStepDown = GuitarTuning(
        name: "Half Step Down",
        midiNotes: [63, 58, 54, 49, 44, 39]  // Eb4 Bb3 Gb3 Db3 Ab2 Eb2
    )

    static let fullStepDown = GuitarTuning(
        name: "Full Step Down",
        midiNotes: [62, 57, 53, 48, 43, 38]  // D4 A3 F3 C3 G2 D2
    )

    static let bass4 = GuitarTuning(name: "Bass standard (4 strings)", midiNotes: [43, 38, 33, 28])
    static let bass5 = GuitarTuning(name: "Bass standard (5 strings)", midiNotes: [43, 38, 33, 28, 23])
    static let bass6 = GuitarTuning(name: "Bass standard (6 strings)", midiNotes: [48, 43, 38, 33, 28, 23])
    static let ukulele = GuitarTuning(name: "Ukulele high G", midiNotes: [69, 64, 60, 67])
    static let guitar7 = GuitarTuning(name: "Guitar standard (7 strings)", midiNotes: [64, 59, 55, 50, 45, 40, 35])
    static let guitar8 = GuitarTuning(name: "Guitar standard (8 strings)", midiNotes: [64, 59, 55, 50, 45, 40, 35, 30])

    static let allPresets: [GuitarTuning] = [
        .standard, .dropD, .openG, .openD, .dadgad, .halfStepDown, .fullStepDown,
        .bass4, .bass5, .bass6, .ukulele, .guitar7, .guitar8
    ]

    // MARK: - Name normalization

    /// Canonical preset name for a raw tuning string from a tab header, or nil
    /// when unrecognized (genuinely exotic tunings keep their raw text).
    /// Handles "Standard", preset names, and note-letter spellings in either
    /// direction with any separators: "EADGBE", "E A D G B E", "e-a-d-g-b-e",
    /// "Eb Ab Db Gb Bb Eb", "D A D G A D", …
    static func displayName(for raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Unknown" }
        if let name = canonicalName(for: raw) { return name }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let notes = noteSpelling(clean) { return notes.joined(separator: " ") }
        return clean
    }

    /// Keep custom note sequences, including repeated pitches, without inventing a preset.
    static func noteSpelling(_ raw: String) -> [String]? {
        let clean = raw.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
        // Separators disambiguate B strings from flat signs, especially on four-string instruments.
        let separated = clean.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-,/()"))).filter { !$0.isEmpty }
        if (1...12).contains(separated.count), separated.allSatisfy({
            $0.range(of: "^[A-Ga-g][#b]?$", options: .regularExpression) != nil
        }) {
            return separated.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        }
        for pattern in ["[A-Ga-g]#?", "[A-Ga-g][#b]?"] {
            let regex = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(clean.startIndex..., in: clean)
            let matches = regex.matches(in: clean, range: range)
            let remaining = regex.stringByReplacingMatches(in: clean, range: range, withTemplate: "")
            guard (1...12).contains(matches.count), remaining.allSatisfy({ $0.isWhitespace || "-,/()".contains($0) }) else { continue }
            return matches.compactMap { Range($0.range, in: clean).map { r in
                let token = String(clean[r]); return token.prefix(1).uppercased() + token.dropFirst()
            } }
        }
        return nil
    }

    static func canonicalName(for raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#").lowercased()
        if ["standard", "standard tuning", "e standard"].contains(lower.trimmingCharacters(in: .whitespacesAndNewlines)) { return standard.name }
        for p in allPresets where p.name != standard.name && lower.contains(p.name.lowercased()) { return p.name }

        // Note-letter signature. Two parses: letters+sharps only (so the 'b'
        // in "eadgbe" is the B string, not a flat), then flats allowed.
        func parse(withFlats: Bool) -> [String]? {
            var tokens: [String] = []
            let chars = Array(lower)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if "abcdefg".contains(c) {
                    var tok = String(c)
                    if i + 1 < chars.count {
                        let n = chars[i + 1]
                        if n == "#" || (withFlats && n == "b") {
                            // flats → enharmonic sharps to match preset names
                            if n == "b" {
                                let flatToSharp = ["a": "g#", "b": "a#", "d": "c#", "e": "d#", "g": "f#"]
                                tok = flatToSharp[tok] ?? tok
                            } else {
                                tok += "#"
                            }
                            i += 1
                        }
                    }
                    tokens.append(tok)
                } else if !(c == " " || c == "-" || c == "," || c == "/" || c == "'") {
                    // other letters/digits — not a plain tuning spelling
                    if c.isLetter || c.isNumber { return nil }
                }
                i += 1
            }
            return (1...12).contains(tokens.count) ? tokens : nil
        }

        for withFlats in [false, true] {
            guard let tokens = parse(withFlats: withFlats) else { continue }
            let sig = tokens.joined()
            for p in allPresets {
                let names = p.noteNames.map { $0.lowercased() }   // high→low
                if sig == names.joined() || sig == names.reversed().joined() {
                    return p.name
                }
            }
        }
        return nil
    }
}

// MARK: - Time Signature

/// Common time signatures for the picker.
struct TimeSignature: Hashable, Identifiable {
    var id: String { "\(beats)/\(noteValue)" }
    let beats: Int
    let noteValue: Int

    var display: String { "\(beats)/\(noteValue)" }

    static let common: [TimeSignature] = [
        .init(beats: 4, noteValue: 4),
        .init(beats: 3, noteValue: 4),
        .init(beats: 2, noteValue: 4),
        .init(beats: 6, noteValue: 8),
        .init(beats: 5, noteValue: 4),
        .init(beats: 7, noteValue: 8),
    ]
}
