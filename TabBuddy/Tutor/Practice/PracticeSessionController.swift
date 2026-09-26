//
//  PracticeSessionController.swift
//  TabBuddy
//
//  Library practice mode (TUTOR_IMPLEMENTATION.md §8, TUTOR_PLAN.md §3):
//  builds the expected passage for the practice range, runs a take in Wait
//  or Play-along mode with app audio muted (cues are visual), then analyzes
//  the take in the background (live tier-B results + tier-C transcription),
//  saves a `PracticeTakeRecord`, and presents the review.
//
//  `PracticeListening` is the seam that keeps the state machine testable
//  without audio; `TutorListener` conforms.
//

import AVFoundation
import Combine
import Foundation

/// The part of `TutorListener` practice mode uses.
@MainActor
protocol PracticeListening: AnyObject {
    var isListening: Bool { get }
    var latency: TimeInterval { get }
    /// Current take time for visual cues and timed arming (host clock mapped
    /// onto the take clock; detections are latency-corrected into this frame).
    var takeClock: TimeInterval { get }
    var inputLevel: Float { get }
    var onVerification: ((VerificationResult) -> Void)? { get set }
    func start(profile: InstrumentProfile, recordTake: Bool) async throws
    @discardableResult func stop() -> URL?
    func armWait(_ event: ExpectedEvent)
    func armTimed(_ passage: ExpectedPassage, passageStart: TimeInterval, tempoScale: Double,
                  tolerance: TimeInterval)
    func disarm()
    func transcribeTake(using transcriber: PolyphonicTranscriber) async throws -> [DetectedEvent]
}

extension TutorListener: PracticeListening {}

/// Everything the review needs for one take.
struct PracticeReviewPayload: Identifiable {
    var id: UUID
    var archive: PracticeTakeArchive
    var audioURL: URL?
    var date: Date
    var measures: ClosedRange<Int>
    var bpm: Double
}

@MainActor
final class PracticeSessionController: ObservableObject {

    enum Phase: Equatable {
        /// Loading notes (Guitar Pro export, MIDI copy).
        case preparing
        /// The source yields no passage at all.
        case unavailable(String)
        case ready
        /// Asking for the microphone and starting input.
        case starting
        /// Visual count-in (play-along); `remaining` beats before beat 0.
        case countIn(remaining: Int)
        case listening
        case analyzing
    }

    // MARK: Published state

    @Published private(set) var phase: Phase = .preparing
    @Published var mode: PracticeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published private(set) var range: ClosedRange<Int>?
    @Published private(set) var tempoPercent: Double
    @Published private(set) var instrument: TutorInstrument
    @Published private(set) var passage: ExpectedPassage?
    @Published private(set) var totalMeasures: Int

    /// Wait mode: the target event index; play-along: the event under the cursor.
    @Published private(set) var currentIndex = 0
    /// Event ids confidently heard during the take.
    @Published private(set) var satisfied: Set<Int> = []
    /// Chords with some tones heard.
    @Published private(set) var partiallyHeard: Set<Int> = []
    /// Frame-rate values (cursor, pulse, level), observed only by the views that draw them.
    let cursor = PracticeCursor()

    @Published private(set) var permissionDenied = false
    @Published private(set) var needsCalibration = false
    @Published var calibrationPromptDismissed = false
    /// One-line status (interruption, route change, save error).
    @Published var notice: String?

    @Published var review: PracticeReviewPayload?
    @Published private(set) var takes: [PracticeTakeSummary] = []
    /// A take saved when practice closed mid-take, not reviewed yet
    /// ("Your last take was saved — Review"). Set by `prepare()`.
    @Published private(set) var unreviewedTakeID: UUID?

    // MARK: Configuration

    let context: PracticeScoreContext
    let factory: PracticePassageFactory
    private let listener: PracticeListening
    private let store: TutorStore
    private let latencyStore: LatencyStore
    private let transcriber: PolyphonicTranscriber
    private let analyze: @Sendable (ExpectedPassage, [VerificationResult], [DetectedEvent], Double,
                                    TempoAnalyzer.Reference) -> TakeAnalysis
    private let clockDriven: Bool
    private let notificationCenter: NotificationCenter

    static let modeKey = "practice.mode"
    /// Takes shorter than this are discarded when practice closes mid-take.
    static let minimumKeptTakeSeconds: TimeInterval = 3
    private var unreviewedKey: String { "practice.unreviewedTake." + context.scoreKey }

    // MARK: Take state

