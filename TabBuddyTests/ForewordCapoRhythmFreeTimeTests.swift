//
//  ForewordCapoRhythmFreeTimeTests.swift
//  TabBuddyTests
//
//  Generator-refinement v2: foreword (title/artist/comments) capture, capo →
//  sounding pitch, authored-rhythm detection + rendering, and free-time spacing.
//  Fixtures mirror the real `Super Mario Galaxy - Comet Observatory` (duration
//  letters + foreword + capo) and `accf city (day)` (free-time lead sheet).
//

import XCTest
@testable import TabBuddy

final class ForewordCapoRhythmFreeTimeTests: XCTestCase {

    // Comet-style: foreword + Capo 2 + 6/4 + "Q E E Q" rhythm over a bar-delimited staff.
    private let cometFixture = """
    Test Title Song
    Composed by: Koji Kondo
    Some prose notes here.
    Capo 2
     6/4
      Q  E E Q  Q  E E Q
    |---------------------|
    |---------------------|
    |----0---0-----0---0--|
    |-0---------2---------|
    |---------------------|
    |-3----3----3----3----|
    """

    // accf-style: section headers + free-time lead sheet (no time sig / rhythm / bars).
    private let accfFixture = """
    [Intro]

    e|-------7p6h7-10p9h10-12~---|
    B|-7p6h7--------------------|
    G|--------------------------|
    D|--------------------------|
    A|--------------------------|
    E|--------------------------|

    [Verse 1](Loops)

    e|---0---2---2/4\\2-2----0----|
    B|-2---2---2----------2----2-|
    G|--------------------------|
    D|--------------------------|
    A|--------------------------|
    E|--------------------------|
    """

    private func canonical(_ text: String, filename: String = "fallback") -> CanonicalTab {
        let map = TabParser.parse(text)
        return CanonicalAdapters.canonicalTab(from: map, title: filename, sourceType: .txtDirect)
    }

    // MARK: - Foreword + capo

    func testForewordCaptured() {
        let tab = canonical(cometFixture)
        XCTAssertEqual(tab.title, "Test Title Song")          // in-file, not filename
        XCTAssertEqual(tab.artist, "Koji Kondo")
        XCTAssertTrue(tab.comments?.contains("prose notes") ?? false)
    }

    func testCapoOffsetsAndPitch() throws {
        let tab = canonical(cometFixture)
        XCTAssertEqual(tab.capoOffsets, [2, 2, 2, 2, 2, 2])
        // Every note's sounding pitch = open + capo(2) + fret.
        for note in tab.allNotes {
            let s = try XCTUnwrap(note.string)
            let f = try XCTUnwrap(note.fret)
            XCTAssertEqual(note.midiPitch, tab.tuningMIDI[s] + 2 + f)
            // Spelling is consistent with the shifted pitch.
            let sp = StaffPitchMapper.staffPosition(midiPitch: note.midiPitch)
            XCTAssertEqual(note.staffStep, sp.staffStep)
            XCTAssertEqual(note.accidental, sp.accidental)
        }
    }

    func testTitleFallsBackToFilename() {
        // No usable title line (starts straight into a labeled tab).
        let text = "e|--0--2--|\nB|--1--3--|\nG|--0--0--|\nD|--2--0--|\nA|--3--2--|\nE|--x--3--|"
        let tab = canonical(text, filename: "My Song")
        XCTAssertEqual(tab.title, "My Song")
    }

    func testTitleNotStolenAsArtist() {
        let text = "By The Way\n\ne|--0--2--|\nB|--1--3--|\nG|--0--0--|\nD|--2--0--|\nA|--3--2--|\nE|--x--3--|"
        let tab = canonical(text, filename: "fallback")
        XCTAssertEqual(tab.title, "By The Way")
        XCTAssertNotEqual(tab.artist, "The Way")   // not consumed as a "by …" artist
    }

    // MARK: - Authored rhythm

    func testRhythmAuthoredWhenRhythmLinePresent() {
        XCTAssertEqual(canonical(cometFixture).provenance.rhythmSource, .authored)
    }

    func testRhythmSynthesizedWithoutRhythmLine() {
        // Same staff, rhythm line removed.
        let noRhythm = """
        Test Title Song
        Capo 2
         6/4
        |---------------------|
        |---------------------|
        |----0---0-----0---0--|
        |-0---------2---------|
        |---------------------|
        |-3----3----3----3----|
        """
        XCTAssertEqual(canonical(noRhythm).provenance.rhythmSource, .synthesized)
    }

