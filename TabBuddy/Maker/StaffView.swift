//
//  StaffView.swift
//  TabBuddy
//
//  Canvas-based treble clef music notation staff.
//  Draws staff lines, clef, time signature, barlines, and note heads.
//

import SwiftUI

struct StaffView: View {
    let notes: [ComposedNote]
    let draftNote: DraftNote?
    let beatsPerMeasure: Int
    let noteValue: Int
    let measureCount: Int
    let measureWidth: CGFloat
    let playbackMeasureIndex: Int
    let playbackBeatFraction: Double
    let isPlaying: Bool

    /// Height of the staff area (5 lines + ledger line space above/below)
    static let staffHeight: CGFloat = 180
    /// Center Y of the staff (where B4 sits — middle line)
    static let staffCenterY: CGFloat = 90

    /// X offset for the clef and time signature — wide enough for clef + time sig + padding
    static let headerWidth: CGFloat = 80

    var body: some View {
        Canvas { context, size in
            let totalWidth = Self.headerWidth + CGFloat(measureCount) * measureWidth

            drawStaffLines(context: context, width: totalWidth)
            drawClef(context: context)
            drawTimeSignature(context: context)
            drawBarlines(context: context)

            if isPlaying {
                drawPlaybackCursor(context: context)
            }

            for note in notes {
                drawNote(context: context, note: note)
            }

            if let draft = draftNote {
                drawDraftNote(context: context, draft: draft)
            }
        }
        .frame(height: Self.staffHeight)
    }

    // MARK: - Staff Lines

    private func drawStaffLines(context: GraphicsContext, width: CGFloat) {
        let staffSteps = [2, 4, 6, 8, 10]  // E4, G4, B4, D5, F5
        for step in staffSteps {
            let y = StaffPitchMapper.yOffset(staffStep: step, staffCenterY: Self.staffCenterY)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
            context.stroke(path, with: .color(.primary.opacity(0.35)), lineWidth: 1)
        }
    }

    // MARK: - Clef

    private func drawClef(context: GraphicsContext) {
        let clefText = Text("𝄞")
            .font(.system(size: 52))
            .foregroundColor(.primary.opacity(0.5))
        let y = StaffPitchMapper.yOffset(staffStep: 4, staffCenterY: Self.staffCenterY)
        context.draw(
            context.resolve(clefText),
            at: CGPoint(x: 22, y: y),
            anchor: .center
        )
    }

    // MARK: - Time Signature

    private func drawTimeSignature(context: GraphicsContext) {
        let topText = Text("\(beatsPerMeasure)")
            .font(.system(size: 22, weight: .bold, design: .serif))
            .foregroundColor(.primary)
        let bottomText = Text("\(noteValue)")
            .font(.system(size: 22, weight: .bold, design: .serif))
            .foregroundColor(.primary)

        // Top number in upper half of staff (between lines 3-5)
        let topY = StaffPitchMapper.yOffset(staffStep: 8, staffCenterY: Self.staffCenterY)
        // Bottom number in lower half (between lines 1-3)
        let bottomY = StaffPitchMapper.yOffset(staffStep: 4, staffCenterY: Self.staffCenterY)

        context.draw(context.resolve(topText), at: CGPoint(x: 58, y: topY), anchor: .center)
        context.draw(context.resolve(bottomText), at: CGPoint(x: 58, y: bottomY), anchor: .center)
    }

    // MARK: - Barlines

    private func drawBarlines(context: GraphicsContext) {
        let topY = StaffPitchMapper.yOffset(staffStep: 10, staffCenterY: Self.staffCenterY)
        let bottomY = StaffPitchMapper.yOffset(staffStep: 2, staffCenterY: Self.staffCenterY)

        for i in 0...measureCount {
            let x = Self.headerWidth + CGFloat(i) * measureWidth
            var path = Path()
            path.move(to: CGPoint(x: x, y: topY))
            path.addLine(to: CGPoint(x: x, y: bottomY))
            context.stroke(path, with: .color(.primary.opacity(0.4)),
                          lineWidth: i == 0 || i == measureCount ? 2 : 1)
        }
    }

    // MARK: - Playback Cursor

    private func drawPlaybackCursor(context: GraphicsContext) {
        let topY = StaffPitchMapper.yOffset(staffStep: 12, staffCenterY: Self.staffCenterY)
        let bottomY = StaffPitchMapper.yOffset(staffStep: 0, staffCenterY: Self.staffCenterY)
        let x = Self.headerWidth + CGFloat(playbackMeasureIndex) * measureWidth
            + CGFloat(playbackBeatFraction) * measureWidth

        var path = Path()
        path.move(to: CGPoint(x: x, y: topY))
        path.addLine(to: CGPoint(x: x, y: bottomY))
        context.stroke(path, with: .color(.accentColor.opacity(0.6)), lineWidth: 2)
    }

    // MARK: - Note Drawing

    private func drawNote(context: GraphicsContext, note: ComposedNote) {
        let x = noteX(measureIndex: note.measureIndex, position: note.positionInMeasure)
        let y = StaffPitchMapper.yOffset(staffStep: note.staffStep, staffCenterY: Self.staffCenterY)

        // Note head
        let filled = note.durationInBeats < 2.0
        drawNoteHead(context: context, x: x, y: y, color: .primary, filled: filled)

        // Stem (not for whole notes)
        if note.durationInBeats < 4.0 {
            drawStem(context: context, x: x, y: y, staffStep: note.staffStep, color: .primary)
        }

        // Ledger lines
        drawLedgerLines(context: context, x: x, staffStep: note.staffStep)

        // Accidental
        if note.accidental != 0 {
            drawAccidental(context: context, x: x - 14, y: y,
                          accidental: note.accidental, color: .primary)
        }
    }

