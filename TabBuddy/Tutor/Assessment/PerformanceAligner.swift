//
//  PerformanceAligner.swift
//  TabBuddy
//
//  Global alignment of what the listener heard to what the score expects
//  (TUTOR_IMPLEMENTATION.md §5). Generalizes the order-based Needleman–Wunsch in
//  `.diag/authbench.swift`:
//   • one cell compares an expected pitch set with a detected onset cluster
//     (Jaccard-style similarity with half credit for octave errors);
//   • a saturating timing cost against a tempo line estimated from a first,
//     pitch-only pass keeps repeated pitches in order but never outweighs a
//     correct pitch, so skipped or repeated sections still align;
//   • low-confidence detections can only produce `uncertain`, never `wrongPitch`.
//

import Foundation

struct PerformanceAligner: Sendable {

    struct Config: Sendable {
        /// Pitches at or above this confidence count as confidently heard.
        var confidentThreshold = 0.5
        /// Pitches below this confidence are discarded.
        var ignoreBelow = 0.1
        /// Detections closer than this (s) form one onset cluster (strums, chords).
        var clusterWindow = 0.05
        /// A following cluster within this window (s) whose pitches all belong to
        /// the matched chord is folded into it (slow strums, rolled chords).
        var strumWindow = 0.15
        /// Score for leaving an expected event unmatched.
        var missPenalty = -0.8
        /// Score for leaving a detected cluster unmatched.
        var extraPenalty = -0.6
        /// Score for pairing an expected event with a confident, unrelated cluster.
        var mismatchScore = -1.0
        /// Score for pairing with a low-confidence unrelated cluster (graded `uncertain`).
        var weakMismatchScore = -0.5
        /// Maximum timing penalty per pair.
        var timingWeight = 1.0
        /// Deviation (in beats, at least `minTimingWindow` s) at which the timing penalty saturates.
        var timingWindowBeats = 1.0
        var minTimingWindow = 0.25
        /// Timing weight scale for free-time passages.
        var freeTimeTimingScale = 0.3
        /// Up to this many expected × detected cells the DP is exact over the full
        /// matrix. Memory is one byte per cell (traceback) plus two score rows, so
        /// 16 M cells (e.g. 4000 × 4000) is 16 MB.
        var fullMatrixCellLimit = 16_000_000
        /// Larger takes use a Sakoe–Chiba band: each expected event only pairs with
        /// clusters within this many seconds (or `bandBeats` beats, whichever is
        /// larger) of its predicted time. When the best path runs along the band's
        /// edge the band widens ×4 and the pass repeats, then falls back to the
        /// full matrix. A repeat or skip longer than the band can still misalign.
        var bandSeconds = 20.0
        var bandBeats = 32.0

        init() {}
    }

    struct Result: Sendable {
        /// One entry per expected event with pitches, in passage order.
        var graded: [GradedEvent]
        var extras: [ExtraNote]
        /// Seconds-per-beat line used for the timing cost: time ≈ intercept + slope × beat.
        var estimatedSecondsPerBeat: Double
    }

    var config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Clusters

    /// A merged onset: max confidence per pitch.
    struct Cluster: Sendable {
        var time: TimeInterval
        var confidence: [Int: Double]

        var pitches: [Int] { confidence.keys.sorted() }
    }

    func clusters(from detected: [DetectedEvent]) -> [Cluster] {
        var out: [Cluster] = []
        for event in detected.sorted(by: { $0.time < $1.time }) {
            var map: [Int: Double] = [:]
            for (i, pitch) in event.pitches.enumerated() {
                let c = event.confidences.indices.contains(i) ? event.confidences[i] : 1
                guard c >= config.ignoreBelow, (0...127).contains(pitch) else { continue }
                map[pitch] = max(map[pitch] ?? 0, c)
            }
            guard !map.isEmpty else { continue }
            if var last = out.last, event.time - last.time <= config.clusterWindow {
                last.confidence.merge(map) { max($0, $1) }
                out[out.count - 1] = last
            } else {
                out.append(Cluster(time: event.time, confidence: map))
            }
        }
        return out
    }

    // MARK: - Pitch evaluation

