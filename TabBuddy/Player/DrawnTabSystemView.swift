//
//  DrawnTabSystemView.swift
//  TabBuddy
//
//  Draws a single tab system with SwiftUI `Canvas`: measure-number gutter,
//  optional rhythm-letter row, an optional standard-notation staff, the
//  6-string tab staff with barlines and fret numbers, the playhead, the active
//  note pill, A/B loop band, and section / loop flags. Pure rendering — all
//  state (playhead position, loop bounds, options) is passed in.
//
//  Replaces the monospaced `UITextView` + overlay approach with a structured,
//  drawn staff so the playhead, fingering, and tab+staff toggle are precise.
//

import SwiftUI

// MARK: - Palette

/// Colors for one rendering theme (light page vs. dark focus mode).
struct TabPalette: Equatable {
    var page: Color
    var staffLine: Color
    var barline: Color
    var measureNumber: Color
    var rhythmLetter: Color
    var fret: Color
    var label: Color
    var accent: Color
    var accentInk: Color      // text drawn on top of an accent pill
    var section: Color
    var sectionBG: Color
    var loopFill: Color
    var loopBorder: Color
    var noteInk: Color        // standard-notation noteheads / stems
    var playheadGlow: Bool

    static let light = TabPalette(
        page: Color(uiColor: .systemBackground),
        staffLine: Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.22),
        barline: Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.34),
        measureNumber: Color(red: 0.71, green: 0.71, blue: 0.74),
        rhythmLetter: Color(red: 0.60, green: 0.60, blue: 0.63),
        fret: Color(uiColor: .label),
        label: Color(red: 0.71, green: 0.71, blue: 0.74),
        accent: .accentColor,
        accentInk: .white,
        section: Color(red: 94/255, green: 92/255, blue: 230/255),
        sectionBG: Color(red: 94/255, green: 92/255, blue: 230/255).opacity(0.12),
        loopFill: Color(red: 94/255, green: 92/255, blue: 230/255).opacity(0.09),
        loopBorder: Color(red: 94/255, green: 92/255, blue: 230/255).opacity(0.55),
        noteInk: Color(uiColor: .label),
        playheadGlow: false
    )

    static let focus = TabPalette(
        page: Color(red: 0x0E/255, green: 0x0F/255, blue: 0x12/255),
        staffLine: Color.white.opacity(0.16),
        barline: Color.white.opacity(0.30),
        measureNumber: Color.white.opacity(0.40),
        rhythmLetter: Color.white.opacity(0.45),
        fret: Color(red: 0xF2/255, green: 0xF2/255, blue: 0xF7/255),
        label: Color.white.opacity(0.45),
        accent: Color(red: 0x0A/255, green: 0x84/255, blue: 1.0),
        accentInk: Color(red: 0x0E/255, green: 0x0F/255, blue: 0x12/255),
        section: Color(red: 0x9D/255, green: 0x9B/255, blue: 0xF0/255),
        sectionBG: Color(red: 94/255, green: 92/255, blue: 230/255).opacity(0.20),
        loopFill: Color(red: 94/255, green: 92/255, blue: 230/255).opacity(0.14),
        loopBorder: Color(red: 94/255, green: 92/255, blue: 230/255).opacity(0.55),
        noteInk: Color(red: 0xF2/255, green: 0xF2/255, blue: 0xF7/255),
        playheadGlow: true
    )
}

// MARK: - Metrics

/// Geometry for the drawn staff, scaled by the user's size control.
struct TabMetrics {
    var scale: CGFloat
    var showRhythm: Bool
    var showStaff: Bool

    var gutter: CGFloat { 60 }
    var rowHeight: CGFloat { 26 * scale }
    var fretFont: CGFloat { 13 * scale }
    var rhythmFont: CGFloat { 10 }
    var numberFont: CGFloat { 11 }
    var labelFont: CGFloat { 12 * scale }

    var headerH: CGFloat { 22 }
    var rhythmH: CGFloat { showRhythm ? 16 : 0 }
    var staffSpacing: CGFloat { 12 }
    var staffBlockH: CGFloat { showStaff ? (staffSpacing * 5 + 44 + 8) : 0 }
    var tabH: CGFloat { rowHeight * 6 }
    var bottomGap: CGFloat { 30 * scale }

