//
//  MiniStaffView.swift
//  TabBuddy
//
//  Small treble / bass / grand staff with a key signature, spelled notes in
//  order left to right, accidentals, and ledger lines. Guitar staff diagrams
//  are authored at written pitch (an octave above sounding) and are drawn as
//  given. Tap a note to hear it (guitar sounds an octave below the page).
//

import SwiftUI

// MARK: - Model

enum StaffClef: String, Hashable {
    case treble, bass, grand
}

struct StaffDiagramModel: Hashable {
    struct Note: Hashable, Identifiable {
        var index: Int
        var pitch: Pitch
        /// Staff the note is drawn on (grand staff: treble for C4 and up).
        var onTreble: Bool
        /// Diatonic steps above the bottom line of its staff (0 = bottom line, 8 = top line).
        var step: Int
        /// Accidental text to print ("♯", "♭", "♮"), nil when the key signature covers it.
        var accidental: String?
        var label: String?
        var id: Int { index }
    }

    let clef: StaffClef
    let signature: KeySignature?
    let notes: [Note]
    let instrument: TutorInstrument

    init(diagram: Diagram, instrument: TutorInstrument) {
        self.instrument = instrument
        let pitches = (diagram.notes ?? []).compactMap { Pitch($0) }
        let key = diagram.key.flatMap { try? Key(parsing: $0) }
        signature = key?.signature
        let clef = Self.inferClef(diagram: diagram, instrument: instrument, pitches: pitches)
        self.clef = clef
        let sig = key?.signature
        notes = pitches.enumerated().map { i, p in
            let treble: Bool
            switch clef {
            case .treble: treble = true
            case .bass: treble = false
            case .grand: treble = p.diatonicIndex >= Pitch(.C, octave: 4).diatonicIndex
            }
            let expected = sig?.accidental(for: p.letter) ?? 0
            let accidental: String?
            if p.note.accidental == expected { accidental = nil }
            else if p.note.accidental == 0 { accidental = "♮" }
            else { accidental = SpelledNote.symbolAccidental(p.note.accidental) }
            let label = diagram.labels == .none ? nil : p.note.displayName
            return Note(index: i, pitch: p, onTreble: treble, step: Self.step(of: p, onTreble: treble),
                        accidental: accidental, label: label)
        }
    }

    /// Clef from the caption ("Treble clef", "Bass clef", "Grand staff"), then the
    /// visible range, then the notes, then the instrument.
    static func inferClef(diagram: Diagram, instrument: TutorInstrument, pitches: [Pitch]) -> StaffClef {
        let caption = (diagram.caption ?? "").lowercased()
        if caption.contains("grand staff") || caption.contains("grand-staff") { return .grand }
        if caption.contains("bass clef") || caption.contains("bass staff") { return .bass }
        if caption.contains("treble clef") || caption.contains("treble staff") { return .treble }
        var range: (Int, Int)?
        if let r = diagram.pitchRange, r.count == 2, let lo = Pitch(r[0]), let hi = Pitch(r[1]) {
            range = (min(lo.midi, hi.midi), max(lo.midi, hi.midi))
        } else if let lo = pitches.map(\.midi).min(), let hi = pitches.map(\.midi).max() {
            range = (lo, hi)
        }
        if let (lo, hi) = range {
            if instrument == .guitar { return .treble }
            if lo <= 55 && hi >= 67 { return .grand }
            if hi <= 62 { return .bass }
            return .treble
        }
        return instrument == .piano && pitches.isEmpty && diagram.key == nil ? .grand : .treble
    }

    static func bottomLine(treble: Bool) -> Pitch { treble ? Pitch(.E, octave: 4) : Pitch(.G, octave: 2) }

    static func step(of pitch: Pitch, onTreble: Bool) -> Int {
        pitch.diatonicIndex - bottomLine(treble: onTreble).diatonicIndex
    }

    /// Ledger-line steps needed for a note at `step` (even steps outside 0...8).
    static func ledgerSteps(for step: Int) -> [Int] {
        if step <= -2 { return stride(from: -2, through: step, by: -2).map { $0 } }
        if step >= 10 { return stride(from: 10, through: step, by: 2).map { $0 } }
        return []
    }

