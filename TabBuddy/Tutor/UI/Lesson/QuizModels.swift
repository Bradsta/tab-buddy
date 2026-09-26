//
//  QuizModels.swift
//  TabBuddy
//
//  Quiz logic: one question's state (answering by tap or by playing) and a
//  quiz step's sequence and score.
//

import Foundation
import SwiftUI

// MARK: - Answer by playing

/// How a question can be answered on the instrument, inferred from its choices.
enum PlayedAnswerKind: Equatable {
    /// Choices name pitch classes ("F♯/G♭", "C"): play any octave of the note.
    case note(choicePitchClasses: [Set<PitchClass>])
    /// Choices name intervals: play two notes, lower first.
    case interval(choiceSemitones: [Int?])
    /// Choices name chord qualities: play the chord.
    case chordQuality(choiceQualities: [ChordQuality?])

    static func infer(_ question: QuizQuestion) -> PlayedAnswerKind? {
        let choices = question.choices
        guard choices.count >= 2 else { return nil }
        let pcs = choices.map(pitchClasses(of:))
        let prompt = question.prompt.lowercased()
        if pcs.allSatisfy({ !$0.isEmpty }), !prompt.contains("chord"), !prompt.contains("scale") {
            return .note(choicePitchClasses: pcs)
        }
        // Interval names ("Major third", "Perfect fifth").
        let intervals = choices.map { Interval($0) ?? Interval($0.lowercased()) }
        if intervals.allSatisfy({ $0 != nil }), question.playback != nil || prompt.contains("interval") {
            return .interval(choiceSemitones: intervals.map { $0?.semitones })
        }
        let qualities = choices.map(quality(named:))
        if qualities.allSatisfy({ $0 != nil }) { return .chordQuality(choiceQualities: qualities) }
        return nil
    }

    /// "F♯/G♭" → {F♯}; "Bb" → {B♭}; empty when the text is not a note name.
    static func pitchClasses(of text: String) -> Set<PitchClass> {
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        var result = Set<PitchClass>()
        for part in parts {
            guard !part.isEmpty, part.count <= 3, let note = SpelledNote(part) else { return [] }
            result.insert(note.pitchClass)
        }
        return result
    }

    static func quality(named text: String) -> ChordQuality? {
        let lower = text.lowercased()
        return ChordQuality.allCases.first { $0.name == lower }
    }

    /// Choice index for a sequence of played notes (monophonic detections, in
    /// order) and chord detections. Nil when the notes don't decide it yet.
    func choice(forNotes notes: [Int], chordPitches: [Int]) -> Int? {
        switch self {
        case .note(let sets):
            guard let last = notes.last else { return nil }
            return sets.firstIndex { $0.contains(PitchClass(last)) }
        case .interval(let semitones):
            guard notes.count >= 2 else { return nil }
            let a = notes[notes.count - 2], b = notes[notes.count - 1]
            let size = abs(b - a)
            return semitones.firstIndex { $0 == size }
        case .chordQuality(let qualities):
            let pcs = Set(chordPitches.map { PitchClass($0) })
            guard pcs.count >= 3, let bass = chordPitches.min() else { return nil }
            let candidates = Chord.identify(pitchClasses: pcs, bass: PitchClass(bass))
            for chord in candidates {
                if let i = qualities.firstIndex(where: { $0 == chord.quality }) { return i }
            }
            return nil
        }
    }

    var instruction: String {
        switch self {
        case .note: return "Play the note on your instrument, any octave."
        case .interval: return "Play the two notes, lower first."
        case .chordQuality: return "Play a chord of that quality."
        }
    }
}

// MARK: - One question

@MainActor
final class QuizQuestionModel: ObservableObject {
    let question: QuizQuestion
    let instrument: TutorInstrument
    let playedKind: PlayedAnswerKind?
    let listener: TutorListening
    let player: TutorSequencePlaying

    @Published private(set) var selected: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackMIDI: Set<Int> = []
    @Published private(set) var isListening = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var heardText: String?
    private var heardNotes: [Int] = []
    /// Bumped by every start/stop; a start that finishes after a stop is dropped.
    private var listenGeneration = 0
    private var isStartingListening = false
    private var stopToken: TutorObserverToken?
    var onAnswered: ((Bool) -> Void)?

    init(question: QuizQuestion, instrument: TutorInstrument, listener: TutorListening, player: TutorSequencePlaying) {
        self.question = question
        self.instrument = instrument
        self.listener = listener
        self.player = player
        playedKind = PlayedAnswerKind.infer(question)
        stopToken = listener.observeUnexpectedStop { [weak self] in
            guard let self, self.isListening else { return }
            self.isListening = false
            self.heardText = TutorListeningCopy.stoppedUnexpectedly
        }
    }

    var isAnswered: Bool { selected != nil }
    var isCorrect: Bool { selected == question.answerIndex }

    /// Ear questions (audio but no picture) play first automatically.
    var isEarQuestion: Bool {
        guard question.playback != nil else { return false }
        if question.diagram == nil { return true }
        let p = question.prompt.lowercased()
        return p.hasPrefix("listen") || p.hasPrefix("hear")
    }

