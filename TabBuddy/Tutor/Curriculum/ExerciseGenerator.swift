//
//  ExerciseGenerator.swift
//  TabBuddy
//
//  Turns curriculum specs into concrete material: `ExerciseSpec` → graded
//  `ExpectedPassage` rounds (plus reference playback, target pitch sets, or an
//  allowed pitch-class set), `PlaybackSpec` → a playable note sequence, and
//  `SongStep` → a timed passage.
//

import Foundation

// MARK: - Playback

/// One sounding event of a demo or reference phrase.
struct PlaybackNote: Hashable, Sendable {
    /// MIDI pitches sounding together; empty = rest.
    var pitches: [Int]
    var startBeat: Double
    var durationBeats: Double
    var label: String? = nil
    var fretting: [FretPosition]? = nil
}

/// A playable note sequence for `TutorSynth` and diagram highlighting.
struct PlaybackSequence: Hashable, Sendable {
    var notes: [PlaybackNote]
    var bpm: Double
    /// `.arpeggio` input is already expanded into single notes; `.strum` asks the synth to roll chords.
    var style: PlaybackSpec.Style

    var totalBeats: Double { notes.map { $0.startBeat + $0.durationBeats }.max() ?? 0 }
    var durationSeconds: TimeInterval { totalBeats * 60 / max(1, bpm) }
    func startTime(of note: PlaybackNote) -> TimeInterval { note.startBeat * 60 / max(1, bpm) }
    /// Sounded notes only.
    var soundedNotes: [PlaybackNote] { notes.filter { !$0.pitches.isEmpty } }
    var allPitches: [Int] { Array(Set(notes.flatMap(\.pitches))).sorted() }
}

// MARK: - Exercises

/// How the lesson player runs an exercise.
enum ExercisePacing: String, Hashable, Sendable {
    /// Events in order; the cursor waits for each (no timing grade).
    case wait
    /// Events at `bpm` with a visual count-in; onset timing graded.
    case timed
    /// Any order, within `durationSec` (findAllNotes).
    case anyOrder
    /// Alternate chords for `durationSec`; count clean changes.
    case countChanges
    /// Free play for `durationSec`, graded on in-scale share (improvise).
    case free
}

/// One listen-then-play (or just play) unit.
struct ExerciseRound: Hashable, Sendable {
    /// Played before the learner answers (intervalPlayback, melodyEcho).
    var reference: PlaybackSequence?
    var expected: ExpectedPassage
    /// Answer name, e.g. "major third".
    var label: String?
}

struct GeneratedExercise: Hashable, Sendable {
    var kind: ExerciseKind
    var pacing: ExercisePacing
    /// At least one round; empty passage only for `.improvise`.
    var rounds: [ExerciseRound]
    var bpm: Double
    var tempoSteps: [Double]
    /// Fraction of events needed to pass. For `.chordChanges` it is derived
    /// from `changesPerMinuteTarget`: target changes in `durationSec` divided
    /// by the passage's chord count (the spec's own value is ignored).
    var passAccuracy: Double
    var durationSec: Double?
    /// `.chordChanges`: clean changes per minute needed to pass.
    var changesPerMinuteTarget: Double?
    /// findAllNotes: every playable MIDI note of the pitch class, ascending.
    var targetPitches: [Int] = []
    /// improvise: pitch classes counted as in-scale.
    var allowedPitchClasses: Set<PitchClass> = []
    var key: Key?
    var scale: Scale?
    /// Piano chord exercises: chord symbols carry no register, so grade pitch
    /// classes plus the lowest note's class (slash bass), octave-tolerantly.
    /// Kept for compatibility; the events themselves carry `octaveTolerant`.
    var gradeChordsByPitchClass = false

    /// First round's passage (the whole exercise for single-round kinds).
    var passage: ExpectedPassage { rounds[0].expected }
}

struct ExerciseGenerationError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    var message: String
    var description: String { message }
    var errorDescription: String? { message }
}

enum ExerciseGenerator {
    static let defaultBPM = 72.0

