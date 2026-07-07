//
//  FretSuggestionCard.swift
//  TabBuddy
//
//  The fret-suggestion card (DESIGN.md §6): appears after a note is placed
//  with the pencil, names the pitch, and offers every playable position as a
//  capsule — recommended (lowest reach) tinted accent, others neutral.
//  Tapping a capsule re-seats the note on that string/fret.
//

import SwiftUI

struct FretSuggestionCard: View {
    @ObservedObject var viewModel: TabMakerViewModel
    let note: ComposedNote

    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F",
                                    "F♯", "G", "G♯", "A", "A♯", "B"]

    private var pitchName: String {
        let midi = note.midiPitch
        return "\(Self.noteNames[((midi % 12) + 12) % 12])\((midi / 12) - 1)"
    }

    private var positions: [(string: Int, fret: Int)] {
        FretSuggestionEngine.allPositions(midiPitch: note.midiPitch,
                                          tuningMIDI: viewModel.cachedTuningMIDI)
            .filter { $0.fret <= 15 }
    }

    private var recommended: (string: Int, fret: Int)? {
        FretSuggestionEngine.suggest(midiPitch: note.midiPitch,
                                     tuningMIDI: viewModel.cachedTuningMIDI)
    }

    /// Open-string letter for a string index (0 = high E), from the tuning.
    private func stringName(_ index: Int) -> String {
        guard index < viewModel.cachedTuningMIDI.count else { return "?" }
        let name = Self.noteNames[((viewModel.cachedTuningMIDI[index] % 12) + 12) % 12]
        // Convention: high E lowercase to disambiguate the two E strings.
        return index == 0 ? name.lowercased() : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.fg1)
                Spacer(minLength: 12)
                Button {
                    viewModel.lastPlacedNoteID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.fg3)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            HStack(spacing: 6) {
                ForEach(positions, id: \.string) { pos in
                    positionCapsule(pos)
                }
            }
        }
        .padding(14)
        .background(DS.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .stroke(DS.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var headline: String {
        let isRecommended = recommended.map {
            $0.string == note.selectedString && $0.fret == note.selectedFret
        } ?? false
        return isRecommended ? "\(pitchName) · easiest reach here"
                             : "\(pitchName) · alternate position"
    }

    private func positionCapsule(_ pos: (string: Int, fret: Int)) -> some View {
        let isCurrent = note.selectedString == pos.string && note.selectedFret == pos.fret
        let isRecommended = recommended.map { $0 == pos } ?? false
        return Button {
            withAnimation(DS.motionFast) {
                viewModel.setPosition(noteID: note.id, string: pos.string, fret: pos.fret)
            }
        } label: {
            Text("\(pos.fret) · \(stringName(pos.string))")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(isRecommended ? AnyShapeStyle(DS.accentSoft)
                                          : AnyShapeStyle(DS.surfaceInset),
                            in: Capsule())
                .foregroundStyle(isRecommended ? DS.accentStrong : DS.fg2)
                .overlay(
                    Capsule().stroke(isCurrent ? DS.accent : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fret \(pos.fret) on \(stringName(pos.string)) string")
    }
}
