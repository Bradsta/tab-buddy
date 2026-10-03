//
//  QuickPracticeModels.swift
//  TabBuddy
//
//  Specs for the Practice section: a scale (root, type, octaves, guitar fret
//  window), a chord (root, quality, play style), an interval (root, interval,
//  direction), and a rhythm (tokens). Each spec turns into a diagram, an
//  example `PlaybackSequence`, and a `GeneratedExercise` that a `TryItModel`
//  plays and listens to. The exercise index lists every Try it box and song
//  in the course by kind so a learner can jump straight to it.
//

import Foundation

// MARK: - Roots

enum QuickPracticeRoots {
    /// Twelve roots with their common spellings.
    static let all: [SpelledNote] = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"].compactMap { SpelledNote($0) }

    /// "C♯ / D♭" style label for a root chip.
    static func label(_ note: SpelledNote) -> String {
        guard note.accidental != 0 else { return note.displayName }
        let other = SpelledNote.common(for: note.pitchClass, preferSharps: note.accidental < 0)
        return "\(note.displayName) / \(other.displayName)"
    }
}

// MARK: - Scales

struct ScalePracticeSpec: Hashable {
    var root: SpelledNote = .C
    var type: ScaleType = .major
    /// 1 or 2.
    var octaves: Int = 1
    /// Guitar only: lowest fret of a five-fret window (0 = open position). Nil uses the course's default start.
    var fretWindow: Int? = nil
    var labels: Diagram.Labels = .noteNames

    /// Window starts offered for guitar.
    static let fretWindows: [Int] = [0, 2, 4, 5, 7, 9, 12]
    static let windowSpan = 4

    var scale: Scale { Scale(root: root, type: type) }
    var title: String { scale.displayName }

    func windowRange(_ start: Int) -> ClosedRange<Int> { start...(start + Self.windowSpan) }

    /// Guitar positions inside the window, lowest pitch first (one per pitch).
    func guitarPositions(layout: FretboardLayout = .standardGuitar) -> [FretPosition] {
        guard let start = fretWindow else { return [] }
        let all = layout.positions(in: scale, fretRange: windowRange(start))
        var byMIDI: [Int: FretPosition] = [:]
        for p in all {
            guard let midi = layout.midi(at: p) else { continue }
            // Prefer the lower fret, then the lower string, for one position per pitch.
            if let existing = byMIDI[midi], (existing.fret, -existing.string) <= (p.fret, -p.string) { continue }
            byMIDI[midi] = p
        }
        let sorted = byMIDI.sorted { $0.key < $1.key }
        guard let first = sorted.first(where: { PitchClass($0.key) == root.pitchClass }) else { return sorted.map(\.value) }
        let top = first.key + 12 * max(1, octaves)
        let run = sorted.filter { $0.key >= first.key && $0.key <= top }
        return run.map(\.value)
    }

    /// Ascending pitches of one run (root to top).
    func ascendingMIDI(instrument: TutorInstrument, layout: FretboardLayout = .standardGuitar) -> [Int] {
        let context = InstrumentContext.standard(instrument)
        if instrument == .guitar, fretWindow != nil {
            let fromWindow = guitarPositions(layout: layout).compactMap { layout.midi(at: $0) }
            if fromWindow.count >= 3 { return fromWindow }
        }
        return context.scalePitches(scale, octaves: max(1, octaves), upAndDown: false).map(\.midi)
    }

    /// Up then down.
    func pitches(instrument: TutorInstrument) -> [Int] {
        let up = ascendingMIDI(instrument: instrument)
        return up + up.dropLast().reversed()
    }

