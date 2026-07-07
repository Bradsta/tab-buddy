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
    var activeMeasureFill: Color   // AccentSoft wash under the playing measure
    var noteInk: Color        // standard-notation noteheads / stems
    var playheadGlow: Bool

    /// The standard palette. Line/text inks are dynamic system colors so the
    /// staff stays visible when the page flips to dark (pure black) mode.
    static let light = TabPalette(
        page: DS.paper,
        staffLine: Color(uiColor: .label).opacity(0.24),
        barline: Color(uiColor: .label).opacity(0.38),
        measureNumber: Color(uiColor: .tertiaryLabel),
        rhythmLetter: Color(uiColor: .secondaryLabel),
        fret: Color(uiColor: .label),
        label: Color(uiColor: .tertiaryLabel),
        accent: DS.accent,
        accentInk: .white,
        section: DS.accentStrong,
        sectionBG: DS.accent.opacity(0.12),
        loopFill: DS.accent.opacity(0.09),
        loopBorder: DS.accent.opacity(0.55),
        activeMeasureFill: DS.accentSoft.opacity(0.55),
        noteInk: Color(uiColor: .label),
        playheadGlow: false
    )

    // Focus (stage) mode is always dark regardless of the system theme, so it
    // uses fixed dark values: pure black stage, lifted rose accent.
    static let focus = TabPalette(
        page: .black,
        staffLine: Color.white.opacity(0.20),
        barline: Color.white.opacity(0.34),
        measureNumber: Color.white.opacity(0.40),
        rhythmLetter: Color.white.opacity(0.45),
        fret: Color(red: 0xF2/255, green: 0xF2/255, blue: 0xF2/255),
        label: Color.white.opacity(0.45),
        accent: Color(red: 0xF0/255, green: 0x7E/255, blue: 0x79/255),        // Accent dark
        accentInk: .black,
        section: Color(red: 0xFF/255, green: 0x91/255, blue: 0x8B/255),       // AccentStrong dark
        sectionBG: Color(red: 0xF0/255, green: 0x7E/255, blue: 0x79/255).opacity(0.20),
        loopFill: Color(red: 0xF0/255, green: 0x7E/255, blue: 0x79/255).opacity(0.14),
        loopBorder: Color(red: 0xF0/255, green: 0x7E/255, blue: 0x79/255).opacity(0.55),
        activeMeasureFill: Color(red: 0x47/255, green: 0x29/255, blue: 0x28/255).opacity(0.6), // AccentSoft dark
        noteInk: Color(red: 0xF2/255, green: 0xF2/255, blue: 0xF2/255),
        playheadGlow: true
    )
}

// MARK: - Metrics

/// Geometry for the drawn staff, scaled by the user's size control.
struct TabMetrics {
    var scale: CGFloat
    var showRhythm: Bool
    var showStaff: Bool
    /// Whether the system carries chord symbols — they get their own band
    /// above the measure numbers so the two never collide.
    var hasChords: Bool = false

    var gutter: CGFloat { 60 }
    // Compact, text-tab-like density: a string row is just tall enough for
    // the fret digits, and the header/rhythm bands hug their content.
    var rowHeight: CGFloat { 17 * scale }
    var fretFont: CGFloat { 20 * scale }
    var rhythmFont: CGFloat { 12 }
    var numberFont: CGFloat { 12 }
    var labelFont: CGFloat { 11 * scale }

