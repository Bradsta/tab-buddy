//
//  ListeningDSP.swift
//  TabBuddy
//
//  Shared DSP building blocks for the tutor detectors: pitch math, a
//  streaming FIR decimator, amplitude-normalized spectra, local-median
//  whitening, and a spectral-flux onset detector. Pure Swift + Accelerate
//  (no AVFoundation) so everything runs against synthetic arrays in tests.
//

import Foundation
import Accelerate

// MARK: - Pitch math

enum ListeningMath {
    static func frequency(midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
    static func frequency(midi: Int) -> Double { frequency(midi: Double(midi)) }
    static func midi(frequency: Double) -> Double { 69 + 12 * log2(frequency / 440) }

    /// Frequency of partial `h` (1-based) of a stiff string.
    static func partial(_ h: Int, f0: Double, inharmonicity b: Double) -> Double {
        let hd = Double(h)
        return hd * f0 * (b > 0 ? (1 + b * hd * hd).squareRoot() : 1)
    }

    /// Internal analysis decimation factor for an input rate (≈22–24 kHz internal).
    static func decimationFactor(forInputRate rate: Double) -> Int {
        rate >= 32000 ? 2 : 1
    }
}

// MARK: - Decimator

/// Streaming low-pass FIR + integer decimation. Output sample n corresponds to
/// input sample n·factor (the 0.3 ms filter delay is ignored).
final class ListeningDecimator {
    let factor: Int
    private let taps: [Float]
    private var carry: [Float] = []

    init(factor: Int) {
        self.factor = max(1, factor)
        let count = 31
        let m = Double(count - 1) / 2
        let cutoff = 0.45 / Double(self.factor)   // cycles/sample at input rate
        var t = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let x = Double(i) - m
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let blackman = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(count - 1))
                + 0.08 * cos(4 * .pi * Double(i) / Double(count - 1))
            t[i] = Float(sinc * blackman)
        }
        let sum = t.reduce(0, +)
        taps = t.map { $0 / sum }
        // Prime with zeros so output index n aligns with input index n·factor.
        carry = [Float](repeating: 0, count: count / 2)
    }

    func reset() { carry = [Float](repeating: 0, count: taps.count / 2) }

    func process(_ input: [Float]) -> [Float] {
        guard factor > 1 else { return input }
        carry.append(contentsOf: input)
        guard carry.count >= taps.count else { return [] }
        let outCount = (carry.count - taps.count) / factor + 1
        var out = [Float](repeating: 0, count: outCount)
        carry.withUnsafeBufferPointer { src in
            vDSP_desamp(src.baseAddress!, vDSP_Stride(factor), taps, &out,
                        vDSP_Length(outCount), vDSP_Length(taps.count))
        }
        carry.removeFirst(outCount * factor)
        return out
    }
}

// MARK: - Spectrum

/// Hann-windowed, zero-padded magnitude spectra normalized so a sinusoid of
/// amplitude A peaks at ≈A regardless of window length.
final class ListeningSpectrum {
    private let maxLog2n: vDSP_Length = 16
    private let setup: FFTSetup
    private var windows: [Int: (window: [Float], sum: Float)] = [:]

    init() {
        setup = vDSP_create_fftsetup(maxLog2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Magnitudes (fftSize/2 bins, bin width rate/fftSize) of `samples`,
    /// windowed over their own length and zero-padded to `fftSize`.
    func magnitudes(_ samples: ArraySlice<Float>, fftSize: Int) -> [Float] {
        let n = samples.count
        precondition(fftSize >= n && fftSize.nonzeroBitCount == 1)
        let log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        precondition(log2n <= maxLog2n)
        let win = window(length: n)
        var buffer = [Float](repeating: 0, count: fftSize)
        samples.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress!, 1, win.window, 1, &buffer, 1, vDSP_Length(n))
        }
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        buffer.withUnsafeBufferPointer { bptr in
            bptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cptr in
                real.withUnsafeMutableBufferPointer { rptr in
                    imag.withUnsafeMutableBufferPointer { iptr in
                        var split = DSPSplitComplex(realp: rptr.baseAddress!, imagp: iptr.baseAddress!)
                        vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        split.imagp[0] = 0   // packed Nyquist term
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
            }
        }
        var scale = 1 / max(win.sum, 1e-9)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(half))
        return mags
    }

