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
    var expectedPitches: [Double?] {
        // Standard tuning open string frequencies (high E to low E)
        let standardOpen: [Double] = [
            329.63,  // E4
            246.94,  // B3
            196.00,  // G3
            146.83,  // D3
            110.00,  // A2
            82.41    // E2
        ]
        return frets.enumerated().map { i, fret in
            guard let f = fret, i < standardOpen.count else { return nil }
            // Equal temperament: freq = open * 2^(fret/12)
            return standardOpen[i] * pow(2.0, Double(f) / 12.0)
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
}