    /// Clean chord changes per minute needed to pass a chord-change drill.
    /// Beginners typically manage 5–15 a minute on a new pair; the goal rises
    /// with the stage. Guitar: stage ≤3 → 8, 4 → 10, 5 → 12, 6–7 → 14, 8+ → 16.
    /// Piano (block chords, one hand) starts at the same goal and rises a stage later.
    static func changesPerMinuteTarget(stage: Int?, instrument: TutorInstrument) -> Double {
        guard var stage else { return 8 }
        if instrument == .piano { stage -= 1 }
        switch stage {
        case ...3: return 8
        case 4: return 10
        case 5: return 12
        case 6, 7: return 14
        default: return 16
        }
    }

    /// Stage number from a lesson id ("guitar.s5.l2" → 5); nil for bonus lessons.
    static func stage(ofLessonID id: String) -> Int? {
        let parts = id.split(separator: ".")
        guard parts.count >= 2, parts[1].hasPrefix("s"), let n = Int(parts[1].dropFirst()) else { return nil }
        return n
    }
    static let defaultIntervals: [Interval] = [.m3, .M3, .P4, .P5, .P8]

    /// Builds an exercise. `intervals` feeds `.intervalPlayback` with a single
    /// root (see `intervals(forLesson:)`); `seed` fixes the interval order.
    /// `stage` (0-based course stage, see `stage(ofLessonID:)`) sets the
    /// chord-change goal; nil uses the beginner goal.
    static func generate(_ spec: ExerciseSpec,
                         context: InstrumentContext,
                         intervals: [Interval]? = nil,
                         seed: UInt64 = 1,
                         stage: Int? = nil) throws -> GeneratedExercise {
        var rng = SeededRandom(seed: seed)
        let instrument = context.instrument
        let key = try spec.key.map { try parse($0, "key", Key.init(parsing:)) }
        let scale = try spec.scale.map { try parse($0, "scale", Scale.init(parsing:)) }
        let bpm = spec.bpm ?? spec.tempoSteps?.first ?? defaultBPM
        let reps = max(1, spec.repetitions ?? 1)
        let hand = hand(for: spec)
        var result = GeneratedExercise(kind: spec.kind, pacing: .wait, rounds: [], bpm: bpm,
                                       tempoSteps: spec.tempoSteps ?? [], passAccuracy: spec.passAccuracy,
                                       durationSec: spec.durationSec, key: key, scale: scale)

        func notes() throws -> [Pitch] {
            guard let list = spec.notes, !list.isEmpty else { throw missing("notes") }
            return try list.map { try checkedPitch($0, context: context) }
        }
        func chords(minimum: Int = 1) throws -> [Chord] {
            guard let list = spec.chords, list.count >= minimum else {
                throw ExerciseGenerationError(message: "\(spec.kind.rawValue) needs at least \(minimum) chord(s) in \"chords\"")
            }
            return try list.map { try parse($0, "chord", Chord.init(parsing:)) }
        }

        switch spec.kind {
        case .playNote:
            let line = Array(repeating: try notes().map { [$0.midi] }, count: reps).flatMap { $0 }
            result.rounds = [ExerciseRound(reference: nil, expected: passage(line, bpm: bpm, context: context, freeTime: true))]

        case .playSequence:
            let pitches = try notes()
            let line = Array(repeating: pitches.map { [$0.midi] }, count: reps).flatMap { $0 }
            if let rhythmText = spec.rhythm {
                let rhythm = try parse(rhythmText, "rhythm", RhythmPattern.init(parsing:))
                let (groups, durations) = try applyRhythm(rhythm, toSounded: line)
                result.rounds = [ExerciseRound(reference: nil,
                                               expected: passage(groups, durations: durations, bpm: bpm,
                                                                 beatsPerMeasure: beatsPerMeasure(for: spec), context: context))]
            } else {
                result.rounds = [ExerciseRound(reference: nil,
                                               expected: passage(line, bpm: bpm, context: context, freeTime: spec.bpm == nil))]
            }
            result.pacing = spec.bpm == nil ? .wait : .timed

        case .playChord:
            let list = try chords()
            let voiced = Array(repeating: list, count: reps).flatMap { $0 }
            result.rounds = [ExerciseRound(reference: nil,
                                           expected: chordPassage(voiced, beatsEach: 4, bpm: bpm, context: context,
                                                                  hand: hand, freeTime: true))]
            result.gradeChordsByPitchClass = instrument == .piano
            result.rounds = result.rounds.map { markOctaveTolerant($0, when: instrument == .piano) }

        case .chordChanges:
            let list = try chords(minimum: 2)
            let duration = spec.durationSec ?? 60
            // One change every two beats at the exercise tempo (60 BPM → 2 s per chord).
            let changeBPM = spec.bpm ?? 60
            let perMinute = changesPerMinuteTarget(stage: stage, instrument: instrument)
            let goal = max(2, (perMinute * duration / 60).rounded(.up))
            // Enough chords for strong players (the tempo's pace or 40 a minute),
            // and at least half again the goal.
            let paced = Int((duration / (2 * 60 / changeBPM)).rounded(.down))
            let count = max(list.count * 2, paced, Int((40 * duration / 60).rounded(.down)), Int(goal * 1.5))
            let sequence = (0..<count).map { list[$0 % list.count] }
            result.rounds = [ExerciseRound(reference: nil,
                                           expected: chordPassage(sequence, beatsEach: 2, bpm: changeBPM, context: context,
                                                                  hand: hand, freeTime: true))]
            result.gradeChordsByPitchClass = instrument == .piano
            result.rounds = result.rounds.map { markOctaveTolerant($0, when: instrument == .piano) }
            result.pacing = .countChanges
            result.durationSec = duration
            result.bpm = changeBPM
            // The run passes at `goal` clean chords: accuracy = clean / count.
            result.changesPerMinuteTarget = perMinute
            result.passAccuracy = min(1, goal / Double(count))

        case .strumRhythm:
            let list = try chords()
            guard let rhythmText = spec.rhythm else { throw missing("rhythm") }
            let rhythm = try parse(rhythmText, "rhythm", RhythmPattern.init(parsing:))
            var groups: [[Int]] = [], durations: [Double] = [], names: [String?] = [], fretting: [[FretPosition]?] = []
            for chord in Array(repeating: list, count: reps).flatMap({ $0 }) {
                let voicing = context.voicing(for: chord, hand: hand)
                for event in rhythm.events {
                    groups.append(event.isRest ? [] : voicing.midi)
                    durations.append(event.beats)
                    names.append(event.isRest ? nil : chord.symbol)
                    fretting.append(event.isRest ? nil : voicing.fretting)
                }
            }
            result.rounds = [ExerciseRound(reference: nil,
                                           expected: passage(groups, durations: durations, bpm: bpm,
                                                             beatsPerMeasure: beatsPerMeasure(for: spec), context: context,
                                                             names: names, fretting: fretting))]
            result.pacing = .timed
            result.gradeChordsByPitchClass = instrument == .piano
            result.rounds = result.rounds.map { markOctaveTolerant($0, when: instrument == .piano) }

        case .scale:
            guard let scale else { throw missing("scale") }
            let pitches = context.scalePitches(scale, octaves: spec.octaves ?? 1, upAndDown: true)
            try checkRange(pitches.map(\.midi), context: context, what: "scale \(scale.name)")
            let line = Array(repeating: pitches.map { [$0.midi] }, count: reps).flatMap { $0 }
            result.rounds = [ExerciseRound(reference: nil, expected: passage(line, bpm: bpm, context: context))]
            result.pacing = .timed

        case .findAllNotes:
            guard let pcText = spec.pitchClass else { throw missing("pitchClass") }
            let pc = try parse(pcText, "pitch class", PitchClass.init(parsing:))
            let range = context.comfortableRange
            let targets = range.filter { PitchClass($0) == pc && isPlayable($0, context: context) }
            guard !targets.isEmpty else { throw ExerciseGenerationError(message: "no playable \(pcText) in range") }
            result.targetPitches = targets
            result.rounds = [ExerciseRound(reference: nil,
                                           expected: passage(targets.map { [$0] }, bpm: bpm, context: context, freeTime: true))]
            result.pacing = .anyOrder
            result.durationSec = spec.durationSec ?? 30

        case .intervalPlayback:
            let given = try notes()
            var rounds: [ExerciseRound] = []
            if given.count >= 2 {
                let label = Interval.between(given[0], given[1]).map(\.name)
                for _ in 0..<reps {
                    let pair = given.map { [$0.midi] }
                    rounds.append(ExerciseRound(reference: playback(pair, bpm: bpm, context: context),
                                                expected: passage(pair, bpm: bpm, context: context, freeTime: true),
                                                label: label))
                }
            } else {
                let root = given[0]
                let pool = (intervals ?? defaultIntervals).filter {
                    context.playableRange.contains(root.midi + $0.semitones)
                }
                guard !pool.isEmpty else { throw ExerciseGenerationError(message: "no interval above \(root.name) fits the instrument") }
                var previous: Interval?
                for _ in 0..<reps {
                    var interval = pool.randomElement(using: &rng)!
                    if pool.count > 1, interval == previous { interval = pool.filter { $0 != previous }.randomElement(using: &rng)! }
                    previous = interval
                    let pair = [[root.midi], [root.transposed(by: interval).midi]]
                    rounds.append(ExerciseRound(reference: playback(pair, bpm: bpm, context: context),
                                                expected: passage(pair, bpm: bpm, context: context, freeTime: true),
                                                label: interval.name))
                }
            }
            result.rounds = rounds

        case .melodyEcho:
            let line = try notes().map { [$0.midi] }
            let durations: [Double]?
            if let rhythmText = spec.rhythm {
                let rhythm = try parse(rhythmText, "rhythm", RhythmPattern.init(parsing:))
                durations = rhythm.events.filter { !$0.isRest }.map(\.beats)
            } else {
                durations = nil
            }
            result.rounds = (0..<reps).map { _ in
                ExerciseRound(reference: playback(line, durations: durations, bpm: bpm, context: context),
                              expected: passage(line, durations: durations, bpm: bpm, context: context, freeTime: true))
            }

        case .improvise:
            guard let pool = scale ?? key?.scale else {
                throw ExerciseGenerationError(message: "improvise needs \"scale\" or \"key\"")
            }
            result.allowedPitchClasses = pool.pitchClassSet
            result.rounds = [ExerciseRound(reference: nil,
                                           expected: ExpectedPassage(events: [], beatsPerMeasure: 4, bpm: bpm,
                                                                     instrument: instrument, isFreeTime: false))]
            result.pacing = .free
            result.durationSec = spec.durationSec ?? 60
            result.scale = pool
        }
        return result
    }

