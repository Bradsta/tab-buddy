//
//  ChordChangesDrillTests.swift
//  TabBuddyTests
//
//  Diatonic chord picking, the One Minute Changes spec and exercise, counting
//  clean changes from the Try it model's heard marks, and changes history in
//  PracticeMemory.
//

import XCTest
@testable import TabBuddy

@MainActor
final class ChordChangesDrillTests: XCTestCase {

    private func key(_ text: String) throws -> Key { try Key(parsing: text) }
    private func chord(_ text: String) throws -> Chord { try Chord(parsing: text) }

    // MARK: Diatonic chords

    func testCMajorTriads() throws {
        let triads = DiatonicChords.triads(in: try key("C major"))
        XCTAssertEqual(triads.map(\.chord.symbol), ["C", "Dm", "Em", "F", "G", "Am", "Bdim"])
        XCTAssertEqual(triads.map(\.roman), ["I", "ii", "iii", "IV", "V", "vi", "vii°"])
    }

    func testAMinorTriads() throws {
        let triads = DiatonicChords.triads(in: try key("A minor"))
        XCTAssertEqual(triads.map(\.chord.symbol), ["Am", "Bdim", "C", "Dm", "Em", "F", "G"])
        XCTAssertEqual(triads.map(\.roman), ["i", "ii°", "III", "iv", "v", "VI", "VII"])
    }

    func testGMajorTriads() throws {
        let triads = DiatonicChords.triads(in: try key("G major"))
        XCTAssertEqual(triads.map(\.chord.symbol), ["G", "Am", "Bm", "C", "D", "Em", "F#dim"])
        XCTAssertEqual(triads.map(\.roman), ["I", "ii", "iii", "IV", "V", "vi", "vii°"])
    }

    func testCMajorSeventhsAndExtras() throws {
        let c = try key("C major")
        let sevenths = DiatonicChords.sevenths(in: c)
        XCTAssertEqual(sevenths.map(\.chord.symbol), ["Cmaj7", "Dm7", "Em7", "Fmaj7", "G7", "Am7", "Bm7b5"])
        XCTAssertEqual(sevenths.first?.roman, "Imaj7")
        XCTAssertEqual(sevenths.last?.roman, "viiø7")
        XCTAssertEqual(DiatonicChords.extras(in: c).map(\.symbol), ["C7", "Cmaj7", "Csus2", "Csus4"])
        XCTAssertEqual(DiatonicChords.roman(for: try chord("C7"), in: c), "I7")
    }

    func testQualityFamilies() {
        XCTAssertEqual(DiatonicChords.family(of: .major), .major)
        XCTAssertEqual(DiatonicChords.family(of: .dominantSeventh), .major)
        XCTAssertEqual(DiatonicChords.family(of: .minor), .minor)
        XCTAssertEqual(DiatonicChords.family(of: .diminished), .diminished)
        XCTAssertEqual(DiatonicChords.family(of: .halfDiminishedSeventh), .diminished)
        XCTAssertEqual(DiatonicChords.family(of: .sus4), .other)
    }

    func testTapSelection() throws {
        let c = try chord("C"), g = try chord("G"), am = try chord("Am"), f = try chord("F"), dm = try chord("Dm")
        XCTAssertEqual(DiatonicChordRow.applyingTap(g, to: [c], mode: .single, maxSelection: 4), [g])
        var tray: [Chord] = []
        for x in [c, am, f, g, dm] { tray = DiatonicChordRow.applyingTap(x, to: tray, mode: .changes, maxSelection: 4) }
        XCTAssertEqual(tray, [c, am, f, g], "keeps tap order and stops at four")
        tray = DiatonicChordRow.applyingTap(am, to: tray, mode: .changes, maxSelection: 4)
        XCTAssertEqual(tray, [c, f, g], "tapping a selected chord removes it")
    }

    // MARK: Spec and exercise

