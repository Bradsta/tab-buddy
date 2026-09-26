//
//  HarmonicEstimator.swift
//  TabBuddy
//
//  Multipitch evidence on the whitened onset-difference spectrum, shared by
//  the tier-B verifier and the tier-C transcriber.
//
//  1. Difference spectrum: magnitude after the onset minus magnitude before
//     it, rectified. Strings still ringing from the previous event decay, so
//     they cancel and cannot capture detection (NoteTranscriberCore lesson).
//  2. Whitening: subtract each bin's local median so the spectrally smooth
//     pluck/body thump vanishes while harmonic peaks survive; the profile's
//     body band (guitar 73–110 Hz) is further attenuated.
//  3. Salience: Klapuri-weighted harmonic sum, partial positions follow the
//     stiff-string model h·f0·sqrt(1 + B·h²).
//  4. Iterative estimation: pick the most salient pitch, subtract its partials
//     with spectral smoothing (shared partials keep their excess), repeat.
//  5. Octave/twelfth refinement: a lower competitor (−12/−19) whose exclusive
//     partials are present replaces the pick; an upper competitor (+12/+19)
//     replaces it when the pick's own exclusive partials are absent.
//

import Foundation

/// Prepared spectral evidence for one onset.
struct OnsetEvidence {
    /// Bin width in Hz.
    let binHz: Double
    /// Whitened, rectified onset-difference magnitudes.
    let white: [Float]
    /// Local noise reference per bin (from the post-onset spectrum).
    let noise: [Float]
    /// RMS of the post-onset window.
    let postRMS: Float
    /// Energy (sum of squares of `white`) — a level-independent tonal gate uses ratios of this.
    let whiteEnergy: Float
}

/// One estimated pitch.
struct EstimatedPitch: Hashable {
    var midi: Int
    /// Harmonic salience when picked (residual spectrum).
    var salience: Float
    /// Salience relative to the strongest pick (0...1).
    var weight: Float
    /// Partials with SNR above the presence threshold.
    var partialsPresent: Int
    /// Partials below the analysis ceiling.
    var partialsAvailable: Int
    /// 0...1 confidence.
    var confidence: Double
}

struct HarmonicEstimator {
    let profile: InstrumentProfile
    /// Partial SNR (whitened peak / local noise) counted as present.
    var snrPresent: Float = 3
    /// Partial tolerance around the model position.
    var toleranceCents: Double = 35
    /// Minimum ratio of exclusive lower-competitor energy to the pick's salience
    /// that flags the lower pitch as the real one.
    var lowerCompetitorRatio: Float = 0.2
    /// Minimum ratio of the pick's exclusive energy to its shared energy with
    /// an upper competitor.
    var upperCompetitorRatio: Float = 0.12

    init(profile: InstrumentProfile) {
        self.profile = profile
    }

    // MARK: Evidence

    /// Builds evidence from post- and (optional) pre-onset magnitude spectra of equal size.
    func evidence(post: [Float], pre: [Float]?, binHz: Double, postRMS: Float) -> OnsetEvidence {
        let maxBin = min(post.count, Int(profile.maxPartialHz * 1.05 / binHz) + 8)
        var diff = [Float](repeating: 0, count: maxBin)
        if let pre, pre.count >= maxBin {
            for k in 0..<maxBin { diff[k] = max(0, post[k] - pre[k]) }
        } else {
            for k in 0..<maxBin { diff[k] = post[k] }
        }
        let halfWidth = max(4, Int(45 / binHz))
        let dMed = ListeningStats.localMedian(diff, count: maxBin, halfWidth: halfWidth,
                                              step: max(1, halfWidth / 4))
        let pMed = ListeningStats.localMedian(post, count: maxBin, halfWidth: halfWidth,
                                              step: max(1, halfWidth / 4))
        var peak: Float = 0
        for k in 0..<maxBin { peak = max(peak, post[k]) }
        let relFloor = max(1e-6, peak * 1e-3)
        var white = [Float](repeating: 0, count: maxBin)
        var noise = [Float](repeating: 0, count: maxBin)
        let lowCut = Int(35 / binHz)
        var energy: Float = 0
        for k in 0..<maxBin {
            var w = max(0, diff[k] - dMed[k])
            if k < lowCut { w = 0 }
            if let band = profile.whiteningBand {
                let f = Double(k) * binHz
                if band.contains(f) { w *= profile.whiteningBandGain }
            }
            white[k] = w
            noise[k] = max(pMed[k], relFloor)
            energy += w * w
        }
        return OnsetEvidence(binHz: binHz, white: white, noise: noise, postRMS: postRMS, whiteEnergy: energy)
    }

