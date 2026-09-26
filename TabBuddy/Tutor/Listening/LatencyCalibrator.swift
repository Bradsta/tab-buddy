//
//  LatencyCalibrator.swift
//  TabBuddy
//
//  Measures the offset between a cue and the matching input onset, per audio
//  route (TUTOR_IMPLEMENTATION.md §4).
//
//  • Audio: plays 8 clicks with output allowed and listens at the same time.
//    On a speaker route the microphone usually hears the click itself, so the
//    median onset offset is the device's round trip; with headphones it is
//    the player's strum/tap against the click. Either way the result is the
//    offset grading needs.
//  • Visual fallback: the UI shows 8 pulses and reports each pulse's host
//    time (ideally the display link's target timestamp); the player taps or
//    strums along; no audio output.
//
//  Both measure the quantity grading subtracts from detections: the delay
//  from a cue (host time mapped onto the take clock) to the detected onset
//  (sample position). For audio clicks the output latency is removed, since
//  graded cues are visual.
//
//  Results persist through `LatencyStore`; `TutorLatency.store()` is the one
//  shared store (tutor store, mirrored to UserDefaults). Default 0.08 s until
//  calibrated. The route key separates built-in mic, USB-C/Lightning
//  interfaces, wired and Bluetooth routes.
//

import AVFoundation
import Combine

/// Persistence for calibrated latency, keyed by `TutorAudioSession.currentRouteKey()`.
@MainActor
protocol LatencyStore: AnyObject {
    func latency(forRoute routeKey: String) -> Double?
    func setLatency(_ seconds: Double, forRoute routeKey: String)
}

/// UserDefaults-backed latency storage (independent of the tutor SwiftData store).
@MainActor
final class UserDefaultsLatencyStore: LatencyStore {
    private let defaults: UserDefaults
    private let prefix = "tutor.latency."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func latency(forRoute routeKey: String) -> Double? {
        defaults.object(forKey: prefix + routeKey) as? Double
    }

    func setLatency(_ seconds: Double, forRoute routeKey: String) {
        defaults.set(seconds, forKey: prefix + routeKey)
    }
}

/// Adapter for any other storage, e.g.
/// `ClosureLatencyStore(get: { TutorStore.shared.latency(forRoute: $0) },
///                      set: { TutorStore.shared.setLatency($0, forRoute: $1) })`.
@MainActor
final class ClosureLatencyStore: LatencyStore {
    private let get: (String) -> Double?
    private let set: (Double, String) -> Void

    init(get: @escaping (String) -> Double?, set: @escaping (Double, String) -> Void) {
        self.get = get
        self.set = set
    }

    func latency(forRoute routeKey: String) -> Double? { get(routeKey) }
    func setLatency(_ seconds: Double, forRoute routeKey: String) { set(seconds, routeKey) }
}

/// The single calibration source for lessons, practice mode, games, and the
/// calibration screen: the tutor store (`CalibrationRecord`), falling back to
/// and mirrored into UserDefaults. Keys that cannot describe a listening
/// route (`in=none`, written before routes were predicted) are ignored.
enum TutorLatency {
    @MainActor
    static func store(_ tutorStore: TutorStore? = nil, defaults: UserDefaults = .standard) -> LatencyStore {
        let tutorStore = tutorStore ?? .shared
        let mirror = UserDefaultsLatencyStore(defaults: defaults)
        return ClosureLatencyStore(
            get: { route in
                guard TutorAudioSession.isUsableRouteKey(route) else { return nil }
                return tutorStore.latency(forRoute: route) ?? mirror.latency(forRoute: route)
            },
            set: { seconds, route in
                guard TutorAudioSession.isUsableRouteKey(route) else { return }
                tutorStore.setLatency(seconds, forRoute: route)
                mirror.setLatency(seconds, forRoute: route)
            })
    }
}

struct LatencyEstimate: Hashable, Sendable {
    /// Median cue → onset offset in seconds.
    var latency: TimeInterval
    /// Median absolute deviation of the offsets.
    var spread: TimeInterval
    var matched: Int
    var cues: Int
    /// Enough matches and a tight spread.
    var isReliable: Bool { matched >= max(4, cues / 2) && spread <= 0.035 }
}

@MainActor
final class LatencyCalibrator: ObservableObject {
    static let defaultLatency: TimeInterval = 0.08

