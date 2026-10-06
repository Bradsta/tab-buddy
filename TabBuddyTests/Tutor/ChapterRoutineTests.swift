//
//  ChapterRoutineTests.swift
//  TabBuddyTests
//
//  End-of-chapter routine: segments come from the chapter (warm-up from the
//  previous chapter, up to three Try it items, then the song) and finishing
//  is recorded once per day.
//

import XCTest
@testable import TabBuddy

@MainActor
final class ChapterRoutineTests: XCTestCase {
    func testSegmentsFromChapterWithWarmUp() async throws {
        await CurriculumLibrary.shared.loadIfNeeded()
        let course = try XCTUnwrap(CurriculumLibrary.shared.course(for: .guitar))
        let lesson = try XCTUnwrap(course.lesson(id: "guitar.s2.l2"))
        let previous = ChapterRoutineBuilder.previousLesson(of: lesson.id, instrument: .guitar)
        XCTAssertEqual(previous?.id, "guitar.s2.l1")
        let segments = ChapterRoutineBuilder.segments(for: lesson, previous: previous)
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.first?.isWarmUp ?? false, "starts with the previous chapter's item")
        XCTAssertLessThanOrEqual(segments.filter { !$0.isWarmUp }.count, ChapterRoutineBuilder.maxPracticeSegments + 1)
        XCTAssertLessThanOrEqual(segments.map(\.minutes).reduce(0, +), 15, "a routine stays short")
    }

    func testFirstChapterOfAPartWarmsUpFromThePreviousPart() async throws {
        await CurriculumLibrary.shared.loadIfNeeded()
        let course = try XCTUnwrap(CurriculumLibrary.shared.course(for: .guitar))
        let first = try XCTUnwrap(course.stages.dropFirst().first?.lessons.first)
        let previous = ChapterRoutineBuilder.previousLesson(of: first.id, instrument: .guitar)
        XCTAssertEqual(previous?.id, course.stages.first?.lessons.last?.id)
    }

    func testRoutineDaysCountOncePerDay() throws {
        let suite = "routine-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let memory = PracticeMemory(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        memory.recordRoutine(lessonID: "x", at: day)
        memory.recordRoutine(lessonID: "x", at: day.addingTimeInterval(60))
        XCTAssertEqual(memory.routineDayCount(lessonID: "x"), 1)
        memory.recordRoutine(lessonID: "x", at: day.addingTimeInterval(86_400))
        XCTAssertEqual(memory.routineDayCount(lessonID: "x"), 2)
        XCTAssertTrue(memory.didRoutineToday(lessonID: "x", now: day.addingTimeInterval(86_400)))
        let reloaded = PracticeMemory(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reloaded.routineDayCount(lessonID: "x"), 2)
    }

    func testPracticeThisMapsLessonExercises() throws {
        let scale = ExerciseSpec(kind: .scale, prompt: "G major", scale: "G major", octaves: 1)
        XCTAssertEqual(PracticeSuggestions.launch(from: scale, instrument: .guitar)?.kind, .scale)
        let changes = ExerciseSpec(kind: .chordChanges, prompt: "C to G", chords: ["C", "G"])
        let launch = try XCTUnwrap(PracticeSuggestions.launch(from: changes, instrument: .guitar))
        XCTAssertEqual(launch.kind, .changes)
        XCTAssertEqual(launch.chords, ["C", "G"])
        XCTAssertEqual(PracticeSuggestions.title(for: launch), "C ↔ G")
        XCTAssertNil(PracticeSuggestions.launch(from: ExerciseSpec(kind: .improvise, prompt: "Jam"), instrument: .guitar))
    }

    func testTempoLadderStaysShortAroundTheLastTempo() {
        XCTAssertEqual(PracticeTempoLadder.steps(including: nil), [60, 72, 84, 96, 108])
        XCTAssertEqual(PracticeTempoLadder.steps(including: 90).count, 5)
        XCTAssertTrue(PracticeTempoLadder.steps(including: 90).contains(90))
    }
}
