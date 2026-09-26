//
//  ListeningTests.swift
//  TabBuddyTests
//
//  WP-B listening tests on synthetic audio (SyntheticAudio.swift). They check
//  the verifier's logic and guard against regressions; they are NOT evidence
//  of accuracy on real guitars or pianos. Real-recording validation (fixture
//  corpus, TUTOR_IMPLEMENTATION.md §10) is pending. Thresholds leave margin
//  below the measured synthetic rates rather than matching them exactly.
//

import XCTest
@testable import TabBuddy

final class ListeningTests: XCTestCase {

    private let rate = SyntheticAudio.sampleRate
    private let chords = SyntheticAudio.openChords

    // MARK: Helpers

    private func event(_ pitches: [Int], id: Int = 0) -> ExpectedEvent {
        ExpectedEvent(id: id, pitches: pitches, beat: Double(id), durationBeats: 1,
                      measureIndex: 0, positionInMeasure: 0)
    }

    /// Room noise bed with `signal` mixed in at `lead` seconds.
    private func take(_ signal: [Float], lead: Double = 0.5, noise: Double = 0.001, seed: UInt64 = 1) -> [Float] {
        var out = SyntheticAudio.roomNoise(seconds: lead + Double(signal.count) / rate + 0.3, rms: noise, seed: seed)
        SyntheticAudio.mix(signal, into: &out, at: Int(lead * rate))
        return out
    }

    /// Feeds `samples` in 512-sample chunks (arming at `armAt` seconds) and flushes.
    private func verify(_ samples: [Float], profile: InstrumentProfile, events: [ExpectedEvent],
                        window: ExpectedNoteVerifier.Window = .wait, armAt: Double = 0) -> [VerificationResult] {
        let v = ExpectedNoteVerifier(sampleRate: rate, profile: profile)
        var out: [VerificationResult] = []
        var armed = false
        var i = 0
        while i < samples.count {
            if !armed && Double(i) / rate >= armAt { v.arm(events, window: window); armed = true }
            let e = min(samples.count, i + 512)
            out += v.process(samples: Array(samples[i..<e]))
            i = e
        }
        out += v.finish()
        return out
    }

    private func isHit(_ r: [VerificationResult], id: Int = 0) -> Bool {
        r.contains { $0.expectedID == id && $0.grade == .hit }
    }

    private func sequence(_ items: [(Double, [Int])], total: Double, seed: UInt64 = 1) -> [Float] {
        var out = SyntheticAudio.roomNoise(seconds: total, rms: 0.001, seed: seed)
        for (i, (t, p)) in items.enumerated() {
            let s = p.count == 1
                ? SyntheticAudio.guitarNote(midi: p[0], seconds: 2, seed: seed &+ UInt64(i))
                : SyntheticAudio.guitarChord(p, seconds: 2.5, seed: seed &+ UInt64(i))
            SyntheticAudio.mix(s, into: &out, at: Int(t * rate))
        }
        return out
    }

    // MARK: Guitar single notes and chords

    func testGuitarSingleNotesE2toE5() {
        var hits = 0, total = 0, onsetErrors: [Double] = []
        for m in 40...76 {
            let s = take(SyntheticAudio.guitarNote(midi: m, seed: UInt64(m)), seed: UInt64(m))
            let r = verify(s, profile: .acousticGuitar, events: [event([m])])
            total += 1
            if let h = r.first(where: { $0.grade == .hit }) {
                hits += 1
                onsetErrors.append(abs(h.onsetTime - 0.5))
            }
        }
        let rateHit = Double(hits) / Double(total)
        print("[WP-B] guitar single notes E2–E5 hit rate \(hits)/\(total) = \(rateHit); max onset error \(onsetErrors.max() ?? -1) s")
        XCTAssertGreaterThanOrEqual(rateHit, 0.95)
        XCTAssertLessThan(onsetErrors.max() ?? 1, 0.03)
    }