    struct Evaluation {
        var matchedConfident: [Int] = []
        var matchedWeak: [Int] = []
        var octaveOnly: [Int] = []
        var wrongConfident: [Int] = []
        var weakOnlyCluster = false
        var similarity = 0.0
        var confidence = 0.0
    }

    func evaluate(expected: [Int], cluster: Cluster) -> Evaluation {
        var ev = Evaluation()
        let thr = config.confidentThreshold
        let heard = cluster.confidence
        ev.weakOnlyCluster = !heard.values.contains { $0 >= thr }
        ev.confidence = heard.values.reduce(0, +) / Double(max(1, heard.count))
        var credit = 0.0
        for pitch in expected {
            if let c = heard[pitch] {
                if c >= thr { ev.matchedConfident.append(pitch); credit += 1 }
                else { ev.matchedWeak.append(pitch); credit += 0.6 }
            } else if let c = heard.first(where: { $0.key % 12 == pitch % 12 })?.value {
                ev.octaveOnly.append(pitch)
                credit += c >= thr ? 0.5 : 0.3
            }
        }
        let expectedClasses = Set(expected.map { $0 % 12 })
        for (pitch, c) in heard where c >= thr && !expected.contains(pitch) && !expectedClasses.contains(pitch % 12) {
            ev.wrongConfident.append(pitch)
        }
        ev.wrongConfident.sort()
        ev.similarity = credit / Double(max(1, expected.count + ev.wrongConfident.count))
        return ev
    }

    private func pitchScore(_ ev: Evaluation) -> Double {
        if ev.similarity > 0 { return -0.5 + 2.5 * ev.similarity }
        return ev.weakOnlyCluster ? config.weakMismatchScore : config.mismatchScore
    }

    func grade(expected: ExpectedEvent, cluster: Cluster) -> GradedEvent {
        let ev = evaluate(expected: expected.pitches, cluster: cluster)
        let grade: EventGrade
        if ev.matchedConfident.count == expected.pitches.count {
            grade = .hit
        } else if !ev.matchedConfident.isEmpty {
            grade = .partial
        } else if !ev.wrongConfident.isEmpty && ev.matchedWeak.isEmpty && ev.octaveOnly.isEmpty {
            grade = .wrongPitch
        } else {
            grade = .uncertain
        }
        let matched = Set(ev.matchedConfident)
        return GradedEvent(expectedID: expected.id, grade: grade,
                           matchedPitches: ev.matchedConfident.sorted(),
                           missingPitches: expected.pitches.filter { !matched.contains($0) }.sorted(),
                           wrongPitches: ev.wrongConfident,
                           playedTime: cluster.time, timingOffsetMs: nil, confidence: ev.confidence)
    }

    // MARK: - Alignment

