//
//  PracticeOverlay.swift
//  TabBuddy
//
//  Live, deliberately light feedback during a take (TUTOR_PLAN.md §3.1 step 2):
//  heard notes turn green, the current target is outlined, nothing turns red.
//  • Native drawn tabs: the practice range drawn with `DrawnTabSystemView`
//    and a Canvas overlay using the same geometry.
//  • Guitar Pro / PDF / MIDI sources: a compact event strip above the
//    practice transport; the score page stays visible behind it.
//  • Visual beat pulse and count-in (app audio is muted while listening).
//

import SwiftUI

// MARK: - Drawn tab surface

struct PracticeDrawnSurface: View {
    @ObservedObject var controller: PracticeSessionController
    let model: TabRenderModel

    @AppStorage("player.notation") private var notationRaw = NotationMode.tabOnly.rawValue
    @AppStorage("player.showRhythm") private var showRhythm = true
    @AppStorage("player.fontScale") private var fontScale = 1.0
    @Environment(\.horizontalSizeClass) private var hSize

    private var showStaff: Bool { NotationMode(rawValue: notationRaw) == .tabAndStaff }
    /// Read from a music stand: never smaller than 120% on iPad.
    private var scale: CGFloat { hSize == .regular ? max(1.2, fontScale) : fontScale }

    private var systems: [TabSystemLayout] {
        guard let range = controller.range else { return [] }
        return model.systems.filter { $0.measures.contains { range.contains($0.globalIndex) } }
    }

    private var targetSystem: Int? {
        guard let e = controller.currentEvent else { return nil }
        return model.systems.first { $0.measures.contains { $0.globalIndex == e.measureIndex } }?.index
    }