    // MARK: Partials

    struct Partial {
        var harmonic: Int
        var bin: Int
        var amplitude: Float
        var snr: Float
        var frequency: Double
    }

    func partialFrequencies(midi: Int, limitHz: Double? = nil) -> [Double] {
        let f0 = ListeningMath.frequency(midi: midi)
        let b = profile.inharmonicity(midi: midi)
        let limit = min(limitHz ?? profile.maxPartialHz, profile.maxPartialHz)
        var out: [Double] = []
        for h in 1...profile.harmonicCount {
            let f = ListeningMath.partial(h, f0: f0, inharmonicity: b)
            if f > limit { break }
            out.append(f)
        }
        return out
    }

    /// Peak evidence at each partial of `midi` in `spectrum` (which must be
    /// the evidence's white spectrum or a residual of it).
    func partials(midi: Int, spectrum: [Float], evidence: OnsetEvidence) -> [Partial] {
        let freqs = partialFrequencies(midi: midi, limitHz: Double(spectrum.count - 2) * evidence.binHz)
        var out: [Partial] = []
        out.reserveCapacity(freqs.count)
        let ratio = pow(2, toleranceCents / 1200) - 1
        for (i, f) in freqs.enumerated() {
            let c = f / evidence.binHz
            let tol = max(1.5, f * ratio / evidence.binHz)
            let lo = max(1, Int((c - tol).rounded(.down)))
            let hi = min(spectrum.count - 1, Int((c + tol).rounded(.up)))
            guard lo <= hi else { break }
            var best: Float = 0
            var bestK = Int(c.rounded())
            for k in lo...hi where spectrum[k] > best {
                best = spectrum[k]; bestK = k
            }
            // Only a local maximum counts: a window edge sitting on the slope
            // of a neighboring pitch's peak is not evidence for this partial.
            if best > 0, (bestK > 0 && spectrum[bestK - 1] > best)
                || (bestK + 1 < spectrum.count && spectrum[bestK + 1] > best) {
                best = 0
            }
            let snr = best / evidence.noise[min(bestK, evidence.noise.count - 1)]
            out.append(Partial(harmonic: i + 1, bin: bestK, amplitude: best, snr: snr, frequency: f))
        }
        return out
    }

    /// Klapuri harmonic weight g(f0, h).
    func weight(f0: Double, harmonic h: Int) -> Float {
        Float((f0 + 27) / (Double(h) * f0 + 320))
    }

    func salience(midi: Int, partials: [Partial]) -> Float {
        let f0 = ListeningMath.frequency(midi: midi)
        var s: Float = 0
        for p in partials where p.snr >= 1 {
            s += weight(f0: f0, harmonic: p.harmonic) * p.amplitude
        }
        return s
    }

    private func requiredPartials(available: Int) -> Int {
        available >= 3 ? 2 : 1
    }

    private func isTonal(_ partials: [Partial]) -> Bool {
        let present = partials.filter { $0.snr >= snrPresent }.count
        let need = requiredPartials(available: partials.count)
        if need == 1 {
            // One- or two-partial pitches (top of the piano) need a stronger peak.
            return partials.contains { $0.snr >= snrPresent * 2 }
        }
        return present >= need
    }

    // MARK: Estimation

