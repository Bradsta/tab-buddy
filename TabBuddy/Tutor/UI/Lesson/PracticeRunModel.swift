//
//  PracticeRunModel.swift
//  TabBuddy
//
//  State machine for one graded exercise (practice steps and song steps).
//  Audio goes through `TutorListening` / `TutorSequencePlaying`, so tests
//  drive it with fakes and a hand-set take clock (`tick()`).
//
//  Per pacing:
//  - wait: events armed in order; each confident hit advances the cursor. An
//    event counts as clean when it is hit with at most one miss before it.
//  - timed: visual count-in, `armTimed`, run ends after the last event; graded
//    with `TakeAnalyzer` (live verifier results + detections).
//  - anyOrder (findAllNotes): monophonic detections tick off target pitches
//    within `durationSec`.
//  - countChanges (chordChanges): clean chord hits within `durationSec`.
//  - free (improvise): share of detected notes in the scale plus rhythm steadiness.
//  Rounds with a reference (intervalPlayback, melodyEcho) play it with
//  listening stopped, then listen for the answer.
//

import Foundation
import SwiftUI

@MainActor
final class PracticeRunModel: ObservableObject {

    enum Phase: Equatable {
        case ready
        case starting
        case playingReference
        case countIn(beat: Int, of: Int)
        case listening
        case finished
        case permissionDenied
        case unavailable(String)

        var isActive: Bool {
            switch self {
            case .starting, .playingReference, .countIn, .listening: return true
            default: return false
            }
        }
    }

    enum Mark: Equatable {
        case pending, hit, retry, notSure, partial, skipped, missed
    }

    struct Feedback: Equatable {
        var text: String
        var tone: TutorTone
        var systemImage: String
    }

    struct RunResult: Equatable {
        var accuracy: Double
        var passed: Bool
        /// The detector could not hear enough to grade; shown neutrally.
        var unsure: Bool
        var summary: String
        var detail: String?
        var timingMADms: Double?
    }

    // MARK: Configuration

    let instrument: TutorInstrument
    let exercise: GeneratedExercise?
    let generationError: String?
    let prompt: String
    let fixedDiagram: Diagram?
    let listener: TutorListening
    let player: TutorSequencePlaying
    /// Runs a 30 Hz timer while listening. Tests turn it off and call `tick()`.
    var autoTick = true
    var onRunFinished: ((RunResult) -> Void)?

    // MARK: Published state

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var roundIndex = 0
    /// Current event index within the round (wait/timed/countChanges).
    @Published private(set) var cursor = 0
    /// Marks by event id within the current round.
    @Published private(set) var marks: [Int: Mark] = [:]
    @Published private(set) var feedback: Feedback?
    @Published private(set) var coachMessage: CoachMessage?
    /// Timed runs: beat position of the cursor (negative during the count-in).
    @Published private(set) var currentBeat: Double = -1
    @Published private(set) var found: Set<Int> = []
    @Published private(set) var cleanChords = 0
    @Published private(set) var freeNoteCount = 0
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var lastResult: RunResult?
    @Published private(set) var bestAccuracy: Double?
    @Published private(set) var hasPassed = false
    @Published private(set) var bpm: Double
    @Published private(set) var tempoOffer: Double?
    /// Index into the reference/demo sequence while it plays.
    @Published private(set) var playbackStep: Int?
    @Published private(set) var isPlayingDemo = false

    // MARK: Private state

    private var coach: FeedbackCoach
    private var live: [VerificationResult] = []
    private var detected: [DetectedEvent] = []
    private var misses: [Int: Int] = [:]
    private var credits: [Double] = []
    private var gradedRounds: [(passage: ExpectedPassage, graded: [GradedEvent])] = []
    private var freeNotes: [(time: TimeInterval, pitch: Int)] = []
    private var runStart: TimeInterval = 0
    private var passageStart: TimeInterval = 0
    private var countInBeats = 4
    private var collecting = false
    private var ticker: Task<Void, Never>?
    /// Bumped whenever listening is cancelled; a start that finishes after
    /// that is dropped even if a new start is already pending.
    private var listenGeneration = 0
    private var stopToken: TutorObserverToken?

