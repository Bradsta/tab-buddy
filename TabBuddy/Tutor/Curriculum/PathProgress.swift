//
//  PathProgress.swift
//  TabBuddy
//
//  Lesson states along a course's fixed path. Main-path lessons unlock in
//  order across stages. Branch lessons unlock once their `unlocksAfter`
//  lesson is completed, run in order within the branch, and never block the
//  main path.
//

import Foundation

enum LessonState: String, Hashable, Sendable {
    case locked, available, inProgress, completed

    var isOpen: Bool { self != .locked }
}

struct PathProgress: Sendable {
    let course: Course
    /// Stored status per lesson id.
    let statuses: [String: LessonProgressStatus]
    private let states: [String: LessonState]

    init(course: Course, statuses: [String: LessonProgressStatus]) {
        self.course = course
        self.statuses = statuses
        var states: [String: LessonState] = [:]
        func resolve(_ id: String, previousCompleted: Bool) -> LessonState {
            switch statuses[id] ?? .notStarted {
            case .completed: return .completed
            case .inProgress: return .inProgress
            case .notStarted: return previousCompleted ? .available : .locked
            }
        }
        var previousDone = true
        for lesson in course.mainPathLessons {
            let state = resolve(lesson.id, previousCompleted: previousDone)
            states[lesson.id] = state
            previousDone = state == .completed
        }
        for branch in course.allBranches {
            var done = statuses[branch.unlocksAfter] == .completed
            for lesson in branch.lessons {
                let state = resolve(lesson.id, previousCompleted: done)
                states[lesson.id] = state
                done = state == .completed
            }
        }
        self.states = states
    }

    /// Reads lesson records for the course's instrument.
    @MainActor
    init(course: Course, store: TutorStore) {
        let records = store.allProgress(instrument: course.instrument)
        self.init(course: course, statuses: Dictionary(records.map { ($0.lessonID, $0.progressStatus) },
                                                       uniquingKeysWith: { a, b in a == .completed ? a : b }))
    }

    func state(of lessonID: String) -> LessonState { states[lessonID] ?? .locked }

    func isUnlocked(_ branch: Branch) -> Bool { statuses[branch.unlocksAfter] == .completed }

    /// First in-progress or available main-path lesson; nil when the path is finished.
    var continueTarget: Lesson? {
        course.mainPathLessons.first { [.inProgress, .available].contains(state(of: $0.id)) }
    }

    /// Stage holding `continueTarget`.
    var currentStage: Stage? {
        guard let target = continueTarget else { return nil }
        return course.stages.first { $0.lessons.contains { $0.id == target.id } }
    }

    /// Completed share of a stage's main-path lessons, 0...1.
    func completion(of stage: Stage) -> Double {
        guard !stage.lessons.isEmpty else { return 0 }
        let done = stage.lessons.filter { state(of: $0.id) == .completed }.count
        return Double(done) / Double(stage.lessons.count)
    }

    func completion(of branch: Branch) -> Double {
        guard !branch.lessons.isEmpty else { return 0 }
        return Double(branch.lessons.filter { state(of: $0.id) == .completed }.count) / Double(branch.lessons.count)
    }

    /// Completed share of the whole main path.
    var overallCompletion: Double {
        let lessons = course.mainPathLessons
        guard !lessons.isEmpty else { return 0 }
        return Double(lessons.filter { state(of: $0.id) == .completed }.count) / Double(lessons.count)
    }

    /// Lesson ids completed on any path (main or branch).
    var completedLessonIDs: Set<String> {
        Set(states.filter { $0.value == .completed }.map(\.key))
    }
}
