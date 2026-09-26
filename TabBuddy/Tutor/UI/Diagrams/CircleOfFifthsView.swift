//
//  CircleOfFifthsView.swift
//  TabBuddy
//
//  Major keys around the outside, relative minors inside, C at the top and
//  sharps clockwise. The diagram's `key` is highlighted with its two
//  neighbours (IV and V) tinted. Tap a key to hear its tonic chord.
//

import SwiftUI

struct CircleOfFifthsModel: Hashable {
    static let majors = ["C", "G", "D", "A", "E", "B", "F♯/G♭", "D♭", "A♭", "E♭", "B♭", "F"]
    static let minors = ["Am", "Em", "Bm", "F♯m", "C♯m", "G♯m", "E♭m", "B♭m", "Fm", "Cm", "Gm", "Dm"]
    /// Tonic MIDI (octave 4 roots) for the majors, clockwise from C.
    static let majorRoots = [60, 67, 62, 69, 64, 71, 66, 61, 68, 63, 70, 65]

    /// Index 0...11 clockwise from C of the highlighted key, and whether it is minor.
    let highlighted: Int?
    let highlightMinor: Bool
    let keyName: String?

    init(diagram: Diagram) {
        if let text = diagram.key, let key = try? Key(parsing: text) {
            let fifths = key.mode == .major ? key.signature.fifths : key.relative.signature.fifths
            highlighted = ((fifths % 12) + 12) % 12
            highlightMinor = key.mode == .minor
            keyName = key.displayName
        } else {
            highlighted = nil
            highlightMinor = false
            keyName = nil
        }
    }

    /// Clockwise index from C for a count of fifths (sharps positive).
    static func index(forFifths fifths: Int) -> Int { ((fifths % 12) + 12) % 12 }

    /// Angle (radians, 0 = top, clockwise) of segment `i`.
    static func angle(_ i: Int) -> Double { Double(i) / 12 * 2 * .pi }

    func isNeighbour(_ i: Int) -> Bool {
        guard let h = highlighted else { return false }
        return (i - h + 12) % 12 == 1 || (h - i + 12) % 12 == 1
    }

    var accessibilityLabel: String {
        var text = "Circle of fifths: C at the top, sharps added clockwise, flats counterclockwise."
        if let keyName, let h = highlighted {
            text += " \(keyName) highlighted, between \(Self.majors[(h + 11) % 12]) and \(Self.majors[(h + 1) % 12])."
        }
        return text
    }
}

struct CircleOfFifthsView: View {
    let model: CircleOfFifthsModel
    var instrument: TutorInstrument = .piano
    @Environment(\.tutorDiagramTapEnabled) private var tapEnabled

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let outer = side / 2 - 4
            let inner = outer * 0.64
            let core = outer * 0.34
            ZStack {
                Canvas { context, _ in
                    for i in 0..<12 {
                        let a0 = CircleOfFifthsModel.angle(i) - .pi / 12 - .pi / 2
                        let a1 = a0 + .pi / 6
                        context.fill(ring(center, inner, outer, a0, a1), with: .color(fill(i, minor: false)))
                        context.stroke(ring(center, inner, outer, a0, a1), with: .color(DS.paper), lineWidth: 2)
                        context.fill(ring(center, core, inner, a0, a1), with: .color(fill(i, minor: true)))
                        context.stroke(ring(center, core, inner, a0, a1), with: .color(DS.paper), lineWidth: 2)
                    }
                }
                ForEach(0..<12, id: \.self) { i in
                    let a = CircleOfFifthsModel.angle(i) - .pi / 2
                    let rMajor = (inner + outer) / 2, rMinor = (core + inner) / 2
                    Text(CircleOfFifthsModel.majors[i])
                        .font(.system(size: max(11, side * (i == 6 ? 0.034 : 0.05)), weight: .bold, design: .rounded))
                        .foregroundStyle(textColor(i, minor: false))
                        .position(x: center.x + rMajor * cos(a), y: center.y + rMajor * sin(a))
                    Text(CircleOfFifthsModel.minors[i])
                        .font(.system(size: max(10, side * 0.036), weight: .semibold, design: .rounded))
                        .foregroundStyle(textColor(i, minor: true))
                        .position(x: center.x + rMinor * cos(a), y: center.y + rMinor * sin(a))
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard tapEnabled else { return }
                let dx = value.location.x - center.x, dy = value.location.y - center.y
                let r = (dx * dx + dy * dy).squareRoot()
                guard r > core, r < outer else { return }
                var angle = atan2(dy, dx) + .pi / 2 + .pi / 12
                if angle < 0 { angle += 2 * .pi }
                let i = Int(angle / (2 * .pi) * 12) % 12
                let root = CircleOfFifthsModel.majorRoots[i]
                let pitches = r >= inner ? [root, root + 4, root + 7] : [root - 3, root, root + 4]
                TutorSequencePlayer.shared.playPitches(pitches, instrument: instrument)
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 440, maxHeight: 440)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
    }

    private func ring(_ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        p.addArc(center: c, radius: r1, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        p.addArc(center: c, radius: r0, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
        p.closeSubpath()
        return p
    }

    private func fill(_ i: Int, minor: Bool) -> Color {
        if model.highlighted == i {
            return minor == model.highlightMinor ? DS.accent : DS.accentSoft
        }
        if model.isNeighbour(i) { return minor ? DS.accentSofter : DS.accentSoft.opacity(0.6) }
        return minor ? DS.surfaceInset : DS.surface
    }

    private func textColor(_ i: Int, minor: Bool) -> Color {
        if model.highlighted == i && minor == model.highlightMinor { return .white }
        return minor ? DS.fg2 : DS.fg1
    }
}
