//
//  CurriculumModel.swift
//  TabBuddy
//
//  Bundled lesson content schema (TUTOR_IMPLEMENTATION.md §6). Content lives in
//  Tutor/Content as `tutor-<instrument>-stage-NN.json` (one Stage per file) and
//  `tutor-glossary.json`. Pitches are written in scientific notation ("E2",
//  "C#4", "Bb3"); chords as symbols ("Am7", "C/G"); scales as "<root> <type>"
//  ("G major", "A minor pentatonic"); keys as "<tonic> major|minor"; rhythms as
//  tokens ("q q e e q", see Theory/Rhythm).
//

import Foundation

struct Course: Hashable, Sendable {
    var instrument: TutorInstrument
    var title: String
    var stages: [Stage]
}

struct Stage: Codable, Hashable, Identifiable, Sendable {
    var id: String              // e.g. "guitar.s3"
    var instrument: TutorInstrument
    var order: Int
    var title: String
    var summary: String
    var lessons: [Lesson]
    @Defaulted<EmptyList<Branch>> var branches: [Branch] = []
}

/// Optional detour. Unlocks after `unlocksAfter` (a lesson id on the main
/// path) and never blocks main-path progress.
struct Branch: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var summary: String
    var unlocksAfter: String
    var lessons: [Lesson]
}

struct Lesson: Codable, Hashable, Identifiable, Sendable {
    var id: String              // e.g. "guitar.s3.l2"
    var title: String
    var summary: String
    var minutes: Int
    var steps: [LessonStep]
    @Defaulted<EmptyList<ReviewItemSeed>> var reviewItems: [ReviewItemSeed] = []
    @Defaulted<EmptyList<String>> var glossaryTerms: [String] = []
}

/// A flashcard for the Flashcards section (shown once its chapter is marked read, or for all chapters).
struct ReviewItemSeed: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: ReviewKind
    var prompt: String
    var answer: String
    /// Optional audio/diagram support for the card.
    var playback: PlaybackSpec? = nil
    var diagram: Diagram? = nil
}

enum ReviewKind: String, Codable, Sendable {
    case fact          // text recall, self-graded
    case noteName      // name the highlighted note
    case playNote      // play the named note ("hear it / play it", not graded)
    case playChord     // play the named chord ("hear it / play it", not graded)
    case earInterval   // hear, name the interval
    case earQuality    // hear, name the chord quality
}

// MARK: - Steps

enum LessonStep: Hashable, Sendable {
    case explain(ExplainStep)
    case demo(DemoStep)
    case practice(PracticeStep)
    case quiz(QuizStep)
    case song(SongStep)
}

extension LessonStep: Codable {
    private enum CodingKeys: String, CodingKey { case type }
    private enum Kind: String, Codable { case explain, demo, practice, quiz, song }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .type)
        switch kind {
        case .explain: self = .explain(try ExplainStep(from: decoder))
        case .demo: self = .demo(try DemoStep(from: decoder))
        case .practice: self = .practice(try PracticeStep(from: decoder))
        case .quiz: self = .quiz(try QuizStep(from: decoder))
        case .song: self = .song(try SongStep(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .explain(let s): try container.encode(Kind.explain, forKey: .type); try s.encode(to: encoder)
        case .demo(let s): try container.encode(Kind.demo, forKey: .type); try s.encode(to: encoder)
        case .practice(let s): try container.encode(Kind.practice, forKey: .type); try s.encode(to: encoder)
        case .quiz(let s): try container.encode(Kind.quiz, forKey: .type); try s.encode(to: encoder)
        case .song(let s): try container.encode(Kind.song, forKey: .type); try s.encode(to: encoder)
        }
    }
}

struct ExplainStep: Codable, Hashable, Sendable {
    var title: String
    /// Markdown (inline styles, lists, short paragraphs).
    var body: String
    var diagram: Diagram? = nil
    /// Optional "hear it" button under the text.
    var playback: PlaybackSpec? = nil
}

struct DemoStep: Codable, Hashable, Sendable {
    var title: String
    var caption: String
    var playback: PlaybackSpec
    /// Highlighted in sync with playback when present.
    var diagram: Diagram? = nil
}

struct Diagram: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case fretboard, keyboard, staff, circleOfFifths, rhythm, intervalLadder
    }
    enum Labels: String, Codable, Sendable { case noteNames, degrees, intervals, fingers, none }

    var kind: Kind
    var scale: String? = nil
    var chord: String? = nil
    /// Explicit pitches ("E2") or, for fretboards, "string:fret" pairs ("6:3" =
    /// low E string fret 3; string numbers are guitarist numbering, 1 = high E).
    var notes: [String]? = nil
    var key: String? = nil
    var rhythm: String? = nil
    @Defaulted<NoteNameLabels> var labels: Labels = .noteNames
    /// Visible fret window for fretboards, e.g. [0, 5].
    var fretRange: [Int]? = nil
    /// Visible key window for keyboards/staff, e.g. ["C4", "B4"].
    var pitchRange: [String]? = nil
    var caption: String? = nil
}

struct PlaybackSpec: Codable, Hashable, Sendable {
    enum Style: String, Codable, Sendable { case block, arpeggio, sequence, strum }
    /// Each inner array sounds together; outer array plays in order.
    var notes: [[String]]? = nil
    var chords: [String]? = nil
    var scale: String? = nil
    var octaves: Int? = nil
    var rhythm: String? = nil
    @Defaulted<DefaultBPM> var bpm: Double = 80
    @Defaulted<SequenceStyle> var style: Style = .sequence
}

struct PracticeStep: Codable, Hashable, Sendable {
    var exercise: ExerciseSpec
    /// Shown as a static "Tips" disclosure in the Try it box.
    @Defaulted<EmptyList<String>> var mistakeTips: [String] = []
}

