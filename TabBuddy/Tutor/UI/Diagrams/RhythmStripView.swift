//
//  RhythmStripView.swift
//  TabBuddy
//
//  A rhythm written as note-value symbols spaced by length, with measure
//  lines and the count ("1 & 2 &") under each event. The play button sounds
//  a click on every note (accent on beat 1) and moves a highlight along.
//

import SwiftUI

struct RhythmStripModel: Hashable {
    struct Item: Hashable, Identifiable {
        var index: Int
        var event: RhythmEvent
        var startBeat: Double
        var count: String
        var id: Int { index }
    }

    let pattern: RhythmPattern?
    let beatsPerMeasure: Int
    let items: [Item]

    init(rhythm: String?, caption: String? = nil, beatsPerMeasure: Int? = nil) {
        pattern = rhythm.flatMap { RhythmPattern($0) }
        let bpm = beatsPerMeasure ?? Self.inferBeatsPerMeasure(pattern: pattern, caption: caption)
        self.beatsPerMeasure = bpm
        guard let pattern else { items = []; return }
        let starts = pattern.startBeats
        let counts = pattern.countLabels(beatsPerMeasure: bpm)
        items = pattern.events.indices.map { Item(index: $0, event: pattern.events[$0], startBeat: starts[$0], count: counts[$0]) }
    }

    static func inferBeatsPerMeasure(pattern: RhythmPattern?, caption: String?) -> Int {
        let text = caption ?? ""
        for (sig, beats) in [("3/4", 3), ("2/4", 2), ("6/8", 3), ("4/4", 4)] where text.contains(sig) { return beats }
        guard let total = pattern?.totalBeats, total > 0 else { return 4 }
        if total.truncatingRemainder(dividingBy: 4) != 0 && total.truncatingRemainder(dividingBy: 3) == 0 { return 3 }
        return 4
    }

    var totalBeats: Double { max(Double(beatsPerMeasure), pattern?.totalBeats ?? 0) }

    /// Measure-line beats strictly inside the strip.
    var barLineBeats: [Double] {
        stride(from: Double(beatsPerMeasure), to: totalBeats, by: Double(beatsPerMeasure)).map { $0 }
    }

    /// Horizontal position (0...1) of a beat inside the strip.
    func fraction(ofBeat beat: Double) -> Double { totalBeats > 0 ? beat / totalBeats : 0 }

    var accessibilityLabel: String {
        guard let pattern else { return "Rhythm" }
        let names = pattern.events.map { $0.isRest ? "\($0.value.name) rest" : "\($0.value.name) note" }
        return "Rhythm: " + names.joined(separator: ", ") + ". Counted " + items.map(\.count).joined(separator: " ")
    }
}

struct RhythmStripView: View {
    let model: RhythmStripModel
    var bpm: Double = 80
    @State private var playing: Int?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let width = proxy.size.width - 24
                ZStack(alignment: .topLeading) {
                    // Measure lines and baseline.
                    Path { p in
                        p.move(to: CGPoint(x: 12, y: 60)); p.addLine(to: CGPoint(x: 12 + width, y: 60))
                    }.stroke(DS.separator, lineWidth: 1)
                    ForEach(Array(model.barLineBeats.enumerated()), id: \.offset) { _, beat in
                        let x = 12 + width * model.fraction(ofBeat: beat)
                        Rectangle().fill(DS.fg2).frame(width: 1.5, height: 70).position(x: x, y: 40)
                    }
                    ForEach(model.items) { item in
                        let x = 12 + width * model.fraction(ofBeat: item.startBeat) + 16
                        VStack(spacing: 6) {
                            RhythmGlyph(event: item.event)
                                .foregroundStyle(playing == item.index ? DS.accentStrong : DS.fg1)
                                .frame(width: 28, height: 56)
                            Text(item.count)
                                .font(.callout.monospacedDigit().weight(item.count.first?.isNumber == true ? .bold : .regular))
                                .foregroundStyle(playing == item.index ? DS.accentStrong : (item.event.isRest ? DS.fg3 : DS.fg2))
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: DS.radiusChip).fill(playing == item.index ? DS.accentSoft : .clear))
                        .position(x: x, y: 50)
                    }
                }
            }
            .frame(height: 104)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)

            TutorPlayButton(isPlaying: task != nil, title: "Play clicks") { toggle() }
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if task != nil { stop(); return }
        let spb = 60 / max(30, bpm)
        let items = model.items
        task = Task { @MainActor in
            let start = Date()
            for item in items {
                let wait = item.startBeat * spb - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                if Task.isCancelled { return }
                playing = item.index
                if !item.event.isRest { TutorSynth.shared.playClick(accent: item.count == "1") }
            }
            try? await Task.sleep(nanoseconds: UInt64(spb * 1e9))
            if Task.isCancelled { return }
            playing = nil
            task = nil
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        playing = nil
    }
}

