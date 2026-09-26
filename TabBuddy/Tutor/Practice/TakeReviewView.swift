//
//  TakeReviewView.swift
//  TabBuddy
//
//  The take review (TUTOR_PLAN.md §3.1 step 4). iPad (regular width): notes
//  and timing on the left, summary, tempo, playback, and history on the right.
//  iPhone and narrow Split View: one stacked column.
//
//  Grading is honest about the detector: uncertain events are neutral gray
//  ("not sure") and never counted as errors.
//

import AVFoundation
import Charts
import SwiftUI

// MARK: - Palette

enum PracticePalette {
    static let hit = Color.green
    static let wrong = Color.red
    static let uncertain = Color.gray
    static let missed = DS.fg3
    static let extra = Color.gray.opacity(0.7)
    static let rushing = DS.cautionText
    static let dragging = Color.teal
    static let steadyTiming = Color.green.opacity(0.8)

    static func heat(_ accuracy: Double) -> Color {
        switch accuracy {
        case ..<0.6: return Color.red.opacity(0.55)
        case ..<0.85: return Color.orange.opacity(0.55)
        default: return Color.green.opacity(0.35 + 0.5 * min(1, (accuracy - 0.85) / 0.15))
        }
    }
}

// MARK: - Review

struct TakeReviewView: View {
    let payload: PracticeReviewPayload
    let takes: [PracticeTakeSummary]
    let totalMeasures: Int
    var onApply: (PracticeSuggestionAction) -> Void = { _ in }
    var onSelectTake: (UUID) -> Void = { _ in }
    var onDeleteTake: (UUID) -> Void = { _ in }
    var onDone: () -> Void = {}

    @Environment(\.horizontalSizeClass) private var hSize
    @StateObject private var player = PracticeTakePlayer()
    @State private var selectedMeasure: Int?
    @State private var pendingDelete: PracticeTakeSummary?

    private var model: TakeReviewModel { TakeReviewModel(archive: payload.archive) }

