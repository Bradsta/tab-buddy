//
//  LessonPageModel.swift
//  TabBuddy
//
//  A lesson as one textbook chapter: every step is a section with a heading,
//  rendered in order on one scrolling page. "Check yourself" (quiz) steps are
//  collected at the end of the chapter. There is no gating, grading, or
//  score; the only state is "done" (read), toggled by the learner and stored
//  through `TutorStore.setLessonCompleted`.
//

import Foundation
import SwiftUI

/// One section of a lesson page.
struct LessonSection: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case explain, demo, practice, quiz, song

        /// Chapter eyebrow text.
        var label: String {
            switch self {
            case .explain: return "Read"
            case .demo: return "Example"
            case .practice: return "Try it"
            case .quiz: return "Check yourself"
            case .song: return "Song"
            }
        }

        var systemImage: String {
            switch self {
            case .explain: return "text.book.closed"
            case .demo: return "speaker.wave.2"
            case .practice: return "music.quarternote.3"
            case .quiz: return "questionmark.circle"
            case .song: return "music.note.list"
            }
        }
    }

    /// Position on the page (0-based).
    var index: Int
    /// Index into `Lesson.steps`.
    var stepIndex: Int
    var kind: Kind
    var title: String
    var step: LessonStep

    var id: Int { stepIndex }
    /// "1.3"-style numbering used in headings and the table of contents.
    var number: Int { index + 1 }
}

@MainActor
final class LessonPageModel: ObservableObject {
    let lesson: Lesson
    let instrument: TutorInstrument
    let sections: [LessonSection]
    /// Salt for generated content (quiz sets, interval rounds) on this page view.
    let salt: UInt64

    @Published private(set) var isDone: Bool
    @Published private(set) var saveError: String?

    private let store: TutorStore?
    private let now: () -> Date

    init(lesson: Lesson, instrument: TutorInstrument, store: TutorStore? = nil,
         salt: UInt64 = UInt64.random(in: 0...UInt64(UInt32.max)), now: @escaping () -> Date = Date.init) {
        self.lesson = lesson
        self.instrument = instrument
        self.store = store
        self.salt = salt
        self.now = now
        sections = Self.sections(for: lesson)
        isDone = store?.progress(lessonID: lesson.id, instrument: instrument)?.progressStatus == .completed
    }

    /// Steps in authored order, with quiz steps moved to the end of the chapter.
    nonisolated static func sections(for lesson: Lesson) -> [LessonSection] {
        var body: [(Int, LessonStep)] = []
        var checks: [(Int, LessonStep)] = []
        for (i, step) in lesson.steps.enumerated() {
            if case .quiz = step { checks.append((i, step)) } else { body.append((i, step)) }
        }
        return (body + checks).enumerated().map { position, entry in
            LessonSection(index: position, stepIndex: entry.0, kind: kind(of: entry.1), title: title(for: entry.1),
                          step: entry.1)
        }
    }

    nonisolated static func kind(of step: LessonStep) -> LessonSection.Kind {
        switch step {
        case .explain: return .explain
        case .demo: return .demo
        case .practice: return .practice
        case .quiz: return .quiz
        case .song: return .song
        }
    }

    nonisolated static func title(for step: LessonStep) -> String {
        switch step {
        case .explain(let s): return s.title
        case .demo(let s): return s.title
        case .practice(let s): return s.exercise.prompt
        case .quiz(let s): return s.title
        case .song(let s): return s.title
        }
    }

    /// Section showing a given step, for jump links from the exercise index.
    func section(forStep stepIndex: Int) -> LessonSection? {
        sections.first { $0.stepIndex == stepIndex }
    }

    var hasCheckYourself: Bool { sections.contains { $0.kind == .quiz } }
    var usesMicrophone: Bool { sections.contains { $0.kind == .practice || $0.kind == .song } }

    /// Stable seed for generated content in one section.
    func seed(for section: LessonSection) -> UInt64 {
        TutorAudioHelpers.seed("\(lesson.id)#\(section.stepIndex)", salt: salt)
    }

    /// Intervals taught so far (interval echo exercises).
    var intervals: [Interval]? {
        if let course = CurriculumLibrary.shared.course(for: instrument),
           let taught = ExerciseGenerator.intervalsTaught(through: lesson.id, in: course) {
            return taught
        }
        return ExerciseGenerator.intervals(forLesson: lesson)
    }

    var stage: Int? { ExerciseGenerator.stage(ofLessonID: lesson.id) }

    // MARK: Done

    /// Marks the chapter read (or not). Done records no attempt and no score.
    func setDone(_ done: Bool) {
        isDone = done
        guard let store else { return }
        do {
            try store.setLessonCompleted(lessonID: lesson.id, instrument: instrument, completed: done, date: now())
            saveError = nil
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
        }
    }

    func toggleDone() { setDone(!isDone) }
}