    /// Aligns detections to the passage. `tempoScale` is the practice speed (0.8 = 80%).
    func align(passage: ExpectedPassage, detected: [DetectedEvent], tempoScale: Double = 1) -> Result {
        let expected = passage.events.filter { !$0.pitches.isEmpty }.sorted { $0.beat < $1.beat }
        var cls = clusters(from: detected)
        let spb = 60 / max(1, passage.bpm * tempoScale)
        guard !expected.isEmpty else {
            return Result(graded: [], extras: extrasFor(cls.indices.map { $0 }, clusters: cls, after: [:]),
                          estimatedSecondsPerBeat: spb)
        }
        guard !cls.isEmpty else {
            return Result(graded: expected.map(missed), extras: [], estimatedSecondsPerBeat: spb)
        }

        // Pass 1: nominal tempo with a voted start offset → anchors → local tempo line.
        // Pitch scores are computed per cell inside the DP band (no n × m table).
        let rows = expected.map(RowPitches.init)
        let cols = cls.map(ClusterPitches.init)
        let start = voteStartTime(expected: expected, clusters: cls, secondsPerBeat: spb)
            ?? cls[0].time - expected[0].beat * spb
        let nominal = expected.map { start + $0.beat * spb }
        let firstPass = needlemanWunsch(rows: rows, clusters: cols, predicted: nominal,
                                        window: max(config.minTimingWindow, config.timingWindowBeats * spb),
                                        weight: passage.isFreeTime ? 0 : config.timingWeight * 0.5,
                                        secondsPerBeat: spb)
        let anchors = firstPass.compactMap { pair -> (beat: Double, time: Double)? in
            guard let e = pair.e, let c = pair.c,
                  evaluate(expected: expected[e].pitches, cluster: cls[c]).similarity >= 0.999 else { return nil }
            return (expected[e].beat, cls[c].time)
        }
        let line = TempoLine(anchors: anchors, nominalSecondsPerBeat: spb,
                             fallbackStart: cls[0].time - expected[0].beat * spb)
        let predicted = expected.map { line.time(atBeat: $0.beat) }

        // Pass 2: pitch + saturating timing cost.
        let weight = config.timingWeight * (passage.isFreeTime ? config.freeTimeTimingScale : 1)
        let window = max(config.minTimingWindow, config.timingWindowBeats * line.secondsPerBeat)
            * (passage.isFreeTime ? 2 : 1)
        var pairs = needlemanWunsch(rows: rows, clusters: cols, predicted: predicted,
                                    window: window, weight: weight, secondsPerBeat: line.secondsPerBeat)
        foldStrums(&pairs, expected: expected, clusters: &cls)

        var graded: [GradedEvent] = []
        var extraIndices: [Int] = []
        var lastMatchedBefore: [Int: Int] = [:]
        var lastExpected: Int?
        for pair in pairs {
            switch (pair.e, pair.c) {
            case let (e?, c?):
                graded.append(grade(expected: expected[e], cluster: cls[c]))
                lastExpected = expected[e].id
            case let (e?, nil):
                graded.append(missed(expected[e]))
            case let (nil, c?):
                extraIndices.append(c)
                if let lastExpected { lastMatchedBefore[c] = lastExpected }
            default: break
            }
        }
        graded.sort { $0.expectedID < $1.expectedID }
        return Result(graded: graded, extras: extrasFor(extraIndices, clusters: cls, after: lastMatchedBefore),
                      estimatedSecondsPerBeat: line.secondsPerBeat)
    }

    /// Hough-style vote for the take time of beat 0 at the nominal tempo: every
    /// (expected, detected) pair sharing a pitch votes for `time − beat × spb`.
    private func voteStartTime(expected: [ExpectedEvent], clusters: [Cluster], secondsPerBeat spb: Double) -> Double? {
        let bin = 0.05
        var beatsByPitch: [Int: [Double]] = [:]
        for e in expected { for p in e.pitches { beatsByPitch[p, default: []].append(e.beat) } }
        var votes: [Int: Int] = [:]
        var budget = 2_000_000
        for c in clusters {
            for (pitch, conf) in c.confidence where conf >= config.confidentThreshold {
                for beat in beatsByPitch[pitch] ?? [] {
                    votes[Int(((c.time - beat * spb) / bin).rounded()), default: 0] += 1
                    budget -= 1
                }
            }
            if budget <= 0 { break }
        }
        let best = votes.keys.max { a, b in
            let sa = 2 * votes[a]! + (votes[a - 1] ?? 0) + (votes[a + 1] ?? 0)
            let sb = 2 * votes[b]! + (votes[b - 1] ?? 0) + (votes[b + 1] ?? 0)
            return sa != sb ? sa < sb : a > b     // ties: earliest start
        }
        return best.map { Double($0) * bin }
    }

    private func missed(_ e: ExpectedEvent) -> GradedEvent {
        GradedEvent(expectedID: e.id, grade: .missed, matchedPitches: [], missingPitches: e.pitches,
                    wrongPitches: [], playedTime: nil, timingOffsetMs: nil, confidence: 0)
    }

    private func extrasFor(_ indices: [Int], clusters: [Cluster], after: [Int: Int]) -> [ExtraNote] {
        indices.flatMap { c in
            clusters[c].confidence.filter { $0.value >= config.confidentThreshold }.keys.sorted().map {
                ExtraNote(time: clusters[c].time, pitch: $0, afterExpectedID: after[c])
            }
        }
    }

    private struct Pair { var e: Int?; var c: Int? }

    /// One expected event's pitches, precomputed for per-cell scoring.
    struct RowPitches {
        var pitches: [Int]
        /// Bit per pitch class.
        var classMask: Int

        init(_ event: ExpectedEvent) {
            pitches = event.pitches
            classMask = event.pitches.reduce(0) { $0 | (1 << ($1 % 12)) }
        }
    }