    var body: some View {
        let model = self.model
        GeometryReader { geo in
            let twoColumns = hSize == .regular && geo.size.width >= 680
            VStack(spacing: 0) {
                header
                if twoColumns {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            notesColumn(model, width: geo.size.width * 0.58 - 40)
                                .padding(20)
                        }
                        .frame(width: geo.size.width * 0.58)
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                summaryCard(model)
                                tempoCard(model)
                                playbackCard(model)
                                historyCard
                            }
                            .padding(20)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            summaryCard(model)
                            playbackCard(model)
                            notesColumn(model, width: geo.size.width - 32)
                            tempoCard(model)
                            historyCard
                        }
                        .padding(16)
                    }
                }
            }
        }
        .background(DS.paper.ignoresSafeArea())
        .onAppear { player.load(payload.audioURL) }
        .onChange(of: payload.id) { player.load(payload.audioURL); selectedMeasure = nil }
        .onDisappear { player.stop() }
        .confirmationDialog("Delete this take?", isPresented: Binding(get: { pendingDelete != nil },
                                                                      set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { take in
            Button("Delete take from \(PracticeDateFormat.dayTime(take.date))", role: .destructive) {
                onDeleteTake(take.id)
            }
        } message: { _ in
            Text("Removes the analysis and recording for this take.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Take review")
                    .font(.headline)
                    .foregroundStyle(DS.fg1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(DS.fg2)
                    .lineLimit(1)
            }
            Spacer()
            Button("Done", action: onDone)
                .font(.body.weight(.semibold))
                .foregroundStyle(DS.accent)
                .frame(minWidth: 44, minHeight: 44)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Closes the review. Escape key")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: DS.headerHeight)
        .background(BarMaterial())
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var subtitle: String {
        var parts = [PracticeDateFormat.dayTime(payload.date), PracticeDefaults.label(payload.measures),
                     "\(Int(payload.bpm.rounded())) BPM"]
        if let mode = payload.archive.mode { parts.append(mode.title) }
        if let pct = payload.archive.tempoPercent { parts.append("\(Int(pct))%") }
        return parts.joined(separator: " · ")
    }

    // MARK: Notes + timing

    @ViewBuilder
    private func notesColumn(_ model: TakeReviewModel, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Notes", detail: "Green = heard. Hollow = not heard.")
            PracticeLegend(model: model)
            if model.marks.isEmpty {
                Text("The notes for this take aren't available anymore, so only the summary is shown.")
                    .font(.subheadline)
                    .foregroundStyle(DS.fg2)
            } else {
                let perRow = max(1, min(4, Int(width / 210)))
                let playbackBeat = player.isActive ? model.beat(atAudioTime: player.currentTime) : nil
                ForEach(Array(model.rows(measuresPerRow: perRow).enumerated()), id: \.offset) { _, row in
                    VStack(spacing: 2) {
                        PracticeNoteStrip(model: model, measures: row, perRow: perRow,
                                          selected: selectedMeasure, playbackBeat: playbackBeat) { m in
                            selectedMeasure = selectedMeasure == m ? nil : m
                        }
                        PracticeTimingLane(model: model, measures: row, perRow: perRow)
                    }
                    .padding(10)
                    .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusControl))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusControl).stroke(DS.separator))
                }
                if let m = selectedMeasure {
                    measureDetail(model, measure: m)
                }
            }
        }
    }

    private func measureDetail(_ model: TakeReviewModel, measure: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Measure \(measure + 1)").font(.headline)
                if let a = model.analysis.measureAccuracy[measure] {
                    Text("\(Int((a * 100).rounded()))%").font(.subheadline.monospacedDigit()).foregroundStyle(DS.fg2)
                }
                Spacer()
                Button("Loop this measure") {
                    onApply(PracticeSuggestionAction(loop: measure...measure, tempoPercent: nil))
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(DS.accent)
            }
            ForEach(model.marks(inMeasure: measure)) { mark in
                HStack(spacing: 8) {
                    PracticeGradeGlyph(grade: mark.grade).frame(width: 16, height: 16)
                    Text(TakeReviewModel.describe(mark)).font(.subheadline)
                    Spacer()
                    if let ms = mark.timingOffsetMs {
                        Text(timingText(ms)).font(.caption.monospacedDigit()).foregroundStyle(DS.fg2)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusControl))
    }

    private func timingText(_ ms: Double) -> String {
        let v = Int(ms.rounded())
        return v == 0 ? "on time" : (v < 0 ? "\(-v) ms early" : "\(v) ms late")
    }

    // MARK: Summary

    private func summaryCard(_ model: TakeReviewModel) -> some View {
        let analysis = model.analysis
        return card {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayAccuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(DS.fg1)
                    Text(model.hasReading ? "accuracy" : "no reading").font(.caption).foregroundStyle(DS.fg2)
                }
                .accessibilityElement(children: .combine)
                let timing = payload.archive.mode == .wait ? nil : analysis.timingMADms
                VStack(alignment: .leading, spacing: 2) {
                    Text(timing.map { "±\(Int($0.rounded())) ms" } ?? "—")
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .foregroundStyle(DS.fg1)
                    Text(payload.archive.mode == .wait ? "timing (not graded in Wait)" : "timing spread")
                        .font(.caption).foregroundStyle(DS.fg2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(timing.map { "Timing spread plus or minus \(Int($0.rounded())) milliseconds" }
                                    ?? "Timing not measured")
                Spacer(minLength: 0)
            }
            if !model.hasReading {
                Text("TabBuddy couldn't hear this take clearly, so it isn't scored. Move closer to the microphone, play a little louder, or check the input level before the next take.")
                    .font(.subheadline)
                    .foregroundStyle(DS.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.count(.uncertain) > 0 {
                Text("\(model.count(.uncertain)) not sure: the detector couldn't tell, so they don't count against you.")
                    .font(.caption)
                    .foregroundStyle(DS.fg2)
            }
            let weakest = model.weakestMeasures()
            if !weakest.isEmpty {
                Text("Weakest: " + weakest.map { "m. \($0.measure + 1) (\(Int(($0.accuracy * 100).rounded()))%)" }
                    .joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(DS.fg1)
            }
            ForEach(Array(analysis.suggestions.enumerated()), id: \.offset) { _, suggestion in
                let action = PracticeSuggestionAction(suggestion, totalMeasures: totalMeasures)
                Button { onApply(action) } label: {
                    HStack {
                        Image(systemName: "repeat")
                        Text(suggestion.message).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right")
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(DS.accentSoft, in: RoundedRectangle(cornerRadius: DS.radiusControl))
                    .foregroundStyle(DS.accentStrong)
                }
                .buttonStyle(.plain)
                .disabled(action.loop == nil && action.tempoPercent == nil)
                .accessibilityHint("Sets the loop and practice speed in the score")
            }
        }
    }

    // MARK: Tempo

    private func tempoCard(_ model: TakeReviewModel) -> some View {
        card {
            sectionTitle("Tempo", detail: "Tap a section to loop it.")
            PracticeTempoRibbon(model: model) { region in
                onApply(PracticeSuggestionAction(loop: region, tempoPercent: nil))
            }
        }
    }

    // MARK: Playback

    private func playbackCard(_ model: TakeReviewModel) -> some View {
        card {
            sectionTitle("Your take", detail: nil)
            if player.isLoaded {
                HStack(spacing: 14) {
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: DS.playDiameter, height: DS.playDiameter)
                            .background(Circle().fill(DS.accent))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause take" : "Play take")
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }),
                               in: 0...max(0.1, player.duration))
                            .tint(DS.accent)
                            .accessibilityLabel("Take position")
                        Text("\(minimalTime(player.currentTime)) / \(minimalTime(player.duration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DS.fg2)
                    }
                }
                Text("The cursor in the notes follows the recording.")
                    .font(.caption)
                    .foregroundStyle(DS.fg3)
            } else {
                Text("No recording for this take. Only the 10 newest takes per song keep audio.")
                    .font(.subheadline)
                    .foregroundStyle(DS.fg2)
            }
        }
    }

    // MARK: History

    private var historyCard: some View {
        card {
            sectionTitle("History", detail: takes.count > 1 ? "Accuracy per measure, oldest at the top." : nil)
            let heatmap = PracticeHeatmap(takes: takes)
            if takes.count > 1, !heatmap.isEmpty {
                PracticeHeatmapView(heatmap: heatmap, current: payload.id)
            }
            if takes.isEmpty {
                Text("Saved takes for this song appear here.").font(.subheadline).foregroundStyle(DS.fg2)
            }
            VStack(spacing: 0) {
                ForEach(takes) { take in
                    takeRow(take)
                    if take.id != takes.last?.id { Divider() }
                }
            }
        }
    }

    private func takeRow(_ take: PracticeTakeSummary) -> some View {
        HStack(spacing: 10) {
            Button { onSelectTake(take.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: take.id == payload.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(take.id == payload.id ? DS.accent : DS.fg3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PracticeDateFormat.dayTime(take.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(DS.fg1)
                        Text("\(PracticeDefaults.label(take.measures)) · \(Int(take.bpm.rounded())) BPM")
                            .font(.caption)
                            .foregroundStyle(DS.fg2)
                    }
                    Spacer()
                    if take.hasAudio {
                        Image(systemName: "waveform").foregroundStyle(DS.fg3).accessibilityLabel("Has recording")
                    }
                    Text(take.hasReading ? "\(Int((take.accuracy * 100).rounded()))%" : "Not heard")
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(take.hasReading ? DS.fg1 : DS.fg3)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this take")
            Button { pendingDelete = take } label: {
                Image(systemName: "trash")
                    .foregroundStyle(DS.fg2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete take from \(PracticeDateFormat.day(take.date))")
        }
        .contextMenu {
            Button(role: .destructive) { pendingDelete = take } label: { Label("Delete take", systemImage: "trash") }
        }
    }

    // MARK: Helpers

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusCard).stroke(DS.separator))
    }

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(DS.fg1)
                .accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.caption).foregroundStyle(DS.fg2) }
        }
    }
}

