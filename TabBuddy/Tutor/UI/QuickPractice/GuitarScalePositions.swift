//
//  GuitarScalePositions.swift
//  TabBuddy
//
//  The five box positions of a scale on a guitar neck, the ascending run
//  played in one box, and every scale note on the neck. Pure model, no UI.
//
//  Box rule (documented in `GuitarScalePositions.positions(for:)`):
//  boxes come from the scale's pentatonic skeleton played two notes per
//  string, so pentatonic scales get the five pentatonic boxes and seven-note
//  scales get the five CAGED windows (the major pentatonic boxes are the
//  CAGED shapes with the 4th and 7th left out).
//

import Foundation

struct GuitarScalePosition: Hashable, Identifiable {
    /// 1...5. Position 1 holds the lowest root on the lowest string.
    let index: Int
    /// Frets the box covers (inclusive).
    let fretRange: ClosedRange<Int>
    /// Every scale note inside `fretRange`, on every string, by string then fret.
    let positions: [FretPosition]

    var id: Int { index }

    /// "Position 2 · frets 4–8".
    var title: String { "Position \(index) · frets \(fretRange.lowerBound)–\(fretRange.upperBound)" }

    /// "Position 2, frets 4 to 8" for VoiceOver.
    var accessibilityTitle: String {
        "Position \(index), frets \(fretRange.lowerBound) to \(fretRange.upperBound)"
    }
}

enum GuitarScalePositions {
    /// The five box positions of `scale`, returned in position order (1...5).
    ///
    /// Rule:
    /// 1. Skeleton: the major pentatonic on the scale's root when the scale has
    ///    a major third, otherwise the minor pentatonic on the root. Pentatonic
    ///    scales are their own skeleton; blues uses the minor pentatonic; seven-note
    ///    scales use the pentatonic whose boxes are their CAGED windows.
    /// 2. Box k (k = 1...5) starts on the k-th skeleton note on the lowest string,
    ///    counting from the lowest root at fret 0 or above. From that note, the
    ///    next twelve skeleton pitches are laid two per string, lowest string to
    ///    highest. The box's frets are the lowest...highest fret of those twelve
    ///    notes: 4 frets (e.g. A minor pentatonic 5–8) or 5 frets (9–13).
    /// 3. A box that would need a fret below 0 moves up an octave (+12). A box that
    ///    starts above fret 12 or ends above `maxFret` moves down an octave when
    ///    that keeps it at fret 0 or above. Anything still above `maxFret` is
    ///    clipped (only possible when `maxFret` is below 15).
    /// 4. `positions` are all scale notes inside the box's frets, so a seven-note
    ///    box adds the 4th and 7th (or the scale's other notes) inside the same
    ///    window. A note that falls between two strings' windows is not stretched
    ///    for; `run(in:)` reaches one fret outside the box when the run needs it.
    ///
    /// Position numbers then climb the neck from position 1, wrapping at the
    /// octave, so position 5 may sit below position 1 after rule 3.
    static func positions(for scale: Scale, layout: FretboardLayout = .standardGuitar,
                          maxFret: Int = 15) -> [GuitarScalePosition] {
        guard layout.stringCount >= 2 else { return [] }
        let top = max(4, min(maxFret, layout.maxFret))
        let skeleton = skeletonPitchClasses(for: scale)
        let lowString = layout.stringCount - 1
        let lowOpen = layout.tuningMIDI[lowString] + layout.capo
        let rootFret = scale.root.pitchClass.value - PitchClass(lowOpen).value
        let firstRoot = lowOpen + ((rootFret % 12) + 12) % 12

        // The root and the next four skeleton pitches on the lowest string.
        let starts = ascending(from: firstRoot, pitchClasses: skeleton, count: 5)

        return starts.enumerated().map { k, start in
            let notes = ascending(from: start, pitchClasses: skeleton, count: 2 * layout.stringCount)
            var frets: [Int] = []
            for (i, midi) in notes.enumerated() {
                let string = lowString - i / 2
                frets.append(midi - layout.tuningMIDI[string] - layout.capo)
            }
            var lo = frets.min() ?? 0, hi = frets.max() ?? 0
            if lo < 0 { lo += 12; hi += 12 }
            while lo > 12 || hi > top, lo - 12 >= 0 { lo -= 12; hi -= 12 }
            hi = min(hi, top)
            let range = lo...max(lo, hi)
            return GuitarScalePosition(index: k + 1, fretRange: range,
                                       positions: layout.positions(in: scale, fretRange: range))
        }
    }

    /// Ascending run from the lowest root in the box, one fret position per pitch.
    ///
    /// Plays `octaves` octaves (at least one) and stops early, after the last
    /// pitch the box can reach, when the range runs out. Each pitch is placed on
    /// the lowest-pitched string that does not move back toward the low strings,
    /// inside the box when possible, otherwise one fret outside it.
    static func run(in position: GuitarScalePosition, scale: Scale, octaves: Int,
                    layout: FretboardLayout = .standardGuitar) -> [FretPosition] {
        let rootPC = scale.root.pitchClass
        let rootPositions = position.positions.filter { p in layout.midi(at: p).map { PitchClass($0) == rootPC } ?? false }
        guard let start = rootPositions.min(by: { (layout.midi(at: $0) ?? 0) < (layout.midi(at: $1) ?? 0) }),
              let startMIDI = layout.midi(at: start) else { return [] }

        let semitones = scale.intervals.map { $0.semitones }.sorted()
        var targets: [Int] = []
        for o in 0..<max(1, octaves) {
            targets += semitones.map { startMIDI + 12 * o + $0 }
        }
        targets.append(startMIDI + 12 * max(1, octaves))

        let box = position.fretRange
        let stretched = max(0, box.lowerBound - 1)...min(layout.maxFret, box.upperBound + 1)
        var result: [FretPosition] = [start]
        var currentString = start.string
        for midi in targets.dropFirst() {
            let inBox = layout.positions(ofMIDI: midi, fretRange: box).filter { $0.string <= currentString }
            let nearBox = layout.positions(ofMIDI: midi, fretRange: stretched).filter { $0.string <= currentString }
            // Highest string index = lowest-pitched string still allowed.
            guard let pick = inBox.max(by: { $0.string < $1.string })
                    ?? nearBox.max(by: { $0.string < $1.string }) else { break }
            result.append(pick)
            currentString = pick.string
        }
        return result
    }

    /// Every scale note on every string, frets 0...maxFret.
    static func fullNeck(scale: Scale, layout: FretboardLayout = .standardGuitar, maxFret: Int = 15) -> [FretPosition] {
        layout.positions(in: scale, fretRange: 0...max(0, min(maxFret, layout.maxFret)))
    }

    // MARK: - Helpers

    /// Pentatonic skeleton that sets the box windows (see `positions(for:)`).
    static func skeletonPitchClasses(for scale: Scale) -> [PitchClass] {
        let hasMajorThird = scale.intervals.contains { $0.semitones == 4 }
        let type: ScaleType = hasMajorThird ? .majorPentatonic : .minorPentatonic
        return Scale(root: scale.root, type: type).pitchClasses
    }

    /// `count` ascending MIDI notes from `start` (included) whose pitch classes are in `pitchClasses`.
    private static func ascending(from start: Int, pitchClasses: [PitchClass], count: Int) -> [Int] {
        let set = Set(pitchClasses)
        guard !set.isEmpty else { return [] }
        var result: [Int] = []
        var midi = start
        while result.count < count {
            if set.contains(PitchClass(midi)) { result.append(midi) }
            midi += 1
        }
        return result
    }
}
