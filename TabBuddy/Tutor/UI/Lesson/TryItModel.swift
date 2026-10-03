//
//  TryItModel.swift
//  TabBuddy
//
//  State for a "Try it" box: an exercise (lesson practice step, song excerpt,
//  or a quick-practice spec) with synth playback at an adjustable tempo, a
//  loop toggle, and an optional "Listen" switch that only turns heard notes
//  green. Nothing is graded: there is no pass, run end, score, or goal.
//
//  Listening comes in two forms:
//  - wait (default): the current target is armed; a confident hit turns it
//    green and moves the cursor on. "Next" skips a target. The cursor wraps
//    around at the end so playing can continue without touching the screen.
//  - play-along (timed passages only): visual count-in, cursor at the tempo,
//    timed arming; hits turn green; the run stops (or loops) after the last
//    event.
//  Exercises without an ordered passage listen differently: findAllNotes ticks
//  off target pitches, improvise names the last heard note.
//
//  Audio goes through `TutorListening` / `TutorSequencePlaying`, so tests
//  drive it with fakes and a hand-set take clock (`tick()`).
//

import Foundation
import SwiftUI

@MainActor
final class TryItModel: ObservableObject {

    enum ListenState: Equatable {
        case off, starting, listening, permissionDenied, unavailable(String)
        var isOn: Bool { self == .starting || self == .listening }
    }

    enum ListenMode: String, Equatable, CaseIterable, Identifiable {
        case wait, playAlong
        var id: String { rawValue }
        var title: String { self == .wait ? "Wait for me" : "Play along" }
    }

    // MARK: Configuration

    let instrument: TutorInstrument
    let exercise: GeneratedExercise?
    let generationError: String?
    let prompt: String
    let fixedDiagram: Diagram?
    let tips: [String]
    let listener: TutorListening
    let player: TutorSequencePlaying
    /// Off for click-only material (rhythm practice).
    let supportsListening: Bool
    /// Quick-practice cards supply their own example (arpeggio, strum, interval direction).
    private let customExample: PlaybackSequence?
    /// Runs a 30 Hz timer in play-along mode. Tests turn it off and call `tick()`.
    var autoTick = true

    static let tempoRange: ClosedRange<Double> = 30...220

    // MARK: Published state

    @Published private(set) var bpm: Double
    @Published var loop = false
    @Published private(set) var roundIndex = 0
    @Published private(set) var isPlaying = false
    /// Index into `exampleSequence.notes` while playing.
    @Published private(set) var playbackIndex: Int?
    @Published private(set) var soundUnavailable = false
    @Published private(set) var listenState: ListenState = .off
    @Published var listenMode: ListenMode = .wait
    /// Event ids heard (green).
    @Published private(set) var heard: Set<Int> = []
    @Published private(set) var cursor = 0
    /// findAllNotes: target pitches heard so far.
    @Published private(set) var found: Set<Int> = []
    /// Neutral line about the last detection ("Heard A♯2", "Not sure").
    @Published private(set) var statusText: String?
    @Published private(set) var statusTone: TutorTone = .neutral
    /// Play-along: beat position of the cursor (negative during the count-in).
    @Published private(set) var currentBeat: Double = -1
    @Published private(set) var countIn: (beat: Int, of: Int)?

    // MARK: Private state

    private var listenGeneration = 0
    private var resumeListeningAfterPlayback = false
    private var ticker: Task<Void, Never>?
    private var passageStart: TimeInterval = 0
    private var countInBeats = 4
    private var stopToken: TutorObserverToken?

    // MARK: Init