// MARK: - Legend

struct PracticeGradeGlyph: View {
    var grade: EventGrade?

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                switch grade {
                case .hit: Circle().fill(PracticePalette.hit)
                case .partial:
                    Circle().stroke(PracticePalette.hit, lineWidth: 2)
                    Circle().trim(from: 0, to: 0.5).fill(PracticePalette.hit).rotationEffect(.degrees(90))
                case .wrongPitch:
                    Circle().stroke(DS.fg2, lineWidth: 1.5)
                    Circle().fill(PracticePalette.wrong).frame(width: r, height: r).offset(x: r * 0.8, y: -r * 0.6)
                case .missed: Circle().stroke(PracticePalette.missed, lineWidth: 1.5)
                case .uncertain:
                    Circle().fill(PracticePalette.uncertain.opacity(0.45))
                    Text("?").font(.system(size: r * 1.3, weight: .bold)).foregroundStyle(.white)
                case nil:
                    RoundedRectangle(cornerRadius: 1).fill(PracticePalette.extra).frame(width: r * 0.6, height: r * 1.6)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}

struct PracticeLegend: View {
    let model: TakeReviewModel

    private var items: [(EventGrade?, String)] {
        [(.hit, "heard"), (.partial, "some chord tones"), (.wrongPitch, "other note"),
         (.missed, "not heard"), (.uncertain, "not sure"), (nil, "extra")]
    }

