//
//  DiagramView.swift
//  TabBuddy
//
//  Dispatches a curriculum `Diagram` to its renderer and prints the caption
//  underneath. Every renderer carries an accessibility label describing the
//  notes or chord it shows.
//

import SwiftUI

struct DiagramView: View {
    let diagram: Diagram
    let instrument: TutorInstrument
    /// Pitches to emphasize (e.g. during demo playback).
    var highlightedMIDI: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
                .frame(maxWidth: .infinity)
            if let caption = diagram.caption, !caption.isEmpty {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch diagram.kind {
        case .fretboard:
            FretboardView(model: FretboardDiagramModel(diagram: diagram), instrument: instrument,
                          highlightedMIDI: highlightedMIDI)
        case .keyboard:
            KeyboardView(model: KeyboardDiagramModel(diagram: diagram), highlightedMIDI: highlightedMIDI)
        case .staff:
            MiniStaffView(model: StaffDiagramModel(diagram: diagram, instrument: instrument),
                          highlightedMIDI: highlightedMIDI)
        case .circleOfFifths:
            CircleOfFifthsView(model: CircleOfFifthsModel(diagram: diagram), instrument: instrument)
        case .rhythm:
            RhythmStripView(model: RhythmStripModel(rhythm: diagram.rhythm, caption: diagram.caption))
        case .intervalLadder:
            IntervalLadderView(model: IntervalLadderModel(diagram: diagram, instrument: instrument),
                               instrument: instrument, highlightedMIDI: highlightedMIDI)
        }
    }
}

extension Diagram {
    /// Sounding MIDI pitches the diagram shows (for highlighting and playback).
    func soundingMIDI(instrument: TutorInstrument) -> [Int] {
        switch kind {
        case .fretboard:
            return FretboardDiagramModel(diagram: self).dots.map(\.midi)
        case .keyboard:
            return KeyboardDiagramModel(diagram: self).marks.map(\.midi)
        case .staff:
            let model = StaffDiagramModel(diagram: self, instrument: instrument)
            return model.notes.map { model.soundingMIDI($0) }
        case .intervalLadder:
            return IntervalLadderModel(diagram: self, instrument: instrument).rungs.map(\.pitch.midi)
        case .circleOfFifths, .rhythm:
            return []
        }
    }

    /// A diagram for the notes of an expected event: fret dots for guitar
    /// (from the event's fret hints, or the best positions), keys for piano.
    static func forEvent(pitches: [Int], fretting: [FretPosition]?, chordName: String?,
                         instrument: TutorInstrument) -> Diagram? {
        guard !pitches.isEmpty else { return nil }
        switch instrument {
        case .guitar:
            let layout = FretboardLayout.standardGuitar
            var positions = fretting ?? []
            if positions.isEmpty {
                if let chordName, let chord = Chord(chordName), let open = ChordFingering.open(for: chord) {
                    positions = open.positions
                } else {
                    positions = pitches.compactMap { layout.bestPosition(ofMIDI: $0) }
                }
            }
            let frets = positions.map(\.fret)
            let hi = max(4, frets.max() ?? 4)
            let fretted = frets.filter { $0 > 0 }
            let lo = hi > 5 ? max(0, (fretted.min() ?? 1) - 1) : 0
            return Diagram(kind: .fretboard, chord: chordName, notes: positions.map(\.notation),
                           labels: .noteNames, fretRange: [lo, max(lo + 4, hi)])
        case .piano:
            let layout = KeyboardLayout.fitting(pitches)
            let names = pitches.map { NoteNaming.pitch(midi: $0).name }
            return Diagram(kind: .keyboard, chord: chordName, notes: names, labels: .noteNames,
                           pitchRange: [Pitch(midi: layout.lowestMIDI).name, Pitch(midi: layout.highestMIDI).name])
        }
    }
}
