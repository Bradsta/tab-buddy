//
//  LessonPlayerView.swift
//  TabBuddy
//
//  Step pager for one lesson: progress bar (tap a finished segment to go
//  back), one renderer per step type, Back/Continue, and the completion
//  screen that records progress and seeds review cards.
//
//  Hardware keyboard: ← / → step navigation, Return continues (quizzes use it
//  for the next question), Space starts/stops listening, 1–4 answer quizzes,
//  Escape closes.
//

import SwiftUI

struct LessonPlayerView: View {
    let lesson: Lesson
    let instrument: TutorInstrument
    /// Called when the learner leaves; `completed` is true after the final step passes.
    var onExit: (_ completed: Bool) -> Void

    @StateObject private var model: LessonPlayerModel
    @State private var sessionSalt = UInt64.random(in: 0...UInt64(UInt32.max))
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if DEBUG
    @Environment(\.tutorDebugStartStep) private var debugStartStep
    #endif

    init(lesson: Lesson, instrument: TutorInstrument, onExit: @escaping (_ completed: Bool) -> Void) {
        self.lesson = lesson
        self.instrument = instrument
        self.onExit = onExit
        _model = StateObject(wrappedValue: LessonPlayerModel(lesson: lesson, instrument: instrument))
    }

    private var compact: Bool { sizeClass == .compact }
    private var gutter: CGFloat { compact ? 16 : 32 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if model.isShowingCompletion {
                            LessonCompletionView(model: model, onDone: { onExit(true) }, onReview: { model.back() })
                        } else if let step = model.currentStep {
                            stepView(step, index: model.index)
                                .id(model.index)
                        }
                    }
                    .frame(maxWidth: 1180, alignment: .leading)
                    .padding(.horizontal, gutter)
                    .padding(.vertical, compact ? 20 : 32)
                    .frame(maxWidth: .infinity)
                    .id("top-\(model.index)-\(model.isShowingCompletion)")
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.index) { _, new in proxy.scrollTo("top-\(new)-false", anchor: .top) }
            }
            if !model.isShowingCompletion {
                Hairline()
                bottomBar
            }
        }
        .background(DS.paper.ignoresSafeArea())
        .background(shortcuts)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            #if DEBUG
            if let debugStartStep { model.jump(to: debugStartStep) }
            #endif
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func stepView(_ step: LessonStep, index: Int) -> some View {
        switch step {
        case .explain(let s):
            ExplainStepView(step: s, instrument: instrument)
        case .demo(let s):
            DemoStepView(step: s, instrument: instrument)
        case .practice(let s):
            PracticeStepView(step: s, instrument: instrument, intervals: intervals,
                             seed: TutorAudioHelpers.seed("\(lesson.id)#\(index)", salt: sessionSalt),
                             stage: ExerciseGenerator.stage(ofLessonID: lesson.id)) { outcome in
                model.record(outcome, forStep: index)
            }
        case .quiz(let s):
            QuizStepView(step: s, instrument: instrument,
                         seed: TutorAudioHelpers.seed("\(lesson.id)#\(index)", salt: sessionSalt)) { outcome in
                model.record(outcome, forStep: index)
            }
        case .song(let s):
            SongStepView(step: s, instrument: instrument) { outcome in
                model.record(outcome, forStep: index)
            }
        }
    }

    /// Intervals taught so far (for interval play-back exercises).
    private var intervals: [Interval]? {
        if let course = CurriculumLibrary.shared.course(for: instrument),
           let taught = ExerciseGenerator.intervalsTaught(through: lesson.id, in: course) {
            return taught
        }
        return ExerciseGenerator.intervals(forLesson: lesson)
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    onExit(model.didSave)
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(DS.fg2)
                        .frame(width: DS.tile, height: DS.tile)
                        .background(Circle().fill(DS.surfaceInset))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close lesson")

                VStack(alignment: .leading, spacing: 2) {
                    Text(lesson.title)
                        .font(.headline)
                        .foregroundStyle(DS.fg1)
                        .lineLimit(1)
                    Text(stepCaption)
                        .font(.caption)
                        .foregroundStyle(DS.fg2)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !compact {
                    Text("\(lesson.minutes) min")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DS.fg3)
                }
            }
            progressBar
        }
        .padding(.horizontal, gutter)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(BarMaterial())
    }

    private var stepCaption: String {
        if model.isShowingCompletion { return "Complete" }
        guard let step = model.currentStep else { return "" }
        return "Step \(model.index + 1) of \(model.stepCount) · \(LessonPlayerModel.kindName(for: step))"
    }

    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.steps.enumerated()), id: \.offset) { i, step in
                Button {
                    model.go(to: i)
                } label: {
                    Capsule()
                        .fill(segmentColor(i))
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(i > model.furthestReachable)
                .accessibilityLabel("Step \(i + 1): \(LessonPlayerModel.kindName(for: step))")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lesson progress")
        .accessibilityValue("\(Int(model.progress * 100)) percent")
    }

    private func segmentColor(_ i: Int) -> Color {
        if model.isShowingCompletion || i < model.index { return DS.accent }
        if i == model.index { return DS.accentStrong }
        return DS.separatorStrong.opacity(0.6)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                model.back()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(TutorSecondaryButtonStyle())
            .disabled(model.isFirst)
            .accessibilityHint("Left arrow")

            Spacer(minLength: 8)
            if !model.canAdvance && !compact {
                Text(blockedHint)
                    .font(.subheadline)
                    .foregroundStyle(DS.fg3)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            Button {
                model.advance()
            } label: {
                Label(model.isLast ? "Finish" : "Continue", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(TutorPrimaryButtonStyle())
            .frame(maxWidth: compact ? 170 : 240)
            .disabled(!model.canAdvance)
            .accessibilityHint("Right arrow or Return")
        }
        .padding(.horizontal, gutter)
        .padding(.vertical, 12)
        .background(BarMaterial())
    }

    private var blockedHint: String {
        guard let step = model.currentStep else { return "" }
        switch step {
        case .quiz: return "Answer the questions to continue"
        case .practice, .song: return compact ? "Play or skip to continue" : "Finish a run, or skip, to continue"
        default: return ""
        }
    }

    /// Keyboard shortcuts without visible buttons.
    private var shortcuts: some View {
        ZStack {
            KeyboardShortcutButton(key: .leftArrow) { model.back() }
            KeyboardShortcutButton(key: .rightArrow) { model.advance() }
            if model.returnContinues && !model.isShowingCompletion {
                KeyboardShortcutButton(key: .return) { model.advance() }
            }
            if model.isShowingCompletion {
                KeyboardShortcutButton(key: .return) { onExit(true) }
            }
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - Completion

struct LessonCompletionView: View {
    @ObservedObject var model: LessonPlayerModel
    var store: TutorStore? = nil
    var onDone: () -> Void
    var onReview: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(DS.accent)
                .padding(.top, 20)
            Text("Lesson complete")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(DS.fg1)
            Text(model.lesson.title)
                .font(.title3)
                .foregroundStyle(DS.fg2)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                stat(value: "\(Int((model.score * 100).rounded()))%", label: "Score")
                stat(value: "\(model.scoredOutcomes.count)", label: "Graded steps")
                stat(value: "\(model.lesson.reviewItems.count)", label: "Review cards")
            }
            .frame(maxWidth: 560)

            VStack(alignment: .leading, spacing: 10) {
                if let weakest = model.weakestSummary {
                    TutorMessageRow(text: weakest, systemImage: "target", tone: .accent)
                } else if !model.scoredOutcomes.isEmpty {
                    TutorMessageRow(text: "Every graded step was clean.", systemImage: "sparkles", tone: .good)
                }
                if model.skippedCount > 0 {
                    TutorMessageRow(text: "You skipped \(model.skippedCount) playing \(model.skippedCount == 1 ? "exercise" : "exercises"). Come back with your instrument to try \(model.skippedCount == 1 ? "it" : "them").",
                                    systemImage: "mic.slash", tone: .neutral)
                }
                if !model.lesson.reviewItems.isEmpty {
                    TutorMessageRow(text: "\(model.lesson.reviewItems.count) review \(model.lesson.reviewItems.count == 1 ? "card is" : "cards are") scheduled for tomorrow.",
                                    systemImage: "calendar", tone: .neutral)
                }
                if let error = model.saveError {
                    TutorMessageRow(text: error, systemImage: "exclamationmark.triangle", tone: .caution)
                }
            }
            .frame(maxWidth: 560)

            HStack(spacing: 12) {
                Button("Review steps", action: onReview)
                    .buttonStyle(TutorSecondaryButtonStyle())
                Button("Done", action: onDone)
                    .buttonStyle(TutorPrimaryButtonStyle())
                    .frame(maxWidth: 240)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { model.complete(store: store ?? TutorStore.shared) }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(DS.fg1)
            Text(label).font(.subheadline).foregroundStyle(DS.fg2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
        .accessibilityElement(children: .combine)
    }
}
