//
//  NoteTranscriberCore.swift
//  TabBuddy
//
//  Offline-testable note transcription engine for play-to-author.
//
//  Pipeline (all sample-clock driven, no wall time):
//    mono input → decimate to ~16 kHz → per-hop (8 ms):
//      • spectral-flux onset detection (log-magnitude STFT)
//      • YIN pitch + aperiodicity (vDSP correlation, parabolic refine)
//    → note state machine:
//      • onset opens an "attack"; after a short skip the first K agreeing
//        confident pitch frames vote (median) and emit the note (~50-80 ms
//        after the pluck). Repeated same-pitch notes work because onsets,
//        not pitch changes, segment notes.
//      • sustained pitch shift without an onset emits a legato note
//        (hammer-on / pull-off / slide).
//      • silence closes the note.
//
//  The same class runs against the live mic tap (PitchDetector) and against
//  decoded audio files in the .diag/authbench harness.
//

import Foundation
import Accelerate

final class NoteTranscriberCore {

    // MARK: - Config

    struct Config {
        /// Internal analysis rate; input is boxcar-decimated to ~this.
        var targetRate: Double = 16000
        /// STFT size for onset flux (samples at internal rate).
        var fftSize: Int = 512
        /// Analysis hop (samples at internal rate). 128 @ 16 kHz = 8 ms.
        var hopSize: Int = 128
        /// YIN integration window (samples at internal rate).
        var yinWindow: Int = 1024
        /// Slightly above unplayable low rumble; open low E (82.4 Hz) still passes.
        var minFreq: Double = 76
        var maxFreq: Double = 1200
        /// First-dip threshold on the cumulative mean normalized difference.
        var yinThreshold: Float = 0.15
        /// A frame votes on pitch only if its CMNDF minimum is below this.
        var voteAperiodicityMax: Float = 0.30
        /// Confident agreeing frames needed to emit a note.
        var votesToEmit: Int = 3
        /// Votes must sit within this many semitones of their median.
        var voteAgreeSemitones: Double = 0.7
        /// Frames to ignore right after an onset (attack transient).
        var attackSkipFrames: Int = 2
        /// Give up on an attack if no agreement after this many frames.
        var maxAttackFrames: Int = 22
        /// Trailing frames for the adaptive onset threshold median.
        var onsetMedianFrames: Int = 40
        /// Peak must exceed median * factor + floor.
        var onsetThresholdFactor: Float = 1.9
        var onsetThresholdFloor: Float = 2.0
        /// Minimum frames between onsets (7 ≈ 56 ms → ~13 notes/s max less voting).
        var onsetRefractoryFrames: Int = 6
        /// RMS below this = silence (frame over fftSize window).
        var rmsGate: Float = 0.0035
        /// Pitch must move at least this far (semitones) to count as legato.
        var legatoSemitones: Double = 0.8
        /// ...but no farther than this (octave flips between ringing strings
        /// are detector noise, not playing).
        var legatoMaxSemitones: Double = 7.5
        /// Consecutive agreeing shifted frames to confirm legato.
        var legatoFrames: Int = 6
        /// Frames a legato frame must be confident to (CMNDF below this).
        var legatoAperiodicityMax: Float = 0.20
        /// No legato this soon after an onset (post-attack pitch is unstable).
        var legatoHoldoffFrames: Int = 12
        /// Consecutive silent frames that close the active note.
        var silenceFramesToIdle: Int = 5
        /// Consecutive agreeing frames to recover a note with no detected onset.
        var recoverFrames: Int = 10
        var recoverAperiodicityMax: Float = 0.15
        /// Harmonics summed for onset difference-spectrum salience.
        var salienceHarmonics: Int = 8
        /// Suppress a re-emission of the SAME pitch within this window —
        /// one physical pluck can produce several flux peaks. Real repeats
        /// (even fast 16ths) are farther apart than this.
        var samePitchDedupSeconds: Double = 0.11
        /// Emit a second note per onset (strummed dyad / boom-chick) when its
        /// salience is at least this fraction of the winner's. 0 disables.
        var dyadSalienceRatio: Float = 0
        /// Second note must have a periodicity dip below this to qualify.
        var dyadAperiodicityMax: Float = 0.35