    private var liveResults: [VerificationResult] = []
    private var passageStart: TimeInterval = 0
    private var countInBeats = 0
    private var lastPulseBeat = Int.min
    private var takePassage: ExpectedPassage?
    private var takeTempoPercent: Double = 100
    private var takeMode: PracticeMode = .wait
    private var timer: Timer?
    private var stoppingByUs = false
    /// Bumped when a take stops; a start that completes afterwards is dropped.
    private var takeGeneration = 0
    /// Take-clock time when listening began (length of a take closed early).
    private var takeStartClock: TimeInterval = 0
    /// Set by `close()`: the take is saved without presenting the review.
    private var closing = false
    private var didPrepare = false
    private var observers: [NSObjectProtocol] = []

    init(context: PracticeScoreContext,
         listener: PracticeListening? = nil,
         store: TutorStore? = nil,
         latencyStore: LatencyStore? = nil,
         transcriber: PolyphonicTranscriber = IterativeHarmonicTranscriber(),
         analyze: (@Sendable (ExpectedPassage, [VerificationResult], [DetectedEvent], Double,
                              TempoAnalyzer.Reference) -> TakeAnalysis)? = nil,
         clockDriven: Bool = true,
         notificationCenter: NotificationCenter = .default) {
        let store = store ?? .shared
        let latencyStore = latencyStore ?? TutorLatency.store(store)
        self.context = context
        self.factory = PracticePassageFactory(source: context.source)
        self.listener = listener ?? TutorListener(latencyStore: latencyStore)
        self.store = store
        self.latencyStore = latencyStore
        self.transcriber = transcriber
        self.analyze = analyze ?? { passage, live, detected, scale, reference in
            TakeAnalyzer().analyze(passage: passage, live: live, detected: detected,
                                   tempoScale: scale, timingReference: reference)
        }
        self.clockDriven = clockDriven
        self.notificationCenter = notificationCenter
        self.mode = PracticeMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .wait
        self.tempoPercent = PracticeTempo.clamp(context.tempoPercent)
        self.instrument = context.instrument
        self.totalMeasures = context.totalMeasures
        self.listener.onVerification = { [weak self] result in self?.handle(result) }
        observeInterruptions()
    }

    deinit {
        timer?.invalidate()
        for o in observers { notificationCenter.removeObserver(o) }
    }

    // MARK: Derived

    var tempoScale: Double { tempoPercent / 100 }
    var isTakeActive: Bool {
        switch phase {
        case .starting, .countIn, .listening: return true
        default: return false
        }
    }
    var canStart: Bool { phase == .ready && passage?.events.isEmpty == false }
    /// Practice BPM in the passage's beat unit.
    var practiceBPM: Double { (passage?.bpm ?? context.referenceBPM ?? 0) * tempoScale }
    var events: [ExpectedEvent] { passage?.events ?? [] }
    var currentEvent: ExpectedEvent? { events.indices.contains(currentIndex) ? events[currentIndex] : nil }

    /// Why Start is disabled while ready (empty range).
    var rangeMessage: String? {
        guard phase == .ready, passage == nil, let range else { return nil }
        return "\(PracticeDefaults.label(range)) have no notes with known pitches. Choose other measures."
    }

