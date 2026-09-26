import XCTest
@testable import TabBuddy

final class TheoryTests: XCTestCase {

    private func names(_ notes: [SpelledNote]) -> String { notes.map(\.name).joined(separator: " ") }

    // MARK: - Pitch

    func testPitchParsingAndMIDI() throws {
        XCTAssertEqual(try Pitch(parsing: "C4").midi, 60)
        XCTAssertEqual(try Pitch(parsing: "E2").midi, 40)
        XCTAssertEqual(try Pitch(parsing: "C#4").midi, 61)
        XCTAssertEqual(try Pitch(parsing: "Bb3").midi, 58)
        XCTAssertEqual(try Pitch(parsing: "B♭3").midi, 58)
        XCTAssertEqual(try Pitch(parsing: "A0").midi, 21)
        XCTAssertEqual(try Pitch(parsing: "C8").midi, 108)
        XCTAssertEqual(try Pitch(parsing: "Cb4").midi, 59)
        XCTAssertEqual(try Pitch(parsing: "B#3").midi, 60)
        XCTAssertEqual(try Pitch(parsing: "Fx4").midi, 67)
        XCTAssertEqual(try Pitch(parsing: "C-1").midi, 0)
        XCTAssertEqual(try Pitch(parsing: " e2 ").name, "E2")
        XCTAssertNil(Pitch("E"))
        XCTAssertNil(Pitch("H2"))
        XCTAssertNil(Pitch("C#b#4"))
        XCTAssertThrowsError(try Pitch(parsing: "E")) { error in
            XCTAssertTrue((error as? TheoryParseError)?.description.contains("octave") == true)
        }
        XCTAssertNotEqual(Pitch("C#4"), Pitch("Db4"))
        XCTAssertTrue(Pitch("C#4")!.isEnharmonic(with: Pitch("Db4")!))
    }

    func testPitchFromMIDIAndFrequency() {
        XCTAssertEqual(Pitch(midi: 61).name, "C#4")
        XCTAssertEqual(Pitch(midi: 61, preferSharps: false).name, "Db4")
        XCTAssertEqual(Pitch(midi: 40).name, "E2")
        XCTAssertEqual(Pitch(midi: 59, spelled: SpelledNote("Cb")!)?.name, "Cb4")
        XCTAssertEqual(Pitch(midi: 60, spelled: SpelledNote("B#")!)?.name, "B#3")
        XCTAssertNil(Pitch(midi: 60, spelled: .D))
        XCTAssertEqual(Pitch("A4")!.frequency, 440, accuracy: 1e-9)
        XCTAssertEqual(Pitch("E2")!.frequency, 82.4069, accuracy: 1e-3)
        XCTAssertEqual(Pitch("C4")!.frequency, 261.6256, accuracy: 1e-3)
        XCTAssertEqual(Pitch.midiValue(frequency: 440), 69, accuracy: 1e-9)
        for midi in 0...127 {
            XCTAssertEqual(Pitch(midi: midi).midi, midi)
            XCTAssertEqual(Pitch(midi: midi, preferSharps: false).midi, midi)
            XCTAssertEqual(Pitch(Pitch(midi: midi).name)?.midi, midi)
        }
    }

    func testSpelledNoteParsing() {
        XCTAssertEqual(SpelledNote("F#"), SpelledNote(.F, 1))
        XCTAssertEqual(SpelledNote("f#"), SpelledNote(.F, 1))
        XCTAssertEqual(SpelledNote("Bb"), SpelledNote(.B, -1))
        XCTAssertEqual(SpelledNote("bb"), SpelledNote(.B, -1))
        XCTAssertEqual(SpelledNote("Cx"), SpelledNote(.C, 2))
        XCTAssertEqual(SpelledNote("C##"), SpelledNote(.C, 2))
        XCTAssertEqual(SpelledNote("Ebb"), SpelledNote(.E, -2))
        XCTAssertEqual(SpelledNote("F sharp"), SpelledNote(.F, 1))
        XCTAssertEqual(SpelledNote("B flat"), SpelledNote(.B, -1))
        XCTAssertEqual(SpelledNote("Cx")!.name, "Cx")
        XCTAssertEqual(SpelledNote("Bb")!.displayName, "B♭")
        XCTAssertNil(SpelledNote("H"))
        XCTAssertNil(SpelledNote("C###"))
        XCTAssertEqual(PitchClass("Db"), PitchClass(1))
        XCTAssertEqual(PitchClass(-1).value, 11)
        XCTAssertEqual(PitchClass(1).enharmonicLabel, "C#/Db")
    }