    func diagram(instrument: TutorInstrument) -> Diagram {
        switch instrument {
        case .guitar:
            let layout = FretboardLayout.standardGuitar
            if fretWindow != nil {
                let positions = guitarPositions(layout: layout)
                if positions.count >= 3, let start = fretWindow {
                    return Diagram(kind: .fretboard, scale: scale.name, notes: positions.map(\.notation), labels: labels,
                                   fretRange: [start, start + Self.windowSpan], caption: caption)
                }
            }
            let midis = ascendingMIDI(instrument: instrument)
            let positions = InstrumentContext.guitar.fretting(forLine: midis.map { [$0] }).compactMap { $0?.first }
            let frets = positions.map(\.fret)
            let hi = max(4, frets.max() ?? 4)
            let lo = hi > 5 ? max(0, (frets.filter { $0 > 0 }.min() ?? 1) - 1) : 0
            return Diagram(kind: .fretboard, scale: scale.name, notes: positions.map(\.notation), labels: labels,
                           fretRange: [lo, max(lo + 4, hi)], caption: caption)
        case .piano:
            let midis = ascendingMIDI(instrument: instrument)
            let layout = KeyboardLayout.fitting(midis)
            let names = midis.map { midi -> String in
                let spelled = scale.notes.first { $0.pitchClass == PitchClass(midi) } ?? SpelledNote.common(for: PitchClass(midi))
                return (Pitch(midi: midi, spelled: spelled) ?? Pitch(midi: midi)).name
            }
            return Diagram(kind: .keyboard, scale: scale.name, notes: names, labels: labels,
                           pitchRange: [Pitch(midi: layout.lowestMIDI).name, Pitch(midi: layout.highestMIDI).name], caption: caption)
        }
    }

    var caption: String {
        let notes = scale.notes.map(\.displayName).joined(separator: " ")
        return "\(scale.displayName): \(notes)"
    }

    func exercise(instrument: TutorInstrument, bpm: Double) -> GeneratedExercise {
        let context = InstrumentContext.standard(instrument)
        let line = pitches(instrument: instrument).map { [$0] }
        var fretting: [[FretPosition]?]? = nil
        if instrument == .guitar, fretWindow != nil {
            let positions = guitarPositions()
            let byMIDI = Dictionary(positions.compactMap { p in FretboardLayout.standardGuitar.midi(at: p).map { ($0, p) } },
                                    uniquingKeysWith: { a, _ in a })
            fretting = line.map { $0.first.flatMap { byMIDI[$0] }.map { [$0] } }
        }
        let passage = ExerciseGenerator.passage(line, durations: nil, bpm: bpm, context: context, fretting: fretting)
        return GeneratedExercise(kind: .scale, pacing: .timed, rounds: [ExerciseRound(reference: nil, expected: passage, label: nil)],
                                 bpm: bpm, tempoSteps: [], passAccuracy: 1, durationSec: nil, scale: scale)
    }
}

// MARK: - Chords

struct ChordPracticeSpec: Hashable {
    enum Style: String, CaseIterable, Identifiable {
        case block, arpeggio, strum
        var id: String { rawValue }
        var title: String {
            switch self {
            case .block: return "Block"
            case .arpeggio: return "Arpeggio"
            case .strum: return "Strum"
            }
        }
    }

    var root: SpelledNote = .C
    var quality: ChordQuality = .major
    var style: Style = .block

    var chord: Chord { Chord(root: root, quality: quality) }
    var title: String { chord.displaySymbol }

    func voicing(instrument: TutorInstrument) -> InstrumentContext.Voicing {
        InstrumentContext.standard(instrument).voicing(for: chord)
    }

    func diagram(instrument: TutorInstrument) -> Diagram {
        let voicing = voicing(instrument: instrument)
        let caption = "\(chord.displaySymbol) (\(chord.quality.name)): " + chord.tones.map(\.displayName).joined(separator: " ")
        if instrument == .guitar, let fretting = voicing.fretting, !fretting.isEmpty {
            let frets = fretting.map(\.fret)
            let hi = max(4, frets.max() ?? 4)
            let lo = hi > 5 ? max(0, (frets.filter { $0 > 0 }.min() ?? 1) - 1) : 0
            return Diagram(kind: .fretboard, chord: chord.symbol, notes: fretting.map(\.notation),
                           labels: voicing.fingering != nil ? .fingers : .noteNames, fretRange: [lo, max(lo + 4, hi)], caption: caption)
        }
        var d = Diagram.forEvent(pitches: voicing.midi, fretting: voicing.fretting, chordName: chord.symbol, instrument: instrument)
            ?? Diagram(kind: instrument == .guitar ? .fretboard : .keyboard, chord: chord.symbol)
        d.caption = caption
        return d
    }

