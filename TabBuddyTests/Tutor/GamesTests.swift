//
//  GamesTests.swift
//  TabBuddyTests
//
//  WP-G games: every game model's state machine and scoring with fake audio
//  and a hand-driven clock (hits, misses, uncertain results, timer expiry,
//  personal bests in an in-memory TutorStore), plus validity of generated
//  rounds (intervals, qualities, rhythms, scales, notes, chords).
//

import XCTest
@testable import TabBuddy

// MARK: - Fakes

@MainActor
private final class GameFakeListener: TutorListening {
    var isListening = false
    var permissionDenied = false
    var inputLevel: Float = 0.3
    var takeClock: TimeInterval = 0
    var onVerification: ((VerificationResult) -> Void)?
    var onDetected: ((DetectedEvent) -> Void)?
    var detectionSources: TutorListener.DetectionSources = .all
    var startError: Error?
    private(set) var startCount = 0
    private(set) var armed: [(events: [ExpectedEvent], window: ExpectedNoteVerifier.Window)] = []

    func start(profile: InstrumentProfile, recordTake: Bool) async throws {
        startCount += 1
        if let startError {
            if case TutorAudioError.permissionDenied = startError { permissionDenied = true }
            throw startError
        }
        isListening = true
    }

    @discardableResult func stop() -> URL? {
        isListening = false
        return nil
    }

    func arm(_ events: [ExpectedEvent], window: ExpectedNoteVerifier.Window) { armed.append((events, window)) }

    func armTimed(_ passage: ExpectedPassage, passageStart: TimeInterval, tempoScale: Double, tolerance: TimeInterval) {
        armed.append((passage.events, .timed(times: passage.events.map { passageStart + passage.time(ofBeat: $0.beat) },
                                             tolerance: tolerance)))
    }

    func disarm() {}

    var lastArmed: ExpectedEvent? { armed.last?.events.first }

    func verify(_ id: Int, _ grade: EventGrade, unexpected: [Int] = []) {
        onVerification?(VerificationResult(expectedID: id, grade: grade, heard: [], unexpected: unexpected,
                                           onsetTime: takeClock, confidence: grade == .uncertain ? 0.2 : 0.9))
    }

    func detect(_ pitch: Int, confidence: Double = 0.9, at time: TimeInterval? = nil) {
        onDetected?(DetectedEvent(time: time ?? takeClock, pitches: [pitch], confidences: [confidence], source: .monophonic))
    }
}

@MainActor
private final class GameFakePlayer: TutorSequencePlaying {
    var isPlaying = false
    private(set) var played: [PlaybackSequence] = []
    private var completion: (() -> Void)?
    weak var listener: GameFakeListener?
    private(set) var playedWhileListening = false

