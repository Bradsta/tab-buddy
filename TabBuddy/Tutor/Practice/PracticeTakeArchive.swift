//
//  PracticeTakeArchive.swift
//  TabBuddy
//
//  What practice mode stores in `PracticeTakeRecord.analysisJSON`: the
//  `TakeAnalysis` keys at the top level (so `PracticeTakeRecord.analysis`
//  still decodes) plus the passage and take settings the review needs to
//  redraw an older take. Extra keys are ignored by plain `TakeAnalysis` decoding.
//

import Foundation

enum PracticeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The cursor waits until the expected notes are heard.
    case wait
    /// The cursor moves at the chosen tempo after a visual count-in.
    case playAlong

    var id: String { rawValue }
    var title: String { self == .wait ? "Wait" : "Play-along" }
    var symbol: String { self == .wait ? "hourglass" : "metronome" }
}

struct PracticeTakeArchive: Codable, Sendable {
    var analysis: TakeAnalysis
    var passage: ExpectedPassage?
    var mode: PracticeMode?
    var tempoPercent: Double?
    /// Latency applied to the take's detections (audio time ≈ played time + latency).
    var latency: Double?
    /// Take-clock time of beat 0 in play-along takes.
    var passageStart: Double?

    init(analysis: TakeAnalysis, passage: ExpectedPassage?, mode: PracticeMode?, tempoPercent: Double?,
         latency: Double?, passageStart: Double?) {
        self.analysis = analysis
        self.passage = passage
        self.mode = mode
        self.tempoPercent = tempoPercent
        self.latency = latency
        self.passageStart = passageStart
    }

    private enum ExtraKeys: String, CodingKey {
        case practicePassage, practiceMode, practiceTempoPercent, practiceLatency, practicePassageStart
    }

    init(from decoder: Decoder) throws {
        analysis = try TakeAnalysis(from: decoder)
        let c = try decoder.container(keyedBy: ExtraKeys.self)
        passage = try c.decodeIfPresent(ExpectedPassage.self, forKey: .practicePassage)
        mode = try c.decodeIfPresent(PracticeMode.self, forKey: .practiceMode)
        tempoPercent = try c.decodeIfPresent(Double.self, forKey: .practiceTempoPercent)
        latency = try c.decodeIfPresent(Double.self, forKey: .practiceLatency)
        passageStart = try c.decodeIfPresent(Double.self, forKey: .practicePassageStart)
    }

    func encode(to encoder: Encoder) throws {
        try analysis.encode(to: encoder)
        var c = encoder.container(keyedBy: ExtraKeys.self)
        try c.encodeIfPresent(passage, forKey: .practicePassage)
        try c.encodeIfPresent(mode, forKey: .practiceMode)
        try c.encodeIfPresent(tempoPercent, forKey: .practiceTempoPercent)
        try c.encodeIfPresent(latency, forKey: .practiceLatency)
        try c.encodeIfPresent(passageStart, forKey: .practicePassageStart)
    }

    static func decode(_ data: Data) -> PracticeTakeArchive? {
        try? JSONDecoder().decode(PracticeTakeArchive.self, from: data)
    }
}

/// A value copy of a stored take for lists and the heatmap.
struct PracticeTakeSummary: Identifiable, Hashable, Sendable {
    var id: UUID
    var date: Date
    var measures: ClosedRange<Int>
    var bpm: Double
    var accuracy: Double
    var timingMADms: Double?
    var measureAccuracy: [Int: Double]
    var hasAudio: Bool
    /// False when every event was uncertain: `accuracy` is then meaningless
    /// (stored as 0) and the take shows "couldn't hear clearly".
    var hasReading: Bool

    init(id: UUID, date: Date, measures: ClosedRange<Int>, bpm: Double, accuracy: Double,
         timingMADms: Double?, measureAccuracy: [Int: Double], hasAudio: Bool, hasReading: Bool = true) {
        self.hasReading = hasReading
        self.id = id
        self.date = date
        self.measures = measures
        self.bpm = bpm
        self.accuracy = accuracy
        self.timingMADms = timingMADms
        self.measureAccuracy = measureAccuracy
        self.hasAudio = hasAudio
    }

    @MainActor
    init(record: PracticeTakeRecord, store: TutorStore) {
        let lo = min(record.firstMeasure, record.lastMeasure)
        let hi = max(record.firstMeasure, record.lastMeasure)
        let analysis = record.analysis
        self.init(id: record.id, date: record.date, measures: lo...hi, bpm: record.bpm,
                  accuracy: record.accuracy, timingMADms: record.timingMADms,
                  measureAccuracy: analysis?.measureAccuracy ?? [:],
                  hasAudio: store.audioURL(for: record) != nil,
                  hasReading: analysis?.hasReading ?? true)
    }
}

enum PracticeDateFormat {
    /// YYYY-MM-DD.
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    /// YYYY-MM-DD HH:mm.
    static func dayTime(_ date: Date) -> String { dayTimeFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
