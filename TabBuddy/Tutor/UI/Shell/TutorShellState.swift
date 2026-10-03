//
//  TutorShellState.swift
//  TabBuddy
//
//  Shared state of the tutor shell: current instrument (persisted in
//  TutorStore settings), path progress (chapters marked read), reading days,
//  today's minutes against the daily goal, progress reset, and DEBUG launch
//  arguments. Done means read: there are no attempts or scores, so the day
//  counts and minutes come from the chapters marked done.
//

import Foundation
import SwiftData

@MainActor
final class TutorShellState: ObservableObject {
    @Published private(set) var instrument: TutorInstrument
    @Published private(set) var progress: PathProgress?
    /// Distinct days on which a chapter was marked done.
    @Published private(set) var practiceDays = 0
    /// Minutes of the chapters marked done today.
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
        let done = store.allProgress(instrument: instrument).filter { $0.progressStatus == .completed }
        var days = Set<DateComponents>()
        for r in done {
            if let date = r.completedAt { days.insert(calendar.dateComponents([.year, .month, .day], from: date)) }
        }
        practiceDays = days.count
        let today = now()
        todayMinutes = done.filter { r in r.completedAt.map { calendar.isDate($0, inSameDayAs: today) } ?? false }
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

    /// Deletes lesson progress (and any legacy review cards) for one
    /// instrument. Settings, calibration, and library practice takes are kept.
    func resetProgress(for target: TutorInstrument) {
        for record in store.allProgress(instrument: target) { store.context.delete(record) }
        for card in legacyCards(instrument: target) { store.context.delete(card) }
        try? store.save()
        refresh()
    }

    /// Marks a chapter read (done) or not.
    func setLessonDone(_ lesson: Lesson, done: Bool) {
        try? store.setLessonCompleted(lessonID: lesson.id, instrument: instrument, completed: done, date: now())
        refresh()
    }

    /// Called when a lesson page closes; the page writes done itself.
    func lessonDidClose() { refresh() }

    /// Review cards from the earlier graded-review design; no longer written by the UI.
    private func legacyCards(instrument: TutorInstrument) -> [ReviewCardRecord] {
        let raw = instrument.rawValue
        return (try? store.context.fetch(FetchDescriptor<ReviewCardRecord>(predicate: #Predicate { $0.instrument == raw }))) ?? []
    }

    // MARK: DEBUG seeding

    /// Marks the first `count` main-path lessons done.
    func seedProgress(firstLessons count: Int) {
        guard let course else { return }
        let date = now()
        for lesson in course.mainPathLessons.prefix(count) {
            if store.progress(lessonID: lesson.id, instrument: instrument)?.progressStatus != .completed {
                try? store.setLessonCompleted(lessonID: lesson.id, instrument: instrument, completed: true, date: date)
            }
        }
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

    /// `-TutorSection path|practice|flashcards|songs|games|glossary|calibration|settings` (screenshots).
    static var section: String? {
        #if DEBUG
        return value(after: "-TutorSection")
        #else
        return nil
        #endif
    }

    /// `-TutorPracticeTab scales|chords|intervals|rhythms|exercises`: tab of the Practice section.
    static var practiceTab: String? {
        #if DEBUG
        return value(after: "-TutorPracticeTab")
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