    /// Interval set for `.intervalPlayback` taken from the lesson: its interval
    /// quiz generators' `intervals` params, else its earInterval review answers.
    static func intervals(forLesson lesson: Lesson) -> [Interval]? {
        var found: [Interval] = []
        for step in lesson.steps {
            guard case .quiz(let quiz) = step, let generator = quiz.generator,
                  generator.kind == .intervalByEar || generator.kind == .intervalByName,
                  let list = generator.params["intervals"] else { continue }
            found += list.split(separator: ",").compactMap { Interval(String($0).trimmingCharacters(in: .whitespaces)) }
        }
        if found.isEmpty {
            found = lesson.reviewItems.filter { $0.kind == .earInterval }.compactMap { parseIntervalName($0.answer) }
        }
        var seen = Set<Interval>()
        let unique = found.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }

    /// Intervals taught up to and including `lessonID` (main path in order, plus
    /// the lesson itself when it is on a branch). Nil when none are named, in
    /// which case `defaultIntervals` apply.
    static func intervalsTaught(through lessonID: String, in course: Course) -> [Interval]? {
        var lessons: [Lesson] = []
        for lesson in course.mainPathLessons {
            lessons.append(lesson)
            if lesson.id == lessonID { break }
        }
        if let location = course.location(ofLesson: lessonID), !location.isOnMainPath {
            lessons.append(location.lesson)
        }
        var seen = Set<Interval>()
        let all = lessons.compactMap { intervals(forLesson: $0) }.flatMap { $0 }.filter { seen.insert($0).inserted }
        return all.isEmpty ? nil : all.sorted { $0.semitones < $1.semitones }
    }

