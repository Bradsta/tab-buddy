//
//  TutorShellTests.swift
//  TabBuddyTests
//
//  WP-E-a tutor shell view-model logic: path node states (with branches),
//  continue target, review session grading into the scheduler, review card
//  construction, glossary search, song suggestions, and the calibration view
//  model with a fake calibrator.
//

import SwiftData
import XCTest
@testable import TabBuddy

@MainActor
final class TutorShellTests: XCTestCase {

    // MARK: Fixtures

    private func lesson(_ id: String, _ title: String, chords: [String]? = nil,
                        reviewItems: [ReviewItemSeed] = []) -> Lesson {
        var steps: [LessonStep] = [.explain(ExplainStep(title: "Read", body: "Body"))]
        if let chords {
            steps.append(.practice(PracticeStep(exercise: ExerciseSpec(kind: .playChord, prompt: "Play", chords: chords))))
        }
        var l = Lesson(id: id, title: title, summary: "S", minutes: 5, steps: steps)
        l.reviewItems = reviewItems
        return l
    }

    private func course() -> Course {
        var s0 = Stage(id: "g.s0", instrument: .guitar, order: 0, title: "Setup", summary: "",
                       lessons: [lesson("g.s0.l1", "One"), lesson("g.s0.l2", "Two", chords: ["E", "A"])])
        s0.branches = [Branch(id: "g.b.x", title: "Detour", summary: "", unlocksAfter: "g.s0.l2",
                              lessons: [lesson("g.b.x.l1", "Side A"), lesson("g.b.x.l2", "Side B")])]
        let s1 = Stage(id: "g.s1", instrument: .guitar, order: 1, title: "Chords", summary: "",
                       lessons: [lesson("g.s1.l1", "Three", chords: ["D"]), lesson("g.s1.l2", "Four")])
        return Course(instrument: .guitar, title: "Guitar", stages: [s0, s1])
    }

    // MARK: Path

    func testPathNodeStatesWithBranches() {
        let c = course()
        let progress = PathProgress(course: c, statuses: ["g.s0.l1": .completed, "g.s0.l2": .completed,
                                                           "g.s1.l1": .inProgress])
        let model = TutorPathModel(course: c, progress: progress)
        XCTAssertEqual(model.sections.map { $0.nodes.map(\.state) },
                       [[.completed, .completed], [.inProgress, .locked]])
        XCTAssertEqual(model.sections[0].completion, 1)
        XCTAssertTrue(model.sections[1].isCurrent)
        XCTAssertTrue(model.node(for: "g.s1.l1")!.isCurrent)
        XCTAssertEqual(model.node(for: "g.s1.l2")!.lockedReason, "Finish “Three” to unlock this lesson.")

        let branch = model.sections[0].branches[0]
        XCTAssertTrue(branch.isUnlocked)
        XCTAssertEqual(branch.anchorLessonID, "g.s0.l2")
        XCTAssertEqual(model.sections[0].branches(after: "g.s0.l2").map(\.id), ["g.b.x"])
        XCTAssertEqual(branch.nodes.map(\.state), [.available, .locked])
        XCTAssertTrue(branch.nodes.allSatisfy(\.isBranch))
        XCTAssertEqual(branch.nodes[1].lockedReason, "Finish “Side A” in this detour first.")
    }

    func testLockedBranchExplainsUnlockAndNeverBlocksMainPath() {
        let c = course()
        let progress = PathProgress(course: c, statuses: ["g.s0.l1": .completed])
        let model = TutorPathModel(course: c, progress: progress)
        let branch = model.sections[0].branches[0]
        XCTAssertFalse(branch.isUnlocked)
        XCTAssertEqual(branch.unlockHint, "Unlocks after “Two”.")
        XCTAssertEqual(branch.nodes[0].lockedReason, "Optional detour. Unlocks after “Two”.")

        // Completing the main path without touching the branch finishes it.
        let done = PathProgress(course: c, statuses: ["g.s0.l1": .completed, "g.s0.l2": .completed,
                                                       "g.s1.l1": .completed, "g.s1.l2": .completed])
        XCTAssertEqual(TutorPathModel(course: c, progress: done).continueCard.kind, .finished)
    }

