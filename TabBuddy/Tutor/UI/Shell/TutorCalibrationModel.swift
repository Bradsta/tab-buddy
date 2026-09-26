//
//  TutorCalibrationModel.swift
//  TabBuddy
//
//  Calibration screen logic: latency calibration (audio clicks or visual
//  pulses) through a calibrator abstraction, route descriptions, instrument
//  pitch check, and the latency store wiring that persists into TutorStore.
//

import AVFoundation
import Foundation

// MARK: - Latency persistence

enum TutorShellLatency {
    /// The shared calibration store (`TutorLatency.store`): tutor store,
    /// mirrored to UserDefaults.
    @MainActor
    static func store(_ tutorStore: TutorStore? = nil) -> LatencyStore {
        TutorLatency.store(tutorStore)
    }
}

// MARK: - Calibrator abstraction

@MainActor
protocol TutorLatencyCalibrating: AnyObject {
    func runAudioCalibration(profile: InstrumentProfile, clicks: Int, interval: TimeInterval) async -> LatencyEstimate?
    func beginVisualCalibration(profile: InstrumentProfile) async -> Bool
    func registerVisualCue(hostTime: UInt64)
    func finishVisualCalibration() async -> LatencyEstimate?
    func cancel()
    func currentLatency() -> TimeInterval
    var isCalibrated: Bool { get }
    /// Message of the last failure, if the calibrator reports one.
    var failureMessage: String? { get }
}

extension LatencyCalibrator: TutorLatencyCalibrating {
    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }
}

// MARK: - Microphone permission

enum TutorMicPermission: Equatable {
    case undetermined, denied, granted

    static var current: TutorMicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }
}

// MARK: - View model