    /// Lesson practice step.
    convenience init(step: PracticeStep, instrument: TutorInstrument, intervals: [Interval]? = nil, seed: UInt64 = 1,
                     stage: Int? = nil, listener: TutorListening, player: TutorSequencePlaying) {
        var exercise: GeneratedExercise?
        var failure: String?
        do {
            exercise = try ExerciseGenerator.generate(step.exercise, context: .standard(instrument),
                                                      intervals: intervals, seed: seed, stage: stage)
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        self.init(exercise: exercise, generationError: failure, prompt: step.exercise.prompt,
                  diagram: step.exercise.diagram, tips: step.mistakeTips, instrument: instrument,
                  bpm: exercise?.bpm ?? step.exercise.bpm ?? step.exercise.tempoSteps?.first ?? ExerciseGenerator.defaultBPM,
                  listener: listener, player: player)
    }

    /// Any generated exercise (songs, quick practice).
    init(exercise: GeneratedExercise?, generationError: String? = nil, prompt: String, diagram: Diagram? = nil,
         tips: [String] = [], instrument: TutorInstrument, bpm: Double? = nil, supportsListening: Bool = true,
         example: PlaybackSequence? = nil, listener: TutorListening, player: TutorSequencePlaying) {
        self.instrument = instrument
        self.customExample = example
        self.exercise = exercise
        self.generationError = generationError
        self.prompt = prompt
        self.fixedDiagram = diagram
        self.tips = tips
        self.listener = listener
        self.player = player
        self.supportsListening = supportsListening && exercise != nil
        self.bpm = Self.clampTempo(bpm ?? exercise?.bpm ?? ExerciseGenerator.defaultBPM)
        if exercise?.pacing == .timed { listenMode = .playAlong }
    }

    // MARK: Derived

    var pacing: ExercisePacing { exercise?.pacing ?? .wait }
    var roundCount: Int { exercise?.rounds.count ?? 0 }
    var round: ExerciseRound? {
        guard let exercise, exercise.rounds.indices.contains(roundIndex) else { return nil }
        return exercise.rounds[roundIndex]
    }
    var passage: ExpectedPassage? { round?.expected }
    var hasReference: Bool { round?.reference != nil }
    /// Tempo chips from the content's ladder.
    var tempoSteps: [Double] { exercise?.tempoSteps ?? [] }
    var targetPitches: [Int] { exercise?.targetPitches ?? [] }
    var scale: Scale? { exercise?.scale }
    var tempoScale: Double {
        guard let base = passage?.bpm, base > 0 else { return 1 }
        return bpm / base
    }
    var secondsPerBeat: Double { 60 / max(1, bpm) }

    /// Sounded events shown and armed. Chord-change drills show the chord
    /// cycle twice rather than the generator's long grading list.
    var events: [ExpectedEvent] {
        guard let passage else { return [] }
        let sounded = passage.events.filter { !$0.pitches.isEmpty }
        guard exercise?.kind == .chordChanges else { return sounded }
        let distinct = Set(sounded.compactMap(\.chordName)).count
        return Array(sounded.prefix(max(2, distinct * 2)))
    }
    var currentEvent: ExpectedEvent? { events.indices.contains(cursor) ? events[cursor] : nil }
    var totalBeats: Double { passage?.events.map { $0.beat + $0.durationBeats }.max() ?? 0 }

    /// Play-along needs a timed passage (a tempo and ordered events).
    var supportsPlayAlong: Bool {
        guard let passage, supportsListening, !hasReference else { return false }
        return !passage.isFreeTime && (pacing == .timed || pacing == .wait) && events.count > 1
    }

    var isListening: Bool { listenState.isOn }
    var isCountingIn: Bool { countIn != nil }

    /// What "Play example" sounds at the current tempo.
    var exampleSequence: PlaybackSequence? {
        guard let exercise else { return nil }
        if let customExample {
            return PlaybackSequence(notes: customExample.notes, bpm: bpm, style: customExample.style)
        }
        if let reference = round?.reference {
            return PlaybackSequence(notes: reference.notes, bpm: bpm, style: reference.style)
        }
        switch pacing {
        case .anyOrder:
            let notes = targetPitches.enumerated().map { PlaybackNote(pitches: [$0.element], startBeat: Double($0.offset), durationBeats: 1) }
            return notes.isEmpty ? nil : PlaybackSequence(notes: notes, bpm: bpm, style: .sequence)
        case .free:
            guard let scale = exercise.scale ?? exercise.key?.scale else { return nil }
            let pitches = InstrumentContext.standard(instrument).scalePitches(scale, octaves: 1, upAndDown: true)
            let notes = pitches.enumerated().map { PlaybackNote(pitches: [$0.element.midi], startBeat: Double($0.offset), durationBeats: 1,
                                                                label: $0.element.note.displayName) }
            return PlaybackSequence(notes: notes, bpm: bpm, style: .sequence)
        case .countChanges:
            let notes = events.enumerated().map {
                PlaybackNote(pitches: $0.element.pitches, startBeat: Double($0.offset) * 2, durationBeats: 2,
                             label: $0.element.chordName, fretting: $0.element.fretting)
            }
            return PlaybackSequence(notes: notes, bpm: bpm, style: .strum)
        case .wait, .timed:
            guard let passage, !passage.events.isEmpty else { return nil }
            let notes = passage.events.map {
                PlaybackNote(pitches: $0.pitches, startBeat: $0.beat, durationBeats: $0.durationBeats, label: $0.chordName,
                             fretting: $0.fretting)
            }
            return PlaybackSequence(notes: notes, bpm: bpm, style: .sequence)
        }
    }

    /// Sounding pitches to highlight: the playing note, else the listening target.
    var highlightedMIDI: Set<Int> {
        if let i = playbackIndex, let seq = exampleSequence, seq.notes.indices.contains(i) {
            return Set(seq.notes[i].pitches)
        }
        if listenState == .listening, let event = currentEvent, pacing != .anyOrder, pacing != .free {
            return Set(event.pitches)
        }
        return []
    }

    /// Index into `events` sounding in the example (for the passage strip).
    var playingEventIndex: Int? {
        guard let i = playbackIndex, let seq = exampleSequence, seq.notes.indices.contains(i), round?.reference == nil,
              pacing == .wait || pacing == .timed || pacing == .countChanges else { return nil }
        let note = seq.notes[i]
        return events.firstIndex { $0.beat == note.startBeat && $0.pitches == note.pitches } ?? events.firstIndex { $0.pitches == note.pitches }
    }

    /// Diagram for the current target, or the step's fixed one.
    var diagram: Diagram? {
        let event = currentEvent ?? events.first
        if let fixedDiagram {
            let mismatch = fixedDiagram.chord != nil && event?.chordName != nil && fixedDiagram.chord != event?.chordName
            if !mismatch { return fixedDiagram }
        }
        if pacing == .free || pacing == .anyOrder {
            if let scale {
                return Diagram(kind: instrument == .guitar ? .fretboard : .keyboard, scale: scale.name, labels: .noteNames,
                               fretRange: instrument == .guitar ? [0, 5] : nil,
                               pitchRange: instrument == .piano ? ["C4", "C5"] : nil)
            }
            if pacing == .anyOrder, !targetPitches.isEmpty {
                return Diagram.forEvent(pitches: targetPitches, fretting: nil, chordName: nil, instrument: instrument)
            }
        }
        if let i = playbackIndex, let seq = exampleSequence, seq.notes.indices.contains(i), !seq.notes[i].pitches.isEmpty {
            let note = seq.notes[i]
            return Diagram.forEvent(pitches: note.pitches, fretting: note.fretting, chordName: note.label.flatMap { Chord($0) != nil ? $0 : nil },
                                    instrument: instrument)
        }
        guard let event else { return nil }
        return Diagram.forEvent(pitches: event.pitches, fretting: event.fretting, chordName: event.chordName, instrument: instrument)
    }

    // MARK: Rounds (phrases)

    func selectRound(_ index: Int) {
        guard exercise?.rounds.indices.contains(index) == true, index != roundIndex else { return }
        stopPlayback()
        roundIndex = index
        heard = []
        cursor = 0
        if listenState == .listening { armForWait() }
    }

    // MARK: Playback

    func togglePlayback() {
        if isPlaying { stopPlayback(); return }
        playExample()
    }

    func playExample() {
        guard let sequence = exampleSequence else { return }
        // Output is muted while listening: pause the microphone, resume after.
        if listenState.isOn {
            resumeListeningAfterPlayback = true
            cancelListening(keepMarks: true)
        }
        isPlaying = true
        let started = player.play(sequence, instrument: instrument, onStep: { [weak self] i in
            self?.playbackIndex = i
        }, completion: { [weak self] in
            guard let self else { return }
            self.playbackIndex = nil
            if self.loop, self.isPlaying {
                self.playExample()
                return
            }
            self.isPlaying = false
            if self.resumeListeningAfterPlayback {
                self.resumeListeningAfterPlayback = false
                Task { await self.startListening() }
            }
        })
        soundUnavailable = !started
        if !started { isPlaying = false; resumeListeningAfterPlayback = false }
    }

    func stopPlayback() {
        guard isPlaying else { return }
        isPlaying = false
        playbackIndex = nil
        player.stop()
        if resumeListeningAfterPlayback {
            resumeListeningAfterPlayback = false
            Task { await startListening() }
        }
    }

    /// Changing the tempo restarts nothing; the next Play uses it. Play-along
    /// runs restart at the new tempo.
    static func clampTempo(_ value: Double) -> Double {
        min(tempoRange.upperBound, max(tempoRange.lowerBound, value))
    }

    func setTempo(_ value: Double) {
        bpm = Self.clampTempo(value.rounded())
        if listenState == .listening, listenMode == .playAlong { beginPlayAlong() }
    }

    func nudgeTempo(_ delta: Double) { setTempo(bpm + delta) }

    // MARK: Listening

    func toggleListening() async {
        if listenState.isOn { stopListening() } else { await startListening() }
    }

    func setListenMode(_ mode: ListenMode) {
        guard mode != listenMode else { return }
        listenMode = mode
        heard = []
        cursor = 0
        if listenState == .listening {
            cancelListening(keepMarks: false)
            Task { await startListening() }
        }
    }

    func startListening() async {
        guard supportsListening, exercise != nil, !listenState.isOn else { return }
        if isPlaying { loop = false; stopPlayback() }
        listenGeneration += 1
        let generation = listenGeneration
        listenState = .starting
        statusText = nil
        listener.onVerification = { [weak self] r in self?.handle(r) }
        listener.onDetected = { [weak self] d in self?.handle(d) }
        listener.detectionSources = (pacing == .anyOrder || pacing == .free) ? .monophonic : .all
        do {
            try await listener.start(profile: TutorAudioHelpers.profile(for: instrument), recordTake: false)
        } catch {
            guard generation == listenGeneration else { return }
            listenState = listener.isPermissionError(error) ? .permissionDenied : .unavailable(error.localizedDescription)
            return
        }
        guard generation == listenGeneration, listenState == .starting else {
            if generation == listenGeneration { listener.stop() }
            return
        }
        guard listener.isListening else { listenState = .off; return }
        observeUnexpectedStop()
        listenState = .listening
        switch pacing {
        case .anyOrder, .free:
            break
        case .wait, .timed, .countChanges:
            if listenMode == .playAlong, supportsPlayAlong { beginPlayAlong() } else { armForWait() }
        }
    }

    func stopListening() {
        cancelListening(keepMarks: true)
        listenState = .off
        countIn = nil
    }

    /// Wait mode: give up on the current target and move on (neutral).
    func skipCurrent() {
        guard listenState == .listening, listenMode == .wait, currentEvent != nil else { return }
        advanceCursor()
    }

    /// Clears the green marks (and found notes) without stopping.
    func resetMarks() {
        heard = []
        found = []
        cursor = 0
        statusText = nil
        if listenState == .listening, listenMode == .wait { armForWait() }
    }

    private func cancelListening(keepMarks: Bool) {
        listenGeneration += 1
        stopTicker()
        countIn = nil
        if listener.isListening {
            listener.disarm()
            listener.stop()
        } else {
            listener.stop()     // cancels a start still waiting for the microphone
        }
        if listenState.isOn { listenState = .off }
        if !keepMarks { heard = []; cursor = 0 }
    }

    private func observeUnexpectedStop() {
        guard stopToken == nil else { return }
        stopToken = listener.observeUnexpectedStop { [weak self] in
            guard let self, self.listenState.isOn else { return }
            self.cancelListening(keepMarks: true)
            self.listenState = .off
            self.statusText = TutorListeningCopy.stoppedUnexpectedly
            self.statusTone = .neutral
        }
    }

    private func armForWait() {
        let rest = Array(events.dropFirst(cursor))
        guard !rest.isEmpty else { return }
        listener.arm(rest, window: .wait)
    }

    private func beginPlayAlong() {
        guard let passage else { return }
        stopTicker()
        heard = []
        cursor = 0
        countInBeats = min(6, max(2, passage.beatsPerMeasure))
        passageStart = listener.takeClock + 0.4 + Double(countInBeats) * secondsPerBeat
        let tolerance = min(0.3, max(0.15, 0.25 * secondsPerBeat))
        listener.armTimed(passage, passageStart: passageStart, tempoScale: tempoScale, tolerance: tolerance)
        currentBeat = -Double(countInBeats)
        countIn = (0, countInBeats)
        startTicker()
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

    /// Play-along clock: count-in, cursor, end of passage.
    func tick() {
        guard listenState == .listening, listenMode == .playAlong else { return }
        let beat = (listener.takeClock - passageStart) / secondsPerBeat
        currentBeat = beat
        if beat < 0 {
            let counted = countInBeats - Int(ceil(-beat)) + 1
            countIn = (max(1, min(countInBeats, counted)), countInBeats)
        } else {
            if countIn != nil { countIn = nil }
            let index = events.lastIndex { $0.beat <= beat + 0.05 } ?? 0
            if index != cursor { cursor = index }
            if beat > totalBeats + 1 {
                if loop {
                    beginPlayAlong()
                } else {
                    stopTicker()
                    listener.disarm()
                    listener.stop()
                    listenState = .off
                    statusText = "Played through. Tap Listen to go again."
                    statusTone = .neutral
                }
            }
        }
    }

    // MARK: Input

    func handle(_ r: VerificationResult) {
        guard listenState == .listening else { return }
        switch pacing {
        case .anyOrder, .free:
            return
        case .wait, .timed, .countChanges:
            break
        }
        if listenMode == .playAlong {
            if r.grade == .hit { heard.insert(r.expectedID) }
            return
        }
        guard let event = currentEvent, r.expectedID == event.id else { return }
        switch r.grade {
        case .hit:
            heard.insert(event.id)
            statusText = "\(label(event)) ✓"
            statusTone = .good
            advanceCursor()
        case .uncertain:
            statusText = "Not sure what I heard. Let it ring."
            statusTone = .neutral
        case .partial:
            statusText = "Part of \(label(event)) came through."
            statusTone = .neutral
        case .wrongPitch where !r.unexpected.isEmpty:
            statusText = "Heard " + r.unexpected.prefix(3).map { TutorAudioHelpers.name($0) }.joined(separator: " ")
            statusTone = .neutral
        case .wrongPitch, .missed:
            statusText = "Waiting for \(label(event))"
            statusTone = .neutral
        }
    }

    func handle(_ d: DetectedEvent) {
        guard listenState == .listening, d.source == .monophonic else { return }
        let confident = zip(d.pitches, d.confidences).filter { $0.1 >= 0.35 }.map(\.0)
        guard let pitch = confident.first else { return }
        switch pacing {
        case .anyOrder:
            if targetPitches.contains(pitch) {
                let inserted = found.insert(pitch).inserted
                statusText = inserted ? "Found \(TutorAudioHelpers.name(pitch))" : "\(TutorAudioHelpers.name(pitch)) again. Try another octave."
                statusTone = inserted ? .good : .neutral
            } else {
                statusText = "Heard \(TutorAudioHelpers.name(pitch))"
                statusTone = .neutral
            }
        case .free:
            let inScale = scale?.contains(midi: pitch) ?? true
            statusText = TutorAudioHelpers.name(pitch) + (inScale ? "" : " (outside the scale)")
            statusTone = inScale ? .good : .neutral
        case .wait, .timed, .countChanges:
            break
        }
    }

    private func advanceCursor() {
        cursor += 1
        if cursor >= events.count {
            // Start over so playing can continue without touching the screen.
            cursor = 0
            heard = []
        }
        if listenState == .listening { armForWait() }
    }

    private func label(_ event: ExpectedEvent) -> String {
        event.chordName ?? event.pitches.map { TutorAudioHelpers.name($0) }.joined(separator: " ")
    }

    /// Stops everything (view disappeared).
    func cancel() {
        loop = false
        resumeListeningAfterPlayback = false
        if isPlaying { isPlaying = false; playbackIndex = nil; player.stop() }
        cancelListening(keepMarks: true)
        listenState = .off
    }
}