    /// Iterative harmonic-sum estimation with spectral subtraction.
    /// `expected` pitches get a salience bonus (score-informed prior).
    /// `requireFundamentalBelow`: pitches below this MIDI note can be picked
    /// only when their fundamental partial is present. Without an expected
    /// voicing this keeps the search off low "virtual" pitches (a major triad
    /// is harmonics 4, 5 and 6 of a note two octaves below its root). Higher
    /// pitches are exempt because guitar bass strings often have weak
    /// fundamentals.
    func estimate(_ ev: OnsetEvidence, expected: Set<Int> = [], bonus: Float = 0,
                  maxPitches: Int? = nil, requireFundamentalBelow: Int? = nil) -> [EstimatedPitch] {
        let limit = maxPitches ?? profile.maxPolyphony
        var residual = ev.white
        var found: [EstimatedPitch] = []
        var rejected = Set<Int>()
        var first: Float = 0
        var guardCount = 0
        let range = profile.pitchRange
        // After the open search stops, expected pitches still get a lower bar.
        var onlyExpected = false
        while found.count < limit, guardCount < limit + 20 {
            guardCount += 1
            var bestMidi = -1
            var bestScore: Float = 0
            var bestSal: Float = 0
            var bestPartials: [Partial] = []
            for m in range where !rejected.contains(m) && !found.contains(where: { $0.midi == m }) {
                if onlyExpected && !expected.contains(m) { continue }
                if let lim = requireFundamentalBelow, m < lim, !hasFundamental(m, evidence: ev) { continue }
                let ps = partials(midi: m, spectrum: residual, evidence: ev)
                let s = salience(midi: m, partials: ps)
                let score = expected.contains(m) ? s * (1 + bonus) : s
                if score > bestScore {
                    bestScore = score; bestMidi = m; bestSal = s; bestPartials = ps
                }
            }
            let stop = profile.polyphonyStopRatio * (onlyExpected ? 0.4 : 1)
            if bestMidi < 0 || bestSal <= 0 || (first > 0 && bestSal < first * stop) {
                let remaining = expected.subtracting(found.map(\.midi)).subtracting(rejected)
                if !onlyExpected, first > 0, !remaining.isEmpty {
                    onlyExpected = true
                    continue
                }
                break
            }
            // Expected pitches may have lost shared partials to earlier picks;
            // judge their tonality on the unsubtracted spectrum.
            let tonal = isTonal(bestPartials)
                || (expected.contains(bestMidi) && isTonal(partials(midi: bestMidi, spectrum: ev.white, evidence: ev)))
            guard tonal, isSupported(bestMidi, found: found, evidence: ev, expected: expected) else {
                rejected.insert(bestMidi)
                continue
            }
            if first == 0 { first = bestSal }
            let present = bestPartials.filter { $0.snr >= snrPresent }.count
            found.append(EstimatedPitch(midi: bestMidi, salience: bestSal, weight: 0,
                                        partialsPresent: present,
                                        partialsAvailable: bestPartials.count, confidence: 0))
            subtract(bestPartials, from: &residual)
        }
        return finalize(found)
    }

    /// Minimum exclusive-partial energy (relative to the pitch's own salience)
    /// for a non-expected later pick to stand.
    var exclusiveRatio: Float = 0.3

    /// False when a pick has no partials of its own: every partial sits on a
    /// partial of an earlier (stronger) pick or of an expected pitch, so it is
    /// most likely a subtraction leftover or an overtone. Expected pitches
    /// pass when they have no exclusive partials to check (octave doublings)
    /// or when at least one exclusive partial is present.
    func isSupported(_ midi: Int, found: [EstimatedPitch], evidence ev: OnsetEvidence,
                     expected: Set<Int>, expectedExplain: Bool = true) -> Bool {
        // During the search, partials of expected pitches count as explained
        // too: a pick that is an overtone of an expected note is most likely
        // that note.
        let explainers = Set(found.map(\.midi)).union(expectedExplain ? expected : []).subtracting([midi])
        guard !explainers.isEmpty else { return true }
        let ex = exclusiveEvidence(midi: midi, excluding: Array(explainers), spectrum: ev.white, evidence: ev)
        if expected.contains(midi) {
            // Octave/twelfth doublings of other expected notes cannot be
            // verified on their own; the verifier treats them separately.
            guard ex.count >= 2 else { return true }
            return ex.present >= 1 && ex.ratio >= expectedExclusiveRatio
        }
        let own = salience(midi: midi, partials: partials(midi: midi, spectrum: ev.white, evidence: ev))
        let need = ex.count >= 3 ? 2 : 1
        return ex.present >= need && ex.energy >= own * exclusiveRatio
    }