    @discardableResult
    func play(_ sequence: PlaybackSequence, instrument: TutorInstrument, onStep: ((Int) -> Void)?,
              completion: (() -> Void)?) -> Bool {
        if listener?.isListening == true { playedWhileListening = true }
        played.append(sequence)
        isPlaying = true
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

@MainActor
private final class FakeGameClock: GameClock {
    var now: TimeInterval = 1000
}

// MARK: - Tests

@MainActor
final class GamesTests: XCTestCase {

    private var listener: GameFakeListener!
    private var player: GameFakePlayer!
    private var clock: FakeGameClock!
    private var store: TutorStore!
    private var scores: TutorStoreGameScores!

    override func setUp() async throws {
        listener = GameFakeListener()
        player = GameFakePlayer()
        player.listener = listener
        clock = FakeGameClock()
        store = try TutorStore.inMemory()
        scores = TutorStoreGameScores(store: store)
    }

    private var deps: GameDependencies {
        GameDependencies(listener: listener, player: player, clock: clock, scores: scores)
    }

    /// Moves both time bases (wall clock and take clock) and ticks.
    private func advance(_ model: GameModel, _ seconds: TimeInterval, steps: Int = 1) {
        for _ in 0..<steps {
            clock.now += seconds / Double(steps)
            listener.takeClock += seconds / Double(steps)
            model.tick()
        }
    }

    /// Ticks in 0.1 s steps until the rhythm measure has been scored.
    private func runUntilReview(_ model: RhythmTapperModel, limit: Int = 200) {
        var n = 0
        while model.roundState != .review && model.phase == .playing && n < limit {
            advance(model, 0.1)
            n += 1
        }
        XCTAssertEqual(model.roundState, .review)
    }

    private func startAndPlay(_ model: GameModel) async {
        model.autoTick = false
        await model.start()
        advance(model, model.countdownSeconds + 0.01)
        XCTAssertEqual(model.phase, .playing)
    }

    // MARK: Content validity

    func testHuntTargetsCoverEveryOctaveInRange() {
        XCTAssertEqual(GameContent.huntTargets(PitchClass(0), instrument: .guitar), [48, 60, 72])
        XCTAssertEqual(GameContent.huntTargets(PitchClass(4), instrument: .guitar), [40, 52, 64, 76])
        XCTAssertEqual(GameContent.huntTargets(PitchClass(0), instrument: .piano), [36, 48, 60, 72, 84, 96])
        for pc in PitchClass.all {
            for instrument in TutorInstrument.allCases {
                let targets = GameContent.huntTargets(pc, instrument: instrument)
                XCTAssertGreaterThanOrEqual(targets.count, 2)
                XCTAssertTrue(targets.allSatisfy { GameContent.huntRange(instrument).contains($0) && PitchClass($0) == pc })
            }
            // Every guitar target is reachable on frets 0–12.
            for midi in GameContent.huntTargets(pc, instrument: .guitar) {
                XCTAssertFalse(GameContent.guitarPositions(midi).isEmpty, "no position for \(midi)")
                XCTAssertTrue(GameContent.guitarPositions(midi).allSatisfy { $0.fret <= 12 })
            }
        }
        XCTAssertEqual(GameContent.huntPitchClasses(level: 1).count, 7)
        XCTAssertTrue(GameContent.huntPitchClasses(level: 1).allSatisfy { !$0.isBlackKey })
        XCTAssertEqual(GameContent.huntPitchClasses(level: 2).count, 12)
    }

    func testIntervalRoundsAreValidForEveryLevel() {
        for instrument in TutorInstrument.allCases {
            for level in 1...3 {
                let pool = GameContent.intervalPool(level: level)
                let rounds = GameContent.intervalRounds(level: level, instrument: instrument, count: 10, seed: UInt64(level))
                XCTAssertEqual(rounds.count, 10)
                for r in rounds {
                    let root = try! XCTUnwrap(r.root), target = try! XCTUnwrap(r.target)
                    XCTAssertTrue(GameContent.intervalRange(instrument).contains(root))
                    XCTAssertTrue(GameContent.intervalRange(instrument).contains(target))
                    let interval = pool.first { QuizGenerator.intervalLabel($0) == r.correctAnswer }
                    XCTAssertEqual(interval?.semitones, target - root, "\(r.correctAnswer)")
                    XCTAssertLessThanOrEqual(r.choices.count, 4)
                    XCTAssertEqual(Set(r.choices).count, r.choices.count)
                    XCTAssertTrue(r.choices.allSatisfy { c in pool.contains { QuizGenerator.intervalLabel($0) == c } })
                    XCTAssertFalse(r.sequence.soundedNotes.isEmpty)
                    XCTAssertTrue(r.sequence.allPitches.allSatisfy { [root, target].contains($0) })
                }
            }
        }
        // Same seed, same rounds.
        XCTAssertEqual(GameContent.intervalRounds(level: 2, instrument: .guitar, seed: 9),
                       GameContent.intervalRounds(level: 2, instrument: .guitar, seed: 9))
    }

    func testQualityRoundsSoundTheNamedChord() {
        for instrument in TutorInstrument.allCases {
            for level in 1...3 {
                let pool = GameContent.qualityPool(level: level)
                for r in GameContent.qualityRounds(level: level, instrument: instrument, count: 10, seed: 3) {
                    XCTAssertEqual(r.choices, pool.map(QuizGenerator.qualityLabel))
                    let quality = pool[r.correctIndex]
                    let block = try! XCTUnwrap(r.sequence.notes.first?.pitches)
                    let intervals = Set(block.map { ($0 - block.min()!) % 12 })
                    // The chord's pitch classes match the quality above some root in the voicing.
                    let expected = Set(quality.intervals.map { $0.semitones % 12 })
                    let matches = PitchClass.all.contains { root in
                        Set(block.map { PitchClass($0).value }) == Set(expected.map { (root.value + $0) % 12 })
                    }
                    XCTAssertTrue(matches, "\(quality) voiced as \(block) (\(intervals))")
                    XCTAssertTrue(block.allSatisfy { InstrumentContext.standard(instrument).playableRange.contains($0) })
                }
            }
        }
        XCTAssertEqual(GameContent.qualityPool(level: 3).last, .dominantSeventh)
    }

    func testRhythmPatternsParseAndFillOneMeasure() {
        for (i, level) in GameContent.rhythmPatterns.enumerated() {
            XCTAssertGreaterThanOrEqual(level.count, 4)
            for text in level {
                let pattern = try! XCTUnwrap(RhythmPattern(text), text)
                XCTAssertEqual(pattern.totalBeats, 4, accuracy: 1e-9, text)
                XCTAssertGreaterThanOrEqual(pattern.noteCount, 2, text)
                // Level 1 has no eighths; level 2+ does.
                if i == 0 { XCTAssertTrue(pattern.events.allSatisfy { $0.value.base != .eighth }, text) }
                // Matching windows are at least 80 ms.
                XCTAssertGreaterThanOrEqual(RhythmScoring.window(onsetBeats: pattern.onsetBeats,
                                                                 bpm: GameContent.rhythmBPM(level: i + 1)), 0.08)
            }
        }
        let rounds = GameContent.rhythmRounds(level: 2, count: 4, seed: 1)
        XCTAssertEqual(rounds.count, 4)
        XCTAssertEqual(Set(rounds).count, 4)
    }

    func testScaleRunsGoUpAndDownInRange() {
        for instrument in TutorInstrument.allCases {
            for option in GameContent.scaleOptions(instrument) {
                let run = GameContent.scaleRun(option, instrument: instrument)
                let ascending = option.scale.pitchClasses.count * option.octaves + 1
                XCTAssertEqual(run.count, ascending * 2 - 1, option.detail)
                XCTAssertEqual(run.first, run.last)
                XCTAssertEqual(run, run.reversed())
                XCTAssertEqual(PitchClass(run[0]), option.scale.root.pitchClass)
                XCTAssertTrue(run.allSatisfy { option.scale.contains(midi: $0) })
                XCTAssertTrue(run.allSatisfy { InstrumentContext.standard(instrument).playableRange.contains($0) })
                let passage = GameContent.scalePassage(run, bpm: 60, instrument: instrument, idBase: 2000)
                XCTAssertEqual(passage.events.map(\.id), Array(2000..<(2000 + run.count)))
                XCTAssertEqual(passage.events.map(\.beat), (0..<run.count).map(Double.init))
                if instrument == .guitar { XCTAssertTrue(passage.events.allSatisfy { $0.fretting?.count == 1 }) }
            }
        }
    }

    func testChordOptionsAndRushNotesAreValid() {
        for instrument in TutorInstrument.allCases {
            for symbol in GameContent.chordOptions(instrument) {
                let event = try! XCTUnwrap(GameContent.chordEvent(symbol, id: 1, instrument: instrument), symbol)
                XCTAssertGreaterThanOrEqual(Set(event.pitches.map { $0 % 12 }).count, 3, symbol)
                XCTAssertEqual(event.octaveTolerant, instrument == .piano)
            }
            XCTAssertTrue(GameContent.defaultChordPair(instrument).allSatisfy(GameContent.chordOptions(instrument).contains))
            var rng = SeededRandom(seed: 5)
            for level in 1...3 {
                let pool = GameContent.rushPool(level: level, instrument: instrument)
                XCTAssertFalse(pool.isEmpty)
                XCTAssertEqual(pool.contains { $0.note.accidental != 0 }, level >= 3)
                var previous: Pitch?
                for _ in 0..<40 {
                    let note = GameContent.rushNote(level: level, instrument: instrument, avoiding: previous, using: &rng)
                    XCTAssertNotEqual(note.written, previous)
                    previous = note.written
                    XCTAssertEqual(note.choices.count, 4)
                    XCTAssertEqual(Set(note.choices).count, 4)
                    XCTAssertEqual(note.choices[note.correctIndex], note.written.note.displayName)
                    XCTAssertTrue(InstrumentContext.standard(instrument).comfortableRange.contains(note.sounding),
                                  "\(note.written) sounds \(note.sounding)")
                }
            }
        }
        let e4 = try! XCTUnwrap(Pitch("E4"))
        XCTAssertEqual(GameContent.soundingMIDI(written: e4, instrument: .guitar), 52)
        XCTAssertEqual(GameContent.soundingMIDI(written: e4, instrument: .piano), 64)
    }

    // MARK: Personal bests

    func testPersonalBestSaveAndLoadInTutorStore() async {
        XCTAssertNil(scores.best(for: "game.fretboard-hunt.guitar", instrument: .guitar))
        scores.record(7, for: "game.fretboard-hunt.guitar", instrument: .guitar)
        scores.record(5, for: "game.fretboard-hunt.guitar", instrument: .guitar)
        XCTAssertEqual(scores.best(for: "game.fretboard-hunt.guitar", instrument: .guitar), 7)
        let record = store.progress(lessonID: "game.fretboard-hunt.guitar", instrument: .guitar)
        XCTAssertEqual(record?.attempts, 2)
        XCTAssertNotEqual(record?.progressStatus, .completed)

        let model = HuntGameModel(instrument: .guitar, dependencies: deps, seed: 1)
        XCTAssertEqual(model.scoreKey, "game.fretboard-hunt.guitar")
        XCTAssertEqual(model.best, 7)
        model.level = 2
        XCTAssertEqual(model.scoreKey, "game.fretboard-hunt.guitar.level2")
        XCTAssertNil(model.best)
        XCTAssertEqual(HuntGameModel(instrument: .piano, dependencies: deps).scoreKey, "game.key-hunt.piano")
    }

    // MARK: Hunt

    func testHuntCountsDistinctPitchesAndSavesBest() async {
        let model = HuntGameModel(instrument: .guitar, dependencies: deps, seed: 1)
        await startAndPlay(model)
        XCTAssertTrue(listener.isListening)
        XCTAssertEqual(listener.detectionSources, .monophonic)
        XCTAssertEqual(model.target, PitchClass(0))
        XCTAssertEqual(model.targets, [48, 60, 72])

        listener.detect(60)
        XCTAssertEqual(model.totalFound, 1)
        XCTAssertEqual(model.feedback?.tone, .good)
        listener.detect(60)                        // same pitch again
        XCTAssertEqual(model.totalFound, 1)
        XCTAssertEqual(model.feedback?.tone, .neutral)
        listener.detect(48, confidence: 0.2)       // unsure: neutral, not counted
        XCTAssertEqual(model.totalFound, 1)
        XCTAssertEqual(model.feedback?.systemImage, "questionmark.circle")
        listener.detect(62)                        // wrong note: neutral, never red
        XCTAssertEqual(model.feedback?.tone, .neutral)
        listener.detect(84)                        // right name, above fret 12
        XCTAssertEqual(model.totalFound, 1)
        XCTAssertEqual(model.foundPositions.count, GameContent.guitarPositions(60).count)

        listener.detect(48)
        listener.detect(72)                        // set complete → new note
        XCTAssertEqual(model.totalFound, 3)
        XCTAssertNotEqual(model.target, PitchClass(0))
        XCTAssertTrue(model.found.isEmpty)
        let next = model.targets[0]
        listener.detect(next)
        XCTAssertEqual(model.totalFound, 4)

        advance(model, 29)
        XCTAssertEqual(model.phase, .playing)
        advance(model, 1.1)
        XCTAssertEqual(model.phase, .results)
        XCTAssertFalse(listener.isListening)
        XCTAssertEqual(model.result?.score, 4)
        XCTAssertEqual(model.result?.isNewBest, true)
        XCTAssertEqual(model.best, 4)
        XCTAssertEqual(scores.best(for: "game.fretboard-hunt.guitar", instrument: .guitar), 4)

        // Detections after the game are ignored.
        listener.detect(60)
        XCTAssertEqual(model.totalFound, 4)

        // A lower score keeps the best.
        await startAndPlay(model)
        listener.detect(48)
        model.endEarly()
        XCTAssertEqual(model.result?.score, 1)
        XCTAssertEqual(model.result?.isNewBest, false)
        XCTAssertEqual(model.result?.previousBest, 4)
        XCTAssertEqual(model.best, 4)
    }

    func testMicrophoneDeniedShowsNoticeAndTapFallback() async {
        listener.startError = TutorAudioError.permissionDenied
        let hunt = HuntGameModel(instrument: .piano, dependencies: deps)
        hunt.autoTick = false
        await hunt.start()
        XCTAssertEqual(hunt.phase, .micDenied)
        XCTAssertFalse(hunt.supportsTapFallback)

        let rush = NoteRushModel(instrument: .guitar, dependencies: deps, seed: 2)
        rush.autoTick = false
        await rush.start()
        XCTAssertEqual(rush.phase, .micDenied)
        XCTAssertTrue(rush.supportsTapFallback)
        rush.useTapFallback()
        rush.showIntro()
        await startAndPlay(rush)
        XCTAssertFalse(listener.isListening)

        let other = GameFakeListener()
        other.startError = TutorAudioError.noInput
        let sprint = ChordSprintModel(instrument: .guitar,
                                      dependencies: GameDependencies(listener: other, player: player, clock: clock, scores: scores))
        sprint.autoTick = false
        await sprint.start()
        if case .unavailable = sprint.phase {} else { XCTFail("expected unavailable, got \(sprint.phase)") }
    }

    // MARK: Chord Change Sprint

    func testChordSprintCountsCleanChanges() async {
        let model = ChordSprintModel(instrument: .guitar, dependencies: deps)
        XCTAssertEqual(model.chords, ["E", "A"])
        await startAndPlay(model)
        XCTAssertEqual(model.duration, 60)
        var event = try! XCTUnwrap(listener.lastArmed)
        XCTAssertEqual(event.chordName, "E")
        XCTAssertFalse(event.octaveTolerant)
        if case .wait = listener.armed.last!.window {} else { XCTFail("wait mode expected") }

        listener.verify(event.id, .hit)             // first chord starts the count
        XCTAssertEqual(model.changes, 0)
        XCTAssertEqual(model.currentChord, "A")
        let stale = event.id
        event = try! XCTUnwrap(listener.lastArmed)
        XCTAssertEqual(event.chordName, "A")
        listener.verify(stale, .hit)                // late result for the old chord
        XCTAssertEqual(model.changes, 0)
        listener.verify(event.id, .uncertain)
        XCTAssertEqual(model.changes, 0)
        XCTAssertEqual(model.feedback?.tone, .neutral)
        listener.verify(event.id, .partial)
        XCTAssertEqual(model.feedback?.tone, .caution)
        XCTAssertEqual(model.retries, 1)
        listener.verify(event.id, .hit)
        XCTAssertEqual(model.changes, 1)
        event = try! XCTUnwrap(listener.lastArmed)
        listener.verify(event.id, .hit)
        XCTAssertEqual(model.changes, 2)

        advance(model, 61)
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.result?.score, 2)
        XCTAssertEqual(scores.best(for: "game.chord-change-sprint.guitar", instrument: .guitar), 2)

        // Another pair keeps its own best.
        model.chords = ["C", "G"]
        XCTAssertEqual(model.scoreKey, "game.chord-change-sprint.guitar.c-g")
        XCTAssertNil(model.best)
    }

    func testChordSprintPianoIsOctaveTolerant() async {
        let model = ChordSprintModel(instrument: .piano, dependencies: deps)
        XCTAssertEqual(model.chords, ["C", "G"])
        await startAndPlay(model)
        XCTAssertEqual(listener.lastArmed?.octaveTolerant, true)
        XCTAssertEqual(Set(listener.lastArmed!.pitches.map { $0 % 12 }), [0, 4, 7])
    }

    // MARK: Ear games

    func testIntervalDuelTapRoundsAndResults() async {
        let model = EarGameModel(kind: .interval, instrument: .guitar, dependencies: deps, seed: 11)
        await startAndPlay(model)
        XCTAssertEqual(model.roundState, .hearing)
        XCTAssertEqual(player.played.count, 1)
        model.choose(0)                                   // no answers while the sound plays
        XCTAssertTrue(model.outcomes.isEmpty)
        player.finish()
        XCTAssertEqual(model.roundState, .answering)
        XCTAssertFalse(listener.isListening)

        model.replay()
        XCTAssertEqual(player.played.count, 2)
        player.finish()

        for i in 0..<EarGameModel.roundCount {
            let round = try! XCTUnwrap(model.round)
            if model.roundState == .hearing { player.finish() }
            model.choose(i < 7 ? round.correctIndex : (round.correctIndex + 1) % round.choices.count)
            if case .answered(let correct, _, _) = model.roundState {
                XCTAssertEqual(correct, i < 7)
            } else {
                XCTFail("expected answered")
            }
            model.next()
        }
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.result?.score, 7)
        XCTAssertEqual(model.result?.scoreText, "7/10")
        XCTAssertEqual(scores.best(for: "game.interval-duel.guitar", instrument: .guitar), 7)
        XCTAssertFalse(player.playedWhileListening)
    }