    // MARK: Init

    init(step: PracticeStep, instrument: TutorInstrument, intervals: [Interval]? = nil, seed: UInt64 = 1,
         stage: Int? = nil, listener: TutorListening, player: TutorSequencePlaying) {
        self.instrument = instrument
        self.listener = listener
        self.player = player
        prompt = step.exercise.prompt
        fixedDiagram = step.exercise.diagram
        let coach = FeedbackCoach(step: step)
        self.coach = coach
        do {
            let generated = try ExerciseGenerator.generate(step.exercise, context: .standard(instrument),
                                                           intervals: intervals, seed: seed, stage: stage)
            exercise = generated
            generationError = nil
            bpm = coach.currentTempo ?? generated.bpm
        } catch {
            exercise = nil
            generationError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            bpm = step.exercise.bpm ?? ExerciseGenerator.defaultBPM
        }
    }

    /// Wraps an already generated exercise (song steps).
    init(exercise: GeneratedExercise, prompt: String, instrument: TutorInstrument, tips: [String] = [],
         listener: TutorListening, player: TutorSequencePlaying) {
        self.instrument = instrument
        self.exercise = exercise
        self.prompt = prompt
        self.listener = listener
        self.player = player
        generationError = nil
        fixedDiagram = nil
        let coach = FeedbackCoach(tips: tips, tempoSteps: exercise.tempoSteps,
                                  cleanThreshold: max(0.95, exercise.passAccuracy))
        self.coach = coach
        bpm = coach.currentTempo ?? exercise.bpm
    }

    // MARK: Derived

    var pacing: ExercisePacing { exercise?.pacing ?? .wait }
    var roundCount: Int { exercise?.rounds.count ?? 0 }
    var round: ExerciseRound? {
        guard let exercise, exercise.rounds.indices.contains(roundIndex) else { return nil }
        return exercise.rounds[roundIndex]
    }
    var passage: ExpectedPassage? { round?.expected }
    /// Sounded events of the current round.
    var events: [ExpectedEvent] { passage?.events.filter { !$0.pitches.isEmpty } ?? [] }
    var currentEvent: ExpectedEvent? { events.indices.contains(cursor) ? events[cursor] : nil }
    var passAccuracy: Double { exercise?.passAccuracy ?? 0.8 }
    var tempoScale: Double {
        guard let base = passage?.bpm, base > 0 else { return 1 }
        return bpm / base
    }
    var secondsPerBeat: Double { 60 / max(1, bpm) }
    var durationSec: Double { exercise?.durationSec ?? 60 }
    var targetPitches: [Int] { exercise?.targetPitches ?? [] }
    var hasReference: Bool { round?.reference != nil }
    var isListening: Bool { listener.isListening }
    /// Beats in the round's passage.
    var totalBeats: Double { passage?.events.map { $0.beat + $0.durationBeats }.max() ?? 0 }

    /// Pulse index for the visual metronome (beat number since passage start).
    var pulseBeat: Int { Int(floor(currentBeat)) }

    // MARK: Controls

    func start() async {
        guard exercise != nil else { return }
        switch phase {
        case .ready, .finished, .unavailable, .permissionDenied: break
        default: return
        }
        stopDemo()
        resetRun()
        phase = .starting
        if hasReference {
            playReferenceThenListen()
        } else {
            await beginListening()
        }
    }

    /// Stop button. Duration-based runs are graded on what was played so far;
    /// wait and timed runs are cancelled.
    func stopRun() {
        switch phase {
        case .starting, .playingReference:
            player.stop()
            playbackStep = nil
            cancelListening()
            phase = .ready
        case .countIn, .listening:
            switch pacing {
            case .anyOrder, .countChanges, .free:
                finishDurationRun()
            case .wait, .timed:
                cancelListening()
                resetRun()
                phase = .ready
            }
        default:
            break
        }
    }

