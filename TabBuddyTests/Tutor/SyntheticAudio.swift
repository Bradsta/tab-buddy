//
//  SyntheticAudio.swift
//  TabBuddyTests
//
//  Deterministic test signals for the listening detectors: Karplus–Strong
//  plucked strings with body resonance and pick noise, additive inharmonic
//  piano tones with decay, pink/room noise, and silence. The models differ
//  on purpose from the detectors' partial model (other inharmonicity law,
//  detune, weak fundamentals, phone-mic high-pass) so tests do not simply
//  replay the detector's assumptions. Synthetic results are not proof of
//  real-recording accuracy.
//

import Foundation

struct SyntheticRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Uniform in [-1, 1).
    mutating func bipolar() -> Double { uniform() * 2 - 1 }
    mutating func gaussian() -> Double {
        let u1 = max(1e-12, uniform()), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

enum SyntheticAudio {
    static let sampleRate: Double = 44100

    static func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    static func silence(seconds: Double, rate: Double = sampleRate) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    /// Pink noise (Paul Kellet filter) at the given RMS.
    static func pinkNoise(seconds: Double, rms: Double, seed: UInt64, rate: Double = sampleRate) -> [Float] {
        var rng = SyntheticRNG(seed: seed)
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        for i in 0..<n {
            let w = rng.bipolar()
            b0 = 0.99886 * b0 + w * 0.0555179
            b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522
            b5 = -0.7616 * b5 - w * 0.0168980
            out[i] = Float(b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362)
            b6 = w * 0.115926
        }
        return normalized(out, rms: rms)
    }

    /// Room noise: pink noise, a little mains hum, and occasional soft clicks.
    static func roomNoise(seconds: Double, rms: Double, seed: UInt64, humHz: Double = 60,
                          rate: Double = sampleRate) -> [Float] {
        var out = pinkNoise(seconds: seconds, rms: rms, seed: seed, rate: rate)
        var rng = SyntheticRNG(seed: seed ^ 0xABCDEF)
        for i in out.indices {
            let t = Double(i) / rate
            out[i] += Float(rms * 0.3 * (sin(2 * .pi * humHz * t) + 0.5 * sin(2 * .pi * 2 * humHz * t)))
        }
        // Soft handling clicks.
        let clicks = Int(seconds * 1.5)
        for _ in 0..<clicks {
            let at = Int(rng.uniform() * Double(out.count - 400))
            for j in 0..<300 {
                out[at + j] += Float(rms * 3 * rng.bipolar() * exp(-Double(j) / 40))
            }
        }
        return out
    }

    static func normalized(_ x: [Float], rms target: Double) -> [Float] {
        let r = (x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
        guard r > 0 else { return x }
        let g = Float(target / r)
        return x.map { $0 * g }
    }

    /// Adds `src` into `dst` starting at `offset` samples (grows `dst` if needed).
    static func mix(_ src: [Float], into dst: inout [Float], at offset: Int, gain: Float = 1) {
        if dst.count < offset + src.count {
            dst.append(contentsOf: [Float](repeating: 0, count: offset + src.count - dst.count))
        }
        for i in src.indices { dst[offset + i] += src[i] * gain }
    }

    // MARK: Guitar

    /// Karplus–Strong plucked string with allpass fractional delay, pick
    /// position comb, per-note detune, and a short pick transient.
    static func pluck(midi: Int, seconds: Double, amplitude: Double = 0.3, detuneCents: Double = 0,
                      seed: UInt64, rate: Double = sampleRate) -> [Float] {
        var rng = SyntheticRNG(seed: seed)
        let f0 = frequency(midi) * pow(2, detuneCents / 1200)
        let n = Int(seconds * rate)
        // Loop delay: N + 0.5 (averager) + allpass fraction.
        let period = rate / f0
        let intDelay = Int(period - 0.5 - 0.1)
        let frac = period - 0.5 - Double(intDelay)
        let apC = (1 - frac) / (1 + frac)
        // Sustain: T60 ≈ 4 s for low strings, shorter up the neck.
        let t60 = max(1.2, 4.5 - Double(midi - 40) * 0.06)
        let loss = pow(10, -3 / (t60 * f0))

        // Excitation: noise burst, lowpassed for a warmer pick, pick-position comb.
        var line = [Double](repeating: 0, count: intDelay)
        var lp = 0.0
        for i in 0..<intDelay {
            lp = 0.6 * lp + 0.4 * rng.bipolar()
            line[i] = lp
        }
        let pickPos = max(1, Int(Double(intDelay) * (0.12 + 0.06 * rng.uniform())))
        var combed = line
        for i in 0..<intDelay { combed[i] = line[i] - (i >= pickPos ? line[i - pickPos] : 0) }
        let mean = combed.reduce(0, +) / Double(intDelay)
        line = combed.map { $0 - mean }

        var out = [Float](repeating: 0, count: n)
        var idx = 0
        var prev = 0.0
        var apX1 = 0.0, apY1 = 0.0
        for i in 0..<n {
            let cur = line[idx]
            let avg = 0.5 * (cur + prev) * loss
            prev = cur
            let ap = apC * avg + apX1 - apC * apY1
            apX1 = avg; apY1 = ap
            line[idx] = ap
            idx += 1
            if idx >= intDelay { idx = 0 }
            out[i] = Float(cur)
        }
        let peak = out.reduce(0) { max($0, abs($1)) }
        let g = Float(amplitude) / max(peak, 1e-9)
        for i in out.indices { out[i] *= g }
        // Pick click: 3 ms of bright noise.
        for i in 0..<min(n, Int(0.003 * rate)) {
            out[i] += Float(amplitude * 0.25 * rng.bipolar() * (1 - Double(i) / (0.003 * rate)))
        }
        return out
    }

    /// Body resonance thump (≈95–105 Hz damped mode plus a lower air mode).
    static func bodyThump(seconds: Double, amplitude: Double, seed: UInt64, rate: Double = sampleRate) -> [Float] {
        var rng = SyntheticRNG(seed: seed)
        let n = Int(seconds * rate)
        let f1 = 98 + 8 * rng.uniform(), f2 = 190 + 20 * rng.uniform()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            out[i] = Float(amplitude * (exp(-t / 0.06) * sin(2 * .pi * f1 * t)
                                        + 0.4 * exp(-t / 0.03) * sin(2 * .pi * f2 * t)))
        }
        return out
    }

    /// Phone-mic high-pass (2nd order, ~130 Hz): weakens low-string fundamentals.
    static func phoneMic(_ x: [Float], cutoff: Double = 130, rate: Double = sampleRate) -> [Float] {
        let w0 = 2 * .pi * cutoff / rate
        let q = 0.707
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let b0 = (1 + cw) / 2, b1 = -(1 + cw), b2 = (1 + cw) / 2
        let a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let xi = Double(x[i])
            let yi = (b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = xi; y2 = y1; y1 = yi
            y[i] = Float(yi)
        }
        return y
    }

    /// One guitar note: string + body thump, through the phone-mic filter.
    static func guitarNote(midi: Int, seconds: Double = 1.2, amplitude: Double = 0.3, seed: UInt64,
                           rate: Double = sampleRate) -> [Float] {
        var rng = SyntheticRNG(seed: seed)
        let detune = rng.bipolar() * 8
        var s = pluck(midi: midi, seconds: seconds, amplitude: amplitude, detuneCents: detune, seed: seed, rate: rate)
        let thump = bodyThump(seconds: seconds, amplitude: amplitude * 0.35, seed: seed &+ 7, rate: rate)
        mix(thump, into: &s, at: 0)
        return phoneMic(s, rate: rate)
    }

    /// A strummed guitar chord (low to high, `strumSpread` seconds across strings).
    static func guitarChord(_ pitches: [Int], seconds: Double = 1.5, amplitude: Double = 0.18,
                            strumSpread: Double = 0.03, seed: UInt64, rate: Double = sampleRate) -> [Float] {
        var rng = SyntheticRNG(seed: seed)
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        let sorted = pitches.sorted()
        for (i, p) in sorted.enumerated() {
            let offset = Int(Double(i) * strumSpread / Double(max(1, sorted.count - 1)) * rate)
            let amp = amplitude * (0.75 + 0.5 * rng.uniform())
            let detune = rng.bipolar() * 8
            let s = pluck(midi: p, seconds: seconds - Double(offset) / rate, amplitude: amp,
                          detuneCents: detune, seed: seed &+ UInt64(i * 31 + 1), rate: rate)
            mix(s, into: &out, at: offset)
        }
        let thump = bodyThump(seconds: seconds, amplitude: amplitude * 0.5, seed: seed &+ 99, rate: rate)
        mix(thump, into: &out, at: 0)
        return phoneMic(out, rate: rate)
    }

    // MARK: Room

    /// Schroeder reverb (4 combs + 2 allpasses) mixed with the dry signal.
    /// Models a device on a stand 0.5–1.5 m away: `wet` near 1 means the
    /// reverberant field is as loud as the direct sound.
    static func room(_ x: [Float], rt60: Double = 0.6, wet: Double = 0.7, tailSeconds: Double = 0.4,
                     rate: Double = sampleRate) -> [Float] {
        var input = x
        input.append(contentsOf: [Float](repeating: 0, count: Int(tailSeconds * rate)))
        let combDelays = [0.0297, 0.0371, 0.0411, 0.0437].map { Int($0 * rate) }
        var wetOut = [Double](repeating: 0, count: input.count)
        for d in combDelays {
            let g = pow(10, -3 * Double(d) / rate / rt60)
            var buf = [Double](repeating: 0, count: d)
            var idx = 0
            var lp = 0.0
            for i in input.indices {
                let y = buf[idx]
                lp = 0.8 * y + 0.2 * lp          // air/wall damping
                buf[idx] = Double(input[i]) + g * lp
                idx = (idx + 1) % d
                wetOut[i] += y * 0.25
            }
        }
        for (dSec, g) in [(0.005, 0.7), (0.0017, 0.7)] {
            let d = Int(dSec * rate)
            var buf = [Double](repeating: 0, count: d)
            var idx = 0
            for i in wetOut.indices {
                let b = buf[idx]
                let y = -g * wetOut[i] + b
                buf[idx] = wetOut[i] + g * y
                idx = (idx + 1) % d
                wetOut[i] = y
            }
        }
        var out = [Float](repeating: 0, count: input.count)
        for i in out.indices { out[i] = input[i] + Float(wet * wetOut[i] * 2.5) }
        return out
    }

    /// A "distant iPad" rendering: level drop plus room reverb.
    static func distant(_ x: [Float], gain: Float = 0.12, rt60: Double = 0.6, wet: Double = 0.8,
                        rate: Double = sampleRate) -> [Float] {
        room(x.map { $0 * gain }, rt60: rt60, wet: wet, rate: rate)
    }

    // MARK: Piano

    /// Additive piano tone: stiff-string partials (B law differs from the
    /// detector's), two slightly detuned unison strings, register-dependent
    /// partial rolloff, weak bass fundamentals, two-stage decay, hammer knock.
    static func pianoNote(midi: Int, seconds: Double = 1.2, amplitude: Double = 0.25, seed: UInt64,
                          rate: Double = sampleRate) -> [Float] {
        var rng = SyntheticRNG(seed: seed)
        let n = Int(seconds * rate)
        let f0 = frequency(midi) * pow(2, rng.bipolar() * 4 / 1200)
        // B: ~1.5e-4 in the bass rising to ~6e-3 at the top.
        let b = 0.00032 * pow(2, Double(midi - 60) / 15)
        var partials: [(f: Double, a: Double, tau: Double, detune: Double)] = []
        let nyq = rate * 0.45
        var h = 1
        while h <= 40 {
            let f = Double(h) * f0 * (1 + b * Double(h * h)).squareRoot()
            if f > min(nyq, 10000) { break }
            var a = 1 / pow(Double(h), 0.9 + Double(midi - 21) / 90)
            if midi < 40 && h == 1 { a *= 0.25 }       // weak bass fundamental
            if midi < 33 && h == 2 { a *= 0.6 }
            a *= 0.7 + 0.6 * rng.uniform()
            let tau = max(0.08, (2.8 - Double(midi - 21) * 0.025) / (1 + 0.15 * Double(h - 1)))
            partials.append((f, a, tau, 1 + rng.bipolar() * 0.0006))
            h += 1
        }
        var out = [Float](repeating: 0, count: n)
        for p in partials {
            let w1 = 2 * .pi * p.f / rate, w2 = w1 * p.detune
            let ph1 = rng.uniform() * 2 * .pi, ph2 = rng.uniform() * 2 * .pi
            let d1 = exp(-1 / (p.tau * 0.35 * rate)), d2 = exp(-1 / (p.tau * rate))
            var e1 = 0.6, e2 = 0.4
            for i in 0..<n {
                let s = sin(w1 * Double(i) + ph1) + sin(w2 * Double(i) + ph2)
                out[i] += Float(p.a * (e1 + e2) * 0.5 * s)
                e1 *= d1; e2 *= d2
            }
        }
        let peak = out.prefix(Int(0.1 * rate)).reduce(0) { max($0, abs($1)) }
        let g = Float(amplitude) / max(peak, 1e-9)
        for i in out.indices { out[i] *= g }
        // Hammer knock: 5 ms decaying noise.
        let knock = Int(0.005 * rate)
        for i in 0..<min(n, knock) {
            out[i] += Float(amplitude * 0.15 * rng.bipolar() * exp(-Double(i) / Double(knock / 3)))
        }
        return out
    }

    static func pianoChord(_ pitches: [Int], seconds: Double = 1.5, amplitude: Double = 0.18,
                           seed: UInt64, rate: Double = sampleRate) -> [Float] {
        var rng = SyntheticRNG(seed: seed)
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        for (i, p) in pitches.enumerated() {
            let offset = Int(rng.uniform() * 0.012 * rate)
            let s = pianoNote(midi: p, seconds: seconds - Double(offset) / rate,
                              amplitude: amplitude * (0.8 + 0.4 * rng.uniform()),
                              seed: seed &+ UInt64(i * 17 + 3), rate: rate)
            mix(s, into: &out, at: offset)
        }
        return out
    }

    // MARK: Vocabulary

    /// Open-chord voicings (sounding MIDI, standard tuning).
    static let openChords: [String: [Int]] = [
        "E":  [40, 47, 52, 56, 59, 64],
        "A":  [45, 52, 57, 61, 64],
        "D":  [50, 57, 62, 66],
        "G":  [43, 47, 50, 55, 59, 67],
        "C":  [48, 52, 55, 60, 64],
        "Am": [45, 52, 57, 60, 64],
        "Em": [40, 47, 52, 55, 59, 64],
        "Dm": [50, 57, 62, 65],
    ]
}
