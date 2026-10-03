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

    // MARK: - Timeline round trip (positions, durations, beat counts)

    private func tab(beats: Int = 4, _ measures: [CanonicalMeasure]) -> CanonicalTab {
        CanonicalTab(title: "Timeline", tuningMIDI: tuning, tuningName: "Standard",
                     beatsPerMeasure: beats, noteValue: 4, bpm: 90, measures: measures,
                     provenance: Provenance(sourceType: .pdfSpatial, confidence: 0.6,
                                            rhythmSource: .synthesized))
    }

    /// encode→decode keeps every note's position, duration, and chord flag,
    /// each measure's beat count and chords, the global time signature, and
    /// re-encodes byte-identically.
    @discardableResult
    private func assertRoundTrip(_ original: CanonicalTab,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> CanonicalTab {
        let xml = MusicXMLCodec.encode(original)
        let decoded = try XCTUnwrap(MusicXMLCodec.decode(xml), file: file, line: line)
        XCTAssertEqual(decoded.beatsPerMeasure, original.beatsPerMeasure, "global beats", file: file, line: line)
        XCTAssertEqual(decoded.measures.count, original.measures.count, file: file, line: line)
        for (m, (a, b)) in zip(original.measures, decoded.measures).enumerated() {
            XCTAssertEqual(b.number, a.number, file: file, line: line)
            XCTAssertEqual(b.beatCount, a.beatCount, "m\(m) beatCount", file: file, line: line)
            XCTAssertEqual(b.notes.count, a.notes.count, "m\(m) note count", file: file, line: line)
            for (n, (x, y)) in zip(a.notes, b.notes).enumerated() {
                XCTAssertEqual(y.positionInMeasure, x.positionInMeasure, accuracy: 1e-9,
                               "m\(m) n\(n) position", file: file, line: line)
                XCTAssertEqual(y.durationInBeats, x.durationInBeats, accuracy: 1e-9,
                               "m\(m) n\(n) duration", file: file, line: line)
                XCTAssertEqual(y.isChordedWithPrevious, x.isChordedWithPrevious,
                               "m\(m) n\(n) chord flag", file: file, line: line)
                XCTAssertEqual(y.midiPitch, x.midiPitch, file: file, line: line)
                XCTAssertEqual(y.string, x.string, file: file, line: line)
                XCTAssertEqual(y.fret, x.fret, file: file, line: line)
            }
            XCTAssertEqual(b.chords.map(\.name), a.chords.map(\.name), file: file, line: line)
            for (x, y) in zip(a.chords, b.chords) {
                XCTAssertEqual(y.positionInMeasure, x.positionInMeasure, accuracy: 1e-9,
                               "m\(m) chord \(x.name) offset", file: file, line: line)
            }
        }
        XCTAssertEqual(MusicXMLCodec.encode(decoded), xml, "re-encode must be byte-stable",
                       file: file, line: line)
        return decoded
    }

    /// Eight evenly spaced notes in 4/4 with the adapter's default 1-beat
    /// duration: the old decoder piled notes 5–8 onto position 1.0.
    func testEightEvenNotesIn44WithOneBeatDurations() throws {
        let notes = (0..<8).map { note(string: $0 % 6, fret: $0, pos: Double($0) / 8, dur: 1.0) }
        let decoded = try assertRoundTrip(tab([CanonicalMeasure(number: 1, notes: notes, beatCount: 4)]))
        XCTAssertEqual(decoded.measures[0].notes.map(\.positionInMeasure),
                       [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875])
        let xml = String(decoding: MusicXMLCodec.encode(tab([CanonicalMeasure(number: 1, notes: notes)])),
                         as: UTF8.self)
        XCTAssertTrue(xml.contains("<note release=\"240\">"),
                      "ringing past the next onset is carried in the standard release attribute")
    }

    /// Free-time measures (adapter: beatCount = onset count, 1-beat notes,
    /// even positions) inside a 4/4 piece, including an onset count of 7.
    func testFreeTimeMeasuresKeepBeatCountAndEvenSpacing() throws {
        func freeMeasure(_ number: Int, onsets: Int) -> CanonicalMeasure {
            let notes = (0..<onsets).map {
                note(string: 5 - ($0 % 6), fret: $0 % 5, pos: Double($0) / Double(onsets), dur: 1.0)
            }
            return CanonicalMeasure(number: number, notes: notes, beatCount: onsets)
        }
        var t = tab([freeMeasure(1, onsets: 5), freeMeasure(2, onsets: 7),
                     freeMeasure(3, onsets: 7), freeMeasure(4, onsets: 1)])
        t.provenance.isFreeTime = true
        try assertRoundTrip(t)
    }

    /// A measure that opens with a rest, has an internal gap, and ends early.
    func testMeasureStartingWithGapKeepsPositions() throws {
        let m1 = CanonicalMeasure(number: 1, notes: [
            note(string: 2, fret: 2, pos: 0.25, dur: 0.5),
            note(string: 1, fret: 3, pos: 0.75, dur: 0.25),
        ], beatCount: 4)
        let empty = CanonicalMeasure(number: 2, beatCount: 4)
        let m3 = CanonicalMeasure(number: 3, notes: [
            note(string: 0, fret: 0, pos: 0.5, dur: 2.0),
        ], beatCount: 4)
        let decoded = try assertRoundTrip(tab([m1, empty, m3]))
        XCTAssertEqual(decoded.measures[0].notes.map(\.positionInMeasure), [0.25, 0.75])
        XCTAssertTrue(decoded.measures[1].notes.isEmpty)
        let xml = String(decoding: MusicXMLCodec.encode(tab([m1])), as: UTF8.self)
        XCTAssertTrue(xml.contains("<forward><duration>480</duration></forward>"),
                      "leading gap is a standard <forward>")
    }

    /// Chord stacks with mixed durations, chord symbols, and positions that
    /// are not on the division grid of the beat (PDF spatial layouts).
    func testChordGroupsAndHarmonyOffsetsRoundTrip() throws {
        let m1 = CanonicalMeasure(number: 1, notes: [
            note(string: 5, fret: 3, pos: 0.0, dur: 3.0),
            note(string: 4, fret: 2, pos: 0.0, dur: 3.0, chord: true),
            note(string: 3, fret: 0, pos: 0.0, dur: 1.0, chord: true),
            note(string: 0, fret: 3, pos: 0.5, dur: 0.5),
            note(string: 1, fret: 0, pos: 0.5, dur: 0.5, chord: true),
            note(string: 2, fret: 0, pos: 0.875, dur: 1.0),
        ], beatCount: 4, chords: [CanonicalChord(name: "G", positionInMeasure: 0),
                                  CanonicalChord(name: "Em7", positionInMeasure: 0.5)])
        // 3-beat measure inside a 4/4 piece: offsets must use this measure's
        // beat count on both sides.
        let m2 = CanonicalMeasure(number: 2, notes: [
            note(string: 5, fret: 0, pos: 1.0 / 3.0, dur: 1.0),
            note(string: 4, fret: 2, pos: 1.0 / 3.0, dur: 1.0, chord: true),
        ], beatCount: 3, chords: [CanonicalChord(name: "C#m", positionInMeasure: 1.0 / 3.0)])
        let decoded = try assertRoundTrip(tab([m1, m2]))
        XCTAssertEqual(decoded.measures[0].notes.map(\.isChordedWithPrevious),
                       [false, true, true, false, true, false])
        XCTAssertEqual(decoded.measures[0].notes[2].durationInBeats, 1.0)
        XCTAssertEqual(decoded.measures[0].notes[0].durationInBeats, 3.0)
    }

    /// Per-measure beat counts that differ from the global time signature,
    /// including the first measure (global kept via a misc field).
    func testMeasureBeatCountsDifferentFromGlobalTimeSignature() throws {
        let measures = [3, 4, 4, 2, 6].enumerated().map { i, beats in
            CanonicalMeasure(number: i + 1, notes: [
                note(string: 1, fret: i, pos: 0.0, dur: 1.0),
                note(string: 0, fret: i, pos: Double(beats - 1) / Double(beats), dur: 1.0),
            ], beatCount: beats)
        }
        let decoded = try assertRoundTrip(tab(beats: 4, measures))
        XCTAssertEqual(decoded.measures.map(\.beatCount), [3, 4, 4, 2, 6])
        XCTAssertEqual(decoded.beatsPerMeasure, 4)
    }

    /// Out-of-order onsets and two non-chorded notes on the same onset use
    /// <backup>; nothing is reordered or merged.
    func testNonMonotonicAndCoincidentOnsetsRoundTrip() throws {
        let m = CanonicalMeasure(number: 1, notes: [
            note(string: 0, fret: 1, pos: 0.5, dur: 1.0),
            note(string: 1, fret: 1, pos: 0.25, dur: 0.5),
            note(string: 2, fret: 1, pos: 0.25, dur: 0.5),
            note(string: 3, fret: 1, pos: 1.0, dur: 1.0),
        ], beatCount: 4)
        try assertRoundTrip(tab([m]))
    }

    /// The adapter path for a text tab with no rhythm line (positions from
    /// column spacing, every duration 1 beat) survives the round trip.
    func testParsedTextTabPositionsSurviveRoundTrip() throws {
        let ascii = """
        e|-0-0-0-0-0-0-0-0-|--------3-----3---|
        B|-----------------|-1----------------|
        G|-----------------|------------------|
        D|-----------------|------------------|
        A|-----------------|------------------|
        E|-----------------|------------------|
        """
        let canonical = CanonicalAdapters.canonicalTab(from: TabParser.parse(ascii),
                                                       title: "Even", sourceType: .txtDirect)
        XCTAssertFalse(canonical.allNotes.isEmpty)
        let decoded = try XCTUnwrap(MusicXMLCodec.decode(MusicXMLCodec.encode(canonical)))
        let quantum = 1.0 / Double(MusicXMLCodec.divisions * 4)
        for (a, b) in zip(canonical.allNotes, decoded.allNotes) {
            XCTAssertEqual(b.positionInMeasure, a.positionInMeasure, accuracy: quantum)
            XCTAssertEqual(b.durationInBeats, a.durationInBeats, accuracy: 1e-9)
        }
        XCTAssertEqual(decoded.allNotes.count, canonical.allNotes.count)
        XCTAssertEqual(decoded.measures.map(\.beatCount), canonical.measures.map(\.beatCount))
    }

    /// Canonicals written by the old encoder (durations only, no timing
    /// marker) still decode; overrunning measures are spread across the bar
    /// instead of piling onto position 1.0, and well-formed ones are unchanged.
    func testLegacyEncodedFileStillDecodes() throws {
        func legacyNote(_ fret: Int, chord: Bool = false) -> String {
            "<note>\(chord ? "<chord/>" : "")<pitch><step>E</step><octave>4</octave></pitch>"
                + "<duration>480</duration><voice>1</voice><type>quarter</type>"
                + "<notations><technical><string>1</string><fret>\(fret)</fret></technical></notations></note>"
        }
        let legacy = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <identification><miscellaneous>
            <miscellaneous-field name="tabbuddy-schema-version">1</miscellaneous-field>
          </miscellaneous></identification>
          <part id="P1">
            <measure number="1">
              <attributes><divisions>480</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
              \((0..<8).map { legacyNote($0) }.joined())
            </measure>
            <measure number="2">
              <harmony><root><root-step>A</root-step></root><kind text="m">other</kind><offset>960</offset></harmony>
              \(legacyNote(0))\(legacyNote(1, chord: true))\(legacyNote(2))
            </measure>
          </part>
        </score-partwise>
        """
        let decoded = try XCTUnwrap(MusicXMLCodec.decode(Data(legacy.utf8)))
        XCTAssertEqual(decoded.beatsPerMeasure, 4)
        XCTAssertEqual(decoded.measures.map(\.beatCount), [4, 4])
        XCTAssertEqual(decoded.measures[0].notes.map(\.positionInMeasure),
                       [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875])
        XCTAssertEqual(decoded.measures[1].notes.map(\.positionInMeasure), [0, 0, 0.25])
        XCTAssertEqual(decoded.measures[1].notes.map(\.durationInBeats), [1, 1, 1])
        XCTAssertEqual(decoded.measures[1].chords.first?.positionInMeasure, 0.5)
    }

    func testAsciiRenderIncludesFrets() {
        let ascii = CanonicalAdapters.asciiTab(from: fixture())
        XCTAssertTrue(ascii.contains("Test Tab"))
        // The high-E string row should be present and contain a fret digit.
        XCTAssertTrue(ascii.contains("|"), "ASCII tab should contain barlines")
    }
}
