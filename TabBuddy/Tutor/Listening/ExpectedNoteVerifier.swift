//
//  ExpectedNoteVerifier.swift
//  TabBuddy
//
//  Tier B score-informed verifier (TUTOR_PLAN.md §1.2). Answers "are the
//  expected pitches present at this onset, and did anything else sound?"
//
//  Sample-clock driven and free of AVFoundation, so tests feed synthetic
//  arrays. Per detected onset:
//    • post window (length chosen from the expected pitches: longer for low
//      notes and chords) and pre window ending just before the onset;
//    • whitened rectified difference spectrum (HarmonicEstimator) so a
//      still-ringing chord cannot satisfy a new event;
//    • iterative harmonic estimation with a bonus for expected pitches,
//      octave (±12) and twelfth (±19) competitor checks, ghost removal;
//    • extra-note scan (found pitches that are not expected);
//    • chroma check of the found pitch set against the expected chord and
//      near-miss templates (one chord tone moved ±1/±2 semitones: E vs Em,
//      C vs Am, sus chords).
//
//  Modes:
//    • wait: events are queued; the first is active until an onset matches
//      it (hit). Every evaluated onset emits a result for the active event,
//      so the UI can count misses; only a hit advances the queue.
//    • timed: each event has an expected time ± tolerance; the best result
//      inside the window is emitted (a hit immediately), or `missed` when no
//      onset landed in it.
//
//  Thresholds are tuned on synthetic audio; real-recording validation is pending.
//

import Foundation

/// Not thread-safe: confine each instance to one queue (TutorListener uses
/// the audio processing queue).
final class ExpectedNoteVerifier: @unchecked Sendable {

    enum Window: Hashable, Sendable {
        /// Queue the events; each is satisfied by its first confident match.
        case wait
        /// Expected times (take clock, latency-corrected) per event, same order.
        case timed(times: [TimeInterval], tolerance: TimeInterval)

        /// Times from event beats at a fixed tempo.
        static func timed(_ events: [ExpectedEvent], passageStart: TimeInterval, bpm: Double,
                          tolerance: TimeInterval) -> Window {
            let spb = 60 / max(1, bpm)
            return .timed(times: events.map { passageStart + $0.beat * spb }, tolerance: tolerance)
        }
    }

    struct Config {
        /// Salience multiplier bonus for expected pitches.
        var expectedBonus: Float = 0.3
        /// Onsets up to this long before `arm` still count for a wait-mode event.
        var preArmGrace: TimeInterval = 0.15
        /// Gap between the pre window's end and the onset.
        var preGuard: TimeInterval = 0.012
        /// Found pitches below this relative weight are not reported as extras.
        var extraMinWeight: Float = 0.25
        /// Extras need this many present partials (body resonances show one or two peaks).
        var extraMinPartials = 3
        /// A near-miss chord template must beat the expected one by this cosine margin.
        var nearMissMargin: Double = 0.03
        var nearMissMinWeight: Float = 0.15
        /// Octave-duplicate chord tones count when this fraction of their partials is present.
        var impliedPresentFraction: Double = 0.5
        /// Onsets this soon after a pending chord onset belong to the same strum.
        var strumMergeSeconds: TimeInterval = 0.12
        /// Minimum pitch confidence for octave-tolerant grading.
        var octaveTolerantMinConfidence: Double = 0.4
        /// A pitch without a detectable fundamental counts as sounding only
        /// when this fraction of its partials is present (else it is a
        /// sub-harmonic ghost).
        var octaveTolerantGhostFraction: Double = 0.8
        /// Octave-tolerant search: pitches below this need a detectable fundamental.
        var octaveTolerantFundamentalBelow = 36
        /// Post-onset analysis window. Longer windows resolve neighboring
        /// semitones and octave competitors better but delay the result.
        var windowSeconds: TimeInterval = 0.18
        /// Window for pitches below `profile.lowNoteWindowBelowMIDI` (piano bass, bass guitar).
        var bassWindowSeconds: TimeInterval = 0.36
        /// Shorter window for single notes at or above `shortWindowMinMIDI`.
        var shortWindowSeconds: TimeInterval = 0.18
        var shortWindowMinMIDI = 72
        init() {}
    }

