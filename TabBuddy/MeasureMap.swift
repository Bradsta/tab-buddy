//
//  MeasureMap.swift
//  TabBuddy
//
//  Shared output schema for both rule-based parsing and ML inference.
//  Text tabs and PDF tabs both produce MeasureMap, consumed by PlaybackCoordinator.
//

import Foundation
import CoreGraphics

// MARK: - Top-level structure

/// Unified representation of a tab's musical structure and layout.
/// Produced by TabParser (text) or PDFMeasureDetector (PDF).
struct MeasureMap {
    /// Detected tempo in BPM (nil if not found)
    var bpm: Double?
    /// Time signature: (beatsPerMeasure, noteValue) e.g. (4, 4) for 4/4
    var timeSignature: (beats: Int, noteValue: Int)?
    /// Key signature (e.g. "A minor", "C major")
    var key: String?
    /// Guitar tuning (e.g. "EADGBE", "Drop D")
    var tuning: String?
    /// Ordered list of visual systems (rows of tab lines)
    var systems: [MeasureSystem]

    /// Physical rows, top to bottom. Exact pitches are supplied by structured files.
    var detectedStringCount: Int? = nil
    var openStringMIDI: [Int]? = nil

    var stringCount: Int {
        max(1, detectedStringCount ?? allMeasures.flatMap { $0.notes ?? [] }.map { $0.frets.count }.max()
            ?? openStringMIDI?.count ?? GuitarTuning.noteSpelling(tuning ?? "")?.count ?? 6)
    }

    /// Unknown custom tunings stay readable without inventing sounding pitches.
    var resolvedOpenStringMIDI: [Int]? {
        if let openStringMIDI, openStringMIDI.count == stringCount { return openStringMIDI }
        let name = GuitarTuning.canonicalName(for: tuning)
        if let preset = GuitarTuning.allPresets.first(where: { $0.name == name && $0.midiNotes.count == stringCount }) {
            return preset.midiNotes
        }
        if tuning == nil && stringCount == 6 { return GuitarTuning.standard.midiNotes }
        return nil
    }

    // MARK: Foreword (captured from header text)
    /// In-file title (first meaningful header line), nil if none found.
    var title: String? = nil
    /// Composer / arranger ("Composed by: …", "by …").
    var artist: String? = nil
    /// Remaining header prose (performer, transcriber, notes). The "foreword".
    var comments: String? = nil
    /// Prose that follows the final tab system (closing notes / credits). The
    /// "afterword". Display-only; not part of the canonical.
    var afterword: String? = nil
    /// Capo position in semitones (nil/0 = no capo). Applied to sounding pitch.
    var capoSemitones: Int? = nil

    /// True when a rhythm/duration line drove the note durations (vs synthesized).
    var rhythmAuthored: Bool = false
    /// True when the tab is unmetered free-time (no time sig, no rhythm, no bars).
    var isFreeTime: Bool = false

    /// Flattened list of all measures across all systems, in order.
    var allMeasures: [Measure] {
        systems.flatMap(\.measures)
    }

    /// Total number of measures in the tab.
    var measureCount: Int {
        systems.reduce(0) { $0 + $1.measures.count }
    }
}

// MARK: - System (visual row)

/// One visual "row" of tab — typically 6 tab lines (one per string)
/// plus optional beat ruler or rhythm notation line.
struct MeasureSystem {
    /// Bounding rect in the view's coordinate space.
    /// For text: derived from line range × character width.
    /// For PDF: detected bounding box in page coordinates.
    var rect: CGRect
    /// Index range of lines in the original text (text tabs only).
    var lineRange: Range<Int>?
    /// The measures within this system, left to right.
    var measures: [Measure]
}

// MARK: - Measure

