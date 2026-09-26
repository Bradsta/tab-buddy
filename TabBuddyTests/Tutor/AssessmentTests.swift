//
//  AssessmentTests.swift
//  TabBuddyTests
//
//  WP-C assessment: passage adapters, alignment, tempo analysis, take analysis.
//  All inputs are synthetic detection timelines; no audio is involved.
//

import AudioToolbox
import XCTest
@testable import TabBuddy

final class AssessmentTests: XCTestCase {

    // MARK: - Helpers

    private func det(_ time: Double, _ pitches: [Int], _ conf: Double = 0.9,
                     source: DetectionSource = .polyphonic) -> DetectedEvent {
        DetectedEvent(time: time, pitches: pitches, confidences: pitches.map { _ in conf }, source: source)
    }

    /// Perfect performance of `passage` starting at `start` seconds.
    private func perfect(_ passage: ExpectedPassage, start: Double = 0.5) -> [DetectedEvent] {
        passage.events.map { det(start + passage.time(ofBeat: $0.beat), $0.pitches) }
    }

    private let scale = [60, 62, 64, 65, 67, 69, 71, 72]

    // MARK: - Alignment

    func testPerfectTakeAllHits() {
        let passage = PassageBuilder.sequence(scale, bpm: 120, instrument: .piano)
        let result = PerformanceAligner().align(passage: passage, detected: perfect(passage))
        XCTAssertEqual(result.graded.map(\.grade), Array(repeating: .hit, count: 8))
        XCTAssertTrue(result.extras.isEmpty)
        XCTAssertEqual(result.estimatedSecondsPerBeat, 0.5, accuracy: 1e-6)
    }

    func testInsertedDeletedAndWrongNotes() {
        let passage = PassageBuilder.sequence(scale, bpm: 120, instrument: .piano)
        var detected: [DetectedEvent] = []
        for (i, e) in passage.events.enumerated() {
            let t = 0.5 + passage.time(ofBeat: e.beat)
            if i == 2 { continue }                                  // deleted
            detected.append(det(t, i == 5 ? [70] : e.pitches))      // wrong pitch (not an octave)
            if i == 6 { detected.append(det(t + 0.25, [55])) }     // inserted
        }
        let result = PerformanceAligner().align(passage: passage, detected: detected)
        XCTAssertEqual(result.graded.map(\.grade),
                       [.hit, .hit, .missed, .hit, .hit, .wrongPitch, .hit, .hit])
        XCTAssertEqual(result.graded[5].wrongPitches, [70])
        XCTAssertEqual(result.graded[5].missingPitches, [69])
        XCTAssertEqual(result.extras.map(\.pitch), [55])
        XCTAssertEqual(result.extras.first?.afterExpectedID, 6)
    }

    func testChordsHitPartialAndStrumFolding() {
        let eMajor = [40, 47, 52, 56, 59, 64]
        let aMinor = [45, 52, 57, 60, 64]
        let passage = PassageBuilder.chords([eMajor, aMinor, eMajor], names: ["E", "Am", "E"], beatsEach: 2,
                                            bpm: 90, instrument: .guitar)
        XCTAssertEqual(passage.events.map(\.chordName), ["E", "Am", "E"])
        let spb = 60.0 / 90
        let detected = [
            det(0.3, eMajor),
            det(0.3 + 2 * spb, [45, 52, 57]),           // three of five chord tones
            // Slow strum split into two onsets 90 ms apart.
            det(0.3 + 4 * spb, [40, 47, 52]),
            det(0.39 + 4 * spb, [56, 59, 64]),
        ]
        let result = PerformanceAligner().align(passage: passage, detected: detected)
        XCTAssertEqual(result.graded.map(\.grade), [.hit, .partial, .hit])
        XCTAssertEqual(result.graded[1].matchedPitches, [45, 52, 57])
        XCTAssertEqual(result.graded[1].missingPitches, [60, 64])
        XCTAssertTrue(result.extras.isEmpty)
        XCTAssertEqual(TakeAnalyzer.credit(result.graded[1])!, 0.6, accuracy: 1e-9)
    }

    func testOctaveErrorIsUncertainNotWrong() {
        let passage = PassageBuilder.sequence([64, 67], bpm: 100, instrument: .guitar)
        let result = PerformanceAligner().align(passage: passage,
                                                detected: [det(0.2, [52]), det(0.8, [67])])
        XCTAssertEqual(result.graded.map(\.grade), [.uncertain, .hit])
        XCTAssertTrue(result.extras.isEmpty)
    }

