//
//  TutorStore.swift
//  TabBuddy
//
//  The Tutor's own SwiftData container (TUTOR_IMPLEMENTATION.md §5):
//  `Application Support/Tutor/tutor.store`, local only, no CloudKit. Take audio
//  lives beside it in `Application Support/Tutor/Takes/` (excluded from
//  backup), re-encoded to AAC after saving and capped per score and overall.
//  The library `cloud`/`local` stores are neither opened nor modified here.
//

import AVFoundation
import Foundation
import SwiftData

@MainActor
final class TutorStore {

    static let schema = Schema([LessonProgressRecord.self, ReviewCardRecord.self, PracticeTakeRecord.self,
                                CalibrationRecord.self, TutorSettingsRecord.self])

    /// Audio files kept per score; older takes keep their records but lose audio.
    nonisolated static let takeAudioLimit = 10
    /// Audio kept across all scores: at most this many files…
    nonisolated static let globalTakeAudioCount = 200
    /// …and at most this many bytes. The oldest audio goes first; records stay.
    nonisolated static let globalTakeAudioBytes: Int64 = 500 * 1024 * 1024

    /// Re-encode saved take audio to AAC (m4a) in the background. Off for
    /// tests that inspect the moved file.
    var compressesTakeAudio = true
    /// The running AAC encode per take (tests await it).
    private(set) var pendingCompressions: [UUID: Task<Void, Never>] = [:]

