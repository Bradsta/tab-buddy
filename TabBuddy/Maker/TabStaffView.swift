//
//  TabStaffView.swift
//  TabBuddy
//
//  Canvas-based 6-string guitar tablature view.
//  Draws string lines, tuning labels, barlines, and fret numbers.
//

import SwiftUI

struct TabStaffView: View {
    let notes: [ComposedNote]
    let draftNote: DraftNote?
    let tuningMIDI: [Int]
    let measureCount: Int
    let measureWidth: CGFloat
    let playbackMeasureIndex: Int
    let playbackBeatFraction: Double
    let isPlaying: Bool

    /// Total height of the tab staff
    static let tabHeight: CGFloat = 120

    /// Vertical spacing between string lines
    private let stringSpacing: CGFloat = 16

    /// Top padding before first string
    private let topPadding: CGFloat = 12

    private let standardLabels = ["e", "B", "G", "D", "A", "E"]

    var body: some View {
        Canvas { context, size in
            let totalWidth = StaffView.headerWidth + CGFloat(measureCount) * measureWidth

            drawStringLines(context: context, width: totalWidth)
            drawTuningLabels(context: context)
            drawBarlines(context: context)

            if isPlaying {
                drawPlaybackCursor(context: context)
            }

            for note in notes {
                drawFretNumber(context: context, note: note)
            }

            if let draft = draftNote {
                drawDraftFretNumber(context: context, draft: draft)
            }
        }
        .frame(height: Self.tabHeight)
    }

    // MARK: - String Y Position

    private func stringY(_ stringIndex: Int) -> CGFloat {
        topPadding + CGFloat(stringIndex) * stringSpacing
    }

    // MARK: - Drawing

    private func drawStringLines(context: GraphicsContext, width: CGFloat) {
        for i in 0..<6 {
            let y = stringY(i)
            var path = Path()
            path.move(to: CGPoint(x: StaffView.headerWidth - 40, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
            context.stroke(path, with: .color(.primary.opacity(0.25)), lineWidth: 1)
        }
    }

    private func drawTuningLabels(context: GraphicsContext) {
        for i in 0..<6 {
            let y = stringY(i)
            let label = Text(standardLabels[i])
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary.opacity(0.5))
            context.draw(context.resolve(label),
                        at: CGPoint(x: StaffView.headerWidth - 32, y: y),
                        anchor: .center)
        }
    }

    private func drawBarlines(context: GraphicsContext) {
        let topY = stringY(0) - 4
        let bottomY = stringY(5) + 4

        for i in 0...measureCount {
            let x = StaffView.headerWidth + CGFloat(i) * measureWidth
            var path = Path()
            path.move(to: CGPoint(x: x, y: topY))
            path.addLine(to: CGPoint(x: x, y: bottomY))
            context.stroke(path, with: .color(.primary.opacity(0.4)),
                          lineWidth: i == 0 || i == measureCount ? 2 : 1)
        }
    }

    private func drawPlaybackCursor(context: GraphicsContext) {
        let topY = stringY(0) - 4
        let bottomY = stringY(5) + 4
        let x = StaffView.headerWidth + CGFloat(playbackMeasureIndex) * measureWidth
            + CGFloat(playbackBeatFraction) * measureWidth

        var path = Path()
        path.move(to: CGPoint(x: x, y: topY))
        path.addLine(to: CGPoint(x: x, y: bottomY))
        context.stroke(path, with: .color(.accentColor.opacity(0.6)), lineWidth: 2)
    }

    // MARK: - Fret Numbers

    private func noteX(measureIndex: Int, position: Double) -> CGFloat {
        StaffView.noteX(measureIndex: measureIndex, position: position, measureWidth: measureWidth)
    }

    private func drawFretNumber(context: GraphicsContext, note: ComposedNote) {
        let stringIndex: Int
        let fret: Int

        if let s = note.selectedString, let f = note.selectedFret {
            stringIndex = s
            fret = f
        } else if let suggestion = FretSuggestionEngine.suggest(
            midiPitch: note.midiPitch,
            tuningMIDI: tuningMIDI
        ) {
            stringIndex = suggestion.string
            fret = suggestion.fret
        } else {
            return
        }

        let x = noteX(measureIndex: note.measureIndex, position: note.positionInMeasure)
        let y = stringY(stringIndex)

        let isAutoSuggested = note.selectedString == nil
        let color: Color = isAutoSuggested ? .secondary : .primary

        // Background to cover the string line — wider for multi-digit frets
        let fretStr = "\(fret)"
        let bgWidth: CGFloat = fretStr.count > 1 ? 20 : 14
        let bgRect = CGRect(x: x - bgWidth / 2, y: y - 8, width: bgWidth, height: 16)
        context.fill(Path(roundedRect: bgRect, cornerRadius: 2),
                    with: .color(Color(.systemBackground)))

        let text = Text(fretStr)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
        context.draw(context.resolve(text), at: CGPoint(x: x, y: y), anchor: .center)
    }

    private func drawDraftFretNumber(context: GraphicsContext, draft: DraftNote) {
        guard let stringIndex = draft.suggestedString,
              let fret = draft.suggestedFret else { return }

        let x = noteX(measureIndex: draft.measureIndex, position: draft.positionInMeasure)
        let y = stringY(stringIndex)

        let fretStr = "\(fret)"
        let bgWidth: CGFloat = fretStr.count > 1 ? 20 : 14
        let bgRect = CGRect(x: x - bgWidth / 2, y: y - 8, width: bgWidth, height: 16)
        context.fill(Path(roundedRect: bgRect, cornerRadius: 2),
                    with: .color(Color(.systemBackground)))

        let text = Text(fretStr)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.accentColor.opacity(0.7))
        context.draw(context.resolve(text), at: CGPoint(x: x, y: y), anchor: .center)
    }
}