    func testLowConfidenceNeverProducesWrongPitch() {
        let passage = PassageBuilder.sequence([60, 62, 64], bpm: 100, instrument: .piano)
        let detected = [det(0.2, [60]), det(0.8, [66], 0.3), det(1.4, [64])]
        let result = PerformanceAligner().align(passage: passage, detected: detected)
        XCTAssertEqual(result.graded.map(\.grade), [.hit, .uncertain, .hit])
        XCTAssertFalse(result.graded.contains { $0.grade == .wrongPitch })
        XCTAssertTrue(result.extras.isEmpty, "weak detections never become extras")

        // A weak match of the right pitch is not a confident hit either.
        let weak = PerformanceAligner().align(passage: passage,
                                              detected: [det(0.2, [60]), det(0.8, [62], 0.3), det(1.4, [64])])
        XCTAssertEqual(weak.graded[1].grade, .uncertain)
    }

    func testSkippedSectionAligns() {
        let pitches = (0..<16).map { 48 + $0 * 2 }
        let passage = PassageBuilder.sequence(pitches, bpm: 120, instrument: .piano)
        var detected: [DetectedEvent] = []
        var t = 0.5
        for i in Array(0..<4) + Array(8..<16) {
            detected.append(det(t, [pitches[i]]))
            t += 0.5
        }
        let result = PerformanceAligner().align(passage: passage, detected: detected)
        let grades = result.graded.map(\.grade)
        XCTAssertEqual(Array(grades[0..<4]), Array(repeating: .hit, count: 4))
        XCTAssertEqual(Array(grades[4..<8]), Array(repeating: .missed, count: 4))
        XCTAssertEqual(Array(grades[8..<16]), Array(repeating: .hit, count: 8))
        XCTAssertTrue(result.extras.isEmpty)
    }

    func testRepeatedSectionBecomesExtras() {
        let pitches = (0..<12).map { 50 + $0 * 2 }
        let passage = PassageBuilder.sequence(pitches, bpm: 120, instrument: .piano)
        var detected: [DetectedEvent] = []
        var t = 0.5
        for i in Array(0..<8) + Array(4..<8) + Array(8..<12) {
            detected.append(det(t, [pitches[i]]))
            t += 0.5
        }
        let result = PerformanceAligner().align(passage: passage, detected: detected)
        XCTAssertEqual(result.graded.map(\.grade), Array(repeating: .hit, count: 12))
        XCTAssertEqual(result.extras.count, 4)
    }

    func testRepeatedPitchesUseTiming() {
        // Four identical notes; the player misses the third. Timing decides which one is missing.
        let passage = PassageBuilder.sequence([60, 60, 60, 60, 62], bpm: 120, instrument: .piano)
        let detected = [det(0.5, [60]), det(1.0, [60]), det(2.0, [60]), det(2.5, [62])]
        let result = PerformanceAligner().align(passage: passage, detected: detected)
        XCTAssertEqual(result.graded.map(\.grade), [.hit, .hit, .missed, .hit, .hit])
    }

    // MARK: - Tempo

    /// Quarter-note timeline over `measures` bars of 4/4, with per-measure BPM.
    private func timeline(measures: Int, bpm: (Int) -> Double, start: Double = 1.0,
                          jitter: (Int) -> Double = { _ in 0 }) -> (ExpectedPassage, [GradedEvent]) {
        let pitches = (0..<(measures * 4)).map { 55 + $0 % 12 }
        let passage = PassageBuilder.sequence(pitches, bpm: 100, instrument: .guitar)
        var t = start
        var graded: [GradedEvent] = []
        for e in passage.events {
            graded.append(GradedEvent(expectedID: e.id, grade: .hit, matchedPitches: e.pitches, missingPitches: [],
                                      wrongPitches: [], playedTime: t + jitter(e.id), timingOffsetMs: nil,
                                      confidence: 1))
            t += 60 / bpm(e.measureIndex)
        }
        return (passage, graded)
    }