    func testIntervalDuelAnswerByPlaying() async {
        let model = EarGameModel(kind: .interval, instrument: .piano, dependencies: deps, seed: 4)
        model.answerByPlaying = true
        await startAndPlay(model)
        XCTAssertFalse(listener.isListening)            // listening stays off while the synth plays
        player.finish()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(listener.isListening)
        XCTAssertEqual(listener.detectionSources, .monophonic)
        let round = try! XCTUnwrap(model.round)

        listener.detect(round.target!, confidence: 0.1)  // unsure: keep listening
        XCTAssertEqual(model.roundState, .answering)
        XCTAssertEqual(model.feedback?.tone, .neutral)
        listener.detect(round.root!)                     // the lower note: a hint, not an answer
        XCTAssertEqual(model.roundState, .answering)

        model.replay()                                   // replay stops listening first
        XCTAssertFalse(listener.isListening)
        XCTAssertFalse(player.playedWhileListening)
        player.finish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(listener.isListening)

        listener.detect(round.target!)
        XCTAssertEqual(model.roundState, .answered(correct: true, chosen: nil, played: round.target!))
        XCTAssertFalse(listener.isListening)

        model.next()
        player.finish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = try! XCTUnwrap(model.round)
        let wrong = second.target! + (second.target! - second.root! == 1 ? 2 : 1)
        listener.detect(wrong)
        XCTAssertEqual(model.outcomes, [true, false])
        XCTAssertEqual(model.feedback?.tone, .caution)
        XCTAssertFalse(player.playedWhileListening)
    }

