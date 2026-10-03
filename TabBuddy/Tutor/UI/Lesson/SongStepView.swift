//
//  SongStepView.swift
//  TabBuddy
//
//  Song excerpt as a playable "Try it" box: Play (synth) with loop and tempo,
//  the passage as chips grouped by measure, and optional listening (wait for
//  each note, or play along after a visual count-in with live highlighting).
//  Nothing is graded.
//

import SwiftUI

@MainActor
enum SongCardBuilder {
    /// Timed exercise for a song excerpt; `error` when the song cannot be built.
    static func exercise(for song: SongStep, instrument: TutorInstrument) -> (GeneratedExercise?, String?) {
        do {
            let passage = try ExerciseGenerator.passage(for: song, context: .standard(instrument))
            let exercise = GeneratedExercise(kind: .playSequence, pacing: .timed,
                                             rounds: [ExerciseRound(reference: nil, expected: passage, label: nil)],
                                             bpm: song.bpm, tempoSteps: [], passAccuracy: 1, durationSec: nil)
            return (exercise, nil)
        } catch {
            return (nil, (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    static func model(for song: SongStep, instrument: TutorInstrument, listener: TutorListening,
                      player: TutorSequencePlaying) -> TryItModel {
        let (exercise, error) = Self.exercise(for: song, instrument: instrument)
        let prompt = song.caption ?? "Play along with the excerpt, or let it wait for each note."
        return TryItModel(exercise: exercise, generationError: error, prompt: prompt, instrument: instrument,
                          bpm: song.bpm, listener: listener, player: player)
    }
}

struct SongStepView: View {
    let step: SongStep
    let instrument: TutorInstrument

    @StateObject private var model: TryItModel

    init(step: SongStep, instrument: TutorInstrument) {
        self.step = step
        self.instrument = instrument
        _model = StateObject(wrappedValue: SongCardBuilder.model(for: step, instrument: instrument,
                                                                 listener: TutorListener(), player: TutorSequencePlayer.shared))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(Int(step.bpm)) BPM · \(step.beatsPerMeasure) beats per measure")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(DS.fg3)
            TryItCardView(model: model, showsPrompt: step.caption != nil, alwaysShowMeasures: true)
        }
    }
}
