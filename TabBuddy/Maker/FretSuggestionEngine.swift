//
//  FretSuggestionEngine.swift
//  TabBuddy
//
//  Suggests the optimal string and fret for a given MIDI pitch,
//  preferring the lowest fret number across all playable strings.
//

import Foundation

enum FretSuggestionEngine {

    /// Maximum fret number to consider
    static let maxFret = 24

    /// Suggest the best string and fret for a MIDI pitch given a tuning.
    /// Returns nil if the pitch is unplayable in this tuning.
    ///
    /// - Parameters:
    ///   - midiPitch: The target MIDI note number
    ///   - tuningMIDI: MIDI base notes for each string (index 0 = high E, 5 = low E)
    /// - Returns: (stringIndex, fret) where stringIndex is 0-based high-E-first
    static func suggest(midiPitch: Int, tuningMIDI: [Int]) -> (string: Int, fret: Int)? {
        var bestString: Int?
        var bestFret = Int.max

        for (stringIndex, openMIDI) in tuningMIDI.enumerated() {
            let fret = midiPitch - openMIDI
            guard fret >= 0, fret <= maxFret else { continue }

            if fret < bestFret {
                bestFret = fret
                bestString = stringIndex
            }
        }

        guard let string = bestString else { return nil }
        return (string, bestFret)
    }

    /// Suggest fret positions for all strings that can play this pitch.
    /// Useful for showing alternative positions to the user.
    static func allPositions(midiPitch: Int, tuningMIDI: [Int]) -> [(string: Int, fret: Int)] {
        var positions: [(string: Int, fret: Int)] = []
        for (stringIndex, openMIDI) in tuningMIDI.enumerated() {
            let fret = midiPitch - openMIDI
            if fret >= 0, fret <= maxFret {
                positions.append((stringIndex, fret))
            }
        }
        return positions.sorted { $0.fret < $1.fret }
    }
}