/// Drawn note or rest symbol for one rhythm event.
struct RhythmGlyph: View {
    let event: RhythmEvent

    var body: some View {
        Canvas { context, size in
            let color = GraphicsContext.Shading.foreground
            let base = event.value.base
            let midY = size.height * 0.7
            let x = size.width * 0.4
            if event.isRest {
                drawRest(&context, base: base, size: size, shading: color)
            } else {
                let w: CGFloat = 13, h: CGFloat = 9
                var head = Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                head = head.applying(CGAffineTransform(rotationAngle: -0.35)).applying(CGAffineTransform(translationX: x, y: midY))
                if base == .whole || base == .half {
                    context.stroke(head, with: color, lineWidth: 2)
                } else {
                    context.fill(head, with: color)
                }
                if base != .whole {
                    var stem = Path()
                    stem.move(to: CGPoint(x: x + w / 2 - 1, y: midY))
                    stem.addLine(to: CGPoint(x: x + w / 2 - 1, y: midY - 36))
                    context.stroke(stem, with: color, lineWidth: 1.6)
                    let flags = base == .eighth ? 1 : base == .sixteenth ? 2 : 0
                    for f in 0..<flags {
                        var flag = Path()
                        let top = midY - 36 + CGFloat(f) * 8
                        flag.move(to: CGPoint(x: x + w / 2 - 1, y: top))
                        flag.addQuadCurve(to: CGPoint(x: x + w / 2 + 9, y: top + 16), control: CGPoint(x: x + w / 2 + 10, y: top + 6))
                        context.stroke(flag, with: color, lineWidth: 2)
                    }
                }
            }
            for d in 0..<event.value.dots {
                let dx = x + 12 + CGFloat(d) * 6
                context.fill(Path(ellipseIn: CGRect(x: dx, y: midY - 5, width: 4, height: 4)), with: color)
            }
            if event.value.isTriplet {
                context.draw(Text("3").font(.caption2.bold()), at: CGPoint(x: x, y: 6))
            }
        }
    }

    private func drawRest(_ context: inout GraphicsContext, base: NoteValue.Base, size: CGSize, shading: GraphicsContext.Shading) {
        let x = size.width * 0.4, mid = size.height * 0.5
        switch base {
        case .whole:
            context.fill(Path(CGRect(x: x - 7, y: mid - 6, width: 14, height: 6)), with: shading)
            context.fill(Path(CGRect(x: x - 11, y: mid - 7, width: 22, height: 1.5)), with: shading)
        case .half:
            context.fill(Path(CGRect(x: x - 7, y: mid - 6, width: 14, height: 6)), with: shading)
            context.fill(Path(CGRect(x: x - 11, y: mid, width: 22, height: 1.5)), with: shading)
        case .quarter:
            var p = Path()
            p.move(to: CGPoint(x: x - 3, y: mid - 16))
            p.addLine(to: CGPoint(x: x + 4, y: mid - 7))
            p.addLine(to: CGPoint(x: x - 3, y: mid + 1))
            p.addLine(to: CGPoint(x: x + 4, y: mid + 9))
            p.addQuadCurve(to: CGPoint(x: x - 1, y: mid + 18), control: CGPoint(x: x - 7, y: mid + 8))
            context.stroke(p, with: shading, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        case .eighth, .sixteenth:
            let flags = base == .eighth ? 1 : 2
            var stem = Path()
            stem.move(to: CGPoint(x: x + 5, y: mid - 10))
            stem.addLine(to: CGPoint(x: x - 1, y: mid + 14))
            context.stroke(stem, with: shading, lineWidth: 1.8)
            for f in 0..<flags {
                let y = mid - 10 + CGFloat(f) * 8
                context.fill(Path(ellipseIn: CGRect(x: x - 6, y: y - 3, width: 5, height: 5)), with: shading)
                var hook = Path()
                hook.move(to: CGPoint(x: x - 4, y: y + 1))
                hook.addQuadCurve(to: CGPoint(x: x + 5 - CGFloat(f) * 2, y: y), control: CGPoint(x: x, y: y + 4))
                context.stroke(hook, with: shading, lineWidth: 1.6)
            }
        }
    }
}
