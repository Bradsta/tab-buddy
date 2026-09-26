//
//  SongStepView.swift
//  TabBuddy
//
//  Song excerpt: "Hear it first" plays the passage (chips light up), then play it in
//  wait mode (the passage waits for each note or chord) or play-along mode (a
//  timed run with count-in and beat pulse, starting at 70% tempo). The passage
//  shows as chips grouped by measure.
//

import SwiftUI

@MainActor
final class SongStepModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case wait, playAlong
        var id: String { rawValue }
        var title: String { self == .wait ? "Wait for me" : "Play along" }
    }

    let song: SongStep
    let instrument: TutorInstrument
    let passage: ExpectedPassage?
    let error: String?
    let demo: DemoPlaybackModel
    /// Playback note index → passage event index (rests have no event).
    let eventIndexForNote: [Int: Int]
    private let listener: TutorListening
    private let player: TutorSequencePlaying

    @Published private(set) var mode: Mode = .wait
    @Published private(set) var run: PracticeRunModel?
    var onRunFinished: ((PracticeRunModel.RunResult, PracticeRunModel) -> Void)?

    init(song: SongStep, instrument: TutorInstrument, listener: TutorListening, player: TutorSequencePlaying) {
        self.song = song
        self.instrument = instrument
        self.listener = listener
        self.player = player
        let context = InstrumentContext.standard(instrument)
        var passage: ExpectedPassage?
        var failure: String?
        var sequence: PlaybackSequence?
        do {
            passage = try ExerciseGenerator.passage(for: song, context: context)
            sequence = try ExerciseGenerator.playback(for: song, context: context)
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        self.passage = passage
        self.error = failure
        demo = DemoPlaybackModel(sequence: sequence, error: failure, instrument: instrument, player: player)
        var map: [Int: Int] = [:]
        var next = 0
        for (i, note) in (sequence?.notes ?? []).enumerated() where !note.pitches.isEmpty {
            map[i] = next
            next += 1
        }
        eventIndexForNote = map
        makeRun()
    }

    var playingEventIndex: Int? { demo.currentIndex.flatMap { eventIndexForNote[$0] } }

    func setMode(_ new: Mode) {
        guard new != mode else { return }
        run?.cancel()
        mode = new
        makeRun()
    }

    private func makeRun() {
        guard let passage else { run = nil; return }
        let bpm = song.bpm
        let steps = mode == .playAlong ? [ (bpm * 0.7).rounded(), (bpm * 0.85).rounded(), bpm ] : []
        let exercise = GeneratedExercise(kind: .playSequence, pacing: mode == .wait ? .wait : .timed,
                                         rounds: [ExerciseRound(reference: nil, expected: passage, label: nil)],
                                         bpm: bpm, tempoSteps: steps, passAccuracy: song.passAccuracy, durationSec: nil)
        let prompt = mode == .wait
            ? "Play each note or chord. The song waits for you."
            : "Play along after the count-in. Watch the beat dots; the app stays silent while it listens."
        let run = PracticeRunModel(exercise: exercise, prompt: prompt, instrument: instrument,
                                   listener: listener, player: player)
        run.onRunFinished = { [weak self, weak run] result in
            guard let self, let run else { return }
            self.onRunFinished?(result, run)
        }
        self.run = run
    }
}

struct SongStepView: View {
    let step: SongStep
    let instrument: TutorInstrument
    var onOutcome: (StepOutcome) -> Void

    @StateObject private var model: SongStepModel

    init(step: SongStep, instrument: TutorInstrument, onOutcome: @escaping (StepOutcome) -> Void) {
        self.step = step
        self.instrument = instrument
        self.onOutcome = onOutcome
        _model = StateObject(wrappedValue: SongStepModel(song: step, instrument: instrument, listener: TutorListener(),
                                                         player: TutorSequencePlayer.shared))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if let error = model.error {
                TutorMessageRow(text: "This song could not be prepared (\(error)).", systemImage: "exclamationmark.circle",
                                tone: .neutral)
                Button("Skip this song") { onOutcome(.skipped(label: step.title)) }
                    .buttonStyle(TutorSecondaryButtonStyle())
            } else {
                Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    ForEach(SongStepModel.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                .disabled(model.run?.phase.isActive ?? false)
                if let run = model.run {
                    PracticeRunPanel(model: run, title: model.mode.title, showsPrompt: true, alwaysShowMeasures: true,
                                     onSkip: {
                                         run.cancel()
                                         onOutcome(.skipped(label: step.title))
                                     })
                    .id(model.mode)
                }
            }
        }
        .onAppear {
            let label = step.title
            let report = onOutcome
            model.onRunFinished = { result, run in
                guard !result.unsure else { return }
                report(StepOutcome(score: run.bestAccuracy ?? result.accuracy, passed: run.hasPassed,
                                   weakest: run.weakestItem, label: label))
            }
        }
        .onDisappear { model.demo.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SONG").font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(DS.accentStrong)
            Text(step.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            if let caption = step.caption {
                Text(caption).font(.title3).foregroundStyle(DS.fg2).fixedSize(horizontal: false, vertical: true)
            }
            Text("\(Int(step.bpm)) BPM · \(step.beatsPerMeasure) beats per measure")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(DS.fg3)
        }
    }
}
