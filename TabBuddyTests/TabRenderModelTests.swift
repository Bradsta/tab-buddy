//
//  TabRenderModelTests.swift
//  TabBuddyTests
//
//  Tests for the drawn Tab Player's layout model — the MeasureMap → render
//  systems/measures/columns flattening and the playhead/active-column geometry.
//

import XCTest
@testable import TabBuddy

final class TabRenderModelTests: XCTestCase {

    /// A small two-system tab: 4 measures in 4/4 with rhythm letters, so the
    /// builder must produce columns with durations and correct global indices.
    private let sample = """
    Title: Test Piece

    E|--0--2--3--5--|--7--5--3--0--|
    B|--1--1--1--1--|--1--1--1--1--|
    G|--0--0--0--0--|--0--0--0--0--|
    D|--------------|--------------|
    A|--------------|--------------|
    E|--------------|--------------|

    E|--0--2--3--5--|--7--5--3--0--|
    B|--1--1--1--1--|--1--1--1--1--|
    G|--0--0--0--0--|--0--0--0--0--|
    D|--------------|--------------|
    A|--------------|--------------|
    E|--------------|--------------|
    """

    private func model(_ text: String) -> TabRenderModel {
        TabRenderModelBuilder.build(from: TabParser.parse(text))
    }

    func testBuildsSystemsAndMeasures() {
        let m = model(sample)
        XCTAssertFalse(m.systems.isEmpty, "expected at least one system")
        XCTAssertEqual(m.totalMeasures, m.systems.reduce(0) { $0 + $1.measureCount })
        // Global indices are contiguous and 0-based across systems.
        var expected = 0
        for sys in m.systems {
            for measure in sys.measures {
                XCTAssertEqual(measure.globalIndex, expected)
                expected += 1
            }
        }
    }

    func testColumnsCarryFretsHighEFirst() {
        let m = model(sample)
        guard let firstMeasure = m.systems.first?.measures.first,
              let firstCol = firstMeasure.columns.first else {
            return XCTFail("no columns parsed")
        }
        XCTAssertEqual(firstCol.frets.count, TabRenderModel.stringCount)
        // High E (index 0) plays fret 0, B (index 1) plays fret 1 at the first onset.
        XCTAssertEqual(firstCol.frets[0], 0)
        XCTAssertEqual(firstCol.frets[1], 1)
    }

    func testPlayheadFractionWithinSystem() {
        let m = model(sample)
        guard let sys = m.systems.first, sys.measureCount > 0 else {
            return XCTFail("no system")
        }
        // At the start of the first measure, fraction is 0.
        let atStart = m.playheadFraction(inSystem: sys, currentMeasure: sys.measures[0].globalIndex, beatFraction: 0)
        XCTAssertEqual(atStart ?? -1, 0, accuracy: 0.0001)
        // Halfway through a single-measure-wide system would be 0.5; with N
        // measures the first measure's midpoint is 0.5/N.
        let mid = m.playheadFraction(inSystem: sys, currentMeasure: sys.measures[0].globalIndex, beatFraction: 0.5)
        XCTAssertEqual(mid ?? -1, 0.5 / Double(sys.measureCount), accuracy: 0.0001)
        // A measure not in this system returns nil.
        XCTAssertNil(m.playheadFraction(inSystem: sys, currentMeasure: 9_999, beatFraction: 0))
    }

    func testActiveColumnTracksBeat() {
        let m = model(sample)
        guard let measure = m.systems.first?.measures.first, !measure.columns.isEmpty else {
            return XCTFail("no columns")
        }
        // At each onset's own position, that column becomes the active one.
        let firstPos = measure.columns[0].position
        XCTAssertEqual(TabRenderModel.activeColumn(in: measure, beatFraction: firstPos), 0)
        // Past the last onset, the active column is the final one.
        let late = TabRenderModel.activeColumn(in: measure, beatFraction: 1.0)
        XCTAssertEqual(late, measure.columns.count - 1)
        // Before the first onset there is nothing sounding yet.
        if firstPos > 0 {
            XCTAssertNil(TabRenderModel.activeColumn(in: measure, beatFraction: -0.01))
        }
    }
}
