//
//  NoteNaming.swift
//  TabBuddy
//
//  Picks note spellings for MIDI numbers heard or shown without a written
//  spelling: key-aware when a key is known, otherwise common sharp/flat names.
//

import Foundation

enum NoteNaming {
    /// True when a key's accidentals are sharps (C major / A minor count as sharps).
    static func prefersSharps(in key: Key?) -> Bool {
        guard let key else { return true }
        return key.signature.fifths >= 0
    }

    /// Spelling of a pitch class: in `key` when given (see `Key.spell`), else common names.
    static func spelledNote(_ pc: PitchClass, in key: Key? = nil, preferSharps: Bool = true) -> SpelledNote {
        if let key { return key.spell(pc) }
        return SpelledNote.common(for: pc, preferSharps: preferSharps)
    }

    /// Spelled pitch for a MIDI number (octave follows the spelled letter, so B#3 = C4).
    static func pitch(midi: Int, in key: Key? = nil, preferSharps: Bool = true) -> Pitch {
        let note = spelledNote(PitchClass(midi), in: key, preferSharps: preferSharps)
        return Pitch(midi: midi, spelled: note) ?? Pitch(midi: midi, preferSharps: preferSharps)
    }

    /// Display name for a MIDI number: "F♯4", or "F#4" when `symbols` is false.
    static func displayName(midi: Int, in key: Key? = nil, showOctave: Bool = true,
                            symbols: Bool = true, preferSharps: Bool = true) -> String {
        let p = pitch(midi: midi, in: key, preferSharps: preferSharps)
        let note = symbols ? p.note.displayName : p.note.name
        return showOctave ? note + String(p.octave) : note
    }

    /// "C♯/D♭" for black keys, the natural name otherwise (for key-less labels).
    static func bothSpellings(_ pc: PitchClass, symbols: Bool = true) -> String {
        let sharp = SpelledNote.common(for: pc, preferSharps: true)
        let flat = SpelledNote.common(for: pc, preferSharps: false)
        let s = symbols ? sharp.displayName : sharp.name
        guard pc.isBlackKey else { return s }
        return s + "/" + (symbols ? flat.displayName : flat.name)
    }
}
