//
//  StaffPitchMapper.swift
//  TabBuddy
//
//  Pure functions mapping between staff positions, MIDI pitches,
//  and pixel coordinates on the notation staff.
//

import Foundation

enum StaffPitchMapper {

    // MARK: - Constants

    /// Vertical points per diatonic step on the staff
    static let stepHeight: CGFloat = 10

    /// The diatonic scale pattern (semitones from C within one octave)
    /// C=0, D=2, E=4, F=5, G=7, A=9, B=11
    private static let diatonicSemitones = [0, 2, 4, 5, 7, 9, 11]

    /// Staff step 0 = C4 = MIDI 60
    private static let referenceStep = 0
    private static let referenceMIDI = 60

    // MARK: - Staff Step ↔ MIDI

    /// Convert a diatonic staff step (0 = C4) to MIDI pitch, plus accidental offset.
    static func midiPitch(staffStep: Int, accidental: Int = 0) -> Int {
        let octaveOffset = staffStep >= 0
            ? staffStep / 7
            : (staffStep - 6) / 7  // floor division for negatives
        let stepInOctave = ((staffStep % 7) + 7) % 7  // always 0–6

        let midi = referenceMIDI + (octaveOffset * 12) + diatonicSemitones[stepInOctave] + accidental
        return midi
    }

    /// Convert a MIDI pitch to the nearest diatonic staff step and accidental.
    /// Prefers sharps for black keys (e.g. MIDI 61 → C#4, step 0, accidental +1).
    static func staffPosition(midiPitch: Int) -> (staffStep: Int, accidental: Int) {
        // Semitone offset from C4
        let offset = midiPitch - referenceMIDI

        let octave = offset >= 0
            ? offset / 12
            : (offset - 11) / 12  // floor division
        let semitoneInOctave = ((offset % 12) + 12) % 12

        // Map semitone to diatonic step + accidental
        // 0=C, 1=C#, 2=D, 3=D#, 4=E, 5=F, 6=F#, 7=G, 8=G#, 9=A, 10=A#, 11=B
        let mapping: [(step: Int, accidental: Int)] = [
            (0, 0),   // C
            (0, 1),   // C#
            (1, 0),   // D
            (1, 1),   // D#
            (2, 0),   // E
            (3, 0),   // F
            (3, 1),   // F#
            (4, 0),   // G
            (4, 1),   // G#
            (5, 0),   // A
            (5, 1),   // A#
            (6, 0),   // B
        ]

        let (stepInOctave, accidental) = mapping[semitoneInOctave]
        let staffStep = (octave * 7) + stepInOctave
        return (staffStep, accidental)
    }

    // MARK: - Y Coordinate ↔ Staff Step

    /// Convert a Y coordinate (relative to staff center) to a staff step.
    /// Staff center corresponds to B4 (step 6) — the middle line of treble clef.
    /// Higher Y = lower on screen = lower pitch.
    static func staffStep(fromYOffset yOffset: CGFloat, staffCenterY: CGFloat) -> Int {
        let deltaY = staffCenterY - yOffset
        return Int(round(deltaY / stepHeight)) + 6  // +6 because center line = B4 = step 6
    }

    /// Convert a staff step to Y coordinate relative to the staff top.
    /// Step 6 (B4) is at the center line.
    static func yOffset(staffStep: Int, staffCenterY: CGFloat) -> CGFloat {
        let deltaSteps = staffStep - 6  // offset from center line (B4)
        return staffCenterY - CGFloat(deltaSteps) * stepHeight
    }

    // MARK: - Note Names

    /// Human-readable note name for a MIDI pitch.
    static func noteName(midiPitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let note = names[((midiPitch % 12) + 12) % 12]
        let octave = (midiPitch / 12) - 1
        return "\(note)\(octave)"
    }

    /// Note name from staff step and accidental.
    static func noteName(staffStep: Int, accidental: Int) -> String {
        let midi = midiPitch(staffStep: staffStep, accidental: accidental)
        return noteName(midiPitch: midi)
    }

    // MARK: - Guitar Range

    /// Lowest MIDI note on a standard-tuned guitar (E2 = 40)
    static let guitarLowestMIDI = 40

    /// Highest practical MIDI note (fret 24 on high E = E6 = 88)
    static let guitarHighestMIDI = 88

    /// Clamp a MIDI pitch to the playable guitar range.
    static func clampToGuitarRange(_ midi: Int) -> Int {
        max(guitarLowestMIDI, min(guitarHighestMIDI, midi))
    }

    /// Staff step range for guitar (E2 to E6)
    static let guitarLowestStep = -8   // E2
    static let guitarHighestStep = 20  // E6
}