    func testAsciiRendersRhythmRowOnlyWhenAuthored() {
        let authored = CanonicalAdapters.asciiTab(from: canonical(cometFixture))
        XCTAssertTrue(authored.contains("Q"), "authored tab should render a Q/E rhythm row")

        // A plain synthesized tab must not gain a rhythm row (byte-compatible diff surface).
        let plain = "e|--0--2--|\nB|--1--3--|\nG|--0--0--|\nD|--2--0--|\nA|--3--2--|\nE|--3--3--|"
        let synthAscii = CanonicalAdapters.asciiTab(from: canonical(plain, filename: "x"))
        XCTAssertFalse(synthAscii.contains("Q"))
    }

    // MARK: - Free-time

    func testFreeTimeDetectedAndEvenlySpaced() {
        let tab = canonical(accfFixture)
        XCTAssertTrue(tab.provenance.isFreeTime)
        // Free-time forces uniform 1.0 durations (honest "unmetered").
        for note in tab.allNotes {
            XCTAssertEqual(note.durationInBeats, 1.0)
        }
    }

    func testSectionHeadersNotCapturedAsForeword() {
        let tab = canonical(accfFixture)
        XCTAssertFalse(tab.title.contains("["))
        XCTAssertFalse(tab.comments?.contains("[Intro]") ?? false)
        XCTAssertFalse(tab.comments?.contains("[Verse") ?? false)
    }

    func testMeteredTabNotFreeTime() {
        XCTAssertFalse(canonical(cometFixture).provenance.isFreeTime)
    }

    // MARK: - Data integrity (the critical one)

    /// Provenance JSON written before `isFreeTime` existed must still decode and
    /// preserve every prior field (the call sites decode with a swallowing try?).
    func testLegacyProvenanceDecodes() throws {
        let legacy = #"{"clipped":false,"confidence":0.5,"converterVersion":1,"rhythmSource":"synthesized","sourceType":"txtDirect"}"#
        let prov = try JSONDecoder().decode(Provenance.self, from: Data(legacy.utf8))
        XCTAssertEqual(prov.sourceType, .txtDirect)
        XCTAssertEqual(prov.confidence, 0.5)
        XCTAssertEqual(prov.converterVersion, 1)
        XCTAssertEqual(prov.rhythmSource, .synthesized)
        XCTAssertFalse(prov.clipped)
        XCTAssertFalse(prov.isFreeTime)   // defaulted, not thrown
    }

    // MARK: - MusicXML round-trip with capo + multiline comments

    func testMusicXMLRoundTripWithCapoAndComments() throws {
        let midi = GuitarTuning.standard.midiNotes[5] + 2 + 0   // low-E + capo2 + open
        let sp = StaffPitchMapper.staffPosition(midiPitch: midi)
        let note = CanonicalNote(positionInMeasure: 0, durationInBeats: 1,
                                 midiPitch: midi, staffStep: sp.staffStep, accidental: sp.accidental,
                                 string: 5, fret: 0)
        let tab = CanonicalTab(title: "Capo Piece", artist: "A. Composer",
                               comments: "line one\nline two",
                               tuningMIDI: GuitarTuning.standard.midiNotes,
                               capoOffsets: [2, 2, 2, 2, 2, 2],
                               beatsPerMeasure: 6, noteValue: 4,
                               measures: [CanonicalMeasure(number: 1, notes: [note], beatCount: 6)],
                               provenance: Provenance(sourceType: .txtDirect, confidence: 0.8,
                                                      rhythmSource: .authored))
        let xml1 = MusicXMLCodec.encode(tab)
        let decoded = try XCTUnwrap(MusicXMLCodec.decode(xml1))
        XCTAssertEqual(decoded, tab)
        XCTAssertEqual(MusicXMLCodec.encode(decoded), xml1)   // byte-stable
    }

    // MARK: - Numeric beat ruler

    private let rulerFixture = """
    Gymnopedie Test
    Timing: 3/4

        1   2   3
    E|------4------|
    B|------2------|
    G|------2------|
    D|-------------|
    A|--0----------|
    E|-------------|
    """