    func testSteadyTempoWithJitterMeasuresMAD() {
        let (passage, graded) = timeline(measures: 8, bpm: { _ in 100 }, jitter: { $0 % 2 == 0 ? 0.03 : -0.03 })
        let report = TempoAnalyzer().analyze(graded: graded, passage: passage, targetBPM: 100)
        XCTAssertEqual(report.timingMADms ?? 0, 30, accuracy: 8)
        XCTAssertEqual(report.globalBPM ?? 0, 100, accuracy: 1)
        XCTAssertEqual(report.globalOffsetSeconds ?? 0, 1.0, accuracy: 0.04)
        XCTAssertEqual(report.tempoCurve.count, 8)
        XCTAssertTrue(report.measureTendency.values.allSatisfy { $0 == .steady }, "\(report.measureTendency)")
    }

    func testRushedSectionDetected() {
        let (passage, graded) = timeline(measures: 8, bpm: { (3...5).contains($0) ? 125 : 100 })
        let report = TempoAnalyzer().analyze(graded: graded, passage: passage, targetBPM: 100)
        XCTAssertEqual(report.measureTendency[4], .rushing)
        XCTAssertEqual(report.measureTendency[0], .steady)
        XCTAssertEqual(report.measureTendency[7], .steady)
        XCTAssertFalse(report.measureTendency.values.contains(.dragging))
        let m4 = report.tempoCurve.first { $0.beat > 16 && $0.beat < 20 }
        XCTAssertEqual(m4?.bpm ?? 0, 125, accuracy: 4)
        // Offsets are measured from the local line, so smooth drift is not scored as unevenness.
        XCTAssertLessThan(report.timingMADms ?? .infinity, 15)
    }

    func testDraggingTowardTheEndDetected() {
        let (passage, graded) = timeline(measures: 8, bpm: { $0 >= 5 ? 80 : 100 })
        let report = TempoAnalyzer().analyze(graded: graded, passage: passage, targetBPM: 100)
        XCTAssertEqual(report.measureTendency[6], .dragging)
        XCTAssertEqual(report.measureTendency[7], .dragging)
        XCTAssertEqual(report.measureTendency[1], .steady)
        XCTAssertFalse(report.measureTendency.values.contains(.rushing))
    }

    func testOwnMedianReferenceIgnoresOverallSpeed() {
        let (passage, graded) = timeline(measures: 6, bpm: { _ in 70 })
        let target = TempoAnalyzer().analyze(graded: graded, passage: passage, targetBPM: 100)
        XCTAssertTrue(target.measureTendency.values.allSatisfy { $0 == .dragging })
        let own = TempoAnalyzer().analyze(graded: graded, passage: passage, targetBPM: 100, reference: .ownMedian)
        XCTAssertTrue(own.measureTendency.values.allSatisfy { $0 == .steady })
    }

    func testFreeTimeSkipsTiming() {
        var (passage, graded) = timeline(measures: 4, bpm: { _ in 100 })
        passage.isFreeTime = true
        let report = TempoAnalyzer().analyze(graded: graded, passage: passage, targetBPM: 100)
        XCTAssertNil(report.timingMADms)
        XCTAssertTrue(report.tempoCurve.isEmpty)
        XCTAssertTrue(report.offsetsMs.isEmpty)
        XCTAssertTrue(report.measureTendency.values.allSatisfy { $0 == .unknown })
    }

    // MARK: - Take analysis

