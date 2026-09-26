//
//  PracticePresentationTests.swift
//  TabBuddyTests
//
//  Practice mode lifetime and presentation: the MIDI source after close, the
//  viewer's session handle, telling a covering presentation from leaving the
//  viewer, bass detection, and "no reading" takes in history.
//

import XCTest
@testable import TabBuddy

@MainActor
final class PracticePresentationTests: XCTestCase {

    func testMIDISourceReloadsAfterCleanUp() async throws {
        let passage = PassageBuilder.sequence([60, 62, 64, 65], bpm: 100, instrument: .piano)
        var loads = 0
        let factory = PracticePassageFactory(source: .midi(load: {
            loads += 1
            // Any readable file stands in for the copy; the passage itself is not used here.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("practice-test-\(UUID().uuidString).mid")
            try? Data([0]).write(to: url)
            return url
        }))
        XCTAssertFalse(factory.loaded)
        let firstLoad = await factory.load()
        XCTAssertTrue(firstLoad)
        XCTAssertEqual(loads, 1)
        factory.cleanUp()
        XCTAssertFalse(factory.loaded, "a cleaned-up MIDI source must not claim to be loaded")
        let secondLoad = await factory.load()
        XCTAssertTrue(secondLoad)
        XCTAssertEqual(loads, 2, "load() copies the MIDI file again")
        factory.cleanUp()

        // Sources without I/O stay loaded.
        let fixed = PracticePassageFactory(source: .passage(passage))
        fixed.cleanUp()
        XCTAssertTrue(fixed.loaded)
    }

    func testSessionHandleClosesOnce() {
        let handle = PracticeSessionHandle()
        var closes = 0
        handle.close()                       // nothing registered: no-op
        handle.register { closes += 1 }
        handle.close()
        handle.close()
        XCTAssertEqual(closes, 1)
    }

    func testViewerDisappearUnderPresentationIsNotALeave() {
        let session = TabViewerLifecycle.Session(depth: 1)
        XCTAssertTrue(session.isCovered(path: [.viewer]), "full-screen cover over the viewer")
        XCTAssertFalse(session.isCovered(path: []), "popped back to the library")
        XCTAssertFalse(session.isCovered(path: [.viewer, .tuner]), "another page pushed on top")
        let fromTutor = TabViewerLifecycle.Session(depth: 2)
        XCTAssertTrue(fromTutor.isCovered(path: [.tutor, .viewer]))
        XCTAssertFalse(fromTutor.isCovered(path: [.tutor]))
    }

    func testBassPartsUseTheBassProfile() {
        XCTAssertTrue(PracticeDefaults.isBass(trackInstrument: .bass, fileInstruments: [.guitar], openStringMIDI: nil))
        XCTAssertFalse(PracticeDefaults.isBass(trackInstrument: .guitar, fileInstruments: [.bass], openStringMIDI: nil))
        // Four-string bass tab (E1 A1 D2 G2, high string first) and a standard guitar tab.
        XCTAssertTrue(PracticeDefaults.isBass(trackInstrument: nil, fileInstruments: [], openStringMIDI: [43, 38, 33, 28]))
        XCTAssertFalse(PracticeDefaults.isBass(trackInstrument: nil, fileInstruments: [.bass],
                                               openStringMIDI: [64, 59, 55, 50, 45, 40]))
        // Drop D (D2) is still guitar; a baritone B1 is not.
        XCTAssertFalse(PracticeDefaults.isBass(trackInstrument: nil, fileInstruments: [], openStringMIDI: [64, 59, 55, 50, 45, 38]))
        XCTAssertTrue(PracticeDefaults.isBass(trackInstrument: nil, fileInstruments: [], openStringMIDI: [59, 54, 50, 45, 40, 35]))
        // Without a tab or track: a bass-only file.
        XCTAssertTrue(PracticeDefaults.isBass(trackInstrument: nil, fileInstruments: [.bass], openStringMIDI: nil))
        XCTAssertFalse(PracticeDefaults.isBass(trackInstrument: nil, fileInstruments: [.bass, .guitar], openStringMIDI: nil))

        var context = PracticeScoreContext(scoreKey: "k", title: "T", source: .passage(
            PassageBuilder.sequence([40, 45], bpm: 90, instrument: .guitar)), totalMeasures: 1, initialRange: nil,
            referenceBPM: nil, tempoPercent: 100, instrument: .guitar)
        XCTAssertEqual(context.listeningProfile(for: .guitar), .acousticGuitar)
        let low = PassageBuilder.sequence([28, 33, 40], bpm: 90, instrument: .guitar)
        XCTAssertEqual(context.listeningProfile(for: .guitar, passage: low), .bassGuitar)
        context.isBass = true
        XCTAssertEqual(context.listeningProfile(for: .guitar), .bassGuitar)
        XCTAssertEqual(context.listeningProfile(for: .piano), .piano)
    }

    func testNoReadingTakesStayOutOfTheHeatmap() {
        let day: TimeInterval = 86_400
        let heard = PracticeTakeSummary(id: UUID(), date: Date(timeIntervalSince1970: day), measures: 0...1, bpm: 80,
                                        accuracy: 0.8, timingMADms: nil, measureAccuracy: [0: 0.7, 1: 0.9],
                                        hasAudio: false)
        let unheard = PracticeTakeSummary(id: UUID(), date: Date(timeIntervalSince1970: 2 * day), measures: 2...3,
                                          bpm: 80, accuracy: 0, timingMADms: nil, measureAccuracy: [2: 0],
                                          hasAudio: true, hasReading: false)
        let heatmap = PracticeHeatmap(takes: [heard, unheard])
        XCTAssertEqual(heatmap.measures, [0, 1])
        XCTAssertEqual(heatmap.rows.map(\.accuracy), [0.8, nil])
        XCTAssertTrue(heatmap.rows[1].cells.isEmpty)
        XCTAssertNil(heatmap.meanByMeasure[2])
    }

    func testStoredAllUncertainTakeHasNoReading() throws {
        let store = try TutorStore.inMemory()
        store.compressesTakeAudio = false
        let uncertain = TakeAnalysis(graded: [GradedEvent(expectedID: 0, grade: .uncertain, matchedPitches: [],
                                                          missingPitches: [60], wrongPitches: [], playedTime: nil,
                                                          timingOffsetMs: nil, confidence: 0.2)],
                                     extras: [], tempoCurve: [], targetBPM: 90, accuracy: 0, timingMADms: nil,
                                     measureAccuracy: [:], measureTendency: [:], suggestions: [])
        let record = try store.saveTake(scoreKey: "k", scoreTitle: "T", measures: 0...0, bpm: 90, analysis: uncertain)
        let summary = PracticeTakeSummary(record: record, store: store)
        XCTAssertFalse(summary.hasReading)
    }
}
