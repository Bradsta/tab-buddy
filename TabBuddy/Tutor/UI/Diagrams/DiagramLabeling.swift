//
//  DiagramLabeling.swift
//  TabBuddy
//
//  Shared label logic for diagrams: spelling a note from the diagram's scale,
//  chord, or key, and the degree / interval text for `Diagram.Labels`.
//

import Foundation

struct DiagramTheory: Hashable {
    var scale: Scale?
    var chord: Chord?
    var key: Key?

    init(diagram: Diagram) {
        scale = diagram.scale.flatMap { Scale($0) }
        chord = diagram.chord.flatMap { Chord($0) }
        key = diagram.key.flatMap { try? Key(parsing: $0) }
    }

    init(scale: Scale? = nil, chord: Chord? = nil, key: Key? = nil) {
        self.scale = scale
        self.chord = chord
        self.key = key
    }

    /// Root used for degrees and intervals: chord root, else scale root, else key tonic.
    var rootPitchClass: PitchClass? {
        chord?.root.pitchClass ?? scale?.root.pitchClass ?? key?.tonic.pitchClass
    }

    /// Spelling that fits the diagram's harmony ("G♯" in E major, "A♭" in F minor).
    func spelled(_ midi: Int) -> SpelledNote {
        let pc = PitchClass(midi)
        if let chord, let tone = (chord.tones + [chord.bass].compactMap { $0 }).first(where: { $0.pitchClass == pc }) {
            return tone
        }
        if let scale, let note = scale.notes.first(where: { $0.pitchClass == pc }) { return note }
        if let key { return key.spell(pc) }
        let flats = (scale.map { Key(tonic: $0.root, mode: .major).signature.fifths < 0 } ?? false)
        return SpelledNote.common(for: pc, preferSharps: !flats)
    }

    func noteName(_ midi: Int) -> String { spelled(midi).displayName }

    /// Scale degree ("1", "♭3") from the scale, or chord-tone degree from the chord.
    func degree(_ midi: Int) -> String? {
        let pc = PitchClass(midi)
        if let scale, let index = scale.degree(of: pc) {
            let degrees = scale.degrees
            return degrees.indices.contains(index - 1) ? Self.pretty(degrees[index - 1]) : String(index)
        }
        if let chord {
            let semis = chord.root.pitchClass.semitones(upTo: pc)
            if let interval = chord.quality.intervals.first(where: { $0.semitones % 12 == semis }) {
                return Self.pretty(ScaleType.degreeLabel(interval))
            }
        }
        return nil
    }

    /// Interval above the root: "R", "m3", "P5".
    func interval(_ midi: Int, fallbackRoot: Int?) -> String? {
        let rootPC = rootPitchClass ?? fallbackRoot.map { PitchClass($0) }
        guard let rootPC else { return nil }
        let semis = rootPC.semitones(upTo: PitchClass(midi))
        if semis == 0 { return "R" }
        if let chord, let interval = chord.quality.intervals.first(where: { $0.semitones % 12 == semis }) {
            return interval.shortName
        }
        if let scale, let interval = scale.intervals.first(where: { $0.semitones % 12 == semis }) {
            return interval.shortName
        }
        return Interval.standard(semitones: semis)?.shortName
    }

    func isRoot(_ midi: Int) -> Bool {
        guard let root = rootPitchClass else { return false }
        return PitchClass(midi) == root
    }

    static func pretty(_ degree: String) -> String {
        degree.replacingOccurrences(of: "b", with: "♭").replacingOccurrences(of: "#", with: "♯")
    }
}