    var staffTopY: CGFloat { headerH + rhythmH + staffBlockH }
    var total: CGFloat { headerH + rhythmH + staffBlockH + tabH + bottomGap }

    /// Y of the line for a string row (index 0 = high e, at top).
    func stringLineY(_ s: Int) -> CGFloat {
        staffTopY + CGFloat(s) * rowHeight + rowHeight * 0.5
    }
}

// MARK: - System view

struct DrawnTabSystemView: View {
    let system: TabSystemLayout
    let model: TabRenderModel
    let palette: TabPalette
    let scale: CGFloat
    let showRhythm: Bool
    let showStaff: Bool

    // Playhead
    let isCurrentSystem: Bool
    let currentMeasure: Int
    let beatFraction: Double
    let isPlaying: Bool

    // Loop (global measure indices, inclusive)
    let loopStart: Int?
    let loopEnd: Int?

    /// Seek callback with a global measure index.
    let onSeek: (Int) -> Void

    private var metrics: TabMetrics {
        TabMetrics(scale: scale, showRhythm: showRhythm, showStaff: showStaff)
    }

    var body: some View {
        let m = metrics
        Canvas { ctx, size in
            draw(ctx: &ctx, size: size, m: m)
        }
        .frame(height: m.total)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    seek(at: value.location, width: lastWidth, m: m)
                }
        )
        .overlay(GeometryReader { geo in
            Color.clear.onAppear { lastWidth = geo.size.width }
                .onChange(of: geo.size.width) { lastWidth = $0 }
        })
    }

    @State private var lastWidth: CGFloat = 0

    /// Full-bleed page color for focus mode (matches `TabPalette.focus.page`).
    static let focusBackground = Color(red: 0x0E/255, green: 0x0F/255, blue: 0x12/255)

    // MARK: Drawing

    private func draw(ctx: inout GraphicsContext, size: CGSize, m: TabMetrics) {
        let staffLeft = m.gutter
        let fullWidth = max(1, size.width - m.gutter)
        // Uniform bar width: divide the full width by the reference (typical)
        // measures-per-system so every bar is the same width across systems.
        // Systems busier than the reference fall back to filling the full width.
        let denom = CGFloat(max(model.referenceMeasuresPerSystem, system.measureCount, 1))
        let measureWidth = fullWidth / denom
        let staffWidth = measureWidth * CGFloat(system.measureCount)

        drawLoopBand(&ctx, m: m, staffLeft: staffLeft, measureWidth: measureWidth, tabBottom: m.staffTopY + m.tabH)
        drawHeaderRow(&ctx, m: m, staffLeft: staffLeft, measureWidth: measureWidth)
        if showRhythm { drawRhythmRow(&ctx, m: m, staffLeft: staffLeft, measureWidth: measureWidth) }
        if showStaff { drawStandardStaff(&ctx, m: m, staffLeft: staffLeft, staffWidth: staffWidth, measureWidth: measureWidth) }
        drawTabStaff(&ctx, m: m, staffLeft: staffLeft, staffWidth: staffWidth, measureWidth: measureWidth)
        drawPlayhead(&ctx, m: m, staffLeft: staffLeft, staffWidth: staffWidth)
    }

    /// Note onset x within the system (small inset so onsets clear the barline).
    private func noteX(measureLocal: Int, position: Double, staffLeft: CGFloat, measureWidth: CGFloat) -> CGFloat {
        staffLeft + (CGFloat(measureLocal) + CGFloat(position)) * measureWidth + min(8, measureWidth * 0.12)
    }

    private func drawLoopBand(_ ctx: inout GraphicsContext, m: TabMetrics,
                              staffLeft: CGFloat, measureWidth: CGFloat, tabBottom: CGFloat) {
        guard let ls = loopStart, let le = loopEnd else { return }
        // Intersection of [ls, le] with this system's measures.
        let locals = system.measures.enumerated()
            .filter { $0.element.globalIndex >= ls && $0.element.globalIndex <= le }
            .map { $0.offset }
        guard let first = locals.first, let last = locals.last else { return }
        let x = staffLeft + CGFloat(first) * measureWidth
        let w = CGFloat(last - first + 1) * measureWidth
        let rect = CGRect(x: x, y: m.staffTopY - 4, width: w, height: tabBottom - m.staffTopY + 8)
        ctx.fill(Path(rect), with: .color(palette.loopFill))
        var border = Path()
        border.move(to: CGPoint(x: x, y: rect.minY)); border.addLine(to: CGPoint(x: x, y: rect.maxY))
        border.move(to: CGPoint(x: x + w, y: rect.minY)); border.addLine(to: CGPoint(x: x + w, y: rect.maxY))
        ctx.stroke(border, with: .color(palette.loopBorder), lineWidth: 1.5)
    }

    private func drawHeaderRow(_ ctx: inout GraphicsContext, m: TabMetrics,
                               staffLeft: CGFloat, measureWidth: CGFloat) {
        for (local, measure) in system.measures.enumerated() {
            let x = staffLeft + CGFloat(local) * measureWidth + 7
            let y: CGFloat = m.headerH * 0.5
            let num = resolveText("\(measure.number)", size: m.numberFont, weight: .regular,
                                  design: .default, color: palette.measureNumber)
            ctx.draw(num, at: CGPoint(x: x, y: y), anchor: .leading)

            if let section = measure.section, !section.isEmpty {
                let tag = resolveText(section.uppercased(), size: 10, weight: .bold,
                                      design: .default, color: palette.section)
                ctx.draw(tag, at: CGPoint(x: x + 18, y: y), anchor: .leading)
            }
            // A / B loop flags
            if loopStart == measure.globalIndex {
                drawLoopFlag(&ctx, "A", x: x + measureWidth - 16, y: y)
            }
            if loopEnd == measure.globalIndex {
                drawLoopFlag(&ctx, "B", x: x + measureWidth - 16, y: y)
            }
        }
    }

    private func drawLoopFlag(_ ctx: inout GraphicsContext, _ s: String, x: CGFloat, y: CGFloat) {
        let pill = CGRect(x: x - 7, y: y - 7, width: 16, height: 14)
        ctx.fill(Path(roundedRect: pill, cornerRadius: 3), with: .color(palette.section))
        ctx.draw(resolveText(s, size: 9, weight: .bold, design: .default, color: .white),
                 at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
    }

    private func drawRhythmRow(_ ctx: inout GraphicsContext, m: TabMetrics,
                               staffLeft: CGFloat, measureWidth: CGFloat) {
        let y = m.headerH + m.rhythmH * 0.5
        for (local, measure) in system.measures.enumerated() {
            for col in measure.columns {
                guard let dur = col.duration else { continue }
                let x = noteX(measureLocal: local, position: col.position,
                              staffLeft: staffLeft, measureWidth: measureWidth)
                let letter = resolveText(dur.notation, size: m.rhythmFont, weight: .bold,
                                         design: .monospaced, color: palette.rhythmLetter)
                ctx.draw(letter, at: CGPoint(x: x, y: y), anchor: .center)
            }
        }
    }

    private func drawTabStaff(_ ctx: inout GraphicsContext, m: TabMetrics,
                              staffLeft: CGFloat, staffWidth: CGFloat, measureWidth: CGFloat) {
        // tuning labels + string lines
        for s in 0..<6 {
            let y = m.stringLineY(s)
            var line = Path()
            line.move(to: CGPoint(x: staffLeft, y: y))
            line.addLine(to: CGPoint(x: staffLeft + staffWidth, y: y))
            ctx.stroke(line, with: .color(palette.staffLine), lineWidth: 1)

            let label = model.stringLabels[safe: s] ?? ""
            ctx.draw(resolveText(label, size: m.labelFont, weight: .medium,
                                 design: .default, color: palette.label),
                     at: CGPoint(x: staffLeft - 11, y: y), anchor: .trailing)
        }

        // barlines
        let topY = m.stringLineY(0)
        let botY = m.stringLineY(5)
        for i in 0...system.measureCount {
            let x = staffLeft + CGFloat(i) * measureWidth
            var bar = Path()
            bar.move(to: CGPoint(x: x, y: topY))
            bar.addLine(to: CGPoint(x: x, y: botY))
            ctx.stroke(bar, with: .color(palette.barline), lineWidth: 1.5)
        }

        // fret numbers
        for (local, measure) in system.measures.enumerated() {
            let active = (isCurrentSystem && measure.globalIndex == currentMeasure && isPlaying)
                ? TabRenderModel.activeColumn(in: measure, beatFraction: beatFraction)
                : nil
            for (colIdx, col) in measure.columns.enumerated() {
                let x = noteX(measureLocal: local, position: col.position,
                              staffLeft: staffLeft, measureWidth: measureWidth)
                let isActive = (colIdx == active)
                for s in 0..<6 {
                    guard let fret = col.frets[safe: s] ?? nil else { continue }
                    let y = m.stringLineY(s)
                    drawFret(&ctx, fret: fret, x: x, y: y, m: m, active: isActive)
                }
            }
        }
    }

    private func drawFret(_ ctx: inout GraphicsContext, fret: Int, x: CGFloat, y: CGFloat,
                          m: TabMetrics, active: Bool) {
        let text = "\(fret)"
        if active {
            let w = max(16, CGFloat(text.count) * m.fretFont * 0.8 + 8)
            let pill = CGRect(x: x - w/2, y: y - m.fretFont * 0.75, width: w, height: m.fretFont * 1.5)
            ctx.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color(palette.accent))
            ctx.draw(resolveText(text, size: m.fretFont, weight: .bold,
                                 design: .monospaced, color: palette.accentInk),
                     at: CGPoint(x: x, y: y), anchor: .center)
        } else {
            // knockout: paint page color behind the digit so it masks the string line
            let w = CGFloat(text.count) * m.fretFont * 0.66 + 4
            let knock = CGRect(x: x - w/2, y: y - m.fretFont * 0.62, width: w, height: m.fretFont * 1.24)
            ctx.fill(Path(knock), with: .color(palette.page))
            ctx.draw(resolveText(text, size: m.fretFont, weight: .semibold,
                                 design: .monospaced, color: palette.fret),
                     at: CGPoint(x: x, y: y), anchor: .center)
        }
    }

    private func drawStandardStaff(_ ctx: inout GraphicsContext, m: TabMetrics,
                                   staffLeft: CGFloat, staffWidth: CGFloat, measureWidth: CGFloat) {
        let top = m.headerH + m.rhythmH + 4
        // 5 staff lines
        for i in 0..<5 {
            let y = top + 8 + CGFloat(i) * m.staffSpacing
            var line = Path()
            line.move(to: CGPoint(x: staffLeft, y: y))
            line.addLine(to: CGPoint(x: staffLeft + staffWidth, y: y))
            ctx.stroke(line, with: .color(palette.staffLine), lineWidth: 1)
        }
        // treble clef glyph
        ctx.draw(resolveText("\u{1D11E}", size: 40, weight: .regular, design: .default,
                             color: palette.noteInk.opacity(0.85)),
                 at: CGPoint(x: staffLeft - 12, y: top + 8 + m.staffSpacing * 2), anchor: .trailing)

        let staffMidY = top + 8 + m.staffSpacing * 2  // ≈ B4 line
        for (local, measure) in system.measures.enumerated() {
            for col in measure.columns {
                guard let midi = col.melodyMIDI, let dur = col.duration else { continue }
                let x = noteX(measureLocal: local, position: col.position,
                              staffLeft: staffLeft, measureWidth: measureWidth)
                // 3px per semitone from B4(59); clamp to the block
                var ny = staffMidY - CGFloat(midi - 59) * 3
                ny = min(top + m.staffBlockH - 12, max(top - 4, ny))
                let open = (dur == .half || dur == .dottedHalf || dur == .whole)
                drawNotehead(&ctx, x: x, y: ny, open: open, dur: dur, staffMidY: staffMidY)
            }
        }
    }

    private func drawNotehead(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat,
                              open: Bool, dur: RhythmDuration, staffMidY: CGFloat) {
        let head = CGRect(x: x - 5.5, y: y - 4, width: 11, height: 8)
        if open {
            ctx.stroke(Path(ellipseIn: head), with: .color(palette.noteInk), lineWidth: 1.7)
        } else {
            ctx.fill(Path(ellipseIn: head), with: .color(palette.noteInk))
        }
        guard dur != .whole else { return }
        // stem: up when the note sits low on the staff, down when high
        let stemUp = y > staffMidY
        var stem = Path()
        if stemUp {
            stem.move(to: CGPoint(x: head.maxX, y: y - 1))
            stem.addLine(to: CGPoint(x: head.maxX, y: y - 30))
        } else {
            stem.move(to: CGPoint(x: head.minX, y: y + 1))
            stem.addLine(to: CGPoint(x: head.minX, y: y + 30))
        }
        ctx.stroke(stem, with: .color(palette.noteInk), lineWidth: 1.4)

        // flags for eighth / sixteenth
        let flags = (dur == .eighth || dur == .dottedEighth) ? 1
                  : (dur == .sixteenth || dur == .dottedSixteenth || dur == .thirtySecond) ? 2 : 0
        guard flags > 0 else { return }
        let fx = stemUp ? head.maxX : head.minX
        let fyBase = stemUp ? y - 30 : y + 30
        for f in 0..<flags {
            var flag = Path()
            let oy = CGFloat(f) * 6 * (stemUp ? 1 : -1)
            flag.move(to: CGPoint(x: fx, y: fyBase + oy))
            flag.addQuadCurve(to: CGPoint(x: fx + 6, y: fyBase + oy + (stemUp ? 10 : -10)),
                              control: CGPoint(x: fx + 7, y: fyBase + oy + (stemUp ? 2 : -2)))
            ctx.stroke(flag, with: .color(palette.noteInk), lineWidth: 1.6)
        }
    }

    private func drawPlayhead(_ ctx: inout GraphicsContext, m: TabMetrics,
                              staffLeft: CGFloat, staffWidth: CGFloat) {
        guard isCurrentSystem,
              let frac = model.playheadFraction(inSystem: system,
                                                currentMeasure: currentMeasure,
                                                beatFraction: beatFraction) else { return }
        let x = staffLeft + CGFloat(frac) * staffWidth
        let topY = (showStaff ? m.headerH + m.rhythmH : m.staffTopY) - 4
        let botY = m.staffTopY + m.tabH + 4
        var line = Path()
        line.move(to: CGPoint(x: x, y: topY))
        line.addLine(to: CGPoint(x: x, y: botY))
        if palette.playheadGlow {
            ctx.stroke(line, with: .color(palette.accent.opacity(0.5)), lineWidth: 6)
        }
        ctx.stroke(line, with: .color(palette.accent), lineWidth: 2)
        let dot = CGRect(x: x - 5, y: topY - 6, width: 10, height: 10)
        ctx.fill(Path(ellipseIn: dot), with: .color(palette.accent))
    }

    // MARK: Text helper

    private func resolveText(_ s: String, size: CGFloat, weight: Font.Weight,
                             design: Font.Design, color: Color) -> Text {
        Text(s).font(.system(size: size, weight: weight, design: design)).foregroundColor(color)
    }

    // MARK: Seek

    private func seek(at point: CGPoint, width: CGFloat, m: TabMetrics) {
        guard system.measureCount > 0 else { return }
        let staffLeft = m.gutter
        let denom = CGFloat(max(model.referenceMeasuresPerSystem, system.measureCount, 1))
        let measureWidth = max(1, width - m.gutter) / denom
        guard point.x >= staffLeft else {
            if let first = system.measures.first { onSeek(first.globalIndex) }
            return
        }
        let local = min(system.measureCount - 1, Int((point.x - staffLeft) / measureWidth))
        onSeek(system.measures[local].globalIndex)
    }
}

// MARK: - Safe index

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