    /// Key-signature accidentals as staff steps (standard placement).
    static func signatureSteps(_ signature: KeySignature, treble: Bool) -> [Int] {
        // Written pitches for the standard order, treble clef.
        let sharpsTreble: [Pitch] = [Pitch(.F, octave: 5), Pitch(.C, octave: 5), Pitch(.G, octave: 5), Pitch(.D, octave: 5),
                                     Pitch(.A, octave: 4), Pitch(.E, octave: 5), Pitch(.B, octave: 4)]
        let flatsTreble: [Pitch] = [Pitch(.B, octave: 4), Pitch(.E, octave: 5), Pitch(.A, octave: 4), Pitch(.D, octave: 5),
                                    Pitch(.G, octave: 4), Pitch(.C, octave: 5), Pitch(.F, octave: 4)]
        let list = signature.fifths >= 0 ? sharpsTreble : flatsTreble
        let count = min(7, abs(signature.fifths))
        // The same letters sit two steps lower relative to the bass staff lines.
        return list.prefix(count).map { step(of: $0, onTreble: true) - (treble ? 0 : 2) }
    }

    /// MIDI to sound for a note: guitar music sounds an octave below the page.
    func soundingMIDI(_ note: Note) -> Int {
        instrument == .guitar ? note.pitch.midi - 12 : note.pitch.midi
    }