    /// Stops everything (view disappeared).
    func cancel() {
        player.stop()
        isPlayingDemo = false
        playbackStep = nil
        cancelListening()
        if phase.isActive { phase = .ready }
    }

    func retry() {
        cancel()
        resetRun()
        phase = .ready
    }

    /// Wait mode: give up on the current event (detector trouble) and move on.
    func skipCurrentEvent() {
        guard phase == .listening, pacing == .wait, let event = currentEvent else { return }
        marks[event.id] = .skipped
        misses[event.id, default: 0] += 3
        feedback = nil
        advanceCursor()
    }

    /// Plays the round's reference again (listening stops for it, then resumes).
    func replayReference() {
        guard hasReference, phase == .listening || phase == .starting else { return }
        cancelListening()
        phase = .starting
        playReferenceThenListen()
    }

    func acceptTempo() {
        coach.advanceTempo()
        if let next = coach.currentTempo { bpm = next }
        tempoOffer = nil
        coachMessage = nil
    }

    func declineTempo() {
        tempoOffer = nil
        coachMessage = nil
    }

    /// "Hear it first": the current round (or reference) played by the synth.
    func playDemo() {
        guard !phase.isActive else { return }
        if isPlayingDemo { stopDemo(); return }
        guard let sequence = round?.reference ?? demoSequence else { return }
        isPlayingDemo = true
        player.play(sequence, instrument: instrument, onStep: { [weak self] i in
            self?.playbackStep = i
        }, completion: { [weak self] in
            self?.isPlayingDemo = false
            self?.playbackStep = nil
        })
    }

    func stopDemo() {
        guard isPlayingDemo else { return }
        player.stop()
        isPlayingDemo = false
        playbackStep = nil
    }

    /// The round's events as a playable sequence at the current tempo.
    var demoSequence: PlaybackSequence? {
        guard let passage, !passage.events.isEmpty else { return nil }
        let notes = passage.events.map {
            PlaybackNote(pitches: $0.pitches, startBeat: $0.beat, durationBeats: $0.durationBeats, label: $0.chordName,
                         fretting: $0.fretting)
        }
        return PlaybackSequence(notes: notes, bpm: bpm, style: .sequence)
    }

    // MARK: Listening lifecycle

    private func playReferenceThenListen() {
        guard let reference = round?.reference else { return }
        cancelListening()
        phase = .playingReference
        feedback = Feedback(text: "Listen…", tone: .neutral, systemImage: "ear")
        player.play(reference, instrument: instrument, onStep: { [weak self] i in
            self?.playbackStep = i
        }, completion: { [weak self] in
            guard let self else { return }
            self.playbackStep = nil
            guard self.phase == .playingReference else { return }
            self.phase = .starting
            self.feedback = Feedback(text: "Your turn. Play it back.", tone: .accent, systemImage: "music.note")
            Task { await self.beginListening() }
        })
    }

    private func beginListening() async {
        guard phase == .starting else { return }
        let generation = listenGeneration
        listener.onVerification = { [weak self] r in self?.handle(r) }
        listener.onDetected = { [weak self] d in self?.handle(d) }
        listener.detectionSources = (pacing == .anyOrder || pacing == .free) ? .monophonic : .all
        do {
            try await listener.start(profile: TutorAudioHelpers.profile(for: instrument), recordTake: false)
        } catch {
            phase = listener.isPermissionError(error) ? .permissionDenied : .unavailable(error.localizedDescription)
            return
        }
        guard phase == .starting, generation == listenGeneration else {
            // Cancelled while the input was starting.
            if generation == listenGeneration { listener.stop() }
            return
        }
        guard listener.isListening else {
            phase = .ready
            return
        }
        observeUnexpectedStop()
        collecting = true
        runStart = listener.takeClock
        switch pacing {
        case .wait, .countChanges:
            armRemaining()
            phase = .listening
            if pacing == .countChanges { remaining = durationSec }
        case .timed:
            countInBeats = min(6, max(2, passage?.beatsPerMeasure ?? 4))
            passageStart = runStart + 0.4 + Double(countInBeats) * secondsPerBeat
            if let passage {
                let tolerance = min(0.3, max(0.15, 0.25 * secondsPerBeat))
                listener.armTimed(passage, passageStart: passageStart, tempoScale: tempoScale, tolerance: tolerance)
            }
            currentBeat = -Double(countInBeats)
            phase = .countIn(beat: 0, of: countInBeats)
        case .anyOrder, .free:
            remaining = durationSec
            phase = .listening
        }
        startTicker()
    }

