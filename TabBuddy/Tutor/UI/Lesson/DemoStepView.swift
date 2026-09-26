//
//  DemoStepView.swift
//  TabBuddy
//
//  Listen steps: the synth plays `ExerciseGenerator.playback(for:)` and the
//  diagram lights up the sounding notes in sync. `DemoPlaybackModel` is also
//  used by explain steps' "Hear it" button.
//

import SwiftUI

@MainActor
final class DemoPlaybackModel: ObservableObject {
    let sequence: PlaybackSequence?
    let error: String?
    let instrument: TutorInstrument
    private let player: TutorSequencePlaying

    @Published private(set) var isPlaying = false
    @Published private(set) var currentIndex: Int?
    @Published private(set) var didPlay = false
    @Published private(set) var soundUnavailable = false

    init(spec: PlaybackSpec?, instrument: TutorInstrument, player: TutorSequencePlaying) {
        self.instrument = instrument
        self.player = player
        if let spec {
            do {
                sequence = try ExerciseGenerator.playback(for: spec, context: .standard(instrument))
                error = nil
            } catch {
                sequence = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        } else {
            sequence = nil
            error = nil
        }
    }

    init(sequence: PlaybackSequence?, error: String? = nil, instrument: TutorInstrument, player: TutorSequencePlaying) {
        self.sequence = sequence
        self.error = error
        self.instrument = instrument
        self.player = player
    }

    var highlighted: Set<Int> {
        guard let i = currentIndex, let sequence, sequence.notes.indices.contains(i) else { return [] }
        return Set(sequence.notes[i].pitches)
    }

    /// Labels for the note strip under the diagram.
    var stripItems: [(index: Int, text: String)] {
        guard let sequence else { return [] }
        return sequence.notes.enumerated().compactMap { i, note in
            guard !note.pitches.isEmpty else { return nil }
            let text = note.label ?? Self.chord(for: note.pitches)?.displaySymbol
                ?? note.pitches.map { NoteNaming.displayName(midi: $0) }.joined(separator: " ")
            return (i, text)
        }
    }

    /// Names a sounding group of three or more pitch classes, so chord demos
    /// read "G, C, Am" instead of raw pitch lists.
    static func chord(for pitches: [Int]) -> Chord? {
        guard Set(pitches.map { PitchClass($0) }).count >= 3 else { return nil }
        return Chord.identify(midi: pitches).first
    }

    /// Diagram for demos authored without one: the current (or first) chord on
    /// a fretboard or keyboard. Nil when the demo is not a chord sequence.
    var autoDiagram: Diagram? {
        guard let sequence else { return nil }
        let chordNotes = sequence.notes.filter { Self.chord(for: $0.pitches) != nil }
        guard !chordNotes.isEmpty else { return nil }
        let note = currentIndex.flatMap { sequence.notes.indices.contains($0) ? sequence.notes[$0] : nil }
            .flatMap { Self.chord(for: $0.pitches) != nil ? $0 : nil } ?? chordNotes[0]
        guard let chord = Self.chord(for: note.pitches) else { return nil }
        switch instrument {
        case .guitar:
            let layout = FretboardLayout.standardGuitar
            var positions = note.fretting
            if positions == nil, let open = ChordFingering.open(for: chord),
               layout.midi(for: open) == note.pitches.sorted() {
                positions = open.positions
            }
            guard let positions, !positions.isEmpty else { return nil }
            let top = positions.map(\.fret).max() ?? 0
            return Diagram(kind: .fretboard, chord: chord.symbol, notes: positions.map(\.notation),
                           fretRange: [0, max(4, top + 1)], caption: chord.displaySymbol)
        case .piano:
            let names = note.pitches.sorted().map { Pitch(midi: $0).name }
            guard let low = note.pitches.min(), let high = note.pitches.max() else { return nil }
            let from = Pitch(midi: max(21, low - low % 12)).name
            let to = Pitch(midi: min(108, high + (11 - high % 12))).name
            return Diagram(kind: .keyboard, chord: chord.symbol, notes: names,
                           pitchRange: [from, to], caption: chord.displaySymbol)
        }
    }

    func toggle() {
        if isPlaying { stop(); return }
        guard let sequence else { return }
        isPlaying = true
        didPlay = true
        let started = player.play(sequence, instrument: instrument, onStep: { [weak self] i in
            self?.currentIndex = i
        }, completion: { [weak self] in
            self?.isPlaying = false
            self?.currentIndex = nil
        })
        soundUnavailable = !started
        if !started { isPlaying = false }
    }

    func stop() {
        player.stop()
        isPlaying = false
        currentIndex = nil
    }
}

/// Horizontal strip of the notes being played, highlighting the current one.
struct PlaybackStrip: View {
    let items: [(index: Int, text: String)]
    let current: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.index) { item in
                        Text(item.text)
                            .font(.headline)
                            .foregroundStyle(current == item.index ? .white : DS.fg1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(current == item.index ? DS.accent : DS.surfaceInset))
                            .id(item.index)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: current) { _, new in
                if let new { withAnimation(DS.motionSlow) { proxy.scrollTo(new, anchor: .center) } }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notes: " + items.map(\.text).joined(separator: ", "))
    }
}

struct DemoStepView: View {
    let step: DemoStep
    let instrument: TutorInstrument
    var onPlayed: () -> Void = {}

    @StateObject private var model: DemoPlaybackModel

    init(step: DemoStep, instrument: TutorInstrument, onPlayed: @escaping () -> Void = {}) {
        self.step = step
        self.instrument = instrument
        self.onPlayed = onPlayed
        _model = StateObject(wrappedValue: DemoPlaybackModel(spec: step.playback, instrument: instrument,
                                                             player: TutorSequencePlayer.shared))
    }

    var body: some View {
        WidthReader { width in
            let wide = TutorLayout.isWide(width) && shownDiagram != nil
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 18) { header; controls }
                            .frame(width: min(380, width * 0.36))
                        diagram.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 20) { header; diagram; controls }
                }
            }
        }
        .onDisappear { model.stop() }
        .onChange(of: model.didPlay) { _, played in if played { onPlayed() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            Text(step.caption)
                .font(.title3)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var diagram: some View {
        if let diagram = shownDiagram {
            DiagramView(diagram: diagram, instrument: instrument, highlightedMIDI: model.highlighted)
                .padding(18)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        }
    }

    private var shownDiagram: Diagram? { step.diagram ?? model.autoDiagram }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                model.toggle()
            } label: {
                Label(model.isPlaying ? "Stop" : (model.didPlay ? "Play again" : "Play"),
                      systemImage: model.isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(TutorPrimaryButtonStyle())
            .keyboardShortcut("p", modifiers: [])
            .disabled(model.sequence == nil)
            if !model.stripItems.isEmpty {
                PlaybackStrip(items: model.stripItems, current: model.currentIndex)
            }
            if model.soundUnavailable {
                TutorMessageRow(text: "Sound is unavailable right now. Check that the microphone is not listening and the volume is up.",
                                systemImage: "speaker.slash", tone: .neutral)
            }
            if let error = model.error {
                TutorMessageRow(text: "This demo could not be prepared (\(error)).", systemImage: "exclamationmark.circle", tone: .neutral)
            }
        }
    }
}