    /// Accepts "M3", "major third", and "Major 3rd".
    static func parseIntervalName(_ text: String) -> Interval? {
        Interval(text) ?? Interval(text.lowercased())
    }

    // MARK: Songs

    /// Timed passage for a song excerpt: one rhythm token per event; rest tokens and empty events are silent.
    static func passage(for song: SongStep, context: InstrumentContext) throws -> ExpectedPassage {
        let rhythm = try parse(song.rhythm, "rhythm", RhythmPattern.init(parsing:))
        let (groups, names, fretting) = try songEvents(notes: song.notes, chords: song.chords, context: context)
        guard groups.count == rhythm.events.count else {
            throw ExerciseGenerationError(message: "song has \(groups.count) events but \(rhythm.events.count) rhythm tokens")
        }
        let sounded = zip(groups, rhythm.events).map { $1.isRest ? [] : $0 }
        let built = passage(sounded, durations: rhythm.events.map(\.beats), bpm: song.bpm,
                            beatsPerMeasure: song.beatsPerMeasure, context: context, names: names, fretting: fretting)
        // Chord symbols carry no register on piano; explicit pitches stay exact.
        let fromSymbols = song.notes == nil && song.chords != nil
        return markOctaveTolerant(built, when: context.instrument == .piano && fromSymbols)
    }

