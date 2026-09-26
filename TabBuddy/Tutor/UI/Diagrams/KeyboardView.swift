//
//  KeyboardView.swift
//  TabBuddy
//
//  Piano keyboard diagram over a `pitchRange` window. Key geometry comes from
//  `KeyboardLayout` (white-key units, black keys on the boundaries). Labels
//  include finger numbers for five-finger positions: right hand thumb = 1 on
//  the lowest note, left hand little finger = 5 on the lowest note. Tap a key
//  to hear it.
//

import SwiftUI

// MARK: - Model

struct KeyboardDiagramModel: Hashable {
    enum Hand: Hashable { case left, right }

    struct Mark: Hashable, Identifiable {
        var midi: Int
        var label: String?
        var isRoot: Bool
        var id: Int { midi }
    }

    let layout: KeyboardLayout
    let marks: [Mark]
    let theory: DiagramTheory
    let chordSymbol: String?

    init(diagram: Diagram) {
        let theory = DiagramTheory(diagram: diagram)
        self.theory = theory
        chordSymbol = diagram.chord
        var pitches = (diagram.notes ?? []).compactMap { Pitch($0) }
        let explicitRange = diagram.pitchRange.flatMap { r -> (Int, Int)? in
            guard r.count == 2, let lo = Pitch(r[0]), let hi = Pitch(r[1]) else { return nil }
            return (min(lo.midi, hi.midi), max(lo.midi, hi.midi))
        }
        var layout: KeyboardLayout
        if let (lo, hi) = explicitRange {
            layout = Self.whiteBounded(lo, hi)
        } else if !pitches.isEmpty {
            layout = KeyboardLayout.fitting(pitches.map(\.midi))
        } else {
            layout = KeyboardLayout.octaves(from: 4)
        }
        if pitches.isEmpty, diagram.notes == nil {
            if let chord = theory.chord {
                var octave = 3
                while octave < 7, (chord.midiNotes(rootOctave: octave).min() ?? 0) < layout.lowestMIDI { octave += 1 }
                pitches = chord.pitches(rootOctave: octave)
            } else if let scale = theory.scale {
                pitches = layout.range.filter { scale.contains(midi: $0) }
                    .map { NoteNaming.pitch(midi: $0, in: nil) }
                    .map { p in Pitch(midi: p.midi, spelled: theory.spelled(p.midi)) ?? p }
            }
        }
        if let lo = pitches.map(\.midi).min(), let hi = pitches.map(\.midi).max(),
           !layout.contains(lo) || !layout.contains(hi) {
            layout = Self.whiteBounded(min(lo, layout.lowestMIDI), max(hi, layout.highestMIDI))
        }
        self.layout = layout

        let lowest = pitches.map(\.midi).min()
        let fingers = diagram.labels == .fingers ? Self.fingers(for: pitches, caption: diagram.caption) : [:]
        var seen = Set<Int>()
        marks = pitches.filter { seen.insert($0.midi).inserted }.map { p in
            let label: String?
            switch diagram.labels {
            case .noteNames: label = p.note.displayName
            case .degrees:
                label = theory.degree(p.midi) ?? lowest.flatMap { root in
                    Interval.standard(semitones: (p.midi - root) % 12).map { DiagramTheory.pretty(ScaleType.degreeLabel($0)) }
                }
            case .intervals: label = theory.interval(p.midi, fallbackRoot: lowest)
            case .fingers: label = fingers[p.midi].map(String.init)
            case .none: label = nil
            }
            return Mark(midi: p.midi, label: label, isRoot: theory.isRoot(p.midi))
        }
    }

    /// Range widened so both ends are white keys.
    static func whiteBounded(_ lo: Int, _ hi: Int) -> KeyboardLayout {
        let low = KeyboardLayout.isBlack(lo) ? lo - 1 : lo
        let high = KeyboardLayout.isBlack(hi) ? hi + 1 : hi
        return KeyboardLayout(lowestMIDI: low, highestMIDI: high)
    }