    private func window(length n: Int) -> (window: [Float], sum: Float) {
        if let w = windows[n] { return w }
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        var sum: Float = 0
        vDSP_sve(w, 1, &sum, vDSP_Length(n))
        windows[n] = (w, sum)
        return (w, sum)
    }
}

// MARK: - Local statistics

enum ListeningStats {
    /// Running median of `x[0..<count]` over ±`halfWidth` bins, evaluated on a
    /// grid of `step` bins and linearly interpolated (fast enough for Debug builds).
    static func localMedian(_ x: [Float], count: Int, halfWidth: Int, step: Int = 4) -> [Float] {
        let n = min(count, x.count)
        guard n > 0 else { return [] }
        let st = max(1, step)
        var gridIdx: [Int] = []
        var gridVal: [Float] = []
        var scratch = [Float](repeating: 0, count: 2 * halfWidth + 1)
        var i = 0
        while true {
            let lo = max(0, i - halfWidth), hi = min(n - 1, i + halfWidth)
            let len = hi - lo + 1
            for j in 0..<len { scratch[j] = x[lo + j] }
            scratch.withUnsafeMutableBufferPointer { p in
                vDSP_vsort(p.baseAddress!, vDSP_Length(len), 1)
            }
            gridIdx.append(i)
            gridVal.append(scratch[len / 2])
            if i >= n - 1 { break }
            i = min(n - 1, i + st)
        }
        var out = [Float](repeating: 0, count: n)
        for g in 0..<(gridIdx.count - 1) {
            let a = gridIdx[g], b = gridIdx[g + 1]
            let va = gridVal[g], vb = gridVal[g + 1]
            let span = Float(b - a)
            for k in a..<b { out[k] = va + (vb - va) * Float(k - a) / span }
        }
        out[n - 1] = gridVal.last!
        return out
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &r, vDSP_Length($0.count)) }
        return r
    }
}

// MARK: - Onset detection

/// Spectral-flux onset detector on log magnitudes with a per-bin tracked noise
/// floor, so stationary noise produces little flux at any level. Sample-clock
/// driven: indices are at the detector's (internal) rate.
final class ListeningOnsetDetector {
    struct Onset: Hashable {
        /// Sample index (internal rate) of the estimated physical onset.
        var index: Int
        var strength: Float
    }

    let rate: Double
    let fftSize: Int
    let hop: Int
    private let thresholdFactor: Float
    private let thresholdFloor: Float
    private let minimumGate: Float
    private let gateFactor: Float
    /// Tracked room-noise RMS (minimum statistics over frames).
    private(set) var noiseFloorRMS: Float = 0
    /// Current adaptive silence gate (linear RMS).
    var gateRMS: Float { max(minimumGate, noiseFloorRMS * gateFactor) }
    private let refractory: Int
    private let medianFrames = 30
    private let loBin: Int
    private let hiBin: Int

    private let spectrum = ListeningSpectrum()
    private var ring: [Float]
    private var ringFill = 0
    private var sinceHop = 0
    private var clock = 0
    private var prevLog: [Float]
    private var noise: [Float]
    private var fluxHistory: [Float] = []
    private var frameEnds: [Int] = []
    private var lastOnset = Int.min / 2
    private var frames = 0
    private var prevRMS: Float = 0

