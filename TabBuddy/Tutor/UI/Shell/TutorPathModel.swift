//
//  TutorPathModel.swift
//  TabBuddy
//
//  View model for the book's contents: stages (parts) → lesson nodes
//  (chapters) with states from `PathProgress`, optional side branches placed
//  after the lesson that suggests them, and the "Next up" target. Done means
//  read. Pure value logic (tested in TutorShellTests).
//

import Foundation

struct TutorPathNode: Identifiable, Hashable {
    var lesson: Lesson
    var state: LessonState
    /// 1-based position within its stage or branch.
    var number: Int
    var isBranch: Bool
    /// True for the main-path continue target.
    var isCurrent: Bool
    /// Why the lesson is locked; nil when open.
    var lockedReason: String?

    var id: String { lesson.id }
}

struct TutorBranchSection: Identifiable, Hashable {
    var branch: Branch
    var isUnlocked: Bool
    var completion: Double
    var nodes: [TutorPathNode]
    /// Main-path lesson after which the branch is drawn.
    var anchorLessonID: String
    /// Shown when locked ("Unlocks after …").
    var unlockHint: String

    var id: String { branch.id }
}

struct TutorStageSection: Identifiable, Hashable {
    var stage: Stage
    var completion: Double
    var nodes: [TutorPathNode]
    var branches: [TutorBranchSection]
    var isCurrent: Bool

    var id: String { stage.id }
    var completedCount: Int { nodes.filter { $0.state == .completed }.count }

    /// Branches drawn right after `lessonID` (main-path lesson).
    func branches(after lessonID: String) -> [TutorBranchSection] {
        branches.filter { $0.anchorLessonID == lessonID }
    }
}

struct TutorContinueCard: Hashable {
    enum Kind: Hashable { case start, resume, finished }
    var kind: Kind
    var lesson: Lesson?
    var stageTitle: String
    var stageNumber: Int
    var minutes: Int

    var buttonTitle: String {
        switch kind {
        case .start: return "Open chapter"
        case .resume: return "Continue chapter"
        case .finished: return "Open any chapter"
        }
    }
}

struct TutorPathModel {
    let course: Course
    let progress: PathProgress
    let sections: [TutorStageSection]

    init(course: Course, progress: PathProgress) {
        self.course = course
        self.progress = progress
        let titles = Dictionary(course.allLessonLocations.map { ($0.lesson.id, $0.lesson.title) },
                                uniquingKeysWith: { a, _ in a })
        let currentID = progress.continueTarget?.id

        sections = course.stages.map { stage in
            let nodes = stage.lessons.enumerated().map { index, lesson -> TutorPathNode in
                let state = progress.state(of: lesson.id)
                return TutorPathNode(lesson: lesson, state: state, number: index + 1, isBranch: false,
                                     isCurrent: lesson.id == currentID, lockedReason: nil)
            }
            let stageLessonIDs = Set(stage.lessons.map(\.id))
            let branches = stage.branches.map { branch -> TutorBranchSection in
                let unlocked = progress.isUnlocked(branch)
                let anchorTitle = titles[branch.unlocksAfter] ?? "an earlier lesson"
                let hint = "Suggested after “\(anchorTitle)”."
                let branchNodes = branch.lessons.enumerated().map { index, lesson -> TutorPathNode in
                    TutorPathNode(lesson: lesson, state: progress.state(of: lesson.id), number: index + 1,
                                  isBranch: true, isCurrent: false, lockedReason: nil)
                }
                let anchor = stageLessonIDs.contains(branch.unlocksAfter)
                    ? branch.unlocksAfter : (stage.lessons.last?.id ?? branch.unlocksAfter)
                return TutorBranchSection(branch: branch, isUnlocked: unlocked,
                                          completion: progress.completion(of: branch), nodes: branchNodes,
                                          anchorLessonID: anchor, unlockHint: hint)
            }
            return TutorStageSection(stage: stage, completion: progress.completion(of: stage), nodes: nodes,
                                     branches: branches, isCurrent: stage.id == progress.currentStage?.id)
        }
    }

    var continueCard: TutorContinueCard {
        guard let target = progress.continueTarget, let stage = progress.currentStage else {
            let last = course.stages.last
            return TutorContinueCard(kind: .finished, lesson: nil, stageTitle: last?.title ?? course.title,
                                     stageNumber: last?.order ?? 0, minutes: 0)
        }
        let kind: TutorContinueCard.Kind = progress.state(of: target.id) == .inProgress ? .resume : .start
        return TutorContinueCard(kind: kind, lesson: target, stageTitle: stage.title, stageNumber: stage.order,
                                 minutes: target.minutes)
    }

    func node(for lessonID: String) -> TutorPathNode? {
        for section in sections {
            if let n = section.nodes.first(where: { $0.id == lessonID }) { return n }
            for b in section.branches {
                if let n = b.nodes.first(where: { $0.id == lessonID }) { return n }
            }
        }
        return nil
    }

    /// Button title in the chapter detail for a state; nil when locked.
    static func actionTitle(for state: LessonState) -> String? {
        switch state {
        case .locked: return nil
        case .available: return "Open chapter"
        case .inProgress: return "Continue chapter"
        case .completed: return "Read again"
        }
    }
}

// MARK: - Chapter section overview

/// Sections of a chapter in page order (quiz steps last), for the chapter
/// detail's contents list. `index` is the section index used by jump links.
struct TutorStepSummary: Hashable, Identifiable {
    enum Kind: String, Hashable { case explain, demo, practice, quiz, song }
    var kind: Kind
    var title: String
    var usesMicrophone: Bool
    var index: Int
    var id: Int { index }

    var systemImage: String {
        switch kind {
        case .explain: return "text.book.closed"
        case .demo: return "speaker.wave.2"
        case .practice: return "mic"
        case .quiz: return "questionmark.circle"
        case .song: return "music.note"
        }
    }

    var kindLabel: String {
        switch kind {
        case .explain: return "Read"
        case .demo: return "Example"
        case .practice: return "Try it"
        case .quiz: return "Check yourself"
        case .song: return "Song"
        }
    }

    static func summaries(for lesson: Lesson) -> [TutorStepSummary] {
        LessonPageModel.sections(for: lesson).map { section in
            let mic = section.kind == .practice || section.kind == .song
            return TutorStepSummary(kind: Kind(rawValue: section.kind.rawValue) ?? .explain, title: section.title,
                                    usesMicrophone: mic, index: section.index)
        }
    }
}