    func testContinueCard() {
        let c = course()
        let fresh = TutorPathModel(course: c, progress: PathProgress(course: c, statuses: [:])).continueCard
        XCTAssertEqual(fresh.kind, .start)
        XCTAssertEqual(fresh.lesson?.id, "g.s0.l1")
        XCTAssertEqual(fresh.stageTitle, "Setup")
        XCTAssertEqual(fresh.minutes, 5)
        XCTAssertEqual(fresh.buttonTitle, "Start lesson")

        let resume = TutorPathModel(course: c, progress: PathProgress(course: c, statuses: [
            "g.s0.l1": .completed, "g.s0.l2": .completed, "g.s1.l1": .inProgress])).continueCard
        XCTAssertEqual(resume.kind, .resume)
        XCTAssertEqual(resume.lesson?.id, "g.s1.l1")
        XCTAssertEqual(resume.stageNumber, 1)

        XCTAssertEqual(TutorPathModel.actionTitle(for: .completed), "Review lesson")
        XCTAssertNil(TutorPathModel.actionTitle(for: .locked))
    }

    func testStepSummaries() {
        let summaries = TutorStepSummary.summaries(for: lesson("x", "X", chords: ["E"]))
        XCTAssertEqual(summaries.map(\.kind), [.explain, .practice])
        XCTAssertEqual(summaries.map(\.usesMicrophone), [false, true])
    }

    // MARK: Reviews

    private func card(_ id: String, _ kind: ReviewKind, prompt: String = "Q", answer: String) -> TutorReviewCard {
        TutorReviewCard(itemID: id, kind: kind, prompt: prompt, answer: answer, state: ReviewState(due: Date()))
    }

    func testReviewPresentationByKind() {
        XCTAssertEqual(TutorReviewCardBuilder.presentation(for: card("f", .fact, answer: "A"), seed: nil,
                                                           instrument: .guitar), .fact)

        guard case .choice(let q) = TutorReviewCardBuilder.presentation(for: card("n", .noteName, answer: "G"),
                                                                        seed: nil, instrument: .guitar) else {
            return XCTFail("noteName should be multiple choice")
        }
        XCTAssertEqual(q.choices.count, 4)
        XCTAssertEqual(q.choices[q.answerIndex], "G")
        XCTAssertEqual(Set(q.choices).count, 4)
        XCTAssertFalse(q.choices.contains { $0.contains("#") }, "natural answers get natural distractors")

        let binary = TutorReviewCardBuilder.question(for: card("q", .earQuality, prompt: "Major or minor?", answer: "Minor"),
                                                     seed: nil)!
        XCTAssertEqual(Set(binary.choices), ["Major", "Minor"])

        let interval = TutorReviewCardBuilder.question(for: card("i", .earInterval, answer: "Perfect 5th"), seed: nil)!
        XCTAssertEqual(interval.choices[interval.answerIndex], "Perfect 5th")
        let step = TutorReviewCardBuilder.question(for: card("s", .earInterval, answer: "Whole step"), seed: nil)!
        XCTAssertEqual(Set(step.choices), ["Half step", "Whole step"])

        let seventh = TutorReviewCardBuilder.question(for: card("d", .earQuality, answer: "Dominant seventh"), seed: nil)!
        XCTAssertFalse(seventh.choices.contains("Dominant 7th"), "synonym must not appear as a distractor")

        let octave = TutorReviewCardBuilder.question(for: card("o", .noteName, answer: "C4 (middle C)"), seed: nil)!
        XCTAssertTrue(octave.choices.filter { $0 != "C4 (middle C)" }.allSatisfy { $0.hasSuffix("4") })

        // Same card, same choices.
        XCTAssertEqual(TutorReviewCardBuilder.question(for: card("n", .noteName, answer: "G"), seed: nil), q)
    }

