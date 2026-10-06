//
//  FullNeckPositionPicker.swift
//  TabBuddy
//
//  Full-neck fretboard for choosing a guitar scale position by direct
//  manipulation: every scale note on frets 0...maxFret, the five box positions
//  drawn as outlines, and a chip row ("Full neck", "1"…"5"). Tap a box to
//  select it; tap the selected box again to go back to the full neck. Same
//  orientation as `FretboardView`: nut on the left, high E on top, low E at
//  the bottom.
//

import SwiftUI

struct FullNeckPositionPicker: View {
    let scale: Scale
    /// Selected position index (1...5); nil = full neck.
    @Binding var selection: Int?
    var labels: Diagram.Labels = .noteNames
    var maxFret: Int = 15

    private var layout: FretboardLayout { .standardGuitar }

    var body: some View {
        let boxes = GuitarScalePositions.positions(for: scale, layout: layout, maxFret: maxFret)
        let notes = GuitarScalePositions.fullNeck(scale: scale, layout: layout, maxFret: maxFret)
        VStack(spacing: 12) {
            NeckHeightLayout {
                NeckBoard(scale: scale, layout: layout, maxFret: min(maxFret, layout.maxFret),
                          boxes: boxes, notes: notes, labels: labels, selection: $selection)
            }
            chipRow(boxes)
        }
        .animation(DS.motionFast, value: selection)
    }

    // MARK: Chips