        init() {}
    }

    // MARK: - Events

    struct Event {
        enum Kind: String {
            case onset      // pluck detected then pitch voted
            case legato     // pitch moved without an onset (hammer/pull/slide)
            case recovered  // stable pitch with no detected onset (safety net)
        }
        let kind: Kind
        /// Seconds from stream start (approximate physical onset time).
        let time: Double
        let frequency: Double
        let midiFloat: Double
        let midi: Int
        /// 0-1, from vote aperiodicity.
        let confidence: Double
    }

    /// Live pitch of the most recent frame (for UI feedback), even between notes.
    private(set) var livePitch: (frequency: Double, midi: Int, confidence: Double)?

    // MARK: - Init

    let config: Config
    private let inputRate: Double
    private let decimation: Int
    private let rate: Double            // internal analysis rate

    private let minTau: Int
    private let maxTau: Int

    // FFT
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var hannWindow: [Float]
    private var prevLogMag: [Float]
    private var windowed: [Float]
    private var splitReal: [Float]
    private var splitImag: [Float]
    private var magSq: [Float]

    // Recent magnitude spectra (sqrt of magSq), newest last; for the
    // pre/post-onset difference spectrum.
    private var specRing: [[Float]] = []
    private let specRingSize = 8
    /// Spectrum snapshot from just before the current onset.
    private var onsetPreSpec: [Float]?
    /// Peak-held rectified (post - pre) spectrum across the attack.
    private var onsetDiffSpec: [Float] = []

    // Rolling analysis buffer of decimated samples (enough for YIN + FFT lookback)
    private var buffer: [Float] = []
    private let keepSamples: Int
    /// Total decimated samples consumed (sample clock).
    private var clock: Int = 0
    /// Leftover input samples not yet forming a full decimation block.
    private var decimRemainder: [Float] = []
    /// Decimated samples accumulated toward the next hop.
    private var hopFill: Int = 0

    // Onset novelty history
    private var fluxHistory: [Float] = []
    private var framesSinceOnset: Int = .max / 2

    // Note state machine
    private enum State {
        case idle
        case attack(onsetClock: Int, framesSince: Int, votes: [(midiF: Double, conf: Double)])
        case sustain(midiF: Double)
    }
    private var state: State = .idle
    private var legatoRun: [(midiF: Double, conf: Double)] = []
    private var recoverRun: [(midiF: Double, conf: Double)] = []
    private var silentFrames: Int = 0
    private var lastEmittedMidi: Int = -1
    private var lastEmittedTime: Double = -1e9

    init(sampleRate: Double, config: Config = Config()) {
        self.config = config
        self.inputRate = sampleRate
        self.decimation = max(1, Int((sampleRate / config.targetRate).rounded()))
        self.rate = sampleRate / Double(decimation)

        self.minTau = max(2, Int(rate / config.maxFreq))
        self.maxTau = Int(rate / config.minFreq)

        self.log2n = vDSP_Length(round(log2(Double(config.fftSize))))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.hannWindow = [Float](repeating: 0, count: config.fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(config.fftSize), Int32(vDSP_HANN_NORM))
        let halfFFT = config.fftSize / 2
        self.prevLogMag = [Float](repeating: 0, count: halfFFT)
        self.windowed = [Float](repeating: 0, count: config.fftSize)
        self.splitReal = [Float](repeating: 0, count: halfFFT)
        self.splitImag = [Float](repeating: 0, count: halfFFT)
        self.magSq = [Float](repeating: 0, count: halfFFT)

        self.keepSamples = max(config.yinWindow + maxTau, config.fftSize) + config.hopSize
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        decimRemainder.removeAll(keepingCapacity: true)
        fluxHistory.removeAll(keepingCapacity: true)
        prevLogMag = [Float](repeating: 0, count: config.fftSize / 2)
        specRing.removeAll(keepingCapacity: true)
        onsetPreSpec = nil
        clock = 0
        hopFill = 0
        framesSinceOnset = .max / 2
        state = .idle
        legatoRun.removeAll()
        recoverRun.removeAll()
        silentFrames = 0
        lastEmittedMidi = -1
        lastEmittedTime = -1e9
        livePitch = nil
    }