    var body: some View {
        let counts = model.legendCounts
        PracticeFlowLayout(spacing: 12, lineSpacing: 6) {
            ForEach(items, id: \.1) { grade, label in
                HStack(spacing: 5) {
                    PracticeGradeGlyph(grade: grade).frame(width: 13, height: 13)
                    Text("\(label) \(counts[grade] ?? 0)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DS.fg2)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(counts[grade] ?? 0) \(label)")
            }
        }
    }
}

/// Wraps children onto new lines (legend chips).
struct PracticeFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + lineSpacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(width, maxX), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + lineSpacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Note strip

/// One system of the review: measures side by side, expected notes as a
/// pitch-height strip (works for guitar and piano alike).
struct PracticeNoteStrip: View {
    let model: TakeReviewModel
    let measures: [Int]
    let perRow: Int
    var selected: Int?
    var playbackBeat: Double?
    var onSelect: (Int) -> Void

    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 11
    static let height: CGFloat = 150

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                let w = measureWidth(totalWidth: lastWidth)
                let local = Int(value.location.x / max(1, w))
                if measures.indices.contains(local) { onSelect(measures[local]) }
            })
            .background(GeometryReader { geo in
                Color.clear.onAppear { lastWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in lastWidth = width }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint("Double-tap a measure for details")
    }

    @State private var lastWidth: CGFloat = 0

    private func measureWidth(totalWidth: CGFloat) -> CGFloat { totalWidth / CGFloat(max(1, perRow)) }

    private var accessibilitySummary: String {
        measures.map { m in
            let marks = model.marks(inMeasure: m)
            let text = marks.map(TakeReviewModel.describe).joined(separator: "; ")
            return "Measure \(m + 1): \(text.isEmpty ? "no notes" : text)"
        }.joined(separator: ". ")
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = measureWidth(totalWidth: size.width)
        let range = model.pitchRange
        let top: CGFloat = 20, bottom: CGFloat = 10
        let span = CGFloat(max(1, range.upperBound - range.lowerBound))
        func y(_ pitch: Int) -> CGFloat {
            top + (1 - CGFloat(pitch - range.lowerBound) / span) * (size.height - top - bottom)
        }
        let r: CGFloat = 7

        for (i, m) in measures.enumerated() {
            let x0 = CGFloat(i) * w
            let cell = CGRect(x: x0, y: top - 4, width: w, height: size.height - top - bottom + 8)
            if selected == m {
                ctx.fill(Path(roundedRect: cell, cornerRadius: 6), with: .color(DS.accentSofter))
            }
            // Barline + measure number and accuracy.
            var bar = Path()
            bar.move(to: CGPoint(x: x0, y: top - 4)); bar.addLine(to: CGPoint(x: x0, y: size.height - bottom + 4))
            ctx.stroke(bar, with: .color(DS.separatorStrong), lineWidth: 1)
            var label = "\(m + 1)"
            if let a = model.analysis.measureAccuracy[m] { label += "  \(Int((a * 100).rounded()))%" }
            ctx.draw(Text(label).font(.system(size: labelSize, weight: .semibold).monospacedDigit())
                        .foregroundColor(DS.fg2),
                     at: CGPoint(x: x0 + 6, y: 8), anchor: .leading)
            // Faint octave guides (C notes).
            for p in range where p % 12 == 0 {
                var guide = Path()
                guide.move(to: CGPoint(x: x0 + 2, y: y(p))); guide.addLine(to: CGPoint(x: x0 + w - 2, y: y(p)))
                ctx.stroke(guide, with: .color(DS.separator), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }

            func xPos(_ position: Double) -> CGFloat { x0 + 12 + CGFloat(position) * (w - 20) }

            for extra in model.extras(inMeasure: m) {
                let x = xPos(extra.position) + 8
                let rect = CGRect(x: x - 1.5, y: y(extra.pitch) - 4, width: 3, height: 8)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(PracticePalette.extra))
            }

            for mark in model.marks(inMeasure: m) {
                let x = xPos(mark.position)
                for pitch in mark.pitches {
                    let rect = CGRect(x: x - r, y: y(pitch) - r, width: 2 * r, height: 2 * r)
                    let circle = Path(ellipseIn: rect)
                    switch mark.grade {
                    case .hit:
                        ctx.fill(circle, with: .color(PracticePalette.hit))
                    case .partial:
                        if mark.matched.contains(pitch) {
                            ctx.fill(circle, with: .color(PracticePalette.hit))
                        } else {
                            ctx.stroke(circle, with: .color(PracticePalette.hit),
                                       style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
                        }
                    case .wrongPitch, .missed:
                        ctx.stroke(circle, with: .color(PracticePalette.missed), lineWidth: 1.5)
                    case .uncertain:
                        ctx.fill(circle, with: .color(PracticePalette.uncertain.opacity(0.45)))
                    case nil:
                        ctx.stroke(circle, with: .color(DS.separatorStrong), lineWidth: 1)
                    }
                }
                if mark.grade == .partial, !mark.missing.isEmpty {
                    // Missing chord tones, beside their hollow circles.
                    for missing in mark.missing.sorted(by: >).prefix(3) {
                        ctx.draw(Text(TakeReviewModel.name(missing))
                                    .font(.system(size: labelSize - 1, weight: .semibold)).foregroundColor(DS.fg2),
                                 at: CGPoint(x: x + r + 3, y: y(missing)), anchor: .leading)
                    }
                }
                if mark.grade == .wrongPitch, !mark.wrong.isEmpty {
                    let anchorPitch = mark.pitches.max() ?? mark.wrong[0]
                    for (k, played) in mark.wrong.sorted().prefix(3).enumerated() {
                        let pos = CGPoint(x: x + r + 3, y: y(anchorPitch) - r + CGFloat(k) * (labelSize + 1))
                        ctx.draw(Text(TakeReviewModel.name(played))
                                    .font(.system(size: labelSize, weight: .bold)).foregroundColor(PracticePalette.wrong),
                                 at: pos, anchor: .leading)
                    }
                }
                if mark.grade == .uncertain, let hi = mark.pitches.max() {
                    ctx.draw(Text("?").font(.system(size: labelSize, weight: .bold)).foregroundColor(.white),
                             at: CGPoint(x: x, y: y(hi)), anchor: .center)
                }
            }
        }
        // Closing barline.
        let end = CGFloat(measures.count) * w
        var closing = Path()
        closing.move(to: CGPoint(x: end, y: top - 4)); closing.addLine(to: CGPoint(x: end, y: size.height - bottom + 4))
        ctx.stroke(closing, with: .color(DS.separatorStrong), lineWidth: 1)

        // Playback cursor.
        if let beat = playbackBeat {
            let pos = model.measurePosition(ofBeat: beat)
            let m = Int(floor(pos))
            if let local = measures.firstIndex(of: m) {
                let x = CGFloat(local) * w + 12 + CGFloat(pos - Double(m)) * (w - 20)
                var line = Path()
                line.move(to: CGPoint(x: x, y: top - 6)); line.addLine(to: CGPoint(x: x, y: size.height - bottom + 6))
                ctx.stroke(line, with: .color(DS.accent), lineWidth: 2)
            }
        }
    }
}

/// Early/late ticks under a note strip, on the same measure grid. Up = late,
/// down = early; ±150 ms reaches the lane edge.
struct PracticeTimingLane: View {
    let model: TakeReviewModel
    let measures: [Int]
    let perRow: Int
    static let scaleMs = 150.0

    var body: some View {
        let hasTiming = measures.contains { m in model.marks(inMeasure: m).contains { $0.timingOffsetMs != nil } }
        if hasTiming {
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(height: 40)
                .overlay(alignment: .trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("late").font(.system(size: 9))
                        Spacer(minLength: 0)
                        Text("±\(Int(Self.scaleMs)) ms").font(.system(size: 9).monospacedDigit())
                        Spacer(minLength: 0)
                        Text("early").font(.system(size: 9))
                    }
                    .foregroundStyle(DS.fg3)
                    .padding(.horizontal, 3)
                    .background(DS.surface.opacity(0.9))
                    .allowsHitTesting(false)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
        }
    }

    private var accessibilitySummary: String {
        let offsets = measures.flatMap { model.marks(inMeasure: $0).compactMap(\.timingOffsetMs) }
        guard !offsets.isEmpty else { return "No timing" }
        let early = offsets.filter { $0 < -40 }.count, late = offsets.filter { $0 > 40 }.count
        return "Timing: \(early) notes early, \(late) late, \(offsets.count - early - late) on time"
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width / CGFloat(max(1, perRow))
        let mid = size.height / 2
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: mid)); axis.addLine(to: CGPoint(x: CGFloat(measures.count) * w, y: mid))
        ctx.stroke(axis, with: .color(DS.separatorStrong), lineWidth: 1)
        for (i, m) in measures.enumerated() {
            for mark in model.marks(inMeasure: m) {
                guard let ms = mark.timingOffsetMs else { continue }
                let x = CGFloat(i) * w + 12 + CGFloat(mark.position) * (w - 20)
                let frac = CGFloat(max(-1, min(1, ms / Self.scaleMs)))
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: mid)); tick.addLine(to: CGPoint(x: x, y: mid - frac * (mid - 2)))
                let color = abs(ms) <= 40 ? PracticePalette.steadyTiming
                    : (ms < 0 ? PracticePalette.rushing : PracticePalette.dragging)
                ctx.stroke(tick, with: .color(color.opacity(0.5 + 0.5 * Double(abs(frac)))),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
    }
}

// MARK: - Tempo ribbon

struct PracticeTempoRibbon: View {
    let model: TakeReviewModel
    var onLoop: (ClosedRange<Int>) -> Void

