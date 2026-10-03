//
//  TryItCardView.swift
//  TabBuddy
//
//  The "Try it" box of a chapter (and the body of quick-practice cards):
//  prompt, diagram, passage strip, Play example with loop and tempo, and a
//  Listen switch that only turns heard notes green. Wide screens put the
//  stage beside a control panel; compact screens stack them. Space toggles
//  Play, L toggles Listen.
//

import SwiftUI

struct TryItCardView: View {
    @ObservedObject var model: TryItModel
    var showsPrompt = true
    /// Group the passage into measures even in wait mode (songs).
    var alwaysShowMeasures = false

    var body: some View {
        WidthReader { width in
            Group {
                if TutorLayout.isWide(width) {
                    HStack(alignment: .top, spacing: 24) {
                        stage.frame(maxWidth: .infinity, alignment: .leading)
                        controls.frame(width: TutorLayout.sidePanelWidth)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        stage
                        controls
                    }
                }
            }
        }
        .environment(\.tutorDiagramTapEnabled, !model.isListening)
        .onDisappear { model.cancel() }
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        if let error = model.generationError {
            TutorMessageRow(text: "This exercise could not be prepared (\(error)).", systemImage: "exclamationmark.circle",
                            tone: .neutral)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if showsPrompt {
                    Text(model.prompt)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(DS.fg1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.roundCount > 1 { phrasePicker }
                if let countIn = model.countIn { countInView(countIn) }
                if model.listenMode == .playAlong, model.isListening, model.countIn == nil {
                    BeatPulseView(beat: Int(floor(model.currentBeat)), beatsPerMeasure: model.passage?.beatsPerMeasure ?? 4,
                                  active: true)
                }
                if let diagram = model.diagram, !(model.hasReference && !revealed) {
                    DiagramView(diagram: diagram, instrument: model.instrument, highlightedMIDI: model.highlightedMIDI)
                }
                switch model.pacing {
                case .anyOrder: targets
                case .free: freeStage
                case .wait, .timed, .countChanges:
                    if model.hasReference { referenceStage } else { strip }
                }
                if let status = model.statusText {
                    TutorStatusChip(text: status, systemImage: model.statusTone == .good ? "checkmark.circle.fill" : "ear",
                                    tone: model.statusTone)
                }
            }
        }
    }

    @State private var revealed = false

    private var phrasePicker: some View {
        HStack(spacing: 10) {
            Button { model.selectRound(model.roundIndex - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.bordered)
                .disabled(model.roundIndex == 0)
                .accessibilityLabel("Previous phrase")
            Text("Phrase \(model.roundIndex + 1) of \(model.roundCount)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(DS.fg2)
            Button { model.selectRound(model.roundIndex + 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.bordered)
                .disabled(model.roundIndex + 1 >= model.roundCount)
                .accessibilityLabel("Next phrase")
        }
        .onChange(of: model.roundIndex) { _, _ in revealed = false }
    }

    private func countInView(_ countIn: (beat: Int, of: Int)) -> some View {
        HStack(spacing: 20) {
            Text("\(max(1, countIn.beat))")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DS.accent)
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 8) {
                Text("Get ready…").font(.title3.weight(.semibold)).foregroundStyle(DS.fg1)
                BeatPulseView(beat: countIn.beat - 1, beatsPerMeasure: countIn.of, active: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Count-in \(countIn.beat) of \(countIn.of)")
    }

    private var strip: some View {
        PassageStripView(events: model.events, heard: model.heard,
                         cursor: model.isListening ? model.cursor : nil,
                         playing: model.playingEventIndex,
                         showMeasures: alwaysShowMeasures || model.pacing == .timed, large: true)
    }

    /// Echo phrases: the answer stays hidden until revealed.
    private var referenceStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.isPlaying ? "Listen…" : "Play the example, then play it back.", systemImage: model.isPlaying ? "ear.fill" : "music.note")
                .font(.headline)
                .foregroundStyle(DS.fg1)
            HStack(spacing: 10) {
                ForEach(Array(model.events.enumerated()), id: \.offset) { i, event in
                    let heard = model.heard.contains(event.id)
                    ZStack {
                        Circle().fill(heard ? Color.green.opacity(0.14) : DS.surfaceInset)
                        if heard { Image(systemName: "checkmark").foregroundStyle(Color.green) }
                    }
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(i == model.cursor && model.isListening ? DS.accent : .clear, lineWidth: 3))
                }
                Spacer(minLength: 0)
                Button(revealed ? "Hide answer" : "Show answer") { withAnimation(DS.motionFast) { revealed.toggle() } }
                    .buttonStyle(.bordered)
            }
            if revealed {
                if let label = model.round?.label {
                    Text(label.prefix(1).uppercased() + label.dropFirst()).font(.headline).foregroundStyle(DS.accentStrong)
                }
                strip
            }
        }
    }

    private var targets: some View {
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

    private var freeStage: some View {
        Text(model.scale.map { "Play freely using \($0.displayName). Heard notes in the scale show green." }
             ?? "Play freely.")
            .font(.subheadline)
            .foregroundStyle(DS.fg2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                model.togglePlayback()
            } label: {
                Label(model.isPlaying ? "Stop" : "Play example", systemImage: model.isPlaying ? "stop.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(TutorPrimaryButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.exampleSequence == nil)

            Toggle(isOn: $model.loop) { Label("Loop", systemImage: "repeat") }
                .toggleStyle(.switch)
                .tint(DS.accent)

            tempoRow

            if model.supportsListening {
                Hairline()
                listenControls
            }

            if model.soundUnavailable {
                TutorMessageRow(text: "Sound is unavailable right now. Check that the microphone is not listening and the volume is up.",
                                systemImage: "speaker.slash", tone: .neutral)
            }

            if !model.tips.isEmpty { tipsDisclosure }
        }
    }

    private var tempoRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "metronome").foregroundStyle(DS.fg2)
                Button { model.nudgeTempo(-4) } label: { Image(systemName: "minus") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Slower")
                Slider(value: Binding(get: { model.bpm }, set: { model.setTempo($0) }),
                       in: TryItModel.tempoRange, step: 1)
                    .tint(DS.accent)
                    .accessibilityLabel("Tempo")
                Button { model.nudgeTempo(4) } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Faster")
                Text("\(Int(model.bpm.rounded()))")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(DS.accentStrong)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            if model.tempoSteps.count > 1 {
                HStack(spacing: 6) {
                    ForEach(model.tempoSteps, id: \.self) { step in
                        Button("\(Int(step))") { model.setTempo(step) }
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .buttonStyle(.bordered)
                            .tint(abs(step - model.bpm) < 0.5 ? DS.accent : DS.fg3)
                    }
                    Text("BPM").font(.caption).foregroundStyle(DS.fg3)
                }
            }
        }
    }

    @ViewBuilder
    private var listenControls: some View {
        Toggle(isOn: Binding(get: { model.isListening }, set: { _ in Task { await model.toggleListening() } })) {
            Label("Listen", systemImage: "mic")
        }
        .toggleStyle(.switch)
        .tint(DS.accent)
        .keyboardShortcut("l", modifiers: [])
        .disabled(model.listenState == .starting)
        Text("Heard notes turn green. Nothing is scored. The app is silent while it listens.")
            .font(.caption)
            .foregroundStyle(DS.fg3)
            .fixedSize(horizontal: false, vertical: true)

        if model.supportsPlayAlong {
            Picker("Mode", selection: Binding(get: { model.listenMode }, set: { model.setListenMode($0) })) {
                ForEach(TryItModel.ListenMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }

        if model.isListening {
            InputLevelMeter(isActive: true) { model.listener.inputLevel }
            HStack(spacing: 10) {
                if model.listenMode == .wait, model.pacing != .anyOrder, model.pacing != .free {
                    Button { model.skipCurrent() } label: { Label("Next", systemImage: "forward") }
                        .buttonStyle(TutorSecondaryButtonStyle())
                        .keyboardShortcut("n", modifiers: [])
                }
                if !model.heard.isEmpty || !model.found.isEmpty {
                    Button { model.resetMarks() } label: { Label("Clear", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(TutorSecondaryButtonStyle())
                }
            }
        }

        switch model.listenState {
        case .permissionDenied:
            MicrophoneOffPanel(onSkip: nil)
        case .unavailable(let message):
            TutorMessageRow(text: message, systemImage: "mic.slash", tone: .neutral)
        default:
            EmptyView()
        }
    }

    @State private var tipsOpen = false

    private var tipsDisclosure: some View {
        DisclosureGroup(isExpanded: $tipsOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.tips.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "lightbulb").foregroundStyle(DS.accent).font(.subheadline)
                        Text(tip).font(.subheadline).foregroundStyle(DS.fg1).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Tips", systemImage: "lightbulb")
                .font(.headline)
                .foregroundStyle(DS.fg1)
        }
        .tint(DS.accentStrong)
    }
}
