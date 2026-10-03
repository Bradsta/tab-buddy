//
//  ExplainStepView.swift
//  TabBuddy
//
//  Reading sections: prose first, with the diagram beside the text on wide
//  screens (under it on compact), plus an optional "Hear it" button that
//  lights the diagram in sync. The section heading is drawn by the page.
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
                    HStack(alignment: .top, spacing: 28) {
                        textColumn(font: .title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        diagramColumn
                            .frame(width: max(320, min(520, width * 0.46)))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
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
        VStack(alignment: .leading, spacing: 14) {
            MarkdownText(text: step.body, font: font)
            if step.playback != nil {
                TutorPlayButton(isPlaying: playback.isPlaying, title: "Hear it") { playback.toggle() }
            }
        }
    }

    @ViewBuilder
    private var diagramColumn: some View {
        if let diagram = step.diagram {
            DiagramView(diagram: diagram, instrument: instrument, highlightedMIDI: playback.highlighted)
                .padding(16)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
        }
    }
}