    /// Example at `bpm` quarter notes: block (held 4 beats), arpeggio (eighths up and down), strum (eight eighth-note strums).
    func example(instrument: TutorInstrument, bpm: Double) -> PlaybackSequence {
        let voicing = voicing(instrument: instrument)
        let pitches = voicing.midi.sorted()
        switch style {
        case .block:
            return PlaybackSequence(notes: [PlaybackNote(pitches: pitches, startBeat: 0, durationBeats: 4, label: chord.symbol,
                                                         fretting: voicing.fretting)], bpm: bpm, style: .block)
        case .arpeggio:
            let order = pitches + pitches.dropLast().dropFirst().reversed()
            let notes = order.enumerated().map { PlaybackNote(pitches: [$0.element], startBeat: Double($0.offset) * 0.5, durationBeats: 0.5) }
            return PlaybackSequence(notes: notes, bpm: bpm, style: .arpeggio)
        case .strum:
            let notes = (0..<8).map { PlaybackNote(pitches: pitches, startBeat: Double($0) * 0.5, durationBeats: 0.5, label: chord.symbol,
                                                   fretting: voicing.fretting) }
            return PlaybackSequence(notes: notes, bpm: bpm, style: .strum)
        }
    }

    func exercise(instrument: TutorInstrument, bpm: Double) -> GeneratedExercise {
        let context = InstrumentContext.standard(instrument)
        let voicing = voicing(instrument: instrument)
        var passage = ExerciseGenerator.passage([voicing.midi], durations: [4], bpm: bpm, context: context, freeTime: true,
                                                names: [chord.symbol], fretting: [voicing.fretting])
        passage = ExerciseGenerator.markOctaveTolerant(passage, when: instrument == .piano)
        return GeneratedExercise(kind: .playChord, pacing: .wait, rounds: [ExerciseRound(reference: nil, expected: passage, label: nil)],
                                 bpm: bpm, tempoSteps: [], passAccuracy: 1, durationSec: nil)
    }
}

// MARK: - Intervals

struct IntervalPracticeSpec: Hashable {
    enum Direction: String, CaseIterable, Identifiable {
        case up, down, together
        var id: String { rawValue }
        var title: String {
            switch self {
            case .up: return "Up"
            case .down: return "Down"
            case .together: return "Together"
            }
        }
    }

    var root: Pitch
    var interval: Interval = .M3
    var direction: Direction = .up

    /// Intervals offered: minor second to octave.
    static let intervals: [Interval] = Interval.common.filter { $0 != .P1 }

    static func defaultRoot(_ instrument: TutorInstrument) -> Pitch {
        instrument == .guitar ? Pitch(.A, octave: 2) : Pitch(.C, octave: 4)
    }

    /// Roots the picker can reach: the instrument's comfortable range minus the interval.
    static func rootRange(_ instrument: TutorInstrument) -> ClosedRange<Int> {
        let range = InstrumentContext.standard(instrument).comfortableRange
        return range.lowerBound...(range.upperBound)
    }

    var title: String { interval.name.prefix(1).uppercased() + interval.name.dropFirst() }

    /// Root, then the other note (lower first when together).
    func pitches() -> [Int] {
        let other = direction == .down ? root.midi - interval.semitones : root.midi + interval.semitones
        return direction == .together ? [root.midi, other].sorted() : [root.midi, other]
    }

    /// The other note's spelling from the root.
    var otherPitch: Pitch { root.transposed(by: interval, down: direction == .down) }

    var caption: String {
        let names = direction == .together
            ? [root, otherPitch].sorted { $0.midi < $1.midi }.map(\.displayName).joined(separator: " + ")
            : "\(root.displayName) → \(otherPitch.displayName)"
        return "\(title): \(names), \(interval.semitones) half \(interval.semitones == 1 ? "step" : "steps")"
    }