    let profile: InstrumentProfile
    let inputSampleRate: Double
    /// Internal analysis rate.
    let rate: Double
    var config: Config
    /// Subtracted from onset times before matching and reporting.
    var latencyCompensation: TimeInterval = 0
    /// Every evaluated onset's found pitches (source `.verifier`).
    var onDetection: ((DetectedEvent) -> Void)?

    private let decimator: ListeningDecimator
    private let onsetDetector: ListeningOnsetDetector
    private let spectrum = ListeningSpectrum()
    private var history: [Float] = []
    private var historyStart = 0
    private var clock = 0
    private var seeded = false
    private var pending: [Int] = []
    private var onsetLog: [(index: Int, consumed: Bool)] = []
    /// Pitches found at the previous evaluated onset (ringing-leakage check).
    private var previousSounding: [Int] = []
    private var results: [VerificationResult] = []

    private struct Slot {
        var event: ExpectedEvent
        var time: TimeInterval
        var tolerance: TimeInterval
        var best: VerificationResult?
        var done = false
    }
    private enum Mode {
        case idle
        case wait(queue: [ExpectedEvent], armedAt: Int)
        case timed([Slot])
    }
    private var mode: Mode = .idle

    init(sampleRate: Double, profile: InstrumentProfile, config: Config = Config()) {
        self.profile = profile
        self.inputSampleRate = sampleRate
        self.config = config
        let factor = ListeningMath.decimationFactor(forInputRate: sampleRate)
        decimator = ListeningDecimator(factor: factor)
        rate = sampleRate / Double(factor)
        onsetDetector = ListeningOnsetDetector(rate: rate, profile: profile)
    }

    /// Current take time (latency-corrected).
    var currentTime: TimeInterval { Double(clock) / rate - latencyCompensation }

    /// IDs of events still armed and unresolved.
    var armedEventIDs: [Int] {
        switch mode {
        case .idle: return []
        case .wait(let q, _): return q.map(\.id)
        case .timed(let slots): return slots.filter { !$0.done }.map(\.event.id)
        }
    }

    // MARK: Arming

    /// Arms events (replacing any previously armed ones).
    func arm(_ events: [ExpectedEvent], window: Window) {
        let gradable = events.filter { !$0.pitches.isEmpty }
        switch window {
        case .wait:
            mode = .wait(queue: gradable, armedAt: clock)
            reevaluateRecentOnsets()
        case .timed(let times, let tol):
            var slots: [Slot] = []
            for (i, e) in events.enumerated() where i < times.count && !e.pitches.isEmpty {
                slots.append(Slot(event: e, time: times[i], tolerance: tol))
            }
            mode = .timed(slots)
        }
    }

    func disarm() { mode = .idle }

    // MARK: Processing

    /// Feeds a chunk that starts at take-clock sample `startSample` (input
    /// rate). The first call seeds the clock, so a verifier attached after
    /// listening started still reports take-clock times.
    @discardableResult
    func process(samples: [Float], startSample: Int) -> [VerificationResult] {
        if !seeded {
            seeded = true
            let factor = max(1, Int((inputSampleRate / rate).rounded()))
            clock = startSample / factor
            historyStart = clock
            onsetDetector.seed(clock: clock)
        }
        return process(samples: samples)
    }

