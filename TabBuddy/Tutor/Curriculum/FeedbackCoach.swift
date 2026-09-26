//
//  FeedbackCoach.swift
//  TabBuddy
//
//  Rule-based coaching for a practice step (TUTOR_IMPLEMENTATION.md §6):
//  - 3 consecutive misses on the same target → the step's `mistakeTips`, in rotation.
//  - 3 clean runs in a row with `tempoSteps` → offer the next tempo.
//  - After a pass → name the weakest item.
//

import Foundation

enum CoachMessage: Hashable, Sendable {
    case tip(String)
    case offerTempo(bpm: Double)
    case weakest(item: String, accuracy: Double)
    case allClean

    var text: String {
        switch self {
        case .tip(let tip): return tip
        case .offerTempo(let bpm): return "Three clean runs. Ready to try \(Int(bpm.rounded())) BPM?"
        case .weakest(let item, let accuracy):
            return "Passed. \(item) was the weakest (\(Int((accuracy * 100).rounded()))%). Give it a few slow repeats."
        case .allClean: return "Passed with every note clean."
        }
    }
}

struct FeedbackCoach: Sendable {
    static let missesBeforeTip = 3
    static let cleanRunsBeforeTempo = 3

    let tips: [String]
    let tempoSteps: [Double]
    /// Accuracy a run needs to count as clean.
    let cleanThreshold: Double

    private(set) var tempoIndex = 0
    private var missStreaks: [String: Int] = [:]
    private var nextTip = 0
    private var cleanStreak = 0

    init(tips: [String], tempoSteps: [Double], cleanThreshold: Double = 0.95) {
        self.tips = tips
        self.tempoSteps = tempoSteps
        self.cleanThreshold = cleanThreshold
    }

    init(step: PracticeStep, cleanThreshold: Double = 0.95) {
        self.init(tips: step.mistakeTips, tempoSteps: step.exercise.tempoSteps ?? [],
                  cleanThreshold: max(cleanThreshold, step.exercise.passAccuracy))
    }

    /// Current tempo step, if the exercise has a ladder.
    var currentTempo: Double? { tempoSteps.indices.contains(tempoIndex) ? tempoSteps[tempoIndex] : nil }

    /// Target label for an expected event: its chord name or spelled pitches ("G", "E2").
    static func targetKey(for event: ExpectedEvent) -> String {
        event.chordName ?? event.pitches.map { Pitch(midi: $0).name }.joined(separator: " ")
    }

    /// Records one attempt at a target. Every third miss in a row on the same target returns the next tip.
    mutating func registerAttempt(target: String, success: Bool) -> CoachMessage? {
        if success {
            missStreaks[target] = 0
            return nil
        }
        let streak = (missStreaks[target] ?? 0) + 1
        missStreaks[target] = streak
        guard streak % Self.missesBeforeTip == 0, !tips.isEmpty else { return nil }
        let tip = tips[nextTip % tips.count]
        nextTip += 1
        return .tip(tip)
    }

    mutating func registerAttempt(_ grade: GradedEvent, event: ExpectedEvent) -> CoachMessage? {
        switch grade.grade {
        case .uncertain: return nil
        case .hit: return registerAttempt(target: Self.targetKey(for: event), success: true)
        default: return registerAttempt(target: Self.targetKey(for: event), success: false)
        }
    }

    /// Records a finished run. After three clean runs in a row, offers the next tempo step.
    mutating func registerRun(accuracy: Double) -> CoachMessage? {
        guard accuracy >= cleanThreshold else {
            cleanStreak = 0
            return nil
        }
        cleanStreak += 1
        guard cleanStreak >= Self.cleanRunsBeforeTempo, tempoIndex + 1 < tempoSteps.count else { return nil }
        cleanStreak = 0
        return .offerTempo(bpm: tempoSteps[tempoIndex + 1])
    }

    /// Moves to the next tempo step (after the learner accepts the offer).
    mutating func advanceTempo() {
        if tempoIndex + 1 < tempoSteps.count { tempoIndex += 1 }
        cleanStreak = 0
    }

    /// Weakest item of a passed run: grouped by target label, lowest hit share first.
    /// Uncertain events are ignored. Returns `.allClean` when nothing was missed.
    static func weakestItem(passage: ExpectedPassage, graded: [GradedEvent]) -> CoachMessage? {
        let events = Dictionary(passage.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var totals: [String: (score: Double, count: Int, order: Int)] = [:]
        for g in graded where g.grade != .uncertain {
            guard let event = events[g.expectedID] else { continue }
            let key = targetKey(for: event)
            let score: Double
            switch g.grade {
            case .hit: score = 1
            case .partial:
                let total = g.matchedPitches.count + g.missingPitches.count
                score = total > 0 ? Double(g.matchedPitches.count) / Double(total) : 0.5
            default: score = 0
            }
            let prior = totals[key] ?? (0, 0, event.id)
            totals[key] = (prior.score + score, prior.count + 1, prior.order)
        }
        guard !totals.isEmpty else { return nil }
        let ranked = totals.map { (key: $0.key, accuracy: $0.value.score / Double($0.value.count), order: $0.value.order) }
            .sorted { ($0.accuracy, $0.order) < ($1.accuracy, $1.order) }
        let worst = ranked[0]
        return worst.accuracy >= 1 ? .allClean : .weakest(item: worst.key, accuracy: worst.accuracy)
    }

    static func weakestItem(analysis: TakeAnalysis, passage: ExpectedPassage) -> CoachMessage? {
        weakestItem(passage: passage, graded: analysis.graded)
    }
}