    static func hand(for pitches: [Pitch], caption: String?) -> Hand {
        let text = (caption ?? "").lowercased()
        if text.contains("left hand") || text.contains("lh ") || text.hasPrefix("lh") { return .left }
        if text.contains("right hand") || text.contains("rh ") || text.hasPrefix("rh") { return .right }
        let midis = pitches.map(\.midi)
        return (midis.max() ?? 60) < 60 ? .left : .right
    }

    /// Finger numbers per MIDI note. Notes spanning both sides of middle C with
    /// more than five notes are split: below C4 left hand, C4 and up right hand.
    static func fingers(for pitches: [Pitch], caption: String?) -> [Int: Int] {
        let sorted = pitches.sorted()
        if sorted.count > 5, let _ = sorted.first(where: { $0.midi < 60 }), sorted.contains(where: { $0.midi >= 60 }) {
            let left = fingers(for: sorted.filter { $0.midi < 60 }, hand: .left)
            let right = fingers(for: sorted.filter { $0.midi >= 60 }, hand: .right)
            return left.merging(right) { a, _ in a }
        }
        return fingers(for: sorted, hand: hand(for: sorted, caption: caption))
    }

    /// Five-finger position when the notes fit within five letter names; otherwise
    /// the usual spread (3 notes 1-3-5, 4 notes 1-2-3-5). Left hand mirrors (5 on the lowest).
    static func fingers(for pitches: [Pitch], hand: Hand) -> [Int: Int] {
        let sorted = pitches.sorted()
        guard let first = sorted.first else { return [:] }
        let span = (sorted.last?.diatonicIndex ?? first.diatonicIndex) - first.diatonicIndex
        var right: [Int]
        if sorted.count <= 5 && span <= 4 {
            right = sorted.map { 1 + $0.diatonicIndex - first.diatonicIndex }
        } else {
            let spreads: [Int: [Int]] = [1: [1], 2: [1, 5], 3: [1, 3, 5], 4: [1, 2, 3, 5], 5: [1, 2, 3, 4, 5]]
            right = spreads[sorted.count] ?? sorted.indices.map { $0 % 5 + 1 }
        }
        if hand == .left { right = right.map { 6 - $0 } }
        var result: [Int: Int] = [:]
        for (p, f) in zip(sorted, right) where result[p.midi] == nil { result[p.midi] = f }
        return result
    }

    var accessibilityLabel: String {
        let names = marks.sorted { $0.midi < $1.midi }.map { m -> String in
            let name = Pitch(midi: m.midi, spelled: theory.spelled(m.midi))?.displayName ?? NoteNaming.displayName(midi: m.midi)
            if let label = m.label, label != theory.noteName(m.midi) { return "\(name) (\(label))" }
            return name
        }
        let head: String
        if let symbol = chordSymbol { head = "\(symbol) chord on the keyboard" }
        else if let scale = theory.scale { head = "\(scale.displayName) on the keyboard" }
        else { head = "Keyboard from \(NoteNaming.displayName(midi: layout.lowestMIDI)) to \(NoteNaming.displayName(midi: layout.highestMIDI))" }
        return names.isEmpty ? head : head + ": " + names.joined(separator: ", ")
    }
}

// MARK: - Geometry

struct KeyboardGeometry {
    var layout: KeyboardLayout
    var size: CGSize

    var whiteWidth: CGFloat { size.width / CGFloat(max(1, layout.whiteKeyCount)) }
    var blackWidth: CGFloat { whiteWidth * 0.6 }
    var blackHeight: CGFloat { size.height * 0.62 }