    enum Phase: Equatable {
        case idle
        case running
        case finished(LatencyEstimate)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Cue index the UI should highlight (visual calibration), -1 when none.
    @Published private(set) var cueIndex = -1

    let session: TutorAudioSession
    let store: LatencyStore
    private var consumer: UUID?
    private let onsets = OnsetCollector()
    private var visualCues: [TimeInterval] = []
    /// Route of the running calibration (read while listening).
    private var runRouteKey: String?

    init(session: TutorAudioSession? = nil, store: LatencyStore? = nil) {
        let session = session ?? .shared
        self.session = session
        self.store = store ?? TutorLatency.store()
        stopObserver = TutorObserverToken(NotificationCenter.default.addObserver(
            forName: .tutorListeningDidStop, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.inputStoppedElsewhere() }
            })
    }

    /// Stored latency for the current route, or the default.
    func currentLatency() -> TimeInterval {
        store.latency(forRoute: TutorAudioSession.currentRouteKey()) ?? Self.defaultLatency
    }

    /// Whether the current route has been calibrated.
    var isCalibrated: Bool { store.latency(forRoute: TutorAudioSession.currentRouteKey()) != nil }

    /// Bluetooth output adds 150–250 ms and drifts; the UI should warn.
    var routeNeedsWarning: Bool { TutorAudioSession.isBluetoothOutput }

    // MARK: Audio calibration