    /// Feeds mono samples at the input rate; returns results completed in this chunk.
    @discardableResult
    func process(samples: [Float]) -> [VerificationResult] {
        seeded = true
        let dec = decimator.process(samples)
        history.append(contentsOf: dec)
        clock += dec.count
        let newOnsets = onsetDetector.process(dec)
        for o in newOnsets {
            // A slow strum can trigger a second onset; while a chord onset is
            // still pending, treat onsets shortly after it as the same strum.
            if let last = pending.last, o.index - last < Int(config.strumMergeSeconds * rate),
               (onset(last).event?.pitches.count ?? 0) >= 3 {
                continue
            }
            // A new onset truncates any evaluation still waiting for samples.
            for p in pending { evaluate(onset: p, limit: o.index) }
            pending.removeAll()
            pending.append(o.index)
            onsetLog.append((o.index, false))
        }
        var still: [Int] = []
        for p in pending {
            if clock >= p + windowLength(for: onset(p)) { evaluate(onset: p, limit: nil) } else { still.append(p) }
        }
        pending = still
        closeExpiredSlots()
        trimHistory()
        let out = results
        results.removeAll()
        return out
    }

    /// Evaluates pending onsets with the samples available and closes every
    /// timed window. Call at the end of a take.
    func finish() -> [VerificationResult] {
        for p in pending { evaluate(onset: p, limit: clock) }
        pending.removeAll()
        if case .timed(var slots) = mode {
            for i in slots.indices where !slots[i].done {
                results.append(slots[i].best ?? missed(slots[i]))
                slots[i].done = true
            }
            mode = .timed(slots)
        }
        let out = results
        results.removeAll()
        return out
    }

    // MARK: Onset → expectation

    private func correctedTime(_ index: Int) -> TimeInterval {
        Double(index) / rate - latencyCompensation
    }

    /// The event an onset should be graded against, and the timed slot index.
    private func onset(_ index: Int) -> (event: ExpectedEvent?, slot: Int?) {
        switch mode {
        case .idle:
            return (nil, nil)
        case .wait(let queue, let armedAt):
            guard let e = queue.first,
                  index >= armedAt - Int(config.preArmGrace * rate) else { return (nil, nil) }
            return (e, nil)
        case .timed(let slots):
            let t = correctedTime(index)
            var best: Int?
            for (i, s) in slots.enumerated() where !s.done && abs(t - s.time) <= s.tolerance {
                if best == nil || abs(t - s.time) < abs(t - slots[best!].time) { best = i }
            }
            return (best.map { slots[$0].event }, best)
        }
    }

    private func windowLength(for target: (event: ExpectedEvent?, slot: Int?)) -> Int {
        let pitches = target.event?.pitches ?? []
        let lowest = pitches.min() ?? profile.pitchRange.lowerBound + 12
        let pcs = Set(pitches.map { (($0 % 12) + 12) % 12 }).count
        let seconds: Double
        if lowest < profile.lowNoteWindowBelowMIDI {
            seconds = profile.lowNoteWindowSeconds ?? config.bassWindowSeconds
        }
        else if lowest < config.shortWindowMinMIDI || pcs >= 2 || target.event == nil { seconds = config.windowSeconds }
        else { seconds = config.shortWindowSeconds }
        return ListeningVerifierMath.powerOfTwo(near: rate * seconds)
    }

    // MARK: Evaluation

    private func evaluate(onset index: Int, limit: Int?) {
        let target = onset(index)
        guard let ev = evidence(onset: index, length: windowLength(for: target), limit: limit) else {
            return
        }
        let expected = target.event
        let grading = grade(ev, expected: expected)
        previousSounding = grading.found.filter { $0.confidence >= config.octaveTolerantMinConfidence }.map(\.midi)
        let time = correctedTime(index)
        if !grading.found.isEmpty {
            onDetection?(DetectedEvent(time: time, pitches: grading.found.map(\.midi),
                                       confidences: grading.found.map(\.confidence), source: .verifier))
        }
        guard let expected, let result = grading.result(expectedID: expected.id, time: time) else { return }

        switch mode {
        case .idle:
            break
        case .wait(var queue, let armedAt):
            results.append(result)
            if result.grade == .hit {
                queue.removeFirst()
                markConsumed(index)
            }
            mode = .wait(queue: queue, armedAt: armedAt)
        case .timed(var slots):
            guard let si = target.slot else { return }
            if result.grade == .hit {
                slots[si].best = result
                slots[si].done = true
                results.append(result)
                markConsumed(index)
            } else if ListeningVerifierMath.rank(result.grade) > ListeningVerifierMath.rank(slots[si].best?.grade) {
                slots[si].best = result
            }
            mode = .timed(slots)
        }
    }