    @State private var region: ClosedRange<Int>?

    var body: some View {
        let points = model.tempoPoints
        let target = model.analysis.targetBPM
        if points.count < 2 {
            Text(model.passage?.isFreeTime == true
                 ? "This piece is free time, so tempo isn't graded."
                 : "Not enough notes were heard to follow the tempo.")
                .font(.subheadline)
                .foregroundStyle(DS.fg2)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                chart(points: points, target: target)
                    .frame(height: 170)
                HStack(spacing: 14) {
                    legendSwatch(PracticePalette.rushing, "rushing")
                    legendSwatch(PracticePalette.dragging, "dragging")
                    legendSwatch(DS.fg2, "target \(Int(target.rounded())) BPM", dashed: true)
                }
                if let region {
                    Button {
                        onLoop(region)
                    } label: {
                        Label("Loop \(PracticeDefaults.label(region).lowercased())", systemImage: "repeat")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accent)
                }
            }
        }
    }

    private struct Band: Identifiable {
        var id: Int
        var start: Double
        var end: Double
        var color: Color
    }

    private func bands() -> [Band] {
        var out: [Band] = []
        for m in model.measures {
            switch model.analysis.measureTendency[m] {
            case .rushing?: out.append(Band(id: m, start: Double(m + 1), end: Double(m + 2), color: PracticePalette.rushing))
            case .dragging?: out.append(Band(id: m, start: Double(m + 1), end: Double(m + 2), color: PracticePalette.dragging))
            default: break
            }
        }
        if let region {
            out.append(Band(id: -1, start: Double(region.lowerBound + 1), end: Double(region.upperBound + 2),
                            color: DS.accent))
        }
        return out
    }

