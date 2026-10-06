//
//  PianoTechnique.swift
//  TabBuddy
//
//  Piano technique chart in the style of exam technical requirements (RCM,
//  ABRSM): rows are exercises, columns are keys. Rows follow the usual method
//  order (five-finger pattern, one-octave scale, two-octave scale, broken
//  triad, blocked triad, arpeggio). Keys run around the circle of fifths from
//  C, majors first, then minors starting with the relatives of C, G and F.
//  Minor keys use the harmonic minor for scales, as exam syllabi require; the
//  first five notes, triads, and arpeggios are the same in every minor form.
//
//  Tempo is a quarter-note BPM. Five-finger patterns, scales, broken triads,
//  and arpeggios move in eighth notes (two notes per beat); blocked triads
//  sound one chord per beat. Targets are approximate early-grade exam tempos.
//
//  Pitches: the right hand starts on the tonic in octave 4 (C4 = middle C),
//  the left hand an octave lower. Hands together pairs the two an octave apart.
//

import Foundation

// MARK: - Rows

enum PianoTechniqueRow: String, CaseIterable, Identifiable, Codable {
    case fiveFinger, scaleOneOctave, scaleTwoOctaves, brokenTriad, blockedTriad, arpeggio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveFinger: return "Five-finger pattern"
        case .scaleOneOctave: return "Scale, 1 octave"
        case .scaleTwoOctaves: return "Scale, 2 octaves"
        case .brokenTriad: return "Broken triad"
        case .blockedTriad: return "Blocked triad"
        case .arpeggio: return "Arpeggio, 1 octave"
        }
    }

    var shortTitle: String {
        switch self {
        case .fiveFinger: return "5-finger"
        case .scaleOneOctave: return "Scale 1 oct"
        case .scaleTwoOctaves: return "Scale 2 oct"
        case .brokenTriad: return "Broken triad"
        case .blockedTriad: return "Blocked triad"
        case .arpeggio: return "Arpeggio"
        }
    }

    /// Lowercase noun used inside spec titles ("scale · 1 octave").
    var noun: String {
        switch self {
        case .fiveFinger: return "five-finger pattern"
        case .scaleOneOctave: return "scale · 1 octave"
        case .scaleTwoOctaves: return "scale · 2 octaves"
        case .brokenTriad: return "broken triad"
        case .blockedTriad: return "blocked triad"
        case .arpeggio: return "arpeggio · 1 octave"
        }
    }

    /// Hands the syllabi ask for first: separate for everything but the
    /// two-octave scale, which is played hands together.
    var hands: PianoHands { self == .scaleTwoOctaves ? .together : .right }

    /// Goal tempo in quarter-note BPM (see `beatsPerNote`).
    var targetBPM: Double {
        switch self {
        case .fiveFinger: return 80
        case .scaleOneOctave: return 66
        case .scaleTwoOctaves: return 80
        case .brokenTriad: return 72
        case .blockedTriad: return 60
        case .arpeggio: return 60
        }
    }

    /// Note value of each event in beats: eighths, except blocked triads (quarters).
    var beatsPerNote: Double { self == .blockedTriad ? 1 : 0.5 }

    var octaves: Int {
        switch self {
        case .scaleTwoOctaves: return 2
        default: return 1
        }
    }

    var isScale: Bool { self == .scaleOneOctave || self == .scaleTwoOctaves }

    /// "Hands separate · 1 octave · ♩ = 66, eighths".
    var detail: String {
        let handsText = hands == .together ? "Hands together" : "Hands separate"
        let octaveText: String? = {
            switch self {
            case .fiveFinger, .brokenTriad, .blockedTriad: return nil
            default: return octaves == 1 ? "1 octave" : "\(octaves) octaves"
            }
        }()
        let tempo = "♩ = \(Int(targetBPM))" + (beatsPerNote == 0.5 ? ", eighths" : "")
        return [handsText, octaveText, tempo].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Hands

enum PianoHands: String, CaseIterable, Codable, Identifiable {
    case right = "rh", left = "lh", together

    var id: String { rawValue }

    var title: String {
        switch self {
        case .right: return "Right hand"
        case .left: return "Left hand"
        case .together: return "Hands together"
        }
    }

    var shortTitle: String {
        switch self {
        case .right: return "RH"
        case .left: return "LH"
        case .together: return "Together"
        }
    }
}

// MARK: - Keys

struct PianoTechniqueKey: Hashable, Identifiable {
    enum Mode: String, Hashable, Codable { case major, minor }

    var root: SpelledNote
    var mode: Mode

    init(_ root: SpelledNote, _ mode: Mode) {
        self.root = root
        self.mode = mode
    }

    init?(_ root: String, _ mode: Mode) {
        guard let note = SpelledNote(root) else { return nil }
        self.init(note, mode)
    }

    var id: String { "\(root.name)-\(mode.rawValue)" }

    /// Major, or harmonic minor (the exam form for minor scales).
    var scaleType: ScaleType { mode == .major ? .major : .harmonicMinor }
    var scale: Scale { Scale(root: root, type: scaleType) }

    /// "G major", "F♯ minor".
    var title: String { "\(root.displayName) \(mode.rawValue)" }
    /// Column header: "G" for major, "g" for minor (chart convention).
    var shortTitle: String {
        mode == .major ? root.displayName : root.letter.name.lowercased() + SpelledNote.symbolAccidental(root.accidental)
    }

    var isMajor: Bool { mode == .major }

    /// Majors in method-book order (C G F, then D A E, then the flat keys and
    /// the far sharp/flat keys), then minors starting with the relatives of
    /// C, F and G (A E D), then the rest around the circle.
    static let order: [PianoTechniqueKey] = majors + minors

    static let majors: [PianoTechniqueKey] = ["C", "G", "F", "D", "A", "E", "Bb", "Eb", "Ab", "B", "Db", "F#"]
        .compactMap { PianoTechniqueKey($0, .major) }
    static let minors: [PianoTechniqueKey] = ["A", "E", "D", "G", "C", "F", "B", "F#", "C#", "G#", "Bb", "Eb"]
        .compactMap { PianoTechniqueKey($0, .minor) }

    /// Keys whose scales use RH 123-1234 / LH 54321-321: C G D A E major and
    /// the harmonic minors A E D G C.
    var usesCFamilyScaleFingering: Bool {
        let family: Set<String> = mode == .major ? ["C", "G", "D", "A", "E"] : ["A", "E", "D", "G", "C"]
        return family.contains(root.name)
    }
}

// MARK: - Spec

struct PianoTechniqueSpec: Hashable, Identifiable {
    var key: PianoTechniqueKey
    var row: PianoTechniqueRow
    var hands: PianoHands

    init(key: PianoTechniqueKey, row: PianoTechniqueRow, hands: PianoHands? = nil) {
        self.key = key
        self.row = row
        self.hands = hands ?? row.hands
    }

    var id: String { launch.key }

    /// "G major scale · 1 octave · right hand".
    var title: String { "\(key.title) \(row.noun) · \(hands.title.lowercased())" }

    var scale: Scale { key.scale }

    static let rightHandOctave = 4
    static let leftHandOctave = 3

    // MARK: Pitches

    /// Spelled pitches of one hand's line, one inner array per event, up and down.
    func spelledEvents(octave: Int) -> [[Pitch]] {
        let tonic = Pitch(key.root, octave: octave)
        let notes = scale.pitches(from: tonic, octaves: row.octaves, upAndDown: false)
        switch row {
        case .fiveFinger:
            let up = Array(notes.prefix(5))
            return (up + up.dropLast().reversed()).map { [$0] }
        case .scaleOneOctave, .scaleTwoOctaves:
            return (notes + notes.dropLast().reversed()).map { [$0] }
        case .brokenTriad:
            let triad = [notes[0], notes[2], notes[4]]
            return (triad + triad.dropLast().reversed()).map { [$0] }
        case .blockedTriad:
            // Root position, first and second inversions, root position an octave up, and back.
            let root = [notes[0], notes[2], notes[4]]
            let first = [notes[2], notes[4], notes[7]]
            let second = [notes[4], notes[7], notes[7].transposed(by: tonicToThird)]
            let top = root.map { Pitch($0.note, octave: $0.octave + 1) }
            let up = [root, first, second, top]
            return up + up.dropLast().reversed()
        case .arpeggio:
            let triadUp = [notes[0], notes[2], notes[4], notes[7]]
            return (triadUp + triadUp.dropLast().reversed()).map { [$0] }
        }
    }

    private var tonicToThird: Interval { key.mode == .major ? .M3 : .m3 }

    /// MIDI pitches per event for `hands`: right hand from octave 4, left hand
    /// from octave 3, together = both, an octave apart, low to high.
    func pitches(hands: PianoHands) -> [[Int]] {
        let right = spelledEvents(octave: Self.rightHandOctave).map { $0.map(\.midi) }
        let left = spelledEvents(octave: Self.leftHandOctave).map { $0.map(\.midi) }
        switch hands {
        case .right: return right
        case .left: return left
        case .together: return zip(left, right).map { ($0 + $1).sorted() }
        }
    }

    /// Events for this spec's own hands.
    var events: [[Int]] { pitches(hands: hands) }

    // MARK: Fingering

    /// Finger per event for one hand (`.right` or `.left`), aligned with
    /// `pitches(hands:)`. Five-finger patterns for every key; scales only for
    /// keys sharing the C fingering (RH 123-1234, LH 54321-321). Nil otherwise.
    func fingering(hand: PianoHands) -> [Int]? {
        guard hand != .together else { return nil }
        switch row {
        case .fiveFinger:
            let up = hand == .right ? [1, 2, 3, 4, 5] : [5, 4, 3, 2, 1]
            return up + up.dropLast().reversed()
        case .scaleOneOctave, .scaleTwoOctaves:
            guard key.usesCFamilyScaleFingering else { return nil }
            let up: [Int]
            let down: [Int]
            if row.octaves == 1 {
                up = hand == .right ? [1, 2, 3, 1, 2, 3, 4, 5] : [5, 4, 3, 2, 1, 3, 2, 1]
                down = hand == .right ? [5, 4, 3, 2, 1, 3, 2, 1] : [1, 2, 3, 1, 2, 3, 4, 5]
            } else {
                up = hand == .right ? [1, 2, 3, 1, 2, 3, 4, 1, 2, 3, 1, 2, 3, 4, 5]
                                    : [5, 4, 3, 2, 1, 3, 2, 1, 4, 3, 2, 1, 3, 2, 1]
                down = Array(up.reversed())
            }
            return up + down.dropFirst()
        default:
            return nil
        }
    }

    // MARK: Diagram

    var caption: String {
        let names = spelledEvents(octave: Self.rightHandOctave).flatMap { $0 }
        var seen = Set<Int>()
        let unique = names.filter { seen.insert($0.midi).inserted }.sorted().map(\.note.displayName)
        return "\(key.title) \(row.noun), \(hands.title.lowercased()): " + unique.joined(separator: " ")
    }

    /// Keyboard with the exercise's keys marked. Five-finger patterns label
    /// finger numbers (the keyboard model numbers five-finger positions);
    /// other rows label note names, since `Diagram` has no per-note finger
    /// field for scale fingerings with thumb crossings.
    func diagram() -> Diagram {
        let events = pitches(hands: hands)
        let midis = Array(Set(events.flatMap { $0 })).sorted()
        let spelled = Dictionary(
            (spelledEvents(octave: Self.rightHandOctave) + spelledEvents(octave: Self.leftHandOctave))
                .flatMap { $0 }.map { ($0.midi, $0) },
            uniquingKeysWith: { a, _ in a })
        let names = midis.map { (spelled[$0] ?? Pitch(midi: $0)).name }
        var labels: Diagram.Labels = .noteNames
        if row == .fiveFinger {
            // Hands together relies on the model splitting at middle C.
            let leftMax = pitches(hands: .left).flatMap { $0 }.max() ?? 0
            labels = (hands != .together || leftMax < 60) ? .fingers : .noteNames
        }
        let layout = KeyboardLayout.fitting(midis)
        return Diagram(kind: .keyboard, scale: scale.name, notes: names, labels: labels,
                       pitchRange: [Pitch(midi: layout.lowestMIDI).name, Pitch(midi: layout.highestMIDI).name],
                       caption: caption)
    }

    // MARK: Exercise and example

    /// Durations per event in beats: `row.beatsPerNote`, the last note held a beat longer.
    func durations(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        var d = Array(repeating: row.beatsPerNote, count: count)
        d[count - 1] = row.beatsPerNote + 1
        return d
    }

    func exercise(bpm: Double) -> GeneratedExercise {
        let line = events
        let passage = ExerciseGenerator.passage(line, durations: durations(count: line.count), bpm: bpm,
                                                context: .standard(.piano))
        return GeneratedExercise(kind: row.isScale ? .scale : .playSequence, pacing: .timed,
                                 rounds: [ExerciseRound(reference: nil, expected: passage, label: nil)],
                                 bpm: bpm, tempoSteps: [], passAccuracy: 1, durationSec: nil,
                                 scale: row.isScale ? scale : nil)
    }

    /// The exercise as a demo: same events and durations as `exercise(bpm:)`.
    func example(bpm: Double) -> PlaybackSequence {
        let line = events
        let lengths = durations(count: line.count)
        var beat = 0.0
        var notes: [PlaybackNote] = []
        for (pitches, length) in zip(line, lengths) {
            notes.append(PlaybackNote(pitches: pitches, startBeat: beat, durationBeats: length))
            beat += length
        }
        return PlaybackSequence(notes: notes, bpm: bpm, style: .sequence)
    }

    // MARK: Launch

    var launch: PracticeLaunch {
        PracticeLaunch(instrument: .piano, kind: .technique, root: key.root.name, type: key.scaleType.rawValue,
                       octaves: row.octaves, technique: row.rawValue, hands: hands.rawValue)
    }

    init?(launch: PracticeLaunch) {
        guard launch.instrument == .piano, launch.kind == .technique,
              let root = SpelledNote(launch.root),
              let row = launch.technique.flatMap(PianoTechniqueRow.init(rawValue:)),
              let hands = launch.hands.flatMap(PianoHands.init(rawValue:)) else { return nil }
        let mode: PianoTechniqueKey.Mode
        switch launch.type.flatMap(ScaleType.init(rawValue:)) {
        case .major: mode = .major
        case .harmonicMinor, .naturalMinor, .melodicMinor: mode = .minor
        default: return nil
        }
        self.init(key: PianoTechniqueKey(root, mode), row: row, hands: hands)
    }

    // MARK: Status

    @MainActor
    func status(in memory: PracticeMemory) -> PianoTechniqueStatus {
        PianoTechniqueStatus(stats: memory.stats(for: launch), targetBPM: row.targetBPM)
    }
}

// MARK: - Status

enum PianoTechniqueStatus: Hashable {
    case new
    case practicing(bestBPM: Double?)
    case atGoal

    /// New until practiced once; at goal when the best tempo reaches `targetBPM`.
    init(stats: PracticeItemStats, targetBPM: Double) {
        if let best = stats.bestBPM, best >= targetBPM {
            self = .atGoal
        } else if stats.sessions > 0 || stats.bestBPM != nil {
            self = .practicing(bestBPM: stats.bestBPM)
        } else {
            self = .new
        }
    }

    var spokenTitle: String {
        switch self {
        case .new: return "not started"
        case .practicing(let best): return best.map { "practicing, best \(Int($0.rounded()))" } ?? "practicing"
        case .atGoal: return "at goal tempo"
        }
    }
}
