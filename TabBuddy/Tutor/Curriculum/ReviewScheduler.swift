//
//  ReviewScheduler.swift
//  TabBuddy
//
//  Simplified FSRS (v4.5 default weights) over `ReviewCardRecord`s. With the
//  target retention of 0.9 the next interval equals the new stability in days.
//  "Again" re-queues the card after a short relearning step. Cards are seeded
//  from `Lesson.reviewItems` when a lesson is completed.
//

import Foundation

enum ReviewGrade: Int, CaseIterable, Codable, Hashable, Sendable {
    case again = 1, hard, good, easy

    var title: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}

/// Scheduling fields of a card, detached from SwiftData for pure math.
struct ReviewState: Hashable, Sendable {
    /// Days until recall probability falls to 90%; 0 = never reviewed.
    var stability: Double = 0
    /// 1 (easy) … 10 (hard); 0 = never reviewed.
    var difficulty: Double = 0
    var due: Date
    var reps: Int = 0
    var lapses: Int = 0
    var lastReview: Date? = nil

    var isNew: Bool { reps == 0 || stability <= 0 }
}

enum ReviewScheduler {
    /// FSRS-4.5 default parameters.
    static let w: [Double] = [0.4072, 1.1829, 3.1262, 15.4722, 7.2102, 0.5316, 1.0651, 0.0234, 1.616, 0.1544,
                              1.0824, 1.9813, 0.0953, 0.2975, 2.2042, 0.2407, 2.9466]
    static let desiredRetention = 0.9
    static let maximumIntervalDays = 365.0
    /// Delay before a failed card returns.
    static let relearnDelay: TimeInterval = 10 * 60
    /// First appearance of a newly seeded card.
    static let firstReviewDelay: TimeInterval = 24 * 3600
    private static let day: TimeInterval = 24 * 3600
    private static let decay = -0.5
    private static let factor = 19.0 / 81.0

    // MARK: Math

    static func initialStability(_ grade: ReviewGrade) -> Double { max(0.1, w[grade.rawValue - 1]) }

    static func initialDifficulty(_ grade: ReviewGrade) -> Double {
        clampDifficulty(w[4] - exp(w[5] * Double(grade.rawValue - 1)) + 1)
    }

    static func clampDifficulty(_ d: Double) -> Double { min(10, max(1, d)) }

    /// Probability of recall after `elapsedDays` at stability `s`.
    static func retrievability(elapsedDays: Double, stability s: Double) -> Double {
        guard s > 0 else { return 0 }
        return pow(1 + factor * max(0, elapsedDays) / s, decay)
    }

    /// Days until retrievability reaches `desiredRetention`.
    static func interval(forStability s: Double) -> Double {
        let days = s / factor * (pow(desiredRetention, 1 / decay) - 1)
        return min(maximumIntervalDays, max(1, days.rounded()))
    }

    static func nextDifficulty(_ d: Double, grade: ReviewGrade) -> Double {
        let delta = -w[6] * Double(grade.rawValue - 3)
        let updated = d + delta * (10 - d) / 9
        // Mean reversion toward the "easy" initial difficulty.
        return clampDifficulty(w[7] * initialDifficulty(.easy) + (1 - w[7]) * updated)
    }

    static func recallStability(d: Double, s: Double, r: Double, grade: ReviewGrade) -> Double {
        let hardPenalty = grade == .hard ? w[15] : 1
        let easyBonus = grade == .easy ? w[16] : 1
        return s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp(w[10] * (1 - r)) - 1) * hardPenalty * easyBonus)
    }

    static func forgetStability(d: Double, s: Double, r: Double) -> Double {
        let next = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp(w[14] * (1 - r))
        return min(s, max(0.1, next))
    }

    /// New state after answering at `now`.
    static func schedule(_ state: ReviewState, grade: ReviewGrade, now: Date = Date()) -> ReviewState {
        var next = state
        if state.isNew {
            next.stability = initialStability(grade)
            next.difficulty = initialDifficulty(grade)
        } else {
            let elapsed = state.lastReview.map { now.timeIntervalSince($0) / day } ?? 0
            let r = retrievability(elapsedDays: elapsed, stability: state.stability)
            next.difficulty = nextDifficulty(state.difficulty, grade: grade)
            next.stability = grade == .again
                ? forgetStability(d: state.difficulty, s: state.stability, r: r)
                : recallStability(d: state.difficulty, s: state.stability, r: r, grade: grade)
        }
        next.reps += 1
        next.lastReview = now
        if grade == .again {
            if !state.isNew { next.lapses += 1 }
            next.due = now.addingTimeInterval(relearnDelay)
        } else {
            next.due = now.addingTimeInterval(interval(forStability: next.stability) * day)
        }
        return next
    }

    /// Interval each grade would give, for button captions ("10m", "3d").
    static func previewIntervals(_ state: ReviewState, now: Date = Date()) -> [ReviewGrade: TimeInterval] {
        Dictionary(uniqueKeysWithValues: ReviewGrade.allCases.map { ($0, schedule(state, grade: $0, now: now).due.timeIntervalSince(now)) })
    }

    // MARK: Records

    static func state(of card: ReviewCardRecord) -> ReviewState {
        ReviewState(stability: card.stability, difficulty: card.difficulty, due: card.due,
                     reps: card.reps, lapses: card.lapses, lastReview: card.lastReview)
    }

    static func apply(_ state: ReviewState, to card: ReviewCardRecord) {
        card.stability = state.stability
        card.difficulty = state.difficulty
        card.due = state.due
        card.reps = state.reps
        card.lapses = state.lapses
        card.lastReview = state.lastReview
    }

    /// Grades a card and saves the store.
    @MainActor
    static func record(_ grade: ReviewGrade, for card: ReviewCardRecord, store: TutorStore, now: Date = Date()) throws {
        apply(schedule(state(of: card), grade: grade, now: now), to: card)
        try store.save()
    }

    /// Adds one card per review item of a completed lesson (existing cards are kept as they are).
    @MainActor
    @discardableResult
    static func seedCards(for lesson: Lesson, instrument: TutorInstrument, store: TutorStore,
                          now: Date = Date()) throws -> [ReviewCardRecord] {
        try lesson.reviewItems.map { item in
            try store.addReviewCardIfMissing(ReviewCardRecord(itemID: item.id, instrument: instrument, kind: item.kind.rawValue,
                                                              prompt: item.prompt, answer: item.answer,
                                                              due: now.addingTimeInterval(firstReviewDelay)))
        }
    }

    /// Records the lesson as completed and seeds its review cards.
    @MainActor
    static func completeLesson(_ lesson: Lesson, instrument: TutorInstrument, score: Double, store: TutorStore,
                               now: Date = Date()) throws {
        try store.recordLessonAttempt(lessonID: lesson.id, instrument: instrument, score: score, completed: true, date: now)
        try seedCards(for: lesson, instrument: instrument, store: store, now: now)
    }

    /// Due cards for an instrument, most overdue first.
    @MainActor
    static func dueQueue(instrument: TutorInstrument, store: TutorStore, now: Date = Date(), limit: Int? = nil) -> [ReviewCardRecord] {
        store.dueReviewCards(instrument: instrument, asOf: now, limit: limit)
    }
}