    private func markConsumed(_ index: Int) {
        if let i = onsetLog.lastIndex(where: { $0.index == index }) { onsetLog[i].consumed = true }
    }

    private func reevaluateRecentOnsets() {
        let earliest = clock - Int(config.preArmGrace * rate)
        for entry in onsetLog where entry.index >= earliest && !entry.consumed && !pending.contains(entry.index) {
            guard case .wait(let q, _) = mode, !q.isEmpty else { return }
            evaluate(onset: entry.index, limit: clock)
        }
    }

    private func evidence(onset index: Int, length n: Int, limit: Int?) -> OnsetEvidence? {
        let prev = onsetLog.last(where: { $0.index < index - Int(config.preGuard * rate) })?.index
        return OnsetWindows.evidence(
            onset: index, previousOnset: prev, length: n, end: min(clock, limit ?? clock),
            earliest: historyStart, rate: rate, preGuard: config.preGuard,
            gateRMS: onsetDetector.gateRMS, spectrum: spectrum,
            estimator: HarmonicEstimator(profile: profile), slice: slice)
    }

    private func slice(_ start: Int, _ length: Int) -> ArraySlice<Float>? {
        let a = start - historyStart
        guard a >= 0, length > 0, a + length <= history.count else { return nil }
        return history[a..<(a + length)]
    }

    private func trimHistory() {
        let keep = Int(rate * 1.6)
        if history.count > keep * 2 {
            let drop = history.count - keep
            history.removeFirst(drop)
            historyStart += drop
        }
        let earliest = clock - Int(rate * 2)
        onsetLog.removeAll { $0.index < earliest }
    }

    private func closeExpiredSlots() {
        guard case .timed(var slots) = mode else { return }
        let now = currentTime
        var changed = false
        for i in slots.indices where !slots[i].done && now > slots[i].time + slots[i].tolerance {
            let open = pending.contains { abs(correctedTime($0) - slots[i].time) <= slots[i].tolerance }
            if open { continue }
            results.append(slots[i].best ?? missed(slots[i]))
            slots[i].done = true
            changed = true
        }
        if changed { mode = .timed(slots) }
    }

    private func missed(_ slot: Slot) -> VerificationResult {
        VerificationResult(expectedID: slot.event.id, grade: .missed, heard: [], unexpected: [],
                           onsetTime: slot.time, confidence: 0.5)
    }

    // MARK: Grading

    struct Grading {
        var found: [EstimatedPitch]
        var grade: EventGrade?
        var heard: [Int] = []
        var unexpected: [Int] = []
        var confidence: Double = 0

        func result(expectedID: Int, time: TimeInterval) -> VerificationResult? {
            guard let grade else { return nil }
            return VerificationResult(expectedID: expectedID, grade: grade, heard: heard,
                                      unexpected: unexpected, onsetTime: time, confidence: confidence)
        }
    }