    var accessibilityLabel: String {
        var parts: [String] = []
        parts.append(clef == .grand ? "Grand staff" : clef == .treble ? "Treble clef staff" : "Bass clef staff")
        if let signature { parts.append("key signature \(signature.description)") }
        if !notes.isEmpty { parts.append("notes " + notes.map { $0.pitch.displayName }.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Geometry

struct StaffGeometry {
    var size: CGSize
    var clef: StaffClef
    /// Half the distance between staff lines.
    var halfSpace: CGFloat

    init(size: CGSize, clef: StaffClef) {
        self.size = size
        self.clef = clef
        let lines: CGFloat = clef == .grand ? 22 : 16   // steps of vertical room incl. ledger space
        halfSpace = min(9, size.height / lines)
    }

    /// y of the bottom line of a staff.
    func bottomY(treble: Bool) -> CGFloat {
        let mid = size.height / 2
        switch clef {
        case .treble, .bass: return mid + 4 * halfSpace
        case .grand: return treble ? mid - 2 * halfSpace : mid + 10 * halfSpace
        }
    }

    func y(step: Int, treble: Bool) -> CGFloat { bottomY(treble: treble) - CGFloat(step) * halfSpace }

    var staves: [Bool] {
        switch clef {
        case .treble: return [true]
        case .bass: return [false]
        case .grand: return [true, false]
        }
    }
}

// MARK: - View

struct MiniStaffView: View {
    let model: StaffDiagramModel
    var highlightedMIDI: Set<Int> = []
    @Environment(\.tutorDiagramTapEnabled) private var tapEnabled

    var body: some View {
        GeometryReader { proxy in
            let geo = StaffGeometry(size: proxy.size, clef: model.clef)
            let layout = columns(width: proxy.size.width, geo: geo)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawStaves(&context, size: size, geo: geo)
                    drawClefs(&context, geo: geo)
                    drawSignature(&context, geo: geo, x: layout.signatureX)
                    for note in model.notes {
                        drawNote(&context, note: note, x: layout.noteX(note.index), geo: geo)
                    }
                }
                ForEach(model.notes) { note in
                    if let label = note.label {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isLit(note) ? DS.accentStrong : DS.fg2)
                            .position(x: layout.noteX(note.index), y: proxy.size.height - 10)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard tapEnabled, !model.notes.isEmpty else { return }
                let nearest = model.notes.min { abs(layout.noteX($0.index) - value.location.x) < abs(layout.noteX($1.index) - value.location.x) }
                if let nearest {
                    TutorSequencePlayer.shared.playPitches([model.soundingMIDI(nearest)], instrument: model.instrument)
                }
            })
        }
        .frame(height: model.clef == .grand ? 230 : 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
    }

    private func isLit(_ note: StaffDiagramModel.Note) -> Bool {
        highlightedMIDI.contains(model.soundingMIDI(note)) || highlightedMIDI.contains(note.pitch.midi)
    }

    private struct Columns {
        var signatureX: CGFloat
        var firstNoteX: CGFloat
        var spacing: CGFloat
        func noteX(_ i: Int) -> CGFloat { firstNoteX + CGFloat(i) * spacing }
    }

    private func columns(width: CGFloat, geo: StaffGeometry) -> Columns {
        let clefWidth = geo.halfSpace * 7
        let sigCount = CGFloat(min(7, abs(model.signature?.fifths ?? 0)))
        let signatureX = 12 + clefWidth
        let sigWidth = sigCount * geo.halfSpace * 2.2
        let start = signatureX + sigWidth + geo.halfSpace * 4
        let count = CGFloat(max(1, model.notes.count))
        let available = max(40, width - start - 20)
        let spacing = min(geo.halfSpace * 9, available / count)
        return Columns(signatureX: signatureX, firstNoteX: start + spacing / 2, spacing: spacing)
    }

    private func drawStaves(_ context: inout GraphicsContext, size: CGSize, geo: StaffGeometry) {
        for treble in geo.staves {
            for line in 0..<5 {
                var p = Path()
                let y = geo.y(step: line * 2, treble: treble)
                p.move(to: CGPoint(x: 8, y: y))
                p.addLine(to: CGPoint(x: size.width - 8, y: y))
                context.stroke(p, with: .color(DS.fg2), lineWidth: 1)
            }
        }
        if model.clef == .grand {
            var brace = Path()
            brace.move(to: CGPoint(x: 8, y: geo.y(step: 8, treble: true)))
            brace.addLine(to: CGPoint(x: 8, y: geo.y(step: 0, treble: false)))
            context.stroke(brace, with: .color(DS.fg2), lineWidth: 2)
        }
    }

    private func drawClefs(_ context: inout GraphicsContext, geo: StaffGeometry) {
        for treble in geo.staves {
            // Treble clef curls around G4 (step 2); bass clef dots surround F3 (step 6).
            let glyph = treble ? "\u{1D11E}" : "\u{1D122}"
            let size = treble ? geo.halfSpace * 13 : geo.halfSpace * 7.5
            let y = treble ? geo.y(step: 3, treble: true) : geo.y(step: 5, treble: false)
            let text = Text(glyph).font(.system(size: size)).foregroundColor(DS.fg1)
            context.draw(text, at: CGPoint(x: 12 + geo.halfSpace * 3, y: y), anchor: .center)
        }
    }

    private func drawSignature(_ context: inout GraphicsContext, geo: StaffGeometry, x: CGFloat) {
        guard let sig = model.signature, sig.fifths != 0 else { return }
        let glyph = sig.fifths > 0 ? "♯" : "♭"
        for treble in geo.staves {
            for (i, step) in StaffDiagramModel.signatureSteps(sig, treble: treble).enumerated() {
                let text = Text(glyph).font(.system(size: geo.halfSpace * 3.2, weight: .medium)).foregroundColor(DS.fg1)
                let pos = CGPoint(x: x + CGFloat(i) * geo.halfSpace * 2.2, y: geo.y(step: step, treble: treble) - (sig.fifths < 0 ? geo.halfSpace * 0.6 : 0))
                context.draw(text, at: pos, anchor: .center)
            }
        }
    }

    private func drawNote(_ context: inout GraphicsContext, note: StaffDiagramModel.Note, x: CGFloat, geo: StaffGeometry) {
        let color = isLit(note) ? DS.accentStrong : DS.fg1
        let y = geo.y(step: note.step, treble: note.onTreble)
        // Ledger lines.
        for ledger in StaffDiagramModel.ledgerSteps(for: note.step) {
            var p = Path()
            let ly = geo.y(step: ledger, treble: note.onTreble)
            p.move(to: CGPoint(x: x - geo.halfSpace * 2.1, y: ly))
            p.addLine(to: CGPoint(x: x + geo.halfSpace * 2.1, y: ly))
            context.stroke(p, with: .color(DS.fg2), lineWidth: 1)
        }
        // Notehead: a tilted filled oval.
        let w = geo.halfSpace * 2.7, h = geo.halfSpace * 2
        var head = Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        head = head.applying(CGAffineTransform(rotationAngle: -0.35)).applying(CGAffineTransform(translationX: x, y: y))
        context.fill(head, with: .color(color))
        if isLit(note) {
            context.stroke(Path(ellipseIn: CGRect(x: x - w * 0.8, y: y - w * 0.8, width: w * 1.6, height: w * 1.6)),
                           with: .color(DS.accent.opacity(0.5)), lineWidth: 2)
        }
        // Stem: up below the middle line, down above it.
        var stem = Path()
        if note.step < 4 {
            stem.move(to: CGPoint(x: x + w / 2 - 1, y: y))
            stem.addLine(to: CGPoint(x: x + w / 2 - 1, y: y - geo.halfSpace * 7))
        } else {
            stem.move(to: CGPoint(x: x - w / 2 + 1, y: y))
            stem.addLine(to: CGPoint(x: x - w / 2 + 1, y: y + geo.halfSpace * 7))
        }
        context.stroke(stem, with: .color(color), lineWidth: 1.4)
        if let acc = note.accidental {
            let text = Text(acc).font(.system(size: geo.halfSpace * 3, weight: .medium)).foregroundColor(color)
            context.draw(text, at: CGPoint(x: x - w * 1.25, y: y - (acc == "♭" ? geo.halfSpace * 0.5 : 0)), anchor: .center)
        }
    }
}
