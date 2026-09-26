//
//  PracticeStepView.swift
//  TabBuddy
//
//  Mic-graded exercise. Wide screens: a large stage (diagram, passage, count-in,
//  beat pulse, targets) with a side panel of controls; compact screens stack
//  them. Space starts/stops listening. The microphone-off state explains how
//  to turn it on and offers "Skip for now" so the lesson stays usable.
//

import SwiftUI

struct PracticeStepView: View {
    let step: PracticeStep
    let instrument: TutorInstrument
    var onOutcome: (StepOutcome) -> Void

    @StateObject private var model: PracticeRunModel

    init(step: PracticeStep, instrument: TutorInstrument, intervals: [Interval]? = nil, seed: UInt64 = 1,
         stage: Int? = nil, onOutcome: @escaping (StepOutcome) -> Void) {
        self.step = step
        self.instrument = instrument
        self.onOutcome = onOutcome
        _model = StateObject(wrappedValue: PracticeRunModel(step: step, instrument: instrument, intervals: intervals,
                                                            seed: seed, stage: stage, listener: TutorListener(),
                                                            player: TutorSequencePlayer.shared))
    }

    var body: some View {
        PracticeRunPanel(model: model, title: Self.title(for: step.exercise.kind), onSkip: {
            model.cancel()
            onOutcome(.skipped(label: step.exercise.prompt))
        })
        .onAppear {
            let run = model
            let label = step.exercise.prompt
            let report = onOutcome
            run.onRunFinished = { [weak run] result in
                guard let run, !result.unsure else { return }
                report(StepOutcome(score: run.bestAccuracy ?? result.accuracy, passed: run.hasPassed,
                                   weakest: run.weakestItem, label: label))
            }
        }
    }

    static func title(for kind: ExerciseKind) -> String {
        switch kind {
        case .playNote: return "Play the notes"
        case .findAllNotes: return "Fretboard hunt"
        case .playSequence: return "Play the sequence"
        case .playChord: return "Play the chords"
        case .chordChanges: return "Chord changes"
        case .strumRhythm: return "Strum the rhythm"
        case .scale: return "Play the scale"
        case .intervalPlayback: return "Hear it, play it back"
        case .melodyEcho: return "Echo the phrase"
        case .improvise: return "Improvise"
        }
    }
}

/// Stage + controls for a `PracticeRunModel` (shared by practice and song steps).
struct PracticeRunPanel: View {
    @ObservedObject var model: PracticeRunModel
    var title: String
    var showsPrompt = true
    /// Group the passage into measures even in wait mode (songs).
    var alwaysShowMeasures = false
    var onSkip: (() -> Void)?