    var body: some View {
        let range = controller.range
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(systems) { system in
                        ZStack(alignment: .topLeading) {
                            DrawnTabSystemView(system: system, model: model, palette: .light, scale: scale,
                                               showRhythm: showRhythm, showStaff: showStaff,
                                               isCurrentSystem: false, currentMeasure: -1, beatFraction: 0,
                                               isPlaying: false, loopStart: range?.lowerBound,
                                               loopEnd: range?.upperBound, onSeek: { _ in })
                                .allowsHitTesting(false)
                            PracticeSystemOverlay(controller: controller, cursor: controller.cursor,
                                                  system: system, model: model, scale: scale,
                                                  showRhythm: showRhythm, showStaff: showStaff)
                        }
                        .id(system.index)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .background(TabPalette.light.page)
            .onChange(of: targetSystem) { _, system in
                guard let system else { return }
                withAnimation(DS.motionSlow) { proxy.scrollTo(system, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Practice range")
    }
}

/// Tints expected notes of one drawn system: green when heard, outlined when
/// current; plus the play-along cursor.
struct PracticeSystemOverlay: View {
    @ObservedObject var controller: PracticeSessionController
    @ObservedObject var cursor: PracticeCursor
    let system: TabSystemLayout
    let model: TabRenderModel
    let scale: CGFloat
    let showRhythm: Bool
    let showStaff: Bool

    var body: some View {
        let metrics = TabMetrics(scale: scale, showRhythm: showRhythm, showStaff: showStaff,
                                 hasChords: system.measures.contains { !$0.chords.isEmpty },
                                 stringCount: model.stringCount)
        Canvas { ctx, size in draw(&ctx, size, metrics) }
            .frame(height: metrics.total)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ m: TabMetrics) {
        let staffLeft = m.gutter
        let measureWidth = max(1, size.width - m.gutter)
            / CGFloat(max(model.referenceMeasuresPerSystem, system.measureCount, 1))
        let locals = Dictionary(system.measures.enumerated().map { ($0.element.globalIndex, $0.offset) },
                                uniquingKeysWith: { a, _ in a })
        func x(_ local: Int, _ position: Double) -> CGFloat {
            staffLeft + (CGFloat(local) + CGFloat(position)) * measureWidth + min(8, measureWidth * 0.12)
        }
        let current = controller.currentEvent?.id
        let active = controller.isTakeActive

        for event in controller.events {
            guard let local = locals[event.measureIndex] else { continue }
            let heard = controller.satisfied.contains(event.id)
            let partial = controller.partiallyHeard.contains(event.id)
            let isCurrent = active && event.id == current
            guard heard || partial || isCurrent else { continue }
            let ex = x(local, event.positionInMeasure)
            let positions = event.fretting ?? []
            if positions.isEmpty {
                // No fingering: mark above the staff.
                let dot = CGRect(x: ex - 6, y: m.staffTopY - 16, width: 12, height: 12)
                if heard { ctx.fill(Path(ellipseIn: dot), with: .color(PracticePalette.hit)) }
                else { ctx.stroke(Path(ellipseIn: dot), with: .color(isCurrent ? DS.accent : PracticePalette.hit), lineWidth: 2) }
                continue
            }
            for fp in positions {
                let y = m.stringLineY(fp.string)
                let text = "\(fp.fret)"
                let w = max(16, CGFloat(text.count) * m.fretFont * 0.8 + 8)
                let pill = CGRect(x: ex - w / 2, y: y - m.fretFont * 0.75, width: w, height: m.fretFont * 1.5)
                let path = Path(roundedRect: pill, cornerRadius: 5)
                if heard {
                    ctx.fill(path, with: .color(PracticePalette.hit))
                    ctx.draw(Text(text).font(.system(size: m.fretFont, weight: .bold, design: .monospaced))
                                .foregroundColor(.white), at: CGPoint(x: ex, y: y), anchor: .center)
                } else if partial {
                    ctx.stroke(path, with: .color(PracticePalette.hit), lineWidth: 2)
                }
                if isCurrent && !heard {
                    ctx.stroke(path, with: .color(DS.accent), lineWidth: 3)
                }
            }
        }

        // Play-along cursor.
        if let beat = cursor.beat, beat >= 0, let spot = locate(beat: beat), let local = locals[spot.measure] {
            let cx = staffLeft + (CGFloat(local) + CGFloat(spot.fraction)) * measureWidth
            let top = (showStaff ? m.headerH + m.rhythmH : m.staffTopY) - 4
            var line = Path()
            line.move(to: CGPoint(x: cx, y: top)); line.addLine(to: CGPoint(x: cx, y: m.staffTopY + m.tabH + 4))
            ctx.stroke(line, with: .color(DS.accent), lineWidth: 2.5)
        }
    }

    /// Passage beat → (global measure, fraction), using the drawn measures' beat counts.
    private func locate(beat: Double) -> (measure: Int, fraction: Double)? {
        guard let range = controller.range else { return nil }
        var start = 0.0
        for sys in model.systems {
            for measure in sys.measures where range.contains(measure.globalIndex) {
                let beats = Double(max(1, measure.beatCount))
                if beat < start + beats { return (measure.globalIndex, (beat - start) / beats) }
                start += beats
            }
        }
        return nil
    }
}

// MARK: - Event strip (Guitar Pro, PDF, MIDI)

struct PracticeEventStrip: View {
    @ObservedObject var controller: PracticeSessionController
    @ScaledMetric(relativeTo: .body) private var chipHeight: CGFloat = 48

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(controller.events) { event in
                        chip(event).id(event.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: chipHeight + 20)
            .onChange(of: controller.currentIndex) {
                guard let id = controller.currentEvent?.id else { return }
                withAnimation(DS.motionFast) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let heard = controller.satisfied.count
        let total = controller.events.filter { !$0.pitches.isEmpty }.count
        var text = "\(heard) of \(total) notes heard"
        if let e = controller.currentEvent { text += ". Next: \(Self.label(e))" }
        return text
    }

    static func label(_ e: ExpectedEvent) -> String {
        if let chord = e.chordName { return chord }
        let names = e.pitches.sorted().map { NoteNaming.displayName(midi: $0) }
        return names.count > 3 ? names.prefix(3).joined(separator: " ") + " +\(names.count - 3)" : names.joined(separator: " ")
    }

    private func chip(_ event: ExpectedEvent) -> some View {
        let heard = controller.satisfied.contains(event.id)
        let partial = controller.partiallyHeard.contains(event.id)
        let current = controller.isTakeActive && controller.currentEvent?.id == event.id
        let first = controller.events.first { $0.measureIndex == event.measureIndex }?.id == event.id
        return VStack(alignment: .leading, spacing: 2) {
            Text(first ? "m. \(event.measureIndex + 1)" : " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(heard ? Color.white.opacity(0.85) : DS.fg3)
            Text(Self.label(event))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(heard ? Color.white : DS.fg1)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 52, minHeight: chipHeight, alignment: .leading)
        .background(heard ? AnyShapeStyle(PracticePalette.hit) : AnyShapeStyle(DS.surfaceInset),
                    in: RoundedRectangle(cornerRadius: DS.radiusChip))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusChip)
            .stroke(current ? DS.accent : (partial ? PracticePalette.hit : Color.clear), lineWidth: current ? 3 : 2))
        .scaleEffect(current ? 1.06 : 1)
        .animation(DS.motionFast, value: current)
    }
}

// MARK: - Beat pulse and count-in

struct PracticePulseView: View {
    @ObservedObject var cursor: PracticeCursor
    let beatsPerMeasure: Int
    let countInRemaining: Int?

    var body: some View {
        HStack(spacing: 14) {
            if let remaining = countInRemaining {
                Text("\(remaining)")
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.accent)
                    .frame(minWidth: 44)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Count-in, \(remaining)")
            }
            HStack(spacing: 10) {
                ForEach(0..<max(1, min(beatsPerMeasure, 12)), id: \.self) { beat in
                    let on = beat == cursor.pulseBeatInMeasure
                    Circle()
                        .fill(on ? DS.accent : DS.separatorStrong)
                        .frame(width: beat == 0 ? 20 : 15, height: beat == 0 ? 20 : 15)
                        .scaleEffect(on ? 1.25 : 1)
                        .animation(.easeOut(duration: 0.12), value: cursor.pulseCount)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Small input meter (so the player sees the mic hears them).
struct PracticeLevelMeter: View {
    @ObservedObject var cursor: PracticeCursor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.separatorStrong)
                Capsule().fill(PracticePalette.hit.opacity(0.8))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, cursor.inputLevel))))
            }
        }
        .frame(width: 64, height: 6)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(cursor.inputLevel * 100)) percent")
    }
}