    func testTakeAnalysisSuggestsWeakestSpan() {
        let pitches = (0..<32).map { 52 + $0 % 14 }
        let passage = PassageBuilder.sequence(pitches, bpm: 100, instrument: .guitar)
        var detected: [DetectedEvent] = []
        for e in passage.events {
            let t = 0.4 + passage.time(ofBeat: e.beat)
            // Measures 5–6 (indices 4 and 5): only the first note of each is correct.
            if (4...5).contains(e.measureIndex) && e.positionInMeasure > 0 {
                detected.append(det(t, [e.pitches[0] + 20]))
            } else {
                detected.append(det(t, e.pitches))
            }
        }
        let analysis = TakeAnalyzer().analyze(passage: passage, live: [], detected: detected)
        XCTAssertEqual(analysis.measureAccuracy[4] ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(analysis.measureAccuracy[0] ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(analysis.accuracy, 26.0 / 32.0, accuracy: 1e-9)
        XCTAssertEqual(analysis.targetBPM, 100)
        let loop = analysis.suggestions.first
        XCTAssertEqual(loop?.loopMeasures, 4...5)
        XCTAssertEqual(loop?.tempoPercent, 80)
        XCTAssertEqual(loop?.message, "Loop measures 5–6 at 80%")
        XCTAssertNotNil(analysis.graded.first?.timingOffsetMs)

        // Round-trips through the store's JSON form.
        let data = try! JSONEncoder().encode(analysis)
        XCTAssertEqual(try! JSONDecoder().decode(TakeAnalysis.self, from: data), analysis)
    }

    func testLiveResultsFillTranscriptionGaps() {
        let passage = PassageBuilder.sequence([60, 64, 67, 72], bpm: 120, instrument: .piano)
        // Transcription missed note 1 and heard note 2 only weakly.
        let detected = [det(0.5, [60]), det(1.5, [66], 0.3), det(2.0, [72])]
        let live = [
            VerificationResult(expectedID: 1, grade: .hit, heard: [64], unexpected: [], onsetTime: 1.0, confidence: 0.8),
            VerificationResult(expectedID: 3, grade: .wrongPitch, heard: [], unexpected: [71], onsetTime: 2.0, confidence: 0.7),
        ]
        let analysis = TakeAnalyzer().analyze(passage: passage, live: live, detected: detected, tempoScale: 1)
        XCTAssertEqual(analysis.graded.map(\.grade), [.hit, .hit, .uncertain, .hit])
        XCTAssertEqual(analysis.graded[1].playedTime, 1.0)
        XCTAssertEqual(analysis.accuracy, 1, accuracy: 1e-9)

        // Live-only path (no tier C).
        let liveOnly = TakeAnalyzer().analyze(passage: passage, live: live, detected: [])
        XCTAssertEqual(liveOnly.graded.map(\.grade), [.missed, .hit, .missed, .wrongPitch])
    }

    func testCleanSlowTakeSuggestsSpeedUp() {
        let passage = PassageBuilder.sequence(scale, bpm: 100, instrument: .piano)
        let detected = passage.events.map { det(0.3 + passage.time(ofBeat: $0.beat, tempoScale: 0.7), $0.pitches) }
        let analysis = TakeAnalyzer().analyze(passage: passage, live: [], detected: detected, tempoScale: 0.7)
        XCTAssertEqual(analysis.accuracy, 1)
        XCTAssertEqual(analysis.targetBPM, 70, accuracy: 1e-9)
        XCTAssertEqual(analysis.suggestions.first?.tempoPercent, 80)
    }

    func testLatencyIsRemovedBeforeAnalysis() {
        let passage = PassageBuilder.sequence(scale, bpm: 120, instrument: .piano)
        let analysis = TakeAnalyzer().analyze(passage: passage, live: [], detected: perfect(passage, start: 0.2),
                                              latencySeconds: 0.08)
        XCTAssertEqual(analysis.graded.first?.playedTime ?? 0, 0.12, accuracy: 1e-9)
    }

    // MARK: - PassageBuilder: MeasureMap

    func testMeasureMapPassageFromFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "classtab-aguado", withExtension: "txt",
                                                           subdirectory: "Fixtures"))
        let text = try String(contentsOf: url).replacingOccurrences(of: "\r\n", with: "\n")
        let map = TabParser.parse(text)
        let passage = try XCTUnwrap(PassageBuilder.from(measureMap: map, measureRange: 1...3, bpm: 100))
        XCTAssertFalse(passage.events.isEmpty)
        XCTAssertEqual(passage.bpm, 100)
        XCTAssertEqual(passage.measureRange, 1...3)
        XCTAssertEqual(passage.events.first?.measureIndex, 1)
        XCTAssertEqual(passage.events.first?.beat ?? -1, 0, accuracy: 0.51, "beat 0 is the start of the first measure in range")
        XCTAssertEqual(passage.events.map(\.id), Array(0..<passage.events.count))
        XCTAssertEqual(passage.events.map(\.beat), passage.events.map(\.beat).sorted())
        for e in passage.events {
            XCTAssertFalse(e.pitches.isEmpty)
            XCTAssertTrue(e.pitches.allSatisfy { (40...88).contains($0) }, "\(e.pitches)")
            XCTAssertEqual(Set(e.pitches).count, e.pitches.count)
            XCTAssertGreaterThanOrEqual(e.fretting?.count ?? 0, e.pitches.count)
        }
        // Measure 2 of the waltz (index 1) opens on the open A bass under a 9th-fret B-string note.
        let firstBeatPitches = Set(passage.events.filter { $0.measureIndex == 1 && $0.positionInMeasure < 0.1 }
            .flatMap(\.pitches))
        XCTAssertTrue(firstBeatPitches.contains(45), "\(firstBeatPitches)")
        // A whole-piece passage has events in every measure with notes.
        let whole = try XCTUnwrap(PassageBuilder.from(measureMap: map))
        XCTAssertGreaterThan(whole.events.count, passage.events.count)
    }

    func testMeasureMapMergesChordsAndAppliesCapo() throws {
        let tab = """
        e|-----0-----|-0---------|
        B|---1-------|-1---------|
        G|-2---------|-0---------|
        D|-----------|-2---------|
        A|-----------|-3---------|
        E|-0---------|-----------|
        """
        var map = TabParser.parse(tab)
        let plain = try XCTUnwrap(PassageBuilder.from(measureMap: map, bpm: 60))
        XCTAssertEqual(plain.events.first?.pitches, [40, 57])
        XCTAssertEqual(plain.events.first?.fretting, [FretPosition(string: 2, fret: 2), FretPosition(string: 5, fret: 0)])
        // C major chord in measure 2 is one event.
        let chord = try XCTUnwrap(plain.events.first { $0.measureIndex == 1 })
        XCTAssertEqual(chord.pitches, [48, 52, 55, 60, 64])
        XCTAssertEqual(plain.events.filter { $0.measureIndex == 1 }.count, 1)

        map.capoSemitones = 2
        let capo = try XCTUnwrap(PassageBuilder.from(measureMap: map, bpm: 60))
        XCTAssertEqual(capo.events.first?.pitches, [42, 59])

        // Unknown tuning without octave information yields no passage.
        map.tuning = "Custom XYZ"
        map.openStringMIDI = nil
        map.detectedStringCount = 5
        XCTAssertNil(PassageBuilder.from(measureMap: map))
    }

    func testCanonicalPassageMatchesMeasureMap() throws {
        let tab = """
        e|-----0-----|-0---------|
        B|---1-------|-1---------|
        G|-2---------|-0---------|
        D|-----------|-2---------|
        A|-----------|-3---------|
        E|-0---------|-----------|
        """
        let map = TabParser.parse(tab)
        let canonical = CanonicalAdapters.canonicalTab(from: map, title: "t", sourceType: .txtDirect)
        let a = try XCTUnwrap(PassageBuilder.from(measureMap: map, bpm: 80))
        let b = try XCTUnwrap(PassageBuilder.from(canonical: canonical, bpm: 80))
        XCTAssertEqual(a.events.map(\.pitches), b.events.map(\.pitches))
        XCTAssertEqual(a.events.map(\.measureIndex), b.events.map(\.measureIndex))
        for (x, y) in zip(a.events, b.events) { XCTAssertEqual(x.beat, y.beat, accuracy: 1e-6) }
    }

    // MARK: - PassageBuilder: MIDI

    func testMIDIFilePassage() throws {
        var sequence: MusicSequence?
        XCTAssertEqual(NewMusicSequence(&sequence), noErr)
        let seq = try XCTUnwrap(sequence)
        defer { DisposeMusicSequence(seq) }
        var tempoTrack: MusicTrack?
        MusicSequenceGetTempoTrack(seq, &tempoTrack)
        XCTAssertEqual(MusicTrackNewExtendedTempoEvent(try XCTUnwrap(tempoTrack), 0, 100), noErr)
        var track: MusicTrack?
        XCTAssertEqual(MusicSequenceNewTrack(seq, &track), noErr)
        let t = try XCTUnwrap(track)
        func note(_ beat: Double, _ pitch: UInt8, _ duration: Float32 = 1) {
            var msg = MIDINoteMessage(channel: 0, note: pitch, velocity: 90, releaseVelocity: 0, duration: duration)
            XCTAssertEqual(MusicTrackNewMIDINoteEvent(t, beat, &msg), noErr)
        }
        note(0, 60)
        note(1, 64); note(1, 67)            // chord
        note(4.5, 71, 0.5)                  // measure 2, eighth after the downbeat
        note(8, 72, 4)                      // measure 3
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wpc-\(UUID().uuidString).mid")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(MusicSequenceFileCreate(seq, url as CFURL, .midiType, .eraseFile, 480), noErr)

        let passage = try XCTUnwrap(PassageBuilder.from(midiFileURL: url))
        XCTAssertEqual(passage.bpm, 100, accuracy: 0.01)
        XCTAssertEqual(passage.events.map(\.pitches), [[60], [64, 67], [71], [72]])
        XCTAssertEqual(passage.events.map(\.measureIndex), [0, 0, 1, 2])
        XCTAssertEqual(passage.events[2].beat, 4.5, accuracy: 1e-3)
        XCTAssertEqual(passage.events[2].positionInMeasure, 0.125, accuracy: 1e-3)
        XCTAssertEqual(passage.events[2].durationBeats, 0.5, accuracy: 1e-3)
        XCTAssertEqual(passage.instrument, .piano)

        // Measure range rebases beats to the first included measure.
        let ranged = try XCTUnwrap(PassageBuilder.from(midiFileURL: url, measureRange: 1...2))
        XCTAssertEqual(ranged.events.map(\.pitches), [[71], [72]])
        XCTAssertEqual(ranged.events[0].beat, 0.5, accuracy: 1e-3)
        XCTAssertEqual(ranged.events[1].beat, 4, accuracy: 1e-3)
    }

    // MARK: - PassageBuilder: alphaTab export

    func testAlphaTabExportPassage() throws {
        let notes: [[String: Any]] = [
            ["track": 0, "bar": 0, "start": 0, "duration": 960, "midi": [40, 47, 52], "tempo": 96,
             "barStartTick": 0, "beatsPerBar": 4],
            ["track": 0, "bar": 0, "start": NSNumber(value: 1920.0), "duration": 960, "midi": [NSNumber(value: 55), -1],
             "tempo": 96, "ticksPerQuarter": 960, "barStartTick": 0, "beatsPerBar": 4],
            ["track": 1, "bar": 0, "start": 0, "duration": 960, "midi": [76], "tempo": 96,
             "barStartTick": 0, "beatsPerBar": 4],
            ["track": 0, "bar": 1, "start": "4080", "duration": 480, "midi": [59], "tempo": 96,
             "barStartTick": 3840, "beatsPerBar": 4],
            ["track": 0, "bar": 1, "start": 4320, "duration": 480, "midi": [-1], "tempo": 96,
             "barStartTick": 3840, "beatsPerBar": 4],
            ["track": 0, "bar": 2, "midi": [60]],                         // missing keys: skipped
        ]
        let passage = try XCTUnwrap(PassageBuilder.from(alphaTabNotes: notes))
        XCTAssertEqual(passage.bpm, 96)
        XCTAssertEqual(passage.beatsPerMeasure, 4)
        XCTAssertEqual(passage.events.map(\.pitches), [[40, 47, 52], [55], [59]])
        XCTAssertEqual(passage.events.map(\.beat), [0, 2, 4.25])
        XCTAssertEqual(passage.events.map(\.measureIndex), [0, 0, 1])
        XCTAssertEqual(passage.events[2].positionInMeasure, 0.0625, accuracy: 1e-9)
        XCTAssertEqual(passage.events[2].durationBeats, 0.5, accuracy: 1e-9)

        let bar1 = try XCTUnwrap(PassageBuilder.from(alphaTabNotes: notes, track: 0, measureRange: 1...1))
        XCTAssertEqual(bar1.events.map(\.beat), [0.25])
        let track1 = try XCTUnwrap(PassageBuilder.from(alphaTabNotes: notes, track: 1))
        XCTAssertEqual(track1.events.map(\.pitches), [[76]])

        // JSON form decodes with the documented defaults.
        let json = #"[{"track":0,"bar":0,"start":480,"duration":480,"midi":[64],"tempo":120,"barStartTick":0,"beatsPerBar":3}]"#
        let typed = try JSONDecoder().decode([PassageBuilder.AlphaTabNote].self, from: Data(json.utf8))
        XCTAssertEqual(typed.first?.ticksPerQuarter, 960)
        let fromJSON = try XCTUnwrap(PassageBuilder.from(alphaTabNotes: typed))
        XCTAssertEqual(fromJSON.events.first?.beat, 0.5)
        XCTAssertEqual(fromJSON.events.first?.positionInMeasure ?? 0, 0.5 / 3, accuracy: 1e-9)
    }

    // MARK: - PassageBuilder: exercises

    func testExerciseHelpers() {
        let chords = PassageBuilder.chords([[45, 52, 57], [40, 47, 52]], beatsEach: 2, repetitions: 2,
                                           bpm: 80, instrument: .guitar)
        XCTAssertEqual(chords.events.count, 4)
        XCTAssertEqual(chords.events.map(\.beat), [0, 2, 4, 6])
        XCTAssertEqual(chords.events.map(\.measureIndex), [0, 0, 1, 1])
        XCTAssertEqual(chords.events[1].positionInMeasure, 0.5)

        let rhythm = PassageBuilder.from(pitchEvents: [[60], [], [62], [64]], durations: [1, 1, 0.5, 1.5],
                                         bpm: 60, beatsPerMeasure: 3, instrument: .piano)
        XCTAssertEqual(rhythm.events.map(\.pitches), [[60], [62], [64]], "rests take time but are not events")
        XCTAssertEqual(rhythm.events.map(\.beat), [0, 2, 2.5])
        XCTAssertEqual(rhythm.events.map(\.durationBeats), [1, 0.5, 1.5])
        XCTAssertEqual(rhythm.events.map(\.measureIndex), [0, 0, 0])
        XCTAssertEqual(rhythm.events.map(\.id), [0, 1, 2])
    }

    // MARK: - x/8 meters, suggestions, no reading

    func testCompoundMetersUseQuarterNoteBeats() throws {
        XCTAssertEqual(PassageBuilder.quarterBeats(numerator: 4, noteValue: 4), 4)
        XCTAssertEqual(PassageBuilder.quarterBeats(numerator: 6, noteValue: 8), 3)
        XCTAssertEqual(PassageBuilder.quarterBeats(numerator: 12, noteValue: 8), 6)
        XCTAssertEqual(PassageBuilder.quarterBeats(numerator: 2, noteValue: 2), 4)
        XCTAssertEqual(PassageBuilder.quarterBeats(numerator: 7, noteValue: 8), 4)
        // alphaTab 6/8 bar = 3 quarters = 2880 ticks.
        let notes: [[String: Any]] = [
            ["track": 0, "bar": 0, "start": 0, "duration": 480, "midi": [60], "tempo": 90,
             "barStartTick": 0, "beatsPerBar": 6, "beatValue": 8],
            ["track": 0, "bar": 1, "start": 2880, "duration": 480, "midi": [62], "tempo": 90,
             "barStartTick": 2880, "beatsPerBar": 6, "beatValue": 8],
        ]
        let passage = try XCTUnwrap(PassageBuilder.from(alphaTabNotes: notes))
        XCTAssertEqual(passage.beatsPerMeasure, 3)
        XCTAssertEqual(passage.events.map(\.beat), [0, 3])
    }

    func testAllUncertainTakeHasNoReading() {
        let passage = PassageBuilder.sequence(scale, bpm: 100, instrument: .piano)
        // Octave-only, low-confidence detections: every event is uncertain.
        let detected = passage.events.map { det(0.5 + passage.time(ofBeat: $0.beat), [$0.pitches[0] + 12], 0.3) }
        let analysis = TakeAnalyzer().analyze(passage: passage, live: [], detected: detected)
        XCTAssertTrue(analysis.graded.allSatisfy { $0.grade == .uncertain })
        XCTAssertFalse(analysis.hasReading)
        XCTAssertEqual(analysis.gradedCount, 0)
        XCTAssertTrue(analysis.measureAccuracy.isEmpty)
        XCTAssertTrue(analysis.suggestions.isEmpty)
        let model = TakeReviewModel(analysis: analysis, passage: passage)
        XCTAssertNil(model.displayAccuracy)

        let clean = TakeAnalyzer().analyze(passage: passage, live: [], detected: perfect(passage))
        XCTAssertTrue(clean.hasReading)
        XCTAssertEqual(TakeReviewModel(analysis: clean, passage: passage).displayAccuracy, 1)
    }

    func testCleanNotesWithLooseTimingDoNotClaimFullSpeed() {
        let passage = PassageBuilder.sequence(scale + scale, bpm: 100, instrument: .piano)
        // Right notes, ±120 ms alternating timing at 70%.
        let detected = passage.events.enumerated().map { i, e in
            det(0.3 + passage.time(ofBeat: e.beat, tempoScale: 0.7) + (i % 2 == 0 ? 0.12 : -0.12), e.pitches)
        }
        let analysis = TakeAnalyzer().analyze(passage: passage, live: [], detected: detected, tempoScale: 0.7)
        XCTAssertEqual(analysis.accuracy, 1)
        XCTAssertGreaterThan(analysis.timingMADms ?? 0, TakeAnalyzer.Config().cleanTimingMs)
        let messages = analysis.suggestions.map(\.message)
        XCTAssertFalse(messages.contains { $0.contains("full speed") }, "\(messages)")
        XCTAssertFalse(messages.contains { $0.hasPrefix("Clean take. Try it at") }, "\(messages)")
    }

    func testWaitModeTakesSkipDriftSuggestions() {
        let passage = PassageBuilder.sequence(scale + scale + scale + scale, bpm: 100, instrument: .piano)
        let spb = passage.time(ofBeat: 1)
        // Every note right; the second half much faster than the first.
        var t = 0.5
        let detected = passage.events.map { e -> DetectedEvent in
            defer { t += e.measureIndex >= 4 ? spb * 0.6 : spb }
            return det(t, e.pitches)
        }
        let timed = TakeAnalyzer().analyze(passage: passage, live: [], detected: detected, timingReference: .target)
        let wait = TakeAnalyzer().analyze(passage: passage, live: [], detected: detected, timingReference: .ownMedian)
        XCTAssertTrue(wait.suggestions.allSatisfy { !$0.message.contains("rushed") && !$0.message.contains("dragged") },
                      "\(wait.suggestions.map(\.message))")
        XCTAssertTrue(timed.hasReading)
    }

    // MARK: - Banded alignment

    func testBandedAlignmentMatchesFullMatrix() {
        // ~200 × 200 with wrong notes, a skipped measure, extras, and drift.
        var pitches: [Int] = []
        for i in 0..<200 { pitches.append(48 + (i * 7) % 24) }
        let passage = PassageBuilder.sequence(pitches, bpm: 110, instrument: .piano)
        var detected: [DetectedEvent] = []
        for e in passage.events where !(40..<44).contains(e.id) {
            let drift = 1 + 0.08 * Double(e.id) / 200
            let t = 0.4 + passage.time(ofBeat: e.beat) * drift
            detected.append(det(t, e.id % 17 == 0 ? [e.pitches[0] + 1] : e.pitches))
            if e.id % 29 == 0 { detected.append(det(t + 0.15, [90])) }
        }
        var full = PerformanceAligner.Config()
        full.fullMatrixCellLimit = .max
        var banded = PerformanceAligner.Config()
        banded.fullMatrixCellLimit = 0
        banded.bandSeconds = 3
        banded.bandBeats = 4
        let a = PerformanceAligner(config: full).align(passage: passage, detected: detected)
        let b = PerformanceAligner(config: banded).align(passage: passage, detected: detected)
        XCTAssertEqual(a.graded, b.graded)
        XCTAssertEqual(a.extras, b.extras)
        XCTAssertEqual(a.estimatedSecondsPerBeat, b.estimatedSecondsPerBeat, accuracy: 1e-12)
    }

    func testRepeatedSectionAlignsExactlyInLongTakes() {
        // Measures 3–6 played twice in a 400-note take: 8 s behind the tempo line.
        let pitches = (0..<400).map { 50 + ($0 * 5) % 19 }
        let passage = PassageBuilder.sequence(pitches, bpm: 120, instrument: .piano)
        let order = Array(0..<24) + Array(8..<24) + Array(24..<400)
        let spb = passage.time(ofBeat: 1)
        let detected = order.enumerated().map { k, id in det(0.5 + Double(k) * spb, passage.events[id].pitches) }
        let result = PerformanceAligner().align(passage: passage, detected: detected)
        XCTAssertEqual(result.graded.filter { $0.grade == .hit }.count, 400)
        XCTAssertEqual(result.extras.count, 16)
    }

    func testWholePieceAlignmentIsBounded() {
        // 1500 expected events against 2000 detected clusters (every fourth note doubled).
        let pitches = (0..<1500).map { 40 + ($0 * 11) % 36 }
        let passage = PassageBuilder.sequence(pitches, beatsEach: 0.5, bpm: 120, instrument: .piano)
        var detected: [DetectedEvent] = []
        for e in passage.events {
            let t = 0.5 + passage.time(ofBeat: e.beat)
            detected.append(det(t, e.pitches))
            if e.id % 3 == 0 { detected.append(det(t + 0.11, [e.pitches[0] + 2])) }
        }
        let start = Date()
        let result = PerformanceAligner().align(passage: passage, detected: detected)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.graded.count, 1500)
        XCTAssertGreaterThan(result.graded.filter { $0.grade == .hit }.count, 1400)
        XCTAssertLessThan(elapsed, 5, "banded DP should finish in seconds")
    }
}
