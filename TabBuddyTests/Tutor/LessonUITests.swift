//
//  LessonUITests.swift
//  TabBuddyTests
//
//  WP-E-b lesson experience: view-model logic with fake audio seams (step
//  navigation, practice run state machine per pacing, quiz scoring and
//  answer-by-playing, completion writing progress) and diagram geometry.
//

import SwiftData
import XCTest
@testable import TabBuddy

// MARK: - Fakes

@MainActor
final class FakeTutorListener: TutorListening {
    var isListening = false
    var permissionDenied = false
    var inputLevel: Float = 0.3
    var takeClock: TimeInterval = 0
    var onVerification: ((VerificationResult) -> Void)?
    var onDetected: ((DetectedEvent) -> Void)?
    var detectionSources: TutorListener.DetectionSources = .all
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var armed: [[ExpectedEvent]] = []
    private(set) var timedStart: TimeInterval?

    /// When set, `start` waits for `releaseStart()`; `stop()` meanwhile
    /// cancels it, as `TutorListener` does.
    var holdsStart = false
    private(set) var isStarting = false
    private var startGate: CheckedContinuation<Void, Never>?
    private var startCancelled = false

    func start(profile: InstrumentProfile, recordTake: Bool) async throws {
        startCount += 1
        if let startError {
            if case TutorAudioError.permissionDenied = startError { permissionDenied = true }
            throw startError
        }
        if holdsStart {
            isStarting = true
            startCancelled = false
            await withCheckedContinuation { startGate = $0 }
            isStarting = false
            if startCancelled { return }
        }
        isListening = true
    }

    func releaseStart() {
        let gate = startGate
        startGate = nil
        gate?.resume()
    }

    @discardableResult func stop() -> URL? {
        if isStarting { startCancelled = true }
        if isListening { stopCount += 1 }
        isListening = false
        return nil
    }

    /// Interruption or route change: the input stopped without `stop()`.
    func simulateUnexpectedStop() {
        isListening = false
        NotificationCenter.default.post(name: .tutorListenerDidStopUnexpectedly, object: self)
    }

    func arm(_ events: [ExpectedEvent], window: ExpectedNoteVerifier.Window) { armed.append(events) }

    func armTimed(_ passage: ExpectedPassage, passageStart: TimeInterval, tempoScale: Double, tolerance: TimeInterval) {
        armed.append(passage.events)
        timedStart = passageStart
    }

    func disarm() {}

    func verify(_ id: Int, _ grade: EventGrade, heard: [Int] = [], unexpected: [Int] = [], at time: TimeInterval = 0) {
        onVerification?(VerificationResult(expectedID: id, grade: grade, heard: heard, unexpected: unexpected,
                                           onsetTime: time, confidence: grade == .uncertain ? 0.2 : 0.9))
    }

    func detect(_ pitches: [Int], at time: TimeInterval = 0, source: DetectionSource = .monophonic, confidence: Double = 0.9) {
        onDetected?(DetectedEvent(time: time, pitches: pitches, confidences: pitches.map { _ in confidence }, source: source))
    }
}

@MainActor
final class FakeSequencePlayer: TutorSequencePlaying {
    var isPlaying = false
    private(set) var played: [PlaybackSequence] = []
    private var completion: (() -> Void)?
    var listenerToCheck: FakeTutorListener?
    private(set) var playedWhileListening = false

    @discardableResult
    func play(_ sequence: PlaybackSequence, instrument: TutorInstrument, onStep: ((Int) -> Void)?,
              completion: (() -> Void)?) -> Bool {
        if listenerToCheck?.isListening == true { playedWhileListening = true }
        played.append(sequence)
        isPlaying = true
        onStep?(0)
        self.completion = completion
        return true
    }

    func finish() {
        isPlaying = false
        let c = completion
        completion = nil
        c?()
    }

    func stop() {
        isPlaying = false
        completion = nil
    }
}

// MARK: - Tests

@MainActor
final class LessonUITests: XCTestCase {

    private func practice(_ spec: ExerciseSpec, tips: [String] = []) -> PracticeStep {
        PracticeStep(exercise: spec, mistakeTips: tips)
    }

    private func makeRun(_ spec: ExerciseSpec, instrument: TutorInstrument = .guitar, tips: [String] = [],
                         intervals: [Interval]? = nil) -> (PracticeRunModel, FakeTutorListener, FakeSequencePlayer) {
        let listener = FakeTutorListener()
        let player = FakeSequencePlayer()
        player.listenerToCheck = listener
        let model = PracticeRunModel(step: practice(spec, tips: tips), instrument: instrument, intervals: intervals,
                                     listener: listener, player: player)
        model.autoTick = false
        return (model, listener, player)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition not met", file: file, line: line)
    }

