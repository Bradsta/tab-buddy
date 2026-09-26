//
//  TutorReviewModel.swift
//  TabBuddy
//
//  Review-session logic: how each spaced-repetition card is presented (self-
//  graded fact, multiple choice, or mic-graded play), multiple-choice
//  construction from a card's answer, play targets parsed from the answer,
//  and grading into `ReviewScheduler`. The view only renders this state.
//

import Foundation
import SwiftUI

/// Snapshot of a stored card (keeps views and tests free of SwiftData objects).
struct TutorReviewCard: Hashable, Identifiable {
    var itemID: String
    var kind: ReviewKind
    var prompt: String
    var answer: String
    var state: ReviewState

    var id: String { itemID }

    init(itemID: String, kind: ReviewKind, prompt: String, answer: String, state: ReviewState) {
        self.itemID = itemID
        self.kind = kind
        self.prompt = prompt
        self.answer = answer
        self.state = state
    }

    init(record: ReviewCardRecord) {
        self.init(itemID: record.itemID, kind: ReviewKind(rawValue: record.kind) ?? .fact, prompt: record.prompt,
                  answer: record.answer, state: ReviewScheduler.state(of: record))
    }
}

/// Something the learner plays for a playNote/playChord card.
struct TutorPlayTarget: Hashable {
    var label: String
    var event: ExpectedEvent
}

enum TutorReviewPresentation: Hashable {
    /// Prompt, reveal, self-grade.
    case fact
    /// Multiple choice, auto-graded (good / again).
    case choice(QuizQuestion)
    /// Mic-graded, one target after another.
    case play([TutorPlayTarget])
}

enum TutorReviewCardBuilder {

    static func presentation(for card: TutorReviewCard, seed: ReviewItemSeed?,
                             instrument: TutorInstrument) -> TutorReviewPresentation {
        switch card.kind {
        case .fact:
            return .fact
        case .noteName, .earInterval, .earQuality:
            if let q = question(for: card, seed: seed) { return .choice(q) }
            return .fact
        case .playNote, .playChord:
            let targets = playTargets(for: card, seed: seed, instrument: instrument)
            return targets.isEmpty ? .fact : .play(targets)
        }
    }

    // MARK: Multiple choice

    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let intervalNames = ["Minor 2nd", "Major 2nd", "Minor 3rd", "Major 3rd", "Perfect 4th", "Tritone",
                                "Perfect 5th", "Minor 6th", "Major 6th", "Minor 7th", "Major 7th", "Octave"]
    static let stepNames = ["Half step", "Whole step"]
    static let qualityNames = ["Major", "Minor", "Diminished", "Augmented", "Dominant 7th", "Major 7th",
                               "Minor 7th", "Half-diminished 7th"]

    /// Builds a four-choice (or two-choice for binary prompts) question from a card.
    /// Deterministic per card id so a card shows the same choices during one session.
    static func question(for card: TutorReviewCard, seed: ReviewItemSeed?) -> QuizQuestion? {
        let correct = card.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correct.isEmpty else { return nil }
        var rng = SeededRandom(seed: stableHash(card.itemID))
        let pool: [String]
        switch card.kind {
        case .noteName:
            pool = noteDistractors(for: correct)
        case .earInterval:
            pool = normalized(correct).contains("step")
                ? stepNames : nearby(correct, in: intervalNames)
        case .earQuality:
            pool = card.prompt.lowercased().contains("major or minor")
                ? ["Major", "Minor"] : nearby(correct, in: qualityNames)
        default:
            return nil
        }
        let distractors = pool.filter { normalized($0) != normalized(correct) }
        guard !distractors.isEmpty else { return nil }
        let explanation = "The answer is \(correct)."
        return QuizGenerator.makeQuestion(prompt: card.prompt, correct: correct, distractors: distractors,
                                          explanation: explanation, playback: seed?.playback, diagram: seed?.diagram,
                                          choiceCount: min(4, distractors.count + 1), using: &rng)
    }

