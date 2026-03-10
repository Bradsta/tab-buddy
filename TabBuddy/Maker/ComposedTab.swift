//
//  ComposedTab.swift
//  TabBuddy
//
//  SwiftData model for a user-composed guitar tab document.
//  Notes are stored as a JSON-encoded blob of [ComposedNote].
//

import Foundation
import SwiftData

@Model
final class ComposedTab {
    @Attribute(.unique) var id: UUID = UUID()

    var title: String = "Untitled"
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    /// Time signature numerator (e.g. 4 for 4/4)
    var beatsPerMeasure: Int = 4

    /// Time signature denominator (e.g. 4 for 4/4)
    var noteValue: Int = 4

    /// Tuning preset name
    var tuningName: String = "Standard"

    /// MIDI base notes for each string (high E first), JSON-encoded [Int]
    var tuningMIDIData: Data = {
        try! JSONEncoder().encode(GuitarTuning.standard.midiNotes)
    }()

    /// Playback tempo
    var bpm: Double = 120

    /// Number of measures in the document
    var measureCount: Int = 4

    /// JSON-encoded [ComposedNote]
    var notesData: Data = {
        try! JSONEncoder().encode([ComposedNote]())
    }()

    // MARK: - Convenience accessors

    var tuningMIDI: [Int] {
        get { (try? JSONDecoder().decode([Int].self, from: tuningMIDIData)) ?? GuitarTuning.standard.midiNotes }
        set { tuningMIDIData = (try? JSONEncoder().encode(newValue)) ?? tuningMIDIData }
    }

    var notes: [ComposedNote] {
        get { (try? JSONDecoder().decode([ComposedNote].self, from: notesData)) ?? [] }
        set {
            notesData = (try? JSONEncoder().encode(newValue)) ?? notesData
            modifiedAt = Date()
        }
    }

    // MARK: - Init

    init(title: String = "Untitled",
         beatsPerMeasure: Int = 4,
         noteValue: Int = 4,
         tuning: GuitarTuning = .standard,
         bpm: Double = 120,
         measureCount: Int = 4) {
        self.title = title
        self.beatsPerMeasure = beatsPerMeasure
        self.noteValue = noteValue
        self.tuningName = tuning.name
        self.tuningMIDI = tuning.midiNotes
        self.bpm = bpm
        self.measureCount = measureCount
    }
}