    func testOpenChordsHit() {
        var hits = 0, total = 0
        var failures: [String] = []
        for (name, pitches) in chords.sorted(by: { $0.key < $1.key }) {
            for seed in [UInt64(11), 23] {
                let s = take(SyntheticAudio.guitarChord(pitches, seed: seed &* 100 &+ UInt64(pitches[0])), seed: seed)
                let r = verify(s, profile: .acousticGuitar, events: [event(pitches)])
                total += 1
                if isHit(r) { hits += 1 } else { failures.append("\(name)/\(seed): \(r.map(\.grade.rawValue))") }
            }
        }
        print("[WP-B] open chords hit rate \(hits)/\(total); misses: \(failures)")
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(total), 0.9)
    }

    /// iPad on a stand: ~18 dB quieter, room reverb, more room noise.
    func testDistantDeviceWithReverb() {
        var hits = 0, total = 0
        for m in stride(from: 40, through: 76, by: 4) {
            let s = take(SyntheticAudio.distant(SyntheticAudio.guitarNote(midi: m, seed: UInt64(m) &+ 500)),
                         noise: 0.0015, seed: UInt64(m))
            total += 1
            if isHit(verify(s, profile: .acousticGuitar, events: [event([m])])) { hits += 1 }
        }
        for name in ["E", "A", "D", "G", "C", "Am"] {
            let p = chords[name]!
            let s = take(SyntheticAudio.distant(SyntheticAudio.guitarChord(p, seed: UInt64(p[1]) &+ 900)),
                         noise: 0.0015, seed: 9)
            total += 1
            if isHit(verify(s, profile: .acousticGuitar, events: [event(p)])) { hits += 1 }
        }
        print("[WP-B] distant/reverb hit rate \(hits)/\(total)")
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(total), 0.85)
    }

    // MARK: False hits

    func testNoFalseHitsOnSilenceAndNoise() {
        let expectations: [[Int]] = [[40], [52], [64], [57], chords["E"]!, chords["C"]!, chords["Am"]!]
        var runs = 0, falseHits = 0
        var signals: [[Float]] = [
            SyntheticAudio.silence(seconds: 2.5),
            SyntheticAudio.pinkNoise(seconds: 2.5, rms: 0.0001, seed: 1),
        ]
        for (i, level) in [0.003, 0.02, 0.08].enumerated() {
            signals.append(SyntheticAudio.roomNoise(seconds: 2.5, rms: level, seed: UInt64(i + 3)))
            signals.append(SyntheticAudio.pinkNoise(seconds: 2.5, rms: level, seed: UInt64(i + 7)))
        }
        for s in signals {
            for p in expectations {
                runs += 1
                if isHit(verify(s, profile: .acousticGuitar, events: [event(p)])) { falseHits += 1 }
            }
            runs += 1
            if isHit(verify(s, profile: .piano, events: [event([60])])) { falseHits += 1 }
        }
        print("[WP-B] false hits on silence/noise: \(falseHits)/\(runs)")
        XCTAssertEqual(falseHits, 0)
    }

    func testWrongChordRejected() {
        let pairs = [("E", "Em"), ("Em", "E"), ("C", "Am"), ("Am", "C"), ("A", "Am"), ("D", "Dm")]
        var falseHits = 0, wrongFlags = 0, runs = 0
        for (expected, played) in pairs {
            for seed in [UInt64(3), 7] {
                let s = take(SyntheticAudio.guitarChord(chords[played]!, seed: seed &* 7), seed: seed)
                let r = verify(s, profile: .acousticGuitar, events: [event(chords[expected]!)])
                runs += 1
                if isHit(r) { falseHits += 1; print("false hit: expected \(expected), played \(played)") }
                if r.contains(where: { $0.grade == .wrongPitch }) { wrongFlags += 1 }
            }
        }
        print("[WP-B] wrong chord: false hits \(falseHits)/\(runs), flagged wrongPitch \(wrongFlags)/\(runs) (rest partial)")
        XCTAssertEqual(falseHits, 0)
    }

    func testOctaveAndTwelfthErrorsRejected() {
        // (expected, played): octave down/up, and twelfth (third-harmonic) confusions.
        let cases = [(52, 40), (40, 52), (57, 45), (45, 57), (59, 40), (64, 45), (64, 52)]
        var falseHits = 0, flagged = 0
        for (e, p) in cases {
            let s = take(SyntheticAudio.guitarNote(midi: p, seed: UInt64(p)), seed: 3)
            let r = verify(s, profile: .acousticGuitar, events: [event([e])])
            if isHit(r) { falseHits += 1; print("false hit: expected \(e), played \(p)") }
            if r.contains(where: { $0.grade == .wrongPitch && $0.unexpected.contains(p) }) { flagged += 1 }
        }
        print("[WP-B] octave/twelfth: false hits \(falseHits)/\(cases.count), reported played pitch \(flagged)/\(cases.count)")
        XCTAssertEqual(falseHits, 0)
        XCTAssertGreaterThanOrEqual(flagged, cases.count / 2)
    }

    // MARK: Ringing strings

    func testRingingChordDoesNotSatisfyNewEvent() {
        let ringing = sequence([(0.5, chords["E"]!)], total: 3)
        // A new expected event armed while E still rings, with no new strum.
        XCTAssertFalse(isHit(verify(ringing, profile: .acousticGuitar,
                                    events: [event(chords["Em"]!, id: 1)], armAt: 1.0), id: 1))
        // Same chord armed twice: the single strum satisfies only the first.
        let twice = verify(ringing, profile: .acousticGuitar,
                           events: [event(chords["E"]!, id: 0), event(chords["E"]!, id: 1)])
        XCTAssertTrue(isHit(twice, id: 0))
        XCTAssertFalse(isHit(twice, id: 1))
        // Ringing C, then Am strummed while G is expected.
        let cThenAm = sequence([(0.5, chords["C"]!), (1.3, chords["Am"]!)], total: 3.5)
        let r = verify(cThenAm, profile: .acousticGuitar,
                       events: [event(chords["C"]!, id: 0), event(chords["G"]!, id: 1)])
        XCTAssertTrue(isHit(r, id: 0))
        XCTAssertFalse(isHit(r, id: 1))
    }

    func testChordChangesAndMelodyOverRingingNotes() {
        let eAm = sequence([(0.5, chords["E"]!), (1.3, chords["Am"]!)], total: 3.5)
        let r = verify(eAm, profile: .acousticGuitar,
                       events: [event(chords["E"]!, id: 0), event(chords["Am"]!, id: 1)])
        XCTAssertTrue(isHit(r, id: 0))
        XCTAssertTrue(isHit(r, id: 1))

        let melody = [52, 55, 57, 59, 57, 55]
        let s = sequence(melody.enumerated().map { (0.5 + 0.4 * Double($0.offset), [$0.element]) }, total: 4)
        let m = verify(s, profile: .acousticGuitar, events: melody.enumerated().map { event([$0.element], id: $0.offset) })
        let hits = melody.indices.filter { isHit(m, id: $0) }.count
        print("[WP-B] melody over ringing notes: \(hits)/\(melody.count)")
        XCTAssertEqual(hits, melody.count)
    }

    // MARK: Timed mode

    func testTimedModeWindows() {
        let names = ["C", "G", "Am", "Em", "D", "A"]
        let times = names.indices.map { 0.5 + Double($0) * 0.8 }
        let events = names.indices.map { event(chords[names[$0]]!, id: $0) }
        let onTime = sequence(names.indices.map { (times[$0], chords[names[$0]]!) }, total: 6)
        let r = verify(onTime, profile: .acousticGuitar, events: events,
                       window: .timed(times: times, tolerance: 0.15))
        XCTAssertEqual(r.count, names.count, "one result per event")
        XCTAssertEqual(r.filter { $0.grade == .hit }.count, names.count)
        for res in r where res.grade == .hit {
            XCTAssertEqual(res.onsetTime, times[res.expectedID], accuracy: 0.03)
        }

        // Third chord 0.3 s late (outside ±0.15), fifth omitted.
        var items = names.indices.map { (times[$0] + ($0 == 2 ? 0.3 : 0), chords[names[$0]]!) }
        items.remove(at: 4)
        let off = verify(sequence(items, total: 6), profile: .acousticGuitar, events: events,
                         window: .timed(times: times, tolerance: 0.15))
        let grades = Dictionary(off.map { ($0.expectedID, $0.grade) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(grades[2], .missed)
        XCTAssertEqual(grades[4], .missed)
        for id in [0, 1, 3, 5] { XCTAssertEqual(grades[id], .hit, "event \(id)") }
    }

    func testLatencyCompensationShiftsTimes() {
        let s = take(SyntheticAudio.guitarNote(midi: 55, seed: 5))
        let v = ExpectedNoteVerifier(sampleRate: rate, profile: .acousticGuitar)
        v.latencyCompensation = 0.1
        v.arm([event([55])], window: .timed(times: [0.4], tolerance: 0.08))
        var r = v.process(samples: s)
        r += v.finish()
        XCTAssertEqual(r.first?.grade, .hit)
        XCTAssertEqual(r.first?.onsetTime ?? 0, 0.4, accuracy: 0.03)
    }

    // MARK: Piano

    func testPianoNotesAcrossRange() {
        var hits = 0, total = 0
        var misses: [Int] = []
        for m in Array(stride(from: 21, through: 105, by: 4)) + [108] {
            let s = take(SyntheticAudio.pianoNote(midi: m, seed: UInt64(m)), seed: UInt64(m))
            total += 1
            if isHit(verify(s, profile: .piano, events: [event([m])])) { hits += 1 } else { misses.append(m) }
        }
        print("[WP-B] piano single notes A0–C8 hit rate \(hits)/\(total); misses \(misses)")
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(total), 0.9)
    }

    func testPianoTriadsAndOctaveError() {
        let triads: [[Int]] = [[60, 64, 67], [57, 60, 64], [62, 65, 69], [48, 52, 55], [72, 76, 79], [43, 47, 50], [65, 69, 72]]
        var hits = 0
        for t in triads {
            let s = take(SyntheticAudio.pianoChord(t, seed: UInt64(t[0])), seed: 5)
            if isHit(verify(s, profile: .piano, events: [event(t)])) { hits += 1 }
        }
        print("[WP-B] piano triads hit rate \(hits)/\(triads.count)")
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(triads.count), 0.85)

        // C major expected, C minor played.
        let minor = take(SyntheticAudio.pianoChord([60, 63, 67], seed: 60), seed: 5)
        XCTAssertFalse(isHit(verify(minor, profile: .piano, events: [event([60, 64, 67])])))
        // Middle C expected, C3 played.
        let low = take(SyntheticAudio.pianoNote(midi: 48, seed: 48), seed: 5)
        XCTAssertFalse(isHit(verify(low, profile: .piano, events: [event([60])])))
    }

    // MARK: Octave-tolerant (chord symbols without a register)

    private func tolerant(_ pitches: [Int], name: String? = nil, id: Int = 0) -> ExpectedEvent {
        var e = event(pitches, id: id)
        e.octaveTolerant = true
        e.chordName = name
        return e
    }

    func testOctaveTolerantInversionsAndOctavesHit() {
        let cMajor = tolerant([60, 64, 67], name: "C")
        let voicings: [[Int]] = [[64, 67, 72], [67, 72, 76], [48, 52, 55], [36, 48, 52, 55], [60, 67, 76]]
        var hits = 0
        for (i, v) in voicings.enumerated() {
            let s = take(SyntheticAudio.pianoChord(v, seed: UInt64(40 + i)), seed: 2)
            let r = verify(s, profile: .piano, events: [cMajor])
            if isHit(r) {
                hits += 1
                // `heard` reports the sounding pitches, not the expected voicing.
                let heard = r.first { $0.grade == .hit }!.heard
                XCTAssertEqual(Set(heard.map { $0 % 12 }), [0, 4, 7], "voicing \(v) heard \(heard)")
                XCTAssertFalse(Set(heard).isDisjoint(with: Set(v)), "voicing \(v) heard \(heard)")
            } else {
                print("[WP-B] octave-tolerant miss \(v): \(r.map(\.grade.rawValue))")
            }
        }
        print("[WP-B] octave-tolerant C major voicings hit \(hits)/\(voicings.count)")
        XCTAssertGreaterThanOrEqual(hits, voicings.count - 1)

        // Guitar open voicings against register-free expectations.
        var guitarHits = 0
        let names = ["C", "G", "D", "A", "E", "Am", "Em", "Dm"]
        for name in names {
            let p = chords[name]!
            let pcs = Set(p.map { $0 % 12 }).sorted().map { $0 + 60 }
            let s = take(SyntheticAudio.guitarChord(p, seed: UInt64(p[1]) &+ 3), seed: 2)
            if isHit(verify(s, profile: .acousticGuitar, events: [tolerant(pcs, name: name)])) { guitarHits += 1 }
        }
        print("[WP-B] octave-tolerant guitar open chords hit \(guitarHits)/\(names.count)")
        XCTAssertGreaterThanOrEqual(guitarHits, names.count - 1)
    }

    func testOctaveTolerantRejectsWrongQuality() {
        let cMajor = tolerant([60, 64, 67], name: "C")
        for (i, v) in [[60, 63, 67], [63, 67, 72], [48, 51, 55]].enumerated() {
            let s = take(SyntheticAudio.pianoChord(v, seed: UInt64(70 + i)), seed: 3)
            XCTAssertFalse(isHit(verify(s, profile: .piano, events: [cMajor])), "C minor \(v) graded as C major")
        }
        for (expected, played) in [("E", "Em"), ("Em", "E"), ("D", "Dm"), ("A", "Am"), ("C", "Am")] {
            let pcs = Set(chords[expected]!.map { $0 % 12 }).sorted().map { $0 + 60 }
            let s = take(SyntheticAudio.guitarChord(chords[played]!, seed: 41), seed: 2)
            XCTAssertFalse(isHit(verify(s, profile: .acousticGuitar, events: [tolerant(pcs, name: expected)])),
                           "\(played) graded as \(expected)")
        }
    }

    func testOctaveTolerantSlashChordNeedsBass() {
        let cOverE = tolerant([52, 60, 67], name: "C/E")
        for (i, v) in [[52, 60, 67], [40, 55, 60, 64]].enumerated() {
            let s = take(SyntheticAudio.pianoChord(v, seed: UInt64(90 + i)), seed: 4)
            XCTAssertTrue(isHit(verify(s, profile: .piano, events: [cOverE])), "E-bass voicing \(v)")
        }
        for (i, v) in [[48, 52, 55], [36, 43, 52], [55, 60, 64]].enumerated() {
            let s = take(SyntheticAudio.pianoChord(v, seed: UInt64(95 + i)), seed: 4)
            XCTAssertFalse(isHit(verify(s, profile: .piano, events: [cOverE])), "non-E bass \(v)")
        }
    }

    func testOctaveTolerantTimedModeAndRinging() {
        // Timed: C then F (other octaves than expected), then a strum-free window.
        let events = [tolerant([60, 64, 67], name: "C", id: 0), tolerant([65, 69, 72], name: "F", id: 1),
                      tolerant([67, 71, 74], name: "G", id: 2)]
        var out = SyntheticAudio.roomNoise(seconds: 4, rms: 0.001, seed: 6)
        SyntheticAudio.mix(SyntheticAudio.pianoChord([48, 52, 55], seconds: 2, seed: 1), into: &out, at: Int(0.5 * rate))
        SyntheticAudio.mix(SyntheticAudio.pianoChord([53, 57, 60], seconds: 2, seed: 2), into: &out, at: Int(1.3 * rate))
        let r = verify(out, profile: .piano, events: events, window: .timed(times: [0.5, 1.3, 2.1], tolerance: 0.15))
        let grades = Dictionary(r.map { ($0.expectedID, $0.grade) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(grades[0], .hit)
        XCTAssertEqual(grades[1], .hit)
        XCTAssertEqual(grades[2], .missed, "ringing F must not satisfy G")
    }

    // MARK: Tier C

    private func precisionRecall(truth: [(Double, [Int])], detected: [DetectedEvent], pitchClass: Bool)
        -> (precision: Double, recall: Double) {
        var tp = 0, fp = 0, fn = 0
        var used = Set<Int>()
        let key: (Int) -> Int = { pitchClass ? (($0 % 12) + 12) % 12 : $0 }
        for (t, pitches) in truth {
            let expected = Set(pitches.map(key))
            if let j = detected.indices.first(where: { !used.contains($0) && abs(detected[$0].time - t) < 0.06 }) {
                used.insert(j)
                let got = Set(detected[j].pitches.map(key))
                tp += got.intersection(expected).count
                fp += got.subtracting(expected).count
                fn += expected.subtracting(got).count
            } else {
                fn += expected.count
            }
        }
        for j in detected.indices where !used.contains(j) { fp += Set(detected[j].pitches.map(key)).count }
        return (Double(tp) / Double(max(1, tp + fp)), Double(tp) / Double(max(1, tp + fn)))
    }

    func testPolyphonicTranscriberOnSyntheticChords() {
        let transcriber = IterativeHarmonicTranscriber()

        let pianoChords: [[Int]] = [[60, 64, 67], [57, 60, 64], [53, 57, 60, 65], [55, 59, 62], [48, 55, 64],
                                    [62, 65, 69], [36, 48, 52, 55], [64, 67, 71, 74], [45, 57, 60, 64], [72, 76, 79]]
        let pianoTruth = pianoChords.indices.map { (0.5 + Double($0) * 0.9, pianoChords[$0]) }
        var piano = SyntheticAudio.roomNoise(seconds: 10.5, rms: 0.001, seed: 2)
        for (i, (t, p)) in pianoTruth.enumerated() {
            SyntheticAudio.mix(SyntheticAudio.pianoChord(p, seconds: 2, seed: UInt64(i) &+ 1), into: &piano, at: Int(t * rate))
        }
        let pianoEvents = transcriber.transcribe(samples: piano, sampleRate: rate, profile: .piano)
        let pExact = precisionRecall(truth: pianoTruth, detected: pianoEvents, pitchClass: false)
        XCTAssertTrue(pianoEvents.allSatisfy { $0.source == .polyphonic && $0.pitches.count == $0.confidences.count })

        let names = ["C", "G", "Am", "Em", "D", "A", "E", "Dm"]
        let guitarTruth = names.indices.map { (0.5 + Double($0) * 0.9, chords[names[$0]]!) }
        let guitar = sequence(guitarTruth, total: 8.5)
        let guitarEvents = transcriber.transcribe(samples: guitar, sampleRate: rate, profile: .acousticGuitar)
        let gExact = precisionRecall(truth: guitarTruth, detected: guitarEvents, pitchClass: false)
        let gClass = precisionRecall(truth: guitarTruth, detected: guitarEvents, pitchClass: true)

        print("[WP-B] tier C piano exact P \(pExact.precision) R \(pExact.recall); guitar exact P \(gExact.precision) R \(gExact.recall), pitch class P \(gClass.precision) R \(gClass.recall)")
        XCTAssertGreaterThanOrEqual(pExact.precision, 0.65)
        XCTAssertGreaterThanOrEqual(pExact.recall, 0.65)
        // Guitar voicings double pitches at the octave; those cannot be
        // separated from the lower string's overtones, so exact recall is low.
        XCTAssertGreaterThanOrEqual(gClass.precision, 0.6)
        XCTAssertGreaterThanOrEqual(gClass.recall, 0.65)
        XCTAssertGreaterThanOrEqual(gExact.precision, 0.55)
    }

    // MARK: Tier A, calibration, advice, synth

    /// Tier A is the unchanged NoteTranscriberCore (YIN); on the synthetic
    /// guitar it can lock an octave low, so pitch class and timing are checked
    /// and the exact-octave rate is reported.
    func testMonophonicListenerEmitsNotes() {
        let notes = [45, 50, 52, 55, 57, 59, 62, 64, 69]
        var exact = 0
        for m in notes {
            let listener = MonophonicListener(sampleRate: rate, profile: .acousticGuitar)
            let s = take(SyntheticAudio.guitarNote(midi: m, seed: UInt64(m)), seed: UInt64(m))
            var events: [DetectedEvent] = []
            var i = 0
            while i < s.count {
                let e = min(s.count, i + 512)
                events += listener.process(samples: Array(s[i..<e]))
                i = e
            }
            guard let first = events.first else { XCTFail("no event for \(m)"); continue }
            XCTAssertEqual(first.pitches.count, 1)
            XCTAssertEqual((first.pitches[0] - m) % 12, 0, "midi \(m) heard \(first.pitches)")
            XCTAssertEqual(first.source, .monophonic)
            XCTAssertEqual(first.time, 0.5, accuracy: 0.05)
            if first.pitches == [m] { exact += 1 }
        }
        print("[WP-B] tier A exact-octave rate \(exact)/\(notes.count)")
    }

    func testLatencyEstimate() {
        let cues = (0..<8).map { 1.0 + Double($0) * 0.75 }
        // Onsets 60 ms late with ±8 ms jitter, one missed cue, one stray onset.
        var onsets = cues.enumerated().compactMap { $0.offset == 3 ? nil : $0.element + 0.06 + Double(($0.offset % 3) - 1) * 0.008 }
        onsets.append(2.2)
        let est = LatencyCalibrator.estimate(cueTimes: cues, onsetTimes: onsets)
        XCTAssertNotNil(est)
        XCTAssertEqual(est?.latency ?? 0, 0.06, accuracy: 0.01)
        XCTAssertEqual(est?.matched, 7)
        XCTAssertTrue(est?.isReliable ?? false)
        XCTAssertNil(LatencyCalibrator.estimate(cueTimes: cues, onsetTimes: [9.9]))
    }

    @MainActor
    func testLatencyStorePerRoute() {
        let defaults = UserDefaults(suiteName: "ListeningTests-\(UUID().uuidString)")!
        let store = UserDefaultsLatencyStore(defaults: defaults)
        store.setLatency(0.05, forRoute: "out=Speaker;in=MicrophoneBuiltIn")
        store.setLatency(0.012, forRoute: "out=USBAudio;in=USBAudio")
        XCTAssertEqual(store.latency(forRoute: "out=Speaker;in=MicrophoneBuiltIn"), 0.05)
        XCTAssertEqual(store.latency(forRoute: "out=USBAudio;in=USBAudio"), 0.012)
        XCTAssertNil(store.latency(forRoute: "out=BluetoothA2DPOutput;in=MicrophoneBuiltIn"))
    }

    func testInputLevelAdvice() {
        XCTAssertEqual(InputLevelAdvisor.assess(peakDBFS: -0.5, noiseFloorDBFS: -60, instrument: .guitar, isPad: true).status, .tooLoud)
        XCTAssertEqual(InputLevelAdvisor.assess(peakDBFS: -58, noiseFloorDBFS: -60, instrument: .guitar, isPad: true).status, .noSignal)
        XCTAssertEqual(InputLevelAdvisor.assess(peakDBFS: -48, noiseFloorDBFS: -70, instrument: .piano, isPad: true).status, .tooQuiet)
        XCTAssertEqual(InputLevelAdvisor.assess(peakDBFS: -20, noiseFloorDBFS: -38, instrument: .guitar, isPad: true).status, .noisyRoom)
        XCTAssertEqual(InputLevelAdvisor.assess(peakDBFS: -20, noiseFloorDBFS: -62, instrument: .guitar, isPad: true).status, .good)
    }

    func testDecimatorPreservesPitchAndTiming() {
        let d = ListeningDecimator(factor: 2)
        let n = 44100
        let tone = (0..<n).map { Float(sin(2 * Double.pi * 440 * Double($0) / 44100)) * ($0 >= 22050 ? 1 : 0) }
        var out: [Float] = []
        for start in stride(from: 0, to: n, by: 333) { out += d.process(Array(tone[start..<min(n, start + 333)])) }
        XCTAssertEqual(out.count, n / 2, accuracy: 20)
        // The step at input 22050 appears near output 11025.
        let first = out.firstIndex { abs($0) > 0.5 } ?? 0
        XCTAssertEqual(first, 11025, accuracy: 12)
    }

    @MainActor
    func testSynthFindsBundledSoundFont() {
        let url = TutorSynth.soundFontURL
        XCTAssertNotNil(url)
        if let url { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(TutorSynth.program(for: .piano), 0)
        XCTAssertEqual(TutorSynth.program(for: .guitar), 25)
    }
}

// MARK: - Bass profile, take clock, route keys, calibration store

extension ListeningTests {

    /// Bass guitar note through a phone mic (fundamentals below ~130 Hz are weak).
    private func bassNote(_ midi: Int, seed: UInt64) -> [Float] {
        let s = SyntheticAudio.pluck(midi: midi, seconds: 1.6, amplitude: 0.35, seed: seed)
        return SyntheticAudio.phoneMic(s)
    }

    func testBassGuitarNotesE1toG2() {
        var hits = 0, total = 0, failures: [String] = []
        for m in 28...43 {
            let s = take(bassNote(m, seed: UInt64(m) &* 3), seed: UInt64(m))
            let r = verify(s, profile: .bassGuitar, events: [event([m])])
            total += 1
            if isHit(r) { hits += 1 } else { failures.append("\(m): \(r.map(\.grade.rawValue))") }
        }
        print("[WP-B] bass E1–G2 hit rate \(hits)/\(total); misses: \(failures)")
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(total), 0.85)
    }

    func testBassGuitarRejectsWrongNoteAndSilence() {
        // A2 played for G2, and room noise alone.
        let wrong = verify(take(bassNote(45, seed: 9)), profile: .bassGuitar, events: [event([43])])
        XCTAssertFalse(isHit(wrong))
        let quiet = verify(SyntheticAudio.roomNoise(seconds: 2, rms: 0.002, seed: 4), profile: .bassGuitar,
                           events: [event([33])])
        XCTAssertFalse(isHit(quiet))
    }

    func testBassPresetSelection() {
        XCTAssertEqual(InstrumentProfile.preset(for: .guitar, pitches: [28, 40]), .bassGuitar)
        XCTAssertEqual(InstrumentProfile.preset(for: .guitar, pitches: [40, 64]), .acousticGuitar)
        XCTAssertEqual(InstrumentProfile.preset(for: .guitar, pitches: [Int]()), .acousticGuitar)
        XCTAssertEqual(InstrumentProfile.preset(for: .piano, pitches: [21]), .piano)
        XCTAssertEqual(InstrumentProfile.preset(for: .guitar, isBass: true), .bassGuitar)
        XCTAssertTrue(InstrumentProfile.bassGuitar.isBass)
        XCTAssertFalse(InstrumentProfile.acousticGuitar.isBass)
        XCTAssertTrue(InstrumentProfile.bassGuitar.pitchRange.contains(28))
        XCTAssertLessThanOrEqual(InstrumentProfile.bassGuitar.maxPolyphony, 3)
    }

    func testVerifierSeedsClockFromChunkStart() {
        let s = take(SyntheticAudio.guitarNote(midi: 55, seed: 5))
        let v = ExpectedNoteVerifier(sampleRate: rate, profile: .acousticGuitar)
        v.arm([event([55])], window: .wait)
        var r: [VerificationResult] = []
        // The verifier joins one second into the take.
        let offset = Int(rate)
        var i = 0
        while i < s.count {
            let e = min(s.count, i + 1024)
            r += v.process(samples: Array(s[i..<e]), startSample: offset + i)
            i = e
        }
        r += v.finish()
        let hit = r.first { $0.grade == .hit }
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.onsetTime ?? 0, 1.5, accuracy: 0.03)
    }

    /// Simulated tap: buffers of `bufferSize` samples, each delivered
    /// `bufferSize / rate + deliveryLag` after its first sample was captured.
    /// A cue computed from the host clock at `cueWall` and a note played on
    /// the cue (reaching the input `inputDelay` later) must grade on time
    /// whatever the buffer size, once latency = the calibrated input delay.
    private func timedTake(bufferSize: Int, latency: TimeInterval, inputDelay: TimeInterval = 0.035,
                           deliveryLag: TimeInterval = 0.004) -> (results: [VerificationResult], times: [TimeInterval]) {
        let hostZero = 5000.0            // host seconds of take sample 0
        let cueWall = hostZero + 0.73    // when the UI computes the passage start
        let notes = [55, 59, 62]
        let spacing = 0.8
        // Buffers delivered before the cue anchor the host → take mapping.
        var map = TakeClockMap()
        var k = 0
        while hostZero + Double((k + 1) * bufferSize) / rate + deliveryLag <= cueWall {
            map.anchor(sample: k * bufferSize, hostSeconds: hostZero + Double(k * bufferSize) / rate, rate: rate)
            k += 1
        }
        let cueNow = map.takeTime(hostSeconds: cueWall) ?? 0
        let passageStart = cueNow + 0.5
        let times = notes.indices.map { passageStart + Double($0) * spacing }
        // The player hits each note as its cue shows; it reaches the input `inputDelay` later.
        var audio = SyntheticAudio.roomNoise(seconds: passageStart + 3.5, rms: 0.001, seed: 3)
        for (i, m) in notes.enumerated() {
            SyntheticAudio.mix(SyntheticAudio.guitarNote(midi: m, seconds: 1.2, seed: UInt64(10 + i)),
                               into: &audio, at: Int((times[i] + inputDelay) * rate))
        }
        let v = ExpectedNoteVerifier(sampleRate: rate, profile: .acousticGuitar)
        v.latencyCompensation = latency
        let events = notes.enumerated().map { event([$0.element], id: $0.offset) }
        var out: [VerificationResult] = []
        var armed = false
        var start = 0
        while start < audio.count {
            let delivered = hostZero + Double(start + bufferSize) / rate + deliveryLag
            if !armed && delivered > cueWall {
                v.arm(events, window: .timed(times: times, tolerance: 0.15))
                armed = true
            }
            let end = min(audio.count, start + bufferSize)
            out += v.process(samples: Array(audio[start..<end]), startSample: start)
            start = end
        }
        out += v.finish()
        return (out, times)
    }

    func testHostClockCuesGradeOnTimeForAnyBufferSize() {
        for size in [256, 1024, 4410] {
            let (r, times) = timedTake(bufferSize: size, latency: 0.035)
            XCTAssertEqual(r.filter { $0.grade == .hit }.count, 3, "buffer \(size): \(r.map(\.grade.rawValue))")
            for res in r where res.grade == .hit {
                XCTAssertEqual(res.onsetTime, times[res.expectedID], accuracy: 0.03, "buffer \(size)")
            }
        }
    }

    func testCalibratedLatencyShiftsTimedResults() {
        // Uncalibrated by 0.25 s: every detection lands outside the ±0.15 s window.
        let (late, _) = timedTake(bufferSize: 1024, latency: 0.035 + 0.25)
        XCTAssertEqual(late.filter { $0.grade == .hit }.count, 0, "\(late.map(\.grade.rawValue))")
        XCTAssertTrue(late.allSatisfy { $0.grade == .missed })
        // Shifting by less than the tolerance still hits, with the onset moved by the difference.
        let (shifted, times) = timedTake(bufferSize: 1024, latency: 0.035 + 0.08)
        let hit = shifted.first { $0.grade == .hit && $0.expectedID == 0 }
        XCTAssertEqual(hit?.onsetTime ?? 0, times[0] - 0.08, accuracy: 0.03)
    }

    /// Calibration measures onset sample time minus the host-mapped cue time,
    /// which is exactly what grading subtracts.
    func testCalibrationEstimatesTheSubtractedDelay() {
        let inputDelay = 0.045
        let bufferSize = 4410
        let hostZero = 100.0
        var map = TakeClockMap()
        // Mapping from a buffer delivered a while after capture; cues shown every 0.75 s from 1 s.
        map.anchor(sample: 4 * bufferSize, hostSeconds: hostZero + Double(4 * bufferSize) / rate, rate: rate)
        let cueWalls = (0..<8).map { hostZero + 1.0 + Double($0) * 0.75 }
        let cues = cueWalls.compactMap { map.takeTime(hostSeconds: $0) }
        var audio = SyntheticAudio.roomNoise(seconds: 8, rms: 0.001, seed: 8)
        for (i, c) in cues.enumerated() {
            SyntheticAudio.mix(SyntheticAudio.guitarNote(midi: 52, seconds: 0.6, seed: UInt64(30 + i)),
                               into: &audio, at: Int((c + inputDelay) * rate))
        }
        let factor = ListeningMath.decimationFactor(forInputRate: rate)
        let decimator = ListeningDecimator(factor: factor)
        let detector = ListeningOnsetDetector(rate: rate / Double(factor), profile: .acousticGuitar)
        var onsets: [TimeInterval] = []
        var i = 0
        while i < audio.count {
            let e = min(audio.count, i + bufferSize)
            onsets += detector.process(decimator.process(Array(audio[i..<e]))).map { Double($0.index) / (rate / Double(factor)) }
            i = e
        }
        let est = LatencyCalibrator.estimate(cueTimes: cues, onsetTimes: onsets)
        XCTAssertEqual(est?.latency ?? 0, inputDelay, accuracy: 0.015)
        XCTAssertTrue(est?.isReliable ?? false)
    }

    func testTakeClockMapFollowsLatestAnchor() {
        var map = TakeClockMap()
        XCTAssertNil(map.takeTime(hostSeconds: 10))
        map.anchor(sample: 0, hostSeconds: 10, rate: 48000)
        XCTAssertEqual(map.takeTime(hostSeconds: 10.5) ?? 0, 0.5, accuracy: 1e-9)
        // A dropped buffer: the next anchor's sample index is behind the host clock.
        map.anchor(sample: 48000, hostSeconds: 11.1, rate: 48000)
        XCTAssertEqual(map.takeTime(hostSeconds: 11.1) ?? 0, 1.0, accuracy: 1e-9)
    }

    func testRouteKeyPredictsListeningRoute() {
        let speakerMic = "out=Speaker;in=MicrophoneBuiltIn"
        // Playback-only category: no inputs in the current route.
        XCTAssertEqual(TutorAudioSession.routeKey(outputs: [.builtInSpeaker], inputs: [], preferredInput: nil,
                                                  availableInputs: [.builtInMic]), speakerMic)
        XCTAssertEqual(TutorAudioSession.routeKey(outputs: [.builtInSpeaker], inputs: [], preferredInput: nil,
                                                  availableInputs: []), speakerMic)
        // Configured for listening: the same key.
        XCTAssertEqual(TutorAudioSession.routeKey(outputs: [.builtInSpeaker], inputs: [.builtInMic], preferredInput: nil,
                                                  availableInputs: [.builtInMic]), speakerMic)
        // Earpiece routing becomes the speaker (listening uses .defaultToSpeaker).
        XCTAssertEqual(TutorAudioSession.routeKey(outputs: [.builtInReceiver], inputs: [.builtInMic], preferredInput: nil,
                                                  availableInputs: [.builtInMic]), speakerMic)
        // Bluetooth HFP (another engine allowed it) becomes A2DP out + built-in mic.
        XCTAssertEqual(TutorAudioSession.routeKey(outputs: [.bluetoothHFP], inputs: [.bluetoothHFP], preferredInput: nil,
                                                  availableInputs: [.builtInMic, .bluetoothHFP]),
                       "out=BluetoothA2DPOutput;in=MicrophoneBuiltIn")
        // An attached USB interface is predicted before the session is configured.
        XCTAssertEqual(TutorAudioSession.routeKey(outputs: [.usbAudio], inputs: [], preferredInput: nil,
                                                  availableInputs: [.builtInMic, .usbAudio]), "out=USBAudio;in=USBAudio")
        XCTAssertFalse(TutorAudioSession.isUsableRouteKey("out=Speaker;in=none"))
        XCTAssertTrue(TutorAudioSession.isUsableRouteKey(speakerMic))
        XCTAssertTrue(TutorAudioSession.isUsableRouteKey(TutorAudioSession.currentRouteKey()))
    }

    @MainActor
    func testSharedLatencyStoreIgnoresUnpredictedKeys() throws {
        let tutor = try TutorStore.inMemory()
        let defaults = UserDefaults(suiteName: "ListeningTests-\(UUID().uuidString)")!
        let store = TutorLatency.store(tutor, defaults: defaults)
        store.setLatency(0.05, forRoute: "out=Speaker;in=MicrophoneBuiltIn")
        XCTAssertEqual(tutor.latency(forRoute: "out=Speaker;in=MicrophoneBuiltIn"), 0.05)
        XCTAssertEqual(UserDefaultsLatencyStore(defaults: defaults).latency(forRoute: "out=Speaker;in=MicrophoneBuiltIn"), 0.05)
        // A key saved before routes were predicted is never used.
        tutor.setLatency(0.2, forRoute: "out=Speaker;in=none")
        XCTAssertNil(store.latency(forRoute: "out=Speaker;in=none"))
        store.setLatency(0.3, forRoute: "out=Speaker;in=none")
        XCTAssertEqual(tutor.latency(forRoute: "out=Speaker;in=none"), 0.2)
        // UserDefaults-only values (older lesson calibration) are still read.
        UserDefaultsLatencyStore(defaults: defaults).setLatency(0.03, forRoute: "out=Headphones;in=MicrophoneBuiltIn")
        XCTAssertEqual(store.latency(forRoute: "out=Headphones;in=MicrophoneBuiltIn"), 0.03)
    }
}