    func testPlayTargetsFromAnswers() {
        XCTAssertEqual(TutorReviewCardBuilder.pitchTokens(in: "D3 (string 6, fret 10)"), ["D3"])
        XCTAssertEqual(TutorReviewCardBuilder.pitchTokens(in: "C3 (string 5 fret 3), then C4 (string 3 fret 5)."), ["C3", "C4"])
        XCTAssertEqual(TutorReviewCardBuilder.pitchTokens(in: "B♭4"), ["Bb4"])

        let notes = TutorReviewCardBuilder.playTargets(for: card("p", .playNote, answer: "A2"), seed: nil, instrument: .guitar)
        XCTAssertEqual(notes.map(\.event.pitches), [[45]])

        let chords = TutorReviewCardBuilder.playTargets(for: card("c", .playChord, answer: "C, G"), seed: nil, instrument: .guitar)
        XCTAssertEqual(chords.map(\.label), ["C", "G"])
        XCTAssertEqual(chords.map(\.event.id), [0, 1])
        XCTAssertFalse(chords[0].event.pitches.isEmpty)

        let piano = TutorReviewCardBuilder.playTargets(for: card("pc", .playChord, answer: "Am7"), seed: nil, instrument: .piano)
        XCTAssertTrue(piano[0].event.octaveTolerant)

        // Unparseable answers fall back to self-grading.
        XCTAssertEqual(TutorReviewCardBuilder.presentation(for: card("u", .playNote, answer: "any"), seed: nil,
                                                           instrument: .guitar), .fact)
    }

