//
//  FretboardView.swift
//  TabBuddy
//
//  Horizontal fretboard diagram: nut on the left, string 1 (high E) on top and
//  string 6 (low E) at the bottom, as the lesson text describes it. Positions
//  come from "string:fret" notes in guitarist numbering. Tuning-aware through
//  `FretboardLayout`. Tap a position to hear it.
//

import SwiftUI

// MARK: - Model

struct FretboardDiagramModel: Hashable {
    struct Dot: Hashable, Identifiable {
        var position: FretPosition
        var midi: Int
        var label: String?
        var isRoot: Bool
        var id: String { position.notation }
    }

    let layout: FretboardLayout
    /// Frets shown, e.g. 0...4. A window starting at 0 shows the nut and open strings.
    let fretWindow: ClosedRange<Int>
    let dots: [Dot]
    /// String indices (0 = high E) marked × (not played) for a known chord fingering.
    let mutedStrings: Set<Int>
    let fingering: ChordFingering?
    let theory: DiagramTheory
    let chordSymbol: String?

    init(diagram: Diagram, layout: FretboardLayout = .standardGuitar) {
        self.layout = layout
        let theory = DiagramTheory(diagram: diagram)
        self.theory = theory
        chordSymbol = diagram.chord

        var positions = (diagram.notes ?? []).compactMap { try? FretPosition(parsing: $0) }
            .filter { layout.tuningMIDI.indices.contains($0.string) && $0.fret <= layout.maxFret }
        let fingering = Self.fingering(for: theory.chord, matching: positions)
        if positions.isEmpty, let fingering { positions = fingering.positions }
        if positions.isEmpty, diagram.notes == nil, let scale = theory.scale {
            let window = Self.window(from: diagram.fretRange, positions: [], layout: layout)
            positions = layout.positions(in: scale, fretRange: window)
        }
        self.fingering = fingering
        fretWindow = Self.window(from: diagram.fretRange, positions: positions, layout: layout)

        let midis = positions.compactMap { layout.midi(at: $0) }
        let lowest = midis.min()
        dots = positions.compactMap { p in
            guard let midi = layout.midi(at: p) else { return nil }
            let label: String?
            switch diagram.labels {
            case .noteNames: label = theory.noteName(midi)
            case .degrees: label = theory.degree(midi)
            case .intervals: label = theory.interval(midi, fallbackRoot: lowest)
            case .fingers:
                if let finger = fingering?.fingers[fbSafe: p.string] ?? nil, finger > 0 { label = String(finger) } else { label = nil }
            case .none: label = nil
            }
            return Dot(position: p, midi: midi, label: label, isRoot: theory.isRoot(midi))
        }
        if let fingering {
            mutedStrings = Set(fingering.frets.indices.filter { fingering.frets[$0] == nil })
        } else {
            mutedStrings = []
        }
    }

    /// Known fingering (open chord or barre form) whose positions match the given
    /// dots; with no dots, the open fingering.
    static func fingering(for chord: Chord?, matching positions: [FretPosition]) -> ChordFingering? {
        guard let chord else { return nil }
        var candidates: [ChordFingering] = []
        if let open = ChordFingering.open(for: chord) { candidates.append(open) }
        candidates += ChordFingering.BarreForm.allCases.compactMap { ChordFingering.barre(chord, form: $0) }
        guard !positions.isEmpty else { return candidates.first }
        let wanted = Set(positions)
        return candidates.first { Set($0.positions) == wanted }
    }

    static func window(from range: [Int]?, positions: [FretPosition], layout: FretboardLayout) -> ClosedRange<Int> {
        if let range, range.count == 2 {
            let lo = max(0, min(range[0], range[1])), hi = min(layout.maxFret, max(range[0], range[1]))
            return lo...max(lo + 1, hi)
        }
        let frets = positions.map(\.fret)
        let hi = max(4, frets.max() ?? 4)
        let fretted = frets.filter { $0 > 0 }
        let lo = (fretted.min() ?? 0) > 4 && hi - (fretted.min() ?? 0) < 5 ? (fretted.min() ?? 1) - 1 : 0
        return lo...max(lo + 4, hi)
    }

