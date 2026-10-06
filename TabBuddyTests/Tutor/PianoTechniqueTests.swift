//
//  PianoTechniqueTests.swift
//  TabBuddyTests
//
//  Piano technique grid model: pitches per row and key, hands, fingering,
//  launch round trips, and cell status from PracticeMemory.
//

import XCTest
@testable import TabBuddy

@MainActor
final class PianoTechniqueTests: XCTestCase {
    private func key(_ root: String, _ mode: PianoTechniqueKey.Mode = .major) -> PianoTechniqueKey {
        PianoTechniqueKey(root, mode)!
    }

    private func line(_ spec: PianoTechniqueSpec, _ hands: PianoHands = .right) -> [Int] {
        spec.pitches(hands: hands).map { $0[0] }
    }

    private func midi(_ names: String) -> [Int] {
        names.split(separator: " ").map { Pitch(String($0))!.midi }
    }

    func testMajorScalesOneOctaveUpAndDown() {
        XCTAssertEqual(line(PianoTechniqueSpec(key: key("C"), row: .scaleOneOctave)),
                       midi("C4 D4 E4 F4 G4 A4 B4 C5 B4 A4 G4 F4 E4 D4 C4"))
        XCTAssertEqual(line(PianoTechniqueSpec(key: key("G"), row: .scaleOneOctave)),
                       midi("G4 A4 B4 C5 D5 E5 F#5 G5 F#5 E5 D5 C5 B4 A4 G4"))
        XCTAssertEqual(line(PianoTechniqueSpec(key: key("F"), row: .scaleOneOctave)),
                       midi("F4 G4 A4 Bb4 C5 D5 E5 F5 E5 D5 C5 Bb4 A4 G4 F4"))
    }

    func testMajorScalesTwoOctaves() {
        let c = line(PianoTechniqueSpec(key: key("C"), row: .scaleTwoOctaves, hands: .right))
        XCTAssertEqual(c.count, 29)
        XCTAssertEqual(Array(c.prefix(15)), midi("C4 D4 E4 F4 G4 A4 B4 C5 D5 E5 F5 G5 A5 B5 C6"))
        XCTAssertEqual(Array(c.suffix(15)), Array(c.prefix(15)).reversed())
        let g = line(PianoTechniqueSpec(key: key("G"), row: .scaleTwoOctaves, hands: .right))
        XCTAssertEqual(g.first, 67); XCTAssertEqual(g[14], 91); XCTAssertEqual(g.last, 67)
        XCTAssertTrue(g.contains(78) && g.contains(90))  // F#5, F#6
        let f = line(PianoTechniqueSpec(key: key("F"), row: .scaleTwoOctaves, hands: .right))
        XCTAssertEqual(Array(f.prefix(15)), midi("F4 G4 A4 Bb4 C5 D5 E5 F5 G5 A5 Bb5 C6 D6 E6 F6"))
    }

    func testHarmonicMinor() {
        let a = PianoTechniqueSpec(key: key("A", .minor), row: .scaleOneOctave)
        XCTAssertEqual(line(a), midi("A4 B4 C5 D5 E5 F5 G#5 A5 G#5 F5 E5 D5 C5 B4 A4"))
        XCTAssertEqual(a.launch.type, "harmonicMinor")
        XCTAssertTrue(a.diagram().notes?.contains("G#5") ?? false)
    }

    func testFiveFingerTriadArpeggio() {
        XCTAssertEqual(line(PianoTechniqueSpec(key: key("C"), row: .fiveFinger)), midi("C4 D4 E4 F4 G4 F4 E4 D4 C4"))
        XCTAssertEqual(line(PianoTechniqueSpec(key: key("G"), row: .brokenTriad)), midi("G4 B4 D5 B4 G4"))
        let arp = line(PianoTechniqueSpec(key: key("C"), row: .arpeggio))
        XCTAssertEqual(Array(arp.prefix(4)), midi("C4 E4 G4 C5"))
        XCTAssertEqual(arp, midi("C4 E4 G4 C5 G4 E4 C4"))
        let blocked = PianoTechniqueSpec(key: key("C"), row: .blockedTriad).pitches(hands: .right)
        XCTAssertEqual(blocked.first, midi("C4 E4 G4"))
        XCTAssertEqual(blocked[1], midi("E4 G4 C5"))
        XCTAssertEqual(blocked[2], midi("G4 C5 E5"))
        XCTAssertEqual(blocked[3], midi("C5 E5 G5"))
        XCTAssertEqual(blocked.count, 7)
        let aMinorBlocked = PianoTechniqueSpec(key: key("A", .minor), row: .blockedTriad).pitches(hands: .right)
        XCTAssertEqual(aMinorBlocked[2], midi("E5 A5 C6"))
    }

    func testLeftHandAndTogether() {
        for row in PianoTechniqueRow.allCases {
            let spec = PianoTechniqueSpec(key: key("D"), row: row)
            let rh = spec.pitches(hands: .right)
            let lh = spec.pitches(hands: .left)
            XCTAssertEqual(lh, rh.map { $0.map { $0 - 12 } }, "\(row)")
            let together = spec.pitches(hands: .together)
            XCTAssertEqual(together.count, rh.count)
            for (i, event) in together.enumerated() {
                XCTAssertEqual(event, (lh[i] + rh[i]).sorted(), "\(row) \(i)")
            }
        }
        let c = PianoTechniqueSpec(key: key("C"), row: .scaleOneOctave).pitches(hands: .together)
        XCTAssertEqual(c.first, [48, 60])
        XCTAssertEqual(c[7], [60, 72])
    }

