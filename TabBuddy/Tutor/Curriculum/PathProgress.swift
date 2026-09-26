//
//  PathProgress.swift
//  TabBuddy
//
//  Lesson states along a course's path. Every lesson is open: the path is a
//  recommended order, and learners may skip ahead or mark lessons done.
//  Branches are optional detours suggested after their `unlocksAfter`
//  lesson and never block the main path. `.locked` remains in the enum for
//  stored-state compatibility but is no longer produced.
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
        func resolve(_ id: String) -> LessonState {
            switch statuses[id] ?? .notStarted {
            case .completed: return .completed
            case .inProgress: return .inProgress
            case .notStarted: return .available
            }
        }
        for lesson in course.mainPathLessons { states[lesson.id] = resolve(lesson.id) }
        for branch in course.allBranches {
            for lesson in branch.lessons { states[lesson.id] = resolve(lesson.id) }
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

    func state(of lessonID: String) -> LessonState { states[lessonID] ?? .available }

    /// Branches are always open; this reports whether the suggested point
    /// (`unlocksAfter`) has been reached.
    func isUnlocked(_ branch: Branch) -> Bool { statuses[branch.unlocksAfter] == .completed }

    /// First main-path lesson that is not completed; nil when the path is finished.
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
