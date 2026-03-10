//
//  MeasureMapBuilder.swift
//  TabBuddy
//
//  Converts [ComposedNote] into a MeasureMap for playback integration
//  with the existing PlaybackCoordinator and NotePlaybackEngine.
//

import Foundation
import CoreGraphics

enum MeasureMapBuilder {

    /// Build a MeasureMap from composed notes, time signature, and BPM.
    /// Groups notes by measure and converts MIDI pitches to fret arrays.
    static func build(
        notes: [ComposedNote],
        beatsPerMeasure: Int,
        noteValue: Int,
        measureCount: Int,
        bpm: Double,
        tuningMIDI: [Int]
    ) -> MeasureMap {
        // Group notes by measure index
        var notesByMeasure: [Int: [ComposedNote]] = [:]
        for note in notes {
            notesByMeasure[note.measureIndex, default: []].append(note)
        }

        // Build measures
        var measures: [Measure] = []
        for i in 0..<measureCount {
            let composedNotes = notesByMeasure[i] ?? []

            let noteEvents: [NoteEvent] = composedNotes.map { cn in
                // Convert MIDI pitch to fret array using suggestion or override
                var frets: [Int?] = Array(repeating: nil, count: 6)

                if let string = cn.selectedString, let fret = cn.selectedFret {
                    frets[string] = fret
                } else if let suggestion = FretSuggestionEngine.suggest(
                    midiPitch: cn.midiPitch,
                    tuningMIDI: tuningMIDI
                ) {
                    frets[suggestion.string] = suggestion.fret
                }

                return NoteEvent(
                    positionInMeasure: cn.positionInMeasure,
                    durationInBeats: cn.durationInBeats,
                    frets: frets,
                    column: nil
                )
            }

            measures.append(Measure(
                rect: .zero,
                measureNumber: i + 1,
                beatCount: beatsPerMeasure,
                notes: noteEvents.isEmpty ? nil : noteEvents,
                columnRange: nil
            ))
        }

        // Wrap all measures into a single system
        let system = MeasureSystem(
            rect: .zero,
            lineRange: nil,
            measures: measures
        )

        return MeasureMap(
            bpm: bpm,
            timeSignature: (beats: beatsPerMeasure, noteValue: noteValue),
            key: nil,
            tuning: nil,
            systems: [system]
        )
    }
}
