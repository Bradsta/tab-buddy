//
//  TutorStoreTests.swift
//  TabBuddyTests
//
//  WP-C tutor store: CRUD on an in-memory container and take-audio pruning on
//  a file store in a temporary directory.
//

import AVFoundation
import SwiftData
import XCTest
@testable import TabBuddy

@MainActor
final class TutorStoreTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TutorStoreTests-\(UUID().uuidString)")
        tempDirs.append(url)
        return url
    }

    private func sampleAnalysis(accuracy: Double) -> TakeAnalysis {
        TakeAnalysis(graded: [GradedEvent(expectedID: 0, grade: .hit, matchedPitches: [60], missingPitches: [],
                                          wrongPitches: [], playedTime: 0.5, timingOffsetMs: 4, confidence: 0.9)],
                     extras: [], tempoCurve: [TempoSample(beat: 2, bpm: 99)], targetBPM: 100, accuracy: accuracy,
                     timingMADms: 12, measureAccuracy: [0: accuracy], measureTendency: [0: .steady],
                     suggestions: [PracticeSuggestion(message: "Loop measures 1–2 at 80%", loopMeasures: 0...1,
                                                      tempoPercent: 80)])
    }

    func testLessonProgressCRUD() throws {
        let store = try TutorStore(inMemoryWithTakesDirectory: tempDir())
        XCTAssertNil(store.progress(lessonID: "g.0.1", instrument: .guitar))

        try store.recordLessonAttempt(lessonID: "g.0.1", instrument: .guitar, score: 0.6, completed: false)
        var p = try XCTUnwrap(store.progress(lessonID: "g.0.1", instrument: .guitar))
        XCTAssertEqual(p.progressStatus, .inProgress)
        XCTAssertEqual(p.attempts, 1)
        XCTAssertNil(p.completedAt)

        let done = Date(timeIntervalSince1970: 1_800_000_000)
        try store.recordLessonAttempt(lessonID: "g.0.1", instrument: .guitar, score: 0.9, completed: true, date: done)
        try store.recordLessonAttempt(lessonID: "g.0.1", instrument: .guitar, score: 0.7, completed: true)
        p = try XCTUnwrap(store.progress(lessonID: "g.0.1", instrument: .guitar))
        XCTAssertEqual(p.attempts, 3)
        XCTAssertEqual(p.bestScore, 0.9)
        XCTAssertEqual(p.progressStatus, .completed)
        XCTAssertEqual(p.completedAt, done, "first completion date is kept")

        XCTAssertNil(store.progress(lessonID: "g.0.1", instrument: .piano), "progress is per instrument")
        try store.recordLessonAttempt(lessonID: "p.0.1", instrument: .piano, score: 1, completed: true)
        XCTAssertEqual(store.allProgress(instrument: .guitar).map(\.lessonID), ["g.0.1"])
        XCTAssertEqual(store.allProgress(instrument: .piano).map(\.lessonID), ["p.0.1"])
    }

    func testReviewCardsDue() throws {
        let store = try TutorStore(inMemoryWithTakesDirectory: tempDir())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.addReviewCardIfMissing(ReviewCardRecord(itemID: "a", instrument: .guitar, kind: "fact",
                                                          prompt: "Q1", answer: "A1", due: now.addingTimeInterval(-60)))
        try store.addReviewCardIfMissing(ReviewCardRecord(itemID: "b", instrument: .guitar, kind: "fact",
                                                          prompt: "Q2", answer: "A2", due: now.addingTimeInterval(-3600)))
        try store.addReviewCardIfMissing(ReviewCardRecord(itemID: "c", instrument: .guitar, kind: "fact",
                                                          prompt: "Q3", answer: "A3", due: now.addingTimeInterval(86400)))
        try store.addReviewCardIfMissing(ReviewCardRecord(itemID: "d", instrument: .piano, kind: "noteName",
                                                          prompt: "Q4", answer: "A4", due: now.addingTimeInterval(-1)))
        // Duplicate item is not inserted twice.
        let dup = try store.addReviewCardIfMissing(ReviewCardRecord(itemID: "a", instrument: .guitar, kind: "fact",
                                                                    prompt: "other", answer: "other"))
        XCTAssertEqual(dup.prompt, "Q1")

        XCTAssertEqual(store.dueReviewCards(instrument: .guitar, asOf: now).map(\.itemID), ["b", "a"])
        XCTAssertEqual(store.dueReviewCount(instrument: .guitar, asOf: now), 2)
        XCTAssertEqual(store.dueReviewCards(instrument: .piano, asOf: now).map(\.itemID), ["d"])
        XCTAssertEqual(store.dueReviewCards(instrument: .guitar, asOf: now, limit: 1).map(\.itemID), ["b"])

        let card = try XCTUnwrap(store.reviewCard(itemID: "c", instrument: .guitar))
        card.due = now.addingTimeInterval(-1)
        card.reps += 1
        try store.save()
        XCTAssertEqual(store.dueReviewCount(instrument: .guitar, asOf: now), 3)
    }

    func testCalibrationAndSettings() throws {
        let store = try TutorStore(inMemoryWithTakesDirectory: tempDir())
        XCTAssertNil(store.latency(forRoute: "Speaker"))
        store.setLatency(0.085, forRoute: "Speaker")
        store.setLatency(0.21, forRoute: "BluetoothA2DPOutput")
        store.setLatency(0.07, forRoute: "Speaker")
        XCTAssertEqual(store.latency(forRoute: "Speaker"), 0.07)
        XCTAssertEqual(store.latency(forRoute: "BluetoothA2DPOutput"), 0.21)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<CalibrationRecord>()), 2)

        let settings = store.settings()
        XCTAssertEqual(settings.instrument, .guitar)
        settings.instrument = .piano
        settings.dailyGoalMinutes = 20
        try store.save()
        XCTAssertEqual(store.settings().instrument, .piano)
        XCTAssertEqual(store.settings().dailyGoalMinutes, 20)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<TutorSettingsRecord>()), 1)
    }

    func testTakesAndAudioPruningOnDisk() throws {
        let dir = tempDir()
        let store = try TutorStore(directory: dir)
        store.compressesTakeAudio = false   // the placeholder files aren't audio
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tutor.store").path))
        XCTAssertEqual(store.takesDirectory, dir.appendingPathComponent("Takes", isDirectory: true))

        let scratch = tempDir()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var saved: [PracticeTakeRecord] = []
        for i in 0..<12 {
            let audio = scratch.appendingPathComponent("take\(i).caf")
            try Data(repeating: UInt8(i), count: 16).write(to: audio)
            saved.append(try store.saveTake(scoreKey: "score-A", scoreTitle: "Waltz", measures: 0...3, bpm: 80,
                                            analysis: sampleAnalysis(accuracy: Double(i) / 12), audioURL: audio,
                                            date: base.addingTimeInterval(Double(i) * 60)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "audio is moved, not copied")
        }
        // Another score's takes are independent.
        let otherAudio = scratch.appendingPathComponent("other.caf")
        try Data([1]).write(to: otherAudio)
        try store.saveTake(scoreKey: "score-B", scoreTitle: "Other", measures: 2...2, bpm: 60,
                           analysis: sampleAnalysis(accuracy: 1), audioURL: otherAudio, date: base)

        let takes = store.takes(forScore: "score-A")
        XCTAssertEqual(takes.count, 12, "records are kept")
        XCTAssertEqual(takes.first?.date, base.addingTimeInterval(11 * 60), "newest first")
        XCTAssertEqual(takes.prefix(10).filter { store.audioURL(for: $0) != nil }.count, 10)
        XCTAssertTrue(takes.suffix(2).allSatisfy { $0.audioFileName == nil && store.audioURL(for: $0) == nil })
        let files = try FileManager.default.contentsOfDirectory(atPath: store.takesDirectory.path)
        XCTAssertEqual(files.count, 11, "10 for score A + 1 for score B")
        XCTAssertNotNil(store.audioURL(for: try XCTUnwrap(store.takes(forScore: "score-B").first)))

        let newest = try XCTUnwrap(takes.first)
        XCTAssertEqual(newest.firstMeasure, 0)
        XCTAssertEqual(newest.lastMeasure, 3)
        XCTAssertEqual(newest.accuracy, 11.0 / 12, accuracy: 1e-9)
        XCTAssertEqual(newest.timingMADms, 12)
        XCTAssertEqual(newest.analysis, sampleAnalysis(accuracy: 11.0 / 12))

        // Delete removes record and audio.
        let url = try XCTUnwrap(store.audioURL(for: newest))
        try store.deleteTake(newest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.takes(forScore: "score-A").count, 11)

        // A take without audio is fine.
        let silent = try store.saveTake(scoreKey: "score-C", scoreTitle: "C", measures: 0...0, bpm: 90,
                                        analysis: sampleAnalysis(accuracy: 0.5))
        XCTAssertNil(silent.audioFileName)

        // Records persist across reopening the file store.
        let reopened = try TutorStore(directory: dir)
        XCTAssertEqual(reopened.takes(forScore: "score-A").count, 11)
        XCTAssertEqual(reopened.takes(forScore: "score-A").filter { $0.audioFileName != nil }.count, 9)
    }

    func testTutorSchemaIsSeparateFromLibrary() {
        let names = Set(TutorStore.schema.entities.map(\.name))
        XCTAssertEqual(names, ["LessonProgressRecord", "ReviewCardRecord", "PracticeTakeRecord",
                               "CalibrationRecord", "TutorSettingsRecord"])
        let library = TabBuddyApp.makeConfigurations(syncEnabled: false, cloudAvailable: false)
        for config in library {
            let entities = Set(config.schema?.entities.map(\.name) ?? [])
            XCTAssertTrue(entities.isDisjoint(with: names))
        }
    }

    // MARK: Take audio size

    /// A mono Float32 .caf like the listener writes (a 220 Hz tone).
    private func writeTone(to url: URL, seconds: Double = 3, sampleRate: Double = 48_000) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                 channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frames) { data[i] = 0.3 * sin(2 * .pi * 220 * Float(i) / Float(sampleRate)) }
        try file.write(from: buffer)
    }

    func testSavedTakeAudioIsEncodedToAAC() async throws {
        let dir = tempDir()
        let store = try TutorStore(directory: dir)
        let values = try store.takesDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        let scratch = tempDir()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let caf = scratch.appendingPathComponent("take.caf")
        try writeTone(to: caf)
        let rawSize = TutorStore.fileSize(caf)
        let record = try store.saveTake(scoreKey: "s", scoreTitle: "S", measures: 0...1, bpm: 90,
                                        analysis: sampleAnalysis(accuracy: 1), audioURL: caf)
        XCTAssertEqual(record.audioFileName, "\(record.id.uuidString).caf")
        await store.waitForPendingCompressions()
        XCTAssertEqual(record.audioFileName, "\(record.id.uuidString).m4a")
        let m4a = try XCTUnwrap(store.audioURL(for: record))
        XCTAssertLessThan(TutorStore.fileSize(m4a) * 5, rawSize, "AAC is far smaller than Float32 PCM")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.takesDirectory.path),
                       [m4a.lastPathComponent], "the .caf is removed")
        let decoded = try AVAudioFile(forReading: m4a)
        XCTAssertEqual(Double(decoded.length) / decoded.processingFormat.sampleRate, 3, accuracy: 0.1)

        // Unreadable audio keeps the original.
        let junk = scratch.appendingPathComponent("junk.caf")
        try Data(repeating: 7, count: 64).write(to: junk)
        let kept = try store.saveTake(scoreKey: "s", scoreTitle: "S", measures: 0...1, bpm: 90,
                                      analysis: sampleAnalysis(accuracy: 1), audioURL: junk)
        await store.waitForPendingCompressions()
        XCTAssertEqual(kept.audioFileName, "\(kept.id.uuidString).caf")
        XCTAssertNotNil(store.audioURL(for: kept))
    }

    func testGlobalTakeAudioCapPrunesOldestAcrossScores() throws {
        let store = try TutorStore(inMemoryWithTakesDirectory: tempDir())
        store.compressesTakeAudio = false
        let scratch = tempDir()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<6 {
            let audio = scratch.appendingPathComponent("t\(i).caf")
            try Data(repeating: 1, count: 1000).write(to: audio)
            try store.saveTake(scoreKey: "score-\(i % 3)", scoreTitle: "S", measures: 0...0, bpm: 90,
                               analysis: sampleAnalysis(accuracy: 1), audioURL: audio,
                               date: base.addingTimeInterval(Double(i)))
        }
        // By count: keep the 4 newest across all scores.
        try store.pruneTakeAudioGlobally(maxCount: 4, maxBytes: .max)
        var all = (0..<3).flatMap { store.takes(forScore: "score-\($0)") }.sorted { $0.date > $1.date }
        XCTAssertEqual(all.count, 6, "records stay")
        XCTAssertEqual(all.map { $0.audioFileName != nil }, [true, true, true, true, false, false])
        XCTAssertNotNil(all[0].analysis, "analysis is kept without audio")
        // By size: 2500 bytes keeps two 1000-byte files.
        try store.pruneTakeAudioGlobally(maxCount: 100, maxBytes: 2500)
        all = (0..<3).flatMap { store.takes(forScore: "score-\($0)") }.sorted { $0.date > $1.date }
        XCTAssertEqual(all.map { $0.audioFileName != nil }, [true, true, false, false, false, false])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.takesDirectory.path).count, 2)
    }
}