    func testSpecTitlesAndExercise() throws {
        let pair = ChordChangesSpec(instrument: .guitar, chords: [try chord("C"), try chord("G")])
        XCTAssertEqual(pair.title, "C ↔ G")
        let four = ChordChangesSpec(instrument: .guitar, chords: try ["C", "Am", "F", "G"].map(chord))
        XCTAssertEqual(four.title, "C → Am → F → G")

        let exercise = try pair.exercise()
        XCTAssertEqual(exercise.kind, .chordChanges)
        XCTAssertEqual(exercise.pacing, .countChanges)
        XCTAssertEqual(exercise.durationSec, 60)
        XCTAssertEqual(exercise.bpm, 60)
        XCTAssertEqual(exercise.changesPerMinuteTarget, pair.goalPerMinute)
        XCTAssertEqual(Array(exercise.passage.events.prefix(4)).map(\.chordName), ["C", "G", "C", "G"])

        XCTAssertThrowsError(try ChordChangesSpec(instrument: .guitar, chords: [try chord("C")]).exercise())
    }

    // MARK: Counting

    func testTallyCountsGrowthAcrossWraps() {
        var tally = ChangesTally()
        tally.observe(heard: [0])
        tally.observe(heard: [0, 1])
        tally.observe(heard: [0, 1])       // re-publish without change
        tally.observe(heard: [])            // cursor wrapped
        tally.observe(heard: [0])
        XCTAssertEqual(tally.cleanChords, 3)
        XCTAssertEqual(tally.changes, 2, "the first clean chord is not a change")
    }

    func testMicrophoneRunCountsHeardChords() async throws {
        let spec = ChordChangesSpec(instrument: .guitar, chords: [try chord("G"), try chord("D")])
        let listener = FakeTutorListener()
        let model = TryItModel(exercise: try spec.exercise(), prompt: spec.prompt, instrument: .guitar, bpm: spec.bpm,
                               listener: listener, player: FakeSequencePlayer())
        model.autoTick = false
        let run = ChordChangesRun(durationSec: 60, counting: .microphone)
        await run.start(model: model)
        XCTAssertEqual(run.phase, .running)
        XCTAssertEqual(model.listenState, .listening)

        let ids = model.events.map(\.id)
        XCTAssertEqual(ids.count, 4)
        for id in ids { listener.verify(id, .hit) }      // wraps after the fourth
        listener.verify(ids[0], .hit)
        listener.verify(ids[1], .uncertain)              // never counted
        listener.verify(ids[1], .hit)
        XCTAssertEqual(run.count, 5, "6 clean chords = 5 changes")

        run.finish(model: model)
        XCTAssertEqual(run.phase, .finished(count: 5, saved: false))
        XCTAssertEqual(model.listenState, .off)
    }

    func testMicrophoneDeniedFallsBackToTaps() async throws {
        let spec = ChordChangesSpec(instrument: .guitar, chords: [try chord("C"), try chord("G")])
        let listener = FakeTutorListener()
        listener.startError = TutorAudioError.permissionDenied
        let model = TryItModel(exercise: try spec.exercise(), prompt: spec.prompt, instrument: .guitar,
                               listener: listener, player: FakeSequencePlayer())
        let run = ChordChangesRun(durationSec: 60, counting: .microphone)
        await run.start(model: model)
        XCTAssertEqual(run.counting, .taps)
        XCTAssertNotNil(run.notice)
        run.tap(); run.tap(); run.tap(); run.undoTap()
        run.finish(model: model)
        XCTAssertEqual(run.phase, .finished(count: 2, saved: false))
    }

    // MARK: History

    func testChangesHistoryPersistsAndIsOrderIndependent() throws {
        let suite = "ChordChangesDrillTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let memory = PracticeMemory(defaults: defaults)
        memory.recordChanges(instrument: .guitar, chords: ["C", "G"], count: 12, durationSec: 60)
        memory.recordChanges(instrument: .guitar, chords: ["G", "C"], count: 9, durationSec: 30)

        let reloaded = PracticeMemory(defaults: defaults)
        let history = reloaded.changesHistory(instrument: .guitar, chords: ["G", "C"])
        XCTAssertEqual(history.map(\.count), [12, 9])
        XCTAssertEqual(history.map(\.perMinute), [12, 18])
        XCTAssertEqual(reloaded.changesHistory(instrument: .guitar, chords: ["C", "G"]), history)
        XCTAssertTrue(reloaded.changesHistory(instrument: .piano, chords: ["C", "G"]).isEmpty)
    }
}