    /// Grades one onset's evidence against an expected event (nil = detection only).
    func grade(_ ev: OnsetEvidence, expected: ExpectedEvent?) -> Grading {
        if let expected, expected.octaveTolerant, !expected.pitches.isEmpty {
            return gradeOctaveTolerant(ev, expected: expected)
        }
        let expectedSet = Set(expected?.pitches ?? [])
        let est = ListeningVerifierMath.estimator(for: profile, expected: expectedSet)
        var found = est.estimate(ev, expected: expectedSet, bonus: expectedSet.isEmpty ? 0 : config.expectedBonus)
        found = est.refineOctaves(found, evidence: ev, expected: expectedSet)
        found = est.pruneExplained(found, evidence: ev, expected: expectedSet)
        found = est.removeGhosts(found, keep: expectedSet)
        guard expected != nil, !expectedSet.isEmpty else { return Grading(found: found, grade: nil) }
        guard !found.isEmpty else {
            return Grading(found: found, grade: .uncertain, confidence: 0.2)
        }

        let foundSet = Set(found.map(\.midi))
        var matched = expectedSet.intersection(foundSet)
        var confidences: [Double] = found.filter { matched.contains($0.midi) }.map(\.confidence)

        // Chord tones whose partials are all partials of another matched tone
        // (octave/twelfth doublings) cannot be heard separately; accept them
        // when their partials are present.
        if expectedSet.count > 1, !matched.isEmpty {
            let doubling: Set<Int> = [12, 19, 24, 28, 31, 36]
            for p in expectedSet.subtracting(matched) {
                let above = matched.contains { doubling.contains(p - $0) }
                let ps = est.partials(midi: p, spectrum: ev.white, evidence: ev)
                let present = ps.filter { $0.snr >= est.snrPresent }.count
                let fraction = Double(present) / Double(max(1, min(6, ps.count)))
                if above, fraction >= config.impliedPresentFraction {
                    matched.insert(p); confidences.append(0.6)
                    continue
                }
                // A lower doubling (octave below a matched tone) with its own exclusive partials.
                let below = matched.filter { [12, 19, 24].contains($0 - p) }
                if !below.isEmpty {
                    let ex = est.exclusiveEvidence(midi: p, excluding: Array(foundSet), spectrum: ev.white, evidence: ev)
                    let refSal = found.filter { below.contains($0.midi) }.map(\.salience).max() ?? 0
                    if ex.present >= 1, ex.energy >= refSal * 0.12 {
                        matched.insert(p); confidences.append(0.6)
                    }
                }
            }
        }

        let extras = found.filter {
            !expectedSet.contains($0.midi) && $0.weight >= config.extraMinWeight
                && $0.partialsPresent >= config.extraMinPartials
        }
        var unexpected = Set(extras.map(\.midi))

        var grading = Grading(found: found, grade: nil)
        grading.heard = matched.sorted()
        let n = expectedSet.count
        let pcs = Set(expectedSet.map { (($0 % 12) + 12) % 12 })

        if n == 1 {
            if !matched.isEmpty {
                grading.grade = .hit
            } else {
                grading.grade = unexpected.isEmpty ? .uncertain : .wrongPitch
            }
        } else {
            if let miss = nearMiss(found: found, expectedPCs: pcs) {
                for f in found where ((f.midi % 12) + 12) % 12 == miss { unexpected.insert(f.midi) }
                grading.grade = .wrongPitch
            } else {
                let matchedPCs = Set(matched.map { (($0 % 12) + 12) % 12 })
                let lenient = n >= 4 && matchedPCs == pcs && matched.count >= n - 1
                if matched.count == n || lenient {
                    grading.grade = .hit
                } else if matched.isEmpty {
                    grading.grade = unexpected.isEmpty ? .uncertain : .wrongPitch
                } else {
                    grading.grade = .partial
                }
            }
        }
        grading.unexpected = unexpected.sorted()
        let meanConf = confidences.isEmpty ? 0.3 : confidences.reduce(0, +) / Double(confidences.count)
        switch grading.grade {
        case .hit: grading.confidence = meanConf
        case .partial: grading.confidence = meanConf * Double(matched.count) / Double(n)
        case .wrongPitch:
            grading.confidence = Double(extras.map(\.confidence).max() ?? 0.5)
        default: grading.confidence = 0.2
        }
        return grading
    }

