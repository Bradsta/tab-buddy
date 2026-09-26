//
//  KeyboardLayout.swift
//  TabBuddy
//
//  Piano key geometry by MIDI number. The default range is the 88-key piano
//  (A0 = 21 … C8 = 108). Horizontal positions are in white-key widths.
//

import Foundation

struct KeyboardLayout: Codable, Hashable, Sendable {
    var lowestMIDI: Int
    var highestMIDI: Int

    init(lowestMIDI: Int = 21, highestMIDI: Int = 108) {
        self.lowestMIDI = min(lowestMIDI, highestMIDI)
        self.highestMIDI = max(lowestMIDI, highestMIDI)
    }

    static let piano88 = KeyboardLayout()
    static let middleC = 60

    /// A view spanning whole octaves C…B: `octaves` starting at `startOctave` (C4 = 60).
    static func octaves(from startOctave: Int, count octaves: Int = 1) -> KeyboardLayout {
        let low = (startOctave + 1) * 12
        return KeyboardLayout(lowestMIDI: low, highestMIDI: low + 12 * max(1, octaves) - 1)
    }

    /// The smallest whole-octave view (C…B) containing every given MIDI note,
    /// clamped to the 88-key range. Defaults to the octave of middle C.
    static func fitting(_ midi: [Int]) -> KeyboardLayout {
        guard let lo = midi.min(), let hi = midi.max() else { return octaves(from: 4) }
        let low = max(21, (lo / 12) * 12)
        let high = min(108, (hi / 12) * 12 + 11)
        return KeyboardLayout(lowestMIDI: low, highestMIDI: high)
    }

    var range: ClosedRange<Int> { lowestMIDI...highestMIDI }
    var keyCount: Int { highestMIDI - lowestMIDI + 1 }

    func contains(_ midi: Int) -> Bool { range.contains(midi) }

    static func isBlack(_ midi: Int) -> Bool { PitchClass(midi).isBlackKey }
    func isBlack(_ midi: Int) -> Bool { Self.isBlack(midi) }

    /// White keys in range, low to high.
    var whiteKeys: [Int] { range.filter { !Self.isBlack($0) } }
    var blackKeys: [Int] { range.filter { Self.isBlack($0) } }
    var whiteKeyCount: Int { whiteKeys.count }

    /// Absolute white-key number (C-1 = 0, D-1 = 1, …); for black keys, the white key below.
    static func absoluteWhiteIndex(_ midi: Int) -> Int {
        let octave = Int((Double(midi) / 12).rounded(.down))
        let pc = PitchClass(midi).value
        let whiteInOctave = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6][pc]
        return octave * 7 + whiteInOctave
    }

    /// Index among this layout's white keys (0 = leftmost), or nil for black keys
    /// and notes outside the range.
    func whiteKeyIndex(of midi: Int) -> Int? {
        guard contains(midi), !Self.isBlack(midi) else { return nil }
        return Self.absoluteWhiteIndex(midi) - firstWhiteAbsoluteIndex
    }

    private var firstWhiteAbsoluteIndex: Int {
        let first = range.first { !Self.isBlack($0) } ?? lowestMIDI
        return Self.absoluteWhiteIndex(first)
    }

    /// Horizontal center of a key in white-key widths from the left edge.
    /// White keys are centered at i + 0.5; black keys sit on the boundary
    /// between their neighbouring white keys.
    func keyCenter(of midi: Int) -> Double {
        let index = Double(Self.absoluteWhiteIndex(midi) - firstWhiteAbsoluteIndex)
        return Self.isBlack(midi) ? index + 1 : index + 0.5
    }
}