    /// A cluster's pitches in its dictionary's iteration order (so octave
    /// lookups pick the same entry as `evaluate`), with its onset time.
    struct ClusterPitches {
        var time: Double
        var pitches: [Int]
        var confidences: [Double]

        init(_ cluster: Cluster) {
            time = cluster.time
            pitches = cluster.confidence.map(\.key)
            confidences = cluster.confidence.map(\.value)
        }
    }

    /// `pitchScore(evaluate(...))` without building an `Evaluation`: the same
    /// arithmetic in the same order, so scores are bit-identical.
    private func cellPitchScore(_ row: RowPitches, cluster: ClusterPitches) -> Double {
        let thr = config.confidentThreshold
        let heard = cluster.pitches, conf = cluster.confidences
        let count = heard.count
        var credit = 0.0
        for pitch in row.pitches {
            var exact = -1, octave = -1
            var k = 0
            while k < count {
                let h = heard[k]
                if h == pitch { exact = k; break }
                if octave < 0 && h % 12 == pitch % 12 { octave = k }
                k += 1
            }
            if exact >= 0 {
                credit += conf[exact] >= thr ? 1 : 0.6
            } else if octave >= 0 {
                credit += conf[octave] >= thr ? 0.5 : 0.3
            }
        }
        var wrong = 0
        var anyConfident = false
        var k = 0
        while k < count {
            if conf[k] >= thr {
                anyConfident = true
                if row.classMask & (1 << (heard[k] % 12)) == 0 { wrong += 1 }
            }
            k += 1
        }
        let similarity = credit / Double(max(1, row.pitches.count + wrong))
        if similarity > 0 { return -0.5 + 2.5 * similarity }
        return anyConfident ? config.mismatchScore : config.weakMismatchScore
    }

    /// DP columns allowed per row (j = clusters consumed, 0...m). Row 0 is the
    /// empty prefix. Bounds are monotone and each row starts no later than one
    /// past the previous row's end, so every cell in the band is reachable.
    struct Band: Equatable {
        var lo: [Int]
        var hi: [Int]

        static func full(rows n: Int, columns m: Int) -> Band {
            Band(lo: Array(repeating: 0, count: n + 1), hi: Array(repeating: m, count: n + 1))
        }

        /// Band around `predicted` times: row i+1 may pair expected i with the
        /// clusters within ±`halfWidth` seconds of `predicted[i]`.
        static func around(predicted: [Double], clusterTimes: [Double], halfWidth: Double) -> Band {
            let n = predicted.count, m = clusterTimes.count
            func firstIndex(atOrAfter t: Double) -> Int {
                var lo = 0, hi = m
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if clusterTimes[mid] < t { lo = mid + 1 } else { hi = mid }
                }
                return lo
            }
            var los = [Int](repeating: 0, count: n + 1)
            var his = [Int](repeating: 0, count: n + 1)
            var rawLo = [Int](repeating: 0, count: n + 1)
            var rawHi = [Int](repeating: 0, count: n + 1)
            for i in 0..<n {
                let a = firstIndex(atOrAfter: predicted[i] - halfWidth)           // first cluster in window
                let b = firstIndex(atOrAfter: predicted[i] + halfWidth + 1e-9)    // one past the last
                rawLo[i + 1] = a
                rawHi[i + 1] = max(a, b)                                          // j = b pairs cluster b−1
            }
            los[0] = 0
            his[0] = n > 0 ? rawHi[1] : m
            guard n > 0 else { return Band(lo: [0], hi: [m]) }
            for i in 1...n {
                his[i] = max(his[i - 1], rawHi[i])
                los[i] = max(los[i - 1], min(rawLo[i], his[i - 1] + 1))
                los[i] = min(los[i], his[i])
            }
            his[n] = m
            return Band(lo: los, hi: his)
        }