    /// Open (fret 0) dots are drawn left of the nut only when the window shows the nut.
    var showsNut: Bool { fretWindow.lowerBound == 0 }
    /// Leftmost fret cell number.
    var firstCellFret: Int { max(1, fretWindow.lowerBound) }
    var cellCount: Int { max(1, fretWindow.upperBound - firstCellFret + 1) }
    var stringCount: Int { layout.stringCount }

    var accessibilityLabel: String {
        if let fingering, let symbol = chordSymbol {
            return "\(symbol) chord: \(fingering.chart)"
        }
        let names = dots.sorted { $0.midi < $1.midi }.map { d -> String in
            let name = theory.noteName(d.midi)
            return d.position.fret == 0 ? "\(name), string \(d.position.guitarString) open"
                : "\(name), string \(d.position.guitarString) fret \(d.position.fret)"
        }
        let head = theory.scale.map { "\($0.displayName) on the fretboard" } ?? "Fretboard, frets \(fretWindow.lowerBound) to \(fretWindow.upperBound)"
        return names.isEmpty ? head : head + ": " + names.joined(separator: "; ")
    }
}

extension Array {
    fileprivate subscript(fbSafe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Geometry

/// Pure layout math for the fretboard (testable).
struct FretboardGeometry {
    var size: CGSize
    var stringCount: Int
    var firstCellFret: Int
    var cellCount: Int
    var showsNut: Bool

    /// Column left of the nut/first wire for open-string dots and × marks.
    var openColumn: CGFloat { min(54, max(34, size.width * 0.08)) }
    var topInset: CGFloat { 16 }
    var bottomInset: CGFloat { 26 }   // fret numbers
    var boardLeft: CGFloat { openColumn }
    var boardRight: CGFloat { size.width - 8 }
    var cellWidth: CGFloat { (boardRight - boardLeft) / CGFloat(max(1, cellCount)) }
    var stringSpacing: CGFloat {
        (size.height - topInset - bottomInset) / CGFloat(max(1, stringCount - 1))
    }

    /// y of a string; index 0 (high E) is the top line.
    func y(string index: Int) -> CGFloat { topInset + CGFloat(index) * stringSpacing }

    /// x of fret wire `n` (the nut / left edge for n = firstCellFret - 1).
    func wireX(_ n: Int) -> CGFloat { boardLeft + CGFloat(n - (firstCellFret - 1)) * cellWidth }

    /// Center of a dot at `fret`: open strings sit in the column left of the board.
    func x(fret: Int) -> CGFloat {
        if fret == 0 { return openColumn / 2 }
        return boardLeft + (CGFloat(fret - firstCellFret) + 0.5) * cellWidth
    }

    var dotDiameter: CGFloat { min(cellWidth * 0.62, stringSpacing * 0.86, 40) }

    /// Nearest (string, fret) to a point, for tap-to-hear.
    func position(at point: CGPoint) -> FretPosition? {
        let s = Int(((point.y - topInset) / max(1, stringSpacing)).rounded())
        guard (0..<stringCount).contains(s) else { return nil }
        if point.x < boardLeft { return FretPosition(string: s, fret: 0) }
        let cell = Int((point.x - boardLeft) / max(1, cellWidth))
        guard (0..<cellCount).contains(cell) else { return nil }
        return FretPosition(string: s, fret: firstCellFret + cell)
    }

    /// Single-dot inlay frets.
    static let inlays: Set<Int> = [3, 5, 7, 9, 15, 17, 19, 21]
}

// MARK: - View

struct FretboardView: View {
    let model: FretboardDiagramModel
    var instrument: TutorInstrument = .guitar
    var highlightedMIDI: Set<Int> = []
    @Environment(\.tutorDiagramTapEnabled) private var tapEnabled

    var body: some View {
        GeometryReader { proxy in
            let geo = FretboardGeometry(size: proxy.size, stringCount: model.stringCount,
                                        firstCellFret: model.firstCellFret, cellCount: model.cellCount,
                                        showsNut: model.showsNut)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context, geo: geo) }
                ForEach(model.dots) { dot in
                    dotView(dot, geo: geo)
                        .position(x: geo.x(fret: dot.position.fret), y: geo.y(string: dot.position.string))
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard tapEnabled, let p = geo.position(at: value.location),
                      let midi = model.layout.midi(at: p) else { return }
                TutorSequencePlayer.shared.playPitches([midi], instrument: .guitar)
            })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(minHeight: 150, maxHeight: 330)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityHint(tapEnabled ? "Tap a position to hear it." : "")
    }