    /// Minimum exclusive/shared partial amplitude ratio for an expected pick.
    var expectedExclusiveRatio: Float = 0.05

    /// Removes a pitch's partials from `spectrum` with spectral smoothing:
    /// each partial loses at most the local mean of its neighbors' amplitudes,
    /// so a coincident partial of another note keeps its excess.
    func subtract(_ ps: [Partial], from spectrum: inout [Float]) {
        guard !ps.isEmpty else { return }
        let amps = ps.map { $0.snr >= 1 ? $0.amplitude : 0 }
        // Hann main lobe with 2x zero padding spans about ±4 bins.
        let lobe = 4
        for (i, p) in ps.enumerated() where amps[i] > 0 {
            let lo = max(0, i - 1), hi = min(amps.count - 1, i + 1)
            var mean: Float = 0
            for j in lo...hi { mean += amps[j] }
            mean /= Float(hi - lo + 1)
            let remove = min(amps[i], max(mean, amps[i] * 0.5))
            let factor = max(0, 1 - remove / amps[i])
            let a = max(0, p.bin - lobe), b = min(spectrum.count - 1, p.bin + lobe)
            if a <= b { for k in a...b { spectrum[k] *= factor } }
        }
    }

    private func finalize(_ found: [EstimatedPitch]) -> [EstimatedPitch] {
        let top = found.map(\.salience).max() ?? 0
        guard top > 0 else { return [] }
        return found.map { p in
            var q = p
            q.weight = p.salience / top
            let presence = Double(p.partialsPresent) / Double(max(1, min(4, p.partialsAvailable)))
            q.confidence = min(1, 0.5 * min(1, presence) + 0.5 * Double(min(1, q.weight * 2)))
            return q
        }
    }

    // MARK: Octave / twelfth refinement

    struct Exclusive {
        /// Weighted salience of the exclusive partials.
        var energy: Float = 0
        /// Exclusive partials above the presence SNR.
        var present = 0
        /// Exclusive partials considered.
        var count = 0
        /// Mean amplitude of exclusive / shared partials among the first `lowHarmonics`.
        var meanExclusive: Float = 0
        var meanShared: Float = 0
        var ratio: Float { meanShared > 0 ? meanExclusive / meanShared : (meanExclusive > 0 ? 10 : 0) }
    }

    /// Evidence from `midi`'s partials that are not within tolerance of any
    /// partial of `others`.
    func exclusiveEvidence(midi: Int, excluding others: [Int], spectrum: [Float],
                           evidence: OnsetEvidence, lowHarmonics: Int = 12) -> Exclusive {
        let ps = partials(midi: midi, spectrum: spectrum, evidence: evidence)
        let ratio = pow(2, toleranceCents / 1200) - 1
        let otherFreqs = others.flatMap { partialFrequencies(midi: $0) }
        let f0 = ListeningMath.frequency(midi: midi)
        var out = Exclusive()
        var exSum: Float = 0, exN = 0, shSum: Float = 0, shN = 0
        for p in ps {
            let tolHz = max(2.5 * evidence.binHz, p.frequency * ratio * 1.5)
            let amp = p.snr >= 1 ? p.amplitude : 0
            if otherFreqs.contains(where: { abs($0 - p.frequency) <= tolHz }) {
                if p.harmonic <= lowHarmonics { shSum += amp; shN += 1 }
                continue
            }
            out.count += 1
            out.energy += weight(f0: f0, harmonic: p.harmonic) * amp
            if p.snr >= snrPresent { out.present += 1 }
            if p.harmonic <= lowHarmonics { exSum += amp; exN += 1 }
        }
        out.meanExclusive = exN > 0 ? exSum / Float(exN) : 0
        out.meanShared = shN > 0 ? shSum / Float(shN) : 0
        return out
    }