    /// Distractor note names in the same written form as the answer ("G", "F4", "C♯4 / D♭4").
    static func noteDistractors(for answer: String) -> [String] {
        let head = answer.split(separator: " ").first.map(String.init) ?? answer
        let letters = head.prefix { "ABCDEFG#b♯♭".contains($0) }
        let octave = head.dropFirst(letters.count).prefix { $0.isNumber }
        let spelled = String(letters).replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        guard let note = SpelledNote(spelled) else { return ["C", "D", "E", "F", "G", "A", "B"].map { $0 + octave } }
        // Nearest pitch classes first (the most plausible confusions); naturals only for a natural answer.
        let pool = note.accidental == 0 ? noteNames.filter { !$0.contains("#") } : noteNames
        func distance(_ name: String) -> Int {
            let d = abs((SpelledNote(name)?.pitchClass.value ?? 0) - note.pitchClass.value)
            return min(d, 12 - d)
        }
        return pool.filter { distance($0) > 0 }
            .sorted { (distance($0), $0) < (distance($1), $1) }
            .map { $0 + octave }
    }

    private static func nearby(_ correct: String, in list: [String]) -> [String] {
        let key = normalized(correct)
        guard let i = list.firstIndex(where: { normalized($0) == key }) else { return list }
        return list.indices.sorted { abs($0 - i) < abs($1 - i) }.map { list[$0] }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "seventh", with: "7th")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FNV-1a, stable across launches (unlike `hashValue`).
    static func stableHash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    // MARK: Play targets

    static func playTargets(for card: TutorReviewCard, seed: ReviewItemSeed?,
                            instrument: TutorInstrument) -> [TutorPlayTarget] {
        let context = InstrumentContext.standard(instrument)
        var events: [(String, [Int], String?, [FretPosition]?, Bool)] = []
        switch card.kind {
        case .playNote:
            for token in pitchTokens(in: card.answer) {
                if let p = Pitch(token), context.playableRange.contains(p.midi) {
                    events.append((token, [p.midi], nil, nil, false))
                }
            }
            if events.isEmpty, let groups = seed?.playback?.notes {
                for group in groups {
                    let midi = group.compactMap { Pitch($0)?.midi }
                    if !midi.isEmpty { events.append((group.joined(separator: " "), midi, nil, nil, false)) }
                }
            }
        case .playChord:
            let parts = card.answer.replacingOccurrences(of: " then ", with: ",")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for symbol in parts {
                guard let chord = Chord(symbol) else { continue }
                let voicing = context.voicing(for: chord)
                events.append((symbol, voicing.midi, chord.symbol, voicing.fretting, instrument == .piano))
            }
        default:
            break
        }
        return events.enumerated().map { i, e in
            TutorPlayTarget(label: e.0, event: ExpectedEvent(id: i, pitches: e.1, beat: Double(i), durationBeats: 1,
                                                             measureIndex: 0, positionInMeasure: 0, chordName: e.2,
                                                             fretting: e.3, octaveTolerant: e.4))
        }
    }

    /// Scientific-pitch tokens in free text ("D3 (string 6, fret 10)" → ["D3"]).
    static func pitchTokens(in text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z])([A-G](?:#|b)?-?[0-9])(?![0-9])") else { return [] }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        return regex.matches(in: cleaned, range: range).compactMap {
            Range($0.range(at: 1), in: cleaned).map { String(cleaned[$0]) }
        }
    }
}

// MARK: - Session

@MainActor
final class TutorReviewSessionModel: ObservableObject {
    struct Outcome: Hashable {
        var itemID: String
        var grade: ReviewGrade?
    }

    let instrument: TutorInstrument
    @Published private(set) var cards: [TutorReviewCard]
    @Published private(set) var index = 0
    @Published var revealed = false
    /// Set after a choice/play card was graded automatically.
    @Published private(set) var autoGrade: ReviewGrade?
    @Published private(set) var outcomes: [Outcome] = []
    @Published private(set) var errorMessage: String?

