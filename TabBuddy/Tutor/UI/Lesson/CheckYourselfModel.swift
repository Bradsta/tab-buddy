//
//  CheckYourselfModel.swift
//  TabBuddy
//
//  "Check yourself" review questions at the end of a chapter. Every question
//  is a flashcard: tapping any choice (or "Show answer") reveals the correct
//  answer and the explanation. There is no score, count, or retry gate.
//  Generated questions are produced once per page view; "New set" draws
//  another set with a fresh seed, keeping the fixed questions.
//

import Foundation
import SwiftUI

@MainActor
final class CheckYourselfModel: ObservableObject {
    let title: String
    let instrument: TutorInstrument
    let fixed: [QuizQuestion]
    let generator: QuizGeneratorSpec?
    let count: Int
    private let baseSeed: UInt64

    @Published private(set) var generated: [QuizQuestion] = []
    @Published private(set) var generationError: String?
    /// Question index → tapped choice (nil when revealed with "Show answer").
    @Published private(set) var revealed: [Int: Int?] = [:]
    @Published private(set) var setNumber = 0

    init(step: QuizStep, instrument: TutorInstrument, seed: UInt64) {
        title = step.title
        self.instrument = instrument
        fixed = step.questions ?? []
        generator = step.generator
        count = step.count
        baseSeed = seed
        regenerate()
    }

    var questions: [QuizQuestion] { fixed + generated }
    var hasGenerator: Bool { generator != nil }

    func isRevealed(_ index: Int) -> Bool { revealed[index] != nil }
    func choice(for index: Int) -> Int? { revealed[index] ?? nil }

    /// Reveals the answer; `choice` is the tapped option, if any.
    func reveal(_ index: Int, choice: Int? = nil) {
        guard questions.indices.contains(index), revealed[index] == nil else { return }
        revealed[index] = .some(choice)
    }

    func hideAll() { revealed = [:] }

    /// Draws a new generated set (fixed questions stay).
    func newSet() {
        setNumber += 1
        revealed = [:]
        regenerate()
    }

    private func regenerate() {
        guard let generator else { generated = []; return }
        do {
            generated = try QuizGenerator.questions(for: generator, count: count, instrument: instrument,
                                                    seed: baseSeed &+ UInt64(setNumber) &* 0x9E37_79B9)
            generationError = nil
        } catch {
            generated = []
            generationError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