    /// Octave-tolerant grading (`ExpectedEvent.octaveTolerant`): the voicing
    /// is unknown, so the pitches are estimated without an expected-pitch
    /// bias and compared by pitch class. A hit needs every expected pitch
    /// class confidently present in some octave; for a slash chord
    /// (`chordName` contains "/") the lowest expected pitch class must also be
    /// the lowest confident sounding pitch class. `heard` lists the sounding
    /// pitches whose class is expected.
    private func gradeOctaveTolerant(_ ev: OnsetEvidence, expected: ExpectedEvent) -> Grading {
        let pc: (Int) -> Int = { (($0 % 12) + 12) % 12 }
        let expectedPCs = Set(expected.pitches.map(pc))
        let est = ListeningVerifierMath.estimator(for: profile, expected: Set(expected.pitches))
        let lim = config.octaveTolerantFundamentalBelow
        var found = est.estimate(ev, requireFundamentalBelow: lim)
        found = est.refineOctaves(found, evidence: ev, trustPicks: true, requireFundamentalBelow: lim)
        found = est.pruneExplained(found, evidence: ev, expected: [])
        found = est.removeGhosts(found)
        guard !found.isEmpty else { return Grading(found: found, grade: .uncertain, confidence: 0.2) }

        // Sub-harmonic ghosts (no fundamental, few partials) are not sounding pitches.
        let confident = found.filter { f in
            guard f.confidence >= config.octaveTolerantMinConfidence else { return false }
            let fundamental = est.partials(midi: f.midi, spectrum: ev.white, evidence: ev).first?.snr ?? 0
            return fundamental >= est.snrPresent
                || Double(f.partialsPresent) >= config.octaveTolerantGhostFraction * Double(max(1, f.partialsAvailable))
        }
        var heard = confident.filter { expectedPCs.contains(pc($0.midi)) }
        var heardPCs = Set(heard.map { pc($0.midi) })

        // Missing pitch classes: look for them in every octave, strongest
        // own evidence first. These never set the bass.
        let foundMIDI = found.map(\.midi)
        let sounding = confident.map(\.midi)
        for missing in expectedPCs.subtracting(heardPCs) {
            let candidates = est.profile.pitchRange.filter { pc($0) == missing }.sorted { a, b in
                est.salience(midi: a, partials: est.partials(midi: a, spectrum: ev.white, evidence: ev))
                    > est.salience(midi: b, partials: est.partials(midi: b, spectrum: ev.white, evidence: ev))
            }
            for m in candidates {
                // An octave, twelfth or double octave above a heard pitch has
                // only shared partials; accept it when its partials are present
                // (as with fixed voicings). Thirds (+28) are never implied.
                let above = heard.contains { [12, 19, 24, 31, 36].contains(m - $0.midi) }
                let ps = est.partials(midi: m, spectrum: ev.white, evidence: ev)
                let present = ps.filter { $0.snr >= est.snrPresent }.count
                let fraction = Double(present) / Double(max(1, min(6, ps.count)))
                var accept = above && fraction >= config.impliedPresentFraction
                if !accept {
                    // Otherwise it needs partials of its own.
                    let ex = est.exclusiveEvidence(midi: m, excluding: foundMIDI.filter { $0 != m }, spectrum: ev.white, evidence: ev)
                    let own = est.salience(midi: m, partials: ps)
                    accept = ex.count >= 2 && ex.present >= 2 && ex.energy >= own * 0.3
                }
                if accept {
                    heard.append(EstimatedPitch(midi: m, salience: 0, weight: 0, partialsPresent: present,
                                                partialsAvailable: ps.count, confidence: 0.6))
                    heardPCs.insert(missing)
                    break
                }
            }
        }
        // Pitches that are octaves or low harmonics of what the previous onset
        // left sounding are most likely leakage from ringing strings; they do
        // not count as wrong notes.
        let previous = previousSounding
        // Likewise a high pick on the harmonic series of a heard chord tone
        // (or of that tone an octave down, whose register is uncertain), e.g.
        // the flat 7th harmonic of C4 near B♭6. Such a pitch cannot be told
        // apart from a real added note, so C7 played for C can grade as a hit.
        let series: Set<Int> = [19, 24, 28, 31, 34, 36]
        let ringing: (Int) -> Bool = { m in
            guard !expectedPCs.contains(pc(m)) else { return false }
            if previous.contains(where: { [0, 12, 19, 24, 28, 31, 36].contains(m - $0) }) { return true }
            return heard.contains { h in series.contains(m - h.midi) || series.contains(m - h.midi + 12) }
        }
        let extras = confident.filter {
            !expectedPCs.contains(pc($0.midi)) && !ringing($0.midi) && $0.weight >= config.extraMinWeight
                && $0.partialsPresent >= config.extraMinPartials
        }
        var unexpected = Set(extras.map(\.midi))

        var grading = Grading(found: confident, grade: nil)
        grading.heard = heard.map(\.midi).sorted()
        let isSlash = expected.chordName?.contains("/") ?? false
        let bassOK: Bool = {
            guard isSlash, let lowestExpected = expected.pitches.min(),
                  let lowestHeard = sounding.min() else { return true }
            return pc(lowestHeard) == pc(lowestExpected)
        }()

        if let miss = nearMiss(found: confident.filter { !ringing($0.midi) }, expectedPCs: expectedPCs) {
            for f in confident where pc(f.midi) == miss && !ringing(f.midi) { unexpected.insert(f.midi) }
            grading.grade = .wrongPitch
        } else if heardPCs == expectedPCs {
            grading.grade = bassOK ? .hit : .partial
        } else if heardPCs.isEmpty {
            grading.grade = unexpected.isEmpty ? .uncertain : .wrongPitch
        } else {
            grading.grade = .partial
        }
        grading.unexpected = unexpected.sorted()
        let confs = heard.map(\.confidence)
        let meanConf = confs.isEmpty ? 0.3 : confs.reduce(0, +) / Double(confs.count)
        switch grading.grade {
        case .hit: grading.confidence = meanConf
        case .partial:
            grading.confidence = meanConf * Double(heardPCs.count) / Double(max(1, expectedPCs.count))
        case .wrongPitch: grading.confidence = Double(extras.map(\.confidence).max() ?? 0.5)
        default: grading.confidence = 0.2
        }
        return grading
    }

