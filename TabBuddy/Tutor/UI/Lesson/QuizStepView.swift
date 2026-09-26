//
//  QuizStepView.swift
//  TabBuddy
//
//  A quiz step: fixed questions then generated ones, one at a time, with a
//  score row. Return moves to the next question once answered.
//

import SwiftUI

struct QuizStepView: View {
    let step: QuizStep
    let instrument: TutorInstrument
    var onOutcome: (StepOutcome) -> Void

    @StateObject private var model: QuizStepModel
    @State private var attempt = 0

    init(step: QuizStep, instrument: TutorInstrument, seed: UInt64, onOutcome: @escaping (StepOutcome) -> Void) {
        self.step = step
        self.instrument = instrument
        self.onOutcome = onOutcome
        _model = StateObject(wrappedValue: QuizStepModel(step: step, instrument: instrument, seed: seed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if let error = model.generationError, model.questions.isEmpty {
                TutorMessageRow(text: "This quiz could not be prepared (\(error)).", systemImage: "exclamationmark.circle",
                                tone: .neutral)
                Button("Continue without it") { onOutcome(.skipped(label: step.title)) }
                    .buttonStyle(TutorSecondaryButtonStyle())
            } else if let question = model.current {
                QuizQuestionView(question: question, instrument: instrument) { correct in
                    model.record(correct: correct)
                    if model.isFinished {
                        onOutcome(StepOutcome(score: model.score, passed: true, label: step.title))
                    }
                }
                .id("\(attempt)-\(model.index)")
                footer
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUIZ").font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(DS.accentStrong)
            Text(model.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(DS.fg1)
            if !model.questions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.questions.indices, id: \.self) { i in
                        Capsule()
                            .fill(dotColor(i))
                            .frame(width: i == model.index ? 26 : 14, height: 8)
                    }
                    Text("Question \(min(model.index + 1, model.questions.count)) of \(model.questions.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(DS.fg2)
                        .padding(.leading, 6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Question \(model.index + 1) of \(model.questions.count), \(model.correctCount) correct so far")
            }
        }
    }

    private func dotColor(_ i: Int) -> Color {
        if i < model.answers.count { return model.answers[i] ? Color.green : DS.cautionText.opacity(0.6) }
        return i == model.index ? DS.accent : DS.surfaceInset
    }

    @ViewBuilder
    private var footer: some View {
        if model.isCurrentAnswered {
            if model.isFinished {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(model.correctCount) of \(model.questions.count) correct")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(DS.fg1)
                    Text(summaryText).foregroundStyle(DS.fg2)
                    Button {
                        attempt += 1
                        model.restart()
                    } label: {
                        Label("Try the quiz again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TutorSecondaryButtonStyle())
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            } else {
                Button {
                    model.next()
                } label: {
                    Label("Next question", systemImage: "arrow.right")
                }
                .buttonStyle(TutorPrimaryButtonStyle())
                .frame(maxWidth: 360)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var summaryText: String {
        let missed = model.questions.count - model.correctCount
        if missed == 0 { return "Every answer right. These items will come back in reviews." }
        return "\(missed) to revisit. They will come back in reviews, or you can try the quiz again now."
    }
}