    /// Plays `clicks` clicks and matches input onsets. Saves the result when reliable.
    func runAudioCalibration(profile: InstrumentProfile, clicks: Int = 8,
                             interval: TimeInterval = 0.75) async -> LatencyEstimate? {
        guard phase != .running else { return nil }
        phase = .running
        guard await startInput(muteOutput: false) else { return nil }
        beginOnsetCapture(profile: profile)
        let outputLatency = AVAudioSession.sharedInstance().outputLatency
        // Wait for the first input buffer so clicks map onto the take clock.
        var cues: [TimeInterval]?
        let myGeneration = generation
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard phase == .running, generation == myGeneration else { return nil }
            if let c = session.scheduleClicks(count: clicks, interval: interval) { cues = c; break }
        }
        guard let cues else {
            endOnsetCapture()
            stopInput()
            phase = .failed("Clicks could not play on this audio route. Try the visual calibration.")
            return nil
        }
        let duration = 0.6 + Double(clicks) * interval + 0.6
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        guard phase == .running, generation == myGeneration else { return nil }   // cancelled
        let onsets = endOnsetCapture()
        stopInput()
        // Clicks leave the speaker `outputLatency` after their scheduled time;
        // graded cues are visual, so only input → detection delay remains.
        return finish(cues: cues.map { $0 + outputLatency }, onsets: onsets)
    }

    // MARK: Visual calibration

    /// Starts listening (output muted) for visual-pulse calibration. The UI then
    /// calls `registerVisualCue(hostTime:)` each time a pulse is shown and
    /// `finishVisualCalibration()` at the end.
    func beginVisualCalibration(profile: InstrumentProfile) async -> Bool {
        guard phase != .running else { return false }
        phase = .running
        visualCues = []
        cueIndex = -1
        guard await startInput(muteOutput: true) else { return false }
        beginOnsetCapture(profile: profile)
        return true
    }

    /// Records a pulse shown at `hostTime` (default: now).
    func registerVisualCue(hostTime: UInt64 = mach_absolute_time()) {
        guard let t = session.takeTime(forHostTime: hostTime) else { return }
        visualCues.append(t)
        cueIndex = visualCues.count - 1
    }

    func finishVisualCalibration() async -> LatencyEstimate? {
        let myGeneration = generation
        // Let the last strum's onset arrive.
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard phase == .running, generation == myGeneration else { return nil }   // cancelled
        let onsets = endOnsetCapture()
        stopInput()
        cueIndex = -1
        return finish(cues: visualCues, onsets: onsets)
    }

    func cancel() {
        generation += 1
        _ = endOnsetCapture()
        stopInput()
        phase = .idle
        cueIndex = -1
    }

    /// Stores a manually chosen latency for the current route.
    func setManualLatency(_ seconds: TimeInterval) {
        runRouteKey = nil
        store.setLatency(seconds, forRoute: TutorAudioSession.currentRouteKey())
    }

    // MARK: Internals

    /// Bumped by `cancel()`; a start or wait that sees a new value stops.
    private var generation = 0
    private var stoppingSelf = false
    private var stopObserver: TutorObserverToken?

    private func stopInput() {
        stoppingSelf = true
        session.stop()
        stoppingSelf = false
    }

    /// Interruption, route or audio configuration change during a run.
    private func inputStoppedElsewhere() {
        guard phase == .running, !stoppingSelf, !session.isListening else { return }
        generation += 1
        _ = endOnsetCapture()
        runRouteKey = nil
        cueIndex = -1
        phase = .failed(TutorListeningCopy.stoppedUnexpectedly)
    }

    /// Opens the input unless `cancel()` runs while the microphone starts.
    private func startInput(muteOutput: Bool) async -> Bool {
        generation += 1
        let myGeneration = generation
        do {
            try await session.start(recordTake: false, muteOutput: muteOutput,
                                    shouldContinue: { [weak self] in self?.generation == myGeneration })
        } catch is CancellationError {
            return false
        } catch {
            if generation == myGeneration { phase = .failed(error.localizedDescription) }
            return false
        }
        guard generation == myGeneration, phase == .running else {
            stopInput()
            return false
        }
        return true
    }

    private func finish(cues: [TimeInterval], onsets: [TimeInterval]) -> LatencyEstimate? {
        let route = runRouteKey ?? TutorAudioSession.currentRouteKey()
        runRouteKey = nil
        guard let est = Self.estimate(cueTimes: cues, onsetTimes: onsets) else {
            phase = .failed("No matching notes were heard. Play one short note on each cue, then try again.")
            return nil
        }
        if est.isReliable {
            store.setLatency(est.latency, forRoute: route)
        }
        phase = .finished(est)
        return est
    }

    private func beginOnsetCapture(profile: InstrumentProfile) {
        runRouteKey = session.routeKey
        let collector = onsets
        let rate = session.sampleRate
        let factor = ListeningMath.decimationFactor(forInputRate: rate)
        let decimator = ListeningDecimator(factor: factor)
        let detector = ListeningOnsetDetector(rate: rate / Double(factor), profile: profile)
        let internalRate = rate / Double(factor)
        session.processingQueue.sync { collector.times = [] }
        var seeded = false
        consumer = session.addConsumer { chunk in
            // Chunks before the consumer was added are missed: start the
            // detector's clock at this chunk's take-clock position.
            if !seeded {
                seeded = true
                detector.seed(clock: chunk.startSample / factor)
            }
            let found = detector.process(decimator.process(chunk.samples))
            guard !found.isEmpty else { return }
            collector.times.append(contentsOf: found.map { Double($0.index) / internalRate })
        }
    }

    /// Stops capture after every queued chunk was processed; returns the onsets.
    @discardableResult
    private func endOnsetCapture() -> [TimeInterval] {
        var times: [TimeInterval] = []
        let collector = onsets
        if let consumer {
            session.processingQueue.sync {
                session.removeConsumer(consumer)
                times = collector.times
            }
        }
        consumer = nil
        return times
    }

    /// Matches each cue to the earliest unused onset within `window` of it
    /// (offsets may be slightly negative when a player anticipates) and
    /// returns the median offset. Nil with fewer than 3 matches.
    nonisolated static func estimate(cueTimes: [TimeInterval], onsetTimes: [TimeInterval],
                                     window: ClosedRange<TimeInterval> = -0.08...0.45) -> LatencyEstimate? {
        let sorted = onsetTimes.sorted()
        var used = Set<Int>()
        var offsets: [Double] = []
        for cue in cueTimes {
            var best: (i: Int, d: Double)?
            for (i, t) in sorted.enumerated() where !used.contains(i) {
                let d = t - cue
                guard window.contains(d) else { continue }
                if best == nil || d < best!.d { best = (i, d) }
            }
            if let best { used.insert(best.i); offsets.append(best.d) }
        }
        guard offsets.count >= 3 else { return nil }
        let med = ListeningStats.median(offsets)
        let mad = ListeningStats.median(offsets.map { abs($0 - med) })
        return LatencyEstimate(latency: max(0, med), spread: mad, matched: offsets.count, cues: cueTimes.count)
    }
}

/// Onset times written and read only on the audio processing queue.
private final class OnsetCollector: @unchecked Sendable {
    var times: [TimeInterval] = []
}