    /// Marks every event octave-tolerant (pitch classes in any octave, lowest class as bass).
    static func markOctaveTolerant(_ passage: ExpectedPassage, when condition: Bool) -> ExpectedPassage {
        guard condition else { return passage }
        var marked = passage
        for i in marked.events.indices { marked.events[i].octaveTolerant = true }
        return marked
    }

    private static func markOctaveTolerant(_ round: ExerciseRound, when condition: Bool) -> ExerciseRound {
        var r = round
        r.expected = markOctaveTolerant(round.expected, when: condition)
        return r
    }

    /// Song as playback (for "hear it first").
    static func playback(for song: SongStep, context: InstrumentContext) throws -> PlaybackSequence {
        let rhythm = try parse(song.rhythm, "rhythm", RhythmPattern.init(parsing:))
        let (groups, names, fretting) = try songEvents(notes: song.notes, chords: song.chords, context: context)
        let sounded = zip(groups, rhythm.events).map { $1.isRest ? [] : $0 }
        return sequence(sounded, durations: rhythm.events.map(\.beats), bpm: song.bpm, style: song.chords == nil ? .sequence : .strum,
                        names: names, fretting: fretting)
    }

    private static func songEvents(notes: [[String]]?, chords: [String]?, context: InstrumentContext) throws
        -> (groups: [[Int]], names: [String?], fretting: [[FretPosition]?]) {
        if let notes {
            let groups = try notes.map { try $0.map { try checkedPitch($0, context: context).midi } }
            return (groups, groups.map { _ in nil }, context.fretting(forLine: groups))
        }
        if let chords {
            var groups: [[Int]] = [], names: [String?] = [], fretting: [[FretPosition]?] = []
            for symbol in chords {
                let chord = try parse(symbol, "chord", Chord.init(parsing:))
                let voicing = context.voicing(for: chord)
                groups.append(voicing.midi)
                names.append(chord.symbol)
                fretting.append(voicing.fretting)
            }
            return (groups, names, fretting)
        }
        throw ExerciseGenerationError(message: "song needs \"notes\" or \"chords\"")
    }

    // MARK: Playback specs

    /// Demo playback. Order of precedence: `notes`, then `chords`, then `scale`.
    /// `rhythm` gives one token per event when the counts match; otherwise the
    /// pattern repeats, rests adding silence without consuming an event. With
    /// no rhythm, notes last one beat and chords two.
    static func playback(for spec: PlaybackSpec, context: InstrumentContext) throws -> PlaybackSequence {
        var groups: [[Int]] = [], names: [String?] = [], fretting: [[FretPosition]?] = []
        var defaultBeats = 1.0
        if let notes = spec.notes {
            groups = try notes.map { try $0.map { try checkedPitch($0, context: context).midi } }
            names = groups.map { _ in nil }
            fretting = context.fretting(forLine: groups)
        } else if let chords = spec.chords {
            for symbol in chords {
                let chord = try parse(symbol, "chord", Chord.init(parsing:))
                let voicing = context.voicing(for: chord)
                groups.append(voicing.midi)
                names.append(chord.symbol)
                fretting.append(voicing.fretting)
            }
            defaultBeats = 2
        } else if let scaleText = spec.scale {
            let scale = try parse(scaleText, "scale", Scale.init(parsing:))
            let pitches = context.scalePitches(scale, octaves: spec.octaves ?? 1, upAndDown: true)
            groups = pitches.map { [$0.midi] }
            names = pitches.map { $0.note.name }
            fretting = context.fretting(forLine: groups)
        } else if let rhythmText = spec.rhythm {
            // Rhythm alone: a click-like note on each onset (A4 / open A string).
            let rhythm = try parse(rhythmText, "rhythm", RhythmPattern.init(parsing:))
            let tone = context.instrument == .guitar ? 45 : 69
            let events = rhythm.events.map { $0.isRest ? [Int]() : [tone] }
            return sequence(events, durations: rhythm.events.map(\.beats), bpm: spec.bpm, style: spec.style,
                            names: events.map { _ in nil }, fretting: events.map { _ in nil })
        } else {
            throw ExerciseGenerationError(message: "playback needs notes, chords, scale, or rhythm")
        }

        var durations = groups.map { _ in defaultBeats }
        if let rhythmText = spec.rhythm, spec.scale == nil || spec.notes != nil || spec.chords != nil {
            let rhythm = try parse(rhythmText, "rhythm", RhythmPattern.init(parsing:))
            if rhythm.events.count == groups.count {
                groups = zip(groups, rhythm.events).map { $1.isRest ? [] : $0 }
                durations = rhythm.events.map(\.beats)
            } else {
                (groups, durations, names, fretting) = cycle(rhythm, groups: groups, names: names, fretting: fretting)
            }
        }
        return sequence(groups, durations: durations, bpm: spec.bpm, style: spec.style, names: names, fretting: fretting)
    }

