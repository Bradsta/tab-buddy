//
//  TempoAnalyzer.swift
//  TabBuddy
//
//  Local tempo and timing analysis from matched (beat, time) pairs
//  (TUTOR_IMPLEMENTATION.md §5, TUTOR_PLAN.md §3.2). A sliding window of about
//  two bars is fitted with Theil–Sen regression; each note's offset is measured
//  from that *local* line, which separates uneven notes from gradual drift.
//

import Foundation

struct TempoAnalyzer: Sendable {

    struct Config: Sendable {
        /// Total window width in bars (centered on each note).
        var windowMeasures = 2.0
        /// Minimum matched notes inside a window for a local fit.
        var minPointsPerWindow = 3
        /// Relative tempo deviation still called steady (0.06 = ±6%).
        var steadyTolerance = 0.06
        init() {}
    }

    /// What rushing/dragging is measured against.
    enum Reference: Sendable {
        /// The requested tempo (score BPM × practice speed).
        case target
        /// The player's own median tempo (wait mode, free practice).
        case ownMedian
    }

    struct Point: Hashable, Sendable {
        var expectedID: Int
        var beat: Double
        var time: TimeInterval
        var measureIndex: Int
    }

    struct Report: Hashable, Sendable {
        /// One sample per measure with enough data, at the measure's center beat.
        var tempoCurve: [TempoSample] = []
        /// Per expected event, ms from the local tempo line (negative = early).
        var offsetsMs: [Int: Double] = [:]
        var measureTendency: [Int: MeasureTendency] = [:]
        /// Median absolute per-note offset from the local line, ms.
        var timingMADms: Double?
        /// Take-clock time of beat 0 on the global robust line, after latency removal.
        var globalOffsetSeconds: Double?
        /// Global robust tempo.
        var globalBPM: Double?
    }

    var config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    /// Analyzes the timing of graded events that carry a `playedTime`
    /// (hits and partials only; wrong pitches are not timing evidence).
    func analyze(graded: [GradedEvent], passage: ExpectedPassage, targetBPM: Double,
                 latencySeconds: Double = 0, reference: Reference = .target) -> Report {
        let byID = Dictionary(passage.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let points = graded.compactMap { g -> Point? in
            guard g.grade == .hit || g.grade == .partial, let t = g.playedTime, let e = byID[g.expectedID] else { return nil }
            return Point(expectedID: e.id, beat: e.beat, time: t, measureIndex: e.measureIndex)
        }
        return analyze(points: points, passage: passage, targetBPM: targetBPM,
                       latencySeconds: latencySeconds, reference: reference)
    }

    func analyze(points raw: [Point], passage: ExpectedPassage, targetBPM: Double,
                 latencySeconds: Double = 0, reference: Reference = .target) -> Report {
        var report = Report()
        let measures = Set(passage.events.map(\.measureIndex))
        for m in measures { report.measureTendency[m] = .unknown }
        guard !passage.isFreeTime else { return report }

        let points = raw.map { Point(expectedID: $0.expectedID, beat: $0.beat, time: $0.time - latencySeconds,
                                     measureIndex: $0.measureIndex) }
            .sorted { $0.beat < $1.beat }
        guard points.count >= 2 else { return report }

        let nominalSPB = 60 / max(1, targetBPM > 0 ? targetBPM : passage.bpm)
        let global = RobustStats.theilSen(x: points.map(\.beat), y: points.map(\.time))
        if let global, global.slope > 0 {
            report.globalOffsetSeconds = global.intercept
            report.globalBPM = 60 / global.slope
        }

        let barBeats = Self.measureLengthBeats(passage)
        let halfWindow = barBeats * config.windowMeasures / 2
        var localBPM: [Int: Double] = [:]       // index into points
        for (i, p) in points.enumerated() {
            let window = points.filter { abs($0.beat - p.beat) <= halfWindow + 1e-9 }
            var line: (slope: Double, intercept: Double)?
            if window.count >= config.minPointsPerWindow,
               (window.last!.beat - window.first!.beat) >= barBeats * 0.5,
               let fit = RobustStats.theilSen(x: window.map(\.beat), y: window.map(\.time)),
               fit.slope > nominalSPB * 0.25, fit.slope < nominalSPB * 4 {
                line = fit
                localBPM[i] = 60 / fit.slope
            } else if let global, global.slope > 0 {
                line = global
            }
            if let line {
                report.offsetsMs[p.expectedID] = (p.time - (line.intercept + line.slope * p.beat)) * 1000
            }
        }
        report.timingMADms = RobustStats.median(report.offsetsMs.values.map(abs))

        // Per-measure tempo = median of local estimates of its notes.
        let starts = Self.measureStartBeats(passage, barBeats: barBeats)
        var perMeasure: [Int: Double] = [:]
        for m in measures.sorted() {
            let values = points.indices.filter { points[$0].measureIndex == m }.compactMap { localBPM[$0] }
            guard let bpm = RobustStats.median(values) else { continue }
            perMeasure[m] = bpm
            report.tempoCurve.append(TempoSample(beat: (starts[m] ?? 0) + barBeats / 2, bpm: bpm))
        }
        let ref: Double? = {
            switch reference {
            case .target where targetBPM > 0: return targetBPM
            default: return RobustStats.median(Array(perMeasure.values))
            }
        }()
        if let ref, ref > 0 {
            for (m, bpm) in perMeasure {
                let deviation = bpm / ref - 1
                report.measureTendency[m] = deviation > config.steadyTolerance ? .rushing
                    : deviation < -config.steadyTolerance ? .dragging : .steady
            }
        }
        return report
    }

    // MARK: - Measure geometry

    /// Beats per measure estimated from event positions (median over cross-measure pairs).
    static func measureLengthBeats(_ passage: ExpectedPassage) -> Double {
        let events = passage.events.sorted { $0.beat < $1.beat }
        var estimates: [Double] = []
        for (a, b) in zip(events, events.dropFirst()) where b.measureIndex != a.measureIndex {
            let span = Double(b.measureIndex - a.measureIndex) + b.positionInMeasure - a.positionInMeasure
            if span > 1e-6 { estimates.append((b.beat - a.beat) / span) }
        }
        if let m = RobustStats.median(estimates), m > 0 { return m }
        return Double(max(1, passage.beatsPerMeasure))
    }

    static func measureStartBeats(_ passage: ExpectedPassage, barBeats: Double) -> [Int: Double] {
        var grouped: [Int: [Double]] = [:]
        for e in passage.events { grouped[e.measureIndex, default: []].append(e.beat - e.positionInMeasure * barBeats) }
        return grouped.compactMapValues { RobustStats.median($0) }
    }
}