    // MARK: - Input

    /// Feed mono samples at the input rate. Returns any note events completed
    /// during this chunk. Safe to call with arbitrary chunk sizes.
    func process(_ samples: [Float]) -> [Event] {
        var events: [Event] = []

        // Decimate (boxcar mean) with remainder carry.
        var input = decimRemainder
        input.append(contentsOf: samples)
        let fullBlocks = input.count / decimation
        if fullBlocks > 0 {
            var decimated = [Float](repeating: 0, count: fullBlocks)
            input.withUnsafeBufferPointer { ptr in
                for i in 0..<fullBlocks {
                    var mean: Float = 0
                    vDSP_meanv(ptr.baseAddress! + i * decimation, 1, &mean, vDSP_Length(decimation))
                    decimated[i] = mean
                }
            }
            decimRemainder = Array(input[(fullBlocks * decimation)...])

            // Append to rolling buffer, process hop by hop.
            for s in decimated {
                buffer.append(s)
                hopFill += 1
                clock += 1
                if hopFill >= config.hopSize {
                    hopFill = 0
                    if buffer.count >= keepSamples - config.hopSize {
                        events.append(contentsOf: processFrame())
                    }
                    if buffer.count > keepSamples {
                        buffer.removeFirst(buffer.count - keepSamples)
                    }
                }
            }
        } else {
            decimRemainder = input
        }
        return events
    }

    // MARK: - Per-frame analysis

