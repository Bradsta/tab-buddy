//
//  TutorContracts.swift
//  TabBuddy
//
//  Cross-package data types for the Tutor (see TUTOR_IMPLEMENTATION.md §2).
//  Pitches are sounding MIDI numbers (after capo). Times are seconds on the
//  take clock (0 = first input sample after listening starts), already
//  latency-corrected. Beats count from the passage start in the passage's own
//  beat unit: quarter notes for MIDI/alphaTab/exercise passages, the measure's
//  beat (e.g. the eighth in 3/8) for MeasureMap/Canonical passages. `bpm` is
//  in that same unit, so `time(ofBeat:)` is correct for every source.
//

import Foundation

enum TutorInstrument: String, Codable, CaseIterable, Identifiable, Sendable {
    case guitar
    case piano

    var id: String { rawValue }
    var displayName: String { self == .guitar ? "Guitar" : "Piano" }
}

/// Optional fingering hint; string 0 is the highest-pitched string (MeasureMap order).
struct FretPosition: Codable, Hashable, Sendable {
    var string: Int
    var fret: Int
}

/// Something the player is expected to sound.
struct ExpectedEvent: Codable, Hashable, Identifiable, Sendable {
    /// Index within its passage.
    var id: Int
    /// Sounding MIDI pitches. Empty means a rest (never graded).
    var pitches: [Int]
    /// Beat from the passage start, in the passage's beat unit (see header).
    var beat: Double
    var durationBeats: Double
    /// 0-based global measure index in the source score (or exercise).
    var measureIndex: Int
    /// 0..<1 within the measure.
    var positionInMeasure: Double
    var chordName: String? = nil
    var fretting: [FretPosition]? = nil
    /// Grade by pitch class (any octave, voicing, or inversion). Only slash
    /// chords (`chordName` containing "/") also require the lowest expected
    /// pitch class in the bass. Used for chord exercises whose symbols carry
    /// no register.
    var octaveTolerant: Bool = false
}

extension ExpectedEvent {
    private enum CodingKeys: String, CodingKey {
        case id, pitches, beat, durationBeats, measureIndex, positionInMeasure
        case chordName, fretting, octaveTolerant
    }

    /// Decodes older JSON that predates `octaveTolerant`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        pitches = try c.decode([Int].self, forKey: .pitches)
        beat = try c.decode(Double.self, forKey: .beat)
        durationBeats = try c.decode(Double.self, forKey: .durationBeats)
        measureIndex = try c.decode(Int.self, forKey: .measureIndex)
        positionInMeasure = try c.decode(Double.self, forKey: .positionInMeasure)
        chordName = try c.decodeIfPresent(String.self, forKey: .chordName)
        fretting = try c.decodeIfPresent([FretPosition].self, forKey: .fretting)
        octaveTolerant = try c.decodeIfPresent(Bool.self, forKey: .octaveTolerant) ?? false
    }
}

struct ExpectedPassage: Codable, Hashable, Sendable {
    var events: [ExpectedEvent]
    var beatsPerMeasure: Int
    var bpm: Double
    var instrument: TutorInstrument
    /// Free-time passages are graded on notes only, never on timing.
    var isFreeTime: Bool = false

    /// Nominal time of a beat at the passage tempo.
    func time(ofBeat beat: Double, tempoScale: Double = 1) -> TimeInterval {
        beat * 60 / max(1, bpm * tempoScale)
    }

    var measureRange: ClosedRange<Int>? {
        guard let lo = events.map(\.measureIndex).min(),
              let hi = events.map(\.measureIndex).max() else { return nil }
        return lo...hi
    }
}

enum DetectionSource: String, Codable, Sendable {
    case monophonic   // NoteTranscriberCore (tier A)
    case verifier     // score-informed check (tier B)
    case polyphonic   // post-take transcription (tier C)
}

/// Something the listener heard.
struct DetectedEvent: Codable, Hashable, Sendable {
    var time: TimeInterval
    var pitches: [Int]
    /// Per-pitch confidence 0...1, same order as `pitches`.
    var confidences: [Double]
    var source: DetectionSource
}

enum EventGrade: String, Codable, Sendable {
    case hit          // every expected pitch confidently heard
    case partial      // some expected pitches heard (chords)
    case wrongPitch   // something else was played instead
    case missed       // nothing matched
    case uncertain    // detector could not decide — never shown as an error
}

struct GradedEvent: Codable, Hashable, Sendable {
    var expectedID: Int
    var grade: EventGrade
    var matchedPitches: [Int]
    var missingPitches: [Int]
    /// Pitches played instead of the expected ones (wrongPitch / partial).
    var wrongPitches: [Int]
    var playedTime: TimeInterval?
    /// Offset from the local tempo line; negative = early.
    var timingOffsetMs: Double?
    var confidence: Double
}

struct ExtraNote: Codable, Hashable, Sendable {
    var time: TimeInterval
    var pitch: Int
    /// Expected event this extra followed, if any.
    var afterExpectedID: Int?
}

struct TempoSample: Codable, Hashable, Sendable {
    var beat: Double
    var bpm: Double
}

enum MeasureTendency: String, Codable, Sendable {
    case steady, rushing, dragging, unknown
}

struct TakeAnalysis: Codable, Hashable, Sendable {
    var graded: [GradedEvent]
    var extras: [ExtraNote]
    var tempoCurve: [TempoSample]
    var targetBPM: Double
    /// 0...1 over graded (non-uncertain) events; partial counts by pitch fraction.
    var accuracy: Double
    /// Median absolute timing deviation from the local tempo line, ms.
    var timingMADms: Double?
    /// Keyed by global measure index.
    var measureAccuracy: [Int: Double]
    var measureTendency: [Int: MeasureTendency]
    /// Human-readable next steps, e.g. "Loop measures 9–12 at 80%".
    var suggestions: [PracticeSuggestion]
}

struct PracticeSuggestion: Codable, Hashable, Sendable {
    var message: String
    var loopMeasures: ClosedRange<Int>?
    var tempoPercent: Double?
}

/// Live result for one armed expected event (tier B).
struct VerificationResult: Hashable, Sendable {
    var expectedID: Int
    var grade: EventGrade
    /// Expected pitches confidently present.
    var heard: [Int]
    /// Unexpected strong pitches at the same onset.
    var unexpected: [Int]
    var onsetTime: TimeInterval
    var confidence: Double
}