    /// Replaces picks that are octave/twelfth errors. Competitors listed in
    /// `expected` are never introduced by a lower-competitor swap (they would
    /// have been found directly).
    /// Whether `midi`'s fundamental partial is present in the whitened evidence.
    func hasFundamental(_ midi: Int, evidence ev: OnsetEvidence) -> Bool {
        (partials(midi: midi, spectrum: ev.white, evidence: ev).first?.snr ?? 0) >= snrPresent
    }

    func refineOctaves(_ found: [EstimatedPitch], evidence ev: OnsetEvidence,
                       expected: Set<Int> = [], trustPicks: Bool = false,
                       requireFundamentalBelow: Int? = nil) -> [EstimatedPitch] {
        var result = found
        let range = profile.pitchRange
        var drop = Set<Int>()
        for idx in result.indices {
            let x = result[idx].midi
            let others = result.map(\.midi).filter { $0 != x }
            let xPartials = partials(midi: x, spectrum: ev.white, evidence: ev)
            let xSal = salience(midi: x, partials: xPartials)
            guard xSal > 0 else { continue }

            // Lower competitors: exclusive partials reveal a lower note whose
            // harmonics contain all of x's partials.
            var replaced = false
            for d in [12, 19, 24] {
                let c = x - d
                guard range.contains(c), !result.contains(where: { $0.midi == c }),
                      !expected.contains(c) else { continue }
                if let lim = requireFundamentalBelow, c < lim, !hasFundamental(c, evidence: ev) { continue }
                // Expected picks always explain their partials. Unexpected
                // picks on c's own harmonic series are likely c's overtones
                // (unless `trustPicks`), so they do not explain c away.
                let series: Set<Int> = [12, 19, 24, 28, 31, 34, 36]
                let unrelated = others.filter {
                    trustPicks || expected.contains($0) || !series.contains($0 - c)
                }
                let ex = exclusiveEvidence(midi: c, excluding: [x] + unrelated, spectrum: ev.white, evidence: ev)
                guard ex.count > 0 else { continue }
                let needed = ex.count >= 3 ? 2 : 1
                if ex.present >= needed, ex.ratio >= lowerCompetitorRatio {
                    set(&result[idx], to: c, ev: ev)
                    replaced = true
                    break
                }
            }
            if replaced { continue }

            // Upper competitors: x must show partials the upper note lacks.
            for d in [12, 19] {
                let u = x + d
                guard range.contains(u) else { continue }
                let ex = exclusiveEvidence(midi: x, excluding: [u], spectrum: ev.white, evidence: ev)
                guard ex.meanShared > 0, ex.count > 0 else { continue }
                if ex.present == 0 || ex.ratio < upperCompetitorRatio {
                    if result.contains(where: { $0.midi == u }) {
                        drop.insert(x)
                    } else {
                        set(&result[idx], to: u, ev: ev)
                    }
                    break
                }
            }
        }
        // An expected pick whose partials all belong to a found, unexpected
        // lower note (octave, twelfth, two octaves) cannot be confirmed: the
        // lower note explains it.
        for x in result where expected.contains(x.midi) {
            if result.contains(where: { c in
                !expected.contains(c.midi) && [12, 19, 24].contains(x.midi - c.midi)
                    && c.salience >= x.salience * 0.25
            }) {
                drop.insert(x.midi)
            }
        }
        result.removeAll { drop.contains($0.midi) }
        var seen = Set<Int>()
        result = result.filter { seen.insert($0.midi).inserted }
        return finalize(result)
    }

