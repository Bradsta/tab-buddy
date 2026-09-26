//
//  IntervalLadderView.swift
//  TabBuddy
//
//  Notes stacked from the root upward with the interval each forms above the
//  root and its size in half steps. Tap a rung to hear the root and that note.
//

import SwiftUI

struct IntervalLadderModel: Hashable {
    struct Rung: Hashable, Identifiable {
        var pitch: Pitch
        var intervalName: String
        var shortName: String
        var semitones: Int
        var id: Int { pitch.midi * 10 + pitch.diatonicIndex % 10 }
    }

    let root: Pitch?
    /// Low to high.
    let rungs: [Rung]

    init(diagram: Diagram, instrument: TutorInstrument) {
        var pitches = (diagram.notes ?? []).compactMap { Pitch($0) }
        if pitches.isEmpty, let scale = diagram.scale.flatMap({ Scale($0) }) {
            let octave = instrument == .guitar ? 3 : 4
            pitches = scale.pitches(startOctave: octave, octaves: 1)
        }
        pitches.sort()
        root = pitches.first
        guard let root = pitches.first else { rungs = []; return }
        rungs = pitches.map { p in
            let semis = p.midi - root.midi
            let interval = Interval.between(root, p)
            let name: String
            if semis == 0 { name = "Root (unison)" }
            else if let interval { name = interval.name.prefix(1).uppercased() + interval.name.dropFirst() }
            else { name = "\(semis) half steps" }
            return Rung(pitch: p, intervalName: name, shortName: semis == 0 ? "R" : (interval?.shortName ?? "\(semis)"),
                        semitones: semis)
        }
    }

    var maxSemitones: Int { max(1, rungs.map(\.semitones).max() ?? 12) }

    var accessibilityLabel: String {
        "Interval ladder: " + rungs.map { "\($0.pitch.displayName), \($0.intervalName), \($0.semitones) half steps" }
            .joined(separator: "; ")
    }
}

struct IntervalLadderView: View {
    let model: IntervalLadderModel
    var instrument: TutorInstrument = .piano
    var highlightedMIDI: Set<Int> = []
    @Environment(\.tutorDiagramTapEnabled) private var tapEnabled

    var body: some View {
        VStack(spacing: 4) {
            ForEach(model.rungs.reversed()) { rung in
                Button {
                    guard tapEnabled, let root = model.root else { return }
                    let seq = PlaybackSequence(notes: [PlaybackNote(pitches: [root.midi], startBeat: 0, durationBeats: 1),
                                                       PlaybackNote(pitches: [rung.pitch.midi], startBeat: 1, durationBeats: 1.5)],
                                               bpm: 72, style: .sequence)
                    TutorSequencePlayer.shared.play(seq, instrument: instrument, onStep: nil, completion: nil)
                } label: {
                    row(rung)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(rung.pitch.displayName): \(rung.intervalName), \(rung.semitones) half steps")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ rung: IntervalLadderModel.Rung) -> some View {
        let lit = highlightedMIDI.contains(rung.pitch.midi)
        return HStack(spacing: 12) {
            Text(rung.pitch.displayName)
                .font(.headline.monospacedDigit())
                .frame(width: 52, alignment: .leading)
            Text(rung.shortName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(rung.semitones == 0 ? .white : DS.accentStrong)
                .frame(width: 40, height: 28)
                .background(RoundedRectangle(cornerRadius: DS.radiusChip).fill(rung.semitones == 0 ? DS.accentStrong : DS.accentSofter))
            Text(rung.intervalName)
                .font(.subheadline)
                .foregroundStyle(DS.fg2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            GeometryReader { proxy in
                Capsule().fill(lit ? DS.accentStrong : DS.accent.opacity(0.5))
                    .frame(width: max(6, proxy.size.width * CGFloat(rung.semitones) / CGFloat(model.maxSemitones)))
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 90, height: 8)
            Text("\(rung.semitones)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(DS.fg3)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: DS.radiusControl).fill(lit ? DS.accentSoft : DS.surfaceInset))
    }
}