    private func sampleLesson() -> Lesson {
        Lesson(id: "test.s1.l1", title: "Test lesson", summary: "", minutes: 5, steps: [
            .explain(ExplainStep(title: "Read", body: "Some **text**.")),
            .practice(PracticeStep(exercise: ExerciseSpec(kind: .playNote, prompt: "Play E", notes: ["E2"]))),
            .quiz(QuizStep(title: "Quiz", questions: [QuizQuestion(prompt: "Q?", choices: ["a", "b"], answerIndex: 0,
                                                                   explanation: "a")])),
        ], reviewItems: [ReviewItemSeed(id: "test.r1", kind: .fact, prompt: "p", answer: "a")])
    }

    // MARK: Step navigation

    func testStepNavigationGatesGradedSteps() {
        let model = LessonPlayerModel(lesson: sampleLesson(), instrument: .guitar)
        XCTAssertTrue(model.canAdvance)
        XCTAssertEqual(model.progress, 0)
        model.advance()
        XCTAssertEqual(model.index, 1)
        XCTAssertFalse(model.canAdvance, "practice needs a run or a skip")
        XCTAssertFalse(model.returnContinues)
        model.advance()
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.furthestReachable, 1)
        model.go(to: 2)
        XCTAssertEqual(model.index, 1, "cannot jump past an unfinished graded step")

