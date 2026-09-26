//
//  LessonPlayerModel.swift
//  TabBuddy
//
//  Step navigation, per-step outcomes, the lesson score, and completion
//  (progress record + review cards through `ReviewScheduler.completeLesson`).
//

import Foundation
import SwiftUI

/// What a graded step reports back to the lesson.
struct StepOutcome: Equatable {
    /// 0...1, nil for steps that are not scored.
    var score: Double?
    var passed: Bool
    /// Practice skipped (microphone off or learner chose to skip).
    var skipped: Bool = false
    /// Weakest item of the step's best run, when known.
    var weakest: CoachMessage? = nil
    /// Short label for the completion screen ("Practice: Em, then E").
    var label: String = ""

    static func skipped(label: String) -> StepOutcome {
        StepOutcome(score: nil, passed: false, skipped: true, weakest: nil, label: label)
    }
}

@MainActor
final class LessonPlayerModel: ObservableObject {
    let lesson: Lesson
    let instrument: TutorInstrument

    @Published private(set) var index = 0
    @Published private(set) var outcomes: [Int: StepOutcome] = [:]
    @Published private(set) var isShowingCompletion = false
    @Published private(set) var didSave = false
    @Published private(set) var saveError: String?

    init(lesson: Lesson, instrument: TutorInstrument) {
        self.lesson = lesson
        self.instrument = instrument
    }

    var steps: [LessonStep] { lesson.steps }
    var stepCount: Int { steps.count }
    var currentStep: LessonStep? { steps.indices.contains(index) ? steps[index] : nil }

    /// 0...1 across the lesson; the completion screen is 1.
    var progress: Double {
        guard stepCount > 0 else { return 1 }
        if isShowingCompletion { return 1 }
        return Double(index) / Double(stepCount)
    }

    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == stepCount - 1 }

    /// Graded steps need an outcome (a finished run, an answered quiz, or a skip).
    func needsOutcome(_ step: LessonStep) -> Bool {
        switch step {
        case .explain, .demo: return false
        case .practice, .quiz, .song: return true
        }
    }

    var canAdvance: Bool {
        guard let step = currentStep else { return false }
        return !needsOutcome(step) || outcomes[index] != nil
    }

    /// Whether Return should continue the lesson (quizzes use Return while unanswered).
    var returnContinues: Bool {
        guard let step = currentStep else { return false }
        if case .quiz = step { return outcomes[index] != nil }
        return canAdvance
    }

    func advance() {
        guard canAdvance else { return }
        if index + 1 < stepCount {
            index += 1
        } else {
            isShowingCompletion = true
        }
    }

    func back() {
        if isShowingCompletion {
            isShowingCompletion = false
        } else if index > 0 {
            index -= 1
        }
    }

    func go(to step: Int) {
        guard steps.indices.contains(step), step <= furthestReachable else { return }
        isShowingCompletion = false
        index = step
    }

    /// Moves to any step, ignoring gating (debug launch and tests).
    func jump(to step: Int) {
        guard steps.indices.contains(step) else { return }
        isShowingCompletion = false
        index = step
    }

    /// Steps up to the first one still waiting for an outcome.
    var furthestReachable: Int {
        for (i, step) in steps.enumerated() where needsOutcome(step) && outcomes[i] == nil { return i }
        return max(0, stepCount - 1)
    }

    /// Keeps the better outcome for a step (a pass beats a skip; higher score wins).
    func record(_ outcome: StepOutcome, forStep step: Int) {
        guard let existing = outcomes[step] else { outcomes[step] = outcome; return }
        let better: Bool
        switch (existing.skipped, outcome.skipped) {
        case (true, false): better = true
        case (false, true): better = false
        default: better = (outcome.score ?? 0) >= (existing.score ?? 0) || (outcome.passed && !existing.passed)
        }
        if better { outcomes[step] = outcome }
    }

    // MARK: Score

    var scoredOutcomes: [StepOutcome] { outcomes.keys.sorted().compactMap { outcomes[$0] }.filter { $0.score != nil && !$0.skipped } }

    /// Mean of scored steps; 1 when nothing was scored (reading-only lessons).
    var score: Double {
        let scores = scoredOutcomes.compactMap(\.score)
        guard !scores.isEmpty else { return 1 }
        return scores.reduce(0, +) / Double(scores.count)
    }

    var skippedCount: Int { outcomes.values.filter(\.skipped).count }

    /// The weakest item named by practice steps, else the lowest-scoring step.
    var weakestSummary: String? {
        let named = outcomes.keys.sorted().compactMap { outcomes[$0]?.weakest }
        let weakest = named.compactMap { message -> (String, Double)? in
            if case .weakest(let item, let accuracy) = message { return (item, accuracy) }
            return nil
        }.min { $0.1 < $1.1 }
        if let weakest {
            return "\(weakest.0) was the weakest item (\(Int((weakest.1 * 100).rounded()))%). Give it a few slow repeats."
        }
        if let low = scoredOutcomes.min(by: { ($0.score ?? 1) < ($1.score ?? 1) }), let s = low.score, s < 1 {
            return "\(low.label) was the weakest step (\(Int((s * 100).rounded()))%)."
        }
        return nil
    }

    // MARK: Completion

    /// Records progress and seeds review cards. Safe to call more than once.
    func complete(store: TutorStore, now: Date = Date()) {
        guard !didSave else { return }
        do {
            try ReviewScheduler.completeLesson(lesson, instrument: instrument, score: score, store: store, now: now)
            didSave = true
            saveError = nil
        } catch {
            saveError = "Progress could not be saved: \(error.localizedDescription)"
        }
    }

    static func label(for step: LessonStep) -> String {
        switch step {
        case .explain(let s): return s.title
        case .demo(let s): return s.title
        case .practice(let s): return s.exercise.prompt
        case .quiz(let s): return s.title
        case .song(let s): return s.title
        }
    }

    static func kindName(for step: LessonStep) -> String {
        switch step {
        case .explain: return "Learn"
        case .demo: return "Listen"
        case .practice: return "Practice"
        case .quiz: return "Quiz"
        case .song: return "Song"
        }
    }

    static func systemImage(for step: LessonStep) -> String {
        switch step {
        case .explain: return "book"
        case .demo: return "ear"
        case .practice: return "mic"
        case .quiz: return "questionmark.circle"
        case .song: return "music.note.list"
        }
    }
}