        var isFull: Bool { lo.allSatisfy { $0 == 0 } && hi.allSatisfy { $0 == hi.last } }
    }

    private func needlemanWunsch(rows: [RowPitches], clusters: [ClusterPitches], predicted: [Double],
                                 window: Double, weight: Double, secondsPerBeat: Double) -> [Pair] {
        let n = rows.count, m = clusters.count
        if n * m <= config.fullMatrixCellLimit {
            return needlemanWunsch(rows: rows, clusters: clusters, predicted: predicted, window: window,
                                   weight: weight, band: .full(rows: n, columns: m)).pairs
        }
        let times = clusters.map(\.time)
        var halfWidth = max(config.bandSeconds, config.bandBeats * secondsPerBeat)
        for _ in 0..<3 {
            let band = Band.around(predicted: predicted, clusterTimes: times, halfWidth: halfWidth)
            let result = needlemanWunsch(rows: rows, clusters: clusters, predicted: predicted, window: window,
                                         weight: weight, band: band)
            if band.isFull || !result.touchedEdge { return result.pairs }
            halfWidth *= 4
        }
        return needlemanWunsch(rows: rows, clusters: clusters, predicted: predicted, window: window,
                               weight: weight, band: .full(rows: n, columns: m)).pairs
    }

    /// Banded Needleman–Wunsch with two rolling score rows and a one-byte
    /// traceback per band cell. Cells outside the band are unreachable; with a
    /// full band this is the exact global alignment.
    private func needlemanWunsch(rows: [RowPitches], clusters: [ClusterPitches], predicted: [Double],
                                 window: Double, weight: Double, band: Band) -> (pairs: [Pair], touchedEdge: Bool) {
        let n = rows.count, m = clusters.count
        var offsets = [Int](repeating: 0, count: n + 2)
        for i in 0...n { offsets[i + 1] = offsets[i] + (band.hi[i] - band.lo[i] + 1) }
        var trace = [UInt8](repeating: 0, count: offsets[n + 1])   // 1 diag, 2 up (miss), 3 left (extra)
        // Reads are guarded by the band bounds, so stale values outside a row's band are never used.
        var prev = [Double](repeating: -.infinity, count: m + 1)
        var cur = prev
        for j in 0...band.hi[0] { prev[j] = Double(j) * config.extraPenalty; trace[j] = 3 }
        if n > 0 {
            for i in 1...n {
                let row = rows[i - 1]
                let lo = band.lo[i], hi = band.hi[i]
                let pLo = band.lo[i - 1], pHi = band.hi[i - 1]
                let base = offsets[i] - lo
                let target = predicted[i - 1]
                for j in lo...hi {
                    if j == 0 {
                        cur[0] = Double(i) * config.missPenalty
                        trace[base] = 2
                        continue
                    }
                    var diag = -Double.infinity
                    if j - 1 >= pLo && j - 1 <= pHi {
                        var cell = cellPitchScore(row, cluster: clusters[j - 1])
                        if weight > 0 {
                            let dev = (clusters[j - 1].time - target) / window
                            cell -= weight * min(1, dev * dev)
                        }
                        diag = prev[j - 1] + cell
                    }
                    let up = j >= pLo && j <= pHi ? prev[j] + config.missPenalty : -.infinity
                    let left = j - 1 >= lo ? cur[j - 1] + config.extraPenalty : -.infinity
                    if diag >= up && diag >= left { cur[j] = diag; trace[base + j] = 1 }
                    else if up >= left { cur[j] = up; trace[base + j] = 2 }
                    else { cur[j] = left; trace[base + j] = 3 }
                }
                swap(&prev, &cur)
            }
        }
        var pairs: [Pair] = []
        var touchedEdge = false
        var i = n, j = m
        while i > 0 || j > 0 {
            // A path on a clamped edge may have wanted to leave the band.
            if i > 0, (j == band.lo[i] && band.lo[i] > 0) || (j == band.hi[i] && band.hi[i] < m) { touchedEdge = true }
            switch trace[offsets[i] + j - band.lo[i]] {
            case 1: pairs.append(Pair(e: i - 1, c: j - 1)); i -= 1; j -= 1
            case 2: pairs.append(Pair(e: i - 1, c: nil)); i -= 1
            default: pairs.append(Pair(e: nil, c: j - 1)); j -= 1
            }
        }
        return (pairs.reversed(), touchedEdge)
    }

    /// Merges an unmatched cluster into an adjacent matched chord when it only
    /// adds that chord's own pitches and falls within `strumWindow`.
    private func foldStrums(_ pairs: inout [Pair], expected: [ExpectedEvent], clusters: inout [Cluster]) {
        var k = 0
        while k < pairs.count {
            guard pairs[k].e == nil, let c = pairs[k].c else { k += 1; continue }
            let neighbours = [k - 1, k + 1].filter { pairs.indices.contains($0) }
            var folded = false
            for nb in neighbours {
                guard let e = pairs[nb].e, let mc = pairs[nb].c, expected[e].pitches.count > 1,
                      abs(clusters[c].time - clusters[mc].time) <= config.strumWindow else { continue }
                let classes = Set(expected[e].pitches.map { $0 % 12 })
                guard clusters[c].confidence.keys.allSatisfy({ classes.contains($0 % 12) }) else { continue }
                clusters[mc].confidence.merge(clusters[c].confidence) { max($0, $1) }
                clusters[mc].time = min(clusters[mc].time, clusters[c].time)
                pairs.remove(at: k)
                folded = true
                break
            }
            if !folded { k += 1 }
        }
    }
}