    private func drawDraftNote(context: GraphicsContext, draft: DraftNote) {
        let x = noteX(measureIndex: draft.measureIndex, position: draft.positionInMeasure)
        let y = StaffPitchMapper.yOffset(staffStep: draft.staffStep, staffCenterY: Self.staffCenterY)
        let color = Color.accentColor.opacity(0.7)

        drawNoteHead(context: context, x: x, y: y, color: color, filled: true)
        drawStem(context: context, x: x, y: y, staffStep: draft.staffStep, color: color)
        drawLedgerLines(context: context, x: x, staffStep: draft.staffStep)

        if draft.accidental != 0 {
            drawAccidental(context: context, x: x - 14, y: y,
                          accidental: draft.accidental, color: color)
        }

        // Note name label above
        let name = StaffPitchMapper.noteName(midiPitch: draft.midiPitch)
        let label = Text(name)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.accentColor)
        context.draw(context.resolve(label), at: CGPoint(x: x, y: y - 22), anchor: .center)
    }

    // MARK: - Note Components

    private func noteX(measureIndex: Int, position: Double) -> CGFloat {
        Self.noteX(measureIndex: measureIndex, position: position, measureWidth: measureWidth)
    }

    private func drawNoteHead(context: GraphicsContext, x: CGFloat, y: CGFloat,
                               color: Color, filled: Bool) {
        let width: CGFloat = 12
        let height: CGFloat = 9
        let rect = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
        let ellipse = Path(ellipseIn: rect)

        if filled {
            context.fill(ellipse, with: .color(color))
        } else {
            context.stroke(ellipse, with: .color(color), lineWidth: 1.5)
        }
    }

    private func drawStem(context: GraphicsContext, x: CGFloat, y: CGFloat,
                           staffStep: Int, color: Color) {
        let stemLength: CGFloat = 30
        // Stem up if below middle line, down if above
        let stemX = staffStep < 6 ? x + 6 : x - 6
        let stemEndY = staffStep < 6 ? y - stemLength : y + stemLength

        var path = Path()
        path.move(to: CGPoint(x: stemX, y: y))
        path.addLine(to: CGPoint(x: stemX, y: stemEndY))
        context.stroke(path, with: .color(color), lineWidth: 1.2)
    }

    private func drawLedgerLines(context: GraphicsContext, x: CGFloat, staffStep: Int) {
        let ledgerWidth: CGFloat = 18

        // Below staff: middle C (step 0) and below
        if staffStep <= 0 {
            var step = 0
            while step >= staffStep {
                if step % 2 == 0 {
                    let ly = StaffPitchMapper.yOffset(staffStep: step, staffCenterY: Self.staffCenterY)
                    var path = Path()
                    path.move(to: CGPoint(x: x - ledgerWidth / 2, y: ly))
                    path.addLine(to: CGPoint(x: x + ledgerWidth / 2, y: ly))
                    context.stroke(path, with: .color(.primary.opacity(0.35)), lineWidth: 1)
                }
                step -= 1
            }
        }

        // Above staff: A5 (step 12) and above
        if staffStep >= 12 {
            var step = 12
            while step <= staffStep {
                if step % 2 == 0 {
                    let ly = StaffPitchMapper.yOffset(staffStep: step, staffCenterY: Self.staffCenterY)
                    var path = Path()
                    path.move(to: CGPoint(x: x - ledgerWidth / 2, y: ly))
                    path.addLine(to: CGPoint(x: x + ledgerWidth / 2, y: ly))
                    context.stroke(path, with: .color(.primary.opacity(0.35)), lineWidth: 1)
                }
                step += 1
            }
        }
    }

    private func drawAccidental(context: GraphicsContext, x: CGFloat, y: CGFloat,
                                 accidental: Int, color: Color) {
        let symbol = accidental > 0 ? "♯" : "♭"
        let text = Text(symbol)
            .font(.system(size: 14))
            .foregroundColor(color)
        context.draw(context.resolve(text), at: CGPoint(x: x, y: y), anchor: .center)
    }

    // MARK: - Hit Testing

    /// Pure geometric hit test — does not require a view instance.
    static func hitTest(location: CGPoint, measureWidth: CGFloat,
                        measureCount: Int) -> (measureIndex: Int, positionInMeasure: Double, staffStep: Int)? {
        guard location.x >= headerWidth else { return nil }
        let relativeX = location.x - headerWidth
        let measureIndex = Int(relativeX / measureWidth)
        guard measureIndex >= 0, measureIndex < measureCount else { return nil }

        let positionInMeasure = Double((relativeX - CGFloat(measureIndex) * measureWidth) / measureWidth)
        let staffStep = StaffPitchMapper.staffStep(fromYOffset: location.y, staffCenterY: staffCenterY)

        return (measureIndex, max(0, min(1, positionInMeasure)), staffStep)
    }

    // MARK: - Shared Note X Calculation

    /// Computes the X position for a note within a measure, with margin so notes don't sit on barlines.
    static func noteX(measureIndex: Int, position: Double, measureWidth: CGFloat) -> CGFloat {
        let marginFraction = 0.08
        let adjustedPosition = marginFraction + position * (1.0 - marginFraction * 2)
        return headerWidth
            + CGFloat(measureIndex) * measureWidth
            + CGFloat(adjustedPosition) * measureWidth
    }
}