    private func chart(points: [TakeReviewModel.TempoPoint], target: Double) -> some View {
        let bpms: [Double] = points.map(\.bpm) + [target]
        let lo: Double = (bpms.min() ?? target) * 0.9
        let hi: Double = (bpms.max() ?? target) * 1.1
        let xLo = Double((model.measures.first ?? 0) + 1)
        let xHi = Double((model.measures.last ?? 0) + 2)
        let bands = bands()
        let chart = Chart {
            ForEach(bands) { (band: Band) in
                RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end),
                              yStart: .value("Low", lo), yEnd: .value("High", hi))
                    .foregroundStyle(band.color.opacity(0.16))
            }
            RuleMark(y: .value("Target", target))
                .foregroundStyle(DS.fg2)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(points) { (p: TakeReviewModel.TempoPoint) in
                LineMark(x: .value("Measure", p.measurePosition + 1), y: .value("BPM", p.bpm))
                    .foregroundStyle(DS.accent)
                    .interpolationMethod(.monotone)
            }
        }
        return chart
            .chartYScale(domain: lo...hi)
            .chartXScale(domain: xLo...xHi)
            .chartXAxisLabel("Measure")
            .chartYAxisLabel("BPM")
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            guard let plot = proxy.plotFrame else { return }
                            let x = value.location.x - geo[plot].origin.x
                            guard let measure: Double = proxy.value(atX: x) else { return }
                            region = model.loopRegion(around: Int(floor(measure)) - 1)
                        })
                }
            }
            .accessibilityLabel(tempoSummary(target: target))
    }

    private func tempoSummary(target: Double) -> String {
        let rushing = model.measures.filter { model.analysis.measureTendency[$0] == .rushing }.map { "\($0 + 1)" }
        let dragging = model.measures.filter { model.analysis.measureTendency[$0] == .dragging }.map { "\($0 + 1)" }
        var parts = ["Target \(Int(target.rounded())) BPM"]
        if !rushing.isEmpty { parts.append("rushing in measures \(rushing.joined(separator: ", "))") }
        if !dragging.isEmpty { parts.append("dragging in measures \(dragging.joined(separator: ", "))") }
        if rushing.isEmpty && dragging.isEmpty { parts.append("steady") }
        return parts.joined(separator: ", ")
    }

    private func legendSwatch(_ color: Color, _ label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dashed {
                Rectangle().stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 14, height: 1)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.35)).frame(width: 14, height: 10)
            }
            Text(label).font(.caption).foregroundStyle(DS.fg2)
        }
    }
}

