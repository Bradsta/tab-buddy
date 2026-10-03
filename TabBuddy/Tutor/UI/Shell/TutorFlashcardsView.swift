//
//  TutorFlashcardsView.swift
//  TabBuddy
//
//  Flashcards pane: scope picker (chapters read / all), one big card that
//  flips to reveal its answer, "Got it" / "Again" that only change the order,
//  and Shuffle / Start over. No grading, no due counts.
//

import SwiftUI

struct TutorFlashcardsView: View {
    let course: Course
    let progress: PathProgress
    let instrument: TutorInstrument

    @StateObject private var model: TutorFlashcardsModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(course: Course, progress: PathProgress, instrument: TutorInstrument) {
        self.course = course
        self.progress = progress
        self.instrument = instrument
        _model = StateObject(wrappedValue: TutorFlashcardsModel(course: course, progress: progress, instrument: instrument,
                                                                seed: UInt64.random(in: 0...UInt64(UInt32.max))))
    }

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !compact {
                    Text("Flashcards").font(.largeTitle.weight(.bold))
                }
                Text("Quick recall for the facts, notes, and chords in the chapters. Flip a card, then keep it or send it to the back. Nothing is scored.")
                    .font(compact ? .body : .title3)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Cards from", selection: Binding(get: { model.scope }, set: { model.setScope($0) })) {
                    ForEach(TutorFlashcardsModel.Scope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)

                if model.cards.isEmpty {
                    emptyState
                } else if let card = model.current {
                    HStack {
                        Text("\(model.remaining) \(model.remaining == 1 ? "card" : "cards") left")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(DS.fg2)
                        Spacer()
                        Button { model.shuffle() } label: { Label("Shuffle", systemImage: "shuffle") }
                            .buttonStyle(.bordered)
                        Button { model.reset() } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(.bordered)
                    }
                    cardView(card)
                        .id(card.id)
                    actions
                } else {
                    finished
                }
            }
            .padding(compact ? 16 : 32)
            .tutorReadableWidth(820)
        }
        .background(DS.paper)
    }

    private var emptyState: some View {
        TutorShellCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.scope == .done ? "No chapters marked read yet" : "No cards in this course")
                    .font(.title3.weight(.semibold))
                Text(model.scope == .done
                     ? "Cards come from the chapters you mark as done. Switch to All chapters to browse everything now."
                     : "This course has no review items.")
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                if model.scope == .done, !model.allCards.isEmpty {
                    Button("Show all chapters") { model.setScope(.all) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var finished: some View {
        TutorShellCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Deck finished", systemImage: "checkmark.circle")
                    .font(.title3.weight(.semibold))
                Text("You kept \(model.gotItCount) \(model.gotItCount == 1 ? "card" : "cards"). Start over to run through them again.")
                    .foregroundStyle(DS.fg2)
                Button { model.reset() } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func cardView(_ card: TutorFlashcard) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(card.kindLabel.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(DS.accentStrong)
                Spacer()
                Text(card.lessonTitle)
                    .font(.caption)
                    .foregroundStyle(DS.fg3)
                    .lineLimit(1)
            }
            Text(card.prompt)
                .font(compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            if let diagram = card.diagram {
                DiagramView(diagram: diagram, instrument: instrument)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                if let playback = card.playback, !card.isPlayCard {
                    Button { TutorShellAudio.play(playback, instrument: instrument) } label: {
                        Label("Hear it", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(.bordered)
                }
                if card.isPlayCard {
                    Text("Play it on your instrument, then flip to check.")
                        .font(.subheadline)
                        .foregroundStyle(DS.fg2)
                }
            }
            if model.revealed {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Answer").font(.subheadline.weight(.semibold)).foregroundStyle(DS.fg3)
                    Text(card.answer)
                        .font(compact ? .title3 : .title2)
                        .foregroundStyle(DS.fg1)
                        .fixedSize(horizontal: false, vertical: true)
                    if card.isPlayCard, !card.hearPitches.isEmpty {
                        Button { hear(card) } label: { Label("Hear it", systemImage: "speaker.wave.2") }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.accentSofter, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            }
        }
        .padding(compact ? 20 : 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if model.revealed {
                Button { model.again() } label: {
                    Label("Again", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut("1", modifiers: [])
                Button { model.gotIt() } label: {
                    Label("Got it", systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("2", modifiers: [])
            } else {
                Button { withAnimation(DS.motionFast) { model.flip() } } label: {
                    Text("Show answer").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
                Button("Skip") { model.skip() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
    }

    private func hear(_ card: TutorFlashcard) {
        let synth = TutorSynth.shared
        synth.instrument = instrument
        synth.play(chords: card.hearPitches, style: .block, bpm: 60, beatsPerChord: 1)
    }
}
