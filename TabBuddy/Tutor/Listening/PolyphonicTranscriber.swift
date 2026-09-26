//
//  PolyphonicTranscriber.swift
//  TabBuddy
//
//  Tier C post-take transcription (TUTOR_IMPLEMENTATION.md §4). The protocol
//  leaves room for a bundled Core ML model later; the default implementation
//  is DSP only: onset segmentation, then per-segment iterative harmonic-sum
//  estimation with spectral subtraction (Klapuri-style) on the whitened
//  onset-difference spectrum, with stiff-string inharmonicity for piano.
//  Tuned on synthetic audio; real-recording validation is pending.
//

import Foundation
import AVFoundation

protocol PolyphonicTranscriber {
    /// Transcribes a recorded take. Event times are seconds from the file start.
    func transcribe(url: URL, profile: InstrumentProfile) async throws -> [DetectedEvent]
}

final class IterativeHarmonicTranscriber: PolyphonicTranscriber {

    struct Config {
        /// Longest analysis window after an onset (shortened by the next onset).
        var windowSeconds: Double = 0.37
        var preGuard: TimeInterval = 0.012
        /// Subtracted from event times (take clock correction).
        var latencyCompensation: TimeInterval = 0
        /// Pitches below this confidence are dropped.
        var minConfidence: Double = 0.3
        init() {}
    }

    var config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    func transcribe(url: URL, profile: InstrumentProfile) async throws -> [DetectedEvent] {
        let config = self.config
        return try await Task.detached(priority: .userInitiated) {
            let (samples, rate) = try Self.readMono(url: url)
            return IterativeHarmonicTranscriber(config: config)
                .transcribe(samples: samples, sampleRate: rate, profile: profile)
        }.value
    }

    /// Synchronous transcription of a mono sample array (input rate).
    func transcribe(samples: [Float], sampleRate: Double, profile: InstrumentProfile) -> [DetectedEvent] {
        let factor = ListeningMath.decimationFactor(forInputRate: sampleRate)
        let decimator = ListeningDecimator(factor: factor)
        let rate = sampleRate / Double(factor)
        var signal = decimator.process(samples)
        // Flush the filter tail.
        signal.append(contentsOf: decimator.process([Float](repeating: 0, count: 64 * factor)))

        let detector = ListeningOnsetDetector(rate: rate, profile: profile)
        var onsets: [Int] = []
        var gates: [Float] = []
        // Feed in hop-sized chunks so the adaptive gate at each onset is known.
        let chunk = 1024
        var i = 0
        while i < signal.count {
            let e = min(signal.count, i + chunk)
            for o in detector.process(Array(signal[i..<e])) {
                onsets.append(o.index)
                gates.append(detector.gateRMS)
            }
            i = e
        }

        let spectrum = ListeningSpectrum()
        let estimator = HarmonicEstimator(profile: profile)
        let n = ListeningVerifierMath.powerOfTwo(near: rate * config.windowSeconds)
        var events: [DetectedEvent] = []
        for (k, o) in onsets.enumerated() {
            let next = k + 1 < onsets.count ? onsets[k + 1] : signal.count
            let prev = k > 0 ? onsets[k - 1] : nil
            guard let ev = OnsetWindows.evidence(
                onset: o, previousOnset: prev, length: n, end: next, earliest: 0, rate: rate,
                preGuard: config.preGuard, gateRMS: gates[k], spectrum: spectrum, estimator: estimator,
                slice: { start, len in
                    guard start >= 0, len > 0, start + len <= signal.count else { return nil }
                    return signal[start..<(start + len)]
                }) else { continue }
            var found = estimator.estimate(ev)
            found = estimator.refineOctaves(found, evidence: ev, trustPicks: true)
            found = estimator.pruneExplained(found, evidence: ev, expected: [])
            found = estimator.removeGhosts(found)
            found = found.filter { $0.confidence >= config.minConfidence }
            guard !found.isEmpty else { continue }
            found.sort { $0.midi < $1.midi }
            events.append(DetectedEvent(time: Double(o) / rate - config.latencyCompensation,
                                        pitches: found.map(\.midi),
                                        confidences: found.map(\.confidence),
                                        source: .polyphonic))
        }
        return events
    }

    /// Reads any AVAudioFile-readable file as mono Float samples (channel mean).
    static func readMono(url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard let data = buffer.floatChannelData else { return ([], format.sampleRate) }
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channels {
            let ptr = data[c]
            for i in 0..<count { mono[i] += ptr[i] }
        }
        if channels > 1 {
            let g = 1 / Float(channels)
            for i in 0..<count { mono[i] *= g }
        }
        return (mono, format.sampleRate)
    }
}