    var headerH: CGFloat { hasChords ? 32 : 18 }
    /// Baseline for the chord band (top of the header).
    var chordY: CGFloat { 9 }
    /// Baseline for measure numbers (bottom of the header).
    var numberY: CGFloat { headerH - 9 }
    var rhythmH: CGFloat { showRhythm ? 13 : 0 }
    var staffSpacing: CGFloat { 9 }
    var staffBlockH: CGFloat { showStaff ? (staffSpacing * 5 + 34 + 6) : 0 }
    var tabH: CGFloat { rowHeight * 6 }
    var bottomGap: CGFloat { 14 * scale }

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
        TabMetrics(scale: scale, showRhythm: showRhythm, showStaff: showStaff,
                   hasChords: system.measures.contains { !$0.chords.isEmpty })
    }

    var body: some View {
        let m = metrics
        // Static content and the moving playhead live in separate child views:
        // the static Canvas's inputs don't include beatFraction, so SwiftUI
        // skips its (expensive) body on every playhead step and only the thin
        // playhead layer redraws. This is what keeps chord-dense systems from
        // starving the main thread during playback.
        ZStack(alignment: .topLeading) {
            StaticSystemLayer(system: system, model: model, palette: palette,
                              scale: scale, showRhythm: showRhythm,
                              showStaff: showStaff,
                              loopStart: loopStart, loopEnd: loopEnd)
            if isCurrentSystem, isPlaying {
                PlayheadLayer(system: system, model: model, palette: palette,
                              scale: scale, showRhythm: showRhythm,
                              showStaff: showStaff,
                              hasChords: m.hasChords,
                              currentMeasure: currentMeasure,
                              beatFraction: beatFraction)
            }
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
    static let focusBackground = Color.black

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

// MARK: - Static content layer

/// Everything except the playhead. Its inputs exclude beatFraction, so SwiftUI
/// skips re-rendering it on playhead steps.
private struct StaticSystemLayer: View {
    let system: TabSystemLayout
    let model: TabRenderModel
    let palette: TabPalette
    let scale: CGFloat
    let showRhythm: Bool
    let showStaff: Bool
    let loopStart: Int?
    let loopEnd: Int?

    private var metrics: TabMetrics {
        TabMetrics(scale: scale, showRhythm: showRhythm, showStaff: showStaff,
                   hasChords: system.measures.contains { !$0.chords.isEmpty })
    }

    var body: some View {
        let m = metrics
        Canvas { ctx, size in
            draw(ctx: &ctx, size: size, m: m)
        }
        .frame(height: m.total)
    }

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
            let y: CGFloat = m.numberY
            let num = resolveText("\(measure.number)", size: m.numberFont, weight: .regular,
                                  design: .default, color: palette.measureNumber)
            ctx.draw(num, at: CGPoint(x: x, y: y), anchor: .leading)

            if let section = measure.section, !section.isEmpty {
                let tag = resolveText(section.uppercased(), size: 10, weight: .bold,
                                      design: .default, color: palette.section)
                ctx.draw(tag, at: CGPoint(x: x + 18, y: y), anchor: .leading)
            }

            // Chord symbols get their own band above the numbers, so long
            // names never collide with them.
            for chord in measure.chords {
                let cx = staffLeft + CGFloat(local) * measureWidth
                    + CGFloat(chord.position) * measureWidth + 2
                let name = resolveText(chord.name, size: 11, weight: .semibold,
                                       design: .default, color: palette.section)
                ctx.draw(name, at: CGPoint(x: cx, y: m.chordY), anchor: .leading)
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

        // fret numbers (the active-column accent is drawn by PlayheadLayer)
        for (local, measure) in system.measures.enumerated() {
            for col in measure.columns {
                let x = noteX(measureLocal: local, position: col.position,
                              staffLeft: staffLeft, measureWidth: measureWidth)
                for s in 0..<6 {
                    guard let fret = col.frets[safe: s] ?? nil else { continue }
                    let y = m.stringLineY(s)
                    drawFret(&ctx, fret: fret, x: x, y: y, m: m, active: false)
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
            ctx.draw(resolveText(text, size: m.fretFont, weight: .heavy,
                                 design: .monospaced, color: palette.accentInk),
                     at: CGPoint(x: x, y: y), anchor: .center)
        } else {
            // knockout: paint page color behind the digit so it masks the
            // string line; capped to the row so neighbor lines stay intact
            let w = CGFloat(text.count) * m.fretFont * 0.62 + 4
            let kh = m.rowHeight * 0.92
            let knock = CGRect(x: x - w/2, y: y - kh / 2, width: w, height: kh)
            ctx.fill(Path(knock), with: .color(palette.page))
            ctx.draw(resolveText(text, size: m.fretFont, weight: .heavy,
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
        ctx.draw(resolveText("\u{1D11E}", size: 32, weight: .regular, design: .default,
                             color: palette.noteInk.opacity(0.85)),
                 at: CGPoint(x: staffLeft - 12, y: top + 8 + m.staffSpacing * 2), anchor: .trailing)

        let staffMidY = top + 8 + m.staffSpacing * 2  // ≈ B4 line
        // Clip noteheads/stems/flags to the staff block so low chord voicings
        // can't spill into the tab rows below.
        var inner = ctx
        inner.clip(to: Path(CGRect(x: 0, y: top - 6, width: staffLeft + staffWidth + 20,
                                   height: m.staffBlockH + 2)))
        for (local, measure) in system.measures.enumerated() {
            for col in measure.columns {
                guard let midi = col.melodyMIDI, let dur = col.duration else { continue }
                let x = noteX(measureLocal: local, position: col.position,
                              staffLeft: staffLeft, measureWidth: measureWidth)
                // 3px per semitone from B4(59); clamp to the block
                var ny = staffMidY - CGFloat(midi - 59) * 3
                ny = min(top + m.staffBlockH - 12, max(top - 4, ny))
                let open = (dur == .half || dur == .dottedHalf || dur == .whole)
                drawNotehead(&inner, x: x, y: ny, open: open, dur: dur, staffMidY: staffMidY)
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

    private func resolveText(_ s: String, size: CGFloat, weight: Font.Weight,
                             design: Font.Design, color: Color) -> Text {
        Text(s).font(.system(size: size, weight: weight, design: design)).foregroundColor(color)
    }
}

// MARK: - Playhead layer

/// The moving playhead + active-column accent. Small and cheap; redraws on
/// each (quantized) beatFraction step while the static layer stays put.
private struct PlayheadLayer: View {
    let system: TabSystemLayout
    let model: TabRenderModel
    let palette: TabPalette
    let scale: CGFloat
    let showRhythm: Bool
    let showStaff: Bool
    let hasChords: Bool
    let currentMeasure: Int
    let beatFraction: Double

    var body: some View {
        let m = TabMetrics(scale: scale, showRhythm: showRhythm, showStaff: showStaff,
                           hasChords: hasChords)
        Canvas { ctx, size in
            let staffLeft = m.gutter
            let fullWidth = max(1, size.width - m.gutter)
            let denom = CGFloat(max(model.referenceMeasuresPerSystem, system.measureCount, 1))
            let measureWidth = fullWidth / denom
            let staffWidth = measureWidth * CGFloat(system.measureCount)

            // active-measure wash (AccentSoft under the playing measure)
            if let localIdx = system.measures.firstIndex(where: { $0.globalIndex == currentMeasure }) {
                let washTop = (showStaff ? m.headerH + m.rhythmH : m.staffTopY) - 2
                let washBot = m.staffTopY + m.tabH + 2
                let wash = CGRect(x: staffLeft + CGFloat(localIdx) * measureWidth,
                                  y: washTop,
                                  width: measureWidth,
                                  height: washBot - washTop)
                ctx.fill(Path(roundedRect: wash, cornerRadius: 4),
                         with: .color(palette.activeMeasureFill))
            }

            // active-column accent
            if let localIdx = system.measures.firstIndex(where: { $0.globalIndex == currentMeasure }) {
                let measure = system.measures[localIdx]
                if let active = TabRenderModel.activeColumn(in: measure, beatFraction: beatFraction),
                   let col = measure.columns[safe: active] {
                    let x = staffLeft + (CGFloat(localIdx) + CGFloat(col.position)) * measureWidth
                        + min(8, measureWidth * 0.12)
                    for s in 0..<6 {
                        guard let fret = col.frets[safe: s] ?? nil else { continue }
                        let y = m.stringLineY(s)
                        let text = "\(fret)"
                        let w = max(16, CGFloat(text.count) * m.fretFont * 0.8 + 8)
                        let pill = CGRect(x: x - w/2, y: y - m.fretFont * 0.75,
                                          width: w, height: m.fretFont * 1.5)
                        ctx.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color(palette.accent))
                        ctx.draw(Text(text).font(.system(size: m.fretFont, weight: .bold, design: .monospaced))
                                    .foregroundColor(palette.accentInk),
                                 at: CGPoint(x: x, y: y), anchor: .center)
                    }
                }
            }

            // playhead line
            if let frac = model.playheadFraction(inSystem: system,
                                                 currentMeasure: currentMeasure,
                                                 beatFraction: beatFraction) {
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
        }
        .frame(height: m.total)
        .allowsHitTesting(false)
    }
}

// MARK: - Safe index

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