    func testFingering() {
        for name in ["C", "G", "D", "A", "E"] {
            for row in [PianoTechniqueRow.scaleOneOctave, .scaleTwoOctaves] {
                let spec = PianoTechniqueSpec(key: key(name), row: row)
                let count = spec.pitches(hands: .right).count
                XCTAssertEqual(spec.fingering(hand: .right)?.count, count, "\(name) \(row)")
                XCTAssertEqual(spec.fingering(hand: .left)?.count, count, "\(name) \(row)")
            }
        }
        let c = PianoTechniqueSpec(key: key("C"), row: .scaleOneOctave)
        XCTAssertEqual(c.fingering(hand: .right), [1, 2, 3, 1, 2, 3, 4, 5, 4, 3, 2, 1, 3, 2, 1])
        XCTAssertEqual(c.fingering(hand: .left), [5, 4, 3, 2, 1, 3, 2, 1, 2, 3, 1, 2, 3, 4, 5])
        XCTAssertNil(c.fingering(hand: .together))
        XCTAssertNil(PianoTechniqueSpec(key: key("F"), row: .scaleOneOctave).fingering(hand: .right))
        XCTAssertNil(PianoTechniqueSpec(key: key("C"), row: .arpeggio).fingering(hand: .right))
        let five = PianoTechniqueSpec(key: key("Bb"), row: .fiveFinger)
        XCTAssertEqual(five.fingering(hand: .right), [1, 2, 3, 4, 5, 4, 3, 2, 1])
        XCTAssertEqual(five.fingering(hand: .left), [5, 4, 3, 2, 1, 2, 3, 4, 5])
        XCTAssertEqual(PianoTechniqueSpec(key: key("C"), row: .fiveFinger).diagram().labels, .fingers)
    }

    func testLaunchRoundTrip() {
        for k in PianoTechniqueKey.order {
            for row in PianoTechniqueRow.allCases {
                for hands in PianoHands.allCases {
                    let spec = PianoTechniqueSpec(key: k, row: row, hands: hands)
                    XCTAssertEqual(PianoTechniqueSpec(launch: spec.launch), spec)
                }
            }
        }
        let launch = PianoTechniqueSpec(key: key("G"), row: .scaleTwoOctaves, hands: .left).launch
        XCTAssertEqual(launch.instrument, .piano)
        XCTAssertEqual(launch.kind, .technique)
        XCTAssertEqual(launch.root, "G")
        XCTAssertEqual(launch.type, "major")
        XCTAssertEqual(launch.octaves, 2)
        XCTAssertEqual(launch.technique, "scaleTwoOctaves")
        XCTAssertEqual(launch.hands, "lh")
        XCTAssertNil(PianoTechniqueSpec(launch: PracticeLaunch(instrument: .piano, kind: .scale, root: "C", type: "major")))
    }

    func testExerciseAndExample() {
        let spec = PianoTechniqueSpec(key: key("G"), row: .scaleOneOctave, hands: .together)
        let exercise = spec.exercise(bpm: 60)
        XCTAssertEqual(exercise.kind, .scale)
        XCTAssertEqual(exercise.pacing, .timed)
        XCTAssertEqual(exercise.scale, Scale(root: .G, type: .major))
        XCTAssertEqual(exercise.passage.events.count, 15)
        let example = spec.example(bpm: 60)
        XCTAssertEqual(example.notes.count, 15)
        XCTAssertEqual(example.notes[1].startBeat, 0.5)
        XCTAssertEqual(example.notes[0].pitches, [55, 67])
        XCTAssertEqual(PianoTechniqueSpec(key: key("C"), row: .arpeggio).exercise(bpm: 60).kind, .playSequence)
        XCTAssertEqual(PianoTechniqueKey.order.count, 24)
        XCTAssertEqual(PianoTechniqueKey.order.prefix(3).map(\.root.name), ["C", "G", "F"])
    }

    func testStatusThresholds() throws {
        let suite = "PianoTechniqueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = PracticeMemory(defaults: defaults)
        let spec = PianoTechniqueSpec(key: key("C"), row: .scaleOneOctave, hands: .right)
        XCTAssertEqual(spec.status(in: memory), .new)
        memory.notePracticed(spec.launch, title: spec.title, bpm: nil)
        XCTAssertEqual(spec.status(in: memory), .practicing(bestBPM: nil))
        memory.notePracticed(spec.launch, title: spec.title, bpm: spec.row.targetBPM - 1)
        XCTAssertEqual(spec.status(in: memory), .practicing(bestBPM: spec.row.targetBPM - 1))
        memory.notePracticed(spec.launch, title: spec.title, bpm: spec.row.targetBPM)
        XCTAssertEqual(spec.status(in: memory), .atGoal)
        // Other hands keep their own status.
        XCTAssertEqual(PianoTechniqueSpec(key: key("C"), row: .scaleOneOctave, hands: .left).status(in: memory), .new)
        XCTAssertEqual(spec.title, "C major scale · 1 octave · right hand")
    }
}