    /// The audio is shown before answering only for ear questions; afterwards for all.
    var showsPlayButton: Bool { question.playback != nil && (isEarQuestion || isAnswered) }

    var sequence: PlaybackSequence? {
        guard let spec = question.playback else { return nil }
        return try? ExerciseGenerator.playback(for: spec, context: .standard(instrument))
    }

    func answer(_ index: Int) {
        guard !isAnswered, question.choices.indices.contains(index) else { return }
        stopListening()
        selected = index
        onAnswered?(index == question.answerIndex)
    }

    func togglePlayback() {
        if isPlaying { player.stop(); isPlaying = false; playbackMIDI = []; return }
        guard let sequence else { return }
        // Output is muted while listening: stop first, then resume after.
        let resume = isListening
        if resume { stopListening() }
        isPlaying = true
        player.play(sequence, instrument: instrument, onStep: { [weak self] i in
            self?.playbackMIDI = Set(sequence.notes[i].pitches)
        }, completion: { [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.playbackMIDI = []
            if resume, !self.isAnswered { Task { await self.startListening() } }
        })
    }

    func stopAudio() {
        player.stop()
        isPlaying = false
        playbackMIDI = []
        stopListening()
    }

    // MARK: Answer by playing

    func toggleListening() async {
        if isListening || isStartingListening { stopListening() } else { await startListening() }
    }

    func startListening() async {
        guard playedKind != nil, !isAnswered, !isListening, !isStartingListening else { return }
        if isPlaying { player.stop(); isPlaying = false }
        listenGeneration += 1
        let generation = listenGeneration
        isStartingListening = true
        defer { if generation == listenGeneration { isStartingListening = false } }
        heardNotes = []
        heardText = nil
        listener.detectionSources = .all
        listener.onDetected = { [weak self] event in self?.handle(event) }
        listener.onVerification = nil
        do {
            try await listener.start(profile: TutorAudioHelpers.profile(for: instrument), recordTake: false)
            // Answered, played, or stopped while the microphone started.
            guard generation == listenGeneration, !isAnswered else {
                listener.stop()
                return
            }
            guard listener.isListening else { return }
            isListening = true
            permissionDenied = false
        } catch {
            guard generation == listenGeneration else { return }
            permissionDenied = listener.isPermissionError(error)
            heardText = permissionDenied ? nil : "The microphone could not start."
        }
    }

    func stopListening() {
        guard isListening || isStartingListening else { return }
        listenGeneration += 1
        isStartingListening = false
        listener.stop()     // also cancels a start in progress
        isListening = false
    }

    func handle(_ event: DetectedEvent) {
        guard isListening, let kind = playedKind else { return }
        let confident = zip(event.pitches, event.confidences).filter { $0.1 >= 0.4 }.map(\.0)
        guard !confident.isEmpty else {
            heardText = "Not sure what I heard. Try again."
            return
        }
        var chordPitches: [Int] = []
        switch kind {
        case .chordQuality:
            guard event.source == .verifier else { return }
            chordPitches = confident
            heardText = "Heard " + confident.sorted().map { TutorAudioHelpers.name($0) }.joined(separator: " ")
        case .note, .interval:
            guard event.source == .monophonic, let p = confident.first else { return }
            heardNotes.append(p)
            heardText = "Heard " + heardNotes.suffix(2).map { TutorAudioHelpers.name($0) }.joined(separator: ", ")
        }
        if let index = kind.choice(forNotes: heardNotes, chordPitches: chordPitches) {
            answer(index)
        } else if case .note = kind {
            heardText = (heardText ?? "") + ". That is not one of the choices."
        } else if case .interval = kind, heardNotes.count >= 2 {
            heardText = (heardText ?? "") + ". That interval is not one of the choices. Try again."
            heardNotes = []
        }
    }
}

// MARK: - Quiz step

@MainActor
final class QuizStepModel: ObservableObject {
    let title: String
    let questions: [QuizQuestion]
    let generationError: String?

    @Published private(set) var index = 0
    @Published private(set) var answers: [Bool] = []

    init(step: QuizStep, instrument: TutorInstrument, seed: UInt64) {
        title = step.title
        do {
            questions = try QuizGenerator.questions(for: step, instrument: instrument, seed: seed)
            generationError = nil
        } catch {
            questions = step.questions ?? []
            generationError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    var current: QuizQuestion? { questions.indices.contains(index) ? questions[index] : nil }
    var isCurrentAnswered: Bool { answers.count > index }
    var isFinished: Bool { !questions.isEmpty && answers.count >= questions.count && index >= questions.count - 1 && isCurrentAnswered }
    var correctCount: Int { answers.filter { $0 }.count }
    var score: Double { questions.isEmpty ? 1 : Double(correctCount) / Double(questions.count) }

    func record(correct: Bool) {
        guard answers.count == index else { return }
        answers.append(correct)
    }

    func next() {
        guard isCurrentAnswered, index + 1 < questions.count else { return }
        index += 1
    }

    /// Try the quiz again from the first question.
    func restart() {
        index = 0
        answers = []
    }
}
