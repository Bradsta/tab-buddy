//
//  ExplainStepView.swift
//  TabBuddy
//
//  Reading steps: Markdown text with the diagram beside it on wide screens
//  (stacked on compact), plus an optional "Hear it" button that lights the
//  diagram in sync.
//

import SwiftUI

struct ExplainStepView: View {
    let step: ExplainStep
    let instrument: TutorInstrument

    @StateObject private var playback: DemoPlaybackModel

    init(step: ExplainStep, instrument: TutorInstrument) {
        self.step = step
        self.instrument = instrument
        _playback = StateObject(wrappedValue: DemoPlaybackModel(spec: step.playback, instrument: instrument,
                                                                player: TutorSequencePlayer.shared))
    }

    var body: some View {
        WidthReader { width in
            let wide = TutorLayout.isWide(width) && step.diagram != nil
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 32) {
                        textColumn(font: .title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        diagramColumn
                            .frame(width: max(320, width * 0.5))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        textColumn(font: TutorLayout.isWide(width) ? .title3 : .body)
                            .frame(maxWidth: TutorLayout.readableWidth, alignment: .leading)
                        diagramColumn
                    }
                }
            }
        }
        .onDisappear { playback.stop() }
    }

    private func textColumn(font: Font) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(step.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            MarkdownText(text: step.body, font: font)
            if step.playback != nil {
                TutorPlayButton(isPlaying: playback.isPlaying, title: "Hear it") { playback.toggle() }
                    .keyboardShortcut("p", modifiers: [])
            }
        }
    }

    @ViewBuilder
    private var diagramColumn: some View {
        if let diagram = step.diagram {
            DiagramView(diagram: diagram, instrument: instrument, highlightedMIDI: playback.highlighted)
                .padding(18)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
        }
    }
}