    var body: some View {
        WidthReader { width in
            Group {
                if TutorLayout.isWide(width) {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 20) {
                            if showsPrompt { promptHeader(large: true) }
                            stage
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        controls
                            .frame(width: TutorLayout.sidePanelWidth)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        if showsPrompt { promptHeader(large: false) }
                        stage
                        controls
                    }
                }
            }
        }
        .environment(\.tutorDiagramTapEnabled, !model.phase.isActive)
        .onDisappear { model.cancel() }
    }

    // MARK: Prompt

    private func promptHeader(large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(DS.accentStrong)
                if model.roundCount > 1 {
                    Text("Round \(model.roundIndex + 1) of \(model.roundCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.fg3)
                }
            }
            Text(model.prompt)
                .font(large ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        if let error = model.generationError {
            TutorMessageRow(text: "This exercise could not be prepared (\(error)). You can skip it.",
                            systemImage: "exclamationmark.circle", tone: .neutral)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                if case .countIn(let beat, let of) = model.phase {
                    countIn(beat: beat, of: of)
                }
                switch model.pacing {
                case .anyOrder: targetsStage
                case .countChanges: changesStage
                case .free: freeStage
                case .wait, .timed: sequenceStage
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
        }
    }

    private func countIn(beat: Int, of total: Int) -> some View {
        HStack(spacing: 20) {
            Text("\(max(1, beat))")
                .font(.system(size: 84, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DS.accent)
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 8) {
                Text("Get ready…").font(.title3.weight(.semibold)).foregroundStyle(DS.fg1)
                BeatPulseView(beat: beat - 1, beatsPerMeasure: total, active: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Count-in \(beat) of \(total)")
    }

    /// Diagram for what to play now.
    private var stageDiagram: Diagram? {
        let event = model.currentEvent ?? model.events.first
        if let fixed = model.fixedDiagram {
            // A chord diagram for a different chord than the current target gives way to the target's.
            let mismatch = fixed.chord != nil && event?.chordName != nil && fixed.chord != event?.chordName
            if !mismatch { return fixed }
        }
        guard let event else { return nil }
        return Diagram.forEvent(pitches: event.pitches, fretting: event.fretting, chordName: event.chordName,
                                instrument: model.instrument)
    }

    private var stageHighlight: Set<Int> {
        if let step = model.playbackStep, let seq = model.round?.reference ?? model.demoSequence,
           seq.notes.indices.contains(step) {
            return Set(seq.notes[step].pitches)
        }
        if model.phase == .listening, let event = model.currentEvent { return Set(event.pitches) }
        return []
    }

    @ViewBuilder
    private var sequenceStage: some View {
        if model.pacing == .timed, model.phase == .listening || isCountIn {
            BeatPulseView(beat: model.pulseBeat, beatsPerMeasure: model.passage?.beatsPerMeasure ?? 4,
                          active: model.phase == .listening)
                .frame(maxWidth: .infinity)
        }
        if let diagram = stageDiagram, !(model.hasReference && model.phase != .finished && model.fixedDiagram == nil) {
            DiagramView(diagram: diagram, instrument: model.instrument, highlightedMIDI: stageHighlight)
        }
        if model.hasReference && model.phase != .finished {
            referenceStage
        } else if !model.events.isEmpty {
            PassageStripView(events: model.events, marks: model.marks,
                             cursor: model.phase == .listening ? model.cursor : nil,
                             playing: model.isPlayingDemo ? model.playbackStep : nil,
                             showMeasures: alwaysShowMeasures || model.pacing == .timed, large: true)
        }
    }

    private var isCountIn: Bool {
        if case .countIn = model.phase { return true }
        return false
    }

    /// Echo rounds: the answer stays hidden; show progress as dots.
    private var referenceStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.phase == .playingReference ? "ear.fill" : "music.note")
                    .font(.title)
                    .foregroundStyle(DS.accent)
                Text(model.phase == .playingReference ? "Listen…" : (model.phase == .listening ? "Your turn" : "Press Start to hear the first one"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DS.fg1)
            }
            HStack(spacing: 10) {
                ForEach(Array(model.events.enumerated()), id: \.offset) { i, event in
                    let mark = model.marks[event.id] ?? .pending
                    let style = PassageStripView.style(for: mark)
                    ZStack {
                        Circle().fill(mark == .pending ? DS.surfaceInset : style.background)
                        if let icon = style.icon { Image(systemName: icon).foregroundStyle(style.foreground) }
                    }
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(i == model.cursor && model.phase == .listening ? DS.accent : .clear, lineWidth: 3))
                }
            }
            if let label = model.round?.label, model.phase == .finished || model.marks.values.contains(.hit) && model.cursor >= model.events.count {
                Text(label.prefix(1).uppercased() + label.dropFirst()).foregroundStyle(DS.fg2)
            }
        }
    }

    private var targetsStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            timerRow
            if let fixed = model.fixedDiagram {
                DiagramView(diagram: fixed, instrument: model.instrument)
            }
            FlowLayout(spacing: 10, lineSpacing: 10) {
                ForEach(model.targetPitches, id: \.self) { p in
                    let found = model.found.contains(p)
                    HStack(spacing: 6) {
                        Image(systemName: found ? "checkmark.circle.fill" : "circle.dashed")
                        Text(NoteNaming.displayName(midi: p)).font(.title3.weight(.semibold))
                    }
                    .foregroundStyle(found ? Color.green : DS.fg2)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(found ? Color.green.opacity(0.14) : DS.surfaceInset))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Found \(model.found.count) of \(model.targetPitches.count)")
        }
    }

    private var changesStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            timerRow
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now").font(.caption.weight(.bold)).foregroundStyle(DS.fg3)
                    Text(model.currentEvent?.chordName ?? "–")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.accentStrong)
                }
                if model.events.indices.contains(model.cursor + 1) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next").font(.caption.weight(.bold)).foregroundStyle(DS.fg3)
                        Text(model.events[model.cursor + 1].chordName ?? "")
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.fg2)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Clean").font(.caption.weight(.bold)).foregroundStyle(DS.fg3)
                    Text("\(model.cleanChords)")
                        .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(DS.fg1)
                        .contentTransition(.numericText())
                }
            }
            if let diagram = stageDiagram {
                DiagramView(diagram: diagram, instrument: model.instrument)
            }
        }
    }

    private var freeStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            timerRow
            if let fixed = model.fixedDiagram {
                DiagramView(diagram: fixed, instrument: model.instrument)
            } else if let scale = model.exercise?.scale {
                DiagramView(diagram: Diagram(kind: model.instrument == .guitar ? .fretboard : .keyboard,
                                             scale: scale.name, labels: .noteNames,
                                             fretRange: model.instrument == .guitar ? [0, 5] : nil,
                                             pitchRange: model.instrument == .piano ? ["C4", "C5"] : nil),
                            instrument: model.instrument)
            }
            Text("\(model.freeNoteCount) notes heard")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(DS.fg2)
        }
    }

    @ViewBuilder
    private var timerRow: some View {
        let total = model.durationSec
        let left = model.remaining ?? total
        HStack(spacing: 12) {
            Image(systemName: "timer").foregroundStyle(DS.fg2)
            ProgressView(value: max(0, min(1, (total - left) / max(1, total))))
                .tint(DS.accent)
            Text(minimalTime(left))
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(DS.fg1)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(left)) seconds left")
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.phase == .permissionDenied {
                MicrophoneOffPanel(onSkip: onSkip)
            } else if case .unavailable(let message) = model.phase {
                TutorMessageRow(text: message, systemImage: "mic.slash", tone: .neutral)
            }

            statusRow
            InputLevelMeter(isActive: model.phase == .listening || isCountIn) { model.listener.inputLevel }

            Button {
                if model.phase.isActive { model.stopRun() } else { Task { await model.start() } }
            } label: {
                Label(primaryTitle, systemImage: model.phase.isActive ? "stop.fill" : "mic.fill")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(TutorPrimaryButtonStyle(tint: model.phase.isActive ? DS.fg2 : DS.accent))
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.exercise == nil)
            .accessibilityHint("Space bar starts and stops listening.")

            secondaryButtons

            if model.tempoSteps.count > 1 || model.pacing == .timed {
                tempoRow
            }

            if let feedback = model.feedback, model.phase.isActive {
                TutorMessageRow(text: feedback.text, systemImage: feedback.systemImage, tone: feedback.tone)
            }

            if let result = model.lastResult, model.phase == .finished {
                resultCard(result)
            }

            if let coach = model.coachMessage {
                coachRow(coach)
            }

            if let onSkip, model.phase != .permissionDenied, !model.hasPassed {
                Button("Skip this exercise", action: onSkip)
                    .font(.subheadline)
                    .foregroundStyle(DS.fg3)
                    .padding(.top, 4)
            }
        }
    }

    private var primaryTitle: String {
        switch model.phase {
        case .starting: return "Starting…"
        case .playingReference: return "Stop"
        case .countIn, .listening: return "Stop"
        case .finished: return model.hasPassed ? "Go again" : "Try again"
        default: return "Start"
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .listening:
                TutorStatusChip(text: "Listening…", systemImage: "waveform", tone: .accent)
            case .countIn:
                TutorStatusChip(text: "Count-in", systemImage: "metronome", tone: .accent)
            case .playingReference:
                TutorStatusChip(text: "Playing, microphone paused", systemImage: "speaker.wave.2", tone: .neutral)
            case .starting:
                TutorStatusChip(text: "Starting the microphone…", systemImage: "mic", tone: .neutral)
            case .finished:
                TutorStatusChip(text: "Run finished", systemImage: "flag.checkered", tone: .neutral)
            default:
                TutorStatusChip(text: "Not listening", systemImage: "mic", tone: .neutral)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        HStack(spacing: 10) {
            if model.hasReference && (model.phase == .listening) {
                Button { model.replayReference() } label: { Label("Hear again", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(TutorSecondaryButtonStyle())
            }
            if model.pacing == .wait && model.phase == .listening && !model.hasReference {
                Button { model.skipCurrentEvent() } label: { Label("Skip note", systemImage: "forward") }
                    .buttonStyle(TutorSecondaryButtonStyle())
                    .keyboardShortcut("s", modifiers: [])
            }
            if !model.phase.isActive && (model.pacing == .wait || model.pacing == .timed) && !model.hasReference
                && model.demoSequence != nil {
                Button { model.playDemo() } label: {
                    Label(model.isPlayingDemo ? "Stop" : "Hear it first", systemImage: model.isPlayingDemo ? "stop.fill" : "play.fill")
                }
                .buttonStyle(TutorSecondaryButtonStyle())
            }
        }
    }

    private var tempoRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "metronome").foregroundStyle(DS.fg2)
            Text("\(Int(model.bpm.rounded())) BPM")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(DS.accentStrong)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(DS.accentSoft))
            if model.tempoSteps.count > 1 {
                Text("Steps: " + model.tempoSteps.map { String(Int($0)) }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(DS.fg3)
            }
        }
    }

    private func resultCard(_ result: PracticeRunModel.RunResult) -> some View {
        let tone: TutorTone = result.unsure ? .neutral : (result.passed ? .good : .caution)
        let headline: String
        if result.unsure { headline = "Not sure" }
        else if result.passed { headline = "Passed · \(Int((result.accuracy * 100).rounded()))%" }
        else { headline = "Not yet · \(Int((result.accuracy * 100).rounded()))% (goal \(Int((model.passAccuracy * 100).rounded()))%)" }
        return VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: result.unsure ? "questionmark.circle" : (result.passed ? "checkmark.seal.fill" : "arrow.clockwise"))
                .font(.headline)
                .foregroundStyle(tone.foreground)
            Text(result.summary).foregroundStyle(DS.fg1)
            if let detail = result.detail {
                Text(detail).font(.subheadline).foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.unsure {
                Text("The microphone didn't pick up enough. Move closer or play a little louder, then try again.")
                    .font(.subheadline).foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func coachRow(_ message: CoachMessage) -> some View {
        switch message {
        case .offerTempo(let bpm):
            VStack(alignment: .leading, spacing: 10) {
                TutorMessageRow(text: message.text, systemImage: "speedometer", tone: .accent)
                HStack {
                    Button("Try \(Int(bpm)) BPM") { model.acceptTempo() }
                        .buttonStyle(TutorSecondaryButtonStyle())
                    Button("Stay at \(Int(model.bpm))") { model.declineTempo() }
                        .foregroundStyle(DS.fg2)
                }
            }
        case .tip:
            TutorMessageRow(text: message.text, systemImage: "lightbulb", tone: .accent)
        case .weakest, .allClean:
            TutorMessageRow(text: message.text, systemImage: "target", tone: .neutral)
        }
    }
}

extension PracticeRunModel {
    var tempoSteps: [Double] { exercise?.tempoSteps ?? [] }
}