    func testReviewSessionGradesIntoScheduler() throws {
        let store = try TutorStore.inMemory()
        let past = Date().addingTimeInterval(-3600)
        for (id, kind) in [("a", ReviewKind.fact), ("b", .noteName), ("c", .fact)] {
            try store.addReviewCardIfMissing(ReviewCardRecord(itemID: id, instrument: .guitar, kind: kind.rawValue,
                                                              prompt: "P", answer: "G", due: past))
        }
        let library = CurriculumLibrary(content: .empty)
        let session = TutorReviewSessionModel(instrument: .guitar, store: store, library: library)
        XCTAssertEqual(session.total, 3)

        let first = try XCTUnwrap(session.current)
        XCTAssertEqual(session.previewIntervals(for: first)[.again].map { Int($0) }, Int(ReviewScheduler.relearnDelay))
        session.revealed = true
        session.grade(.good)
        let graded = try XCTUnwrap(store.reviewCard(itemID: first.itemID, instrument: .guitar))
        XCTAssertEqual(graded.reps, 1)
        XCTAssertGreaterThan(graded.due, Date())
        XCTAssertFalse(session.revealed)

        // Choice card: wrong answer → again, recorded on next().
        let second = try XCTUnwrap(session.current)
        session.answeredChoice(correct: false)
        session.answeredChoice(correct: true)   // ignored after the first answer
        XCTAssertEqual(session.autoGrade, .again)
        session.next()
        let again = try XCTUnwrap(store.reviewCard(itemID: second.itemID, instrument: .guitar))
        XCTAssertEqual(again.reps, 1)
        XCTAssertLessThanOrEqual(again.due.timeIntervalSinceNow, ReviewScheduler.relearnDelay + 5)

        // Skip leaves the card due and unrecorded.
        let third = try XCTUnwrap(session.current)
        session.skip()
        XCTAssertEqual(store.reviewCard(itemID: third.itemID, instrument: .guitar)?.reps, 0)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.summary.reviewed, 2)
        XCTAssertEqual(session.summary.again, 1)
        XCTAssertEqual(session.summary.skipped, 1)
        XCTAssertEqual(store.dueReviewCount(instrument: .guitar), 1)
    }

    func testIntervalCaption() {
        XCTAssertEqual(TutorReviewSessionModel.intervalCaption(600), "10m")
        XCTAssertEqual(TutorReviewSessionModel.intervalCaption(3 * 86_400), "3d")
        XCTAssertEqual(TutorReviewSessionModel.intervalCaption(90 * 86_400), "3mo")
    }

    // MARK: Glossary

    func testGlossarySearch() {
        let entries = [
            GlossaryEntry(term: "Major scale", definition: "W-W-H-W-W-W-H."),
            GlossaryEntry(term: "Scale degree", definition: "A note's position in a scale."),
            GlossaryEntry(term: "Octave", definition: "Same letter, double the frequency."),
            GlossaryEntry(term: "Pentatonic scale", definition: "Five notes."),
            GlossaryEntry(term: "Tonic", definition: "Home note of a scale."),
        ]
        XCTAssertEqual(TutorGlossarySearch.filter(entries, query: "").count, 5)
        XCTAssertEqual(TutorGlossarySearch.filter(entries, query: "scale").map(\.term),
                       ["Major scale", "Scale degree", "Pentatonic scale", "Tonic"])
        XCTAssertEqual(TutorGlossarySearch.filter(entries, query: "OCT").map(\.term), ["Octave"])
        XCTAssertEqual(TutorGlossarySearch.filter(entries, query: "frequency").map(\.term), ["Octave"])
        XCTAssertTrue(TutorGlossarySearch.filter(entries, query: "zzz").isEmpty)
        XCTAssertEqual(TutorGlossarySearch.sections(entries).map(\.letter), ["M", "S", "O", "P", "T"])
    }

    // MARK: Songs

    func testSongSuggestionAdapter() {
        let c = course()
        let songs = [
            TutorLibrarySong(fileID: UUID(), title: "Two chords", chords: ["E", "A", "E"]),
            TutorLibrarySong(fileID: UUID(), title: "Needs D", chords: ["E", "D"]),
            TutorLibrarySong(fileID: UUID(), title: "Far away", chords: ["F#m7", "Bb", "C#"]),
        ]
        let none = PathProgress(course: c, statuses: [:])
        XCTAssertTrue(TutorSongSuggestionAdapter.rows(songs: songs, course: c, progress: none).ready.isEmpty)

        let learnedEA = PathProgress(course: c, statuses: ["g.s0.l1": .completed, "g.s0.l2": .completed])
        let rows = TutorSongSuggestionAdapter.rows(songs: songs, course: c, progress: learnedEA)
        XCTAssertEqual(rows.ready.map(\.title), ["Two chords"])
        XCTAssertEqual(rows.ready.first?.fileID, songs[0].fileID)
        XCTAssertEqual(rows.ready.first?.chords, ["E", "A"])
        XCTAssertEqual(rows.almost.map(\.title), ["Needs D"])
        XCTAssertEqual(rows.almost.first?.missing, ["D"])
        XCTAssertEqual(TutorSongSuggestionAdapter.learnedChordSymbols(course: c, progress: learnedEA), ["E", "A"])
    }

    func testChordNamesFromCanonicalMusicXML() {
        let tab = CanonicalTab(title: "T", measures: [CanonicalMeasure(number: 1, chords: [CanonicalChord(name: "Am", positionInMeasure: 0),
                                                                              CanonicalChord(name: "F#m7", positionInMeasure: 0.5)]),
                                          CanonicalMeasure(number: 2, chords: [CanonicalChord(name: "Am", positionInMeasure: 0)])])
        let data = MusicXMLCodec.encode(tab)
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromMusicXML: data), ["Am", "F#m7"])
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromMusicXML: Data("<score-partwise/>".utf8)), [])
    }

    func testChordNamesFromTextTabs() throws {
        let tab = """
          G           C
        e|-3---3---|-0---0---|
        B|-0---0---|-1---1---|
        G|-0---0---|-0---0---|
        D|-0---0---|-2---2---|
        A|-2---2---|-3---3---|
        E|-3---3---|---------|
        """
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTabText: tab), ["G", "C"])

        // Chord sheet without tab staves: chord-symbol lines only.
        let sheet = "Verse\r\nAm      F       C\r\nA man walks down the road\r\nG   Am\r\n"
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTabText: sheet), ["Am", "F", "C", "G"])
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTabText: "Just some words here"), [])

        // File reads are cached by path and modification date, and skip large files.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chords-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(sheet.utf8).write(to: url)
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTextTabAt: url, cacheKey: url.path), ["Am", "F", "C", "G"])
        try Data(repeating: 0x41, count: TutorLibraryChordIndex.textTabByteLimit + 1).write(to: url)
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTextTabAt: url, cacheKey: url.path), [])
    }

    // MARK: Shell state

    func testShellStateInstrumentResetAndSeeding() throws {
        let store = try TutorStore.inMemory()
        let content = CurriculumContent(courses: [.guitar: course()], glossary: [], stageFiles: [:], loadIssues: [])
        let state = TutorShellState(store: store, library: CurriculumLibrary(content: content))
        state.refresh()
        XCTAssertEqual(state.progress?.continueTarget?.id, "g.s0.l1")

        state.seedProgress(firstLessons: 2)
        XCTAssertEqual(state.progress?.continueTarget?.id, "g.s1.l1")
        XCTAssertEqual(state.practiceDays, 1)
        XCTAssertEqual(state.todayMinutes, 10)

        state.setInstrument(.piano)
        XCTAssertEqual(store.settings().instrument, .piano)
        XCTAssertNil(state.progress, "no piano course in this fixture")
        state.setInstrument(.guitar)

        state.setDailyGoal(200)
        XCTAssertEqual(state.dailyGoalMinutes, 60)

        store.setLatency(0.05, forRoute: "r")
        state.resetProgress(for: .guitar)
        XCTAssertTrue(store.allProgress(instrument: .guitar).isEmpty)
        XCTAssertEqual(state.progress?.continueTarget?.id, "g.s0.l1")
        XCTAssertEqual(store.latency(forRoute: "r"), 0.05, "reset keeps calibration")
    }

    func testLessonExitRecordsCompletionOnce() throws {
        let store = try TutorStore.inMemory()
        let c = course()
        let content = CurriculumContent(courses: [.guitar: c], glossary: [], stageFiles: [:], loadIssues: [])
        let state = TutorShellState(store: store, library: CurriculumLibrary(content: content))
        let first = c.stages[0].lessons[0]
        state.lessonDidExit(first, completed: false)
        XCTAssertNil(store.progress(lessonID: first.id, instrument: .guitar))
        state.lessonDidExit(first, completed: true)
        state.lessonDidExit(first, completed: true)
        XCTAssertEqual(store.progress(lessonID: first.id, instrument: .guitar)?.attempts, 1)
        XCTAssertEqual(state.progress?.state(of: first.id), .completed)
    }

    // MARK: Games

    func testGameRegistry() {
        XCTAssertEqual(Set(TutorGameRegistry.entries.map(\.id)).count, TutorGameRegistry.entries.count)
        XCTAssertTrue(TutorGameRegistry.entries(for: .guitar).contains { $0.id == TutorGameID.fretboardHunt })
        XCTAssertFalse(TutorGameRegistry.entries(for: .piano).contains { $0.id == TutorGameID.fretboardHunt })
        for entry in TutorGameRegistry.entries {
            XCTAssertFalse(entry.instruments.isEmpty)
            if entry.instruments.contains(.guitar) {
                _ = TutorGameRegistry.isAvailable(entry, instrument: .guitar)   // must not crash
            }
        }
    }

    // MARK: Calibration

    func testCalibrationModelAudioSuccessAndFailure() async {
        let fake = FakeCalibrator()
        fake.audioResult = LatencyEstimate(latency: 0.062, spread: 0.01, matched: 7, cues: 8)
        let model = TutorCalibrationModel(calibrator: fake, instrument: .guitar, sleep: { _ in })
        XCTAssertFalse(model.isCalibrated)
        XCTAssertEqual(model.currentLatency, LatencyCalibrator.defaultLatency)

        await model.runAudio()
        XCTAssertEqual(fake.audioCalls, 1)
        XCTAssertEqual(fake.lastClicks, 8)
        XCTAssertEqual(model.step, .finished(fake.audioResult!, saved: true))
        XCTAssertTrue(model.isCalibrated)
        XCTAssertEqual(model.currentLatency, 0.062, accuracy: 1e-9)
        XCTAssertEqual(model.resultMessage?.hasPrefix("Saved 62 ms"), true)

        fake.audioResult = LatencyEstimate(latency: 0.2, spread: 0.1, matched: 3, cues: 8)
        await model.runAudio()
        XCTAssertEqual(model.step, .finished(fake.audioResult!, saved: false))
        XCTAssertEqual(model.currentLatency, 0.062, accuracy: 1e-9, "unreliable result is not saved")

        fake.audioResult = nil
        fake.failure = "No matching notes"
        await model.runAudio()
        XCTAssertEqual(model.step, .failed("No matching notes"))
    }

    func testCalibrationModelVisualPulses() async {
        let fake = FakeCalibrator()
        fake.visualResult = LatencyEstimate(latency: 0.09, spread: 0.02, matched: 8, cues: 8)
        let model = TutorCalibrationModel(calibrator: fake, instrument: .piano, sleep: { _ in })
        XCTAssertEqual(model.profile.instrument, .piano)
        await model.runVisual()
        XCTAssertEqual(fake.cues, TutorCalibrationModel.pulseCount)
        XCTAssertEqual(model.step, .finished(fake.visualResult!, saved: true))

        fake.beginSucceeds = false
        fake.failure = "Microphone access is off."
        await model.runVisual()
        XCTAssertEqual(model.step, .failed("Microphone access is off."))
    }

    func testRouteAndPitchCheckFormatting() {
        XCTAssertEqual(TutorCalibrationModel.routeDescription("out=Speaker;in=MicrophoneBuiltIn"),
                       "Speaker · Built-in microphone")
        XCTAssertTrue(TutorCalibrationModel.isBluetoothRoute("out=BluetoothA2DPOutput;in=MicrophoneBuiltIn"))
        XCTAssertFalse(TutorCalibrationModel.isBluetoothRoute("out=Speaker;in=MicrophoneBuiltIn"))
        XCTAssertEqual(TutorCalibrationModel.latencyText(0.0804), "80 ms")

        let target = TutorCalibrationModel.checkTarget(for: .guitar).midi
        XCTAssertEqual(target, 40)
        XCTAssertEqual(TutorCalibrationModel.checkTarget(for: .piano).midi, 60)
        XCTAssertEqual(TutorCalibrationModel.pitchCheck(midi: nil, cents: nil, target: target), .waiting)
        XCTAssertEqual(TutorCalibrationModel.pitchCheck(midi: 40, cents: -6.4, target: target), .match(cents: -6))
        XCTAssertEqual(TutorCalibrationModel.pitchCheck(midi: 52, cents: 0, target: target), .wrongOctave(heard: "E3"))
        XCTAssertEqual(TutorCalibrationModel.pitchCheck(midi: 45, cents: 0, target: target), .other(heard: "A2"))
        XCTAssertTrue(TutorCalibrationModel.pitchCheckMessage(.match(cents: 25), target: 40).contains("25 cents sharp"))
    }

    func testShellLatencyStoreWritesTutorStore() throws {
        let store = try TutorStore.inMemory()
        let route = "test-route-\(UUID().uuidString)"
        let latency = TutorShellLatency.store(store)
        latency.setLatency(0.07, forRoute: route)
        XCTAssertEqual(store.latency(forRoute: route), 0.07)
        XCTAssertEqual(latency.latency(forRoute: route), 0.07)
        UserDefaults.standard.removeObject(forKey: "tutor.latency." + route)
    }
}

@MainActor
private final class FakeCalibrator: TutorLatencyCalibrating {
    var audioResult: LatencyEstimate?
    var visualResult: LatencyEstimate?
    var failure: String?
    var beginSucceeds = true
    var stored: TimeInterval?
    private(set) var audioCalls = 0
    private(set) var lastClicks = 0
    private(set) var cues = 0

    func runAudioCalibration(profile: InstrumentProfile, clicks: Int, interval: TimeInterval) async -> LatencyEstimate? {
        audioCalls += 1
        lastClicks = clicks
        if let r = audioResult, r.isReliable { stored = r.latency }
        return audioResult
    }

    func beginVisualCalibration(profile: InstrumentProfile) async -> Bool {
        cues = 0
        return beginSucceeds
    }

    func registerVisualCue(hostTime: UInt64) { cues += 1 }

    func finishVisualCalibration() async -> LatencyEstimate? {
        if let r = visualResult, r.isReliable { stored = r.latency }
        return visualResult
    }

    func cancel() {}
    func currentLatency() -> TimeInterval { stored ?? LatencyCalibrator.defaultLatency }
    var isCalibrated: Bool { stored != nil }
    var failureMessage: String? { failure }
}