    /// Final pass: drops non-expected picks whose partials are all explained
    /// by stronger picks (weakest first).
    func pruneExplained(_ found: [EstimatedPitch], evidence ev: OnsetEvidence,
                        expected: Set<Int>) -> [EstimatedPitch] {
        var kept = found
        for q in found.sorted(by: { $0.salience < $1.salience }) where !expected.contains(q.midi) {
            // Only stronger picks can explain a weaker one away (no circular pruning).
            let rest = kept.filter { $0.midi != q.midi && $0.salience >= q.salience }
            guard !rest.isEmpty else { continue }
            if !isSupported(q.midi, found: rest, evidence: ev, expected: expected, expectedExplain: false) {
                kept.removeAll { $0.midi == q.midi }
            }
        }
        return finalize(kept)
    }

    private func set(_ p: inout EstimatedPitch, to midi: Int, ev: OnsetEvidence) {
        let ps = partials(midi: midi, spectrum: ev.white, evidence: ev)
        p.midi = midi
        p.salience = salience(midi: midi, partials: ps)
        p.partialsPresent = ps.filter { $0.snr >= snrPresent }.count
        p.partialsAvailable = ps.count
    }

    /// Drops weak picks that sit an octave/twelfth/two octaves above, or a
    /// semitone beside, a stronger pick (subtraction leftovers).
    func removeGhosts(_ found: [EstimatedPitch], keep: Set<Int> = [],
                      ratio: Float = 0.45) -> [EstimatedPitch] {
        let ghostIntervals: Set<Int> = [12, 19, 24, 28, 31, 36]
        let kept = found.filter { q in
            if keep.contains(q.midi) { return true }
            return !found.contains { p in
                guard p.midi != q.midi else { return false }
                let d = q.midi - p.midi
                if ghostIntervals.contains(d) { return q.salience < p.salience * ratio }
                if abs(d) == 1 { return q.salience < p.salience * 0.35 }
                return false
            }
        }
        return finalize(kept)
    }
}

/// Pre/post onset windows → evidence, shared by the verifier and the transcriber.
enum OnsetWindows {
    /// - Parameters:
    ///   - length: desired post-window length (samples at `rate`).
    ///   - end: first sample index not yet available (or the next onset).
    ///   - earliest: first sample index still available.
    ///   - slice: returns samples [start, start+length) or nil.
    static func evidence(onset index: Int, previousOnset prev: Int?, length n: Int, end: Int,
                         earliest: Int, rate: Double, preGuard: TimeInterval, gateRMS: Float,
                         spectrum: ListeningSpectrum, estimator: HarmonicEstimator,
                         slice: (Int, Int) -> ArraySlice<Float>?) -> OnsetEvidence? {
        var postLen = n
        let available = end - index
        if available < postLen {
            postLen = available >= 1024 ? ListeningVerifierMath.powerOfTwo(floor: available) : available
        }
        guard postLen >= 512 else { return nil }
        let fftSize = ListeningVerifierMath.powerOfTwo(ceil: n) * 2
        guard let post = slice(index, postLen) else { return nil }
        let postRMS = ListeningStats.rms(post)
        guard postRMS >= gateRMS else { return nil }
        let postMag = spectrum.magnitudes(post, fftSize: fftSize)

        let guardSamples = Int(preGuard * rate)
        let preEnd = index - guardSamples
        var preMag: [Float]?
        let preStart = max(earliest, preEnd - n)
        if preEnd - preStart >= 256, let s = slice(preStart, preEnd - preStart) {
            preMag = spectrum.magnitudes(s, fftSize: fftSize)
        }
        // A previous onset inside the pre window: also take the spectrum of
        // just its ringing part and keep the larger magnitudes, so the
        // still-ringing notes cancel fully.
        if let prev, prev + Int(0.02 * rate) > preStart {
            let shortStart = prev + Int(0.02 * rate)
            let len = preEnd - shortStart
            if len >= 512, let s = slice(shortStart, len) {
                let m = spectrum.magnitudes(s, fftSize: fftSize)
                if var p = preMag {
                    for k in p.indices { p[k] = max(p[k], m[k]) }
                    preMag = p
                } else {
                    preMag = m
                }
            }
        }
        return estimator.evidence(post: postMag, pre: preMag, binHz: rate / Double(fftSize), postRMS: postRMS)
    }
}
