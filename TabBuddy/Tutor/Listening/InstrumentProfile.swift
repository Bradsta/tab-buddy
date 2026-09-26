//
//  InstrumentProfile.swift
//  TabBuddy
//
//  Per-instrument listening parameters (TUTOR_IMPLEMENTATION.md §4).
//  Thresholds were tuned on synthetic audio only (TabBuddyTests/Tutor/
//  SyntheticAudio.swift); validation on real recordings is pending.
//

import Foundation

struct InstrumentProfile: Hashable, Sendable {
    var instrument: TutorInstrument
    /// Sounding MIDI range the detectors search.
    var pitchRange: ClosedRange<Int>
    /// Frequency band (Hz) whose onset energy is de-emphasized before pitch
    /// evidence is summed (acoustic guitar body thump). Nil = none.
    var whiteningBand: ClosedRange<Double>?
    /// Gain applied inside `whiteningBand` (0 = ignore, 1 = no change).
    var whiteningBandGain: Float
    /// Partials summed per candidate pitch.
    var harmonicCount: Int
    /// Stiff-string inharmonicity coefficient B at middle C (MIDI 60).
    /// Partial h sits at h·f0·sqrt(1 + B·h²).
    var inharmonicityAtMiddleC: Double
    /// B doubles every this many semitones upward (0 = constant B).
    var inharmonicityDoublingSemitones: Double
    /// Absolute lower bound (linear RMS) of the silence gate.
    var minimumGateRMS: Float
    /// The gate follows the tracked room-noise RMS times this factor, so a
    /// distant device (iPad on a stand 0.5–1.5 m away) in a noisy room still
    /// gates correctly without a fixed level.
    var noiseGateFactor: Float
    /// Onset threshold = median(recent flux) · factor + floor.
    var onsetThresholdFactor: Float
    var onsetThresholdFloor: Float
    /// Upper bound on simultaneous pitches for multipitch estimation.
    var maxPolyphony: Int
    /// A further pitch is accepted only while its salience is at least this
    /// fraction of the first (strongest) pitch's salience.
    var polyphonyStopRatio: Float
    /// Highest partial frequency considered (phone mics and room noise make
    /// the top of the spectrum unreliable).
    var maxPartialHz: Double
    /// Expected events whose lowest pitch is below this use the long
    /// (low-register) verifier window.
    var lowNoteWindowBelowMIDI: Int = 36
    /// Long-window length override (nil = the verifier's `bassWindowSeconds`).
    var lowNoteWindowSeconds: TimeInterval? = nil
    /// Monophonic (YIN) search range in Hz; nil keeps the detector default.
    var monophonicFrequencyRange: ClosedRange<Double>? = nil

    /// Inharmonicity coefficient for a pitch.
    func inharmonicity(midi: Int) -> Double {
        guard inharmonicityAtMiddleC > 0 else { return 0 }
        guard inharmonicityDoublingSemitones > 0 else { return inharmonicityAtMiddleC }
        return inharmonicityAtMiddleC * pow(2, Double(midi - 60) / inharmonicityDoublingSemitones)
    }

    /// Acoustic guitar through the built-in microphone. Range covers drop D
    /// up to the 24th fret of the high E string.
    static let acousticGuitar = InstrumentProfile(
        instrument: .guitar,
        pitchRange: 38...88,
        whiteningBand: 73...110,
        whiteningBandGain: 0.3,
        harmonicCount: 30,
        inharmonicityAtMiddleC: 0,
        inharmonicityDoublingSemitones: 0,
        minimumGateRMS: 0.0003,
        noiseGateFactor: 2.5,
        onsetThresholdFactor: 1.8,
        onsetThresholdFloor: 6,
        maxPolyphony: 6,
        polyphonyStopRatio: 0.12,
        maxPartialHz: 6000)

    /// Acoustic piano through the built-in microphone, full 88 keys.
    /// B ≈ 0.0004 at middle C, rising toward the treble.
    static let piano = InstrumentProfile(
        instrument: .piano,
        pitchRange: 21...108,
        whiteningBand: nil,
        whiteningBandGain: 1,
        harmonicCount: 30,
        inharmonicityAtMiddleC: 0.0004,
        inharmonicityDoublingSemitones: 14,
        minimumGateRMS: 0.0003,
        noiseGateFactor: 2.5,
        onsetThresholdFactor: 1.8,
        onsetThresholdFloor: 6,
        maxPolyphony: 10,
        polyphonyStopRatio: 0.10,
        maxPartialHz: 8000)

    /// Electric or acoustic bass guitar (4-string E1 up to the 24th fret of
    /// the G string at G4; 5-string low B is below the analysis floor). Low
    /// fundamentals need longer analysis windows, and the body-thump band sits
    /// on the fundamentals, so there is no whitening band. Bass lines are
    /// mostly single notes and double stops.
    static let bassGuitar = InstrumentProfile(
        instrument: .guitar,
        pitchRange: 28...67,
        whiteningBand: nil,
        whiteningBandGain: 1,
        harmonicCount: 24,
        inharmonicityAtMiddleC: 0,
        inharmonicityDoublingSemitones: 0,
        minimumGateRMS: 0.0003,
        noiseGateFactor: 2.5,
        onsetThresholdFactor: 1.8,
        onsetThresholdFloor: 6,
        maxPolyphony: 3,
        polyphonyStopRatio: 0.15,
        maxPartialHz: 4000,
        lowNoteWindowBelowMIDI: 48,
        lowNoteWindowSeconds: 0.36,
        monophonicFrequencyRange: 38...420)

    static func preset(for instrument: TutorInstrument) -> InstrumentProfile {
        switch instrument {
        case .guitar: return .acousticGuitar
        case .piano: return .piano
        }
    }

    /// Preset for an instrument, returning `bassGuitar` for a bass part.
    static func preset(for instrument: TutorInstrument, isBass: Bool) -> InstrumentProfile {
        instrument == .guitar && isBass ? .bassGuitar : preset(for: instrument)
    }

    /// Preset for a guitar part from its sounding pitches: any pitch below
    /// the guitar range (drop D, MIDI 38) selects `bassGuitar`.
    static func preset(for instrument: TutorInstrument, pitches: some Sequence<Int>) -> InstrumentProfile {
        let lowest = pitches.min()
        return preset(for: instrument, isBass: lowest.map { $0 < acousticGuitar.pitchRange.lowerBound } ?? false)
    }

    /// True for the bass-guitar preset (range starts below guitar).
    var isBass: Bool { instrument == .guitar && pitchRange.lowerBound < 38 }
}