    func testNumericBeatRulerYieldsDurations() {
        let map = TabParser.parse(rulerFixture)
        XCTAssertTrue(map.rhythmAuthored, "numeric ruler counts as authored rhythm")
        XCTAssertEqual(map.timeSignature?.beats, 3)        // "Timing: 3/4"
        XCTAssertFalse(map.isFreeTime)
        let notes = map.allMeasures.flatMap { $0.notes ?? [] }
        XCTAssertFalse(notes.isEmpty)
        XCTAssertTrue(notes.allSatisfy { $0.durationInBeats != nil },
                      "every note gets a proportional duration from the ruler")
        XCTAssertEqual(canonical(rulerFixture).provenance.rhythmSource, .authored)
    }

    // MARK: - Foreword completeness

    func testForewordKeepsDirectiveLines() {
        let text = """
        Song Title
        Tempo: 120
        Tuning: Drop D

        e|--0--2--|
        B|--1--3--|
        G|--0--0--|
        D|--2--0--|
        A|--3--2--|
        E|--x--3--|
        """
        let tab = canonical(text)
        XCTAssertEqual(tab.title, "Song Title")
        // Directive header lines are preserved verbatim (the whole human element).
        XCTAssertTrue(tab.comments?.contains("Tempo: 120") ?? false)
        XCTAssertTrue(tab.comments?.contains("Tuning: Drop D") ?? false)
    }

    func testSectionLabelCutsOffForeword() {
        let text = """
        My Song
        Composed by: Me

        Intro:

        e|--0--2--|
        B|--1--3--|
        G|--0--0--|
        D|--2--0--|
        A|--3--2--|
        E|--x--3--|
        """
        let tab = canonical(text)
        XCTAssertEqual(tab.title, "My Song")
        XCTAssertEqual(tab.artist, "Me")
        XCTAssertFalse(tab.comments?.lowercased().contains("intro") ?? false,
                       "the Intro: section label ends the foreword")
    }

    // MARK: - Title heuristics

    private let plainStaff = "\ne|--0--2--|\nB|--1--3--|\nG|--0--0--|\nD|--2--0--|\nA|--3--2--|\nE|--x--3--|"

    func testJunkLinesFallBackToFilename() {
        let text = "Tabbed from listening to the original song\nhttps://youtube.com/watch?v=abc\nFrom 0:18 - 1:44" + plainStaff
        XCTAssertEqual(canonical(text, filename: "Real Song Name").title, "Real Song Name")
    }

    func testGarbageGlyphTitleRejected() {
        let text = "Υ ∀∀" + plainStaff
        XCTAssertEqual(canonical(text, filename: "Good Filename").title, "Good Filename")
    }

    func testTitleContainingTimeWordAccepted() {
        // "Time" must not be mistaken for a time-signature directive.
        let text = "Ocarina of Time - Song of Storms" + plainStaff
        XCTAssertEqual(canonical(text, filename: "fallback").title, "Ocarina of Time - Song of Storms")
    }

    func testFilenameSupersetPreferred() {
        // Filename already contains the in-file title → keep the more specific name.
        let text = "Outset Island" + plainStaff
        XCTAssertEqual(canonical(text, filename: "Zelda Wind Waker - Outset Island").title,
                       "Zelda Wind Waker - Outset Island")
    }

    func testPDFTitleUsesFilename() {
        let map = TabParser.parse("Some In-File Title" + plainStaff)
        let tab = CanonicalAdapters.canonicalTab(from: map, title: "Filename Title", sourceType: .pdfText)
        XCTAssertEqual(tab.title, "Filename Title")
    }

    // MARK: - Tuplet brackets & phantom measures

    func testTupletBracketLineNotParsedAsMeasures() {
        let text = """
        e|--0--2--|
        B|--1--3--|
        G|--0--0--|
        D|--2--0--|
        A|--3--2--|
        E|--x--3--|

        |--3--|  |--3--|

        e|--5--7--|
        B|--5--7--|
        G|--0--0--|
        D|--0--0--|
        A|--0--0--|
        E|--0--0--|
        """
        XCTAssertEqual(TabParser.parse(text).measureCount, 2,
                       "two staves = two measures; the triplet bracket line is not a measure")
    }

    // MARK: - RhythmDuration helpers

    func testRhythmDurationNotationRoundTrips() {
        for d in RhythmDuration.allCases {
            XCTAssertEqual(RhythmDuration.from(notation: d.notation), d, "notation \(d.notation)")
            XCTAssertEqual(RhythmDuration.nearest(toBeats: d.rawValue), d)
        }
    }
}
