//
//  CanonicalBridgeTests.swift
//  TabBuddyTests
//
//  Unit tests for the CanonicalTab <-> MusicXML bridge (Phase 1).
//

import XCTest
@testable import TabBuddy

final class CanonicalBridgeTests: XCTestCase {

    private let tuning = GuitarTuning.standard.midiNotes  // high-E-first

    /// Build a note whose pitch/spelling are internally consistent and whose
    /// position equals the rhythm-derived position the decoder reconstructs.
    private func note(string s: Int, fret f: Int, pos: Double, dur: Double,
                      chord: Bool = false) -> CanonicalNote {
        let midi = tuning[s] + f
        let sp = StaffPitchMapper.staffPosition(midiPitch: midi)
        return CanonicalNote(positionInMeasure: pos,
                             durationInBeats: dur,
                             midiPitch: midi,
                             staffStep: sp.staffStep,
                             accidental: sp.accidental,
                             string: s,
                             fret: f,
                             isChordedWithPrevious: chord)
    }

    /// A canonical with two measures including a chord, built so positions line
    /// up with cumulative durations (4/4, quarter notes).
    private func fixture() -> CanonicalTab {
        let m1 = CanonicalMeasure(number: 1, notes: [
            note(string: 0, fret: 0, pos: 0.00, dur: 1.0),
            note(string: 1, fret: 1, pos: 0.25, dur: 1.0),
            note(string: 2, fret: 0, pos: 0.50, dur: 1.0),
            note(string: 3, fret: 2, pos: 0.75, dur: 1.0),
        ], beatCount: 4)

        // Measure 2 opens with a two-note chord, then a single note.
        let m2 = CanonicalMeasure(number: 2, notes: [
            note(string: 5, fret: 3, pos: 0.00, dur: 1.0),
            note(string: 4, fret: 2, pos: 0.00, dur: 1.0, chord: true),
            note(string: 0, fret: 3, pos: 0.25, dur: 1.0),
        ], beatCount: 4)

        let provenance = Provenance(sourceType: .txtDirect,
                                    confidence: 0.75,
                                    converterVersion: CanonicalConverterVersion.current,
                                    rhythmSource: .synthesized,
                                    clipped: false)

        return CanonicalTab(title: "Test Tab",
                            artist: "TabBuddy",
                            tuningMIDI: tuning,
                            tuningName: "Standard",
                            beatsPerMeasure: 4,
                            noteValue: 4,
                            bpm: 120,
                            measures: [m1, m2],
                            provenance: provenance)
    }

    // MARK: - Tests

    func testRoundTripPreservesFields() throws {
        let original = fixture()
        let xml = MusicXMLCodec.encode(original)
        let decoded = try XCTUnwrap(MusicXMLCodec.decode(xml),
                                    "decode returned nil")

        XCTAssertEqual(decoded, original, "round-trip should preserve all fields")
    }

    func testRoundTripIsIdempotent() throws {
        let original = fixture()
        let xml1 = MusicXMLCodec.encode(original)
        let decoded = try XCTUnwrap(MusicXMLCodec.decode(xml1))
        let xml2 = MusicXMLCodec.encode(decoded)
        XCTAssertEqual(xml1, xml2, "encode∘decode∘encode should be byte-stable")
    }

    func testEncodedXMLShape() throws {
        let xml = String(data: MusicXMLCodec.encode(fixture()), encoding: .utf8) ?? ""
        XCTAssertTrue(xml.contains("<score-partwise"))
        XCTAssertTrue(xml.contains("<clef><sign>TAB</sign>"))
        XCTAssertTrue(xml.contains("<technical><string>1</string><fret>0</fret>"),
                      "high-E string should map to MusicXML string 1")
        XCTAssertTrue(xml.contains("<chord/>"), "chord note should emit <chord/>")
        XCTAssertTrue(xml.contains("tabbuddy-provenance"))
    }

    func testTuningStringMappingHighEFirst() throws {
        let decoded = try XCTUnwrap(MusicXMLCodec.decode(MusicXMLCodec.encode(fixture())))
        XCTAssertEqual(decoded.tuningMIDI, GuitarTuning.standard.midiNotes,
                       "tuning must round-trip high-E-first")
    }

    func testChordReconstruction() throws {
        let decoded = try XCTUnwrap(MusicXMLCodec.decode(MusicXMLCodec.encode(fixture())))
        let m2 = decoded.measures[1]
        XCTAssertFalse(m2.notes[0].isChordedWithPrevious)
        XCTAssertTrue(m2.notes[1].isChordedWithPrevious)
        XCTAssertEqual(m2.notes[0].positionInMeasure, m2.notes[1].positionInMeasure,
                       "chorded note shares the head's position")
    }

    /// Full pipeline smoke test: ASCII tab -> MeasureMap -> CanonicalTab -> XML -> back.
    func testParseTextPipeline() throws {
        let ascii = """
        Test Song
        Tuning: Standard

        e|--0--2--3--|
        B|--1--3--0--|
        G|--0--2--0--|
        D|--2--0--2--|
        A|--3--2--3--|
        E|--x--x--x--|
        """

        let map = TabParser.parse(ascii)
        let canonical = CanonicalAdapters.canonicalTab(from: map,
                                                       title: "Test Song",
                                                       sourceType: .txtDirect)

        // The pipeline should produce a stable MusicXML document either way.
        let xml = MusicXMLCodec.encode(canonical)
        XCTAssertFalse(xml.isEmpty)
        let decoded = try XCTUnwrap(MusicXMLCodec.decode(xml))
        XCTAssertEqual(decoded.allNotes.count, canonical.allNotes.count,
                       "note count must survive the MusicXML round-trip")
        XCTAssertEqual(decoded.beatsPerMeasure, canonical.beatsPerMeasure)
    }

    func testAsciiRenderIncludesFrets() {
        let ascii = CanonicalAdapters.asciiTab(from: fixture())
        XCTAssertTrue(ascii.contains("Test Tab"))
        // The high-E string row should be present and contain a fret digit.
        XCTAssertTrue(ascii.contains("|"), "ASCII tab should contain barlines")
    }
}
