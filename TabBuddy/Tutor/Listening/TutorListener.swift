//
//  TutorListener.swift
//  TabBuddy
//
//  The facade UIs use for live listening (TUTOR_IMPLEMENTATION.md §4).
//  Runs the tier-B ExpectedNoteVerifier and the tier-A MonophonicListener on
//  TutorAudioSession's input (processing queue) and publishes results on the
//  main actor. Times are take-clock seconds, latency-corrected.
//
//  Timing model: detections are stamped with their sample position (when
//  the sound reached the input) minus the calibrated input→detection
//  latency; `takeClock` (for visual cues and timed arming) is the host clock
//  mapped onto the take clock through the tap's timestamps. The two meet
//  when the player plays on the cue, whatever the tap's buffer size.
//

import Foundation
import Combine

extension Notification.Name {
    /// Posted (object: the `TutorListener`) when listening ended without the
    /// listener's own `stop()`: an interruption, an audio configuration
    /// change, or another tutor feature stopping the shared input.
    static let tutorListenerDidStopUnexpectedly = Notification.Name("TabBuddy.tutorListenerDidStopUnexpectedly")
}

@MainActor
final class TutorListener: ObservableObject {

    // MARK: Published state

    @Published private(set) var isListening = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var inputLevel: Float = 0
    /// Live monophonic pitch (tuner needle); nil between notes.
    @Published private(set) var livePitch: MonophonicListener.LivePitch?
    /// Latency applied to detections for the current route.
    @Published private(set) var latency: TimeInterval = LatencyCalibrator.defaultLatency
    @Published private(set) var lastVerification: VerificationResult?
    @Published private(set) var lastDetected: DetectedEvent?

    // MARK: Outputs

    var onVerification: ((VerificationResult) -> Void)?
    var onDetected: ((DetectedEvent) -> Void)?
    let verificationPublisher = PassthroughSubject<VerificationResult, Never>()
    let detectedPublisher = PassthroughSubject<DetectedEvent, Never>()

    /// Which detectors feed `onDetected`.
    struct DetectionSources: OptionSet, Sendable {
        let rawValue: Int
        static let monophonic = DetectionSources(rawValue: 1)
        static let verifier = DetectionSources(rawValue: 2)
        static let all: DetectionSources = [.monophonic, .verifier]
    }
    var detectionSources: DetectionSources = .all

    /// Take file of the current/last session.
    private(set) var takeURL: URL?
    private(set) var profile: InstrumentProfile?

    /// Current take time for cursors, count-ins, and timed arming: the host
    /// clock mapped onto the take clock. Detections are already
    /// latency-corrected, so cues and detections share this frame.
    var takeClock: TimeInterval { max(0, clockSource()) }

    /// True while `start` is in progress.
    private(set) var isStarting = false
    /// Set when listening ended without `stop()` (interruption, route or
    /// configuration change); cleared on the next start.
    @Published private(set) var stoppedUnexpectedly = false

    let session: TutorAudioSession
    private let latencyStore: LatencyStore
    private let clockSource: @MainActor () -> TimeInterval
    private var consumer: UUID?
    private var verifier: ExpectedNoteVerifier?
    private var mono: MonophonicListener?
    private var bag: Set<AnyCancellable> = []
    /// Bumped by every start and stop; a start whose generation changed while
    /// it awaited the microphone was cancelled.
    private var generation = 0
    private var stoppingSelf = false
    private let teardown = ListenerTeardown()
    private var stopObserver: TutorObserverToken?
    private var outbox: ListenerOutbox?