enum ExerciseKind: String, Codable, Sendable {
    case playNote          // play the listed note(s), wait mode
    case findAllNotes      // play every position/octave of `pitchClass` in `durationSec`
    case playSequence      // play `notes` in order (wait or timed with bpm)
    case playChord         // sound each chord in `chords` once, wait mode
    case chordChanges      // alternate `chords` for `durationSec`, count clean changes
    case strumRhythm       // strum `chords` in `rhythm` at `bpm` (onset timing graded)
    case scale             // play `scale` over `octaves`, up then down
    case intervalPlayback  // hear an interval, play it back from the given root
    case melodyEcho        // hear a short phrase, play it back
    case improvise         // play freely over `key`/`scale`; graded on in-scale %, rhythm
}

struct ExerciseSpec: Codable, Hashable, Sendable {
    var kind: ExerciseKind
    var prompt: String
    var notes: [String]? = nil
    var chords: [String]? = nil
    var scale: String? = nil
    var octaves: Int? = nil
    var key: String? = nil
    var bpm: Double? = nil
    /// Suggested tempos, e.g. [60, 70, 80]; shown as tempo chips. The first seeds the tempo.
    var tempoSteps: [Double]? = nil
    var durationSec: Double? = nil
    var rhythm: String? = nil
    var repetitions: Int? = nil
    var pitchClass: String? = nil
    /// Kept for content compatibility; the Try it box does not grade.
    @Defaulted<PassAccuracy80> var passAccuracy: Double = 0.8
    /// Optional fixed diagram shown during the exercise.
    var diagram: Diagram? = nil
}

struct QuizStep: Codable, Hashable, Sendable {
    @Defaulted<QuizTitle> var title: String = "Quiz"
    var questions: [QuizQuestion]? = nil
    var generator: QuizGeneratorSpec? = nil
    /// Number of generated questions (ignored for fixed questions).
    @Defaulted<FiveQuestions> var count: Int = 5
}

struct QuizQuestion: Codable, Hashable, Sendable {
    var prompt: String
    var choices: [String]
    var answerIndex: Int
    var explanation: String
    var playback: PlaybackSpec? = nil
    var diagram: Diagram? = nil
}

enum QuizGeneratorKind: String, Codable, Sendable {
    case noteOnFretboard, noteOnKeyboard, noteOnStaff
    case intervalByEar, intervalByName
    case chordQualityByEar, chordSpelling
    case keySignature, romanNumeral
    case scaleDegreeByEar, scaleSpelling
    case rhythmCount
}

struct QuizGeneratorSpec: Codable, Hashable, Sendable {
    var kind: QuizGeneratorKind
    /// Free-form parameters, e.g. {"intervals": "m3,M3,P5", "strings": "6,5",
    /// "fretMax": "5", "keys": "C,G,D,F", "qualities": "maj,min", "clef": "treble"}.
    @Defaulted<EmptyParams> var params: [String: String] = [:]
}

/// Short in-app excerpt (public-domain or original melodies only).
struct SongStep: Codable, Hashable, Sendable {
    var title: String
    var caption: String? = nil
    /// Each inner array sounds together.
    var notes: [[String]]? = nil
    var chords: [String]? = nil
    /// One rhythm token per event.
    var rhythm: String
    var bpm: Double
    @Defaulted<FourBeats> var beatsPerMeasure: Int = 4
    /// Kept for content compatibility; song boxes do not grade.
    @Defaulted<PassAccuracy75> var passAccuracy: Double = 0.75
}

struct GlossaryEntry: Codable, Hashable, Identifiable, Sendable {
    var term: String
    var definition: String
    @Defaulted<EmptyList<String>> var seeAlso: [String] = []
    var id: String { term.lowercased() }
}

// MARK: - Optional keys with defaults

/// Lets content JSON omit keys that have a default. Synthesized `Codable`
/// otherwise requires every non-optional key.
protocol DefaultValueProvider {
    associatedtype Value: Codable & Hashable & Sendable
    static var defaultValue: Value { get }
}

@propertyWrapper
struct Defaulted<Provider: DefaultValueProvider>: Codable, Hashable, Sendable {
    var wrappedValue: Provider.Value

    init(wrappedValue: Provider.Value) { self.wrappedValue = wrappedValue }
    init() { wrappedValue = Provider.defaultValue }

    init(from decoder: Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(Provider.Value.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode<P>(_ type: Defaulted<P>.Type, forKey key: Key) throws -> Defaulted<P> {
        try decodeIfPresent(type, forKey: key) ?? Defaulted()
    }
}

enum EmptyList<Element: Codable & Hashable & Sendable>: DefaultValueProvider {
    static var defaultValue: [Element] { [] }
}
enum EmptyParams: DefaultValueProvider { static var defaultValue: [String: String] { [:] } }
enum NoteNameLabels: DefaultValueProvider { static var defaultValue: Diagram.Labels { .noteNames } }
enum SequenceStyle: DefaultValueProvider { static var defaultValue: PlaybackSpec.Style { .sequence } }
enum DefaultBPM: DefaultValueProvider { static var defaultValue: Double { 80 } }
enum PassAccuracy80: DefaultValueProvider { static var defaultValue: Double { 0.8 } }
enum PassAccuracy75: DefaultValueProvider { static var defaultValue: Double { 0.75 } }
enum QuizTitle: DefaultValueProvider { static var defaultValue: String { "Quiz" } }
enum FiveQuestions: DefaultValueProvider { static var defaultValue: Int { 5 } }
enum FourBeats: DefaultValueProvider { static var defaultValue: Int { 4 } }
