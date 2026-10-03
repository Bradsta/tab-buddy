//
//  CheckYourselfView.swift
//  TabBuddy
//
//  The "Check yourself" section: every question as a flashcard with its
//  choices, an optional "Hear it" button, an optional diagram, and the
//  answer plus explanation once revealed. No score and no gating.
//

import SwiftUI

struct CheckYourselfView: View {
    let step: QuizStep
    let instrument: TutorInstrument

    @StateObject private var model: CheckYourselfModel

    init(step: QuizStep, instrument: TutorInstrument, seed: UInt64) {
        self.step = step
        self.instrument = instrument
        _model = StateObject(wrappedValue: CheckYourselfModel(step: step, instrument: instrument, seed: seed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("Tap a choice or Show answer. Nothing is scored.")
                    .font(.subheadline)
                    .foregroundStyle(DS.fg3)
                Spacer(minLength: 0)
                if model.hasGenerator {
                    Button { model.newSet() } label: { Label("New set", systemImage: "shuffle") }
                        .buttonStyle(.bordered)
                }
                if !model.revealed.isEmpty {
                    Button("Hide answers") { model.hideAll() }
                        .buttonStyle(.bordered)
                }
            }
            if let error = model.generationError {
                TutorMessageRow(text: "Generated questions could not be prepared (\(error)).",
                                systemImage: "exclamationmark.circle", tone: .neutral)
            }
            ForEach(Array(model.questions.enumerated()), id: \.offset) { i, question in
                FlashcardQuestionView(number: i + 1, question: question, instrument: instrument,
                                      revealed: model.isRevealed(i), chosen: model.choice(for: i)) { choice in
                    withAnimation(DS.motionFast) { model.reveal(i, choice: choice) }
                }
                .id("\(model.setNumber)-\(i)")
            }
        }
    }
}

/// One flashcard question. Reused by the Flashcards section for choice cards.
struct FlashcardQuestionView: View {
    var number: Int? = nil
    let question: QuizQuestion
    let instrument: TutorInstrument
    let revealed: Bool
    var chosen: Int? = nil
    /// Called with the tapped choice, or nil for "Show answer".
    var onReveal: (Int?) -> Void

    @StateObject private var playback: DemoPlaybackModel

    init(number: Int? = nil, question: QuizQuestion, instrument: TutorInstrument, revealed: Bool, chosen: Int? = nil,
         onReveal: @escaping (Int?) -> Void) {
        self.number = number
        self.question = question
        self.instrument = instrument
        self.revealed = revealed
        self.chosen = chosen
        self.onReveal = onReveal
        _playback = StateObject(wrappedValue: DemoPlaybackModel(spec: question.playback, instrument: instrument,
                                                                player: TutorSequencePlayer.shared))
    }

    var body: some View {
        WidthReader { width in
            let wide = TutorLayout.isWide(width) && question.diagram != nil
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 14) { prompt; diagram }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        answers.frame(width: min(400, width * 0.42))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) { prompt; diagram; answers }
                }
            }
        }
        .padding(18)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
        .onDisappear { playback.stop() }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let number {
                    Text("\(number).")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(DS.accentStrong)
                }
                Text(question.prompt)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DS.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.playback != nil {
                TutorPlayButton(isPlaying: playback.isPlaying, title: "Hear it") { playback.toggle() }
            }
        }
    }

    @ViewBuilder
    private var diagram: some View {
        if let diagram = question.diagram {
            DiagramView(diagram: diagram, instrument: instrument, highlightedMIDI: playback.highlighted)
                .padding(12)
                .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        }
    }

    private var answers: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(question.choices.enumerated()), id: \.offset) { i, choice in
                choiceButton(i, choice)
            }
            if revealed {
                explanation
            } else {
                Button("Show answer") { onReveal(nil) }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
            }
        }
    }

    private func choiceButton(_ i: Int, _ choice: String) -> some View {
        let isAnswer = revealed && i == question.answerIndex
        let isChosen = revealed && chosen == i && !isAnswer
        return Button {
            onReveal(i)
        } label: {
            HStack(spacing: 12) {
                Text("\(i + 1)")
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(isAnswer ? .white : DS.fg2)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isAnswer ? Color.green : DS.surfaceInset))
                Text(choice)
                    .font(.body.weight(.medium))
                    .foregroundStyle(DS.fg1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isAnswer {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                } else if isChosen {
                    Text("your pick").font(.caption).foregroundStyle(DS.fg3)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .fill(isAnswer ? Color.green.opacity(0.12) : DS.surfaceInset.opacity(revealed ? 0.5 : 1)))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .strokeBorder(isAnswer ? Color.green.opacity(0.7) : (isChosen ? DS.separatorStrong : .clear), lineWidth: isAnswer ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(revealed)
        .accessibilityLabel("Choice \(i + 1): \(choice)")
        .accessibilityValue(isAnswer ? "Correct answer" : "")
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Answer: \(question.choices[question.answerIndex])", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(DS.fg1)
            Text(question.explanation)
                .font(.subheadline)
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.accentSofter, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