    /// Pitch class of a near-miss template tone that explains the found
    /// pitches better than the expected chord, if any.
    private func nearMiss(found: [EstimatedPitch], expectedPCs: Set<Int>) -> Int? {
        guard expectedPCs.count >= 2 else { return nil }
        var chroma = [Double](repeating: 0, count: 12)
        for f in found { chroma[((f.midi % 12) + 12) % 12] += Double(f.weight) }
        let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        func cosine(_ t: Set<Int>) -> Double {
            t.reduce(0) { $0 + chroma[$1] } / (norm * sqrt(Double(t.count)))
        }
        let base = cosine(expectedPCs)
        var best: (pc: Int, score: Double)?
        for pc in expectedPCs {
            for d in [-2, -1, 1, 2] {
                let np = ((pc + d) % 12 + 12) % 12
                guard !expectedPCs.contains(np) else { continue }
                var t = expectedPCs
                t.remove(pc); t.insert(np)
                let s = cosine(t)
                if best == nil || s > best!.score { best = (np, s) }
            }
        }
        guard let best, best.score > base + config.nearMissMargin,
              chroma[best.pc] >= Double(config.nearMissMinWeight) else { return nil }
        return best.pc
    }
}

enum ListeningVerifierMath {
    static func powerOfTwo(near x: Double) -> Int {
        let p = Int(pow(2, (log2(max(2, x))).rounded()))
        return max(256, p)
    }
    static func powerOfTwo(floor x: Int) -> Int {
        var p = 1
        while p * 2 <= x { p *= 2 }
        return p
    }
    static func powerOfTwo(ceil x: Int) -> Int {
        var p = 1
        while p < x { p *= 2 }
        return p
    }
    static func rank(_ g: EventGrade?) -> Int {
        switch g {
        case .hit: return 5
        case .partial: return 4
        case .wrongPitch: return 3
        case .uncertain: return 2
        case .missed: return 1
        case nil: return 0
        }
    }
    /// Estimator whose search range also covers every expected pitch.
    static func estimator(for profile: InstrumentProfile, expected: Set<Int>) -> HarmonicEstimator {
        var p = profile
        if let lo = expected.min(), let hi = expected.max() {
            p.pitchRange = min(lo, profile.pitchRange.lowerBound)...max(hi, profile.pitchRange.upperBound)
        }
        return HarmonicEstimator(profile: p)
    }
}