    /// Interruption, route or audio configuration change: stop the run and
    /// show a neutral note; Start begins again.
    private func observeUnexpectedStop() {
        guard stopToken == nil else { return }
        stopToken = listener.observeUnexpectedStop { [weak self] in
            guard let self, self.phase.isActive, self.phase != .playingReference else { return }
            self.cancelListening()
            self.resetRun()
            self.phase = .ready
            self.feedback = Feedback(text: TutorListeningCopy.stoppedUnexpectedly, tone: .neutral,
                                     systemImage: "mic.slash")
        }
    }

    private func cancelListening() {
        listenGeneration += 1
        stopTicker()
        collecting = false
        if listener.isListening {
            listener.disarm()
            listener.stop()
        } else {
            listener.stop()     // cancels a start still waiting for the microphone
        }
    }

    private func armRemaining() {
        let rest = Array(events.dropFirst(cursor))
        guard !rest.isEmpty else { return }
        listener.arm(rest, window: .wait)
    }

    private func startTicker() {
        guard autoTick else { return }
        stopTicker()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Clock

    /// Advances count-in, cursor, and timers from the listener's take clock.
    func tick() {
        let now = listener.takeClock
        switch pacing {
        case .timed:
            guard phase == .listening || { if case .countIn = phase { return true }; return false }() else { return }
            let beat = (now - passageStart) / secondsPerBeat
            currentBeat = beat
            if beat < 0 {
                let counted = countInBeats - Int(ceil(-beat)) + 1
                let next = Phase.countIn(beat: max(1, min(countInBeats, counted)), of: countInBeats)
                if phase != next { phase = next }
            } else {
                if phase != .listening { phase = .listening }
                let index = events.lastIndex { $0.beat <= beat + 0.05 } ?? 0
                if index != cursor { cursor = index }
                if beat > totalBeats + 1 { finishTimedRun() }
            }
        case .anyOrder, .countChanges, .free:
            guard phase == .listening else { return }
            let left = max(0, durationSec - (now - runStart))
            remaining = left
            if left <= 0 { finishDurationRun() }
        case .wait:
            break
        }
    }

    // MARK: Input

    func handle(_ r: VerificationResult) {
        guard collecting else { return }
        switch pacing {
        case .timed:
            live.append(r)
            if r.grade == .hit { marks[r.expectedID] = .hit }
        case .wait:
            handleWait(r)
        case .countChanges:
            handleChange(r)
        case .anyOrder, .free:
            break
        }
    }

    func handle(_ d: DetectedEvent) {
        guard collecting else { return }
        switch pacing {
        case .timed:
            detected.append(d)
        case .anyOrder:
            handleFind(d)
        case .free:
            guard d.source == .monophonic, phase == .listening else { return }
            for (p, c) in zip(d.pitches, d.confidences) where c >= 0.35 {
                freeNotes.append((d.time, p))
            }
            freeNoteCount = freeNotes.count
            if let last = freeNotes.last {
                let inScale = exercise?.allowedPitchClasses.contains(PitchClass(last.pitch)) ?? true
                feedback = Feedback(text: "\(TutorAudioHelpers.name(last.pitch))\(inScale ? "" : " (outside the scale)")",
                                    tone: inScale ? .good : .neutral, systemImage: "music.note")
            }
        case .wait, .countChanges:
            break
        }
    }

    private func handleWait(_ r: VerificationResult) {
        guard phase == .listening, let event = currentEvent, r.expectedID == event.id else { return }
        let target = FeedbackCoach.targetKey(for: event)
        switch r.grade {
        case .hit:
            marks[event.id] = .hit
            _ = coach.registerAttempt(target: target, success: true)
            feedback = Feedback(text: "\(displayTarget(event)) ✓", tone: .good, systemImage: "checkmark.circle.fill")
            advanceCursor()
        case .uncertain:
            marks[event.id] = .notSure
            feedback = Feedback(text: "Not sure what I heard. Play it again and let it ring.",
                                tone: .neutral, systemImage: "questionmark.circle")
        case .partial, .wrongPitch, .missed:
            misses[event.id, default: 0] += 1
            marks[event.id] = r.grade == .partial ? .partial : .retry
            feedback = missFeedback(r, event: event)
            if let tip = coach.registerAttempt(target: target, success: false) { coachMessage = tip }
        }
    }

    private func handleChange(_ r: VerificationResult) {
        guard phase == .listening, let event = currentEvent, r.expectedID == event.id else { return }
        let target = FeedbackCoach.targetKey(for: event)
        switch r.grade {
        case .hit:
            cleanChords += 1
            marks[event.id] = .hit
            _ = coach.registerAttempt(target: target, success: true)
            feedback = Feedback(text: "\(displayTarget(event)) ✓", tone: .good, systemImage: "checkmark.circle.fill")
            cursor += 1
            if cursor >= events.count {
                // Ran through the whole list: start it again.
                cursor = 0
                marks = [:]
                armRemaining()
            }
        case .uncertain:
            feedback = Feedback(text: "Not sure. Strum \(displayTarget(event)) again.", tone: .neutral,
                                systemImage: "questionmark.circle")
        case .partial, .wrongPitch, .missed:
            feedback = missFeedback(r, event: event)
            if let tip = coach.registerAttempt(target: target, success: false) { coachMessage = tip }
        }
    }

    private func handleFind(_ d: DetectedEvent) {
        guard phase == .listening else { return }
        let targets = Set(targetPitches)
        for (p, c) in zip(d.pitches, d.confidences) where c >= 0.35 {
            if targets.contains(p) {
                if found.insert(p).inserted {
                    feedback = Feedback(text: "Found \(TutorAudioHelpers.name(p))", tone: .good, systemImage: "checkmark.circle.fill")
                } else {
                    feedback = Feedback(text: "\(TutorAudioHelpers.name(p)) is already found. Try another octave.",
                                        tone: .neutral, systemImage: "arrow.up.arrow.down")
                }
            } else {
                feedback = Feedback(text: "Heard \(TutorAudioHelpers.name(p)).", tone: .neutral, systemImage: "ear")
            }
        }
        if !targets.isEmpty, found.count >= targets.count { finishDurationRun() }
    }

    private func displayTarget(_ event: ExpectedEvent) -> String {
        event.chordName ?? event.pitches.map { TutorAudioHelpers.name($0) }.joined(separator: " ")
    }

    private func missFeedback(_ r: VerificationResult, event: ExpectedEvent) -> Feedback {
        switch r.grade {
        case .partial:
            return Feedback(text: "Part of \(displayTarget(event)) came through. Check that every string rings.",
                            tone: .caution, systemImage: "circle.lefthalf.filled")
        case .wrongPitch where !r.unexpected.isEmpty:
            let heard = r.unexpected.prefix(3).map { TutorAudioHelpers.name($0) }.joined(separator: " ")
            return Feedback(text: "Heard \(heard). Try \(displayTarget(event)).", tone: .caution, systemImage: "arrow.uturn.left")
        default:
            return Feedback(text: "Not quite. Try \(displayTarget(event)) again.", tone: .caution, systemImage: "arrow.uturn.left")
        }
    }

    // MARK: Progress

    private func advanceCursor() {
        cursor += 1
        if cursor >= events.count {
            finishWaitRound()
        } else if phase == .listening {
            // Re-arm so a skipped event leaves the verifier's queue too.
            armRemaining()
        }
    }

    private func finishWaitRound() {
        guard let passage else { return }
        var graded: [GradedEvent] = []
        for event in events {
            let miss = misses[event.id] ?? 0
            let mark = marks[event.id] ?? .pending
            let credit: Double
            let grade: GradedEvent
            if mark == .skipped || mark == .pending {
                credit = 0
                grade = GradedEvent(expectedID: event.id, grade: .missed, matchedPitches: [], missingPitches: event.pitches,
                                    wrongPitches: [], playedTime: nil, timingOffsetMs: nil, confidence: 0)
            } else if miss <= 1 {
                credit = 1
                grade = GradedEvent(expectedID: event.id, grade: .hit, matchedPitches: event.pitches, missingPitches: [],
                                    wrongPitches: [], playedTime: nil, timingOffsetMs: nil, confidence: 1)
            } else {
                // Found after several tries: half credit.
                credit = 0.5
                grade = GradedEvent(expectedID: event.id, grade: .partial, matchedPitches: event.pitches,
                                    missingPitches: event.pitches, wrongPitches: [], playedTime: nil,
                                    timingOffsetMs: nil, confidence: 1)
            }
            credits.append(credit)
            graded.append(grade)
        }
        gradedRounds.append((passage, graded))
        if roundIndex + 1 < roundCount {
            roundIndex += 1
            cursor = 0
            marks = [:]
            misses = [:]
            if hasReference {
                cancelListening()
                phase = .starting
                playReferenceThenListen()
            } else {
                armRemaining()
            }
            return
        }
        cancelListening()
        let accuracy = credits.isEmpty ? 0 : credits.reduce(0, +) / Double(credits.count)
        let clean = credits.filter { $0 >= 1 }.count
        finishRun(accuracy: accuracy, unsure: false,
                  summary: "\(clean) of \(credits.count) clean",
                  detail: roundCount > 1 ? "\(roundCount) rounds" : nil, timing: nil)
    }

    private func finishTimedRun() {
        guard let passage else { return }
        stopTicker()
        // Stopping flushes the verifier's open windows into `handle`.
        if listener.isListening { listener.stop() }
        collecting = false
        let analysis = TakeAnalyzer().analyze(passage: passage, live: live, detected: detected,
                                              tempoScale: tempoScale, timingReference: .target)
        var newMarks: [Int: Mark] = [:]
        for g in analysis.graded {
            switch g.grade {
            case .hit: newMarks[g.expectedID] = .hit
            case .partial: newMarks[g.expectedID] = .partial
            case .wrongPitch: newMarks[g.expectedID] = .retry
            case .missed: newMarks[g.expectedID] = .missed
            case .uncertain: newMarks[g.expectedID] = .notSure
            }
            if let event = passage.events.first(where: { $0.id == g.expectedID }),
               let tip = coach.registerAttempt(g, event: event) {
                coachMessage = tip
            }
        }
        marks = newMarks
        gradedRounds.append((passage, analysis.graded))
        let decided = analysis.graded.filter { $0.grade != .uncertain }.count
        let unsure = analysis.graded.isEmpty || decided * 3 < analysis.graded.count
        var detail: String?
        if let mad = analysis.timingMADms {
            detail = "Timing: typically within \(Int(mad.rounded())) ms of the beat"
        }
        if let suggestion = analysis.suggestions.first?.message {
            detail = [detail, suggestion].compactMap { $0 }.joined(separator: ". ")
        }
        let hits = analysis.graded.filter { $0.grade == .hit }.count
        finishRun(accuracy: analysis.accuracy, unsure: unsure,
                  summary: "\(hits) of \(analysis.graded.count) on time and in tune",
                  detail: detail, timing: analysis.timingMADms)
    }

    private func finishDurationRun() {
        stopTicker()
        cancelListening()
        switch pacing {
        case .anyOrder:
            let total = max(1, targetPitches.count)
            let names = targetPitches.filter { !found.contains($0) }.map { TutorAudioHelpers.name($0) }
            finishRun(accuracy: Double(found.count) / Double(total), unsure: false,
                      summary: "Found \(found.count) of \(targetPitches.count)",
                      detail: names.isEmpty ? nil : "Still to find: " + names.joined(separator: ", "), timing: nil)
        case .countChanges:
            let target = max(1, events.count)
            finishRun(accuracy: min(1, Double(cleanChords) / Double(target)), unsure: false,
                      summary: "\(cleanChords) clean chords",
                      detail: "Goal: \(Int((Double(target) * passAccuracy).rounded(.up))) in \(Int(durationSec)) seconds",
                      timing: nil)
        case .free:
            let pitches = freeNotes.map(\.pitch)
            guard pitches.count >= 8 else {
                finishRun(accuracy: 0, unsure: true, summary: "Only \(pitches.count) notes came through",
                          detail: "Play a little longer, or move closer to the microphone.", timing: nil)
                return
            }
            let allowed = exercise?.allowedPitchClasses ?? []
            let share = Self.inScaleShare(pitches, allowed: allowed)
            let steadiness = Self.steadiness(onsets: freeNotes.map(\.time))
            let scaleName = exercise?.scale?.displayName ?? "the scale"
            finishRun(accuracy: share, unsure: false,
                      summary: "\(Int((share * 100).rounded()))% of notes in \(scaleName)",
                      detail: steadiness.map { "Rhythm steadiness \(Int(($0 * 100).rounded()))%" }, timing: nil)
        case .wait, .timed:
            break
        }
    }

    private func finishRun(accuracy: Double, unsure: Bool, summary: String, detail: String?, timing: Double?) {
        stopTicker()
        collecting = false
        let passed = !unsure && accuracy + 1e-9 >= passAccuracy
        let result = RunResult(accuracy: accuracy, passed: passed, unsure: unsure, summary: summary,
                               detail: detail, timingMADms: timing)
        lastResult = result
        if !unsure { bestAccuracy = max(bestAccuracy ?? 0, accuracy) }
        if passed { hasPassed = true }
        if !unsure, let offer = coach.registerRun(accuracy: accuracy) {
            coachMessage = offer
            if case .offerTempo(let next) = offer { tempoOffer = next }
        } else if passed {
            coachMessage = weakestItem
        }
        feedback = nil
        phase = .finished
        onRunFinished?(result)
    }

    /// Weakest item across the run's rounds.
    var weakestItem: CoachMessage? {
        var combined = ExpectedPassage(events: [], beatsPerMeasure: 4, bpm: bpm, instrument: instrument)
        var graded: [GradedEvent] = []
        for (r, entry) in gradedRounds.enumerated() {
            for e in entry.passage.events {
                var copy = e
                copy.id = r * 10_000 + e.id
                combined.events.append(copy)
            }
            for g in entry.graded {
                var copy = g
                copy.expectedID = r * 10_000 + g.expectedID
                graded.append(copy)
            }
        }
        return FeedbackCoach.weakestItem(passage: combined, graded: graded)
    }

    private func resetRun() {
        stopTicker()
        roundIndex = 0
        cursor = 0
        marks = [:]
        misses = [:]
        credits = []
        gradedRounds = []
        live = []
        detected = []
        freeNotes = []
        found = []
        cleanChords = 0
        freeNoteCount = 0
        remaining = nil
        currentBeat = -1
        feedback = nil
        collecting = false
        playbackStep = nil
    }

    // MARK: Scoring helpers

    static func inScaleShare(_ pitches: [Int], allowed: Set<PitchClass>) -> Double {
        guard !pitches.isEmpty else { return 0 }
        guard !allowed.isEmpty else { return 1 }
        return Double(pitches.filter { allowed.contains(PitchClass($0)) }.count) / Double(pitches.count)
    }

    /// 1 − coefficient of variation of inter-onset intervals (gaps over 2 s are
    /// phrase breaks and ignored). Nil with fewer than four intervals.
    static func steadiness(onsets: [TimeInterval]) -> Double? {
        let sorted = onsets.sorted()
        let gaps = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.filter { $0 > 0.05 && $0 <= 2 }
        guard gaps.count >= 4 else { return nil }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        let variance = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)
        return max(0, min(1, 1 - variance.squareRoot() / mean))
    }
}
