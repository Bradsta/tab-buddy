//
//  LessonUITests.swift
//  TabBuddyTests
//
//  Lesson page logic with fake audio seams: chapter sections and the done
//  toggle, the Try it model (playback, loop, tempo, listening per pacing,
//  play-along), Check yourself flashcards, song boxes, and diagram geometry.
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

    private func makeTryIt(_ spec: ExerciseSpec, instrument: TutorInstrument = .guitar, tips: [String] = [],
                           intervals: [Interval]? = nil) -> (TryItModel, FakeTutorListener, FakeSequencePlayer) {
        let listener = FakeTutorListener()
        let player = FakeSequencePlayer()
        player.listenerToCheck = listener
        let model = TryItModel(step: practice(spec, tips: tips), instrument: instrument, intervals: intervals,
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
            .quiz(QuizStep(title: "Quick check", questions: [QuizQuestion(prompt: "Q?", choices: ["a", "b"], answerIndex: 0,
                                                                          explanation: "a")])),
            .practice(PracticeStep(exercise: ExerciseSpec(kind: .playNote, prompt: "Play E", notes: ["E2"]))),
            .demo(DemoStep(title: "Hear E", caption: "Low E.", playback: PlaybackSpec(notes: [["E2"]]))),
        ], reviewItems: [ReviewItemSeed(id: "test.r1", kind: .fact, prompt: "p", answer: "a")])
    }

    // MARK: Chapter page

    func testSectionsKeepOrderWithCheckYourselfLast() {
        let sections = LessonPageModel.sections(for: sampleLesson())
        XCTAssertEqual(sections.map(\.kind), [.explain, .practice, .demo, .quiz])
        XCTAssertEqual(sections.map(\.stepIndex), [0, 2, 3, 1])
        XCTAssertEqual(sections.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(sections.map(\.title), ["Read", "Play E", "Hear E", "Quick check"])
        XCTAssertEqual(sections[3].kind.label, "Check yourself")
        XCTAssertEqual(sections.map(\.number), [1, 2, 3, 4])
    }

    func testDoneToggleWritesReadStateWithoutAttemptsOrCards() throws {
        let store = try TutorStore.inMemory()
        let lesson = sampleLesson()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = LessonPageModel(lesson: lesson, instrument: .guitar, store: store, now: { now })
        XCTAssertFalse(model.isDone)
        XCTAssertTrue(model.hasCheckYourself)
        XCTAssertTrue(model.usesMicrophone)
        XCTAssertEqual(model.section(forStep: 1)?.index, 3)

        model.toggleDone()
        XCTAssertTrue(model.isDone)
        let record = try XCTUnwrap(store.progress(lessonID: lesson.id, instrument: .guitar))
        XCTAssertEqual(record.progressStatus, .completed)
        XCTAssertEqual(record.attempts, 0, "done means read: no attempt is recorded")
        XCTAssertEqual(record.bestScore, 0)
        XCTAssertEqual(record.completedAt, now)
        XCTAssertNil(store.reviewCard(itemID: "test.r1", instrument: .guitar), "no review cards are seeded")

        model.toggleDone()
        XCTAssertFalse(model.isDone)
        XCTAssertEqual(store.progress(lessonID: lesson.id, instrument: .guitar)?.progressStatus, .notStarted)

        // A new page for a done lesson opens done.
        model.setDone(true)
        XCTAssertTrue(LessonPageModel(lesson: lesson, instrument: .guitar, store: store).isDone)
    }

    func testSeedIsStablePerSectionWithinAPageView() {
        let a = LessonPageModel(lesson: sampleLesson(), instrument: .guitar, salt: 9)
        let b = LessonPageModel(lesson: sampleLesson(), instrument: .guitar, salt: 9)
        XCTAssertEqual(a.seed(for: a.sections[3]), b.seed(for: b.sections[3]))
        XCTAssertNotEqual(a.seed(for: a.sections[1]), a.seed(for: a.sections[3]))
    }

    // MARK: Try it — playback

    func testPlayExampleUsesCurrentTempoAndLoops() {
        let (model, _, player) = makeTryIt(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2", "A2"], tempoSteps: [60, 72]))
        XCTAssertEqual(model.bpm, 60, "seeded from the tempo ladder")
        XCTAssertEqual(model.tempoSteps, [60, 72])
        XCTAssertFalse(model.supportsPlayAlong, "free-time passages wait; they do not play along")
        model.setTempo(90)
        model.loop = true
        model.playExample()
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(player.played.last?.bpm, 90)
        XCTAssertEqual(player.played.last?.notes.map(\.pitches), [[40], [45]])
        player.finish()
        XCTAssertEqual(player.played.count, 2, "loop plays the example again")
        XCTAssertTrue(model.isPlaying)
        model.stopPlayback()
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.playbackIndex)
    }

    func testTempoIsClampedAndNudged() {
        let (model, _, _) = makeTryIt(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2"]))
        model.setTempo(1000)
        XCTAssertEqual(model.bpm, TryItModel.tempoRange.upperBound)
        model.setTempo(5)
        XCTAssertEqual(model.bpm, TryItModel.tempoRange.lowerBound)
        model.setTempo(80)
        model.nudgeTempo(4)
        XCTAssertEqual(model.bpm, 84)
    }

    func testChordChangesShowTheCycleNotTheGradingList() {
        let (model, _, _) = makeTryIt(ExerciseSpec(kind: .chordChanges, prompt: "G to D", chords: ["G", "D"], durationSec: 60))
        XCTAssertEqual(model.pacing, .countChanges)
        XCTAssertEqual(model.events.map(\.chordName), ["G", "D", "G", "D"])
        XCTAssertGreaterThan(model.passage?.events.count ?? 0, 4, "generator still pads for its own purposes")
        XCTAssertEqual(model.exampleSequence?.notes.count, 4)
    }

    func testExamplesForHuntImproviseAndEcho() {
        let (hunt, _, _) = makeTryIt(ExerciseSpec(kind: .findAllNotes, prompt: "Find C", durationSec: 30, pitchClass: "C"))
        XCTAssertEqual(hunt.exampleSequence?.notes.map(\.pitches), [[48], [60], [72]])
        XCTAssertNotNil(hunt.diagram)

        let (free, _, _) = makeTryIt(ExerciseSpec(kind: .improvise, prompt: "Improvise", scale: "A minor pentatonic", durationSec: 10))
        XCTAssertEqual(free.exampleSequence?.notes.count, 11, "pentatonic one octave up and down")
        XCTAssertEqual(free.diagram?.scale, "A minor pentatonic")

        let (echo, _, player) = makeTryIt(ExerciseSpec(kind: .intervalPlayback, prompt: "Echo", notes: ["C4", "G4"], repetitions: 2),
                                          instrument: .piano)
        XCTAssertTrue(echo.hasReference)
        XCTAssertEqual(echo.roundCount, 2)
        XCTAssertEqual(echo.round?.label, "perfect fifth")
        echo.setTempo(100)
        echo.playExample()
        XCTAssertEqual(player.played.last?.bpm, 100)
        XCTAssertEqual(player.played.last?.notes.map(\.pitches), [[60], [67]])
        echo.selectRound(1)
        XCTAssertEqual(echo.roundIndex, 1)
        XCTAssertFalse(echo.isPlaying, "changing phrase stops playback")
    }

    // MARK: Try it — listening (wait)

    func testListenMarksHeardInOrderAndWrapsAround() async {
        let (model, listener, _) = makeTryIt(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2", "A2", "D3"]))
        await model.startListening()
        XCTAssertEqual(model.listenState, .listening)
        XCTAssertEqual(listener.armed.last?.count, 3)

        listener.verify(0, .hit)
        XCTAssertEqual(model.heard, [0])
        XCTAssertEqual(model.cursor, 1)
        XCTAssertEqual(listener.armed.last?.count, 2, "re-armed with the remaining events")
        XCTAssertEqual(model.statusTone, .good)

        listener.verify(1, .wrongPitch, unexpected: [46])
        XCTAssertEqual(model.cursor, 1)
        XCTAssertFalse(model.heard.contains(1))
        XCTAssertEqual(model.statusTone, .neutral, "misses are never shown as errors")
        XCTAssertEqual(model.statusText, "Heard A♯2")

        listener.verify(1, .uncertain)
        XCTAssertEqual(model.statusTone, .neutral)
        listener.verify(2, .hit)   // not the current target
        XCTAssertEqual(model.cursor, 1)
        listener.verify(1, .hit)
        listener.verify(2, .hit)
        XCTAssertEqual(model.cursor, 0, "wraps around to keep going")
        XCTAssertTrue(model.heard.isEmpty)
        XCTAssertEqual(model.listenState, .listening, "no run end, listening continues")
        XCTAssertTrue(listener.isListening)

        model.stopListening()
        XCTAssertEqual(model.listenState, .off)
        XCTAssertFalse(listener.isListening)
    }

    func testSkipAndClearWhileListening() async {
        let (model, listener, _) = makeTryIt(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2", "A2"]))
        await model.startListening()
        model.skipCurrent()
        XCTAssertEqual(model.cursor, 1)
        XCTAssertTrue(model.heard.isEmpty, "a skipped target is neutral, not red")
        listener.verify(1, .hit)
        XCTAssertEqual(model.cursor, 0)
        listener.verify(0, .hit)
        XCTAssertEqual(model.heard, [0])
        model.resetMarks()
        XCTAssertTrue(model.heard.isEmpty)
        XCTAssertEqual(model.cursor, 0)
        XCTAssertEqual(listener.armed.last?.count, 2)
    }

    func testPlaybackPausesListeningThenResumes() async {
        let (model, listener, player) = makeTryIt(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2", "A2"]))
        await model.startListening()
        model.playExample()
        XCTAssertFalse(listener.isListening, "output is muted while listening, so the microphone pauses")
        XCTAssertEqual(model.listenState, .off)
        XCTAssertFalse(player.playedWhileListening)
        player.finish()
        await waitUntil { model.listenState == .listening }
        XCTAssertTrue(listener.isListening)

        // Turning Listen on while a loop plays stops the loop.
        model.stopListening()
        model.loop = true
        model.playExample()
        await model.startListening()
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.loop)
        XCTAssertEqual(model.listenState, .listening)
    }

    func testPermissionDeniedAndUnexpectedStop() async {
        let (model, listener, _) = makeTryIt(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2"]))
        listener.startError = TutorAudioError.permissionDenied
        await model.startListening()
        XCTAssertEqual(model.listenState, .permissionDenied)
        XCTAssertNotNil(model.exampleSequence, "the card still plays with the microphone off")

        listener.startError = nil
        await model.startListening()
        XCTAssertEqual(model.listenState, .listening)
        listener.simulateUnexpectedStop()
        XCTAssertEqual(model.listenState, .off)
        XCTAssertEqual(model.statusText, TutorListeningCopy.stoppedUnexpectedly)
        XCTAssertEqual(model.statusTone, .neutral)
    }

    func testStopWhileMicrophoneStartsStaysOff() async {
        let (model, listener, _) = makeTryIt(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2"]))
        listener.holdsStart = true
        let task = Task { await model.startListening() }
        await waitUntil { listener.isStarting }
        XCTAssertEqual(model.listenState, .starting)
        model.stopListening()
        listener.releaseStart()
        await task.value
        XCTAssertEqual(model.listenState, .off)
        XCTAssertFalse(listener.isListening)
    }

    func testFindAllNotesAndImproviseOnlyAddGreen() async {
        let (hunt, listener, _) = makeTryIt(ExerciseSpec(kind: .findAllNotes, prompt: "Find C", durationSec: 30, pitchClass: "C"))
        await hunt.startListening()
        XCTAssertEqual(listener.detectionSources, .monophonic)
        listener.detect([60])
        listener.detect([61])
        listener.detect([72], confidence: 0.1)
        XCTAssertEqual(hunt.found, [60])
        XCTAssertEqual(hunt.statusTone, .neutral)
        listener.detect([48])
        XCTAssertEqual(hunt.found, [60, 48])
        XCTAssertEqual(hunt.statusTone, .good)
        XCTAssertEqual(hunt.listenState, .listening, "no timer ends the hunt")

        let (free, freeListener, _) = makeTryIt(ExerciseSpec(kind: .improvise, prompt: "Improvise", scale: "A minor pentatonic", durationSec: 10))
        await free.startListening()
        freeListener.detect([57])
        XCTAssertEqual(free.statusText, "A3")
        XCTAssertEqual(free.statusTone, .good)
        freeListener.detect([61])
        XCTAssertEqual(free.statusText, "C♯4 (outside the scale)")
        XCTAssertEqual(free.statusTone, .neutral)
    }

    // MARK: Try it — play-along

    func testPlayAlongCountsInMovesCursorAndEndsWithoutAScore() async {
        let (model, listener, _) = makeTryIt(ExerciseSpec(kind: .playSequence, prompt: "Play", notes: ["C4", "D4", "E4", "F4"], bpm: 60),
                                             instrument: .piano)
        XCTAssertEqual(model.pacing, .timed)
        XCTAssertEqual(model.listenMode, .playAlong, "timed passages default to play-along")
        XCTAssertTrue(model.supportsPlayAlong)
        listener.takeClock = 1
        await model.startListening()
        XCTAssertEqual(model.countIn?.of, 4)
        let start = try! XCTUnwrap(listener.timedStart)
        XCTAssertEqual(start, 1 + 0.4 + 4, accuracy: 1e-9)

        listener.takeClock = start - 2.5
        model.tick()
        XCTAssertEqual(model.countIn?.beat, 2)
        listener.takeClock = start + 1.2
        model.tick()
        XCTAssertNil(model.countIn)
        XCTAssertEqual(model.cursor, 1)

        for e in model.events { listener.verify(e.id, .hit, heard: e.pitches) }
        XCTAssertEqual(model.heard, Set(model.events.map(\.id)))
        listener.takeClock = start + model.totalBeats + 1.1
        model.tick()
        XCTAssertEqual(model.listenState, .off, "the run ends after the passage")
        XCTAssertFalse(listener.isListening)
        XCTAssertEqual(model.statusText, "Played through. Tap Listen to go again.")
        XCTAssertEqual(model.heard.count, 4, "green marks stay visible")

        // Loop restarts the count-in instead of stopping.
        model.loop = true
        await model.startListening()
        let second = try! XCTUnwrap(listener.timedStart)
        listener.takeClock = second + model.totalBeats + 1.1
        model.tick()
        XCTAssertEqual(model.listenState, .listening)
        XCTAssertNotNil(model.countIn)
        XCTAssertTrue(model.heard.isEmpty)
        model.stopListening()

        // Switching to wait mode arms in wait mode.
        model.setListenMode(.wait)
        await model.startListening()
        XCTAssertNil(model.countIn)
        XCTAssertEqual(listener.armed.last?.count, 4)
    }

    func testGenerationErrorIsReported() {
        let (model, _, _) = makeTryIt(ExerciseSpec(kind: .playNote, prompt: "Play"))
        XCTAssertNil(model.exercise)
        XCTAssertNotNil(model.generationError)
        XCTAssertFalse(model.supportsListening)
        XCTAssertNil(model.exampleSequence)
    }

    func testTipsAreStatic() {
        let (model, _, _) = makeTryIt(ExerciseSpec(kind: .playNote, prompt: "Play", notes: ["E2"]), tips: ["Press behind the fret."])
        XCTAssertEqual(model.tips, ["Press behind the fret."])
    }

    // MARK: Songs

    func testSongBoxBuildsTimedPassageWithPlayAlong() {
        let song = SongStep(title: "Ode", caption: "Slow.", notes: [["E4"], ["E4"], ["F4"], ["G4"]], rhythm: "q q q q", bpm: 80)
        let model = SongCardBuilder.model(for: song, instrument: .guitar, listener: FakeTutorListener(), player: FakeSequencePlayer())
        XCTAssertNil(model.generationError)
        XCTAssertEqual(model.pacing, .timed)
        XCTAssertEqual(model.bpm, 80)
        XCTAssertEqual(model.events.count, 4)
        XCTAssertTrue(model.supportsPlayAlong)
        XCTAssertEqual(model.prompt, "Slow.")
        let broken = SongCardBuilder.exercise(for: SongStep(title: "X", rhythm: "q", bpm: 80), instrument: .guitar)
        XCTAssertNil(broken.0)
        XCTAssertNotNil(broken.1)
    }

    // MARK: Check yourself

    func testCheckYourselfRevealsWithoutScoring() {
        let questions = (0..<3).map { QuizQuestion(prompt: "Q\($0)", choices: ["a", "b"], answerIndex: 0, explanation: "") }
        let model = CheckYourselfModel(step: QuizStep(title: "T", questions: questions), instrument: .guitar, seed: 1)
        XCTAssertEqual(model.questions.count, 3)
        XCTAssertFalse(model.hasGenerator)
        XCTAssertFalse(model.isRevealed(0))
        model.reveal(0, choice: 1)
        XCTAssertTrue(model.isRevealed(0))
        XCTAssertEqual(model.choice(for: 0), 1)
        model.reveal(0, choice: 0)
        XCTAssertEqual(model.choice(for: 0), 1, "first reveal stands")
        model.reveal(2)
        XCTAssertTrue(model.isRevealed(2))
        XCTAssertNil(model.choice(for: 2))
        XCTAssertFalse(model.isRevealed(1), "questions are independent")
        model.hideAll()
        XCTAssertFalse(model.isRevealed(0))
    }

    func testGeneratedSetIsRepeatableAndNewSetChanges() {
        let fixed = [QuizQuestion(prompt: "Fixed", choices: ["a", "b"], answerIndex: 0, explanation: "")]
        let step = QuizStep(title: "Notes", questions: fixed,
                            generator: QuizGeneratorSpec(kind: .noteOnKeyboard, params: ["range": "C4-B4"]), count: 4)
        let a = CheckYourselfModel(step: step, instrument: .piano, seed: 7)
        let b = CheckYourselfModel(step: step, instrument: .piano, seed: 7)
        XCTAssertEqual(a.questions, b.questions)
        XCTAssertEqual(a.questions.count, 5)
        XCTAssertEqual(a.questions.first?.prompt, "Fixed")
        a.reveal(1)
        a.newSet()
        XCTAssertEqual(a.setNumber, 1)
        XCTAssertFalse(a.isRevealed(1))
        XCTAssertEqual(a.questions.first, fixed[0], "fixed questions stay")
        XCTAssertNotEqual(Array(a.questions.dropFirst()), Array(b.questions.dropFirst()), "a new set draws new questions")
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
        // Every Try it box, song, and Check yourself section in the bundled curriculum prepares without errors.
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TabBuddy/Tutor/Content")
        let content = CurriculumLoader.load(directory: directory)
        XCTAssertNotNil(content.course(.guitar))
        var failures: [String] = []
        for instrument in TutorInstrument.allCases {
            guard let course = content.course(instrument) else { continue }
            for location in course.allLessonLocations {
                let page = LessonPageModel(lesson: location.lesson, instrument: instrument, salt: 3)
                XCTAssertEqual(page.sections.count, location.lesson.steps.count)
                for section in page.sections {
                    switch section.step {
                    case .practice(let s):
                        let model = TryItModel(step: s, instrument: instrument,
                                               intervals: ExerciseGenerator.intervals(forLesson: location.lesson),
                                               listener: FakeTutorListener(), player: FakeSequencePlayer())
                        if let e = model.generationError { failures.append("\(location.lesson.id)#\(section.stepIndex): \(e)") }
                        if model.exampleSequence == nil { failures.append("\(location.lesson.id)#\(section.stepIndex): no example") }
                    case .song(let s):
                        let (_, error) = SongCardBuilder.exercise(for: s, instrument: instrument)
                        if let error { failures.append("\(location.lesson.id)#\(section.stepIndex): \(error)") }
                    case .quiz(let s):
                        let model = CheckYourselfModel(step: s, instrument: instrument, seed: 3)
                        if let e = model.generationError { failures.append("\(location.lesson.id)#\(section.stepIndex): \(e)") }
                        if model.questions.isEmpty { failures.append("\(location.lesson.id)#\(section.stepIndex): no questions") }
                    default: break
                    }
                }
            }
        }
        XCTAssertEqual(failures, [])
    }
}