        model.record(.skipped(label: "Play E"), forStep: 1)
        XCTAssertTrue(model.canAdvance)
        model.advance()
        XCTAssertEqual(model.index, 2)
        XCTAssertFalse(model.returnContinues, "Return belongs to the quiz while unanswered")
        model.record(StepOutcome(score: 1, passed: true, label: "Quiz"), forStep: 2)
        XCTAssertTrue(model.returnContinues)
        model.advance()
        XCTAssertTrue(model.isShowingCompletion)
        XCTAssertEqual(model.progress, 1)
        model.back()
        XCTAssertFalse(model.isShowingCompletion)
        XCTAssertEqual(model.index, 2)
        model.back()
        XCTAssertEqual(model.index, 1)
    }

    func testRecordKeepsBetterOutcomeAndScore() {
        let model = LessonPlayerModel(lesson: sampleLesson(), instrument: .guitar)
        model.record(.skipped(label: "p"), forStep: 1)
        model.record(StepOutcome(score: 0.6, passed: false, label: "p"), forStep: 1)
        XCTAssertEqual(model.outcomes[1]?.score, 0.6)
        model.record(StepOutcome(score: 0.4, passed: false, label: "p"), forStep: 1)
        XCTAssertEqual(model.outcomes[1]?.score, 0.6, "keeps the best run")
        model.record(StepOutcome(score: 1, passed: true, label: "q"), forStep: 2)
        XCTAssertEqual(model.score, 0.8, accuracy: 1e-9)
        XCTAssertEqual(model.skippedCount, 0)
        XCTAssertNotNil(model.weakestSummary)
    }

    func testCompletionWritesProgressAndSeedsCards() throws {
        let store = try TutorStore.inMemory()
        let lesson = sampleLesson()
        let model = LessonPlayerModel(lesson: lesson, instrument: .guitar)
        model.record(StepOutcome(score: 0.75, passed: true, label: "p"), forStep: 1)
        model.record(StepOutcome(score: 1, passed: true, label: "q"), forStep: 2)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model.complete(store: store, now: now)
        model.complete(store: store, now: now)   // idempotent
        XCTAssertTrue(model.didSave)
        let record = try XCTUnwrap(store.progress(lessonID: lesson.id, instrument: .guitar))
        XCTAssertEqual(record.progressStatus, .completed)
        XCTAssertEqual(record.attempts, 1)
        XCTAssertEqual(record.bestScore, 0.875, accuracy: 1e-9)
        XCTAssertNotNil(store.reviewCard(itemID: "test.r1", instrument: .guitar))
    }

    // MARK: Practice — wait mode

    func testWaitModeAdvancesOnHitsAndGradesClean() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2", "A2", "D3"]))
        XCTAssertEqual(model.pacing, .wait)
        var finished: PracticeRunModel.RunResult?
        model.onRunFinished = { finished = $0 }
        await model.start()
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(listener.armed.last?.count, 3)

        listener.verify(0, .hit)
        XCTAssertEqual(model.cursor, 1)
        XCTAssertEqual(model.marks[0], .hit)
        XCTAssertEqual(listener.armed.last?.count, 2, "re-armed with the remaining events")

        listener.verify(1, .wrongPitch, unexpected: [46])
        XCTAssertEqual(model.cursor, 1)
        XCTAssertEqual(model.marks[1], .retry)
        XCTAssertEqual(model.feedback?.tone, .caution)
        listener.verify(1, .hit)

        listener.verify(2, .uncertain)
        XCTAssertEqual(model.marks[2], .notSure)
        XCTAssertEqual(model.feedback?.tone, .neutral, "unsure is never shown as an error")
        listener.verify(2, .hit)

        XCTAssertEqual(model.phase, .finished)
        XCTAssertFalse(listener.isListening)
        XCTAssertEqual(finished?.accuracy, 1)
        XCTAssertEqual(finished?.passed, true)
        XCTAssertTrue(model.hasPassed)
    }

    func testWaitModeRepeatedMissesHalveCreditAndShowTips() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2", "A2"]),
                                           tips: ["Press behind the fret."])
        await model.start()
        listener.verify(0, .missed)
        listener.verify(0, .missed)
        listener.verify(0, .missed)
        XCTAssertEqual(model.coachMessage, .tip("Press behind the fret."))
        listener.verify(0, .hit)
        listener.verify(1, .hit)
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.lastResult?.accuracy ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(model.lastResult?.passed, false, "0.75 < 0.8")
    }

    func testSkipNoteAndIgnoresOtherEventIDs() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2", "A2"]))
        await model.start()
        listener.verify(1, .hit)   // not the current event
        XCTAssertEqual(model.cursor, 0)
        model.skipCurrentEvent()
        XCTAssertEqual(model.marks[0], .skipped)
        listener.verify(1, .hit)
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.lastResult?.accuracy ?? -1, 0.5, accuracy: 1e-9)
    }

    func testPermissionDeniedState() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2"]))
        listener.startError = TutorAudioError.permissionDenied
        await model.start()
        XCTAssertEqual(model.phase, .permissionDenied)
        XCTAssertFalse(model.phase.isActive)
    }

    func testStopCancelsWaitRun() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2", "A2"]))
        await model.start()
        listener.verify(0, .hit)
        model.stopRun()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(listener.isListening)
        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertNil(model.lastResult)
    }

    func testStopWhileMicrophoneStartsLeavesRunStopped() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2"]))
        listener.holdsStart = true
        let task = Task { await model.start() }
        await waitUntil { listener.isStarting }
        model.stopRun()
        XCTAssertEqual(model.phase, .ready)
        listener.releaseStart()
        await task.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(listener.isListening)

        listener.holdsStart = false
        await model.start()
        XCTAssertEqual(model.phase, .listening)
        XCTAssertTrue(listener.isListening)
    }

    func testUnexpectedStopShowsNeutralRestartState() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2", "A2"]))
        await model.start()
        XCTAssertEqual(model.phase, .listening)
        listener.simulateUnexpectedStop()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.feedback?.text, TutorListeningCopy.stoppedUnexpectedly)
        XCTAssertEqual(model.feedback?.tone, .neutral)
        await model.start()
        XCTAssertEqual(model.phase, .listening)
    }

    // MARK: Practice — timed

    func testTimedRunCountsInAndGradesAtEnd() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playSequence, prompt: "Play", notes: ["C4", "D4", "E4", "F4"],
                                                        bpm: 60), instrument: .piano)
        XCTAssertEqual(model.pacing, .timed)
        listener.takeClock = 1
        await model.start()
        guard case .countIn(_, let of) = model.phase else { return XCTFail("expected count-in, got \(model.phase)") }
        XCTAssertEqual(of, 4)
        let start = try! XCTUnwrap(listener.timedStart)
        XCTAssertEqual(start, 1 + 0.4 + 4, accuracy: 1e-9)

        listener.takeClock = start - 2.5
        model.tick()
        XCTAssertEqual(model.phase, .countIn(beat: 2, of: 4))
        listener.takeClock = start + 1.2
        model.tick()
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(model.cursor, 1)
        XCTAssertEqual(model.pulseBeat, 1)

        let events = model.events
        for (i, e) in events.enumerated() {
            listener.verify(e.id, .hit, heard: e.pitches, at: start + Double(i))
            listener.detect(e.pitches, at: start + Double(i), source: .verifier)
        }
        listener.takeClock = start + model.totalBeats + 1.1
        model.tick()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.lastResult?.accuracy ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(model.lastResult?.passed, true)
        XCTAssertTrue(events.allSatisfy { model.marks[$0.id] == .hit })
    }

    func testTimedRunWithNothingHeardIsNotAPass() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playSequence, prompt: "Play", notes: ["C4", "D4"], bpm: 90),
                                           instrument: .piano)
        await model.start()
        listener.takeClock = 100
        model.tick()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.lastResult?.passed, false)
    }

    // MARK: Practice — duration modes

    func testFindAllNotesTicksOffTargets() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .findAllNotes, prompt: "Find C", durationSec: 30, pitchClass: "C"))
        XCTAssertEqual(model.pacing, .anyOrder)
        XCTAssertEqual(model.targetPitches, [48, 60, 72])
        await model.start()
        XCTAssertEqual(listener.detectionSources, .monophonic)
        listener.detect([60])
        listener.detect([61])
        XCTAssertEqual(model.found, [60])
        listener.takeClock = 10
        model.tick()
        XCTAssertEqual(model.remaining ?? 0, 20, accuracy: 1e-9)
        listener.detect([48])
        listener.detect([72], confidence: 0.1)   // too unsure to count
        XCTAssertEqual(model.found.count, 2)
        listener.takeClock = 31
        model.tick()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.lastResult?.accuracy ?? 0, 2.0 / 3, accuracy: 1e-9)
    }

    func testChordChangesCountsCleanHits() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .chordChanges, prompt: "G to D", chords: ["G", "D"],
                                                        durationSec: 20, passAccuracy: 0.5))
        XCTAssertEqual(model.pacing, .countChanges)
        await model.start()
        let events = model.events
        XCTAssertEqual(events.first?.chordName, "G")
        listener.verify(events[0].id, .hit)
        listener.verify(events[1].id, .partial)
        listener.verify(events[1].id, .hit)
        listener.verify(events[2].id, .hit)
        XCTAssertEqual(model.cleanChords, 3)
        listener.takeClock = 25
        model.tick()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.lastResult?.accuracy ?? 0, 3.0 / Double(events.count), accuracy: 1e-9)
    }

    func testImproviseScoresInScaleShare() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .improvise, prompt: "Improvise", scale: "A minor pentatonic",
                                                        durationSec: 10, passAccuracy: 0.7))
        XCTAssertEqual(model.pacing, .free)
        await model.start()
        let notes = [57, 60, 62, 64, 67, 69, 72, 61, 57, 64]   // one C# outside the scale
        for (i, n) in notes.enumerated() { listener.detect([n], at: Double(i) * 0.5) }
        model.stopRun()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.lastResult?.accuracy ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(model.lastResult?.passed, true)
    }

    func testImproviseWithTooFewNotesIsUnsure() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .improvise, prompt: "Improvise", scale: "C major", durationSec: 5))
        await model.start()
        listener.detect([60])
        listener.takeClock = 6
        model.tick()
        XCTAssertEqual(model.lastResult?.unsure, true)
        XCTAssertEqual(model.lastResult?.passed, false)
    }

    func testSteadinessAndInScaleHelpers() {
        XCTAssertEqual(PracticeRunModel.steadiness(onsets: [0, 0.5, 1.0, 1.5, 2.0]) ?? 0, 1, accuracy: 1e-9)
        XCTAssertNil(PracticeRunModel.steadiness(onsets: [0, 0.5, 1.0]))
        let uneven = PracticeRunModel.steadiness(onsets: [0, 0.2, 1.0, 1.2, 2.0, 2.2]) ?? 1
        XCTAssertLessThan(uneven, 0.5)
        let allowed = Set(Scale("C major")!.pitchClasses)
        XCTAssertEqual(PracticeRunModel.inScaleShare([60, 62, 61, 64], allowed: allowed), 0.75)
    }

    // MARK: Practice — reference rounds

    func testIntervalPlaybackStopsListeningForReference() async {
        let (model, listener, player) = makeRun(ExerciseSpec(kind: .intervalPlayback, prompt: "Echo", notes: ["C4", "G4"],
                                                             repetitions: 2), instrument: .piano)
        XCTAssertTrue(model.hasReference)
        XCTAssertEqual(model.roundCount, 2)
        await model.start()
        XCTAssertEqual(model.phase, .playingReference)
        XCTAssertEqual(player.played.count, 1)
        XCTAssertFalse(listener.isListening)
        player.finish()
        await waitUntil { model.phase == .listening }
        XCTAssertTrue(listener.isListening)
        listener.verify(0, .hit)
        listener.verify(1, .hit)
        // Round 2: listening stops before the reference plays again.
        XCTAssertEqual(model.roundIndex, 1)
        XCTAssertEqual(model.phase, .playingReference)
        XCTAssertFalse(listener.isListening)
        XCTAssertFalse(player.playedWhileListening, "never plays while the microphone listens")
        player.finish()
        await waitUntil { model.phase == .listening }
        model.replayReference()
        XCTAssertEqual(model.phase, .playingReference)
        XCTAssertFalse(listener.isListening)
        player.finish()
        await waitUntil { model.phase == .listening }
        listener.verify(0, .hit)
        listener.verify(1, .hit)
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.lastResult?.accuracy, 1)
        XCTAssertFalse(player.playedWhileListening)
    }

    func testTempoOfferAfterThreeCleanRuns() async {
        let (model, listener, _) = makeRun(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2"], tempoSteps: [60, 70]))
        XCTAssertEqual(model.bpm, 60)
        for _ in 0..<3 {
            await model.start()
            listener.verify(0, .hit)
        }
        XCTAssertEqual(model.tempoOffer, 70)
        model.acceptTempo()
        XCTAssertEqual(model.bpm, 70)
        XCTAssertNil(model.tempoOffer)
    }

    func testGenerationErrorIsReported() {
        let (model, _, _) = makeRun(ExerciseSpec(kind: .playNote, prompt: "Play"))
        XCTAssertNil(model.exercise)
        XCTAssertNotNil(model.generationError)
    }

    // MARK: Quiz

    func testQuizStepScoring() {
        let questions = (0..<3).map { QuizQuestion(prompt: "Q\($0)", choices: ["a", "b"], answerIndex: 0, explanation: "") }
        let model = QuizStepModel(step: QuizStep(title: "T", questions: questions), instrument: .guitar, seed: 1)
        XCTAssertEqual(model.questions.count, 3)
        model.next()
        XCTAssertEqual(model.index, 0, "cannot skip an unanswered question")
        model.record(correct: true)
        model.record(correct: false)   // ignored: already answered
        model.next()
        model.record(correct: false)
        model.next()
        XCTAssertFalse(model.isFinished)
        model.record(correct: true)
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.correctCount, 2)
        XCTAssertEqual(model.score, 2.0 / 3, accuracy: 1e-9)
        model.restart()
        XCTAssertEqual(model.index, 0)
        XCTAssertTrue(model.answers.isEmpty)
    }

    func testGeneratedQuizIsRepeatableForSeed() {
        let step = QuizStep(title: "Notes", generator: QuizGeneratorSpec(kind: .noteOnKeyboard, params: ["range": "C4-B4"]), count: 4)
        let a = QuizStepModel(step: step, instrument: .piano, seed: 7)
        let b = QuizStepModel(step: step, instrument: .piano, seed: 7)
        XCTAssertEqual(a.questions, b.questions)
        XCTAssertEqual(a.questions.count, 4)
    }

    func testQuizQuestionAnswerOnce() {
        let q = QuizQuestion(prompt: "Name the marked note.", choices: ["F", "G", "A", "B"], answerIndex: 1, explanation: "G")
        let model = QuizQuestionModel(question: q, instrument: .guitar, listener: FakeTutorListener(), player: FakeSequencePlayer())
        var reported: [Bool] = []
        model.onAnswered = { reported.append($0) }
        model.answer(0)
        model.answer(1)
        XCTAssertEqual(reported, [false])
        XCTAssertFalse(model.isCorrect)
    }

    func testAnswerByPlayingNote() async {
        let q = QuizQuestion(prompt: "Name the highlighted key.", choices: ["F♯/G♭", "G", "A", "C"], answerIndex: 0,
                             explanation: "", playback: PlaybackSpec(notes: [["F#4"]]),
                             diagram: Diagram(kind: .keyboard, notes: ["F#4"], pitchRange: ["C4", "B4"]))
        let listener = FakeTutorListener()
        let model = QuizQuestionModel(question: q, instrument: .piano, listener: listener, player: FakeSequencePlayer())
        XCTAssertFalse(model.isEarQuestion)
        guard case .note = model.playedKind else { return XCTFail("expected note kind") }
        var reported: [Bool] = []
        model.onAnswered = { reported.append($0) }
        await model.startListening()
        XCTAssertTrue(model.isListening)
        listener.detect([66], confidence: 0.2)
        XCTAssertTrue(reported.isEmpty, "unsure detections do not answer")
        listener.detect([54])   // F#3: any octave counts
        XCTAssertEqual(reported, [true])
        XCTAssertFalse(listener.isListening)
    }

    func testQuizStopWhileMicrophoneStartsStaysStopped() async {
        let q = QuizQuestion(prompt: "Name the highlighted key.", choices: ["F♯/G♭", "G", "A", "C"], answerIndex: 0,
                             explanation: "", playback: PlaybackSpec(notes: [["F#4"]]),
                             diagram: Diagram(kind: .keyboard, notes: ["F#4"], pitchRange: ["C4", "B4"]))
        let listener = FakeTutorListener()
        listener.holdsStart = true
        let model = QuizQuestionModel(question: q, instrument: .piano, listener: listener, player: FakeSequencePlayer())
        let task = Task { await model.startListening() }
        await waitUntil { listener.isStarting }
        model.stopListening()
        listener.releaseStart()
        await task.value
        XCTAssertFalse(model.isListening)
        XCTAssertFalse(listener.isListening)

        listener.holdsStart = false
        await model.startListening()
        XCTAssertTrue(model.isListening)
        listener.simulateUnexpectedStop()
        XCTAssertFalse(model.isListening)
        XCTAssertEqual(model.heardText, TutorListeningCopy.stoppedUnexpectedly)
    }

    func testPlayedAnswerKinds() {
        let interval = QuizQuestion(prompt: "Listen: two notes, going up. Which interval is it?",
                                    choices: ["Major third", "Perfect fifth", "Minor third"], answerIndex: 1,
                                    explanation: "", playback: PlaybackSpec(notes: [["C4"], ["G4"]]))
        let kind = PlayedAnswerKind.infer(interval)
        XCTAssertEqual(kind?.choice(forNotes: [60, 67], chordPitches: []), 1)
        XCTAssertEqual(kind?.choice(forNotes: [62, 65], chordPitches: []), 2)
        XCTAssertNil(kind?.choice(forNotes: [60], chordPitches: []))

        let quality = QuizQuestion(prompt: "What quality is it?", choices: ["Major", "Minor"], answerIndex: 1, explanation: "",
                                   playback: PlaybackSpec(notes: [["A3", "C4", "E4"]]))
        let qk = PlayedAnswerKind.infer(quality)
        XCTAssertEqual(qk?.choice(forNotes: [], chordPitches: [57, 60, 64]), 1)
        XCTAssertEqual(qk?.choice(forNotes: [], chordPitches: [55, 59, 62]), 0)

        let fact = QuizQuestion(prompt: "How many half steps is a major third?", choices: ["3", "4", "7"], answerIndex: 1,
                                explanation: "")
        XCTAssertNil(PlayedAnswerKind.infer(fact))
        let chords = QuizQuestion(prompt: "In C major, which chord is IV?", choices: ["F", "G", "C", "D"], answerIndex: 0,
                                  explanation: "")
        XCTAssertNil(PlayedAnswerKind.infer(chords), "chord symbols are not note answers")
    }

    func testEarQuestionDetection() {
        let ear = QuizQuestion(prompt: "Listen: two notes together.", choices: ["a", "b"], answerIndex: 0, explanation: "",
                               playback: PlaybackSpec(notes: [["C4", "E4"]]))
        let model = QuizQuestionModel(question: ear, instrument: .piano, listener: FakeTutorListener(), player: FakeSequencePlayer())
        XCTAssertTrue(model.isEarQuestion)
        XCTAssertTrue(model.showsPlayButton)
    }

    // MARK: Diagram geometry

    func testFretboardGeometry() {
        let geo = FretboardGeometry(size: CGSize(width: 540, height: 200), stringCount: 6, firstCellFret: 1, cellCount: 4,
                                    showsNut: true)
        XCTAssertLessThan(geo.x(fret: 0), geo.boardLeft, "open strings sit left of the nut")
        XCTAssertEqual(geo.wireX(0), geo.boardLeft, accuracy: 1e-9)
        XCTAssertEqual(geo.x(fret: 3), geo.boardLeft + 2.5 * geo.cellWidth, accuracy: 1e-9)
        XCTAssertLessThan(geo.y(string: 0), geo.y(string: 5), "string 1 (high E) on top")
        XCTAssertEqual(geo.position(at: CGPoint(x: geo.x(fret: 2), y: geo.y(string: 4))), FretPosition(string: 4, fret: 2))
        XCTAssertEqual(geo.position(at: CGPoint(x: 2, y: geo.y(string: 5))), FretPosition(string: 5, fret: 0))
    }

    func testFretboardModelChordFingersAndMutes() {
        let diagram = Diagram(kind: .fretboard, chord: "C", notes: ["5:3", "4:2", "3:0", "2:1", "1:0"], labels: .fingers,
                              fretRange: [0, 4])
        let model = FretboardDiagramModel(diagram: diagram)
        XCTAssertEqual(model.fretWindow, 0...4)
        XCTAssertEqual(model.mutedStrings, [5], "low E is not played in C")
        let byNotation = Dictionary(uniqueKeysWithValues: model.dots.map { ($0.position.notation, $0) })
        XCTAssertEqual(byNotation["5:3"]?.label, "3")
        XCTAssertEqual(byNotation["4:2"]?.label, "2")
        XCTAssertEqual(byNotation["2:1"]?.label, "1")
        XCTAssertNil(byNotation["3:0"]?.label, "open strings carry no finger")
        XCTAssertEqual(byNotation["5:3"]?.midi, 48)
        XCTAssertEqual(byNotation["5:3"]?.isRoot, true)
        XCTAssertEqual(model.accessibilityLabel, "C chord: x32010")

        let em = FretboardDiagramModel(diagram: Diagram(kind: .fretboard, chord: "Em",
                                                        notes: ["6:0", "5:2", "4:2", "3:0", "2:0", "1:0"],
                                                        labels: .intervals, fretRange: [0, 4]))
        let labels = em.dots.sorted { $0.midi < $1.midi }.map { $0.label ?? "" }
        XCTAssertEqual(labels, ["R", "P5", "R", "m3", "P5", "R"])

        let barre = FretboardDiagramModel(diagram: Diagram(kind: .fretboard, chord: "G",
                                                           notes: ["6:3", "5:5", "4:5", "3:4", "2:3", "1:3"],
                                                           labels: .fingers, fretRange: [1, 6]))
        XCTAssertFalse(barre.showsNut)
        XCTAssertEqual(barre.firstCellFret, 1)
        XCTAssertNotNil(barre.fingering, "matches the E-form barre, not the open G")
    }

    func testFretboardScaleNamesUseScaleSpelling() {
        let model = FretboardDiagramModel(diagram: Diagram(kind: .fretboard, scale: "E major",
                                                           notes: ["6:0", "6:4"], labels: .noteNames, fretRange: [0, 12]))
        XCTAssertEqual(model.dots.map(\.label), ["E", "G♯"])
        let degrees = FretboardDiagramModel(diagram: Diagram(kind: .fretboard, scale: "A minor pentatonic",
                                                             notes: ["6:5", "6:8"], labels: .degrees, fretRange: [4, 9]))
        XCTAssertEqual(degrees.dots.map(\.label), ["1", "♭3"])
    }

    func testKeyboardGeometry() {
        let layout = KeyboardLayout(lowestMIDI: 60, highestMIDI: 71)
        let geo = KeyboardGeometry(layout: layout, size: CGSize(width: 700, height: 200))
        XCTAssertEqual(geo.whiteWidth, 100, accuracy: 1e-9)
        XCTAssertEqual(geo.rect(for: 60), CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(geo.rect(for: 64).minX, 200, accuracy: 1e-9)
        XCTAssertEqual(geo.rect(for: 61).midX, 100, accuracy: 1e-9, "C♯ sits on the C–D boundary")
        XCTAssertEqual(geo.rect(for: 61).height, 124, accuracy: 1e-9)
        XCTAssertEqual(geo.key(at: CGPoint(x: 100, y: 50)), 61)
        XCTAssertEqual(geo.key(at: CGPoint(x: 90, y: 180)), 60)
        XCTAssertEqual(geo.key(at: CGPoint(x: 650, y: 180)), 71)
    }

    func testKeyboardFingerNumbers() {
        let rh = KeyboardDiagramModel(diagram: Diagram(kind: .keyboard, notes: ["C4", "D4", "E4", "F4", "G4"], labels: .fingers,
                                                       pitchRange: ["C4", "C5"]))
        XCTAssertEqual(rh.marks.map(\.label), ["1", "2", "3", "4", "5"])
        let lh = KeyboardDiagramModel(diagram: Diagram(kind: .keyboard, notes: ["C3", "D3", "E3", "F3", "G3"], labels: .fingers,
                                                       pitchRange: ["C3", "C4"]))
        XCTAssertEqual(lh.marks.map(\.label), ["5", "4", "3", "2", "1"])
        let triad = KeyboardDiagramModel(diagram: Diagram(kind: .keyboard, chord: "Cm", notes: ["C4", "Eb4", "G4"], labels: .fingers))
        XCTAssertEqual(triad.marks.map(\.label), ["1", "3", "5"])
        let seventh = KeyboardDiagramModel(diagram: Diagram(kind: .keyboard, notes: ["C4", "E4", "G4", "B4"], labels: .fingers))
        XCTAssertEqual(seventh.marks.map(\.label), ["1", "2", "3", "5"])
        let fifth = KeyboardDiagramModel(diagram: Diagram(kind: .keyboard, notes: ["C3", "G3"], labels: .fingers, pitchRange: ["F2", "C4"]))
        XCTAssertEqual(fifth.marks.map(\.label), ["5", "1"])
        let both = KeyboardDiagramModel(diagram: Diagram(kind: .keyboard, notes: ["C3", "D3", "E3", "F3", "G3", "C4", "D4", "E4", "F4", "G4"],
                                                         labels: .fingers, pitchRange: ["C3", "C5"]))
        XCTAssertEqual(both.marks.map(\.label), ["5", "4", "3", "2", "1", "1", "2", "3", "4", "5"])
        let flatName = KeyboardDiagramModel(diagram: Diagram(kind: .keyboard, notes: ["Bb4"], pitchRange: ["F4", "F5"]))
        XCTAssertEqual(flatName.marks.first?.label, "B♭")
        XCTAssertEqual(flatName.layout.lowestMIDI, 65)
    }

    func testStaffPositions() {
        XCTAssertEqual(StaffDiagramModel.step(of: Pitch("E4")!, onTreble: true), 0)
        XCTAssertEqual(StaffDiagramModel.step(of: Pitch("F5")!, onTreble: true), 8)
        XCTAssertEqual(StaffDiagramModel.step(of: Pitch("C4")!, onTreble: true), -2)
        XCTAssertEqual(StaffDiagramModel.step(of: Pitch("G2")!, onTreble: false), 0)
        XCTAssertEqual(StaffDiagramModel.step(of: Pitch("C4")!, onTreble: false), 10)
        XCTAssertEqual(StaffDiagramModel.ledgerSteps(for: -2), [-2])
        XCTAssertEqual(StaffDiagramModel.ledgerSteps(for: -5), [-2, -4])
        XCTAssertEqual(StaffDiagramModel.ledgerSteps(for: 12), [10, 12])
        XCTAssertEqual(StaffDiagramModel.ledgerSteps(for: 9), [])

        let d = KeySignature(fifths: 2)
        XCTAssertEqual(StaffDiagramModel.signatureSteps(d, treble: true), [8, 5])   // F5, C5
        XCTAssertEqual(StaffDiagramModel.signatureSteps(d, treble: false), [6, 3])  // F3, C3
        XCTAssertEqual(StaffDiagramModel.signatureSteps(KeySignature(fifths: -1), treble: true), [4])   // B4

        let grand = StaffDiagramModel(diagram: Diagram(kind: .staff, notes: ["C3", "C4", "G4"], pitchRange: ["F2", "G5"]),
                                      instrument: .piano)
        XCTAssertEqual(grand.clef, .grand)
        XCTAssertEqual(grand.notes.map(\.onTreble), [false, true, true])
        let bass = StaffDiagramModel(diagram: Diagram(kind: .staff, notes: ["G2"], pitchRange: ["F2", "C4"]), instrument: .piano)
        XCTAssertEqual(bass.clef, .bass)
        let caption = StaffDiagramModel(diagram: Diagram(kind: .staff, notes: ["G4"], pitchRange: ["F2", "G5"], caption: "Treble clef"),
                                        instrument: .piano)
        XCTAssertEqual(caption.clef, .treble)
        let guitar = StaffDiagramModel(diagram: Diagram(kind: .staff, notes: ["E4"], pitchRange: ["C4", "A5"]), instrument: .guitar)
        XCTAssertEqual(guitar.clef, .treble)
        XCTAssertEqual(guitar.notes.first.map { guitar.soundingMIDI($0) }, 52, "guitar sounds an octave below the page")

        let keyed = StaffDiagramModel(diagram: Diagram(kind: .staff, notes: ["F#4", "F4", "C#5"], key: "D major"), instrument: .piano)
        XCTAssertEqual(keyed.notes.map(\.accidental), [nil, "♮", nil])
    }

    func testCircleAndRhythmModels() {
        let g = CircleOfFifthsModel(diagram: Diagram(kind: .circleOfFifths, key: "G major"))
        XCTAssertEqual(g.highlighted, 1)
        XCTAssertFalse(g.highlightMinor)
        XCTAssertTrue(g.isNeighbour(0) && g.isNeighbour(2))
        let em = CircleOfFifthsModel(diagram: Diagram(kind: .circleOfFifths, key: "E minor"))
        XCTAssertEqual(em.highlighted, 1)
        XCTAssertTrue(em.highlightMinor)
        XCTAssertEqual(CircleOfFifthsModel(diagram: Diagram(kind: .circleOfFifths, key: "F major")).highlighted, 11)

        let r = RhythmStripModel(rhythm: "q q e e q", caption: nil)
        XCTAssertEqual(r.items.map(\.count), ["1", "2", "3", "&", "4"])
        XCTAssertEqual(r.beatsPerMeasure, 4)
        let waltz = RhythmStripModel(rhythm: "h q h q", caption: "Two measures")
        XCTAssertEqual(waltz.beatsPerMeasure, 3)
        XCTAssertEqual(waltz.barLineBeats, [3])

        let ladder = IntervalLadderModel(diagram: Diagram(kind: .intervalLadder, scale: "C major"), instrument: .piano)
        XCTAssertEqual(ladder.rungs.map(\.shortName), ["R", "M2", "M3", "P4", "P5", "M6", "M7", "P8"])
        XCTAssertEqual(ladder.rungs.last?.semitones, 12)
    }

    func testForEventDiagram() {
        let d = Diagram.forEvent(pitches: [48], fretting: [FretPosition(guitarString: 5, fret: 3)], chordName: nil,
                                 instrument: .guitar)
        XCTAssertEqual(d?.notes, ["5:3"])
        XCTAssertEqual(d.map { $0.soundingMIDI(instrument: .guitar) }, [48])
        let chord = Diagram.forEvent(pitches: [40, 47, 52, 55, 59, 64], fretting: nil, chordName: "Em", instrument: .guitar)
        XCTAssertEqual(chord.map { FretboardDiagramModel(diagram: $0).dots.count }, 6)
        let piano = Diagram.forEvent(pitches: [60, 64, 67], fretting: nil, chordName: "C", instrument: .piano)
        XCTAssertEqual(piano?.kind, .keyboard)
        XCTAssertEqual(piano.map { $0.soundingMIDI(instrument: .piano) }, [60, 64, 67])
    }

    // MARK: Text

    func testMarkdownBlocks() {
        let text = "Intro **bold**.\n\n- one\n- two\n\n| Chord | Root |\n|---|---|\n| E | E |\n\n1. first\n2. second"
        let blocks = MarkdownBlock.parse(text)
        XCTAssertEqual(blocks, [
            .paragraph("Intro **bold**."),
            .bullets(["one", "two"]),
            .table(header: ["Chord", "Root"], rows: [["E", "E"]]),
            .numbered(["first", "second"]),
        ])
    }

    func testBundledLessonsBuildEveryStep() throws {
        // Every practice/song/quiz step in the bundled curriculum prepares without errors.
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TabBuddy/Tutor/Content")
        let content = CurriculumLoader.load(directory: directory)
        XCTAssertNotNil(content.course(.guitar))
        var failures: [String] = []
        for instrument in TutorInstrument.allCases {
            guard let course = content.course(instrument) else { continue }
            for location in course.allLessonLocations {
                for (i, step) in location.lesson.steps.enumerated() {
                    switch step {
                    case .practice(let s):
                        let model = PracticeRunModel(step: s, instrument: instrument,
                                                     intervals: ExerciseGenerator.intervals(forLesson: location.lesson),
                                                     listener: FakeTutorListener(), player: FakeSequencePlayer())
                        if let e = model.generationError { failures.append("\(location.lesson.id)#\(i): \(e)") }
                    case .song(let s):
                        let model = SongStepModel(song: s, instrument: instrument, listener: FakeTutorListener(),
                                                  player: FakeSequencePlayer())
                        if let e = model.error { failures.append("\(location.lesson.id)#\(i): \(e)") }
                    case .quiz(let s):
                        let model = QuizStepModel(step: s, instrument: instrument, seed: 3)
                        if let e = model.generationError { failures.append("\(location.lesson.id)#\(i): \(e)") }
                    default: break
                    }
                }
            }
        }
        XCTAssertEqual(failures, [])
    }
}