    init(rate: Double, profile: InstrumentProfile) {
        self.rate = rate
        fftSize = rate > 30000 ? 2048 : 1024
        hop = max(64, Int((rate * 0.01).rounded()))
        thresholdFactor = profile.onsetThresholdFactor
        thresholdFloor = profile.onsetThresholdFloor
        minimumGate = profile.minimumGateRMS
        gateFactor = profile.noiseGateFactor
        refractory = Int(rate * 0.08)
        let binHz = rate / Double(fftSize)
        loBin = max(1, Int(60 / binHz))
        hiBin = min(fftSize / 2 - 1, Int(min(7000, rate * 0.45) / binHz))
        ring = [Float](repeating: 0, count: fftSize)
        prevLog = [Float](repeating: 0, count: fftSize / 2)
        noise = [Float](repeating: 0, count: fftSize / 2)
    }

    /// Samples consumed so far (internal-rate clock).
    var sampleClock: Int { clock }

    /// Starts the clock at `index` (internal rate) so onsets carry take-clock
    /// indices when the first chunk is not the take's first. Only before the
    /// first sample.
    func seed(clock index: Int) {
        guard ringFill == 0 else { return }
        clock = index
    }

    func process(_ samples: [Float]) -> [Onset] {
        var out: [Onset] = []
        for s in samples {
            ring[ringFill % fftSize] = s
            ringFill += 1
            clock += 1
            sinceHop += 1
            if sinceHop >= hop, ringFill >= fftSize {
                sinceHop = 0
                if let o = frame() { out.append(o) }
            }
        }
        return out
    }

    private func frame() -> Onset? {
        // Unroll the ring in time order.
        let start = ringFill % fftSize
        var frameSamples = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize { frameSamples[i] = ring[(start + i) % fftSize] }
        let rms = ListeningStats.rms(frameSamples[...])
        let mags = spectrum.magnitudes(frameSamples[...], fftSize: fftSize)
        frames += 1
        // Noise floor: falls fast, rises ~1.35x per second (sustained notes
        // must not lift it much before they decay).
        if frames == 1 || rms < noiseFloorRMS { noiseFloorRMS = frames == 1 ? rms : 0.8 * noiseFloorRMS + 0.2 * rms }
        else { noiseFloorRMS = min(noiseFloorRMS * 1.003, rms) }
        let rmsGate = gateRMS

        // Absolute floor ≈ -90 dBFS per bin keeps digital silence inert.
        let absFloor: Float = 3e-5
        var flux: Float = 0
        for k in loBin...hiBin {
            let m = mags[k]
            // Minimum-statistics noise tracker: falls fast, rises ~1.6x/s.
            if frames == 1 { noise[k] = m }
            else if m < noise[k] { noise[k] = 0.7 * noise[k] + 0.3 * m }
            else { noise[k] *= 1.005 }
            let floor = max(absFloor, 3 * noise[k])
            let l = log(m + floor)
            if frames > 1 {
                let d = l - prevLog[k]
                if d > 0 { flux += d }
            }
            prevLog[k] = l
        }
        fluxHistory.append(flux)
        frameEnds.append(clock)
        if fluxHistory.count > medianFrames + 3 {
            fluxHistory.removeFirst()
            frameEnds.removeFirst()
        }
        let c = fluxHistory.count
        guard c >= 3 else { return nil }
        let prev = fluxHistory[c - 2], cur = fluxHistory[c - 1], prev2 = fluxHistory[c - 3]
        let past = Array(fluxHistory.prefix(c - 2))
        let median = past.isEmpty ? 0 : past.sorted()[past.count / 2]
        let threshold = median * thresholdFactor + thresholdFloor
        guard prev > threshold, prev >= prev2, prev >= cur, prevRMS >= rmsGate || rms >= rmsGate else {
            prevRMS = rms
            return nil
        }
        prevRMS = rms
        // The flux peak frame's window just took in the attack; place the
        // onset one hop before that window's end.
        let index = max(0, frameEnds[c - 2] - hop)
        guard index - lastOnset >= refractory else { return nil }
        lastOnset = index
        return Onset(index: index, strength: prev)
    }
}