@MainActor
final class TutorCalibrationModel: ObservableObject {
    enum Step: Equatable {
        case idle
        case runningAudio
        /// Visual calibration: -1 while counting in, then the pulse index.
        case visual(pulse: Int)
        case finishing
        case finished(LatencyEstimate, saved: Bool)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .runningAudio, .visual, .finishing: return true
            default: return false
            }
        }
    }

    static let clickCount = 8
    static let pulseCount = 8

    @Published private(set) var step: Step = .idle
    @Published private(set) var currentLatency: TimeInterval
    @Published private(set) var isCalibrated: Bool

    let instrument: TutorInstrument
    let pulseInterval: TimeInterval
    private let calibrator: TutorLatencyCalibrating
    private let sleep: (TimeInterval) async -> Void
    private var cancelled = false

    init(calibrator: TutorLatencyCalibrating, instrument: TutorInstrument, pulseInterval: TimeInterval = 0.75,
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.calibrator = calibrator
        self.instrument = instrument
        self.pulseInterval = pulseInterval
        self.sleep = sleep
        currentLatency = calibrator.currentLatency()
        isCalibrated = calibrator.isCalibrated
    }

    var profile: InstrumentProfile { .preset(for: instrument) }

    func refresh() {
        currentLatency = calibrator.currentLatency()
        isCalibrated = calibrator.isCalibrated
    }

    /// Plays 8 clicks and listens; the learner strums along (or the mic hears the clicks).
    func runAudio() async {
        guard !step.isRunning else { return }
        cancelled = false
        step = .runningAudio
        let estimate = await calibrator.runAudioCalibration(profile: profile, clicks: Self.clickCount,
                                                            interval: pulseInterval)
        finish(estimate)
    }

    /// Shows 8 pulses (no sound); the learner plays one short note on each.
    func runVisual() async {
        guard !step.isRunning else { return }
        cancelled = false
        step = .visual(pulse: -1)
        guard await calibrator.beginVisualCalibration(profile: profile) else {
            step = .failed(calibrator.failureMessage ?? "Listening could not start.")
            return
        }
        await sleep(1.2)   // count-in
        for i in 0..<Self.pulseCount {
            guard !cancelled else { return }
            // Listening stopped under the run (interruption, route change).
            guard calibrator.failureMessage == nil else { finish(nil); return }
            step = .visual(pulse: i)
            calibrator.registerVisualCue(hostTime: mach_absolute_time())
            await sleep(pulseInterval)
        }
        guard !cancelled else { return }
        step = .finishing
        finish(await calibrator.finishVisualCalibration())
    }

    func cancel() {
        guard step.isRunning else { return }
        cancelled = true
        calibrator.cancel()
        step = .idle
    }

    private func finish(_ estimate: LatencyEstimate?) {
        guard !cancelled else { return }
        if let estimate {
            step = .finished(estimate, saved: estimate.isReliable)
        } else {
            step = .failed(calibrator.failureMessage ?? "No matching notes were heard. Try again.")
        }
        refresh()
    }

    var resultMessage: String? {
        switch step {
        case .finished(let e, let saved):
            let heard = "Matched \(e.matched) of \(e.cues) cues."
            return saved
                ? "Saved \(Self.latencyText(e.latency)) for this audio route. \(heard)"
                : "Measured \(Self.latencyText(e.latency)), but the notes were uneven, so it was not saved. \(heard) Try again with one short, clear note per cue."
        case .failed(let message):
            return message
        default:
            return nil
        }
    }

    // MARK: Formatting

    static func latencyText(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded())) ms" }

    /// "Speaker · Built-in microphone" from a route key like `out=Speaker;in=MicrophoneBuiltIn`.
    static func routeDescription(_ key: String) -> String {
        var output = "none", input = "none"
        for part in key.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "out" { output = kv[1] } else if kv[0] == "in" { input = kv[1] }
        }
        func name(_ raw: String) -> String {
            raw.split(separator: "+").map { port -> String in
                switch port {
                case "Speaker": return "Speaker"
                case "Receiver": return "Earpiece"
                case "Headphones": return "Wired headphones"
                case "BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE": return "Bluetooth"
                case "MicrophoneBuiltIn": return "Built-in microphone"
                case "MicrophoneWired", "HeadsetMicrophone": return "Headset microphone"
                case "USBAudio": return "USB audio"
                case "AirPlay": return "AirPlay"
                case "LineOut": return "Line out"
                case "LineIn": return "Line in"
                case "none": return "None"
                default: return String(port)
                }
            }.joined(separator: " + ")
        }
        return "\(name(output)) · \(name(input))"
    }

    static func isBluetoothRoute(_ key: String) -> Bool {
        key.contains("Bluetooth")
    }

    // MARK: Instrument check

    enum PitchCheck: Equatable {
        case waiting
        case match(cents: Int)
        case wrongOctave(heard: String)
        case other(heard: String)

        var isMatch: Bool { if case .match = self { return true }; return false }
    }

    /// Target of the "play your open low E" / "play middle C" check.
    static func checkTarget(for instrument: TutorInstrument) -> (midi: Int, prompt: String) {
        instrument == .guitar ? (40, "Play your open low E string (E2).") : (60, "Play middle C (C4).")
    }

    static func pitchCheck(midi: Int?, cents: Double?, target: Int) -> PitchCheck {
        guard let midi else { return .waiting }
        let heard = Pitch(midi: midi).name
        if midi == target { return .match(cents: Int((cents ?? 0).rounded())) }
        if (midi - target) % 12 == 0 { return .wrongOctave(heard: heard) }
        return .other(heard: heard)
    }

    static func pitchCheckMessage(_ check: PitchCheck, target: Int) -> String {
        let name = Pitch(midi: target).name
        switch check {
        case .waiting: return "Waiting for a note…"
        case .match(let cents):
            if abs(cents) <= 10 { return "Heard \(name), in tune. The app can hear you." }
            return "Heard \(name), \(abs(cents)) cents \(cents > 0 ? "sharp" : "flat"). The app can hear you; tune up with the tuner if needed."
        case .wrongOctave(let heard):
            return "Heard \(heard), an octave away from \(name). That can happen with strong overtones; play the note again, a little softer."
        case .other(let heard):
            return "Heard \(heard), not \(name). Check your tuning or play the target note on its own."
        }
    }
}