    func testNameThatQualityLevelsAndBest() async {
        let model = EarGameModel(kind: .quality, instrument: .piano, dependencies: deps, seed: 2)
        model.level = 2
        await startAndPlay(model)
        XCTAssertEqual(model.round?.choices.count, 4)
        for _ in 0..<EarGameModel.roundCount {
            player.finish()
            model.choose(model.round!.correctIndex)
            model.next()
        }
        XCTAssertEqual(model.result?.score, 10)
        XCTAssertEqual(scores.best(for: "game.name-that-quality.piano.level2", instrument: .piano), 10)
        XCTAssertFalse(model.supportsTapFallback)
        XCTAssertFalse(model.playsAnswers)
    }

    // MARK: Rhythm Tapper

    func testRhythmScoringGradesOffsetsAndExtras() {
        let expected: [TimeInterval] = [0, 1, 2, 3]
        let perfect = RhythmScoring.score(expected: expected, taps: expected, window: 0.2)
        XCTAssertEqual(perfect.notes.map(\.grade), Array(repeating: .onBeat, count: 4))
        XCTAssertEqual(RhythmScoring.roundScore(perfect.notes, extras: perfect.extras), 100)

        let mixed = RhythmScoring.score(expected: expected, taps: [0.03, 0.9, 2.15, 2.5, 5], window: 0.2)
        XCTAssertEqual(mixed.notes.map(\.grade), [.onBeat, .close, .loose, .missed])
        XCTAssertEqual(mixed.notes[1].offsetMs!, -100, accuracy: 1e-6)
        XCTAssertEqual(mixed.extras, 1)                  // 2.5 is inside the measure; 5 is after it
        XCTAssertEqual(RhythmScoring.roundScore(mixed.notes, extras: mixed.extras), (100 + 70 + 40 + 0 - 50) / 4)
        XCTAssertEqual(RhythmScoring.roundScore([], extras: 0), 0)
        XCTAssertEqual(RhythmScoring.grade(offsetMs: -59, window: 0.2), .onBeat)
        XCTAssertEqual(RhythmScoring.grade(offsetMs: 250, window: 0.2), .missed)
        XCTAssertEqual(RhythmScoring.window(onsetBeats: [0, 0.5, 1], bpm: 60), 0.22)
        XCTAssertEqual(RhythmScoring.window(onsetBeats: [0, 0.25], bpm: 120), 0.08, accuracy: 1e-9)
    }