    private var aspect: CGFloat {
        // Wider windows get a wider board; keep strings readable.
        let cells = CGFloat(model.cellCount)
        return min(3.4, max(1.5, (cells + 0.9) / 2.6))
    }

    private func draw(in context: inout GraphicsContext, geo: FretboardGeometry) {
        let top = geo.y(string: 0), bottom = geo.y(string: geo.stringCount - 1)
        // Board.
        let board = CGRect(x: geo.boardLeft, y: top - 6, width: geo.boardRight - geo.boardLeft, height: bottom - top + 12)
        context.fill(Path(roundedRect: board, cornerRadius: 4), with: .color(DS.surfaceInset))
        // Inlays.
        for fret in model.firstCellFret..<(model.firstCellFret + model.cellCount) {
            let x = geo.x(fret: fret), mid = (top + bottom) / 2, r: CGFloat = 5
            if fret % 12 == 0 {
                for dy in [-geo.stringSpacing, geo.stringSpacing] {
                    context.fill(Path(ellipseIn: CGRect(x: x - r, y: mid + dy - r, width: 2 * r, height: 2 * r)),
                                 with: .color(DS.separatorStrong))
                }
            } else if FretboardGeometry.inlays.contains(fret) {
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: mid - r, width: 2 * r, height: 2 * r)),
                             with: .color(DS.separatorStrong))
            }
        }
        // Fret wires; the nut is thick.
        for n in (model.firstCellFret - 1)...(model.firstCellFret + model.cellCount - 1) {
            let x = geo.wireX(n)
            var p = Path()
            p.move(to: CGPoint(x: x, y: top - 6))
            p.addLine(to: CGPoint(x: x, y: bottom + 6))
            let isNut = n == 0 && model.showsNut
            context.stroke(p, with: .color(isNut ? DS.fg1 : DS.separatorStrong), lineWidth: isNut ? 6 : 2)
        }
        // Strings: lower strings drawn thicker.
        for s in 0..<geo.stringCount {
            var p = Path()
            let y = geo.y(string: s)
            p.move(to: CGPoint(x: geo.boardLeft, y: y))
            p.addLine(to: CGPoint(x: geo.boardRight, y: y))
            context.stroke(p, with: .color(DS.fg2), lineWidth: 1 + CGFloat(s) * 0.35)
        }
        // Fret numbers under the board.
        for fret in model.firstCellFret..<(model.firstCellFret + model.cellCount) {
            let text = Text("\(fret)").font(.caption.monospacedDigit()).foregroundColor(DS.fg3)
            context.draw(text, at: CGPoint(x: geo.x(fret: fret), y: bottom + 18))
        }
        // Muted strings.
        for s in model.mutedStrings {
            let text = Text("×").font(.title3.weight(.semibold)).foregroundColor(DS.fg2)
            context.draw(text, at: CGPoint(x: geo.openColumn / 2, y: geo.y(string: s)))
        }
    }

    @ViewBuilder
    private func dotView(_ dot: FretboardDiagramModel.Dot, geo: FretboardGeometry) -> some View {
        let lit = highlightedMIDI.contains(dot.midi)
        let open = dot.position.fret == 0
        let d = open ? min(geo.dotDiameter, geo.openColumn - 8) : geo.dotDiameter
        ZStack {
            if open {
                Circle()
                    .strokeBorder(lit ? DS.accentStrong : (dot.isRoot ? DS.accentStrong : DS.accent), lineWidth: 3)
                    .background(Circle().fill(lit ? DS.accentSoft : DS.surface))
            } else {
                Circle().fill(lit ? DS.accentStrong : (dot.isRoot ? DS.accentStrong : DS.accent))
            }
            if let label = dot.label {
                Text(label)
                    .font(.system(size: max(10, d * 0.42), weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(open ? DS.accentStrong : .white)
                    .padding(2)
            }
        }
        .frame(width: d, height: d)
        .scaleEffect(lit ? 1.18 : 1)
        .shadow(color: lit ? DS.accent.opacity(0.5) : .clear, radius: 6)
        .animation(DS.motionFast, value: lit)
    }
}