    func diagram(instrument: TutorInstrument) -> Diagram {
        var d = Diagram.forEvent(pitches: pitches().sorted(), fretting: nil, chordName: nil, instrument: instrument)
            ?? Diagram(kind: instrument == .guitar ? .fretboard : .keyboard)
        d.labels = .noteNames
        d.caption = caption
        return d
    }

    func groups() -> [[Int]] {
        direction == .together ? [pitches()] : pitches().map { [$0] }
    }

    func example(instrument: TutorInstrument, bpm: Double) -> PlaybackSequence {
        let notes: [PlaybackNote]
        if direction == .together {
            notes = [PlaybackNote(pitches: pitches(), startBeat: 0, durationBeats: 2)]
        } else {
            notes = pitches().enumerated().map { PlaybackNote(pitches: [$0.element], startBeat: Double($0.offset), durationBeats: $0.offset == 1 ? 2 : 1) }
        }
        return PlaybackSequence(notes: notes, bpm: bpm, style: .sequence)
    }

    func exercise(instrument: TutorInstrument, bpm: Double) -> GeneratedExercise {
        let context = InstrumentContext.standard(instrument)
        let passage = ExerciseGenerator.passage(groups(), durations: nil, bpm: bpm, context: context, freeTime: true)
        return GeneratedExercise(kind: .playSequence, pacing: .wait, rounds: [ExerciseRound(reference: nil, expected: passage, label: nil)],
                                 bpm: bpm, tempoSteps: [], passAccuracy: 1, durationSec: nil)
    }

    /// Whether both notes fit the instrument.
    func fits(_ instrument: TutorInstrument) -> Bool {
        let range = InstrumentContext.standard(instrument).playableRange
        return pitches().allSatisfy { range.contains($0) }
    }
}

// MARK: - Rhythms

struct RhythmPracticeSpec: Hashable {
    var tokens: String = "q q e e q"
    var beatsPerMeasure: Int? = nil

    struct Preset: Hashable, Identifiable {
        var name: String
        var tokens: String
        var id: String { tokens }
    }

    static let presets: [Preset] = [
        Preset(name: "Quarters", tokens: "q q q q"),
        Preset(name: "Eighths", tokens: "e e e e e e e e"),
        Preset(name: "Quarter, two eighths", tokens: "q q e e q"),
        Preset(name: "Dotted quarter", tokens: "q. e q q"),
        Preset(name: "Waltz", tokens: "h q | q q q"),
        Preset(name: "Rests on 2 and 4", tokens: "q qr q qr"),
        Preset(name: "Triplets", tokens: "te te te q te te te q"),
        Preset(name: "Sixteenths", tokens: "s s s s e e q q"),
        Preset(name: "Down-up strum", tokens: "q e e q e e"),
    ]

    var pattern: RhythmPattern? { RhythmPattern(tokens) }

    /// Parse error for the free field, if any.
    var error: String? {
        do { _ = try RhythmPattern(parsing: tokens); return nil } catch let e as TheoryParseError { return e.reason } catch { return "\(error)" }
    }

    var title: String { pattern.map { "\($0.noteCount) notes, \(Self.beats($0.totalBeats)) beats" } ?? "Rhythm" }