    // MARK: Setup

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true
        phase = .preparing
        guard await factory.load() else {
            phase = .unavailable(unavailableReason)
            return
        }
        if totalMeasures <= 0 { totalMeasures = factory.measureCount }
        let initial = context.initialRange.flatMap { PracticeDefaults.clamp($0, count: totalMeasures) }
        range = initial ?? PracticeDefaults.span(from: 0, count: totalMeasures)
        rebuildPassage()
        if passage == nil, factory.passage(range: nil, bpm: context.referenceBPM, instrument: instrument) == nil {
            phase = .unavailable(unavailableReason)
            return
        }
        refreshCalibrationState()
        reloadTakes()
        if let raw = UserDefaults.standard.string(forKey: unreviewedKey), let id = UUID(uuidString: raw),
           takes.contains(where: { $0.id == id }) {
            unreviewedTakeID = id
            notice = "Your last take was saved. Review it from your takes."
        } else {
            UserDefaults.standard.removeObject(forKey: unreviewedKey)
        }
        phase = .ready
    }

    /// Opens the take saved when practice last closed mid-take.
    func reviewUnreviewedTake() {
        guard let id = unreviewedTakeID else { return }
        review = payload(forTake: id)
        dismissUnreviewedTake()
    }

    func dismissUnreviewedTake() {
        unreviewedTakeID = nil
        UserDefaults.standard.removeObject(forKey: unreviewedKey)
        if notice?.hasPrefix("Your last take was saved") == true { notice = nil }
    }

    private var unavailableReason: String {
        switch context.source {
        case .alphaTab:
            return "The selected track has no pitched notes to listen for. Choose another track in Settings."
        case .midi:
            return "The matching MIDI file could not be read."
        case .measureMap:
            return "This tab has no notes with known pitches. Its tuning may not say which octave each string is in."
        case .passage:
            return "There are no notes to practice."
        }
    }

    func setRange(_ newRange: ClosedRange<Int>) {
        guard !isTakeActive, let clamped = PracticeDefaults.clamp(newRange, count: totalMeasures) else { return }
        range = clamped
        rebuildPassage()
    }

    func setTempoPercent(_ percent: Double, pushToViewer: Bool = true) {
        guard !isTakeActive else { return }
        tempoPercent = PracticeTempo.clamp(percent)
        if pushToViewer { context.applyToViewer(nil, tempoPercent) }
    }

    func setInstrument(_ value: TutorInstrument) {
        guard !isTakeActive, value != instrument else { return }
        instrument = value
        rebuildPassage()
    }

    private func rebuildPassage() {
        passage = range.flatMap { factory.passage(range: $0, bpm: context.referenceBPM, instrument: instrument) }
        resetLiveState()
    }

    private func resetLiveState() {
        satisfied = []
        partiallyHeard = []
        liveResults = []
        currentIndex = firstGradedIndex(from: 0)
        cursor.beat = nil
    }

    /// The route key predicts the listening route even before the session is
    /// configured, so a calibrated route is not reported as uncalibrated.
    func refreshCalibrationState() {
        let key = TutorAudioSession.currentRouteKey()
        needsCalibration = !TutorAudioSession.isUsableRouteKey(key) || latencyStore.latency(forRoute: key) == nil
    }

    // MARK: Take lifecycle

    /// Space bar / Start button.
    func toggleTake() {
        if isTakeActive { stopTake() } else if canStart { Task { await startTake() } }
    }

    func startTake() async {
        guard canStart, let passage else { return }
        resetLiveState()
        notice = nil
        takePassage = passage
        takeTempoPercent = tempoPercent
        takeMode = mode
        phase = .starting
        takeGeneration += 1
        let generation = takeGeneration
        let profile = context.listeningProfile(for: instrument, passage: passage)
        do {
            try await listener.start(profile: profile, recordTake: true)
        } catch TutorAudioError.permissionDenied {
            guard generation == takeGeneration else { return }
            permissionDenied = true
            phase = .ready
            return
        } catch {
            guard generation == takeGeneration else { return }
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .ready
            return
        }
        guard phase == .starting, generation == takeGeneration, listener.isListening else {
            // Stopped while starting (stopTake already cancelled the start).
            if generation == takeGeneration {
                if listener.isListening, let url = listener.stop() { try? FileManager.default.removeItem(at: url) }
                if phase == .starting { phase = .ready }
            }
            return
        }
        takeStartClock = listener.takeClock
        permissionDenied = false
        refreshCalibrationState()

        switch takeMode {
        case .wait:
            phase = .listening
            armCurrentWaitTarget()
        case .playAlong:
            let spb = secondsPerBeat(passage)
            // Visual count-in: one bar, two when a bar is shorter than two seconds.
            let bar = max(1, passage.beatsPerMeasure)
            countInBeats = Double(bar) * spb < 2 ? bar * 2 : bar
            passageStart = listener.takeClock + Double(countInBeats) * spb
            lastPulseBeat = Int.min
            listener.armTimed(passage, passageStart: passageStart, tempoScale: tempoScale,
                              tolerance: min(0.25, max(0.1, 0.3 * spb)))
            phase = .countIn(remaining: countInBeats)
            cursor.beat = -Double(countInBeats)
        }
        startClock()
    }

    /// Stops the take. Takes stopped during the count-in are discarded.
    func stopTake(reason: String? = nil) {
        guard isTakeActive else { return }
        stopClock()
        takeGeneration += 1
        if phase == .starting {
            listener.stop()                         // cancels the pending start
            phase = .ready
            return
        }
        var wasCountIn = false
        if case .countIn = phase { wasCountIn = true }
        let length = listener.takeClock - takeStartClock
        stoppingByUs = true
        let url = listener.stop()          // flushes pending results through onVerification
        stoppingByUs = false
        if let reason { notice = reason }
        cursor.beat = nil
        let tooShortToKeep = closing && length < Self.minimumKeptTakeSeconds
        if wasCountIn || takePassage == nil || tooShortToKeep {
            if let url { try? FileManager.default.removeItem(at: url) }
            phase = .ready
            return
        }
        phase = .analyzing
        Task { await analyzeTake(audioURL: url) }
    }

    /// Wait mode: move past the current target without hearing it (→ key).
    func skipCurrent() {
        guard phase == .listening, takeMode == .wait else { return }
        advanceWait()
    }

    private func armCurrentWaitTarget() {
        guard let event = currentEvent else { stopTake(); return }
        listener.armWait(event)
    }

    private func advanceWait() {
        currentIndex = firstGradedIndex(from: currentIndex + 1)
        if currentIndex >= events.count {
            stopTake()
        } else {
            armCurrentWaitTarget()
        }
    }

    private func firstGradedIndex(from index: Int) -> Int {
        var i = index
        while i < events.count, events[i].pitches.isEmpty { i += 1 }
        return i
    }

    // MARK: Live results

    func handle(_ result: VerificationResult) {
        guard isTakeActive || stoppingByUs else { return }
        liveResults.append(result)
        switch result.grade {
        case .hit:
            satisfied.insert(result.expectedID)
            partiallyHeard.remove(result.expectedID)
        case .partial:
            if !satisfied.contains(result.expectedID) { partiallyHeard.insert(result.expectedID) }
        case .wrongPitch, .missed, .uncertain:
            break   // live feedback stays neutral; the review explains
        }
        if takeMode == .wait, phase == .listening, result.grade == .hit,
           result.expectedID == currentEvent?.id {
            advanceWait()
        }
    }

    // MARK: Clock (visual cues)

    private func startClock() {
        guard clockDriven else { return }
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    /// Advances the count-in, pulse, and play-along cursor from the take clock.
    func tick() {
        if cursor.inputLevel != listener.inputLevel { cursor.inputLevel = listener.inputLevel }
        guard takeMode == .playAlong, let passage = takePassage else { return }
        switch phase {
        case .countIn, .listening: break
        default: return
        }
        let spb = secondsPerBeat(passage)
        let beat = (listener.takeClock - passageStart) / spb
        cursor.beat = beat
        let whole = Int(floor(beat + 1e-6))
        if whole != lastPulseBeat {
            lastPulseBeat = whole
            let bar = max(1, passage.beatsPerMeasure)
            cursor.pulseBeatInMeasure = ((whole % bar) + bar) % bar
            cursor.pulseCount += 1
        }
        if beat < 0 {
            let remaining = PracticeSessionController.Phase.countIn(remaining: max(1, Int(ceil(-beat - 1e-6))))
            if phase != remaining { phase = remaining }
            return
        }
        if phase != .listening { phase = .listening }
        var index = currentIndex
        while index + 1 < passage.events.count, passage.events[index + 1].beat <= beat + 1e-6 { index += 1 }
        if index != currentIndex { currentIndex = index }
        let end = passage.events.map { $0.beat + $0.durationBeats }.max() ?? 0
        // Past the last note plus one beat (and the timed window): the take is done.
        if beat > end + 1 { stopTake() }
    }

    private func secondsPerBeat(_ passage: ExpectedPassage) -> Double {
        passage.time(ofBeat: 1, tempoScale: tempoScale)
    }

    // MARK: Analysis and storage

    private func analyzeTake(audioURL: URL?) async {
        guard let passage = takePassage else { phase = .ready; return }
        let detected: [DetectedEvent]
        if audioURL != nil {
            detected = (try? await listener.transcribeTake(using: transcriber)) ?? []
        } else {
            detected = []
        }
        let live = liveResults
        let scale = takeTempoPercent / 100
        let reference: TempoAnalyzer.Reference = takeMode == .playAlong ? .target : .ownMedian
        let analyze = self.analyze
        let analysis = await Task.detached(priority: .userInitiated) {
            analyze(passage, live, detected, scale, reference)
        }.value

        let archive = PracticeTakeArchive(analysis: analysis, passage: passage, mode: takeMode,
                                          tempoPercent: takeTempoPercent, latency: listener.latency,
                                          passageStart: takeMode == .playAlong ? passageStart : nil)
        let measures = passage.measureRange ?? (range ?? 0...0)
        var saved = false
        var payload = PracticeReviewPayload(id: UUID(), archive: archive, audioURL: audioURL, date: Date(),
                                            measures: measures, bpm: passage.bpm * scale)
        do {
            let record = try store.saveTake(scoreKey: context.scoreKey, scoreTitle: context.title,
                                            measures: measures, bpm: passage.bpm * scale,
                                            analysis: analysis, audioURL: audioURL)
            record.analysisJSON = try JSONEncoder().encode(archive)
            try store.save()
            payload.id = record.id
            payload.date = record.date
            saved = true
            payload.audioURL = store.audioURL(for: record)
        } catch {
            notice = "The take couldn't be saved (\(error.localizedDescription)). The review below is still available."
        }
        reloadTakes()
        phase = .ready
        if closing {
            // Practice closed mid-take: keep the take for the next visit.
            if saved { UserDefaults.standard.set(payload.id.uuidString, forKey: unreviewedKey) }
            return
        }
        review = payload
    }

    func reloadTakes() {
        takes = store.takes(forScore: context.scoreKey).map { PracticeTakeSummary(record: $0, store: store) }
    }

    /// Review payload for a stored take (history list).
    func payload(forTake id: UUID) -> PracticeReviewPayload? {
        guard let record = store.takes(forScore: context.scoreKey).first(where: { $0.id == id }) else { return nil }
        let archive = PracticeTakeArchive.decode(record.analysisJSON)
            ?? record.analysis.map { PracticeTakeArchive(analysis: $0, passage: nil, mode: nil, tempoPercent: nil,
                                                         latency: nil, passageStart: nil) }
        guard var archive else { return nil }
        if archive.passage == nil {
            // Older takes: rebuild the passage from the score when it is still available.
            let lo = min(record.firstMeasure, record.lastMeasure), hi = max(record.firstMeasure, record.lastMeasure)
            archive.passage = factory.passage(range: lo...hi, bpm: context.referenceBPM, instrument: instrument)
        }
        return PracticeReviewPayload(id: record.id, archive: archive, audioURL: store.audioURL(for: record),
                                     date: record.date,
                                     measures: min(record.firstMeasure, record.lastMeasure)...max(record.firstMeasure, record.lastMeasure),
                                     bpm: record.bpm)
    }

    func deleteTake(_ id: UUID) {
        guard let record = store.takes(forScore: context.scoreKey).first(where: { $0.id == id }) else { return }
        do { try store.deleteTake(record) } catch { notice = "The take couldn't be deleted (\(error.localizedDescription))." }
        if review?.id == id { review = nil }
        reloadTakes()
    }

    /// Suggestion button: sets the practice range/tempo and the viewer's loop/speed.
    func apply(_ action: PracticeSuggestionAction) {
        if let loop = action.loop { setRange(loop) }
        if let percent = action.tempoPercent { setTempoPercent(percent, pushToViewer: false) }
        context.applyToViewer(action.loop, action.tempoPercent.map { PracticeTempo.clamp($0) })
    }

    /// Closing practice mode: stop listening without saving a partial
    /// count-in. A take of at least `minimumKeptTakeSeconds` is analyzed and
    /// saved; the next `prepare()` for this score offers its review.
    func close() {
        closing = true
        if isTakeActive { stopTake() }
        stopClock()
        factory.cleanUp()
    }

    // MARK: Interruptions

    private func observeInterruptions() {
        observers.append(notificationCenter.addObserver(forName: .tutorListeningDidStop, object: nil,
                                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.listeningStoppedElsewhere() }
        })
        observers.append(notificationCenter.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                        object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { self?.routeChanged(reason) }
        })
    }

    /// The audio session stopped under us (phone call, Siri, another app).
    func listeningStoppedElsewhere() {
        guard isTakeActive, !stoppingByUs else { return }
        stopTake(reason: "Listening stopped because another app or a call took the microphone. The take so far is below.")
    }

    func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard isTakeActive, reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
        stopTake(reason: "The audio route changed, so the take stopped. Delay is calibrated per route; check calibration before the next take.")
        refreshCalibrationState()
    }
}


/// Values that change every frame during a take.
@MainActor
final class PracticeCursor: ObservableObject {
    /// Play-along cursor in passage beats (negative during the count-in).
    @Published var beat: Double?
    /// Increments once per beat (drives the visual pulse).
    @Published var pulseCount = 0
    @Published var pulseBeatInMeasure = 0
    @Published var inputLevel: Float = 0
}