    /// Repeats `rhythm` over the events; rests insert silence.
    private static func cycle(_ rhythm: RhythmPattern, groups: [[Int]], names: [String?], fretting: [[FretPosition]?])
        -> ([[Int]], [Double], [String?], [[FretPosition]?]) {
        var g: [[Int]] = [], d: [Double] = [], n: [String?] = [], f: [[FretPosition]?] = []
        guard rhythm.noteCount > 0 else { return (groups, groups.map { _ in 1 }, names, fretting) }
        var i = 0, t = 0
        while i < groups.count {
            let event = rhythm.events[t % rhythm.events.count]
            t += 1
            d.append(event.beats)
            if event.isRest {
                g.append([]); n.append(nil); f.append(nil)
            } else {
                g.append(groups[i]); n.append(names[i]); f.append(fretting[i])
                i += 1
            }
        }
        return (g, d, n, f)
    }

    private static func sequence(_ groups: [[Int]], durations: [Double], bpm: Double, style: PlaybackSpec.Style,
                                 names: [String?], fretting: [[FretPosition]?]) -> PlaybackSequence {
        var notes: [PlaybackNote] = []
        var beat = 0.0
        for (i, group) in groups.enumerated() {
            let duration = durations.indices.contains(i) ? durations[i] : 1
            let label = names.indices.contains(i) ? names[i] : nil
            let frets = fretting.indices.contains(i) ? fretting[i] : nil
            if style == .arpeggio, group.count > 1 {
                let step = duration / Double(group.count)
                for (j, pitch) in group.sorted().enumerated() {
                    notes.append(PlaybackNote(pitches: [pitch], startBeat: beat + Double(j) * step,
                                              durationBeats: duration - Double(j) * step, label: label, fretting: nil))
                }
            } else {
                notes.append(PlaybackNote(pitches: group.sorted(), startBeat: beat, durationBeats: duration,
                                          label: label, fretting: frets))
            }
            beat += duration
        }
        return PlaybackSequence(notes: notes, bpm: bpm > 0 ? bpm : 80, style: style)
    }

    private static func playback(_ groups: [[Int]], durations: [Double]? = nil, bpm: Double,
                                 context: InstrumentContext) -> PlaybackSequence {
        sequence(groups, durations: durations ?? groups.map { _ in 1 }, bpm: bpm, style: .sequence,
                 names: groups.map { _ in nil }, fretting: context.fretting(forLine: groups))
    }

    // MARK: Passage assembly

    /// Maps sounded rhythm tokens onto pitch groups, repeating the pattern when it is shorter.
    static func applyRhythm(_ rhythm: RhythmPattern, toSounded line: [[Int]]) throws -> ([[Int]], [Double]) {
        guard rhythm.noteCount > 0 else { throw ExerciseGenerationError(message: "rhythm has no sounded notes") }
        if rhythm.events.count == line.count, rhythm.noteCount != line.count {
            // One token per note, rests included in place of notes.
            return (zip(line, rhythm.events).map { $1.isRest ? [] : $0 }, rhythm.events.map(\.beats))
        }
        var groups: [[Int]] = [], durations: [Double] = []
        var i = 0, t = 0
        while i < line.count {
            let event = rhythm.events[t % rhythm.events.count]
            t += 1
            durations.append(event.beats)
            if event.isRest { groups.append([]) } else { groups.append(line[i]); i += 1 }
        }
        return (groups, durations)
    }

