//
//  MonophonicListener.swift
//  TabBuddy
//
//  Tier A adapter: runs the existing NoteTranscriberCore (onset + YIN voting,
//  unchanged) on tutor input and emits DetectedEvent (source .monophonic) for
//  "play any C" drills and ear-training answers, plus the live frequency and
//  cents offset for a tuner-style needle. Sample-clock driven; no AVFoundation.
//

import Foundation

/// Not thread-safe: confine each instance to one queue.
final class MonophonicListener: @unchecked Sendable {
    let profile: InstrumentProfile
    let sampleRate: Double
    /// Subtracted from event times (take clock correction).
    var latencyCompensation: TimeInterval = 0

    private let core: NoteTranscriberCore

    init(sampleRate: Double, profile: InstrumentProfile) {
        self.profile = profile
        self.sampleRate = sampleRate
        var config = NoteTranscriberCore.Config()
        switch profile.instrument {
        case .guitar:
            break   // the core's defaults target guitar
        case .piano:
            // YIN range for piano's melodic register; the verifier covers the extremes.
            config.minFreq = 50
            config.maxFreq = 2100
        }
        if let range = profile.monophonicFrequencyRange {
            config.minFreq = range.lowerBound
            config.maxFreq = range.upperBound
            // Two periods of the lowest fundamental at the internal rate.
            let needed = Int((2 * config.targetRate / range.lowerBound).rounded(.up))
            while config.yinWindow < needed { config.yinWindow *= 2 }
        }
        core = NoteTranscriberCore(sampleRate: sampleRate, config: config)
    }

    func reset() { core.reset() }

    /// Take-clock seconds of the first sample fed (see `process(samples:startSample:)`).
    private var timeOffset: TimeInterval = 0
    private var seeded = false

    /// Feeds a chunk starting at take-clock sample `startSample`; the first
    /// call sets the time offset.
    func process(samples: [Float], startSample: Int) -> [DetectedEvent] {
        if !seeded {
            seeded = true
            timeOffset = Double(startSample) / sampleRate
        }
        return process(samples: samples)
    }

    /// Feeds mono samples at the input rate; returns notes completed in this chunk.
    func process(samples: [Float]) -> [DetectedEvent] {
        seeded = true
        return core.process(samples).map { e in
            DetectedEvent(time: e.time + timeOffset - latencyCompensation, pitches: [e.midi],
                          confidences: [min(1, max(0, e.confidence))], source: .monophonic)
        }
    }

    /// Live pitch of the latest frame, nil between notes.
    var livePitch: LivePitch? {
        guard let p = core.livePitch, p.frequency > 0 else { return nil }
        let midiF = ListeningMath.midi(frequency: p.frequency)
        return LivePitch(frequency: p.frequency, midi: Int(midiF.rounded()),
                         cents: (midiF - midiF.rounded()) * 100, confidence: p.confidence)
    }

    struct LivePitch: Hashable, Sendable {
        var frequency: Double
        var midi: Int
        /// Offset from the nearest equal-tempered pitch, -50...+50.
        var cents: Double
        var confidence: Double
    }
}
