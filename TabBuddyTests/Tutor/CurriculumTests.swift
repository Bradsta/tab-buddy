import SwiftData
import XCTest
@testable import TabBuddy

final class CurriculumTests: XCTestCase {

    // MARK: - Content from the source tree

    static let contentDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tutor
        .deletingLastPathComponent()   // TabBuddyTests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("TabBuddy/Tutor/Content", isDirectory: true)

    static let content = CurriculumLoader.load(directory: contentDirectory)

    private var content: CurriculumContent { Self.content }

    /// Every practice/song/demo step in the content, with its location.
    private func steps() -> [(instrument: TutorInstrument, course: Course, lesson: Lesson, index: Int, step: LessonStep)] {
        var result: [(TutorInstrument, Course, Lesson, Int, LessonStep)] = []
        for (instrument, course) in content.courses.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for location in course.allLessonLocations {
                for (i, step) in location.lesson.steps.enumerated() {
                    result.append((instrument, course, location.lesson, i, step))
                }
            }
        }
        return result
    }

    func testContentLoadsBothCourses() {
        XCTAssertNotNil(content.courses[.guitar])
        XCTAssertNotNil(content.courses[.piano])
        for course in content.courses.values {
            XCTAssertEqual(course.stages.map(\.order), course.stages.map(\.order).sorted())
            XCTAssertFalse(course.mainPathLessons.isEmpty)
        }
        XCTAssertFalse(content.glossary.isEmpty)
    }

    func testContentValidates() {
        let issues = CurriculumValidator.validate(content)
        let errors = issues.filter { $0.severity == .error }
        let warnings = issues.filter { $0.severity == .warning }
        print("CURRICULUM VALIDATION: \(errors.count) errors, \(warnings.count) warnings")
        for issue in issues { print("CURRICULUM ISSUE \(issue)") }
        XCTAssertEqual(errors.count, 0, errors.map(\.description).joined(separator: "\n"))
    }

    func testValidatorCatchesBrokenContent() throws {
        let json = """
        {"id":"guitar.s0","instrument":"guitar","order":0,"title":"T","summary":"s",
         "lessons":[{"id":"guitar.s0.l1","title":"T","summary":"s","minutes":5,"glossaryTerms":["Fret","Nonexistent"],
           "steps":[{"type":"explain","title":"x","body":"b","diagram":{"kind":"fretboard","notes":["7:1","6:3"],"fretRange":[0,2]}},
                    {"type":"explain","title":"x","body":"b","diagram":{"kind":"keyboard","notes":["H4"],"pitchRange":["C5","C4"]}},
                    {"type":"practice","exercise":{"kind":"strumRhythm","prompt":"p","chords":["G","Xm"]}},
                    {"type":"practice","exercise":{"kind":"playSequence","prompt":"p","notes":["E2","E9"],"rhythm":"q q q"}},
                    {"type":"quiz","questions":[{"prompt":"q","choices":["a","b"],"answerIndex":2,"explanation":"e"}]},
                    {"type":"quiz","generator":{"kind":"intervalByEar","params":{"intervals":"M5","speed":"fast"}}},
                    {"type":"song","title":"s","notes":[["E2"],["G2"]],"rhythm":"q q q","bpm":80}]},
          {"id":"guitar.s0.l1","title":"Dup","summary":"s","minutes":5,"steps":[{"type":"quiz","generator":{"kind":"keySignature"}}]}],
         "branches":[{"id":"b","title":"B","summary":"s","unlocksAfter":"guitar.s9.l9","lessons":[]}]}
        """
        let stage = try JSONDecoder().decode(Stage.self, from: Data(json.utf8))
        let content = CurriculumContent(courses: [.guitar: Course(instrument: .guitar, title: "Guitar", stages: [stage])],
                                        glossary: [GlossaryEntry(term: "Fret", definition: "A metal strip.", seeAlso: ["Nut"])],
                                        stageFiles: ["guitar.s0": "tutor-guitar-stage-00.json"], loadIssues: [])
        let issues = CurriculumValidator.validate(content)
        func has(_ severity: CurriculumIssue.Severity, _ fragment: String, step: Int? = nil) -> Bool {
            issues.contains { $0.severity == severity && $0.message.contains(fragment) && (step == nil || $0.stepIndex == step) }
        }
        XCTAssertTrue(has(.error, "off the 6-string"))
        XCTAssertTrue(has(.warning, "outside fretRange"))
        XCTAssertTrue(has(.error, "Invalid pitch \"H4\""))
        XCTAssertTrue(has(.error, "high to low"))
        XCTAssertTrue(has(.error, "strumRhythm needs \"rhythm\"", step: 2))
        XCTAssertTrue(has(.error, "Invalid chord \"Xm\""))
        XCTAssertTrue(has(.error, "E9 is outside the guitar range"))
        XCTAssertTrue(has(.error, "3 rhythm tokens for 2 notes"))
        XCTAssertTrue(has(.error, "answerIndex 2 is out of range"))
        XCTAssertTrue(has(.error, "M5", step: 5))
        XCTAssertTrue(has(.warning, "unknown param \"speed\""))
        XCTAssertTrue(has(.error, "3 rhythm tokens for 2 events", step: 6))
        XCTAssertTrue(has(.error, "duplicate lesson id"))
        XCTAssertTrue(has(.error, "not a lesson in the guitar course"))
        XCTAssertTrue(has(.error, "branch has no lessons"))
        XCTAssertTrue(has(.warning, "\"Nonexistent\" is not in tutor-glossary.json"))
        XCTAssertFalse(has(.warning, "\"Fret\" is not in"))
        XCTAssertTrue(has(.warning, "seeAlso \"Nut\""))
        XCTAssertTrue(issues.allSatisfy { $0.file == "tutor-guitar-stage-00.json" || $0.file.hasPrefix("tutor-piano") || $0.file == "tutor-glossary.json" })
    }

    func testEveryPracticeStepGeneratesAValidPassage() throws {
        var checked = 0
        for item in steps() {
            guard case .practice(let practice) = item.step else { continue }
            let context = InstrumentContext.standard(item.instrument)
            let where_ = "\(item.lesson.id) step \(item.index)"
            let spec = practice.exercise
            let generated: GeneratedExercise
            do {
                generated = try ExerciseGenerator.generate(
                    spec, context: context,
                    intervals: ExerciseGenerator.intervalsTaught(through: item.lesson.id, in: item.course))
            } catch {
                XCTFail("\(where_): \(error)")
                continue
            }
            checked += 1
            XCTAssertFalse(generated.rounds.isEmpty, where_)
            for round in generated.rounds {
                let passage = round.expected
                XCTAssertEqual(passage.instrument, item.instrument, where_)
                if spec.kind == .improvise {
                    XCTAssertFalse(generated.allowedPitchClasses.isEmpty, where_)
                    continue
                }
                XCTAssertFalse(passage.events.isEmpty, where_)
                var lastBeat = -1.0
                for event in passage.events {
                    XCTAssertFalse(event.pitches.isEmpty, where_)
                    XCTAssertTrue(event.pitches.allSatisfy { context.playableRange.contains($0) }, "\(where_) \(event.pitches)")
                    XCTAssertGreaterThan(event.beat, lastBeat, where_)
                    XCTAssertGreaterThan(event.durationBeats, 0, where_)
                    lastBeat = event.beat
                    if item.instrument == .guitar, let fretting = event.fretting {
                        for pos in fretting { XCTAssertNotNil(context.fretboard.midi(at: pos), where_) }
                    }
                }
            }
            switch spec.kind {
            case .findAllNotes:
                let pc = try PitchClass(parsing: spec.pitchClass!)
                XCTAssertFalse(generated.targetPitches.isEmpty, where_)
                XCTAssertTrue(generated.targetPitches.allSatisfy { PitchClass($0) == pc }, where_)
            case .intervalPlayback, .melodyEcho:
                XCTAssertEqual(generated.rounds.count, max(1, spec.repetitions ?? 1), where_)
                XCTAssertTrue(generated.rounds.allSatisfy { $0.reference != nil }, where_)
                if spec.kind == .intervalPlayback {
                    XCTAssertTrue(generated.rounds.allSatisfy { $0.expected.events.count == 2 }, where_)
                }
            case .strumRhythm:
                let rhythm = try RhythmPattern(parsing: spec.rhythm!)
                XCTAssertEqual(generated.passage.events.count,
                               rhythm.noteCount * spec.chords!.count * max(1, spec.repetitions ?? 1), where_)
                XCTAssertEqual(generated.pacing, .timed)
            default:
                break
            }
        }
        XCTAssertGreaterThan(checked, 50)
    }

    func testEverySongAndDemoBuilds() throws {
        for item in steps() {
            let context = InstrumentContext.standard(item.instrument)
            let where_ = "\(item.lesson.id) step \(item.index)"
            switch item.step {
            case .song(let song):
                do {
                    let passage = try ExerciseGenerator.passage(for: song, context: context)
                    XCTAssertFalse(passage.events.isEmpty, where_)
                    XCTAssertEqual(passage.beatsPerMeasure, song.beatsPerMeasure, where_)
                    let playback = try ExerciseGenerator.playback(for: song, context: context)
                    XCTAssertEqual(playback.totalBeats, try RhythmPattern(parsing: song.rhythm).totalBeats, accuracy: 1e-6)
                } catch {
                    XCTFail("\(where_): \(error)")
                }
            case .demo(let demo):
                do {
                    let sequence = try ExerciseGenerator.playback(for: demo.playback, context: context)
                    XCTAssertFalse(sequence.soundedNotes.isEmpty, where_)
                } catch {
                    XCTFail("\(where_): \(error)")
                }
            default:
                break
            }
        }
    }

    func testContentQuizGeneratorsProduceValidQuestions() throws {
        var generators = 0
        for item in steps() {
            guard case .quiz(let quiz) = item.step else { continue }
            let where_ = "\(item.lesson.id) step \(item.index)"
            do {
                let questions = try QuizGenerator.questions(for: quiz, instrument: item.instrument, seed: 42)
                let expected = (quiz.questions?.count ?? 0) + (quiz.generator == nil ? 0 : quiz.count)
                XCTAssertEqual(questions.count, expected, where_)
                for q in questions { assertValid(q, where_) }
                if quiz.generator != nil { generators += 1 }
            } catch {
                XCTFail("\(where_): \(error)")
            }
        }
        XCTAssertGreaterThan(generators, 10)
    }

    // MARK: - Quiz generators

    private func assertValid(_ q: QuizQuestion, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(q.choices.count, 2, "\(context): \(q.prompt)", file: file, line: line)
        XCTAssertTrue(q.choices.indices.contains(q.answerIndex), context, file: file, line: line)
        XCTAssertEqual(Set(q.choices).count, q.choices.count, "\(context): duplicate choices \(q.choices)", file: file, line: line)
        if q.choices.indices.contains(q.answerIndex) {
            let answer = q.choices[q.answerIndex]
            XCTAssertEqual(q.choices.filter { $0 == answer }.count, 1, context, file: file, line: line)
        }
        XCTAssertFalse(q.explanation.isEmpty, context, file: file, line: line)
    }

    func testEveryQuizKindWithDefaults() throws {
        let kinds: [QuizGeneratorKind] = [.noteOnFretboard, .noteOnKeyboard, .noteOnStaff, .intervalByEar, .intervalByName,
                                          .chordQualityByEar, .chordSpelling, .keySignature, .romanNumeral,
                                          .scaleDegreeByEar, .scaleSpelling, .rhythmCount]
        for instrument in TutorInstrument.allCases {
            for kind in kinds {
                let questions = try QuizGenerator.questions(for: QuizGeneratorSpec(kind: kind), count: 40,
                                                            instrument: instrument, seed: 9)
                XCTAssertEqual(questions.count, 40)
                for q in questions { assertValid(q, "\(instrument) \(kind)") }
                // Seeded generation is reproducible.
                let again = try QuizGenerator.questions(for: QuizGeneratorSpec(kind: kind), count: 40,
                                                        instrument: instrument, seed: 9)
                XCTAssertEqual(questions, again, "\(kind)")
            }
        }
    }

    func testQuizAnswersAreCorrect() throws {
        var rng = SeededRandom(seed: 3)
        for _ in 0..<60 {
            let q = try QuizGenerator.question(for: QuizGeneratorSpec(kind: .scaleSpelling, params: ["scales": "G major"]),
                                               context: .piano, using: &rng)
            XCTAssertEqual(q.choices[q.answerIndex], "G A B C D E F#")
            let k = try QuizGenerator.question(for: QuizGeneratorSpec(kind: .keySignature, params: ["keys": "Eb", "mode": "major"]),
                                               context: .piano, using: &rng)
            XCTAssertTrue(["3 flats", "Eb major"].contains(k.choices[k.answerIndex]))
            let r = try QuizGenerator.question(for: QuizGeneratorSpec(kind: .romanNumeral, params: ["keys": "G", "numerals": "IV"]),
                                               context: .piano, using: &rng)
            XCTAssertTrue(["C", "IV"].contains(r.choices[r.answerIndex]))
            let c = try QuizGenerator.question(for: QuizGeneratorSpec(kind: .chordSpelling, params: ["roots": "D", "qualities": "min"]),
                                               context: .guitar, using: &rng)
            XCTAssertTrue(["D F A", "Dm"].contains(c.choices[c.answerIndex]))
            let f = try QuizGenerator.question(for: QuizGeneratorSpec(kind: .noteOnFretboard, params: ["strings": "6", "fretMin": "3", "fretMax": "3"]),
                                               context: .guitar, using: &rng)
            XCTAssertEqual(f.choices[f.answerIndex], "G")
            XCTAssertEqual(f.diagram?.notes, ["6:3"])
            let s = try QuizGenerator.question(for: QuizGeneratorSpec(kind: .noteOnStaff, params: ["range": "E4-E4", "guitarOctave": "true"]),
                                               context: .guitar, using: &rng)
            XCTAssertEqual(s.choices[s.answerIndex], "E")
            XCTAssertEqual(s.playback?.notes, [["E3"]])
            let i = try QuizGenerator.question(for: QuizGeneratorSpec(kind: .intervalByName, params: ["intervals": "M3"]),
                                               context: .piano, using: &rng)
            XCTAssertEqual(i.choices[i.answerIndex], "Major third")
        }
    }

    func testRhythmCountAnswers() throws {
        var rng = SeededRandom(seed: 11)
        for _ in 0..<60 {
            let q = try QuizGenerator.question(for: QuizGeneratorSpec(kind: .rhythmCount, params: ["values": "h."]),
                                               context: .piano, using: &rng)
            XCTAssertEqual(q.choices[q.answerIndex], "3 beats")
        }
        XCTAssertEqual(QuizGenerator.beatsLabel(0.5), "½ beat")
        XCTAssertEqual(QuizGenerator.beatsLabel(1), "1 beat")
        XCTAssertEqual(QuizGenerator.beatsLabel(1.5), "1½ beats")
    }

    func testQuizParamValidation() {
        let bad = QuizGenerator.check(QuizGeneratorSpec(kind: .intervalByEar, params: ["intervals": "M5", "colour": "x"]),
                                      instrument: .piano)
        XCTAssertFalse(bad.errors.isEmpty)
        XCTAssertEqual(bad.warnings.count, 1)
        let good = QuizGenerator.check(QuizGeneratorSpec(kind: .keySignature, params: ["keys": "Am,Em", "mode": "minor"]),
                                       instrument: .guitar)
        XCTAssertTrue(good.errors.isEmpty && good.warnings.isEmpty)
    }

    // MARK: - Exercise generator specifics

    func testGuitarScaleInFirstPosition() throws {
        let spec = ExerciseSpec(kind: .scale, prompt: "", scale: "C major", octaves: 1, bpm: 60)
        let ex = try ExerciseGenerator.generate(spec, context: .guitar)
        XCTAssertEqual(ex.passage.events.map { $0.pitches[0] },
                       [48, 50, 52, 53, 55, 57, 59, 60, 59, 57, 55, 53, 52, 50, 48])
        XCTAssertEqual(ex.passage.events[1].fretting, [FretPosition(guitarString: 4, fret: 0)])
        XCTAssertTrue(ex.passage.events.allSatisfy { ($0.fretting?.first?.fret ?? 99) <= 4 })
        let g = try ExerciseGenerator.generate(ExerciseSpec(kind: .scale, prompt: "", scale: "G major", octaves: 2), context: .guitar)
        XCTAssertEqual(g.passage.events.first?.pitches, [43])
        XCTAssertEqual(g.passage.events.map { $0.pitches[0] }.max(), 67)
    }

    func testPianoScaleAndChordRegisters() throws {
        let ex = try ExerciseGenerator.generate(ExerciseSpec(kind: .scale, prompt: "", scale: "G major", octaves: 1), context: .piano)
        XCTAssertEqual(ex.passage.events.first?.pitches, [67])
        let chords = try ExerciseGenerator.generate(ExerciseSpec(kind: .playChord, prompt: "", chords: ["C", "C/E", "G7"]),
                                                    context: .piano)
        XCTAssertEqual(chords.passage.events.map(\.pitches), [[60, 64, 67], [64, 67, 72], [55, 59, 62, 65]])
        XCTAssertTrue(chords.gradeChordsByPitchClass)
        XCTAssertTrue(chords.passage.events.allSatisfy(\.octaveTolerant))
        let changes = try ExerciseGenerator.generate(ExerciseSpec(kind: .chordChanges, prompt: "", chords: ["C", "F"]), context: .piano)
        XCTAssertTrue(changes.passage.events.allSatisfy(\.octaveTolerant))
        let strum = try ExerciseGenerator.generate(ExerciseSpec(kind: .strumRhythm, prompt: "", chords: ["C"], bpm: 60, rhythm: "q q q q"),
                                                   context: .piano)
        XCTAssertTrue(strum.passage.events.allSatisfy(\.octaveTolerant))
        let melody = try ExerciseGenerator.generate(ExerciseSpec(kind: .playSequence, prompt: "", notes: ["C4", "E4"]), context: .piano)
        XCTAssertFalse(melody.passage.events.contains(where: \.octaveTolerant))
        let chordSong = try ExerciseGenerator.passage(for: SongStep(title: "t", chords: ["C", "G/B"], rhythm: "h h", bpm: 80), context: .piano)
        XCTAssertTrue(chordSong.events.allSatisfy(\.octaveTolerant))
        XCTAssertEqual(chordSong.events[1].pitches.first, 59)   // slash bass lowest
        let noteSong = try ExerciseGenerator.passage(for: SongStep(title: "t", notes: [["C4", "E4", "G4"]], rhythm: "w", bpm: 80),
                                                     context: .piano)
        XCTAssertFalse(noteSong.events[0].octaveTolerant)
        let left = try ExerciseGenerator.generate(ExerciseSpec(kind: .playChord, prompt: "Left hand: play C", chords: ["C"]),
                                                  context: .piano)
        XCTAssertEqual(left.passage.events.first?.pitches, [48, 52, 55])
    }

    func testGuitarChordVoicings() throws {
        let ex = try ExerciseGenerator.generate(ExerciseSpec(kind: .playChord, prompt: "", chords: ["G", "F", "Bm"]), context: .guitar)
        XCTAssertEqual(ex.passage.events[0].pitches, [43, 47, 50, 55, 59, 67])
        XCTAssertEqual(ex.passage.events[0].chordName, "G")
        XCTAssertEqual(ex.passage.events[1].pitches, [41, 48, 53, 57, 60, 65])   // E-form barre, fret 1
        XCTAssertEqual(ex.passage.events[2].pitches, [47, 54, 59, 62, 66])       // A-form barre, fret 2
        XCTAssertEqual(ex.passage.events[1].fretting?.count, 6)
        XCTAssertFalse(ex.gradeChordsByPitchClass)
        XCTAssertFalse(ex.passage.events.contains(where: \.octaveTolerant))
        let song = try ExerciseGenerator.passage(for: SongStep(title: "t", chords: ["G"], rhythm: "w", bpm: 80), context: .guitar)
        XCTAssertFalse(song.events[0].octaveTolerant)
    }

    func testStrumRhythmAndChordChanges() throws {
        let strum = try ExerciseGenerator.generate(ExerciseSpec(kind: .strumRhythm, prompt: "", chords: ["G", "C"], bpm: 80,
                                                                rhythm: "q e e er e e e", repetitions: 2), context: .guitar)
        XCTAssertEqual(strum.passage.events.count, 6 * 4)
        XCTAssertEqual(strum.passage.events.map(\.beat).prefix(6), [0, 1, 1.5, 2.5, 3, 3.5])
        XCTAssertEqual(strum.passage.events[6].beat, 4)
        XCTAssertEqual(strum.passage.events[6].chordName, "C")

        let changes = try ExerciseGenerator.generate(ExerciseSpec(kind: .chordChanges, prompt: "", chords: ["A", "D"], durationSec: 60),
                                                     context: .guitar)
        XCTAssertEqual(changes.pacing, .countChanges)
        // Room for 40 changes a minute; the beginner goal is 8 clean changes.
        XCTAssertEqual(changes.passage.events.count, 40)
        XCTAssertEqual(changes.passage.events.prefix(3).compactMap(\.chordName), ["A", "D", "A"])
        XCTAssertEqual(changes.changesPerMinuteTarget, 8)
        XCTAssertEqual(changes.passAccuracy * Double(changes.passage.events.count), 8, accuracy: 1e-9)
    }

    func testChordChangeGoalRisesByStage() throws {
        let spec = ExerciseSpec(kind: .chordChanges, prompt: "", chords: ["G", "C"], durationSec: 60, passAccuracy: 0.7)
        func goal(_ stage: Int?, _ context: InstrumentContext = .guitar) throws -> Double {
            let e = try ExerciseGenerator.generate(spec, context: context, stage: stage)
            return (e.passAccuracy * Double(e.passage.events.count)).rounded()
        }
        XCTAssertEqual(try goal(nil), 8)
        XCTAssertEqual(try goal(3), 8)
        XCTAssertEqual(try goal(5), 12)
        XCTAssertEqual(try goal(8), 16)
        XCTAssertEqual(try goal(5, .piano), 10)
        // The spec's 0.7 (28 of 40) no longer applies.
        XCTAssertLessThan(try ExerciseGenerator.generate(spec, context: .guitar, stage: 8).passAccuracy, 0.7)
        // 30-second drill: half the per-minute goal.
        var short = spec
        short.durationSec = 30
        let half = try ExerciseGenerator.generate(short, context: .guitar, stage: 5)
        XCTAssertEqual(half.passAccuracy * Double(half.passage.events.count), 6, accuracy: 1e-9)
        XCTAssertEqual(ExerciseGenerator.stage(ofLessonID: "guitar.s5.l2"), 5)
        XCTAssertEqual(ExerciseGenerator.stage(ofLessonID: "piano.s0.l1"), 0)
        XCTAssertNil(ExerciseGenerator.stage(ofLessonID: "guitar.b.finger.l3"))
    }

    func testIntervalPlaybackRoundsAndFindAll() throws {
        let spec = ExerciseSpec(kind: .intervalPlayback, prompt: "", notes: ["A2"], repetitions: 5)
        let ex = try ExerciseGenerator.generate(spec, context: .guitar, intervals: [.m3, .P5], seed: 4)
        XCTAssertEqual(ex.rounds.count, 5)
        for round in ex.rounds {
            XCTAssertEqual(round.expected.events.first?.pitches, [45])
            XCTAssertTrue([48, 52].contains(round.expected.events.last?.pitches.first ?? 0))
            XCTAssertEqual(round.reference?.soundedNotes.map(\.pitches), round.expected.events.map(\.pitches))
        }
        let fixed = try ExerciseGenerator.generate(ExerciseSpec(kind: .intervalPlayback, prompt: "", notes: ["C4", "G4"], repetitions: 3),
                                                   context: .piano)
        XCTAssertEqual(fixed.rounds.count, 3)
        XCTAssertEqual(fixed.rounds[0].label, "perfect fifth")

        let find = try ExerciseGenerator.generate(ExerciseSpec(kind: .findAllNotes, prompt: "", pitchClass: "G"), context: .guitar)
        XCTAssertEqual(find.targetPitches, [43, 55, 67])
        XCTAssertEqual(find.pacing, .anyOrder)
        let improv = try ExerciseGenerator.generate(ExerciseSpec(kind: .improvise, prompt: "", scale: "A minor pentatonic"),
                                                    context: .guitar)
        XCTAssertEqual(improv.allowedPitchClasses, Set([9, 0, 2, 4, 7].map { PitchClass($0) }))
    }

    func testPlaybackRhythmAndRests() throws {
        let spec = PlaybackSpec(notes: [[], ["E4"], ["G4", "C5"]], rhythm: "hr q h", bpm: 60, style: .arpeggio)
        let seq = try ExerciseGenerator.playback(for: spec, context: .piano)
        XCTAssertEqual(seq.totalBeats, 5)
        XCTAssertEqual(seq.soundedNotes.map(\.pitches), [[64], [67], [72]])
        XCTAssertEqual(seq.soundedNotes.map(\.startBeat), [2, 3, 4])
        let song = SongStep(title: "t", notes: [[], ["E4"], ["D4"]], rhythm: "hr q q", bpm: 90)
        let passage = try ExerciseGenerator.passage(for: song, context: .piano)
        XCTAssertEqual(passage.events.map(\.beat), [2, 3])
    }

    // MARK: - Scheduler

    func testSchedulerMath() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = 86_400.0
        let new = ReviewState(due: now)
        let good = ReviewScheduler.schedule(new, grade: .good, now: now)
        XCTAssertEqual(good.stability, ReviewScheduler.w[2], accuracy: 1e-9)
        XCTAssertEqual(good.due.timeIntervalSince(now) / day, 3, accuracy: 0.01)
        XCTAssertEqual(good.reps, 1)
        let again = ReviewScheduler.schedule(new, grade: .again, now: now)
        XCTAssertEqual(again.due.timeIntervalSince(now), ReviewScheduler.relearnDelay, accuracy: 1)
        XCTAssertEqual(again.lapses, 0)
        XCTAssertGreaterThan(ReviewScheduler.initialDifficulty(.again), ReviewScheduler.initialDifficulty(.easy))

        // Retention target: R(t = S) = 0.9, so the interval equals the stability.
        XCTAssertEqual(ReviewScheduler.retrievability(elapsedDays: 10, stability: 10), 0.9, accuracy: 1e-9)
        XCTAssertEqual(ReviewScheduler.interval(forStability: 10), 10)

        // Reviewing on time with "good" grows the interval; "easy" grows it more; "hard" less.
        let reviewTime = good.due
        let good2 = ReviewScheduler.schedule(good, grade: .good, now: reviewTime)
        let easy2 = ReviewScheduler.schedule(good, grade: .easy, now: reviewTime)
        let hard2 = ReviewScheduler.schedule(good, grade: .hard, now: reviewTime)
        XCTAssertGreaterThan(good2.stability, good.stability)
        XCTAssertGreaterThan(easy2.stability, good2.stability)
        XCTAssertLessThan(hard2.stability, good2.stability)
        XCTAssertGreaterThan(good2.due, reviewTime.addingTimeInterval(3 * day))

        // A lapse shrinks stability, counts a lapse, and raises difficulty.
        let lapse = ReviewScheduler.schedule(good2, grade: .again, now: good2.due)
        XCTAssertLessThan(lapse.stability, good2.stability)
        XCTAssertEqual(lapse.lapses, 1)
        XCTAssertGreaterThan(lapse.difficulty, good2.difficulty)
        XCTAssertTrue((1...10).contains(lapse.difficulty))

        // Intervals are capped.
        var s = good
        for _ in 0..<30 { s = ReviewScheduler.schedule(s, grade: .easy, now: s.due) }
        XCTAssertLessThanOrEqual(s.due.timeIntervalSince(s.lastReview!), ReviewScheduler.maximumIntervalDays * day + 1)
    }

    @MainActor
    func testSeedingAndDueQueue() throws {
        let store = try TutorStore.inMemory()
        let lesson = Self.lesson("g.l1", reviewItems: [
            ReviewItemSeed(id: "g.l1.r1", kind: .fact, prompt: "p", answer: "a"),
            ReviewItemSeed(id: "g.l1.r2", kind: .playNote, prompt: "Play A", answer: "A2"),
        ])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try ReviewScheduler.completeLesson(lesson, instrument: .guitar, score: 0.9, store: store, now: now)
        XCTAssertEqual(store.progress(lessonID: "g.l1", instrument: .guitar)?.progressStatus, .completed)
        XCTAssertTrue(ReviewScheduler.dueQueue(instrument: .guitar, store: store, now: now).isEmpty)
        let tomorrow = now.addingTimeInterval(ReviewScheduler.firstReviewDelay + 1)
        let due = ReviewScheduler.dueQueue(instrument: .guitar, store: store, now: tomorrow)
        XCTAssertEqual(Set(due.map(\.itemID)), ["g.l1.r1", "g.l1.r2"])
        XCTAssertTrue(ReviewScheduler.dueQueue(instrument: .piano, store: store, now: tomorrow).isEmpty)

        try ReviewScheduler.record(.good, for: due[0], store: store, now: tomorrow)
        XCTAssertEqual(ReviewScheduler.dueQueue(instrument: .guitar, store: store, now: tomorrow).count, 1)
        // Seeding again keeps the reviewed card's schedule.
        try ReviewScheduler.seedCards(for: lesson, instrument: .guitar, store: store, now: tomorrow)
        XCTAssertEqual(store.reviewCard(itemID: due[0].itemID, instrument: .guitar)?.reps, 1)
    }

    // MARK: - Path

    private static func lesson(_ id: String, reviewItems: [ReviewItemSeed] = [], steps: [LessonStep] = []) -> Lesson {
        Lesson(id: id, title: id, summary: "", minutes: 5, steps: steps, reviewItems: reviewItems)
    }

    private static func course() -> Course {
        let s0 = Stage(id: "g.s0", instrument: .guitar, order: 0, title: "", summary: "",
                       lessons: [lesson("l1"), lesson("l2")],
                       branches: [Branch(id: "b1", title: "", summary: "", unlocksAfter: "l1", lessons: [lesson("b1.l1"), lesson("b1.l2")])])
        let s1 = Stage(id: "g.s1", instrument: .guitar, order: 1, title: "", summary: "", lessons: [lesson("l3"), lesson("l4")])
        return Course(instrument: .guitar, title: "Guitar", stages: [s0, s1])
    }

    func testPathIsOpenInRecommendedOrder() {
        let course = Self.course()
        let fresh = PathProgress(course: course, statuses: [:])
        XCTAssertEqual(fresh.state(of: "l1"), .available)
        XCTAssertEqual(fresh.state(of: "l4"), .available)
        XCTAssertEqual(fresh.state(of: "b1.l2"), .available)
        XCTAssertEqual(fresh.continueTarget?.id, "l1")

        // Skipping ahead leaves the recommended next lesson on the first gap.
        let skipped = PathProgress(course: course, statuses: ["l3": .completed])
        XCTAssertEqual(skipped.continueTarget?.id, "l1")

        let p = PathProgress(course: course, statuses: ["l1": .completed, "l2": .inProgress])
        XCTAssertEqual(p.state(of: "l2"), .inProgress)
        XCTAssertEqual(p.state(of: "l3"), .available)
        XCTAssertEqual(p.state(of: "b1.l1"), .available)
        XCTAssertEqual(p.state(of: "b1.l2"), .available)
        XCTAssertEqual(p.continueTarget?.id, "l2")
        XCTAssertEqual(p.completion(of: course.stages[0]), 0.5)

        // Branches never block: the main path advances with the branch untouched.
        let later = PathProgress(course: course, statuses: ["l1": .completed, "l2": .completed, "l3": .completed])
        XCTAssertEqual(later.state(of: "l4"), .available)
        XCTAssertEqual(later.state(of: "b1.l1"), .available)
        XCTAssertEqual(later.continueTarget?.id, "l4")
        XCTAssertEqual(later.currentStage?.id, "g.s1")
        XCTAssertEqual(later.completion(of: course.stages[0]), 1)
        XCTAssertEqual(later.overallCompletion, 0.75)

        let done = PathProgress(course: course, statuses: ["l1": .completed, "l2": .completed, "l3": .completed,
                                                           "l4": .completed, "b1.l1": .completed])
        XCTAssertNil(done.continueTarget)
        XCTAssertEqual(done.state(of: "b1.l2"), .available)
        XCTAssertEqual(done.completion(of: course.stages[0].branches[0]), 0.5)
    }

    func testRealCoursePathStartsAtFirstLesson() throws {
        for course in content.courses.values {
            let p = PathProgress(course: course, statuses: [:])
            XCTAssertEqual(p.continueTarget?.id, course.mainPathLessons.first?.id)
            for branch in course.allBranches {
                XCTAssertFalse(p.isUnlocked(branch))
            }
        }
    }

    // MARK: - Coach

    func testFeedbackCoachRules() {
        var coach = FeedbackCoach(tips: ["tip A", "tip B"], tempoSteps: [60, 70, 80])
        XCTAssertNil(coach.registerAttempt(target: "G", success: false))
        XCTAssertNil(coach.registerAttempt(target: "G", success: false))
        XCTAssertEqual(coach.registerAttempt(target: "G", success: false), .tip("tip A"))
        XCTAssertNil(coach.registerAttempt(target: "C", success: false))
        XCTAssertNil(coach.registerAttempt(target: "G", success: true))
        for _ in 0..<2 { XCTAssertNil(coach.registerAttempt(target: "G", success: false)) }
        XCTAssertEqual(coach.registerAttempt(target: "G", success: false), .tip("tip B"))

        XCTAssertNil(coach.registerRun(accuracy: 1))
        XCTAssertNil(coach.registerRun(accuracy: 1))
        XCTAssertNil(coach.registerRun(accuracy: 0.5))   // breaks the streak
        XCTAssertNil(coach.registerRun(accuracy: 1))
        XCTAssertNil(coach.registerRun(accuracy: 0.97))
        XCTAssertEqual(coach.registerRun(accuracy: 1), .offerTempo(bpm: 70))
        coach.advanceTempo()
        XCTAssertEqual(coach.currentTempo, 70)
        for _ in 0..<2 { _ = coach.registerRun(accuracy: 1) }
        XCTAssertEqual(coach.registerRun(accuracy: 1), .offerTempo(bpm: 80))
        coach.advanceTempo()
        for _ in 0..<3 { XCTAssertNil(coach.registerRun(accuracy: 1)) }   // top of the ladder

        let passage = PassageBuilder.chords([[45, 52], [50, 57]], names: ["A", "D"], repetitions: 2, bpm: 60, instrument: .guitar)
        let graded = [
            GradedEvent(expectedID: 0, grade: .hit, matchedPitches: [45, 52], missingPitches: [], wrongPitches: [], confidence: 1),
            GradedEvent(expectedID: 1, grade: .hit, matchedPitches: [45, 52], missingPitches: [], wrongPitches: [], confidence: 1),
            GradedEvent(expectedID: 2, grade: .partial, matchedPitches: [50], missingPitches: [57], wrongPitches: [], confidence: 1),
            GradedEvent(expectedID: 3, grade: .uncertain, matchedPitches: [], missingPitches: [], wrongPitches: [], confidence: 0),
        ]
        XCTAssertEqual(FeedbackCoach.weakestItem(passage: passage, graded: graded), .weakest(item: "D", accuracy: 0.5))
        XCTAssertEqual(FeedbackCoach.weakestItem(passage: passage, graded: Array(graded.prefix(2))), .allClean)
    }

    // MARK: - Library suggestions

    func testLibrarySongSuggester() {
        let chordLesson = Self.lesson("c1", steps: [
            .practice(PracticeStep(exercise: ExerciseSpec(kind: .chordChanges, prompt: "", chords: ["G", "C", "D", "Em"]))),
        ])
        let other = Self.lesson("c2", steps: [
            .practice(PracticeStep(exercise: ExerciseSpec(kind: .playChord, prompt: "", chords: ["A#m"]))),
        ])
        let course = Course(instrument: .guitar, title: "G", stages: [
            Stage(id: "s", instrument: .guitar, order: 0, title: "", summary: "", lessons: [chordLesson, other]),
        ])
        let known = LibrarySongSuggester.learnedChords(in: course, completedLessonIDs: ["c1", "c2"])
        XCTAssertEqual(known.count, 5)
        let songs: [(title: String, chords: [String])] = [
            ("Three Chords", ["G", "C", "D", "G"]),
            ("Needs F", ["G", "F", "C"]),
            ("Slash and flats", ["C/G", "Bbm", "Em"]),
            ("Nothing", []),
            ("Garbage", ["???"]),
        ]
        let full = LibrarySongSuggester.suggest(songs: songs, known: known)
        XCTAssertEqual(full.map(\.title), ["Slash and flats", "Three Chords"])
        XCTAssertEqual(full.first { $0.title == "Three Chords" }?.chords, ["G", "C", "D"])
        let near = LibrarySongSuggester.suggest(songs: songs, known: known, maxMissing: 1)
        XCTAssertEqual(near.map(\.title), ["Slash and flats", "Three Chords", "Needs F"])
        XCTAssertEqual(near.last?.missing, ["F"])
    }

    // MARK: - Loader

    func testLoaderFileNamesAndLookups() throws {
        XCTAssertEqual(CurriculumLoader.stageFileInfo("tutor-guitar-stage-03.json")?.number, 3)
        XCTAssertEqual(CurriculumLoader.stageFileInfo("tutor-piano-stage-10.json")?.instrument, .piano)
        XCTAssertNil(CurriculumLoader.stageFileInfo("tutor-glossary.json"))
        XCTAssertNil(CurriculumLoader.stageFileInfo("tutor-guitar-glossary-terms.txt"))
        let guitar = try XCTUnwrap(content.courses[.guitar])
        let first = try XCTUnwrap(guitar.mainPathLessons.first)
        XCTAssertEqual(guitar.location(ofLesson: first.id)?.stage.id, guitar.stages.first?.id)
        if let item = guitar.mainPathLessons.lazy.flatMap(\.reviewItems).first {
            XCTAssertEqual(guitar.reviewItem(id: item.id), item)
        }
    }

    @MainActor
    func testLibraryLoadsOffMain() async {
        let content = Self.content
        let library = CurriculumLibrary(loader: { content })
        XCTAssertFalse(library.isLoaded)
        await library.loadIfNeeded()
        XCTAssertTrue(library.isLoaded)
        XCTAssertNotNil(library.course(for: .piano))
        XCTAssertNotNil(library.glossaryEntry(for: library.glossary.first?.term ?? ""))
    }
}