/// A single measure (bar) in the tab.
struct Measure {
    /// Bounding rect within the parent system's coordinate space.
    var rect: CGRect
    /// 1-based measure number in the piece.
    var measureNumber: Int
    /// Number of beats in this measure (from time signature or beat ruler).
    var beatCount: Int
    /// Individual note events within this measure (nil if not parsed).
    var notes: [NoteEvent]?

    /// Column range in the original text (text tabs only).
    var columnRange: Range<Int>?

    /// Chord symbols over this measure ("F#m7" at fractional position),
    /// from a chord line above the system (text tabs) or extracted lead-sheet
    /// harmony (PDFs). nil = none.
    var chords: [(name: String, position: Double)]? = nil
}

// MARK: - Note Event

/// A single note or chord event at a specific position within a measure.
struct NoteEvent {
    /// Fractional position within the measure (0.0 = start, 1.0 = end).
    var positionInMeasure: Double
    /// Duration in beats (e.g. 1.0 = quarter note in 4/4).
    var durationInBeats: Double?
    /// Which frets are played on which strings (index 0 = high E, 5 = low E).
    /// nil entry means string is not played.
    var frets: [Int?]
    /// Column position in the original text (text tabs only).
    var column: Int?

    /// Expected pitches in Hz for each fretted string.
    /// Computed from tuning + fret number using equal temperament.
    func expectedPitches(openStringMIDI: [Int]) -> [Double?] {
        frets.enumerated().map { index, fret in
            guard let fret, openStringMIDI.indices.contains(index) else { return nil }
            return 440 * pow(2, Double(openStringMIDI[index] + fret - 69) / 12)
        }
    }

}

// MARK: - Rhythm Duration

/// Standard musical note durations, expressed in beats (quarter note = 1.0).
enum RhythmDuration: Double, CaseIterable {
    case thirtySecond  = 0.125
    case sixteenth     = 0.25
    case dottedSixteenth = 0.375
    case eighth        = 0.5
    case dottedEighth  = 0.75
    case quarter       = 1.0
    case dottedQuarter = 1.5
    case half          = 2.0
    case dottedHalf    = 3.0
    case whole         = 4.0

    /// Single-letter rhythm notation for this duration (inverse of `from`).
    var notation: String {
        switch self {
        case .thirtySecond:    return "T"
        case .sixteenth:       return "S"
        case .dottedSixteenth: return "S."
        case .eighth:          return "E"
        case .dottedEighth:    return "E."
        case .quarter:         return "Q"
        case .dottedQuarter:   return "Q."
        case .half:            return "H"
        case .dottedHalf:      return "H."
        case .whole:           return "W"
        }
    }

    /// The standard duration nearest to an arbitrary beat value.
    static func nearest(toBeats beats: Double) -> RhythmDuration {
        allCases.min(by: { abs($0.rawValue - beats) < abs($1.rawValue - beats) }) ?? .quarter
    }

    /// Parse from rhythm notation character (E, Q, H, S, W, T).
    /// Returns nil for unrecognized characters.
    static func from(notation: String) -> RhythmDuration? {
        let trimmed = notation.trimmingCharacters(in: .whitespaces)
        let isDotted = trimmed.hasSuffix(".")
        let base = isDotted ? String(trimmed.dropLast()) : trimmed

        switch base.uppercased() {
        case "T": return .thirtySecond
        case "S": return isDotted ? .dottedSixteenth : .sixteenth
        case "E": return isDotted ? .dottedEighth : .eighth
        case "Q": return isDotted ? .dottedQuarter : .quarter
        case "H": return isDotted ? .dottedHalf : .half
        case "W": return .whole
        default: return nil
        }
    }
}

// MARK: - Tab Metadata (text-specific, used by TabParser)

/// Metadata extracted from text tab headers.
struct TabMetadata {
    var timeSignature: (beats: Int, noteValue: Int)?
    var bpm: Double?
    var key: String?
    var tuning: String?
    var title: String? = nil
    var artist: String? = nil
    var comments: String? = nil
    var capoSemitones: Int? = nil
}