    static func beats(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    func diagram() -> Diagram {
        Diagram(kind: .rhythm, rhythm: tokens, caption: beatsPerMeasure.map { "\($0)/4" })
    }

    /// Click-like tone on every onset; rests are silent.
    func exercise(instrument: TutorInstrument, bpm: Double) -> GeneratedExercise? {
        guard let pattern else { return nil }
        let tone = instrument == .guitar ? 45 : 69
        let groups = pattern.events.map { $0.isRest ? [Int]() : [tone] }
        let passage = ExerciseGenerator.passage(groups, durations: pattern.events.map(\.beats), bpm: bpm,
                                                beatsPerMeasure: beatsPerMeasure ?? RhythmStripModel.inferBeatsPerMeasure(pattern: pattern, caption: nil),
                                                context: .standard(instrument))
        return GeneratedExercise(kind: .strumRhythm, pacing: .timed, rounds: [ExerciseRound(reference: nil, expected: passage, label: nil)],
                                 bpm: bpm, tempoSteps: [], passAccuracy: 1, durationSec: nil)
    }
}

// MARK: - Exercise index

enum ExerciseGroup: String, CaseIterable, Identifiable {
    case scales, chords, chordChanges, strumming, sequences, notes, noteHunt, intervals, melodyEcho, improvise, songs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scales: return "Scales"
        case .chords: return "Chords"
        case .chordChanges: return "Chord changes"
        case .strumming: return "Strumming"
        case .sequences: return "Sequences and melodies"
        case .notes: return "Single notes"
        case .noteHunt: return "Note hunts"
        case .intervals: return "Interval echo"
        case .melodyEcho: return "Melody echo"
        case .improvise: return "Improvising"
        case .songs: return "Songs"
        }
    }

    var systemImage: String {
        switch self {
        case .scales: return "arrow.up.right"
        case .chords: return "guitars"
        case .chordChanges: return "arrow.left.arrow.right"
        case .strumming: return "waveform.path"
        case .sequences: return "music.note"
        case .notes: return "circle"
        case .noteHunt: return "scope"
        case .intervals: return "arrow.up.and.down"
        case .melodyEcho: return "ear"
        case .improvise: return "sparkles"
        case .songs: return "music.note.list"
        }
    }

    static func group(for kind: ExerciseKind) -> ExerciseGroup {
        switch kind {
        case .scale: return .scales
        case .playChord: return .chords
        case .chordChanges: return .chordChanges
        case .strumRhythm: return .strumming
        case .playSequence: return .sequences
        case .playNote: return .notes
        case .findAllNotes: return .noteHunt
        case .intervalPlayback: return .intervals
        case .melodyEcho: return .melodyEcho
        case .improvise: return .improvise
        }
    }
}

struct ExerciseIndexEntry: Identifiable, Hashable {
    var lessonID: String
    var lessonTitle: String
    var stageOrder: Int
    var branchTitle: String?
    var stepIndex: Int
    /// Index into `LessonPageModel.sections(for:)` for the jump link.
    var sectionIndex: Int
    var title: String
    var group: ExerciseGroup

    var id: String { "\(lessonID)#\(stepIndex)" }

    var location: String {
        branchTitle.map { "\($0) · \(lessonTitle)" } ?? "Part \(stageOrder) · \(lessonTitle)"
    }
}

enum TutorExerciseIndex {
    /// Every practice and song step of the course, in path order.
    static func entries(course: Course) -> [ExerciseIndexEntry] {
        var result: [ExerciseIndexEntry] = []
        for location in course.allLessonLocations {
            let sections = LessonPageModel.sections(for: location.lesson)
            for section in sections {
                switch section.step {
                case .practice(let p):
                    result.append(ExerciseIndexEntry(lessonID: location.lesson.id, lessonTitle: location.lesson.title,
                                                     stageOrder: location.stage.order, branchTitle: location.branch?.title,
                                                     stepIndex: section.stepIndex, sectionIndex: section.index,
                                                     title: p.exercise.prompt, group: ExerciseGroup.group(for: p.exercise.kind)))
                case .song(let s):
                    result.append(ExerciseIndexEntry(lessonID: location.lesson.id, lessonTitle: location.lesson.title,
                                                     stageOrder: location.stage.order, branchTitle: location.branch?.title,
                                                     stepIndex: section.stepIndex, sectionIndex: section.index,
                                                     title: s.title, group: .songs))
                default:
                    break
                }
            }
        }
        return result
    }

    /// Entries by group, in `ExerciseGroup.allCases` order, skipping empty groups.
    static func grouped(course: Course) -> [(group: ExerciseGroup, entries: [ExerciseIndexEntry])] {
        let all = entries(course: course)
        return ExerciseGroup.allCases.compactMap { group in
            let items = all.filter { $0.group == group }
            return items.isEmpty ? nil : (group, items)
        }
    }
}