    private let seedLookup: (String) -> ReviewItemSeed?
    private let recorder: (ReviewGrade, String) throws -> Void
    private let now: () -> Date

    init(cards: [TutorReviewCard], instrument: TutorInstrument,
         seedLookup: @escaping (String) -> ReviewItemSeed?,
         recorder: @escaping (ReviewGrade, String) throws -> Void,
         now: @escaping () -> Date = Date.init) {
        self.cards = cards
        self.instrument = instrument
        self.seedLookup = seedLookup
        self.recorder = recorder
        self.now = now
    }

    /// Session over the store's due queue, recording into `ReviewScheduler`.
    convenience init(instrument: TutorInstrument, store: TutorStore, library: CurriculumLibrary, limit: Int = 30) {
        var records = ReviewScheduler.dueQueue(instrument: instrument, store: store, limit: limit)
        #if DEBUG
        // `-TutorReviewKind noteName`: that kind first (screenshots).
        if let kind = TutorLaunchOptions.reviewKind {
            records = records.filter { $0.kind == kind } + records.filter { $0.kind != kind }
        }
        #endif
        let byID = Dictionary(records.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        self.init(cards: records.map(TutorReviewCard.init(record:)), instrument: instrument,
                  seedLookup: { library.reviewItem(id: $0, instrument: instrument) },
                  recorder: { grade, itemID in
                      guard let record = byID[itemID] else { return }
                      try ReviewScheduler.record(grade, for: record, store: store)
                  })
    }

    var current: TutorReviewCard? { cards.indices.contains(index) ? cards[index] : nil }
    var isFinished: Bool { index >= cards.count }
    var total: Int { cards.count }

    func seed(for card: TutorReviewCard) -> ReviewItemSeed? { seedLookup(card.itemID) }

    func presentation(for card: TutorReviewCard) -> TutorReviewPresentation {
        TutorReviewCardBuilder.presentation(for: card, seed: seed(for: card), instrument: instrument)
    }

    /// Interval captions for the self-grade buttons.
    func previewIntervals(for card: TutorReviewCard) -> [ReviewGrade: TimeInterval] {
        ReviewScheduler.previewIntervals(card.state, now: now())
    }

    /// Self-grade (fact cards) or confirm an auto grade; records and advances.
    func grade(_ grade: ReviewGrade) {
        guard let card = current else { return }
        do {
            try recorder(grade, card.itemID)
            errorMessage = nil
        } catch {
            errorMessage = "Could not save this review (\(error.localizedDescription))."
        }
        outcomes.append(Outcome(itemID: card.itemID, grade: grade))
        advance()
    }

    /// Multiple-choice answer: correct → good, wrong → again. The view calls `next()` after showing feedback.
    func answeredChoice(correct: Bool) {
        guard autoGrade == nil else { return }
        autoGrade = correct ? .good : .again
    }

    /// Mic-graded card: every target heard → good.
    func playSucceeded() {
        guard autoGrade == nil else { return }
        autoGrade = .good
    }

    /// Records the pending auto grade and moves on.
    func next() {
        if let g = autoGrade { grade(g) } else { advance() }
    }

    /// Leaves the card due, unrecorded.
    func skip() {
        guard let card = current else { return }
        outcomes.append(Outcome(itemID: card.itemID, grade: nil))
        advance()
    }

    private func advance() {
        index += 1
        revealed = false
        autoGrade = nil
    }

    var summary: (reviewed: Int, again: Int, skipped: Int) {
        (outcomes.filter { $0.grade != nil }.count,
         outcomes.filter { $0.grade == .again }.count,
         outcomes.filter { $0.grade == nil }.count)
    }

    /// "10m", "3d", "2mo".
    static func intervalCaption(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(1, Int(minutes.rounded())))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(Int(hours.rounded()))h" }
        let days = hours / 24
        if days < 31 { return "\(Int(days.rounded()))d" }
        if days < 365 { return "\(Int((days / 30).rounded()))mo" }
        return "\(Int((days / 365).rounded()))y"
    }
}
