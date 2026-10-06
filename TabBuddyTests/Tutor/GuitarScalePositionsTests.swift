import XCTest
@testable import TabBuddy

final class GuitarScalePositionsTests: XCTestCase {
    private let layout = FretboardLayout.standardGuitar
    private let scaleNames = ["C major", "G major", "A minor pentatonic", "E blues"]

    private func scale(_ name: String) -> Scale { Scale(name)! }

    func testFivePositionsWithinNeckAndOrdered() {
        for name in scaleNames {
            let boxes = GuitarScalePositions.positions(for: scale(name))
            XCTAssertEqual(boxes.map(\.index), [1, 2, 3, 4, 5], name)
            for box in boxes {
                XCTAssertGreaterThanOrEqual(box.fretRange.lowerBound, 0, "\(name) \(box.title)")
                XCTAssertLessThanOrEqual(box.fretRange.upperBound, 15, "\(name) \(box.title)")
                let span = box.fretRange.upperBound - box.fretRange.lowerBound + 1
                XCTAssertTrue((4...5).contains(span), "\(name) \(box.title) spans \(span) frets")
                XCTAssertTrue(box.positions.allSatisfy { box.fretRange.contains($0.fret) }, "\(name) \(box.title)")
                XCTAssertEqual(Set(box.positions.map(\.string)), Set(0..<6), "\(name) \(box.title) covers every string")
            }
            // Each box climbs from the previous one (modulo the octave wrap) and overlaps or touches it.
            for (a, b) in zip(boxes, boxes.dropFirst()) {
                let step = ((b.fretRange.lowerBound - a.fretRange.lowerBound) % 12 + 12) % 12
                XCTAssertTrue((1...5).contains(step), "\(name): \(a.title) → \(b.title)")
            }
        }
    }

    func testEachPositionContainsRoot() {
        for name in scaleNames {
            let s = scale(name)
            for box in GuitarScalePositions.positions(for: s) {
                let hasRoot = box.positions.contains { layout.midi(at: $0).map { PitchClass($0) == s.root.pitchClass } ?? false }
                XCTAssertTrue(hasRoot, "\(name) \(box.title)")
            }
        }
    }

    func testSevenNoteBoxesHoldEveryPitchClass() {
        for name in ["C major", "G major", "A natural minor", "D dorian"] {
            let s = scale(name)
            for box in GuitarScalePositions.positions(for: s) {
                let pcs = Set(box.positions.compactMap { layout.midi(at: $0) }.map { PitchClass($0) })
                XCTAssertEqual(pcs, s.pitchClassSet, "\(name) \(box.title)")
            }
        }
    }

    func testRunsAscendFromRoot() {
        for name in scaleNames + ["A natural minor"] {
            let s = scale(name)
            for box in GuitarScalePositions.positions(for: s) {
                for octaves in [1, 2] {
                    let run = GuitarScalePositions.run(in: box, scale: s, octaves: octaves)
                    let midis = run.compactMap { layout.midi(at: $0) }
                    XCTAssertEqual(midis.count, run.count)
                    guard let first = midis.first else { return XCTFail("\(name) \(box.title): empty run") }
                    XCTAssertEqual(PitchClass(first), s.root.pitchClass, "\(name) \(box.title)")
                    XCTAssertTrue(zip(midis, midis.dropFirst()).allSatisfy { $0 < $1 }, "\(name) \(box.title)")
                    XCTAssertTrue(midis.allSatisfy { s.contains(midi: $0) }, "\(name) \(box.title)")
                    // At least one full octave, one pitch per scale step.
                    XCTAssertGreaterThanOrEqual(midis.count, s.notes.count + 1, "\(name) \(box.title) \(octaves) oct")
                    XCTAssertEqual(midis[s.notes.count], first + 12, "\(name) \(box.title)")
                    XCTAssertTrue(run.allSatisfy {
                        ($0.fret >= box.fretRange.lowerBound - 1) && ($0.fret <= box.fretRange.upperBound + 1)
                    }, "\(name) \(box.title)")
                    // The run never moves back toward the low strings.
                    XCTAssertTrue(zip(run, run.dropFirst()).allSatisfy { $0.string >= $1.string }, "\(name) \(box.title)")
                }
            }
        }
    }

    func testAMinorPentatonicPositionOneIsClassicBox() {
        let s = scale("A minor pentatonic")
        let boxes = GuitarScalePositions.positions(for: s)
        XCTAssertEqual(boxes[0].fretRange, 5...8)
        XCTAssertTrue(boxes[0].positions.contains(FretPosition(guitarString: 6, fret: 5)))
        XCTAssertEqual(boxes[0].title, "Position 1 · frets 5–8")
        XCTAssertEqual(boxes.map(\.fretRange), [5...8, 7...10, 9...13, 12...15, 2...5])
        // Two notes per string in the classic box.
        XCTAssertEqual(boxes[0].positions.count, 12)
        let run = GuitarScalePositions.run(in: boxes[0], scale: s, octaves: 2)
        XCTAssertEqual(run.first, FretPosition(guitarString: 6, fret: 5))
        XCTAssertEqual(run.compactMap { layout.midi(at: $0) }.last, 69) // A4
    }

    func testCMajorPositionOneIsRootOnLowE() {
        let boxes = GuitarScalePositions.positions(for: scale("C major"))
        XCTAssertEqual(boxes[0].fretRange, 7...10)
        XCTAssertTrue(boxes[0].positions.contains(FretPosition(guitarString: 6, fret: 8)))
    }

    func testFullNeckCoversEveryScaleNote() {
        let s = scale("G major")
        let all = GuitarScalePositions.fullNeck(scale: s, maxFret: 15)
        XCTAssertEqual(all.count, all.filter { (0...15).contains($0.fret) }.count)
        XCTAssertTrue(all.compactMap { layout.midi(at: $0) }.allSatisfy { s.contains(midi: $0) })
        // 7 of 12 pitch classes over 16 frets on 6 strings.
        let expected = (0..<6).reduce(0) { sum, string in
            sum + (0...15).filter { s.contains(midi: layout.tuningMIDI[string] + $0) }.count
        }
        XCTAssertEqual(all.count, expected)
    }
}
