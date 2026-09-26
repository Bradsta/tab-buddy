//
//  QuizQuestionView.swift
//  TabBuddy
//
//  One multiple-choice question: prompt, optional audio (ear questions play
//  first automatically), optional diagram, large choices (keys 1–9), the
//  explanation after answering, and "answer by playing" for note, interval,
//  and chord-quality questions. Reused by the review session.
//

import SwiftUI

struct QuizQuestionView: View {
    let question: QuizQuestion
    let instrument: TutorInstrument
    var onAnswered: (_ correct: Bool) -> Void

    @StateObject private var model: QuizQuestionModel

    init(question: QuizQuestion, instrument: TutorInstrument, onAnswered: @escaping (_ correct: Bool) -> Void) {
        self.question = question
        self.instrument = instrument
        self.onAnswered = onAnswered
        _model = StateObject(wrappedValue: QuizQuestionModel(question: question, instrument: instrument,
                                                             listener: TutorListener(),
                                                             player: TutorSequencePlayer.shared))
    }

    var body: some View {
        WidthReader { width in
            let wide = TutorLayout.isWide(width) && question.diagram != nil
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 16) {
                            promptView
                            diagramView
                        }
                        .frame(maxWidth: .infinity)
                        answerColumn
                            .frame(width: min(420, width * 0.42))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        promptView
                        diagramView
                        answerColumn
                    }
                }
            }
        }
        .onAppear {
            model.onAnswered = onAnswered
            if model.isEarQuestion {
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if !model.isPlaying && !model.isAnswered { model.togglePlayback() }
                }
            }
        }
        .onDisappear { model.stopAudio() }
    }

    // MARK: Pieces

    private var promptView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.prompt)
                .font(.title2.weight(.semibold))
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            if model.showsPlayButton {
                TutorPlayButton(isPlaying: model.isPlaying, title: model.isAnswered ? "Hear it" : "Play again") {
                    model.togglePlayback()
                }
            }
        }
    }

    @ViewBuilder
    private var diagramView: some View {
        if let diagram = question.diagram {
            DiagramView(diagram: diagram, instrument: instrument, highlightedMIDI: model.playbackMIDI)
                .padding(16)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                .environment(\.tutorDiagramTapEnabled, model.isAnswered && !model.isListening)
        }
    }

    private var answerColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(question.choices.enumerated()), id: \.offset) { i, choice in
                choiceButton(i, choice)
            }
            if model.playedKind != nil && !model.isAnswered {
                playPanel
            }
            if model.isAnswered {
                explanation
            }
        }
    }

    private func choiceButton(_ i: Int, _ choice: String) -> some View {
        let state = choiceState(i)
        return Button {
            model.answer(i)
        } label: {
            HStack(spacing: 14) {
                Text("\(i + 1)")
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(state.badgeForeground)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(state.badgeBackground))
                Text(choice)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(DS.fg1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let icon = state.icon {
                    Image(systemName: icon).font(.title3).foregroundStyle(state.iconColor)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: TutorLayout.largeTarget)
            .background(RoundedRectangle(cornerRadius: DS.radiusControl + 3, style: .continuous).fill(state.fill))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl + 3, style: .continuous)
                .strokeBorder(state.border, lineWidth: state.borderWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isAnswered)
        .keyboardShortcut(i < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: []) : nil)
        .accessibilityLabel("Choice \(i + 1): \(choice)")
        .accessibilityValue(state.accessibilityValue)
    }

    private struct ChoiceState {
        var fill: Color = DS.surface
        var border: Color = DS.separator
        var borderWidth: CGFloat = 1
        var badgeBackground: Color = DS.surfaceInset
        var badgeForeground: Color = DS.fg2
        var icon: String?
        var iconColor: Color = DS.fg2
        var accessibilityValue = ""
    }

    private func choiceState(_ i: Int) -> ChoiceState {
        var s = ChoiceState()
        guard let selected = model.selected else { return s }
        if i == question.answerIndex {
            s.fill = Color.green.opacity(0.12)
            s.border = Color.green.opacity(0.7)
            s.borderWidth = 2
            s.badgeBackground = Color.green
            s.badgeForeground = .white
            s.icon = "checkmark.circle.fill"
            s.iconColor = .green
            s.accessibilityValue = "Correct answer"
        } else if i == selected {
            s.fill = DS.cautionSoft
            s.border = DS.cautionText.opacity(0.5)
            s.badgeBackground = DS.cautionText
            s.badgeForeground = .white
            s.icon = "arrow.uturn.left.circle"
            s.iconColor = DS.cautionText
            s.accessibilityValue = "Your answer"
        } else {
            s.fill = DS.surface.opacity(0.6)
        }
        return s
    }

    @ViewBuilder
    private var playPanel: some View {
        if let kind = model.playedKind {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { await model.toggleListening() }
                } label: {
                    Label(model.isListening ? "Stop listening" : "Answer by playing",
                          systemImage: model.isListening ? "stop.fill" : "mic.fill")
                }
                .buttonStyle(TutorSecondaryButtonStyle(fullWidth: true))
                .keyboardShortcut(.space, modifiers: [])
                if model.isListening {
                    Text("Listening… \(kind.instruction)")
                        .font(.subheadline)
                        .foregroundStyle(DS.fg2)
                    InputLevelMeter(isActive: true) { model.listener.inputLevel }
                }
                if let heard = model.heardText {
                    TutorStatusChip(text: heard, systemImage: "ear", tone: .neutral)
                }
                if model.permissionDenied {
                    HStack {
                        Text("Microphone access is off.").foregroundStyle(DS.fg2)
                        Button("Open Settings") { TutorAudioHelpers.openSettings() }
                    }
                    .font(.subheadline)
                }
            }
            .padding(.top, 6)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.isCorrect ? "Correct" : "The answer is \(question.choices[question.answerIndex])",
                  systemImage: model.isCorrect ? "checkmark.circle.fill" : "info.circle")
                .font(.headline)
                .foregroundStyle(model.isCorrect ? Color.green : DS.fg1)
            Text(question.explanation)
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
