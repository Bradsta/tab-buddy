//
//  TutorModels.swift
//  TabBuddy
//
//  SwiftData models for the Tutor's own store (TUTOR_IMPLEMENTATION.md §5).
//  These live only in `TutorStore`'s container and are never registered with
//  the library `cloud`/`local` stores.
//

import Foundation
import SwiftData

enum LessonProgressStatus: String, Codable, Sendable {
    case notStarted, inProgress, completed
}

@Model
final class LessonProgressRecord {
    var lessonID: String = ""
    /// `TutorInstrument.rawValue`.
    var instrument: String = TutorInstrument.guitar.rawValue
    /// `LessonProgressStatus.rawValue`.
    var status: String = LessonProgressStatus.notStarted.rawValue
    var bestScore: Double = 0
    var attempts: Int = 0
    var completedAt: Date?
    var updatedAt: Date = Date()

    init(lessonID: String, instrument: TutorInstrument) {
        self.lessonID = lessonID
        self.instrument = instrument.rawValue
    }

    var progressStatus: LessonProgressStatus {
        get { LessonProgressStatus(rawValue: status) ?? .notStarted }
        set { status = newValue.rawValue }
    }
}

@Model
final class ReviewCardRecord {
    var itemID: String = ""
    var instrument: String = TutorInstrument.guitar.rawValue
    /// Curriculum `ReviewKind.rawValue`.
    var kind: String = ""
    var prompt: String = ""
    var answer: String = ""
    var due: Date = Date()
    var stability: Double = 0
    var difficulty: Double = 0
    var reps: Int = 0
    var lapses: Int = 0
    var lastReview: Date?

    init(itemID: String, instrument: TutorInstrument, kind: String, prompt: String, answer: String,
         due: Date = Date(), stability: Double = 0, difficulty: Double = 0) {
        self.itemID = itemID
        self.instrument = instrument.rawValue
        self.kind = kind
        self.prompt = prompt
        self.answer = answer
        self.due = due
        self.stability = stability
        self.difficulty = difficulty
    }
}

@Model
final class PracticeTakeRecord {
    var id: UUID = UUID()
    /// `FileItem.id` UUID string of the practiced score.
    var scoreKey: String = ""
    var scoreTitle: String = ""
    var date: Date = Date()
    /// 0-based global measure indices of the practiced range.
    var firstMeasure: Int = 0
    var lastMeasure: Int = 0
    /// Tempo the take was played at (score BPM × practice speed).
    var bpm: Double = 0
    var accuracy: Double = 0
    var timingMADms: Double?
    /// JSON-encoded `TakeAnalysis`.
    var analysisJSON: Data = Data()
    /// File name inside `Application Support/Tutor/Takes/`; nil once pruned.
    var audioFileName: String?

    init(id: UUID = UUID(), scoreKey: String, scoreTitle: String, date: Date = Date(),
         firstMeasure: Int, lastMeasure: Int, bpm: Double, accuracy: Double, timingMADms: Double?,
         analysisJSON: Data, audioFileName: String? = nil) {
        self.id = id
        self.scoreKey = scoreKey
        self.scoreTitle = scoreTitle
        self.date = date
        self.firstMeasure = firstMeasure
        self.lastMeasure = lastMeasure
        self.bpm = bpm
        self.accuracy = accuracy
        self.timingMADms = timingMADms
        self.analysisJSON = analysisJSON
        self.audioFileName = audioFileName
    }

    /// Decoded analysis; nil if the JSON is unreadable.
    var analysis: TakeAnalysis? {
        try? JSONDecoder().decode(TakeAnalysis.self, from: analysisJSON)
    }
}

@Model
final class CalibrationRecord {
    /// Audio route identifier (e.g. output port type).
    var routeKey: String = ""
    var latencySeconds: Double = 0
    var date: Date = Date()

    init(routeKey: String, latencySeconds: Double, date: Date = Date()) {
        self.routeKey = routeKey
        self.latencySeconds = latencySeconds
        self.date = date
    }
}

@Model
final class TutorSettingsRecord {
    var currentInstrument: String = TutorInstrument.guitar.rawValue
    var dailyGoalMinutes: Int = 10

    init(currentInstrument: TutorInstrument = .guitar, dailyGoalMinutes: Int = 10) {
        self.currentInstrument = currentInstrument.rawValue
        self.dailyGoalMinutes = dailyGoalMinutes
    }

    var instrument: TutorInstrument {
        get { TutorInstrument(rawValue: currentInstrument) ?? .guitar }
        set { currentInstrument = newValue.rawValue }
    }
}
