//
//  TakeReviewModel.swift
//  TabBuddy
//
//  Pure computations behind the take review (TUTOR_PLAN.md §3.1): note
//  marks per measure, extras, legend counts, weakest measures, the tempo
//  ribbon in measure coordinates, the playback cursor, and the per-measure
//  history heatmap. No SwiftUI, so tests cover it directly.
//

import Foundation

struct TakeReviewModel {

    struct NoteMark: Identifiable, Hashable {
        var id: Int
        var measureIndex: Int
        /// 0..<1 within the measure.
        var position: Double
        var beat: Double
        var pitches: [Int]
        /// nil = not graded (no pitches).
        var grade: EventGrade?
        var matched: [Int]
        var missing: [Int]
        var wrong: [Int]
        var timingOffsetMs: Double?
        var playedTime: Double?
        var chordName: String?
    }

    struct ExtraMark: Hashable {
        var measureIndex: Int
        var position: Double
        var pitch: Int
    }

    struct TempoPoint: Hashable, Identifiable {
        var id: Double { measurePosition }
        /// Global measure index + fraction.
        var measurePosition: Double
        var bpm: Double
    }

    let analysis: TakeAnalysis
    let passage: ExpectedPassage?
    let latency: Double
    let marks: [NoteMark]
    let extras: [ExtraMark]
    /// Measures covered by the take, ascending.
    let measures: [Int]

    init(archive: PracticeTakeArchive) {
        self.init(analysis: archive.analysis, passage: archive.passage, latency: archive.latency ?? 0)
    }

    init(analysis: TakeAnalysis, passage: ExpectedPassage?, latency: Double = 0) {
        self.analysis = analysis
        self.passage = passage
        self.latency = latency
        let gradedByID = Dictionary(analysis.graded.map { ($0.expectedID, $0) }, uniquingKeysWith: { a, _ in a })
        var marks: [NoteMark] = []
        if let passage {
            for e in passage.events {
                let g = gradedByID[e.id]
                marks.append(NoteMark(id: e.id, measureIndex: e.measureIndex, position: e.positionInMeasure,
                                      beat: e.beat, pitches: e.pitches, grade: e.pitches.isEmpty ? nil : (g?.grade ?? .missed),
                                      matched: g?.matchedPitches ?? [], missing: g?.missingPitches ?? e.pitches,
                                      wrong: g?.wrongPitches ?? [], timingOffsetMs: g?.timingOffsetMs,
                                      playedTime: g?.playedTime, chordName: e.chordName))
            }
        }
        self.marks = marks
        let markByID = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.extras = analysis.extras.map { extra in
            if let id = extra.afterExpectedID, let m = markByID[id] {
                return ExtraMark(measureIndex: m.measureIndex, position: min(0.999, m.position + 0.04), pitch: extra.pitch)
            }
            let first = marks.first
            return ExtraMark(measureIndex: first?.measureIndex ?? 0, position: 0, pitch: extra.pitch)
        }
        let fromMarks = Set(marks.map(\.measureIndex))
        let fromAnalysis = Set(analysis.measureAccuracy.keys)
        self.measures = fromMarks.union(fromAnalysis).sorted()
    }

    // MARK: Layout

    /// Consecutive groups of `measuresPerRow` measures (the note strip's systems).
    func rows(measuresPerRow: Int) -> [[Int]] {
        let n = max(1, measuresPerRow)
        return stride(from: 0, to: measures.count, by: n).map { Array(measures[$0..<min(measures.count, $0 + n)]) }
    }

    func marks(inMeasure m: Int) -> [NoteMark] { marks.filter { $0.measureIndex == m } }
    func extras(inMeasure m: Int) -> [ExtraMark] { extras.filter { $0.measureIndex == m } }

    /// Pitch range to draw (padded, at least an octave).
    var pitchRange: ClosedRange<Int> {
        let all = marks.flatMap { $0.pitches + $0.wrong } + extras.map(\.pitch)
        guard let lo = all.min(), let hi = all.max() else { return 48...72 }
        let pad = max(2, (12 - (hi - lo)) / 2)
        return (lo - pad)...(hi + pad)
    }

    // MARK: Summary

    /// False when no event could be graded; show "couldn't hear clearly", not 0%.
    var hasReading: Bool { analysis.hasReading }

    /// Accuracy for display; nil without a reading.
    var displayAccuracy: Double? { hasReading ? analysis.accuracy : nil }

    /// Counts per grade over graded events, plus extras under `nil`.
    var legendCounts: [EventGrade?: Int] {
        var counts: [EventGrade?: Int] = [:]
        for m in marks { if let g = m.grade { counts[g, default: 0] += 1 } }
        if !extras.isEmpty { counts[nil] = extras.count }
        return counts
    }

    func count(_ grade: EventGrade) -> Int { legendCounts[grade] ?? 0 }

    /// Lowest-accuracy measures, ascending by accuracy then measure.
    func weakestMeasures(limit: Int = 3, below threshold: Double = 0.999) -> [(measure: Int, accuracy: Double)] {
        analysis.measureAccuracy
            .filter { $0.value < threshold }
            .sorted { ($0.value, $0.key) < ($1.value, $1.key) }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }

    // MARK: Beat ↔ measure

    private var barBeats: Double {
        guard let passage else { return 4 }
        return TempoAnalyzer.measureLengthBeats(passage)
    }