    /// App-wide store at `Application Support/Tutor/`. Falls back to memory if the file store cannot open.
    static let shared: TutorStore = {
        do {
            return try TutorStore(directory: defaultDirectory)
        } catch {
            print("[TutorStore] on-disk store failed (\(error)); using an in-memory store for this session.")
            return try! TutorStore.inMemory()
        }
    }()

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tutor", isDirectory: true)
    }

    let container: ModelContainer
    let takesDirectory: URL
    var context: ModelContext { container.mainContext }

    /// Opens (or creates) `directory/tutor.store`; take audio goes to `directory/Takes/`.
    init(directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        takesDirectory = directory.appendingPathComponent("Takes", isDirectory: true)
        try fm.createDirectory(at: takesDirectory, withIntermediateDirectories: true)
        Self.excludeFromBackup(takesDirectory)
        let config = ModelConfiguration("tutor", schema: Self.schema,
                                        url: directory.appendingPathComponent("tutor.store"),
                                        cloudKitDatabase: .none)
        container = try ModelContainer(for: Self.schema, configurations: [config])
    }

    /// In-memory records; take audio goes to `takesDirectory` (a fresh temp folder by default).
    init(inMemoryWithTakesDirectory takes: URL) throws {
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
        takesDirectory = takes
        Self.excludeFromBackup(takes)
        let config = ModelConfiguration("tutor-memory", schema: Self.schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        container = try ModelContainer(for: Self.schema, configurations: [config])
    }

    static func inMemory() throws -> TutorStore {
        try TutorStore(inMemoryWithTakesDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("TutorTakes-\(UUID().uuidString)", isDirectory: true))
    }

    func save() throws {
        if context.hasChanges { try context.save() }
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Lesson progress

    func progress(lessonID: String, instrument: TutorInstrument) -> LessonProgressRecord? {
        let raw = instrument.rawValue
        var d = FetchDescriptor<LessonProgressRecord>(predicate: #Predicate { $0.lessonID == lessonID && $0.instrument == raw })
        d.fetchLimit = 1
        return fetch(d).first
    }

    func allProgress(instrument: TutorInstrument) -> [LessonProgressRecord] {
        let raw = instrument.rawValue
        return fetch(FetchDescriptor(predicate: #Predicate<LessonProgressRecord> { $0.instrument == raw },
                                     sortBy: [SortDescriptor(\.lessonID)]))
    }

    /// Records one attempt: bumps `attempts`, keeps the best score, and marks completion.
    @discardableResult
    func recordLessonAttempt(lessonID: String, instrument: TutorInstrument, score: Double,
                             completed: Bool, date: Date = Date()) throws -> LessonProgressRecord {
        let record = progress(lessonID: lessonID, instrument: instrument) ?? {
            let r = LessonProgressRecord(lessonID: lessonID, instrument: instrument)
            context.insert(r)
            return r
        }()
        record.attempts += 1
        record.bestScore = max(record.bestScore, score)
        record.updatedAt = date
        if completed {
            if record.progressStatus != .completed { record.completedAt = date }
            record.progressStatus = .completed
        } else if record.progressStatus == .notStarted {
            record.progressStatus = .inProgress
        }
        try save()
        return record
    }

    /// Marks a lesson done (skipped ahead) or back to not started without
    /// recording an attempt. Best score and attempt count are kept.
    @discardableResult
    func setLessonCompleted(lessonID: String, instrument: TutorInstrument, completed: Bool,
                            date: Date = Date()) throws -> LessonProgressRecord {
        let record = progress(lessonID: lessonID, instrument: instrument) ?? {
            let r = LessonProgressRecord(lessonID: lessonID, instrument: instrument)
            context.insert(r)
            return r
        }()
        record.updatedAt = date
        if completed {
            if record.progressStatus != .completed { record.completedAt = date }
            record.progressStatus = .completed
        } else {
            record.completedAt = nil
            record.progressStatus = record.attempts > 0 ? .inProgress : .notStarted
        }
        try save()
        return record
    }

    // MARK: - Review cards

    func reviewCard(itemID: String, instrument: TutorInstrument) -> ReviewCardRecord? {
        let raw = instrument.rawValue
        var d = FetchDescriptor<ReviewCardRecord>(predicate: #Predicate { $0.itemID == itemID && $0.instrument == raw })
        d.fetchLimit = 1
        return fetch(d).first
    }

    /// Inserts a card unless one with the same item and instrument exists; returns the stored card.
    @discardableResult
    func addReviewCardIfMissing(_ card: ReviewCardRecord) throws -> ReviewCardRecord {
        let instrument = TutorInstrument(rawValue: card.instrument) ?? .guitar
        if let existing = reviewCard(itemID: card.itemID, instrument: instrument) { return existing }
        context.insert(card)
        try save()
        return card
    }

    func dueReviewCards(instrument: TutorInstrument, asOf date: Date = Date(), limit: Int? = nil) -> [ReviewCardRecord] {
        let raw = instrument.rawValue
        var d = FetchDescriptor<ReviewCardRecord>(predicate: #Predicate { $0.instrument == raw && $0.due <= date },
                                                  sortBy: [SortDescriptor(\.due)])
        d.fetchLimit = limit
        return fetch(d)
    }

    func dueReviewCount(instrument: TutorInstrument, asOf date: Date = Date()) -> Int {
        let raw = instrument.rawValue
        let d = FetchDescriptor<ReviewCardRecord>(predicate: #Predicate { $0.instrument == raw && $0.due <= date })
        return (try? context.fetchCount(d)) ?? 0
    }

    // MARK: - Practice takes

    /// Takes for a score, newest first.
    func takes(forScore scoreKey: String) -> [PracticeTakeRecord] {
        fetch(FetchDescriptor(predicate: #Predicate<PracticeTakeRecord> { $0.scoreKey == scoreKey },
                              sortBy: [SortDescriptor(\.date, order: .reverse)]))
    }

    /// Saves a take. When `audioURL` is given the file is moved into `takesDirectory`
    /// and, when `compressesTakeAudio` is on, re-encoded to AAC in the background
    /// (the original stays if encoding fails). Afterwards only the `takeAudioLimit`
    /// newest takes of the score keep audio, and the oldest audio across all scores
    /// goes beyond `globalTakeAudioCount` files or `globalTakeAudioBytes`.
    @discardableResult
    func saveTake(scoreKey: String, scoreTitle: String, measures: ClosedRange<Int>, bpm: Double,
                  analysis: TakeAnalysis, audioURL: URL? = nil, date: Date = Date()) throws -> PracticeTakeRecord {
        let id = UUID()
        var audioName: String?
        if let audioURL {
            let ext = audioURL.pathExtension.isEmpty ? "caf" : audioURL.pathExtension
            let name = "\(id.uuidString).\(ext)"
            try FileManager.default.moveItem(at: audioURL, to: takesDirectory.appendingPathComponent(name))
            audioName = name
        }
        let record = PracticeTakeRecord(id: id, scoreKey: scoreKey, scoreTitle: scoreTitle, date: date,
                                        firstMeasure: measures.lowerBound, lastMeasure: measures.upperBound,
                                        bpm: bpm, accuracy: analysis.accuracy, timingMADms: analysis.timingMADms,
                                        analysisJSON: try JSONEncoder().encode(analysis), audioFileName: audioName)
        context.insert(record)
        try save()
        try pruneTakeAudio(forScore: scoreKey)
        try pruneTakeAudioGlobally()
        if compressesTakeAudio, record.audioFileName != nil { scheduleCompression(of: record) }
        return record
    }

    func audioURL(for take: PracticeTakeRecord) -> URL? {
        guard let name = take.audioFileName else { return nil }
        let url = takesDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Deletes audio beyond the `keeping` newest takes of a score. Records stay.
    func pruneTakeAudio(forScore scoreKey: String, keeping: Int? = nil) throws {
        let keeping = keeping ?? Self.takeAudioLimit
        let withAudio = takes(forScore: scoreKey).filter { $0.audioFileName != nil }
        guard withAudio.count > keeping else { return }
        for take in withAudio.dropFirst(keeping) { try removeAudio(of: take) }
        try save()
    }

    /// Deletes the oldest take audio across all scores until at most `maxCount`
    /// files and `maxBytes` remain. Records and their analyses stay.
    func pruneTakeAudioGlobally(maxCount: Int? = nil, maxBytes: Int64? = nil) throws {
        let maxCount = maxCount ?? Self.globalTakeAudioCount
        let maxBytes = maxBytes ?? Self.globalTakeAudioBytes
        let withAudio = fetch(FetchDescriptor<PracticeTakeRecord>(
            predicate: #Predicate { $0.audioFileName != nil },
            sortBy: [SortDescriptor(\.date, order: .reverse)]))
        var count = 0
        var bytes: Int64 = 0
        var changed = false
        for take in withAudio {
            let size = take.audioFileName.map { Self.fileSize(takesDirectory.appendingPathComponent($0)) } ?? 0
            if count + 1 > maxCount || bytes + size > maxBytes {
                try removeAudio(of: take)
                changed = true
            } else {
                count += 1
                bytes += size
            }
        }
        if changed { try save() }
    }

    private func removeAudio(of take: PracticeTakeRecord) throws {
        if let name = take.audioFileName {
            pendingCompressions.removeValue(forKey: take.id)?.cancel()
            let url = takesDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        take.audioFileName = nil
    }

    /// Removes a take record and its audio.
    func deleteTake(_ take: PracticeTakeRecord) throws {
        pendingCompressions.removeValue(forKey: take.id)?.cancel()
        if let url = audioURL(for: take) { try FileManager.default.removeItem(at: url) }
        context.delete(take)
        try save()
    }

    // MARK: - Take audio encoding

    /// Re-encodes a take's audio to AAC off the main thread, then points the
    /// record at the m4a and removes the original. Any failure keeps the original.
    private func scheduleCompression(of record: PracticeTakeRecord) {
        guard let name = record.audioFileName, !name.lowercased().hasSuffix(".m4a") else { return }
        let id = record.id
        let source = takesDirectory.appendingPathComponent(name)
        let destination = takesDirectory.appendingPathComponent("\(id.uuidString).m4a")
        pendingCompressions[id]?.cancel()
        pendingCompressions[id] = Task { [weak self] in
            let encoded = await Task.detached(priority: .utility) {
                Self.encodeAAC(from: source, to: destination)
            }.value
            guard let self else { return }
            self.pendingCompressions.removeValue(forKey: id)
            // The take may have been deleted or pruned meanwhile.
            guard encoded, !Task.isCancelled,
                  let current = self.fetch(FetchDescriptor<PracticeTakeRecord>(predicate: #Predicate { $0.id == id })).first,
                  current.audioFileName == name else {
                if encoded { try? FileManager.default.removeItem(at: destination) }
                return
            }
            current.audioFileName = destination.lastPathComponent
            do {
                try self.save()
                try? FileManager.default.removeItem(at: source)
            } catch {
                current.audioFileName = name
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    /// Waits for background encodes (tests).
    func waitForPendingCompressions() async {
        while let task = pendingCompressions.values.first {
            await task.value
        }
    }

    /// Encodes any readable audio file to mono-or-stereo AAC at 64 kbit/s per
    /// channel. Returns false (and leaves no partial file) on failure.
    nonisolated static func encodeAAC(from source: URL, to destination: URL) -> Bool {
        do {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            guard input.length > 0, format.sampleRate > 0 else { return false }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 64_000 * Int(format.channelCount),
            ]
            try? FileManager.default.removeItem(at: destination)
            let ok: Bool = try {
                let output = try AVAudioFile(forWriting: destination, settings: settings,
                                             commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                let chunk: AVAudioFrameCount = 16_384
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return false }
                while input.framePosition < input.length {
                    try input.read(into: buffer, frameCount: chunk)
                    if buffer.frameLength == 0 { break }
                    try output.write(from: buffer)
                }
                return true
            }()   // `output` closes here, finishing the file
            guard ok, fileSize(destination) > 0 else {
                try? FileManager.default.removeItem(at: destination)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
    }

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Take audio is re-creatable practice material, not user documents.
    nonisolated static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Calibration

    func calibration(forRoute routeKey: String) -> CalibrationRecord? {
        var d = FetchDescriptor<CalibrationRecord>(predicate: #Predicate { $0.routeKey == routeKey },
                                                   sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = 1
        return fetch(d).first
    }

    /// Calibrated output→input latency in seconds for an audio route, if measured.
    func latency(forRoute routeKey: String) -> Double? {
        calibration(forRoute: routeKey)?.latencySeconds
    }

    func setLatency(_ seconds: Double, forRoute routeKey: String, date: Date = Date()) {
        if let existing = calibration(forRoute: routeKey) {
            existing.latencySeconds = seconds
            existing.date = date
        } else {
            context.insert(CalibrationRecord(routeKey: routeKey, latencySeconds: seconds, date: date))
        }
        try? save()
    }

    // MARK: - Settings

    /// The single settings record, created with defaults on first access.
    func settings() -> TutorSettingsRecord {
        if let existing = fetch(FetchDescriptor<TutorSettingsRecord>()).first { return existing }
        let record = TutorSettingsRecord()
        context.insert(record)
        try? save()
        return record
    }
}