// MARK: - Tempo line

/// Piecewise-linear beat → time map through monotonic anchors, extrapolated with
/// a robust (Theil–Sen) slope. Interpolating between anchors keeps the timing
/// cost local, so a skipped or repeated section only affects its own neighbourhood.
struct TempoLine: Sendable {
    private(set) var anchors: [(beat: Double, time: Double)] = []
    private(set) var secondsPerBeat: Double
    private var intercept: Double

    init(anchors raw: [(beat: Double, time: Double)], nominalSecondsPerBeat spb: Double, fallbackStart: Double) {
        var kept: [(beat: Double, time: Double)] = []
        for a in raw.sorted(by: { $0.beat < $1.beat }) {
            if let last = kept.last {
                guard a.beat > last.beat + 1e-6, a.time > last.time else { continue }
                let local = (a.time - last.time) / (a.beat - last.beat)
                guard local > spb * 0.25, local < spb * 4 else { continue }
            }
            kept.append(a)
        }
        anchors = kept
        if kept.count >= 2, let fit = RobustStats.theilSen(x: kept.map(\.beat), y: kept.map(\.time)),
           fit.slope > spb * 0.25, fit.slope < spb * 4 {
            secondsPerBeat = fit.slope
            intercept = fit.intercept
        } else if let only = kept.first {
            secondsPerBeat = spb
            intercept = only.time - only.beat * spb
        } else {
            secondsPerBeat = spb
            intercept = fallbackStart
        }
    }

    func time(atBeat beat: Double) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return intercept + secondsPerBeat * beat }
        if beat <= first.beat { return first.time - (first.beat - beat) * secondsPerBeat }
        if beat >= last.beat { return last.time + (beat - last.beat) * secondsPerBeat }
        var lo = 0, hi = anchors.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if anchors[mid].beat <= beat { lo = mid } else { hi = mid }
        }
        let a = anchors[lo], b = anchors[hi]
        return a.time + (beat - a.beat) / (b.beat - a.beat) * (b.time - a.time)
    }
}

// MARK: - Robust statistics

enum RobustStats {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    /// Theil–Sen line fit: median pairwise slope, median intercept.
    /// Subsamples pairs above ~200 points to bound cost.
    static func theilSen(x: [Double], y: [Double]) -> (slope: Double, intercept: Double)? {
        let n = min(x.count, y.count)
        guard n >= 2 else { return nil }
        let step = max(1, n / 200)
        var slopes: [Double] = []
        slopes.reserveCapacity((n / step) * (n / step) / 2)
        var i = 0
        while i < n {
            var j = i + 1
            while j < n {
                let dx = x[j] - x[i]
                if abs(dx) > 1e-9 { slopes.append((y[j] - y[i]) / dx) }
                j += step
            }
            i += step
        }
        guard let slope = median(slopes),
              let intercept = trimmedMean((0..<n).map { y[$0] - slope * x[$0] }) else { return nil }
        return (slope, intercept)
    }

    /// Mean of the central half (interquartile) of the values. Unlike the median it
    /// does not snap to one side of a bimodal residual set.
    static func trimmedMean(_ values: [Double], trim: Double = 0.25) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let cut = Int(Double(s.count) * trim)
        let core = s.count - 2 * cut > 0 ? Array(s[cut..<(s.count - cut)]) : s
        return core.reduce(0, +) / Double(core.count)
    }
}