    private var measureStarts: [Int: Double] {
        guard let passage else { return [:] }
        return TempoAnalyzer.measureStartBeats(passage, barBeats: barBeats)
    }

    /// Passage beat → global measure index + fraction.
    func measurePosition(ofBeat beat: Double) -> Double {
        let starts = measureStarts
        let bar = max(1e-6, barBeats)
        guard let first = starts.min(by: { $0.value < $1.value }) else { return beat / bar }
        let candidates = starts.filter { $0.value <= beat + 1e-9 }
        let (m, start) = candidates.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) } ?? (first.key, first.value)
        return Double(m) + (beat - start) / bar
    }

    /// The tempo curve in measure coordinates.
    var tempoPoints: [TempoPoint] {
        analysis.tempoCurve.map { TempoPoint(measurePosition: measurePosition(ofBeat: $0.beat), bpm: $0.bpm) }
            .sorted { $0.measurePosition < $1.measurePosition }
    }

    /// Consecutive measures with the same tendency as `measure` (tap-to-loop).
    /// Steady or unknown measures loop with their neighbor.
    func loopRegion(around measure: Int) -> ClosedRange<Int> {
        guard let lo = measures.first, let hi = measures.last else { return measure...measure }
        let m = max(lo, min(hi, measure))
        let tendency = analysis.measureTendency[m] ?? .unknown
        guard tendency == .rushing || tendency == .dragging else {
            return m...min(hi, m + 1)
        }
        var a = m, b = m
        while a - 1 >= lo, analysis.measureTendency[a - 1] == tendency { a -= 1 }
        while b + 1 <= hi, analysis.measureTendency[b + 1] == tendency { b += 1 }
        return a...b
    }

    // MARK: Playback cursor

    /// Passage beat at a time in the take audio, interpolated between heard notes.
    func beat(atAudioTime t: Double) -> Double? {
        var anchors: [(time: Double, beat: Double)] = []
        for m in marks.sorted(by: { $0.beat < $1.beat }) {
            guard let played = m.playedTime, m.grade == .hit || m.grade == .partial else { continue }
            let time = played + latency
            if let last = anchors.last, time <= last.time { continue }
            anchors.append((time, m.beat))
        }
        guard let first = anchors.first else { return nil }
        if anchors.count == 1 || t <= first.time {
            let spb = 60 / max(1, analysis.targetBPM)
            return first.beat + (t - first.time) / spb
        }
        for i in 1..<anchors.count where t <= anchors[i].time {
            let a = anchors[i - 1], b = anchors[i]
            return a.beat + (t - a.time) / (b.time - a.time) * (b.beat - a.beat)
        }
        let a = anchors[anchors.count - 2], b = anchors[anchors.count - 1]
        let slope = (b.beat - a.beat) / max(1e-6, b.time - a.time)
        return b.beat + (t - b.time) * slope
    }

    // MARK: Names

    static func name(_ midi: Int) -> String { NoteNaming.displayName(midi: midi) }
    static func names(_ midis: [Int]) -> String { midis.sorted().map(name).joined(separator: " ") }

    /// Spoken/visible description of one mark.
    static func describe(_ m: NoteMark) -> String {
        let expected = m.chordName ?? names(m.pitches)
        switch m.grade {
        case .hit: return "\(expected): heard"
        case .partial: return "\(expected): missing \(names(m.missing))"
        case .wrongPitch:
            return m.wrong.isEmpty ? "\(expected): other notes heard" : "\(expected): heard \(names(m.wrong)) instead"
        case .missed: return "\(expected): not heard"
        case .uncertain: return "\(expected): not sure"
        case nil: return expected
        }
    }
}

// MARK: - History heatmap

struct PracticeHeatmap {
    struct Row: Identifiable, Hashable {
        var id: UUID
        var date: Date
        /// nil when the take had no reading (every event uncertain).
        var accuracy: Double?
        /// Accuracy per measure; absent = not practiced in that take, or not heard clearly.
        var cells: [Int: Double]
    }

    /// Union of practiced measures, ascending.
    let measures: [Int]
    /// Oldest first.
    let rows: [Row]

    /// - Parameter limit: newest takes kept.
    init(takes: [PracticeTakeSummary], limit: Int = 12) {
        let recent = takes.sorted { $0.date > $1.date }.prefix(limit).sorted { $0.date < $1.date }
        // Takes with no reading contribute no cells: their stored 0 is not a score.
        rows = recent.map { Row(id: $0.id, date: $0.date, accuracy: $0.hasReading ? $0.accuracy : nil,
                                cells: $0.hasReading ? $0.measureAccuracy : [:]) }
        measures = Array(Set(rows.flatMap { $0.cells.keys })).sorted()
    }

    var isEmpty: Bool { rows.isEmpty || measures.isEmpty }

    /// Mean accuracy per measure across the rows that include it.
    var meanByMeasure: [Int: Double] {
        var sums: [Int: (Double, Int)] = [:]
        for row in rows {
            for (m, a) in row.cells { sums[m, default: (0, 0)].0 += a; sums[m, default: (0, 0)].1 += 1 }
        }
        return sums.mapValues { $0.0 / Double($0.1) }
    }

    /// Latest minus earliest accuracy for a measure (needs two takes that include it).
    func trend(forMeasure m: Int) -> Double? {
        let values = rows.compactMap { $0.cells[m] }
        guard values.count >= 2, let first = values.first, let last = values.last else { return nil }
        return last - first
    }
}
