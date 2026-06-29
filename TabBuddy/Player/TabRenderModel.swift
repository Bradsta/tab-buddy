//
//  TabRenderModel.swift
//  TabBuddy
//
//  A pure, value-typed layout model derived from `MeasureMap`, consumed by the
//  drawn Tab Player (`DrawnTabSystemView` / `TabPlayerView`). It flattens the
//  parser output into systems → measures → note columns, the shape the Canvas
//  renderer draws directly. No UIKit / SwiftData dependencies, so it is trivial
//  to unit-test.
//
//  String indexing follows the project convention everywhere: index 0 = high E
//  (top staff line) … index 5 = low E (bottom line).
//

import CoreGraphics
import Foundation

// MARK: - Render model

/// Whole-piece layout: an ordered list of systems plus a global measure count.
struct TabRenderModel: Equatable {
    static let stringCount = 6
    /// Open-string MIDI notes, high-E-first. Used to place standard-notation
    /// noteheads from (string, fret). Standard tuning.
    static let openStringMIDI = [64, 59, 55, 50, 45, 40]

    var systems: [TabSystemLayout]
    var totalMeasures: Int

    /// The reference measures-per-system used to size measures consistently:
    /// a measure's width is `staffWidth / referenceMeasuresPerSystem`, so bars
    /// are the same width across systems instead of stretching to fill each
    /// line. Systems busier than the reference fall back to filling the width.
    var referenceMeasuresPerSystem: Int

    /// Tuning-letter labels top→bottom (string index 0→5).
    var stringLabels: [String]

    static let empty = TabRenderModel(systems: [], totalMeasures: 0,
                                      referenceMeasuresPerSystem: 4,
                                      stringLabels: ["e", "B", "G", "D", "A", "E"])
}

/// One staff system (a horizontal line of measures).
struct TabSystemLayout: Equatable, Identifiable {
    /// 0-based system index — stable id for `ScrollViewReader`.
    var id: Int { index }
    var index: Int
    var measures: [TabMeasureLayout]
    /// 1-based number of this system's first measure (for the gutter labels).
    var firstMeasureNumber: Int
    var measureCount: Int { measures.count }
}

/// One bar.
struct TabMeasureLayout: Equatable {
    /// 0-based index into the flattened piece (matches `PlaybackCoordinator`).
    var globalIndex: Int
    /// 1-based human measure number.
    var number: Int
    var beatCount: Int
    /// Note onsets in this measure, ascending by `position`.
    var columns: [TabColumnLayout]
    /// Optional section label (e.g. "INTRO"); reserved for the section model.
    var section: String?
}

/// One note onset (a vertical stack of fretted strings sounding together).
struct TabColumnLayout: Equatable {
    /// Fractional position within the measure (0.0 = start … 1.0 = end).
    var position: Double
    /// Per-string fret, high-E-first (length 6). nil = string not played.
    var frets: [Int?]
    /// Rhythmic value of this onset, if the source carried durations.
    var duration: RhythmDuration?

    /// The highest-sounding pitch in this column (lowest string index with a
    /// fret), as a MIDI number — used to place a standard-notation notehead.
    var melodyMIDI: Int? {
        for (s, fret) in frets.enumerated() {
            if let fret { return TabRenderModel.openStringMIDI[s] + fret }
        }
        return nil
    }
}

// MARK: - Builder

enum TabRenderModelBuilder {

    /// Build a render model from the parser's `MeasureMap`.
    static func build(from map: MeasureMap) -> TabRenderModel {
        var systems: [TabSystemLayout] = []
        var globalIndex = 0

        for (sysIdx, sys) in map.systems.enumerated() {
            var measures: [TabMeasureLayout] = []
            let firstNumber = sys.measures.first?.measureNumber ?? (globalIndex + 1)

            for measure in sys.measures {
                let columns = columns(for: measure)
                measures.append(TabMeasureLayout(
                    globalIndex: globalIndex,
                    number: measure.measureNumber,
                    beatCount: max(1, measure.beatCount),
                    columns: columns,
                    section: nil
                ))
                globalIndex += 1
            }

            systems.append(TabSystemLayout(
                index: sysIdx,
                measures: measures,
                firstMeasureNumber: firstNumber
            ))
        }

        return TabRenderModel(
            systems: systems,
            totalMeasures: globalIndex,
            referenceMeasuresPerSystem: referenceMeasureCount(systems),
            stringLabels: ["e", "B", "G", "D", "A", "E"]
        )
    }

    /// The most common measures-per-system (mode); ties and emptiness fall back
    /// to a sensible default of 4. Used to size all bars to one width.
    private static func referenceMeasureCount(_ systems: [TabSystemLayout]) -> Int {
        var counts: [Int: Int] = [:]
        for sys in systems where sys.measureCount > 0 {
            counts[sys.measureCount, default: 0] += 1
        }
        guard let mode = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key else { return 4 }
        return max(1, mode)
    }

    /// Convert a measure's `NoteEvent`s into ascending note columns.
    private static func columns(for measure: Measure) -> [TabColumnLayout] {
        guard let notes = measure.notes, !notes.isEmpty else { return [] }
        return notes
            .sorted { $0.positionInMeasure < $1.positionInMeasure }
            .map { note in
                var frets = note.frets
                if frets.count < TabRenderModel.stringCount {
                    frets.append(contentsOf:
                        Array(repeating: nil, count: TabRenderModel.stringCount - frets.count))
                }
                let duration = note.durationInBeats.map { RhythmDuration.nearest(toBeats: $0) }
                return TabColumnLayout(
                    position: min(1, max(0, note.positionInMeasure)),
                    frets: Array(frets.prefix(TabRenderModel.stringCount)),
                    duration: duration
                )
            }
    }
}

// MARK: - Playhead geometry

extension TabRenderModel {
    /// Horizontal playhead position **within a system**, as a 0–1 fraction of
    /// the staff width, given the globally-current measure + beat fraction.
    /// Returns nil when the playhead is not in this system.
    func playheadFraction(inSystem system: TabSystemLayout,
                          currentMeasure: Int,
                          beatFraction: Double) -> Double? {
        guard let local = system.measures.firstIndex(where: { $0.globalIndex == currentMeasure })
        else { return nil }
        guard system.measureCount > 0 else { return nil }
        return (Double(local) + min(1, max(0, beatFraction))) / Double(system.measureCount)
    }

    /// The index (into a measure's `columns`) that is "currently sounding" at the
    /// given beat fraction — the latest onset at or before the playhead.
    static func activeColumn(in measure: TabMeasureLayout, beatFraction: Double) -> Int? {
        var active: Int?
        for (i, col) in measure.columns.enumerated() {
            if col.position <= beatFraction + 0.0001 { active = i } else { break }
        }
        return active
    }
}
