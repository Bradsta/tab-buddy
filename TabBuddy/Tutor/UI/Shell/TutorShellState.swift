//
//  TutorShellState.swift
//  TabBuddy
//
//  Shared state of the tutor shell: current instrument (persisted in
//  TutorStore settings), path progress, due reviews, a gentle practice-days
//  count, today's minutes against the daily goal, progress reset, and DEBUG
//  launch arguments.
//

import Foundation
import SwiftData

@MainActor
final class TutorShellState: ObservableObject {
    @Published private(set) var instrument: TutorInstrument
    @Published private(set) var progress: PathProgress?
    @Published private(set) var dueCount = 0
    @Published private(set) var practiceDays = 0
    @Published private(set) var todayMinutes = 0
    @Published private(set) var dailyGoalMinutes: Int

    let store: TutorStore
    let library: CurriculumLibrary
    private let calendar: Calendar
    private let now: () -> Date

    init(store: TutorStore? = nil, library: CurriculumLibrary? = nil, calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init) {
        let store = store ?? .shared
        self.store = store
        self.library = library ?? .shared
        self.calendar = calendar
        self.now = now
        let settings = store.settings()
        instrument = settings.instrument
        dailyGoalMinutes = settings.dailyGoalMinutes
    }

    var course: Course? { library.course(for: instrument) }

    var pathModel: TutorPathModel? {
        guard let course, let progress else { return nil }
        return TutorPathModel(course: course, progress: progress)
    }

    func refresh() {
        if let course {
            progress = PathProgress(course: course, store: store)
        } else {
            progress = nil
        }
        dueCount = store.dueReviewCount(instrument: instrument, asOf: now())
        let records = store.allProgress(instrument: instrument)
        let cards = allCards(instrument: instrument)
        var days = Set<DateComponents>()
        for r in records where r.attempts > 0 { days.insert(calendar.dateComponents([.year, .month, .day], from: r.updatedAt)) }
        for c in cards { if let d = c.lastReview { days.insert(calendar.dateComponents([.year, .month, .day], from: d)) } }
        practiceDays = days.count
        let today = now()
        todayMinutes = records.filter { calendar.isDate($0.updatedAt, inSameDayAs: today) && $0.attempts > 0 }
            .reduce(0) { sum, r in sum + (course?.lesson(id: r.lessonID)?.minutes ?? 0) }
    }

    func setInstrument(_ new: TutorInstrument) {
        guard new != instrument else { return }
        instrument = new
        store.settings().instrument = new
        try? store.save()
        refresh()
    }

    func setDailyGoal(_ minutes: Int) {
        let clamped = min(60, max(5, minutes))
        dailyGoalMinutes = clamped
        store.settings().dailyGoalMinutes = clamped
        try? store.save()
    }

    /// Deletes lesson progress and review cards for one instrument. Settings,
    /// calibration, and library practice takes are kept.
    func resetProgress(for target: TutorInstrument) {
        for record in store.allProgress(instrument: target) { store.context.delete(record) }
        for card in allCards(instrument: target) { store.context.delete(card) }
        try? store.save()
        refresh()
    }

    /// Called when the lesson player closes. Records completion if the player did not.
    func lessonDidExit(_ lesson: Lesson, completed: Bool) {
        if completed, store.progress(lessonID: lesson.id, instrument: instrument)?.progressStatus != .completed {
            try? ReviewScheduler.completeLesson(lesson, instrument: instrument, score: 1, store: store, now: now())
        }
        refresh()
    }

    private func allCards(instrument: TutorInstrument) -> [ReviewCardRecord] {
        let raw = instrument.rawValue
        return (try? store.context.fetch(FetchDescriptor<ReviewCardRecord>(predicate: #Predicate { $0.instrument == raw }))) ?? []
    }

    // MARK: DEBUG seeding

    /// Marks the first `count` main-path lessons complete and makes their cards due now.
    func seedProgress(firstLessons count: Int) {
        guard let course else { return }
        let date = now()
        for lesson in course.mainPathLessons.prefix(count) {
            if store.progress(lessonID: lesson.id, instrument: instrument)?.progressStatus != .completed {
                try? ReviewScheduler.completeLesson(lesson, instrument: instrument, score: 1, store: store, now: date)
            }
            for item in lesson.reviewItems {
                if let card = store.reviewCard(itemID: item.id, instrument: instrument), card.reps == 0 {
                    card.due = date.addingTimeInterval(-60)
                }
            }
        }
        try? store.save()
        refresh()
    }
}

// MARK: - Launch arguments (DEBUG)

enum TutorLaunchOptions {
    /// `-TutorOpen`: open the tutor on launch.
    static var openOnLaunch: Bool {
        #if DEBUG
        return arguments.contains("-TutorOpen") || calibration || TutorLessonDebugLaunch.isRequested
        #else
        return false
        #endif
    }

    /// `-TutorInstrument piano|guitar`.
    static var instrument: TutorInstrument? {
        #if DEBUG
        return value(after: "-TutorInstrument").flatMap(TutorInstrument.init(rawValue:))
        #else
        return nil
        #endif
    }

    /// `-TutorSeedProgress <n>`.
    static var seedProgress: Int? {
        #if DEBUG
        return value(after: "-TutorSeedProgress").flatMap(Int.init)
        #else
        return nil
        #endif
    }

    /// `-TutorCalibration`: open the calibration section.
    static var calibration: Bool {
        #if DEBUG
        return arguments.contains("-TutorCalibration")
        #else
        return false
        #endif
    }

    /// `-TutorSection path|reviews|songs|games|glossary|calibration|settings|review-session` (screenshots).
    static var section: String? {
        #if DEBUG
        return value(after: "-TutorSection")
        #else
        return nil
        #endif
    }

    /// `-TutorReviewKind <ReviewKind>`: show due cards of that kind first.
    static var reviewKind: String? {
        #if DEBUG
        return value(after: "-TutorReviewKind")
        #else
        return nil
        #endif
    }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }
}
