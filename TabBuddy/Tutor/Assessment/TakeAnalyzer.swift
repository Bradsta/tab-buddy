//
//  TakeAnalyzer.swift
//  TabBuddy
//
//  Combines the live verifier results (tier B) with the post-take transcription
//  (tier C), aligns, analyzes tempo, and produces a `TakeAnalysis` with practice
//  suggestions (TUTOR_IMPLEMENTATION.md §5). Pure and offline-testable.
//

import Foundation

struct TakeAnalyzer: Sendable {

    struct Config: Sendable {
        var aligner = PerformanceAligner.Config()
        var tempo = TempoAnalyzer.Config()
        /// Measures below this accuracy are candidates for a loop suggestion.
        var weakMeasureThreshold = 0.85
        /// Loop span bounds, in measures.
        var minLoopMeasures = 2
        var maxLoopMeasures = 4
        /// Loop speed as a fraction of the take's speed.
        var loopSpeedFactor = 0.8
        /// A take at or above this accuracy and below `cleanTimingMs` suggests speeding up.
        var cleanAccuracy = 0.95
        var cleanTimingMs = 45.0
        init() {}
    }

    var config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    /// - Parameters:
    ///   - live: tier-B results from the take (may be empty).
    ///   - detected: tier-C (or monophonic) detections on the take clock (may be empty).
    ///   - tempoScale: practice speed of the take (0.8 = 80%).
    ///   - latencySeconds: extra latency to remove when inputs are not yet corrected.
    ///   - timingReference: `.target` for play-along, `.ownMedian` for wait mode.
    func analyze(passage: ExpectedPassage,
                 live: [VerificationResult],
                 detected: [DetectedEvent],
                 tempoScale: Double = 1,
                 latencySeconds: Double = 0,
                 timingReference: TempoAnalyzer.Reference = .target) -> TakeAnalysis {
        let targetBPM = passage.bpm * tempoScale
        let shifted = latencySeconds == 0 ? detected
            : detected.map { var d = $0; d.time -= latencySeconds; return d }
        let liveShifted = live.map { var r = $0; r.onsetTime -= latencySeconds; return r }

        var graded: [GradedEvent]
        var extras: [ExtraNote] = []
        if !shifted.isEmpty {
            let aligned = PerformanceAligner(config: config.aligner).align(passage: passage, detected: shifted,
                                                                           tempoScale: tempoScale)
            graded = aligned.graded
            extras = aligned.extras
            if !liveShifted.isEmpty { graded = Self.combine(aligned: graded, live: liveShifted) }
        } else {
            graded = Self.fromLive(passage: passage, live: liveShifted)
        }

        let tempo = TempoAnalyzer(config: config.tempo).analyze(graded: graded, passage: passage,
                                                                 targetBPM: targetBPM, reference: timingReference)
        for i in graded.indices { graded[i].timingOffsetMs = tempo.offsetsMs[graded[i].expectedID] }

        let byID = Dictionary(passage.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var creditByMeasure: [Int: (sum: Double, count: Double)] = [:]
        var total = 0.0, count = 0.0
        for g in graded {
            guard let credit = Self.credit(g), let e = byID[g.expectedID] else { continue }
            total += credit; count += 1
            creditByMeasure[e.measureIndex, default: (0, 0)].sum += credit
            creditByMeasure[e.measureIndex, default: (0, 0)].count += 1
        }
        let measureAccuracy = creditByMeasure.mapValues { $0.sum / $0.count }
        // `accuracy` is 0 when nothing was graded (every event uncertain); readers
        // check `hasReading` before showing it (the contract field is non-optional).
        var analysis = TakeAnalysis(graded: graded, extras: extras, tempoCurve: tempo.tempoCurve,
                                    targetBPM: targetBPM, accuracy: count > 0 ? total / count : 0,
                                    timingMADms: tempo.timingMADms, measureAccuracy: measureAccuracy,
                                    measureTendency: tempo.measureTendency, suggestions: [])
        analysis.suggestions = suggestions(for: analysis, tempoScale: tempoScale, timingReference: timingReference)
        return analysis
    }

    // MARK: - Grading helpers

    /// Accuracy credit: nil for uncertain (excluded), pitch fraction for partial.
    static func credit(_ g: GradedEvent) -> Double? {
        switch g.grade {
        case .hit: return 1
        case .partial:
            let total = g.matchedPitches.count + g.missingPitches.count
            return total > 0 ? Double(g.matchedPitches.count) / Double(total) : 0
        case .wrongPitch, .missed: return 0
        case .uncertain: return nil
        }
    }

    private static func rank(_ grade: EventGrade) -> Int {
        switch grade {
        case .hit: return 4
        case .partial: return 3
        case .uncertain: return 2   // benefit of the doubt over an error
        case .wrongPitch: return 1
        case .missed: return 0
        }
    }

    /// Per event, keeps the more favourable of the two sources. Uncertain outranks
    /// wrongPitch so an unsure source never turns into an error.
    static func combine(aligned: [GradedEvent], live: [VerificationResult]) -> [GradedEvent] {
        let liveByID = Dictionary(live.map { ($0.expectedID, $0) }, uniquingKeysWith: { a, b in
            rank(a.grade) >= rank(b.grade) ? a : b })
        return aligned.map { g in
            guard let r = liveByID[g.expectedID], rank(r.grade) > rank(g.grade) else { return g }
            var out = g
            out.grade = r.grade
            let expected = Set(g.matchedPitches + g.missingPitches)
            let heard = Set(r.heard).intersection(expected).union(g.matchedPitches)
            out.matchedPitches = heard.sorted()
            out.missingPitches = expected.subtracting(heard).sorted()
            if r.grade == .hit { out.missingPitches = []; out.matchedPitches = expected.sorted() }
            out.wrongPitches = r.grade == .hit ? [] : Array(Set(g.wrongPitches + r.unexpected)).sorted()
            if r.grade != .missed { out.playedTime = g.playedTime ?? r.onsetTime }
            out.confidence = max(g.confidence, r.confidence)
            return out
        }
    }

    /// Grades from live verification alone (no transcription available).
    static func fromLive(passage: ExpectedPassage, live: [VerificationResult]) -> [GradedEvent] {
        let liveByID = Dictionary(live.map { ($0.expectedID, $0) }, uniquingKeysWith: { a, b in
            rank(a.grade) >= rank(b.grade) ? a : b })
        return passage.events.filter { !$0.pitches.isEmpty }.map { e in
            guard let r = liveByID[e.id] else {
                return GradedEvent(expectedID: e.id, grade: .missed, matchedPitches: [], missingPitches: e.pitches,
                                   wrongPitches: [], playedTime: nil, timingOffsetMs: nil, confidence: 0)
            }
            let heard = r.grade == .hit ? Set(e.pitches) : Set(r.heard).intersection(e.pitches)
            return GradedEvent(expectedID: e.id, grade: r.grade, matchedPitches: heard.sorted(),
                               missingPitches: e.pitches.filter { !heard.contains($0) }.sorted(),
                               wrongPitches: r.unexpected.sorted(),
                               playedTime: r.grade == .missed ? nil : r.onsetTime,
                               timingOffsetMs: nil, confidence: r.confidence)
        }
    }

    // MARK: - Suggestions

    /// - Parameter timingReference: `.ownMedian` (wait mode) has no beat to rush
    ///   or drag against, so drift and timing never drive its suggestions.
    func suggestions(for analysis: TakeAnalysis, tempoScale: Double,
                     timingReference: TempoAnalyzer.Reference = .target) -> [PracticeSuggestion] {
        var out: [PracticeSuggestion] = []
        // Nothing graded: the detector couldn't hear the take clearly, so there is
        // nothing to suggest (the review says so instead of showing 0%).
        guard analysis.hasReading else { return out }
        let measures = analysis.measureAccuracy.keys.sorted()
        let currentPercent = (tempoScale * 100).rounded()
        let timed = timingReference == .target

        // Weakest span of 2–4 consecutive measures.
        if let weakest = weakestSpan(analysis.measureAccuracy), weakest.accuracy < config.weakMeasureThreshold {
            let percent = max(40, (currentPercent * config.loopSpeedFactor / 5).rounded() * 5)
            out.append(PracticeSuggestion(
                message: "Loop \(Self.label(weakest.range)) at \(Int(percent))%",
                loopMeasures: weakest.range, tempoPercent: percent))
        }

        // Tempo drift runs (timed takes only).
        for tendency in [MeasureTendency.rushing, .dragging] where timed {
            let runs = Self.runs(of: measures.filter { analysis.measureTendency[$0] == tendency })
            guard let longest = runs.max(by: { $0.count < $1.count }) else { continue }
            let verb = tendency == .rushing ? "rushed" : "dragged"
            out.append(PracticeSuggestion(
                message: "You \(verb) in \(Self.label(longest)). Loop them with the beat pulse at \(Int(currentPercent))%",
                loopMeasures: longest, tempoPercent: currentPercent))
        }

        // Clean notes: speed up, steady the timing first, or try a longer section.
        guard out.isEmpty, analysis.accuracy >= config.cleanAccuracy else { return out }
        let steady = !timed || (analysis.timingMADms ?? 0) <= config.cleanTimingMs
        if !steady {
            out.append(PracticeSuggestion(
                message: "Notes were clean; the timing wandered. Play it again at \(Int(currentPercent))% with the beat pulse",
                loopMeasures: nil, tempoPercent: currentPercent))
        } else if currentPercent < 100 {
            let next = min(100, currentPercent + 10)
            out.append(PracticeSuggestion(message: "Clean take. Try it at \(Int(next))%",
                                          loopMeasures: nil, tempoPercent: next))
        } else {
            out.append(PracticeSuggestion(message: "Clean take at full speed. Try a longer section",
                                          loopMeasures: nil, tempoPercent: nil))
        }
        return out
    }

    /// Lowest mean-accuracy run of consecutive measures, 2–4 long (shorter if the take is shorter).
    func weakestSpan(_ accuracy: [Int: Double]) -> (range: ClosedRange<Int>, accuracy: Double)? {
        let keys = accuracy.keys.sorted()
        guard !keys.isEmpty else { return nil }
        var best: (range: ClosedRange<Int>, accuracy: Double)?
        let minLen = min(config.minLoopMeasures, keys.count)
        for start in keys.indices {
            var sum = 0.0
            for end in start..<min(keys.count, start + config.maxLoopMeasures) {
                if end > start && keys[end] != keys[end - 1] + 1 { break }
                sum += accuracy[keys[end]] ?? 0
                let length = end - start + 1
                guard length >= minLen else { continue }
                let mean = sum / Double(length)
                // Prefer lower accuracy; on ties prefer the shorter span.
                if best == nil || mean < best!.accuracy - 1e-9 {
                    best = (keys[start]...keys[end], mean)
                }
            }
        }
        return best
    }

    private static func runs(of sorted: [Int]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for m in sorted {
            if let last = out.last, last.upperBound + 1 == m { out[out.count - 1] = last.lowerBound...m }
            else { out.append(m...m) }
        }
        return out
    }

    /// 1-based display label for 0-based measure indices.
    static func label(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound ? "measure \(range.lowerBound + 1)"
            : "measures \(range.lowerBound + 1)–\(range.upperBound + 1)"
    }
}

extension TakeAnalysis {
    /// Events that count toward accuracy (hit, partial, wrong, missed). Zero
    /// means every event was uncertain: `accuracy` is then 0 by construction
    /// and must be shown as "couldn't hear clearly", not as 0%.
    var gradedCount: Int { graded.filter { TakeAnalyzer.credit($0) != nil }.count }

    /// False when the detector couldn't grade a single event.
    var hasReading: Bool { graded.contains { TakeAnalyzer.credit($0) != nil } }
}