    func testRhythmTapperTapModeRunsFourMeasures() async {
        let model = RhythmTapperModel(instrument: .guitar, dependencies: deps, seed: 3)
        await startAndPlay(model)
        XCTAssertFalse(listener.isListening)
        XCTAssertEqual(model.roundState, .countIn)
        for round in 0..<RhythmTapperModel.roundCount {
            XCTAssertEqual(model.roundIndex, round)
            model.tick()
            XCTAssertEqual(model.roundState, .countIn)
            let times = model.expectedTimes
            // Tap every note 20 ms late (plus one extra tap on the first round).
            for t in times {
                advance(model, t + 0.02 - clock.now)
                model.tap()
                if round == 0 && t == times.first { model.tap() }
            }
            XCTAssertEqual(model.roundState, .performing)
            runUntilReview(model)
            XCTAssertTrue(model.noteResults.allSatisfy { $0.grade == .onBeat })
            XCTAssertEqual(model.extras, round == 0 ? 1 : 0)
            advance(model, RhythmTapperModel.reviewSeconds + 0.1)
        }
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.roundScores.count, 4)
        let firstNotes = Double(model.patterns[0].noteCount)
        let expectedFirst = (100 * firstNotes - 50) / firstNotes
        XCTAssertEqual(model.result!.score, ((expectedFirst + 300) / 4).rounded())
        XCTAssertEqual(scores.best(for: "game.rhythm-tapper.guitar", instrument: .guitar), model.result!.score)
    }

    func testRhythmTapperPlayModeUsesOnsetsAndMergesDoubles() async {
        let model = RhythmTapperModel(instrument: .piano, dependencies: deps, seed: 3)
        model.playOnInstrument = true
        await startAndPlay(model)
        XCTAssertTrue(listener.isListening)
        let times = model.expectedTimes
        for t in times {
            listener.detect(60, at: t - 0.03)
            listener.detect(60, at: t - 0.01)           // second detector, same onset
        }
        runUntilReview(model)
        XCTAssertEqual(model.extras, 0)
        XCTAssertTrue(model.noteResults.allSatisfy { $0.grade == .onBeat })

        // A silent measure is "not sure", not a failure.
        advance(model, RhythmTapperModel.reviewSeconds + 0.1)
        XCTAssertEqual(model.roundIndex, 1)
        runUntilReview(model)
        XCTAssertEqual(model.feedback?.systemImage, "questionmark.circle")
    }

    // MARK: Scale Runner

    func testScaleRunnerLadderClimbsAndEnds() async {
        let model = ScaleRunnerModel(instrument: .guitar, dependencies: deps)
        await startAndPlay(model)
        XCTAssertEqual(model.bpm, 60)
        XCTAssertEqual(model.runState, .countIn)
        var armed = try! XCTUnwrap(listener.armed.last)
        if case .timed(let times, _) = armed.window {
            XCTAssertEqual(times.count, model.notes.count)
            XCTAssertEqual(times[1] - times[0], 1, accuracy: 1e-9)
        } else {
            XCTFail("timed mode expected")
        }
        // Clean run: every note hit.
        for e in armed.events { listener.verify(e.id, .hit) }
        advance(model, 4.5 + Double(model.notes.count) + 1.5, steps: 20)
        if case .review(_, let climbing) = model.runState { XCTAssertTrue(climbing) } else { XCTFail("review expected") }
        XCTAssertEqual(model.cleanRuns, 1)
        XCTAssertEqual(model.bpm, 66)
        advance(model, ScaleRunnerModel.reviewSeconds + 0.1)
        XCTAssertEqual(model.runState, .countIn)

        // Detector could not hear: same tempo again, the ladder goes on.
        armed = try! XCTUnwrap(listener.armed.last)
        for e in armed.events { listener.verify(e.id, .uncertain) }
        advance(model, 30, steps: 30)
        XCTAssertEqual(model.bpm, 66)
        XCTAssertEqual(model.unsureRuns, 1)
        advance(model, ScaleRunnerModel.reviewSeconds + 0.1)

        // Stale results from an older run are ignored; a messy run ends the ladder.
        let old = armed.events[0].id
        armed = try! XCTUnwrap(listener.armed.last)
        listener.verify(old, .hit)
        for (i, e) in armed.events.enumerated() { listener.verify(e.id, i % 3 == 0 ? .wrongPitch : .hit) }
        advance(model, 30, steps: 30)
        advance(model, ScaleRunnerModel.reviewSeconds + 0.1)
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.result?.score, 60)
        XCTAssertEqual(model.result?.scoreText, "60 BPM")
        XCTAssertEqual(scores.best(for: "game.scale-runner.guitar", instrument: .guitar), 60)
    }

    func testScaleRunnerWaitModeKeepsNoBest() async {
        let model = ScaleRunnerModel(instrument: .piano, dependencies: deps)
        model.waitMode = true
        await startAndPlay(model)
        let armed = try! XCTUnwrap(listener.armed.last)
        if case .wait = armed.window {} else { XCTFail("wait mode expected") }
        listener.verify(armed.events[0].id, .uncertain)
        XCTAssertEqual(model.cursor, 0)
        XCTAssertEqual(model.feedback?.tone, .neutral)
        listener.verify(armed.events[1].id, .hit)        // not the current note
        XCTAssertEqual(model.cursor, 0)
        for e in armed.events { listener.verify(e.id, .hit) }
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.result?.recordsBest, false)
        XCTAssertEqual(model.result?.score, Double(model.notes.count))
        XCTAssertNil(scores.best(for: "game.scale-runner.piano", instrument: .piano))
    }

    // MARK: Note Rush

    func testNoteRushPlayMode() async {
        let model = NoteRushModel(instrument: .guitar, dependencies: deps, seed: 8)
        await startAndPlay(model)
        XCTAssertEqual(model.duration, 60)
        XCTAssertEqual(listener.detectionSources, .verifier)
        var event = try! XCTUnwrap(listener.lastArmed)
        XCTAssertEqual(event.pitches, [model.current.sounding])
        XCTAssertTrue(event.octaveTolerant)              // level 1: any octave
        XCTAssertEqual(model.current.sounding, model.current.written.midi - 12)

        listener.verify(event.id, .uncertain)
        XCTAssertEqual(model.correct, 0)
        XCTAssertEqual(model.feedback?.tone, .neutral)
        listener.verify(event.id, .wrongPitch, unexpected: [event.pitches[0] + 2])
        XCTAssertEqual(model.correct, 0)
        XCTAssertEqual(model.feedback?.tone, .caution)
        let before = model.current
        listener.verify(event.id, .hit)
        XCTAssertEqual(model.correct, 1)
        XCTAssertNotEqual(model.current.written, before.written)
        let stale = event.id
        event = try! XCTUnwrap(listener.lastArmed)
        listener.verify(stale, .hit)
        XCTAssertEqual(model.correct, 1)
        model.skip()
        XCTAssertEqual(model.skipped, 1)
        XCTAssertNotEqual(listener.lastArmed?.id, event.id)

        advance(model, 61)
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.result?.score, 1)
        XCTAssertEqual(scores.best(for: "game.note-rush.guitar", instrument: .guitar), 1)

        model.level = 2
        await startAndPlay(model)
        XCTAssertEqual(listener.lastArmed?.octaveTolerant, false)
    }

    func testNoteRushTapModeNeedsNoMicrophone() async {
        let model = NoteRushModel(instrument: .piano, dependencies: deps, seed: 8)
        model.playOnInstrument = false
        XCTAssertEqual(model.scoreKey, "game.note-rush.piano.tap")
        await startAndPlay(model)
        XCTAssertEqual(listener.startCount, 0)
        model.choose(model.current.correctIndex)
        model.choose((model.current.correctIndex + 1) % 4)
        XCTAssertEqual(model.correct, 1)
        XCTAssertEqual(model.wrong, 1)
        model.endEarly()
        XCTAssertEqual(model.result?.score, 1)
        XCTAssertEqual(scores.best(for: "game.note-rush.piano.tap", instrument: .piano), 1)
    }

    // MARK: Lifecycle

    func testCancelStopsListeningAndReturnsToIntro() async {
        let model = HuntGameModel(instrument: .guitar, dependencies: deps)
        model.autoTick = false
        await model.start()
        if case .countdown = model.phase {} else { XCTFail("countdown expected") }
        XCTAssertTrue(listener.isListening)
        model.cancel()
        XCTAssertEqual(model.phase, .intro)
        XCTAssertFalse(listener.isListening)
        XCTAssertNil(scores.best(for: model.scoreKey, instrument: .guitar))
    }

    func testRegistryHasEveryGameAndDestinations() {
        let ids = TutorGameRegistry.entries.map(\.id)
        XCTAssertTrue(ids.contains(TutorGameID.noteRush))
        for entry in TutorGameRegistry.entries {
            for instrument in entry.instruments {
                XCTAssertNotNil(TutorGames.view(for: entry.id, instrument: instrument, dependencies: self.deps), entry.id)
            }
        }
        XCTAssertNil(TutorGames.view(for: "nope", instrument: .guitar, dependencies: self.deps))
    }
}