    private static func chordPassage(_ chords: [Chord], beatsEach: Double, bpm: Double,
                                     context: InstrumentContext, hand: InstrumentContext.Hand,
                                     freeTime: Bool) -> ExpectedPassage {
        let voicings = chords.map { context.voicing(for: $0, hand: hand) }
        return passage(voicings.map(\.midi), durations: chords.map { _ in beatsEach }, bpm: bpm, context: context,
                       freeTime: freeTime, names: chords.map(\.symbol), fretting: voicings.map(\.fretting))
    }

    /// Builds the passage with `PassageBuilder` and attaches names/fret hints.
    /// Empty groups are rests (no event, time still advances).
    /// Meter of a content exercise: a time signature named in the prompt or the
    /// rhythm diagram's caption ("3/4 pattern…"), else the diagram's rhythm length
    /// (three beats = 3/4), else 4. Same rule as the rhythm diagram, so the Try it
    /// strip's measures match the diagram above it.
    static func beatsPerMeasure(for spec: ExerciseSpec) -> Int {
        let text = [spec.prompt, spec.diagram?.caption ?? ""].joined(separator: " ")
        let pattern = spec.diagram?.kind == .rhythm ? spec.diagram?.rhythm.flatMap { RhythmPattern($0) } : nil
        return RhythmStripModel.inferBeatsPerMeasure(pattern: pattern, caption: text)
    }

    static func passage(_ groups: [[Int]], durations: [Double]? = nil, bpm: Double, beatsPerMeasure: Int = 4,
                        context: InstrumentContext, freeTime: Bool = false,
                        names: [String?]? = nil, fretting: [[FretPosition]?]? = nil) -> ExpectedPassage {
        var built = PassageBuilder.from(pitchEvents: groups, durations: durations, bpm: bpm,
                                        beatsPerMeasure: beatsPerMeasure, instrument: context.instrument,
                                        isFreeTime: freeTime, chordNames: names)
        let hints = fretting ?? context.fretting(forLine: groups)
        let soundedHints = zip(groups, hints).filter { !$0.0.filter { (0...127).contains($0) }.isEmpty }.map(\.1)
        if context.instrument == .guitar, soundedHints.count == built.events.count {
            for i in built.events.indices {
                built.events[i].fretting = soundedHints[i]
            }
        }
        return built
    }

    // MARK: Parsing helpers

    static func parse<T>(_ text: String, _ what: String, _ make: (String) throws -> T) throws -> T {
        do { return try make(text) } catch let error as TheoryParseError {
            throw ExerciseGenerationError(message: error.description)
        } catch {
            throw ExerciseGenerationError(message: "invalid \(what) \"\(text)\"")
        }
    }

    static func checkedPitch(_ text: String, context: InstrumentContext) throws -> Pitch {
        let pitch = try parse(text, "pitch", Pitch.init(parsing:))
        guard context.playableRange.contains(pitch.midi) else {
            throw ExerciseGenerationError(message: "\(text) is outside the \(context.instrument.rawValue) range")
        }
        return pitch
    }

    private static func checkRange(_ midi: [Int], context: InstrumentContext, what: String) throws {
        let range = context.playableRange
        guard midi.allSatisfy({ range.contains($0) }) else {
            throw ExerciseGenerationError(message: "\(what) leaves the \(context.instrument.rawValue) range")
        }
    }

    private static func isPlayable(_ midi: Int, context: InstrumentContext) -> Bool {
        context.instrument == .guitar ? !context.fretboard.positions(ofMIDI: midi).isEmpty : context.keyboard.contains(midi)
    }

    private static func passage(_ line: [[Int]], bpm: Double, context: InstrumentContext, freeTime: Bool = false) -> ExpectedPassage {
        passage(line, durations: nil, bpm: bpm, context: context, freeTime: freeTime)
    }

    /// Left hand when the prompt says so (piano chord register).
    static func hand(for spec: ExerciseSpec) -> InstrumentContext.Hand {
        spec.prompt.lowercased().contains("left hand") ? .left : .right
    }

    private static func missing(_ field: String) -> ExerciseGenerationError {
        ExerciseGenerationError(message: "missing \"\(field)\"")
    }
}