    func rect(for midi: Int) -> CGRect {
        if KeyboardLayout.isBlack(midi) {
            let center = CGFloat(layout.keyCenter(of: midi)) * whiteWidth
            return CGRect(x: center - blackWidth / 2, y: 0, width: blackWidth, height: blackHeight)
        }
        let index = CGFloat(layout.whiteKeyIndex(of: midi) ?? 0)
        return CGRect(x: index * whiteWidth, y: 0, width: whiteWidth, height: size.height)
    }

    /// Key under a point (black keys win where they overlap white keys).
    func key(at point: CGPoint) -> Int? {
        if point.y <= blackHeight, let black = layout.blackKeys.first(where: { rect(for: $0).contains(point) }) {
            return black
        }
        return layout.whiteKeys.first { rect(for: $0).contains(point) }
    }

    /// Where a key's label sits: near the bottom of the key.
    func labelPoint(for midi: Int) -> CGPoint {
        let r = rect(for: midi)
        return CGPoint(x: r.midX, y: r.maxY - min(r.width * 0.55, r.height * 0.2))
    }
}

// MARK: - View

struct KeyboardView: View {
    let model: KeyboardDiagramModel
    var highlightedMIDI: Set<Int> = []
    @Environment(\.tutorDiagramTapEnabled) private var tapEnabled

    var body: some View {
        GeometryReader { proxy in
            let geo = KeyboardGeometry(layout: model.layout, size: proxy.size)
            let marks = Dictionary(model.marks.map { ($0.midi, $0) }, uniquingKeysWith: { a, _ in a })
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for midi in model.layout.whiteKeys {
                        let r = geo.rect(for: midi).insetBy(dx: 1, dy: 0)
                        let path = Path(roundedRect: r, cornerRadii: .init(bottomLeading: 6, bottomTrailing: 6))
                        context.fill(path, with: .color(fill(midi, marks: marks, black: false)))
                        context.stroke(path, with: .color(DS.separatorStrong), lineWidth: 1)
                    }
                    for midi in model.layout.blackKeys {
                        let r = geo.rect(for: midi)
                        let path = Path(roundedRect: r, cornerRadii: .init(bottomLeading: 4, bottomTrailing: 4))
                        context.fill(path, with: .color(fill(midi, marks: marks, black: true)))
                    }
                    // Middle C landmark.
                    if model.layout.contains(60), marks[60] == nil {
                        let r = geo.rect(for: 60)
                        context.fill(Path(ellipseIn: CGRect(x: r.midX - 3, y: r.maxY - 12, width: 6, height: 6)),
                                     with: .color(DS.fg3))
                    }
                }
                ForEach(model.marks) { mark in
                    markView(mark, geo: geo)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard tapEnabled, let midi = geo.key(at: value.location) else { return }
                TutorSequencePlayer.shared.playPitches([midi], instrument: .piano)
            })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(minHeight: 120, maxHeight: 280)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityHint(tapEnabled ? "Tap a key to hear it." : "")
    }

    private var aspect: CGFloat {
        min(5, max(1.6, CGFloat(model.layout.whiteKeyCount) / 3.2))
    }

    private func fill(_ midi: Int, marks: [Int: KeyboardDiagramModel.Mark], black: Bool) -> Color {
        if highlightedMIDI.contains(midi) { return DS.accentStrong }
        if let mark = marks[midi] { return mark.isRoot ? DS.accentStrong.opacity(black ? 1 : 0.85) : DS.accent.opacity(black ? 1 : 0.7) }
        return black ? DS.fg1 : DS.surfaceRaised
    }

    @ViewBuilder
    private func markView(_ mark: KeyboardDiagramModel.Mark, geo: KeyboardGeometry) -> some View {
        if let label = mark.label {
            let r = geo.rect(for: mark.midi)
            let d = min(r.width * 0.86, 34)
            Text(label)
                .font(.system(size: max(10, d * 0.5), weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(DS.accentStrong)
                .frame(width: d, height: d)
                .background(Circle().fill(DS.surfaceRaised))
                .position(geo.labelPoint(for: mark.midi))
        }
    }
}
