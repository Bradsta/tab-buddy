//
//  CanonicalTab.swift
//  TabBuddy
//
//  The Tab Buddy canonical representation of a tab — an in-memory mirror of the
//  MusicXML document that is the portable source of truth for a library entry.
//
//  See DESIGN.md. CanonicalTab is the hub every import/edit path converges on:
//    TabParser/MeasureMap  ─► CanonicalTab ─► MusicXML file (on disk)
//    ComposedTab (Maker)  ◄─► CanonicalTab ─► MeasureMap (playback) / ASCII (diff)
//
//  This is a pure Codable value type with no UI, SwiftData, or iCloud
//  dependencies, so it is trivially testable.
//

import Foundation

// MARK: - CanonicalTab

/// In-memory, serializable canonical form of a tab.
///
/// `tuningMIDI` follows the project convention: index 0 = high E (string 1),
/// index 5 = low E (string 6); standard = `[64, 59, 55, 50, 45, 40]`.
struct CanonicalTab: Codable, Equatable {
    /// Schema version of this in-memory model (distinct from the *converter*
    /// version recorded in `provenance.converterVersion`). Bump when the shape
    /// of `CanonicalTab` itself changes so decoders can migrate.
    var schemaVersion: Int = 1

    // –– Headers ––
    var title: String
    var artist: String?
    var comments: String?

    // –– Instrument configuration ––
    /// Open-string MIDI notes, high-E-first (length 6 for guitar).
    var tuningMIDI: [Int]
    /// Human-readable tuning name (e.g. "Standard", "Drop D").
    var tuningName: String
    /// Per-string capo offset in semitones, high-E-first, same indexing as
    /// `tuningMIDI`. All-zero = no capo. A uniform non-zero value = a normal
    /// capo; a partial pattern (e.g. strings 1–5 raised, string 6 at 0) models
    /// a partial capo, which MusicXML has no native element for. Used by the
    /// future lens layer; length matches `tuningMIDI` (or empty = no capo).
    var capoOffsets: [Int]

    // –– Musical context ––
    var beatsPerMeasure: Int
    var noteValue: Int
    /// Key signature as a fifths count (MusicXML `<fifths>`: 0 = C/Am,
    /// + = sharps, − = flats). nil = unknown/unspecified.
    var keyFifths: Int?
    /// Tempo in BPM at the start of the piece. nil = unknown.
    var bpm: Double?

    // –– Content ––
    var measures: [CanonicalMeasure]

    // –– Bookkeeping ––
    var provenance: Provenance

    init(title: String = "Untitled",
         artist: String? = nil,
         comments: String? = nil,
         tuningMIDI: [Int] = GuitarTuning.standard.midiNotes,
         tuningName: String = GuitarTuning.standard.name,
         capoOffsets: [Int] = [],
         beatsPerMeasure: Int = 4,
         noteValue: Int = 4,
         keyFifths: Int? = nil,
         bpm: Double? = nil,
         measures: [CanonicalMeasure] = [],
         provenance: Provenance = Provenance()) {
        self.title = title
        self.artist = artist
        self.comments = comments
        self.tuningMIDI = tuningMIDI
        self.tuningName = tuningName
        self.capoOffsets = capoOffsets
        self.beatsPerMeasure = beatsPerMeasure
        self.noteValue = noteValue
        self.keyFifths = keyFifths
        self.bpm = bpm
        self.measures = measures
        self.provenance = provenance
    }

    /// All notes flattened across measures, in document order.
    var allNotes: [CanonicalNote] {
        measures.flatMap(\.notes)
    }

    var measureCount: Int { measures.count }
}

// MARK: - CanonicalMeasure

/// One bar of the tab.
struct CanonicalMeasure: Codable, Equatable {
    /// 1-based measure number in the piece.
    var number: Int
    /// Notes within the measure, left-to-right (ascending `positionInMeasure`).
    var notes: [CanonicalNote]
    /// Beats in this measure (from time signature or a detected beat ruler).
    var beatCount: Int

    init(number: Int, notes: [CanonicalNote] = [], beatCount: Int = 4) {
        self.number = number
        self.notes = notes
        self.beatCount = beatCount
    }
}

// MARK: - CanonicalNote

/// A single note (or one voice of a chord) at a position within a measure.
///
/// Pitch is intentionally over-specified — `midiPitch` is the absolute truth,
/// while `staffStep`/`accidental` carry the diatonic spelling so MusicXML
/// `<step>/<octave>/<alter>` can be emitted without re-deriving an enharmonic
/// choice. `string`/`fret` carry the tab fingering (lossless).
struct CanonicalNote: Codable, Equatable {
    /// Fractional position within the measure (0.0 = start, 1.0 = end).
    var positionInMeasure: Double
    /// Duration in beats (quarter note = 1.0).
    var durationInBeats: Double

    /// Absolute MIDI pitch (e.g. 64 = E4).
    var midiPitch: Int
    /// Diatonic staff step, 0 = C4 (matches `StaffPitchMapper`).
    var staffStep: Int
    /// Accidental: -1 flat, 0 natural, +1 sharp.
    var accidental: Int

    /// String index, high-E-first (0–5). nil if not assigned to a string.
    var string: Int?
    /// Fret number on `string`. nil if not assigned.
    var fret: Int?

    /// True if this note sounds together with the previous note in the measure
    /// (i.e. part of the same chord / vertical stack).
    var isChordedWithPrevious: Bool

    init(positionInMeasure: Double,
         durationInBeats: Double,
         midiPitch: Int,
         staffStep: Int,
         accidental: Int,
         string: Int? = nil,
         fret: Int? = nil,
         isChordedWithPrevious: Bool = false) {
        self.positionInMeasure = positionInMeasure
        self.durationInBeats = durationInBeats
        self.midiPitch = midiPitch
        self.staffStep = staffStep
        self.accidental = accidental
        self.string = string
        self.fret = fret
        self.isChordedWithPrevious = isChordedWithPrevious
    }
}

// MARK: - Provenance

/// Where a canonical came from and how much to trust it. Drives the
/// confidence-gated display and lets canonicals be re-derived as converters
/// improve (see DESIGN.md §3, §6).
struct Provenance: Codable, Equatable {
    enum SourceType: String, Codable {
        case txtDirect    // parsed straight from an ASCII .txt
        case pdfText      // text extracted from a (vector) PDF, then parsed
        case ocr          // reconstructed via OCR/CV (future)
        case composed     // authored in the Maker
        case unknown
    }

    enum RhythmSource: String, Codable {
        case synthesized  // durations inferred from column spacing
        case midiAligned  // durations taken from a paired .mid
        case authored     // durations entered by the user
        case unknown
    }

    var sourceType: SourceType
    /// 0–1 estimate of conversion quality; gates standardized vs fallback view.
    var confidence: Double
    /// Version of the converter that produced this canonical. Lets us find and
    /// re-derive stale canonicals when the converter improves.
    var converterVersion: Int
    var rhythmSource: RhythmSource
    /// True if the source appeared cut off (e.g. a clipped PDF page).
    var clipped: Bool

    init(sourceType: SourceType = .unknown,
         confidence: Double = 0,
         converterVersion: Int = CanonicalConverterVersion.current,
         rhythmSource: RhythmSource = .unknown,
         clipped: Bool = false) {
        self.sourceType = sourceType
        self.confidence = confidence
        self.converterVersion = converterVersion
        self.rhythmSource = rhythmSource
        self.clipped = clipped
    }
}

/// Single source of truth for the current converter version. Bump whenever the
/// conversion logic changes in a way that should trigger re-derivation.
enum CanonicalConverterVersion {
    static let current = 1
}
