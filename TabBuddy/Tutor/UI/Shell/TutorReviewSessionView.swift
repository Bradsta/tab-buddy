//
//  TutorReviewSessionView.swift
//  TabBuddy
//
//  Full-screen review of due cards. Facts: prompt → reveal → self-grade
//  (Again / Hard / Good / Easy with the next interval). Note and ear cards:
//  multiple choice through QuizQuestionView, auto-graded. Play cards: the
//  microphone listens for each target (wait mode); they can be skipped.
//

import SwiftUI

struct TutorReviewSessionView: View {
    var onDone: () -> Void
    @StateObject private var model: TutorReviewSessionModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(instrument: TutorInstrument, store: TutorStore, library: CurriculumLibrary, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _model = StateObject(wrappedValue: TutorReviewSessionModel(instrument: instrument, store: store, library: library))
    }

    init(model: @autoclosure @escaping () -> TutorReviewSessionModel, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TutorShellProgressBar(value: model.total > 0 ? Double(model.index) / Double(model.total) : 1, height: 4)
                ScrollView {
                    Group {
                        if let card = model.current {
                            cardView(card)
                                .id(card.id)
                        } else {
                            summary
                        }
                    }
                    .padding(sizeClass == .compact ? 20 : 40)
                    .tutorReadableWidth(760)
                }
            }
            .background(DS.paper)
            .navigationTitle(model.isFinished ? "Reviews" : "Review \(min(model.index + 1, model.total)) of \(model.total)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isFinished ? "Done" : "End") {
                        TutorSynth.shared.stop()
                        onDone()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if !model.isFinished {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Skip") { model.skip() }
                            .keyboardShortcut("s", modifiers: .command)
                    }
                }
            }
        }
    }

    // MARK: Card

    @ViewBuilder
    private func cardView(_ card: TutorReviewCard) -> some View {
        let seed = model.seed(for: card)
        VStack(alignment: .leading, spacing: 24) {
            Text(kindLabel(card.kind))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.accentStrong)
            switch model.presentation(for: card) {
            case .fact:
                factCard(card, seed: seed)
            case .choice(let question):
                choiceCard(card, question: question)
            case .play(let targets):
                TutorReviewPlayCard(card: card, seed: seed, targets: targets, instrument: model.instrument,
                                    succeeded: model.autoGrade == .good,
                                    onSuccess: model.playSucceeded,
                                    onCannotPlay: { model.grade(.again) })
                if model.autoGrade != nil { nextButton(card) }
            }
            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(DS.cautionText)
            }
        }
    }

    private func kindLabel(_ kind: ReviewKind) -> String {
        switch kind {
        case .fact: return "Recall"
        case .noteName: return "Name the note"
        case .playNote: return "Play the note"
        case .playChord: return "Play the chord"
        case .earInterval: return "Ear: interval"
        case .earQuality: return "Ear: chord quality"
        }
    }

    @ViewBuilder
    private func factCard(_ card: TutorReviewCard, seed: ReviewItemSeed?) -> some View {
        Text(card.prompt)
            .font(sizeClass == .compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
            .foregroundStyle(DS.fg1)
            .fixedSize(horizontal: false, vertical: true)
        if let diagram = seed?.diagram {
            DiagramView(diagram: diagram, instrument: model.instrument)
                .frame(maxWidth: .infinity)
        }
        if let playback = seed?.playback {
            Button { TutorShellAudio.play(playback, instrument: model.instrument) } label: {
                Label("Hear it", systemImage: "speaker.wave.2")
            }
            .buttonStyle(.bordered)
        }
        if model.revealed {
            VStack(alignment: .leading, spacing: 6) {
                Text("Answer").font(.subheadline.weight(.semibold)).foregroundStyle(DS.fg3)
                Text(card.answer)
                    .font(sizeClass == .compact ? .title3 : .title2)
                    .foregroundStyle(DS.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            Text("How well did you remember it?").font(.headline).foregroundStyle(DS.fg2)
            gradeButtons(card)
        } else {
            Button {
                withAnimation(DS.motionFast) { model.revealed = true }
            } label: {
                Text("Show answer").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
        }
    }

    private func gradeButtons(_ card: TutorReviewCard) -> some View {
        let previews = model.previewIntervals(for: card)
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                ForEach(ReviewGrade.allCases, id: \.self) { grade in
                    Button {
                        model.grade(grade)
                    } label: {
                        VStack(spacing: 2) {
                            Text(grade.title).font(.headline)
                            Text(TutorReviewSessionModel.intervalCaption(previews[grade] ?? 0))
                                .font(.caption.monospacedDigit())
                                .opacity(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                    .tint(grade == .again ? DS.cautionText : DS.accent)
                    .keyboardShortcut(KeyEquivalent(Character(String(grade.rawValue))), modifiers: [])
                    .accessibilityHint("Next review in \(TutorReviewSessionModel.intervalCaption(previews[grade] ?? 0))")
                }
            }
        }
    }

    @ViewBuilder
    private func choiceCard(_ card: TutorReviewCard, question: QuizQuestion) -> some View {
        QuizQuestionView(question: question, instrument: model.instrument) { correct in
            model.answeredChoice(correct: correct)
        }
        if let grade = model.autoGrade {
            let caption = TutorReviewSessionModel.intervalCaption(
                ReviewScheduler.schedule(card.state, grade: grade).due.timeIntervalSinceNow)
            Text(grade == .good ? "Right. You will see this again in \(caption)."
                                : "The answer is \(card.answer). It comes back in \(caption) for another try.")
                .font(.headline)
                .foregroundStyle(grade == .good ? DS.accentStrong : DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            nextButton(card)
        }
    }

    private func nextButton(_ card: TutorReviewCard) -> some View {
        Button {
            TutorSynth.shared.stop()
            model.next()
        } label: {
            Text(model.index + 1 >= model.total ? "Finish" : "Next card")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: Summary

    private var summary: some View {
        let s = model.summary
        return VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(DS.accent)
            Text(model.total == 0 ? "Nothing to review" : "Reviews done")
                .font(.largeTitle.weight(.bold))
            Text(summaryText(s))
                .font(.title3)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onDone()
            } label: {
                Text("Back to the path").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func summaryText(_ s: (reviewed: Int, again: Int, skipped: Int)) -> String {
        guard model.total > 0 else { return "Cards appear a day after you finish a lesson." }
        var parts = ["You reviewed \(s.reviewed) \(s.reviewed == 1 ? "card" : "cards")."]
        if s.again > 0 { parts.append("\(s.again) will come back in a few minutes for another look.") }
        if s.skipped > 0 { parts.append("\(s.skipped) skipped \(s.skipped == 1 ? "card stays" : "cards stay") due.") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Mic-graded card

private struct TutorReviewPlayCard: View {
    let card: TutorReviewCard
    let seed: ReviewItemSeed?
    let targets: [TutorPlayTarget]
    let instrument: TutorInstrument
    let succeeded: Bool
    var onSuccess: () -> Void
    var onCannotPlay: () -> Void

    @StateObject private var listener = TutorListener(latencyStore: TutorShellLatency.store())
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var targetIndex = 0
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(card.prompt)
                .font(sizeClass == .compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            if let diagram = seed?.diagram {
                DiagramView(diagram: diagram, instrument: instrument,
                            highlightedMIDI: Set(targets.indices.contains(targetIndex) ? targets[targetIndex].event.pitches : []))
                    .frame(maxWidth: .infinity)
            }
            if targets.count > 1 {
                HStack(spacing: 8) {
                    ForEach(Array(targets.enumerated()), id: \.offset) { i, t in
                        TutorShellChip(text: t.label, systemImage: i < targetIndex || succeeded ? "checkmark" : nil,
                                       fill: i == targetIndex && !succeeded ? DS.accentSoft : DS.accentSofter)
                    }
                }
            }
            if listener.permissionDenied {
                MicrophoneOffPanel(onSkip: nil)
            }
            if succeeded {
                Label("Heard it. Nicely played.", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DS.accentStrong)
            } else {
                HStack(spacing: 12) {
                    Button {
                        if listener.isListening { listener.stop() }
                        TutorShellAudio.play(pitches: targets[min(targetIndex, targets.count - 1)].event.pitches,
                                             instrument: instrument)
                    } label: {
                        Label("Hear it", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Button {
                        listener.isListening ? stop() : start()
                    } label: {
                        Label(listener.isListening ? "Stop listening" : "Start listening",
                              systemImage: listener.isListening ? "stop.fill" : "mic.fill")
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
                if listener.isListening {
                    HStack(spacing: 10) {
                        InputLevelMeter(isActive: listener.isListening, level: { listener.inputLevel })
                            .frame(maxWidth: 240)
                        Text("Listening for \(targets[min(targetIndex, targets.count - 1)].label)…")
                            .foregroundStyle(DS.fg2)
                    }
                }
                if let status { Text(status).foregroundStyle(DS.fg1) }
                if let error { Text(error).foregroundStyle(DS.cautionText) }
                Button("I can’t play it yet") {
                    stop()
                    onCannotPlay()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DS.fg2)
            }
        }
        .onDisappear { stop() }
        .onReceive(listener.$stoppedUnexpectedly) { stopped in
            if stopped, !succeeded { status = TutorListeningCopy.stoppedUnexpectedly }
        }
    }

    private func start() {
        error = nil
        status = nil
        TutorSynth.shared.stop()
        listener.onVerification = { result in handle(result) }
        Task {
            do {
                try await listener.start(profile: .preset(for: instrument), recordTake: false)
                // Stopped (Hear it, skip, view gone) while the microphone started.
                guard listener.isListening else { return }
                arm()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func arm() {
        guard targets.indices.contains(targetIndex) else { return }
        listener.armWait(targets[targetIndex].event)
    }

    private func handle(_ result: VerificationResult) {
        guard targets.indices.contains(targetIndex), result.expectedID == targets[targetIndex].event.id else { return }
        switch result.grade {
        case .hit:
            targetIndex += 1
            if targetIndex >= targets.count {
                stop()
                onSuccess()
            } else {
                status = "Good. Now \(targets[targetIndex].label)."
                arm()
            }
        case .partial:
            status = "Close: some notes were missing. Try again."
            arm()
        case .wrongPitch:
            let heard = result.unexpected.map { Pitch(midi: $0).name }.joined(separator: ", ")
            status = heard.isEmpty ? "That was a different note. Try again." : "Heard \(heard). Try again."
            arm()
        case .missed, .uncertain:
            arm()
        }
    }

    private func stop() {
        listener.stop()     // also cancels a start still in progress
        listener.onVerification = nil
    }
}
