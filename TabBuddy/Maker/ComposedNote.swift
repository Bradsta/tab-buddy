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

    static let allPresets: [GuitarTuning] = [
        .standard, .dropD, .openG, .openD, .dadgad, .halfStepDown, .fullStepDown
    ]
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