    func testCodableStrings() throws {
        struct Box: Codable, Equatable {
            var p: Pitch; var n: SpelledNote; var c: Chord; var s: Scale; var k: Key; var r: RhythmPattern; var i: Interval
        }
        let box = Box(p: Pitch("Bb3")!, n: SpelledNote("F#")!, c: Chord("C/G")!, s: Scale("A minor pentatonic")!,
                      k: Key("Eb major")!, r: RhythmPattern("q. e te te te qr")!, i: .M3)
        let data = try JSONEncoder().encode(box)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"Bb3\""))
        XCTAssertTrue(json.contains("\"C\\/G\"") || json.contains("\"C/G\""))
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: data), box)
        let bad = #"{"p":"Q9","n":"F#","c":"C","s":"C major","k":"C major","r":"q","i":"M3"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Box.self, from: bad))
    }

    // MARK: - Intervals

    func testIntervalSemitonesAndNames() {
        let expected: [(Interval, Int, String, String)] = [
            (.P1, 0, "P1", "perfect unison"), (.m2, 1, "m2", "minor second"), (.M2, 2, "M2", "major second"),
            (.m3, 3, "m3", "minor third"), (.M3, 4, "M3", "major third"), (.P4, 5, "P4", "perfect fourth"),
            (.A4, 6, "A4", "augmented fourth"), (.d5, 6, "d5", "diminished fifth"), (.P5, 7, "P5", "perfect fifth"),
            (.A5, 8, "A5", "augmented fifth"), (.m6, 8, "m6", "minor sixth"), (.M6, 9, "M6", "major sixth"),
            (.d7, 9, "d7", "diminished seventh"), (.m7, 10, "m7", "minor seventh"), (.M7, 11, "M7", "major seventh"),
            (.P8, 12, "P8", "perfect octave"), (.m9, 13, "m9", "minor ninth"), (.M9, 14, "M9", "major ninth"),
            (.P11, 17, "P11", "perfect eleventh"), (.M13, 21, "M13", "major thirteenth"),
        ]
        for (iv, semis, short, name) in expected {
            XCTAssertEqual(iv.semitones, semis, short)
            XCTAssertEqual(iv.shortName, short)
            XCTAssertEqual(iv.name, name)
            XCTAssertEqual(try Interval(parsing: short), iv)
        }
        XCTAssertEqual(Interval.A4.alternateName, "tritone")
        XCTAssertNil(Interval(quality: .major, number: 5))
        XCTAssertNil(Interval(quality: .perfect, number: 3))
        XCTAssertThrowsError(try Interval(parsing: "M5"))
        XCTAssertEqual(Interval("major third"), .M3)
        XCTAssertEqual(Interval("perfect 5th"), .P5)
        XCTAssertEqual(Interval("minor 3rd"), .m3)
        XCTAssertEqual(Interval("tritone"), .A4)
        XCTAssertEqual(Interval("maj7"), .M7)
        XCTAssertEqual(Interval("min3"), .m3)
        XCTAssertEqual(Interval.M3.inverted, .m6)
        XCTAssertEqual(Interval.P4.inverted, .P5)
        XCTAssertEqual(Interval.A4.inverted, .d5)
        XCTAssertEqual(Interval.P1.inverted, .P8)
        XCTAssertEqual(Interval.P8.inverted, .P1)
        XCTAssertEqual(Interval.M9.simple, .M2)
    }

    func testSpelledTransposition() {
        func t(_ note: String, _ iv: Interval, down: Bool = false) -> String {
            SpelledNote(note)!.transposed(by: iv, down: down).name
        }
        XCTAssertEqual(t("C", .M3), "E")
        XCTAssertEqual(t("E", .m3), "G")
        XCTAssertEqual(t("F#", .M3), "A#")
        XCTAssertEqual(t("B", .m2), "C")
        XCTAssertEqual(t("Bb", .M3), "D")
        XCTAssertEqual(t("Db", .P4), "Gb")
        XCTAssertEqual(t("G#", .M3), "B#")
        XCTAssertEqual(t("D#", .M3), "Fx")
        XCTAssertEqual(t("B", .d5), "F")
        XCTAssertEqual(t("F", .A4), "B")
        XCTAssertEqual(t("C", .P5, down: true), "F")
        XCTAssertEqual(t("E", .M3, down: true), "C")
        XCTAssertEqual(Pitch("E4")!.transposed(by: .m3).name, "G4")
        XCTAssertEqual(Pitch("B3")!.transposed(by: .m2).name, "C4")
        XCTAssertEqual(Pitch("C4")!.transposed(by: .P5, down: true).name, "F3")
        XCTAssertEqual(Pitch("C4")!.transposed(by: .M9).name, "D5")
        XCTAssertEqual(Pitch("B3")!.transposed(by: .d5).name, "F4")
    }

    func testIntervalBetween() {
        XCTAssertEqual(Interval.between(.C, .E), .M3)
        XCTAssertEqual(Interval.between(.E, .C), .m6)
        XCTAssertEqual(Interval.between(SpelledNote("F")!, SpelledNote("B")!), .A4)
        XCTAssertEqual(Interval.between(SpelledNote("B")!, SpelledNote("F")!), .d5)
        XCTAssertEqual(Interval.between(SpelledNote("C#")!, SpelledNote("Bb")!), .d7)
        XCTAssertEqual(Interval.between(Pitch("C4")!, Pitch("E5")!), Interval(quality: .major, number: 10))
        XCTAssertEqual(Interval.between(Pitch("G3")!, Pitch("C3")!), .P5)
        XCTAssertEqual(Interval.between(Pitch("C4")!, Pitch("C5")!), .P8)
        // Every common interval transposes then measures back to itself, from every common root.
        for pc in PitchClass.all {
            for root in [pc.spelled(preferSharps: true), pc.spelled(preferSharps: false)] {
                for iv in Interval.common where iv != .P8 {
                    XCTAssertEqual(Interval.between(root, root.transposed(by: iv)), iv, "\(root) \(iv)")
                }
            }
        }
    }

    // MARK: - Scales and keys

    /// Textbook major scales for all 15 conventional major keys.
    private let majorScales: [String: String] = [
        "C": "C D E F G A B", "G": "G A B C D E F#", "D": "D E F# G A B C#", "A": "A B C# D E F# G#",
        "E": "E F# G# A B C# D#", "B": "B C# D# E F# G# A#", "F#": "F# G# A# B C# D# E#",
        "C#": "C# D# E# F# G# A# B#", "F": "F G A Bb C D E", "Bb": "Bb C D Eb F G A",
        "Eb": "Eb F G Ab Bb C D", "Ab": "Ab Bb C Db Eb F G", "Db": "Db Eb F Gb Ab Bb C",
        "Gb": "Gb Ab Bb Cb Db Eb F", "Cb": "Cb Db Eb Fb Gb Ab Bb",
    ]

    private let majorFifths: [String: Int] = [
        "C": 0, "G": 1, "D": 2, "A": 3, "E": 4, "B": 5, "F#": 6, "C#": 7,
        "F": -1, "Bb": -2, "Eb": -3, "Ab": -4, "Db": -5, "Gb": -6, "Cb": -7,
    ]

    func testAllMajorScalesAndSignatures() throws {
        for (tonic, expected) in majorScales {
            let scale = try Scale(parsing: "\(tonic) major")
            XCTAssertEqual(names(scale.notes), expected, tonic)
            let key = try Key(parsing: "\(tonic) major")
            XCTAssertEqual(key.signature.fifths, majorFifths[tonic], tonic)
            // Signature accidentals are exactly the altered scale notes.
            XCTAssertEqual(Set(key.signature.accidentals), Set(scale.notes.filter { !$0.isNatural }), tonic)
            // One letter per degree.
            XCTAssertEqual(Set(scale.notes.map(\.letter)).count, 7, tonic)
        }
        XCTAssertEqual(names(Key("D major")!.signature.accidentals), "F# C#")
        XCTAssertEqual(names(Key("Eb major")!.signature.accidentals), "Bb Eb Ab")
        XCTAssertEqual(names(Key("C# major")!.signature.accidentals), "F# C# G# D# A# E# B#")
        XCTAssertEqual(Key("A major")!.signature.description, "3 sharps")
        XCTAssertEqual(Key("F major")!.signature.description, "1 flat")
        XCTAssertEqual(Key("C major")!.signature.description, "no sharps or flats")
        XCTAssertTrue(Key("G# major")!.isTheoretical)
        XCTAssertEqual(names(Scale("G# major")!.notes), "G# A# B# C# D# E# Fx")
        XCTAssertEqual(Key.allKeys(mode: .major).count, 15)
    }

    func testMinorKeysAndScales() throws {
        let minors: [String: (String, Int)] = [
            "A": ("A B C D E F G", 0), "E": ("E F# G A B C D", 1), "B": ("B C# D E F# G A", 2),
            "F#": ("F# G# A B C# D E", 3), "C#": ("C# D# E F# G# A B", 4), "G#": ("G# A# B C# D# E F#", 5),
            "D#": ("D# E# F# G# A# B C#", 6), "A#": ("A# B# C# D# E# F# G#", 7),
            "D": ("D E F G A Bb C", -1), "G": ("G A Bb C D Eb F", -2), "C": ("C D Eb F G Ab Bb", -3),
            "F": ("F G Ab Bb C Db Eb", -4), "Bb": ("Bb C Db Eb F Gb Ab", -5), "Eb": ("Eb F Gb Ab Bb Cb Db", -6),
            "Ab": ("Ab Bb Cb Db Eb Fb Gb", -7),
        ]
        for (tonic, (expected, fifths)) in minors {
            XCTAssertEqual(names(try Scale(parsing: "\(tonic) minor").notes), expected, tonic)
            XCTAssertEqual(names(try Scale(parsing: "\(tonic) natural minor").notes), expected, tonic)
            XCTAssertEqual(try Key(parsing: "\(tonic) minor").signature.fifths, fifths, tonic)
        }
        XCTAssertEqual(names(Scale("A harmonic minor")!.notes), "A B C D E F G#")
        XCTAssertEqual(names(Scale("A melodic minor")!.notes), "A B C D E F# G#")
        XCTAssertEqual(names(Scale("C harmonic minor")!.notes), "C D Eb F G Ab B")
        XCTAssertEqual(names(Scale("D# harmonic minor")!.notes), "D# E# F# G# A# B Cx")
        XCTAssertEqual(Key("E minor")!.relative, Key("G major"))
        XCTAssertEqual(Key("Bb major")!.relative, Key("G minor"))
        XCTAssertEqual(Key("F# major")!.relative, Key("D# minor"))
        XCTAssertEqual(Key("Gb major")!.relative, Key("Eb minor"))
        XCTAssertEqual(Key("C major")!.parallel, Key("C minor"))
        XCTAssertEqual(Key("F# major")!.enharmonicEquivalent, Key("Gb major"))
        XCTAssertEqual(Key(fifths: -6, mode: .minor), Key("Eb minor"))
    }

    func testOtherScales() throws {
        XCTAssertEqual(names(Scale("A minor pentatonic")!.notes), "A C D E G")
        XCTAssertEqual(names(Scale("C major pentatonic")!.notes), "C D E G A")
        XCTAssertEqual(names(Scale("E minor pentatonic")!.notes), "E G A B D")
        XCTAssertEqual(names(Scale("A blues")!.notes), "A C D Eb E G")
        XCTAssertEqual(names(Scale("E blues")!.notes), "E G A Bb B D")
        XCTAssertEqual(names(Scale("D dorian")!.notes), "D E F G A B C")
        XCTAssertEqual(names(Scale("E phrygian")!.notes), "E F G A B C D")
        XCTAssertEqual(names(Scale("F lydian")!.notes), "F G A B C D E")
        XCTAssertEqual(names(Scale("G mixolydian")!.notes), "G A B C D E F")
        XCTAssertEqual(names(Scale("B locrian")!.notes), "B C D E F G A")
        XCTAssertEqual(names(Scale("C ionian")!.notes), "C D E F G A B")
        XCTAssertEqual(names(Scale("A aeolian")!.notes), "A B C D E F G")
        XCTAssertEqual(names(Scale("A dorian")!.notes), "A B C D E F# G")
        XCTAssertEqual(names(Scale("Bb mixolydian")!.notes), "Bb C D Eb F G Ab")
        XCTAssertEqual(names(Scale("C chromatic")!.notes), "C C# D D# E F F# G G# A A# B")
        XCTAssertEqual(names(Scale("F chromatic")!.notes), "F Gb G Ab A Bb B C Db D Eb E")
        XCTAssertEqual(Scale("A minor")!.degrees, ["1", "2", "b3", "4", "5", "b6", "b7"])
        XCTAssertEqual(Scale("A blues")!.degrees, ["1", "b3", "4", "b5", "5", "b7"])
        XCTAssertEqual(Scale("F lydian")!.degrees, ["1", "2", "3", "#4", "5", "6", "7"])
        XCTAssertEqual(Scale("C Major Scale")?.type, .major)
        XCTAssertEqual(Scale("A pentatonic minor")?.type, .minorPentatonic)
        XCTAssertEqual(Scale("C major")!.mode(onDegree: 2), Scale("D dorian"))
        XCTAssertThrowsError(try Scale(parsing: "C superlocrian")) { error in
            XCTAssertTrue((error as? TheoryParseError)?.reason.contains("unknown scale type") == true)
        }
        XCTAssertThrowsError(try Scale(parsing: "major"))
        let g = Scale("G major")!
        XCTAssertEqual(g.pitches(startOctave: 3).map(\.name), ["G3", "A3", "B3", "C4", "D4", "E4", "F#4", "G4"])
        XCTAssertEqual(g.pitches(startOctave: 2, octaves: 2).count, 15)
        let upDown = Scale("C major")!.pitches(startOctave: 4, upAndDown: true).map(\.name)
        XCTAssertEqual(upDown.count, 15)
        XCTAssertEqual(upDown.first, "C4"); XCTAssertEqual(upDown[7], "C5"); XCTAssertEqual(upDown.last, "C4")
        XCTAssertEqual(Scale("Cb major")!.pitches(startOctave: 4).first?.midi, 59)
        XCTAssertEqual(g.degree(of: PitchClass(6)), 7)
        XCTAssertNil(g.degree(of: PitchClass(5)))
        XCTAssertEqual(g.note(degree: 8), .G)
    }

    func testCircleOfFifths() {
        XCTAssertEqual(Key.circleOfFifths().map(\.tonic.name), ["C", "G", "D", "A", "E", "B", "F#", "Db", "Ab", "Eb", "Bb", "F"])
        XCTAssertEqual(Key.circleOfFifths(mode: .minor).map(\.tonic.name), ["A", "E", "B", "F#", "C#", "G#", "D#", "Bb", "F", "C", "G", "D"])
        XCTAssertEqual(Key("G major")!.dominant, Key("D major"))
        XCTAssertEqual(Key("G major")!.subdominant, Key("C major"))
    }

    func testKeyParsing() throws {
        XCTAssertEqual(try Key(parsing: "Em"), Key(tonic: .E, mode: .minor))
        XCTAssertEqual(try Key(parsing: "Bbm"), Key(tonic: SpelledNote("Bb")!, mode: .minor))
        XCTAssertEqual(try Key(parsing: "G"), Key(tonic: .G, mode: .major))
        XCTAssertEqual(try Key(parsing: "c# MINOR"), Key(tonic: SpelledNote("C#")!, mode: .minor))
        XCTAssertEqual(try Key(parsing: "Eb maj"), Key(tonic: SpelledNote("Eb")!, mode: .major))
        XCTAssertThrowsError(try Key(parsing: "G dorian"))
        XCTAssertThrowsError(try Key(parsing: "H major"))
    }

    // MARK: - Chords

    func testChordSpelling() {
        func tones(_ s: String) -> String { names(Chord(s)!.tones) }
        XCTAssertEqual(tones("C"), "C E G")
        XCTAssertEqual(tones("Am"), "A C E")
        XCTAssertEqual(tones("A7"), "A C# E G")
        XCTAssertEqual(tones("Amaj7"), "A C# E G#")
        XCTAssertEqual(tones("AM7"), "A C# E G#")
        XCTAssertEqual(tones("A-7"), "A C E G")
        XCTAssertEqual(tones("Asus4"), "A D E")
        XCTAssertEqual(tones("Asus2"), "A B E")
        XCTAssertEqual(tones("A5"), "A E")
        XCTAssertEqual(tones("Bbm7b5"), "Bb Db Fb Ab")
        XCTAssertEqual(tones("Bm7b5"), "B D F A")
        XCTAssertEqual(tones("Bø7"), "B D F A")
        XCTAssertEqual(tones("F#dim7"), "F# A C Eb")
        XCTAssertEqual(tones("Bdim7"), "B D F Ab")
        XCTAssertEqual(tones("Bdim"), "B D F")
        XCTAssertEqual(tones("C°"), "C Eb Gb")
        XCTAssertEqual(tones("Caug"), "C E G#")
        XCTAssertEqual(tones("C+"), "C E G#")
        XCTAssertEqual(tones("Cadd9"), "C E G D")
        XCTAssertEqual(tones("C6"), "C E G A")
        XCTAssertEqual(tones("Am6"), "A C E F#")
        XCTAssertEqual(tones("G9"), "G B D F A")
        XCTAssertEqual(tones("Dm9"), "D F A C E")
        XCTAssertEqual(tones("Fmaj9"), "F A C E G")
        XCTAssertEqual(tones("Ebmaj7"), "Eb G Bb D")
        XCTAssertEqual(tones("F#"), "F# A# C#")
        XCTAssertEqual(tones("Db"), "Db F Ab")
        XCTAssertEqual(tones("G#m"), "G# B D#")
        XCTAssertEqual(tones("D7sus4"), "D G A C")
        XCTAssertEqual(tones("E7"), "E G# B D")
    }

    func testChordSymbolsRoundTrip() throws {
        let symbols = ["A", "Am", "A7", "Amaj7", "Am7", "Asus4", "Asus2", "A5", "C/G", "D/F#", "Bbm7b5", "F#dim7",
                       "Bdim", "Caug", "C6", "Am6", "Cadd9", "G9", "Dm9", "Fmaj9", "Ebm", "Abmaj7", "D7sus4"]
        for s in symbols {
            let chord = try Chord(parsing: s)
            XCTAssertEqual(chord.symbol, s)
            XCTAssertEqual(try Chord(parsing: chord.symbol), chord)
        }
        XCTAssertEqual(Chord("AM7")?.symbol, "Amaj7")
        XCTAssertEqual(Chord("A-7")?.symbol, "Am7")
        XCTAssertEqual(Chord("A-")?.symbol, "Am")
        XCTAssertEqual(Chord("Amin")?.symbol, "Am")
        XCTAssertEqual(Chord("Bø7")?.symbol, "Bm7b5")
        XCTAssertEqual(Chord("Bm7(b5)")?.symbol, "Bm7b5")
        XCTAssertEqual(Chord("Co7")?.symbol, "Cdim7")
        XCTAssertEqual(Chord("CΔ7")?.symbol, "Cmaj7")
        XCTAssertEqual(Chord("Asus")?.symbol, "Asus4")
        XCTAssertEqual(Chord("C/C")?.symbol, "C")
        XCTAssertEqual(Chord("Bbm7b5")?.displaySymbol, "B♭m7♭5")
        XCTAssertEqual(Chord("D/F#")?.displaySymbol, "D/F♯")
        XCTAssertThrowsError(try Chord(parsing: "Cblah")) { error in
            XCTAssertTrue((error as? TheoryParseError)?.reason.contains("unknown chord suffix") == true)
        }
        XCTAssertThrowsError(try Chord(parsing: "am"))
        XCTAssertThrowsError(try Chord(parsing: "C/Q"))
        XCTAssertThrowsError(try Chord(parsing: ""))
    }

    func testChordVoicingAndInversion() {
        XCTAssertEqual(Chord("C")!.pitches(rootOctave: 4).map(\.name), ["C4", "E4", "G4"])
        XCTAssertEqual(Chord("C/G")!.pitches(rootOctave: 3).map(\.name), ["G2", "C3", "E3", "G3"])
        XCTAssertEqual(Chord("C/E")!.inversion, 1)
        XCTAssertEqual(Chord("C/G")!.inversion, 2)
        XCTAssertEqual(Chord("C/D")!.inversion, nil)
        XCTAssertEqual(Chord("C7")!.inverted(3).symbol, "C7/Bb")
        XCTAssertEqual(Chord("G7")!.transposed(by: .M2).symbol, "A7")
        XCTAssertEqual(Chord.identify(midi: [48, 52, 55]).first?.symbol, "C")
        XCTAssertEqual(Chord.identify(midi: [40, 48, 55]).first?.symbol, "C/E")
        XCTAssertEqual(Chord.identify(midi: [45, 52, 57, 60, 64]).first?.symbol, "Am")
        XCTAssertEqual(Chord.identify(midi: [43, 47, 50, 53]).first?.symbol, "G7")
    }

    // MARK: - Roman numerals

    func testDiatonicChordsAndNumerals() throws {
        let c = Key("C major")!
        XCTAssertEqual(c.diatonicTriads.map(\.symbol), ["C", "Dm", "Em", "F", "G", "Am", "Bdim"])
        XCTAssertEqual(c.triadNumerals, ["I", "ii", "iii", "IV", "V", "vi", "vii°"])
        XCTAssertEqual(c.diatonicSevenths.map(\.symbol), ["Cmaj7", "Dm7", "Em7", "Fmaj7", "G7", "Am7", "Bm7b5"])
        XCTAssertEqual(c.seventhNumerals, ["Imaj7", "ii7", "iii7", "IVmaj7", "V7", "vi7", "viiø7"])
        XCTAssertEqual(Key("F major")!.diatonicTriads.map(\.symbol), ["F", "Gm", "Am", "Bb", "C", "Dm", "Edim"])
        XCTAssertEqual(Key("D major")!.diatonicTriads.map(\.symbol), ["D", "Em", "F#m", "G", "A", "Bm", "C#dim"])
        XCTAssertEqual(Key("Db major")!.diatonicTriads.map(\.symbol), ["Db", "Ebm", "Fm", "Gb", "Ab", "Bbm", "Cdim"])
        let am = Key("A minor")!
        XCTAssertEqual(am.diatonicTriads.map(\.symbol), ["Am", "Bdim", "C", "Dm", "Em", "F", "G"])
        XCTAssertEqual(am.triadNumerals, ["i", "ii°", "III", "iv", "v", "VI", "VII"])
        XCTAssertEqual(am.diatonicSevenths.map(\.symbol), ["Am7", "Bm7b5", "Cmaj7", "Dm7", "Em7", "Fmaj7", "G7"])
        // Every key: triads round-trip through Roman numerals.
        for mode in KeyMode.allCases {
            for key in Key.allKeys(mode: mode) {
                for chord in key.diatonicTriads + key.diatonicSevenths {
                    let numeral = try XCTUnwrap(key.romanNumeral(for: chord), "\(key) \(chord)")
                    XCTAssertEqual(try key.chord(forRoman: numeral), chord, "\(key) \(numeral)")
                }
            }
        }
    }

    func testRomanNumeralParsing() throws {
        let c = Key("C major")!
        XCTAssertEqual(try c.chord(forRoman: "V7").symbol, "G7")
        XCTAssertEqual(try c.chord(forRoman: "ii").symbol, "Dm")
        XCTAssertEqual(try c.chord(forRoman: "vii°").symbol, "Bdim")
        XCTAssertEqual(try c.chord(forRoman: "viio").symbol, "Bdim")
        XCTAssertEqual(try c.chord(forRoman: "viiø7").symbol, "Bm7b5")
        XCTAssertEqual(try c.chord(forRoman: "bVII").symbol, "Bb")
        XCTAssertEqual(try c.chord(forRoman: "♭III").symbol, "Eb")
        XCTAssertEqual(try c.chord(forRoman: "IVmaj7").symbol, "Fmaj7")
        XCTAssertEqual(try c.chord(forRoman: "iv").symbol, "Fm")
        XCTAssertEqual(c.romanNumeral(for: Chord("Bb")!), "bVII")
        XCTAssertEqual(c.romanNumeral(for: Chord("Fm")!), "iv")
        XCTAssertEqual(c.romanNumeral(for: Chord("D7")!), "II7")
        let am = Key("A minor")!
        XCTAssertEqual(try am.chord(forRoman: "V7").symbol, "E7")
        XCTAssertEqual(try am.chord(forRoman: "V").symbol, "E")
        XCTAssertEqual(try am.chord(forRoman: "vii°").symbol, "G#dim")
        XCTAssertEqual(try am.chord(forRoman: "vii°7").symbol, "G#dim7")
        XCTAssertEqual(try am.chord(forRoman: "VII").symbol, "G")
        XCTAssertEqual(am.romanNumeral(for: Chord("E7")!), "V7")
        XCTAssertEqual(am.romanNumeral(for: Chord("G#dim7")!), "vii°7")
        XCTAssertEqual(try Key("G major")!.chord(forRoman: "V7").symbol, "D7")
        XCTAssertEqual(try Key("Eb major")!.chord(forRoman: "vi").symbol, "Cm")
        XCTAssertEqual(try Key("E minor")!.chord(forRoman: "V7").symbol, "B7")
        XCTAssertThrowsError(try c.chord(forRoman: "VIII"))
        XCTAssertThrowsError(try c.chord(forRoman: "Iv"))
        XCTAssertThrowsError(try c.chord(forRoman: "I°"))
        XCTAssertThrowsError(try c.chord(forRoman: "")) { error in
            XCTAssertEqual((error as? TheoryParseError)?.kind, .romanNumeral)
        }
    }

    func testKeySpelling() {
        XCTAssertEqual(Key("F major")!.spell(PitchClass(10)).name, "Bb")
        XCTAssertEqual(Key("F major")!.spell(PitchClass(11)).name, "B")
        XCTAssertEqual(Key("F major")!.spell(PitchClass(1)).name, "Db")
        XCTAssertEqual(Key("G major")!.spell(PitchClass(5)).name, "F")
        XCTAssertEqual(Key("D major")!.spell(PitchClass(3)).name, "D#")
        XCTAssertEqual(Key("A minor")!.spell(PitchClass(8)).name, "G#")
        XCTAssertEqual(Key("A minor")!.spell(PitchClass(6)).name, "F#")
        XCTAssertEqual(Key("C major")!.spell(PitchClass(10)).name, "Bb")
        XCTAssertEqual(Key("Gb major")!.spell(PitchClass(11)).name, "Cb")
        XCTAssertEqual(Key("Eb minor")!.spell(PitchClass(2)).name, "D")
        XCTAssertEqual(NoteNaming.displayName(midi: 70, in: Key("F major")), "B♭4")
        XCTAssertEqual(NoteNaming.displayName(midi: 70, in: Key("E major"), symbols: false), "A#4")
        XCTAssertEqual(NoteNaming.displayName(midi: 70), "A♯4")
        XCTAssertEqual(NoteNaming.displayName(midi: 70, preferSharps: false), "B♭4")
        XCTAssertEqual(NoteNaming.displayName(midi: 59, in: Key("Gb major")), "C♭4")
        XCTAssertEqual(NoteNaming.displayName(midi: 64, showOctave: false), "E")
        XCTAssertEqual(NoteNaming.bothSpellings(PitchClass(1), symbols: false), "C#/Db")
        XCTAssertFalse(NoteNaming.prefersSharps(in: Key("Bb major")))
    }

    // MARK: - Rhythm

    func testRhythmParsing() throws {
        let p = try RhythmPattern(parsing: "q q e e q")
        XCTAssertEqual(p.totalBeats, 4, accuracy: 1e-9)
        XCTAssertEqual(p.startBeats, [0, 1, 2, 2.5, 3])
        XCTAssertEqual(p.countLabels(), ["1", "2", "3", "&", "4"])
        XCTAssertEqual(p.measureCount(beatsPerMeasure: 4), 1)

        let dotted = try RhythmPattern(parsing: "h. q")
        XCTAssertEqual(dotted.events.map(\.beats), [3, 1])
        XCTAssertEqual(dotted.events[0].value.name, "dotted half")

        let triplets = try RhythmPattern(parsing: "te te te q h")
        XCTAssertEqual(triplets.totalBeats, 4, accuracy: 1e-9)
        XCTAssertEqual(triplets.countLabels(), ["1", "trip", "let", "2", "3"])
        XCTAssertEqual(triplets.events[0].value.name, "triplet eighth")
        XCTAssertEqual(try RhythmEvent(parsing: "et"), try RhythmEvent(parsing: "te"))

        let rests = try RhythmPattern(parsing: "q qr e.r s h")
        XCTAssertEqual(rests.events.map(\.isRest), [false, true, true, false, false])
        XCTAssertEqual(rests.totalBeats, 5, accuracy: 1e-9)
        XCTAssertEqual(rests.onsetBeats, [0, 2.75, 3])
        XCTAssertEqual(rests.noteCount, 3)
        XCTAssertEqual(rests.tokens, "q qr e.r s h")

        let sixteenths = try RhythmPattern(parsing: "s s s s | w, h h")
        XCTAssertEqual(sixteenths.countLabels(), ["1", "e", "&", "a", "2", "2", "4"])
        XCTAssertEqual(sixteenths.totalBeats, 9, accuracy: 1e-9)
        XCTAssertNil(sixteenths.measureCount(beatsPerMeasure: 4))
        XCTAssertEqual(try RhythmPattern(parsing: "Q Q H").totalBeats, 4, accuracy: 1e-9)
        XCTAssertEqual(NoteValue(.quarter, dots: 2).beats, 1.75, accuracy: 1e-9)

        for bad in ["", "q x", "qq", ".q", "rq", "q...", "tt e"] {
            XCTAssertThrowsError(try RhythmPattern(parsing: bad), bad) { error in
                XCTAssertEqual((error as? TheoryParseError)?.kind, .rhythm)
            }
        }
    }

    // MARK: - Fretboard

    func testFretboardBasics() {
        let fb = FretboardLayout.standardGuitar
        XCTAssertEqual(fb.tuningMIDI, [64, 59, 55, 50, 45, 40])
        XCTAssertEqual(fb.openStringPitches.map(\.name), ["E4", "B3", "G3", "D3", "A2", "E2"])
        XCTAssertEqual(fb.midi(string: 5, fret: 0), 40)
        XCTAssertEqual(fb.midi(string: 5, fret: 3), 43)
        XCTAssertEqual(fb.midi(string: 0, fret: 20), 84)
        XCTAssertNil(fb.midi(string: 0, fret: 21))
        XCTAssertNil(fb.midi(string: 6, fret: 0))
        let capo2 = FretboardLayout(tuningMIDI: GuitarTuning.standard.midiNotes, capo: 2)
        XCTAssertEqual(capo2.midi(string: 5, fret: 0), 42)
        XCTAssertEqual(capo2.maxFret, 18)

        // Middle C: B string fret 1, G string fret 5, D string fret 10, A string fret 15, low E fret 20.
        XCTAssertEqual(fb.positions(of: Pitch("C4")!), [
            FretPosition(string: 1, fret: 1), FretPosition(string: 2, fret: 5), FretPosition(string: 3, fret: 10),
            FretPosition(string: 4, fret: 15), FretPosition(string: 5, fret: 20),
        ])
        XCTAssertEqual(fb.positions(of: Pitch("E2")!), [FretPosition(string: 5, fret: 0)])
        // Every C in frets 0–12: one per string.
        let cs = fb.positions(of: PitchClass(0), fretRange: 0...12)
        XCTAssertTrue(cs.allSatisfy { fb.midi(at: $0)! % 12 == 0 })
        XCTAssertEqual(cs.count, 6)
        XCTAssertTrue(cs.contains(FretPosition(guitarString: 5, fret: 3)))
        XCTAssertTrue(cs.contains(FretPosition(guitarString: 6, fret: 8)))

        let pent = fb.positions(in: Scale("A minor pentatonic")!, fretRange: 5...8)
        XCTAssertEqual(pent.count, 12) // the box pattern: two notes per string
        XCTAssertEqual(fb.bestPosition(ofMIDI: 45), FretPosition(string: 4, fret: 0))
    }

    func testGuitarStringNumbering() throws {
        let p = try FretPosition(parsing: "6:3")
        XCTAssertEqual(p, FretPosition(string: 5, fret: 3))
        XCTAssertEqual(p.guitarString, 6)
        XCTAssertEqual(p.notation, "6:3")
        XCTAssertEqual(FretboardLayout.standardGuitar.midi(at: p), Pitch("G2")!.midi)
        XCTAssertEqual(try FretPosition(parsing: "1:0"), FretPosition(string: 0, fret: 0))
        for bad in ["6", "0:3", "6:-1", "a:b", "6:3:1"] {
            XCTAssertThrowsError(try FretPosition(parsing: bad), bad)
        }
    }

    func testOpenChordFingerings() throws {
        let fb = FretboardLayout.standardGuitar
        let required = ["E", "A", "D", "G", "C", "Am", "Em", "Dm", "E7", "A7", "D7", "G7", "C7", "B7", "Fmaj7", "Cadd9"]
        for symbol in required {
            XCTAssertNotNil(ChordFingering.open(symbol), symbol)
        }
        XCTAssertEqual(ChordFingering.open("C")?.chart, "x32010")
        XCTAssertEqual(ChordFingering.open("G")?.chart, "320003")
        XCTAssertEqual(ChordFingering.open("D")?.chart, "xx0232")
        XCTAssertEqual(ChordFingering.open("Am")?.chart, "x02210")
        XCTAssertEqual(ChordFingering.open("B7")?.chart, "x21202")
        for f in ChordFingering.openChords {
            let chord = try XCTUnwrap(f.chord, f.symbol)
            let sounded = Set(fb.midi(for: f).map { PitchClass($0) })
            // Every chord tone sounds, except the fifth may be omitted (C7 x32310).
            let fifth = chord.root.transposed(by: .P5).pitchClass
            XCTAssertTrue(sounded.isSubset(of: chord.pitchClasses), f.symbol)
            XCTAssertTrue(chord.pitchClasses.subtracting(sounded).isSubset(of: [fifth]), f.symbol)
            // Lowest sounded note is the root.
            XCTAssertEqual(PitchClass(fb.midi(for: f).first!), chord.root.pitchClass, f.symbol)
            XCTAssertEqual(f.frets.count, 6); XCTAssertEqual(f.fingers.count, 6)
            for (fret, finger) in zip(f.frets, f.fingers) {
                XCTAssertEqual(fret == nil, finger == nil, f.symbol)
                if let fret, let finger { XCTAssertEqual(fret == 0, finger == 0, f.symbol) }
            }
        }
        XCTAssertEqual(fb.midi(for: ChordFingering.open("E")!), [40, 47, 52, 56, 59, 64])
    }

    func testBarreChords() throws {
        let fb = FretboardLayout.standardGuitar
        let f = try XCTUnwrap(ChordFingering.barre(Chord("F")!, form: .eRoot))
        XCTAssertEqual(f.chart, "133211")
        XCTAssertEqual(f.barre?.fret, 1)
        let bm = try XCTUnwrap(ChordFingering.barre(Chord("Bm")!, form: .aRoot))
        XCTAssertEqual(bm.chart, "x24432")
        let cases: [(String, ChordFingering.BarreForm)] = [
            ("G", .eRoot), ("Gm", .eRoot), ("G7", .eRoot), ("Gm7", .eRoot), ("Bb", .aRoot), ("C#m", .aRoot),
            ("D7", .aRoot), ("Em7", .aRoot), ("Cmaj7", .aRoot), ("E", .eRoot), ("A", .aRoot),
        ]
        for (symbol, form) in cases {
            let chord = Chord(symbol)!
            let voicing = try XCTUnwrap(ChordFingering.barre(chord, form: form), symbol)
            XCTAssertEqual(Set(fb.midi(for: voicing).map { PitchClass($0) }), chord.pitchClasses, symbol)
            XCTAssertEqual(PitchClass(fb.midi(for: voicing).first!), chord.root.pitchClass, symbol)
            XCTAssertTrue((1...12).contains(voicing.barre!.fret), symbol)
        }
        XCTAssertNil(ChordFingering.barre(Chord("Csus4")!, form: .eRoot))
        XCTAssertEqual(try ChordFingering.parseChart("x(10)(12)(12)(12)(10)"), [10, 12, 12, 12, 10, nil])
    }

    // MARK: - Keyboard

    func testKeyboardLayout() {
        let kb = KeyboardLayout.piano88
        XCTAssertEqual(kb.keyCount, 88)
        XCTAssertEqual(kb.whiteKeyCount, 52)
        XCTAssertEqual(kb.blackKeys.count, 36)
        XCTAssertTrue(KeyboardLayout.isBlack(61))
        XCTAssertFalse(KeyboardLayout.isBlack(60))
        XCTAssertEqual(kb.whiteKeyIndex(of: 21), 0)   // A0
        XCTAssertEqual(kb.whiteKeyIndex(of: 23), 1)   // B0
        XCTAssertEqual(kb.whiteKeyIndex(of: 24), 2)   // C1
        XCTAssertEqual(kb.whiteKeyIndex(of: 60), 23)  // middle C
        XCTAssertEqual(kb.whiteKeyIndex(of: 108), 51) // C8
        XCTAssertNil(kb.whiteKeyIndex(of: 22))
        XCTAssertNil(kb.whiteKeyIndex(of: 20))
        let octave = KeyboardLayout.octaves(from: 4)
        XCTAssertEqual(octave.range, 60...71)
        XCTAssertEqual(octave.whiteKeyCount, 7)
        XCTAssertEqual(octave.keyCenter(of: 60), 0.5)
        XCTAssertEqual(octave.keyCenter(of: 61), 1.0)
        XCTAssertEqual(octave.keyCenter(of: 66), 4.0)
        XCTAssertEqual(KeyboardLayout.fitting([60, 64, 67, 72]).range, 60...83)
    }
}