    private func chipRow(_ boxes: [GuitarScalePosition]) -> some View {
        let row = HStack(spacing: 6) {
            chip(title: "Full neck", accessibility: "Full neck, every note", isSelected: selection == nil) {
                selection = nil
            }
            ForEach(boxes) { box in
                chip(title: "\(box.index)", accessibility: box.accessibilityTitle, isSelected: selection == box.index) {
                    selection = selection == box.index ? nil : box.index
                }
            }
        }
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(title: String, accessibility: String, isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(isSelected ? Color.white : DS.fg1)
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 44)
                .background(isSelected ? DS.accent : DS.surfaceInset, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Height

/// Fills the offered width; height follows the width (150...220 pt).
private struct NeckHeightLayout: Layout {
    static func height(forWidth width: CGFloat) -> CGFloat {
        min(220, max(150, width * 0.24))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: Self.height(forWidth: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

// MARK: - Geometry

/// Layout math for the full neck: an open-string column, then one cell per fret 1...maxFret.
struct FullNeckGeometry {
    var size: CGSize
    var stringCount: Int
    var maxFret: Int

    var openColumn: CGFloat { min(40, max(22, size.width * 0.045)) }
    /// Room above the board for box numbers.
    var topInset: CGFloat { 26 }
    /// Room below the board for fret numbers.
    var bottomInset: CGFloat { 24 }
    var boardLeft: CGFloat { openColumn }
    var boardRight: CGFloat { size.width - 4 }
    var cellWidth: CGFloat { (boardRight - boardLeft) / CGFloat(max(1, maxFret)) }
    var stringSpacing: CGFloat { (size.height - topInset - bottomInset) / CGFloat(max(1, stringCount - 1)) }
    var boardTop: CGFloat { topInset - 8 }
    var boardBottom: CGFloat { y(string: stringCount - 1) + 8 }

    /// y of a string; index 0 (high E) is the top line.
    func y(string: Int) -> CGFloat { topInset + CGFloat(string) * stringSpacing }

    /// x of fret wire `n` (n = 0 is the nut).
    func wireX(_ n: Int) -> CGFloat { boardLeft + CGFloat(n) * cellWidth }

    /// Center of a note at `fret`; open strings sit in the column left of the nut.
    func x(fret: Int) -> CGFloat {
        fret == 0 ? openColumn / 2 : boardLeft + (CGFloat(fret) - 0.5) * cellWidth
    }

    var dotDiameter: CGFloat { max(12, min(cellWidth * 0.72, stringSpacing * 0.82, 30)) }

    /// Outline of a box covering `frets`; fret 0 includes the open column.
    /// `inset` staggers neighbouring boxes so shared frets show both outlines.
    func boxRect(_ frets: ClosedRange<Int>, inset: CGFloat) -> CGRect {
        let left = frets.lowerBound == 0 ? 1 : wireX(frets.lowerBound - 1)
        let right = wireX(frets.upperBound)
        return CGRect(x: left + inset, y: boardTop - 4 + inset,
                      width: max(8, right - left - 2 * inset), height: boardBottom - boardTop + 8 - 2 * inset)
    }

    /// Single-dot inlay frets; 12 (and 24) get two dots.
    static let inlays: Set<Int> = [3, 5, 7, 9, 15, 17, 19, 21]
}

// MARK: - Board

private struct NeckBoard: View {
    let scale: Scale
    let layout: FretboardLayout
    let maxFret: Int
    let boxes: [GuitarScalePosition]
    let notes: [FretPosition]
    let labels: Diagram.Labels
    @Binding var selection: Int?

    private var theory: DiagramTheory { DiagramTheory(scale: scale) }

    var body: some View {
        GeometryReader { proxy in
            let geo = FullNeckGeometry(size: proxy.size, stringCount: layout.stringCount, maxFret: maxFret)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context, geo: geo) }
                    .accessibilityHidden(true)
                // One accessibility element per box; taps go through the board gesture.
                ForEach(boxes) { box in
                    let rect = geo.boxRect(box.fretRange, inset: 0)
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel(box.accessibilityTitle)
                        .accessibilityValue(selection == box.index ? "Selected" : "")
                        .accessibilityHint(selection == box.index ? "Double-tap to show the full neck." : "Double-tap to practice this position.")
                        .accessibilityAddTraits(selection == box.index ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { toggle(box.index) }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                if let index = boxIndex(at: value.location, geo: geo) { toggle(index) }
            })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(scale.displayName) on the neck")
    }

    private func toggle(_ index: Int) {
        selection = selection == index ? nil : index
    }

    /// Box under a tap. Where boxes overlap, the one whose centre is closest wins,
    /// and the selected box wins ties so a second tap can deselect it.
    private func boxIndex(at point: CGPoint, geo: FullNeckGeometry) -> Int? {
        let hits = boxes.filter { geo.boxRect($0.fretRange, inset: 0).insetBy(dx: 0, dy: -12).contains(point) }
        return hits.min { a, b in
            let da = abs(geo.boxRect(a.fretRange, inset: 0).midX - point.x)
            let db = abs(geo.boxRect(b.fretRange, inset: 0).midX - point.x)
            if a.index == selection, abs(da - db) < geo.cellWidth * 0.5 { return true }
            if b.index == selection, abs(da - db) < geo.cellWidth * 0.5 { return false }
            return da < db
        }?.index
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, geo: FullNeckGeometry) {
        let top = geo.y(string: 0), bottom = geo.y(string: geo.stringCount - 1)
        let board = CGRect(x: geo.boardLeft, y: geo.boardTop, width: geo.boardRight - geo.boardLeft,
                           height: geo.boardBottom - geo.boardTop)
        context.fill(Path(roundedRect: board, cornerRadius: 4), with: .color(DS.surfaceInset))

        // Inlays.
        let mid = (top + bottom) / 2, r: CGFloat = max(3, min(5, geo.cellWidth * 0.12))
        for fret in 1...maxFret {
            let x = geo.x(fret: fret)
            if fret % 12 == 0 {
                for dy in [-geo.stringSpacing, geo.stringSpacing] {
                    context.fill(Path(ellipseIn: CGRect(x: x - r, y: mid + dy - r, width: 2 * r, height: 2 * r)),
                                 with: .color(DS.separatorStrong))
                }
            } else if FullNeckGeometry.inlays.contains(fret) {
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: mid - r, width: 2 * r, height: 2 * r)),
                             with: .color(DS.separatorStrong))
            }
        }

        // Fret wires; the nut is thick.
        for n in 0...maxFret {
            var p = Path()
            let x = geo.wireX(n)
            p.move(to: CGPoint(x: x, y: geo.boardTop))
            p.addLine(to: CGPoint(x: x, y: geo.boardBottom))
            context.stroke(p, with: .color(n == 0 ? DS.fg1 : DS.separatorStrong), lineWidth: n == 0 ? 5 : 1.5)
        }

        // Strings, thicker toward the low E.
        for s in 0..<geo.stringCount {
            var p = Path()
            let y = geo.y(string: s)
            p.move(to: CGPoint(x: geo.boardLeft, y: y))
            p.addLine(to: CGPoint(x: geo.boardRight, y: y))
            context.stroke(p, with: .color(DS.fg2.opacity(0.8)), lineWidth: 0.8 + CGFloat(s) * 0.3)
        }

        // Fret numbers under the board.
        let numberFont = Font.caption2.monospacedDigit()
        for fret in 1...maxFret where geo.cellWidth >= 26 || fret % 2 == 1 || fret == 12 {
            let marked = fret % 12 == 0 || FullNeckGeometry.inlays.contains(fret)
            context.draw(Text("\(fret)").font(numberFont).foregroundColor(marked ? DS.fg2 : DS.fg3),
                         at: CGPoint(x: geo.x(fret: fret), y: geo.boardBottom + 11))
        }

        // Boxes: faint when nothing is selected; the selected one solid on top.
        for (i, box) in boxes.enumerated() where box.index != selection {
            let rect = geo.boxRect(box.fretRange, inset: i.isMultiple(of: 2) ? 0 : 3)
            let path = Path(roundedRect: rect, cornerRadius: 8)
            context.stroke(path, with: .color(DS.accent.opacity(selection == nil ? 0.35 : 0.18)),
                           style: StrokeStyle(lineWidth: 1.5, dash: selection == nil ? [] : [4, 4]))
            context.draw(Text("\(box.index)").font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundColor(selection == nil ? DS.fg2 : DS.fg3),
                         at: CGPoint(x: rect.midX, y: geo.boardTop - 11))
        }
        if let selected = boxes.first(where: { $0.index == selection }) {
            let rect = geo.boxRect(selected.fretRange, inset: 0)
            let path = Path(roundedRect: rect, cornerRadius: 8)
            context.fill(path, with: .color(DS.accentSofter.opacity(0.6)))
            context.stroke(path, with: .color(DS.accent), lineWidth: 2.5)
            let label = Text("\(selected.index)").font(.caption.weight(.bold).monospacedDigit()).foregroundColor(DS.accentStrong)
            context.draw(label, at: CGPoint(x: rect.midX, y: geo.boardTop - 11))
        }

        // Notes.
        let inSelection = Set(boxes.first(where: { $0.index == selection })?.positions ?? [])
        let d = geo.dotDiameter
        for note in notes {
            guard let midi = layout.midi(at: note) else { continue }
            let center = CGPoint(x: geo.x(fret: note.fret), y: geo.y(string: note.string))
            let isRoot = theory.isRoot(midi)
            let dimmed = selection != nil && !inSelection.contains(note)
            let size = note.fret == 0 ? min(d, geo.openColumn - 4) : d
            let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            let circle = Path(ellipseIn: rect)
            let fill = isRoot ? DS.accentStrong : DS.accent
            var dot = context
            dot.opacity = dimmed ? 0.22 : 1
            if note.fret == 0 {
                dot.fill(circle, with: .color(DS.surface))
                dot.stroke(circle, with: .color(fill), lineWidth: 2)
            } else {
                dot.fill(circle, with: .color(fill))
            }
            if let text = label(for: midi), size >= 14 {
                let fontSize = max(8, min(13, size * 0.42))
                let foreground = note.fret == 0 ? DS.accentStrong : Color.white
                dot.draw(Text(text).font(.system(size: fontSize, weight: .bold, design: .rounded)).foregroundColor(foreground),
                         at: center)
            }
        }
    }

    private func label(for midi: Int) -> String? {
        switch labels {
        case .noteNames: return theory.noteName(midi)
        case .degrees: return theory.degree(midi)
        case .intervals: return theory.interval(midi, fallbackRoot: nil)
        case .fingers, .none: return nil
        }
    }
}

// MARK: - Preview

#Preview("G major and A minor pentatonic") {
    struct Demo: View {
        @State private var major: Int? = 1
        @State private var pentatonic: Int? = nil
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text("G major").font(.headline)
                    FullNeckPositionPicker(scale: Scale("G major")!, selection: $major)
                    Text("A minor pentatonic").font(.headline)
                    FullNeckPositionPicker(scale: Scale("A minor pentatonic")!, selection: $pentatonic, labels: .degrees)
                }
                .padding(16)
            }
            .background(DS.paper)
        }
    }
    return Demo()
}