// MARK: - Heatmap

struct PracticeHeatmapView: View {
    let heatmap: PracticeHeatmap
    var current: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    Text("").frame(width: 84)
                    ForEach(heatmap.measures, id: \.self) { m in
                        Text("\(m + 1)").font(.caption2.monospacedDigit()).foregroundStyle(DS.fg2)
                            .frame(width: 26)
                    }
                }
                ForEach(heatmap.rows) { row in
                    GridRow {
                        Text(PracticeDateFormat.day(row.date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(row.id == current ? DS.accentStrong : DS.fg2)
                            .frame(width: 84, alignment: .leading)
                        ForEach(heatmap.measures, id: \.self) { m in
                            cell(row.cells[m])
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rowLabel(row))
                }
            }
        }
    }

    private func cell(_ value: Double?) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(value.map(PracticePalette.heat) ?? DS.surfaceInset)
            .frame(width: 26, height: 22)
    }

    private func rowLabel(_ row: PracticeHeatmap.Row) -> String {
        let cells = heatmap.measures.compactMap { m in row.cells[m].map { "measure \(m + 1) \(Int(($0 * 100).rounded()))%" } }
        return "\(PracticeDateFormat.day(row.date)): " + cells.joined(separator: ", ")
    }
}

// MARK: - Take playback

@MainActor
final class PracticeTakePlayer: ObservableObject {
    @Published private(set) var isLoaded = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    /// Playing or paused mid-take (cursor visible).
    var isActive: Bool { isLoaded && (isPlaying || currentTime > 0) }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL?) {
        stop()
        player = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
        isLoaded = player != nil
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player, !TutorAudioSession.outputMuted else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        player?.currentTime = 0
        currentTime = 0
    }

    func seek(_ time: Double) {
        player?.currentTime = max(0, min(duration, time))
        currentTime = player?.currentTime ?? 0
    }

    private func poll() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying { pause() }
    }
}