    /// - Parameters:
    ///   - latencyStore: default is the shared calibration store (`TutorLatency.store()`),
    ///     so lessons, practice mode, and games use the same calibration.
    ///   - clock: take-clock source for cues (tests inject a fake clock).
    init(session: TutorAudioSession? = nil, latencyStore: LatencyStore? = nil,
         clock: (@MainActor () -> TimeInterval)? = nil) {
        let session = session ?? .shared
        self.session = session
        self.latencyStore = latencyStore ?? TutorLatency.store()
        self.clockSource = clock ?? { session.currentTakeTime }
        teardown.session = session
        session.$inputLevel.assign(to: &$inputLevel)
        session.$permissionDenied.assign(to: &$permissionDenied)
        stopObserver = TutorObserverToken(NotificationCenter.default.addObserver(
            forName: .tutorListeningDidStop, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionStoppedElsewhere() }
            })
    }

    deinit {
        teardown.run()
    }

    // MARK: Lifecycle

    /// Starts listening with output muted. Returns without listening (and
    /// without throwing) when `stop()` was called while the microphone was
    /// starting; callers check `isListening` or their own phase afterwards.
    func start(profile: InstrumentProfile, recordTake: Bool = true) async throws {
        guard !isListening, !isStarting else { return }
        generation += 1
        let myGeneration = generation
        isStarting = true
        stoppedUnexpectedly = false
        defer { if generation == myGeneration { isStarting = false } }
        self.profile = profile
        latency = currentLatency()
        do {
            try await session.start(recordTake: recordTake, muteOutput: true,
                                    shouldContinue: { [weak self] in self?.generation == myGeneration })
        } catch is CancellationError {
            return
        }
        guard generation == myGeneration else {
            // Stopped (or deallocated) right as the input opened.
            session.stop()
            return
        }
        takeURL = session.takeURL
        // The route is known exactly once the session is active.
        latency = currentLatency()

        let rate = session.sampleRate
        let verifier = ExpectedNoteVerifier(sampleRate: rate, profile: profile)
        verifier.latencyCompensation = latency
        let mono = MonophonicListener(sampleRate: rate, profile: profile)
        mono.latencyCompensation = latency
        self.verifier = verifier
        self.mono = mono

        // Results go through an outbox so `stop()` can deliver everything
        // already produced, in order, before it returns.
        let outbox = ListenerOutbox()
        self.outbox = outbox
        verifier.onDetection = { event in outbox.append(.detected(event)) }
        let id = session.addConsumer { [weak self] chunk in
            let results = verifier.process(samples: chunk.samples, startSample: chunk.startSample)
            let notes = mono.process(samples: chunk.samples, startSample: chunk.startSample)
            let live = mono.livePitch
            outbox.append(contentsOf: results.map { .verification($0) } + notes.map { .detected($0) })
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                self.livePitch = live
                self.drain(outbox)
            }
        }
        consumer = id
        teardown.consumer = id
        teardown.ownsSession = true
        isListening = true
    }

    /// Stops listening (or cancels a pending start), flushes pending
    /// verification results, and returns the take URL.
    @discardableResult
    func stop() -> URL? {
        if isStarting {
            // The pending start sees the new generation and does not open the input.
            generation += 1
            isStarting = false
            return takeURL
        }
        guard isListening else { return takeURL }
        generation += 1
        let tail = detachFromInput()
        stoppingSelf = true
        takeURL = session.stop()
        stoppingSelf = false
        finishStop(tail: tail)
        return takeURL
    }

    /// Removes the consumer after every queued chunk was processed and
    /// returns the verifier's remaining results (open timed windows, pending onsets).
    private func detachFromInput() -> [VerificationResult] {
        var tail: [VerificationResult] = []
        if let consumer {
            let verifier = self.verifier
            // Chunks already queued still reach the consumer; then close the windows.
            session.processingQueue.sync {
                session.removeConsumer(consumer)
                tail = verifier?.finish() ?? []
            }
        }
        consumer = nil
        teardown.consumer = nil
        teardown.ownsSession = false
        return tail
    }

    private func finishStop(tail: [VerificationResult]) {
        // Deliver what the processing queue produced before the tail, while
        // callers still treat the take as active.
        if let outbox { drain(outbox) }
        for r in tail { publishVerification(r) }
        outbox = nil
        isListening = false
        livePitch = nil
        verifier = nil
        mono = nil
    }

    private func drain(_ box: ListenerOutbox) {
        for item in box.take() {
            switch item {
            case .verification(let r): publishVerification(r)
            case .detected(let e): publishDetected(e)
            }
        }
    }

    /// The shared input stopped without our `stop()`.
    private func sessionStoppedElsewhere() {
        guard isListening, !stoppingSelf, !session.isListening else { return }
        generation += 1
        let tail = detachFromInput()
        takeURL = session.takeURL
        finishStop(tail: tail)
        stoppedUnexpectedly = true
        NotificationCenter.default.post(name: .tutorListenerDidStopUnexpectedly, object: self)
    }

    private func currentLatency() -> TimeInterval {
        let key = TutorAudioSession.currentRouteKey()
        guard TutorAudioSession.isUsableRouteKey(key) else { return LatencyCalibrator.defaultLatency }
        return latencyStore.latency(forRoute: key) ?? LatencyCalibrator.defaultLatency
    }

    // MARK: Arming

    /// Arms expected events (replacing earlier ones). Timed-mode times are
    /// take-clock seconds, latency-corrected (compare with `takeClock`).
    func arm(_ events: [ExpectedEvent], window: ExpectedNoteVerifier.Window) {
        guard let verifier else { return }
        session.processingQueue.async { verifier.arm(events, window: window) }
    }

    /// Wait mode for a single event.
    func armWait(_ event: ExpectedEvent) { arm([event], window: .wait) }

    /// Timed mode from beats: `passageStart` is the take time of beat 0.
    func armTimed(_ passage: ExpectedPassage, passageStart: TimeInterval, tempoScale: Double = 1,
                  tolerance: TimeInterval = 0.15) {
        let times = passage.events.map { passageStart + passage.time(ofBeat: $0.beat, tempoScale: tempoScale) }
        arm(passage.events, window: .timed(times: times, tolerance: tolerance))
    }

    func disarm() {
        guard let verifier else { return }
        session.processingQueue.async { verifier.disarm() }
    }

    /// Re-reads the calibrated latency for the current route (after calibration).
    func reloadLatency() {
        latency = currentLatency()
        let value = latency
        if let verifier, let mono {
            session.processingQueue.async {
                verifier.latencyCompensation = value
                mono.latencyCompensation = value
            }
        }
    }

    // MARK: Tier C

    /// Post-take polyphonic transcription of the last take.
    func transcribeTake(using transcriber: PolyphonicTranscriber = IterativeHarmonicTranscriber()) async throws
        -> [DetectedEvent] {
        guard let url = takeURL, let profile else { return [] }
        let offset = latency
        return try await transcriber.transcribe(url: url, profile: profile).map {
            var e = $0
            e.time -= offset
            return e
        }
    }

    // MARK: Publishing

    private func publishVerification(_ r: VerificationResult) {
        lastVerification = r
        onVerification?(r)
        verificationPublisher.send(r)
    }

    private func publishDetected(_ e: DetectedEvent) {
        switch e.source {
        case .monophonic where !detectionSources.contains(.monophonic): return
        case .verifier where !detectionSources.contains(.verifier): return
        default: break
        }
        lastDetected = e
        onDetected?(e)
        detectedPublisher.send(e)
    }
}

/// What `deinit` needs to release the input when a listener is dropped
/// while listening (a view model torn down mid-take).
private final class ListenerTeardown: @unchecked Sendable {
    // Written on the main actor only; read once in deinit.
    weak var session: TutorAudioSession?
    var consumer: UUID?
    var ownsSession = false

    func run() {
        guard let session else { return }
        if let consumer { session.removeConsumer(consumer) }
        guard ownsSession else { return }
        Task { @MainActor in session.stop() }
    }
}

/// Results produced on the processing queue, drained on the main actor.
private final class ListenerOutbox: @unchecked Sendable {
    enum Item {
        case verification(VerificationResult)
        case detected(DetectedEvent)
    }
    private let lock = NSLock()
    private var items: [Item] = []

    func append(_ item: Item) {
        lock.lock(); items.append(item); lock.unlock()
    }

    func append(contentsOf more: [Item]) {
        guard !more.isEmpty else { return }
        lock.lock(); items.append(contentsOf: more); lock.unlock()
    }

    func take() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        let out = items
        items = []
        return out
    }
}
