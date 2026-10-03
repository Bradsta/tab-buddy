//
//  TutorFlashcardsModel.swift
//  TabBuddy
//
//  Optional flashcards built from the review items of the course's lessons.
//  The deck covers lessons marked done (or every lesson). Cards flip to
//  reveal; "Got it" takes a card out of the deck for this session and
//  "Again" moves it to the back. Nothing is graded or stored. Play cards
//  ("play E2", "play Am") offer "Hear it" through the synth instead of the
//  microphone.
//

import Foundation
import SwiftUI

struct TutorFlashcard: Identifiable, Hashable {
    var itemID: String
    var lessonID: String
    var lessonTitle: String
    var kind: ReviewKind
    var prompt: String
    var answer: String
    var playback: PlaybackSpec?
    var diagram: Diagram?
    /// Pitches of a play card's answer (each inner array sounds together).
    var hearPitches: [[Int]]

    var id: String { itemID }

    var kindLabel: String {
        switch kind {
        case .fact: return "Recall"
        case .noteName: return "Name the note"
        case .playNote: return "Play the note"
        case .playChord: return "Play the chord"
        case .earInterval: return "Hear it: interval"
        case .earQuality: return "Hear it: chord quality"
        }
    }

    var isPlayCard: Bool { kind == .playNote || kind == .playChord }
}

enum TutorFlashcardBuilder {
    /// Cards for every lesson in the course, in path order.
    static func cards(course: Course, instrument: TutorInstrument) -> [TutorFlashcard] {
        course.allLessonLocations.flatMap { location in
            location.lesson.reviewItems.map { item in
                TutorFlashcard(itemID: item.id, lessonID: location.lesson.id, lessonTitle: location.lesson.title,
                               kind: item.kind, prompt: item.prompt, answer: item.answer, playback: item.playback,
                               diagram: item.diagram, hearPitches: hearPitches(for: item, instrument: instrument))
            }
        }
    }

    /// What "Hear it" plays for a play card: the answer's pitches or chords.
    static func hearPitches(for item: ReviewItemSeed, instrument: TutorInstrument) -> [[Int]] {
        let context = InstrumentContext.standard(instrument)
        switch item.kind {
        case .playNote:
            let pitches = pitchTokens(in: item.answer).compactMap { Pitch($0) }.map(\.midi)
                .filter { context.playableRange.contains($0) }
            if !pitches.isEmpty { return pitches.map { [$0] } }
            return (item.playback?.notes ?? []).map { $0.compactMap { Pitch($0)?.midi } }.filter { !$0.isEmpty }
        case .playChord:
            let parts = item.answer.replacingOccurrences(of: " then ", with: ",")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.compactMap { Chord($0) }.map { context.voicing(for: $0).midi }
        default:
            return []
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

@MainActor
final class TutorFlashcardsModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case done, all
        var id: String { rawValue }
        var title: String { self == .done ? "Chapters I've read" : "All chapters" }
    }

    let instrument: TutorInstrument
    let allCards: [TutorFlashcard]
    private let doneLessonIDs: Set<String>
    private var rng: SeededRandom

    @Published private(set) var scope: Scope
    @Published private(set) var deck: [TutorFlashcard] = []
    @Published private(set) var revealed = false
    /// Cards taken out with "Got it" this session.
    @Published private(set) var gotItCount = 0

    init(course: Course, progress: PathProgress, instrument: TutorInstrument, seed: UInt64 = 1) {
        self.instrument = instrument
        allCards = TutorFlashcardBuilder.cards(course: course, instrument: instrument)
        doneLessonIDs = progress.completedLessonIDs
        rng = SeededRandom(seed: seed)
        scope = allCards.contains { progress.completedLessonIDs.contains($0.lessonID) } ? .done : .all
        reset()
    }

    var cards: [TutorFlashcard] {
        scope == .all ? allCards : allCards.filter { doneLessonIDs.contains($0.lessonID) }
    }
    var doneCardCount: Int { allCards.filter { doneLessonIDs.contains($0.lessonID) }.count }
    var current: TutorFlashcard? { deck.first }
    var remaining: Int { deck.count }
    var isFinished: Bool { deck.isEmpty }

    func setScope(_ new: Scope) {
        guard new != scope else { return }
        scope = new
        reset()
    }

    /// Rebuilds the deck in lesson order.
    func reset() {
        deck = cards
        revealed = false
        gotItCount = 0
    }

    func shuffle() {
        deck.shuffle(using: &rng)
        revealed = false
    }

    func flip() { revealed.toggle() }

    /// Removes the current card from this session's deck.
    func gotIt() {
        guard !deck.isEmpty else { return }
        deck.removeFirst()
        gotItCount += 1
        revealed = false
    }

    /// Moves the current card to the back of the deck.
    func again() {
        guard deck.count > 1 else { revealed = false; return }
        let card = deck.removeFirst()
        deck.append(card)
        revealed = false
    }

    /// Leaves the card in place and moves on (it goes to the back).
    func skip() { again() }
}
