//
//  TutorGameRegistry.swift
//  TabBuddy
//
//  Games shelf data. The shell lists `TutorGameRegistry.entries`; a game is
//  playable once `TutorGames.destination(for:instrument:)` returns a view for
//  its id. Until then the shelf shows it as "Coming soon".
//
//  Games package (TabBuddy/Tutor/Games) hook — add one file there:
//
//      extension TutorGames {
//          @MainActor
//          static func destination(for id: String, instrument: TutorInstrument) -> AnyView? {
//              switch id {
//              case TutorGameID.fretboardHunt: return AnyView(FretboardHuntView(instrument: instrument))
//              default: return nil
//              }
//          }
//      }
//
//  The concrete method on `TutorGames` takes precedence over the default in
//  `TutorGameCatalog`. The shell presents the view full screen inside a
//  NavigationStack with a Done button; games may also use
//  `@Environment(\.dismiss)`. Game ids and titles below may be edited by the
//  games package.
//

import SwiftUI

enum TutorGameID {
    static let fretboardHunt = "fretboard-hunt"
    static let keyHunt = "key-hunt"
    static let chordChangeSprint = "chord-change-sprint"
    static let intervalDuel = "interval-duel"
    static let nameThatQuality = "name-that-quality"
    static let rhythmTapper = "rhythm-tapper"
    static let scaleRunner = "scale-runner"
    static let noteRush = "note-rush"
}

struct TutorGameEntry: Identifiable, Hashable {
    var id: String
    var title: String
    var summary: String
    var systemImage: String
    var instruments: Set<TutorInstrument>
    /// True when the game listens through the microphone.
    var usesMicrophone: Bool
}

enum TutorGameRegistry {
    static let entries: [TutorGameEntry] = [
        TutorGameEntry(id: TutorGameID.fretboardHunt, title: "Fretboard Hunt",
                       summary: "Play every C you can find in 30 seconds.",
                       systemImage: "scope", instruments: [.guitar], usesMicrophone: true),
        TutorGameEntry(id: TutorGameID.keyHunt, title: "Key Hunt",
                       summary: "Find the named note in every octave before time runs out.",
                       systemImage: "pianokeys", instruments: [.piano], usesMicrophone: true),
        TutorGameEntry(id: TutorGameID.chordChangeSprint, title: "Chord Change Sprint",
                       summary: "Switch between two chords for a minute. Count the clean changes.",
                       systemImage: "arrow.left.arrow.right", instruments: [.guitar, .piano], usesMicrophone: true),
        TutorGameEntry(id: TutorGameID.intervalDuel, title: "Interval Duel",
                       summary: "Hear an interval, then name it or play it back.",
                       systemImage: "ear", instruments: [.guitar, .piano], usesMicrophone: false),
        TutorGameEntry(id: TutorGameID.nameThatQuality, title: "Name That Quality",
                       summary: "Major, minor, or something else? Answer by ear.",
                       systemImage: "waveform", instruments: [.guitar, .piano], usesMicrophone: false),
        TutorGameEntry(id: TutorGameID.rhythmTapper, title: "Rhythm Tapper",
                       summary: "Tap or strum a written rhythm and see your timing per beat.",
                       systemImage: "metronome", instruments: [.guitar, .piano], usesMicrophone: true),
        TutorGameEntry(id: TutorGameID.scaleRunner, title: "Scale Runner",
                       summary: "Play a scale up and down; the tempo rises after clean runs.",
                       systemImage: "figure.run", instruments: [.guitar, .piano], usesMicrophone: true),
        TutorGameEntry(id: TutorGameID.noteRush, title: "Note Rush",
                       summary: "Read notes on the staff and play them. How many in a minute?",
                       systemImage: "music.note.list", instruments: [.guitar, .piano], usesMicrophone: true),
    ]

    static func entries(for instrument: TutorInstrument) -> [TutorGameEntry] {
        entries.filter { $0.instruments.contains(instrument) }
    }

    @MainActor
    static func destination(for entry: TutorGameEntry, instrument: TutorInstrument) -> AnyView? {
        guard entry.instruments.contains(instrument) else { return nil }
        return TutorGames.destination(for: entry.id, instrument: instrument)
    }

    @MainActor
    static func isAvailable(_ entry: TutorGameEntry, instrument: TutorInstrument) -> Bool {
        destination(for: entry, instrument: instrument) != nil
    }
}

/// Destination hook implemented by the games package.
@MainActor
protocol TutorGameCatalog {
    static func destination(for id: String, instrument: TutorInstrument) -> AnyView?
}

extension TutorGameCatalog {
    static func destination(for id: String, instrument: TutorInstrument) -> AnyView? { nil }
}

/// Namespace the games package extends with `destination(for:instrument:)`.
enum TutorGames: TutorGameCatalog {}