    private func processFrame() -> [Event] {
        let n = buffer.count
        let cfg = config

        // --- RMS over the newest fftSize samples
        var rms: Float = 0
        buffer.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress! + (n - cfg.fftSize), 1, &rms, vDSP_Length(cfg.fftSize))
        }

        // --- Spectral flux
        let flux = computeFlux()
        fluxHistory.append(flux)
        if fluxHistory.count > cfg.onsetMedianFrames + 4 {
            fluxHistory.removeFirst(fluxHistory.count - (cfg.onsetMedianFrames + 4))
        }
        framesSinceOnset += 1

        var onsetNow = false
        if fluxHistory.count >= 5, framesSinceOnset >= cfg.onsetRefractoryFrames {
            // Peak-pick on the previous frame (needs one frame of lookahead).
            let c = fluxHistory.count
            let prev = fluxHistory[c - 2]
            let cur = fluxHistory[c - 1]
            let prev2 = fluxHistory[c - 3]
            let median = medianOf(Array(fluxHistory.prefix(max(1, c - 2)).suffix(cfg.onsetMedianFrames)))
            let threshold = median * cfg.onsetThresholdFactor + cfg.onsetThresholdFloor
            if prev > threshold && prev >= prev2 && prev >= cur {
                onsetNow = true
                framesSinceOnset = 1
            }
        }

        // --- Pitch (YIN candidate dips)
        let candidates = yinCandidates()
        let bestDip = candidates.min(by: { $0.aperiodicity < $1.aperiodicity })
        if let p = bestDip, p.aperiodicity < 0.5 {
            let midiF = 69.0 + 12.0 * log2(p.frequency / 440.0)
            livePitch = (p.frequency, Int(midiF.rounded()), Double(1 - p.aperiodicity))
        } else {
            livePitch = nil
        }

        // --- Silence tracking
        if rms < cfg.rmsGate {
            silentFrames += 1
        } else {
            silentFrames = 0
        }

        // --- State machine
        var events: [Event] = []
        let frameTime = Double(clock) / rate

        /// Plain vote from the strongest periodicity (sustain/idle paths).
        let confidentVote: (midiF: Double, conf: Double)? = {
            guard rms >= cfg.rmsGate, let p = bestDip,
                  p.aperiodicity < cfg.voteAperiodicityMax else { return nil }
            let midiF = 69.0 + 12.0 * log2(p.frequency / 440.0)
            return (midiF, Double(1 - p.aperiodicity))
        }()

        if onsetNow {
            // A new pluck always starts a fresh attack, even mid-attack/sustain.
            state = .attack(onsetClock: clock - cfg.hopSize, framesSince: 0, votes: [])
            legatoRun.removeAll()
            recoverRun.removeAll()
            capturePreOnsetSpectrum()
        }

        switch state {
        case .attack(let onsetClock, var framesSince, var votes):
            framesSince += 1
            accumulateOnsetDiff()
            if framesSince > cfg.attackSkipFrames, rms >= cfg.rmsGate,
               let v = onsetVote(candidates: candidates) {
                votes.append(v)
                let agreeing = agreeingVotes(votes)
                if agreeing.count >= cfg.votesToEmit {
                    let midiF = medianOf(agreeing.map(\.midiF))
                    let conf = medianOf(agreeing.map(\.conf))
                    let onsetTime = Double(onsetClock) / rate

                    // Strummed dyad: a second, harmonically distinct note in
                    // the same pluck. Emit ascending (strum order).
                    var toEmit: [(midiF: Double, conf: Double)] = [(midiF, conf)]
                    if let second = dyadPartner(primaryMidiF: midiF, candidates: candidates) {
                        toEmit.append(second)
                        toEmit.sort { $0.midiF < $1.midiF }
                    }
                    for note in toEmit {
                        if let e = emit(.onset, time: onsetTime,
                                        midiF: note.midiF, conf: note.conf) {
                            events.append(e)
                        }
                    }
                    state = .sustain(midiF: midiF)
                    break
                }
            }
            if framesSince > cfg.maxAttackFrames {
                // Attack never produced agreement: percussive noise or dead pluck.
                state = .idle
            } else {
                state = .attack(onsetClock: onsetClock, framesSince: framesSince, votes: votes)
            }

        case .sustain(let activeMidiF):
            if silentFrames >= cfg.silenceFramesToIdle {
                state = .idle
                legatoRun.removeAll()
                break
            }
            if framesSinceOnset > cfg.legatoHoldoffFrames,
               let v = confidentVote, let p = bestDip,
               p.aperiodicity < cfg.legatoAperiodicityMax {
                let delta = abs(v.midiF - activeMidiF)
                if delta >= cfg.legatoSemitones && delta <= cfg.legatoMaxSemitones {
                    // Candidate legato: require consecutive agreeing shifted frames.
                    if let last = legatoRun.last, abs(last.midiF - v.midiF) > 0.5 {
                        legatoRun.removeAll()
                    }
                    legatoRun.append(v)
                    if legatoRun.count >= cfg.legatoFrames {
                        let midiF = medianOf(legatoRun.map(\.midiF))
                        let conf = medianOf(legatoRun.map(\.conf))
                        if let e = emit(.legato,
                                        time: frameTime - Double(cfg.legatoFrames * cfg.hopSize) / rate,
                                        midiF: midiF, conf: conf) {
                            events.append(e)
                        }
                        state = .sustain(midiF: midiF)
                        legatoRun.removeAll()
                    }
                } else {
                    legatoRun.removeAll()
                }
            }

        case .idle:
            // Safety net: a clearly ringing stable pitch whose onset we missed.
            if let v = confidentVote, let p = bestDip,
               p.aperiodicity < cfg.recoverAperiodicityMax,
               rms >= cfg.rmsGate * 2 {
                if let last = recoverRun.last, abs(last.midiF - v.midiF) > 0.5 {
                    recoverRun.removeAll()
                }
                recoverRun.append(v)
                if recoverRun.count >= cfg.recoverFrames {
                    let midiF = medianOf(recoverRun.map(\.midiF))
                    let conf = medianOf(recoverRun.map(\.conf))
                    if let e = emit(.recovered,
                                    time: frameTime - Double(cfg.recoverFrames * cfg.hopSize) / rate,
                                    midiF: midiF, conf: conf) {
                        events.append(e)
                    }
                    state = .sustain(midiF: midiF)
                    recoverRun.removeAll()
                }
            } else {
                recoverRun.removeAll()
            }
        }

        return events
    }

    // MARK: - Onset-informed pitch voting

    /// Snapshot the spectrum from just before the onset (elementwise min of a
    /// few pre-onset frames — robust to a splash in any single frame).
    private func capturePreOnsetSpectrum() {
        let c = specRing.count
        // Ring newest-last; the flux peak was at frame c-2, so pre-onset
        // frames are c-4 and earlier.
        guard c >= 6 else { onsetPreSpec = nil; return }
        var pre = specRing[c - 6]
        for idx in [c - 5, c - 4] {
            vDSP_vmin(pre, 1, specRing[idx], 1, &pre, 1, vDSP_Length(pre.count))
        }
        onsetPreSpec = pre
        onsetDiffSpec = [Float](repeating: 0, count: pre.count)
    }

    /// Peak-hold the rectified (current - pre-onset) spectrum across the
    /// attack, then whiten it: subtract each bin's local median so the
    /// spectrally smooth pluck thump vanishes while harmonic peaks survive.
    private func accumulateOnsetDiff() {
        guard let pre = onsetPreSpec, let cur = specRing.last,
              onsetDiffSpec.count == pre.count else { return }
        for k in 0..<pre.count {
            let d = cur[k] - pre[k]
            if d > onsetDiffSpec[k] { onsetDiffSpec[k] = d }
        }
        let n = onsetDiffSpec.count
        if onsetDiffWhite.count != n { onsetDiffWhite = [Float](repeating: 0, count: n) }
        var window = [Float](repeating: 0, count: 7)
        for k in 0..<n {
            let lo = max(0, k - 3), hi = min(n - 1, k + 3)
            var count = 0
            for j in lo...hi { window[count] = onsetDiffSpec[j]; count += 1 }
            window[0..<count].sort()
            let median = window[count / 2]
            onsetDiffWhite[k] = max(0, onsetDiffSpec[k] - median)
        }
    }
    private var onsetDiffWhite: [Float] = []

    /// Score a candidate f0 by harmonic salience on the onset difference
    /// spectrum: energy that APPEARED at the pluck, so already-ringing
    /// strings don't capture the vote.
    private func salience(frequency: Double) -> Float {
        guard !onsetDiffWhite.isEmpty else { return 0 }
        let binWidth = rate / Double(config.fftSize)
        var s: Float = 0
        for h in 1...config.salienceHarmonics {
            let bin = frequency * Double(h) / binWidth
            let i = Int(bin)
            guard i + 1 < onsetDiffWhite.count else { break }
            let frac = Float(bin - Double(i))
            let v = onsetDiffWhite[i] * (1 - frac) + onsetDiffWhite[i + 1] * frac
            s += v / Float(h)
        }
        return s
    }

    /// A second simultaneous note in the current onset (strummed dyad).
    /// Must be harmonically distinct from the primary (no octave/unison —
    /// those are usually the primary's own harmonics) with comparable
    /// new-energy salience and a solid periodicity dip of its own.
    private func dyadPartner(primaryMidiF: Double,
                             candidates: [(frequency: Double, aperiodicity: Float)])
        -> (midiF: Double, conf: Double)? {
        let cfg = config
        guard cfg.dyadSalienceRatio > 0, onsetPreSpec != nil else { return nil }
        let primarySalience = salience(frequency: 440.0 * pow(2.0, (primaryMidiF - 69.0) / 12.0))
        guard primarySalience > 0 else { return nil }

        var best: (midiF: Double, conf: Double, sal: Float)?
        for c in candidates where c.aperiodicity < cfg.dyadAperiodicityMax {
            let midiF = 69.0 + 12.0 * log2(c.frequency / 440.0)
            let interval = abs(midiF - primaryMidiF)
            // Boom-chick geometry: a bass note well apart from the melody
            // note, but never the octave/double-octave (usually the
            // primary's own harmonics masquerading).
            guard interval >= 7.5, interval <= 22.5,
                  abs(interval - 12) > 1.0 else { continue }
            let s = salience(frequency: c.frequency)
            guard s >= primarySalience * cfg.dyadSalienceRatio else { continue }
            if best == nil || s > best!.sal {
                best = (midiF, Double(1 - c.aperiodicity), s)
            }
        }
        return best.map { ($0.midiF, $0.conf) }
    }

    /// Among the frame's YIN dips, vote for the one whose harmonics best
    /// match the onset difference spectrum. Falls back to the strongest dip.
    private func onsetVote(candidates: [(frequency: Double, aperiodicity: Float)])
        -> (midiF: Double, conf: Double)? {
        let usable = candidates.filter { $0.aperiodicity < 0.55 }
        guard !usable.isEmpty else { return nil }

        let chosen: (frequency: Double, aperiodicity: Float)
        if onsetPreSpec != nil {
            chosen = usable.max(by: { salience(frequency: $0.frequency) < salience(frequency: $1.frequency) })!
        } else {
            chosen = usable.min(by: { $0.aperiodicity < $1.aperiodicity })!
        }
        // The chosen dip still needs reasonable periodicity to vote.
        guard chosen.aperiodicity < max(config.voteAperiodicityMax, 0.40) else { return nil }
        let midiF = 69.0 + 12.0 * log2(chosen.frequency / 440.0)
        return (midiF, Double(1 - chosen.aperiodicity))
    }

    /// Build and register an event, or nil if it's a same-pitch double-trigger.
    private func emit(_ kind: Event.Kind, time: Double, midiF: Double, conf: Double) -> Event? {
        let midi = Int(midiF.rounded())
        if midi == lastEmittedMidi && time - lastEmittedTime < config.samePitchDedupSeconds {
            return nil
        }
        lastEmittedMidi = midi
        lastEmittedTime = time
        let freq = 440.0 * pow(2.0, (midiF - 69.0) / 12.0)
        return Event(kind: kind, time: time, frequency: freq,
                     midiFloat: midiF, midi: midi, confidence: conf)
    }

    /// Votes within voteAgreeSemitones of the running median.
    private func agreeingVotes(_ votes: [(midiF: Double, conf: Double)]) -> [(midiF: Double, conf: Double)] {
        guard !votes.isEmpty else { return [] }
        let median = medianOf(votes.map(\.midiF))
        return votes.filter { abs($0.midiF - median) <= config.voteAgreeSemitones }
    }

    // MARK: - Spectral flux

    private func computeFlux() -> Float {
        let cfg = config
        let n = buffer.count
        let halfFFT = cfg.fftSize / 2

        buffer.withUnsafeBufferPointer { ptr in
            vDSP_vmul(ptr.baseAddress! + (n - cfg.fftSize), 1, hannWindow, 1, &windowed, 1,
                      vDSP_Length(cfg.fftSize))
        }

        windowed.withUnsafeBufferPointer { wptr in
            wptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfFFT) { cptr in
                splitReal.withUnsafeMutableBufferPointer { rptr in
                    splitImag.withUnsafeMutableBufferPointer { iptr in
                        var split = DSPSplitComplex(realp: rptr.baseAddress!, imagp: iptr.baseAddress!)
                        vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(halfFFT))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &magSq, 1, vDSP_Length(halfFFT))
                    }
                }
            }
        }

        // Keep linear magnitudes for the onset difference spectrum.
        var mags = [Float](repeating: 0, count: halfFFT)
        vvsqrtf(&mags, magSq, [Int32(halfFFT)])
        specRing.append(mags)
        if specRing.count > specRingSize { specRing.removeFirst(specRing.count - specRingSize) }

        // Log compression: L = log(1 + gamma * mag^2). Tames level dependence.
        var flux: Float = 0
        for k in 1..<halfFFT {
            let logMag = log1p(50.0 * magSq[k])
            let d = logMag - prevLogMag[k]
            if d > 0 { flux += d }
            prevLogMag[k] = logMag
        }
        return flux
    }

    // MARK: - YIN

    private var yinCorr: [Float] = []
    private var yinCumsum: [Float] = []
    private var yinCMNDF: [Float] = []

    /// All local CMNDF dips in range (candidate periods), best first.
    /// Each is (frequency, aperiodicity = CMNDF value at the dip).
    private func yinCandidates() -> [(frequency: Double, aperiodicity: Float)] {
        let cfg = config
        let w = cfg.yinWindow
        let t = maxTau
        let need = w + t
        let n = buffer.count
        guard n >= need else { return [] }

        if yinCorr.count != t + 1 {
            yinCorr = [Float](repeating: 0, count: t + 1)
            yinCumsum = [Float](repeating: 0, count: need + 1)
            yinCMNDF = [Float](repeating: 0, count: t + 1)
        }

        var results: [(frequency: Double, aperiodicity: Float)] = []
        buffer.withUnsafeBufferPointer { ptr in
            let x = ptr.baseAddress! + (n - need)

            // corr[tau] = sum_{i<w} x[i]*x[i+tau] via vectorized correlation
            vDSP_conv(x, 1, x, 1, &yinCorr, 1, vDSP_Length(t + 1), vDSP_Length(w))

            // Sliding energies via cumulative sum of squares
            yinCumsum[0] = 0
            for i in 0..<need {
                let v = x[i]
                yinCumsum[i + 1] = yinCumsum[i] + v * v
            }
            let e0 = yinCumsum[w] - yinCumsum[0]

            // d(tau) & CMNDF
            yinCMNDF[0] = 1
            var runningSum: Float = 0
            for tau in 1...t {
                let eTau = yinCumsum[tau + w] - yinCumsum[tau]
                var d = e0 + eTau - 2 * yinCorr[tau]
                if d < 0 { d = 0 }
                runningSum += d
                yinCMNDF[tau] = runningSum > 0 ? d * Float(tau) / runningSum : 1
            }

            // Collect every local minimum below 0.6 in the search range.
            for tau in (minTau + 1)..<t {
                let v = yinCMNDF[tau]
                guard v < 0.6, v <= yinCMNDF[tau - 1], v < yinCMNDF[tau + 1] else { continue }

                // Parabolic interpolation
                let s0 = yinCMNDF[tau - 1]
                let s1 = v
                let s2 = yinCMNDF[tau + 1]
                let denom = 2 * (s0 - 2 * s1 + s2)
                let adjust = denom != 0 ? (s0 - s2) / denom : 0
                let refined = Double(tau) + Double(max(-0.5, min(0.5, adjust)))

                let frequency = rate / refined
                guard frequency >= cfg.minFreq && frequency <= cfg.maxFreq else { continue }
                results.append((frequency, max(0, s1)))
            }
        }
        results.sort { $0.aperiodicity < $1.aperiodicity }
        if results.count > 6 { results.removeLast(results.count - 6) }
        return results
    }

    // MARK: - Utilities

    private func medianOf(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func medianOf(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
