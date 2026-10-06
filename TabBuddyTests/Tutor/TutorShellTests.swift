//
//  TutorShellTests.swift
//  TabBuddyTests
//
//  Tutor shell view-model logic: contents node states (with branches), the
//  next-up target, flashcards, quick practice specs and the exercise index,
//  glossary search, song suggestions, shell state, and the calibration view
//  model with a fake calibrator.
//

import SwiftData
import XCTest
@testable import TabBuddy

@MainActor
final class TutorShellTests: XCTestCase {

    // MARK: Fixtures

    private func lesson(_ id: String, _ title: String, chords: [String]? = nil,
                        reviewItems: [ReviewItemSeed] = []) -> Lesson {
        var steps: [LessonStep] = [.explain(ExplainStep(title: "Read", body: "Body"))]
        if let chords {
            steps.append(.practice(PracticeStep(exercise: ExerciseSpec(kind: .playChord, prompt: "Play", chords: chords))))
        }
        var l = Lesson(id: id, title: title, summary: "S", minutes: 5, steps: steps)
        l.reviewItems = reviewItems
        return l
    }

    private func course() -> Course {
        var s0 = Stage(id: "g.s0", instrument: .guitar, order: 0, title: "Setup", summary: "",
                       lessons: [lesson("g.s0.l1", "One"), lesson("g.s0.l2", "Two", chords: ["E", "A"])])
        s0.branches = [Branch(id: "g.b.x", title: "Detour", summary: "", unlocksAfter: "g.s0.l2",
                              lessons: [lesson("g.b.x.l1", "Side A"), lesson("g.b.x.l2", "Side B")])]
        let s1 = Stage(id: "g.s1", instrument: .guitar, order: 1, title: "Chords", summary: "",
                       lessons: [lesson("g.s1.l1", "Three", chords: ["D"]), lesson("g.s1.l2", "Four")])
        return Course(instrument: .guitar, title: "Guitar", stages: [s0, s1])
    }

    // MARK: Path

    func testPathNodeStatesWithBranches() {
        let c = course()
        let progress = PathProgress(course: c, statuses: ["g.s0.l1": .completed, "g.s0.l2": .completed,
                                                           "g.s1.l1": .inProgress])
        let model = TutorPathModel(course: c, progress: progress)
        XCTAssertEqual(model.sections.map { $0.nodes.map(\.state) },
                       [[.completed, .completed], [.inProgress, .available]])
        XCTAssertEqual(model.sections[0].completion, 1)
        XCTAssertTrue(model.sections[1].isCurrent)
        XCTAssertTrue(model.node(for: "g.s1.l1")!.isCurrent)
        XCTAssertNil(model.node(for: "g.s1.l2")!.lockedReason)

        let branch = model.sections[0].branches[0]
        XCTAssertTrue(branch.isUnlocked)
        XCTAssertEqual(branch.anchorLessonID, "g.s0.l2")
        XCTAssertEqual(model.sections[0].branches(after: "g.s0.l2").map(\.id), ["g.b.x"])
        XCTAssertEqual(branch.nodes.map(\.state), [.available, .available])
        XCTAssertTrue(branch.nodes.allSatisfy(\.isBranch))
        XCTAssertNil(branch.nodes[1].lockedReason)
    }

    func testBranchIsOpenBeforeItsSuggestedPointAndNeverBlocksMainPath() {
        let c = course()
        let progress = PathProgress(course: c, statuses: ["g.s0.l1": .completed])
        let model = TutorPathModel(course: c, progress: progress)
        let branch = model.sections[0].branches[0]
        XCTAssertFalse(branch.isUnlocked)
        XCTAssertEqual(branch.unlockHint, "Suggested after “Two”.")
        XCTAssertEqual(branch.nodes[0].state, .available)
        XCTAssertNil(branch.nodes[0].lockedReason)

        // Completing the main path without touching the branch finishes it.
        let done = PathProgress(course: c, statuses: ["g.s0.l1": .completed, "g.s0.l2": .completed,
                                                       "g.s1.l1": .completed, "g.s1.l2": .completed])
        XCTAssertEqual(TutorPathModel(course: c, progress: done).continueCard.kind, .finished)
    }

    func testContinueCard() {
        let c = course()
        let fresh = TutorPathModel(course: c, progress: PathProgress(course: c, statuses: [:])).continueCard
        XCTAssertEqual(fresh.kind, .start)
        XCTAssertEqual(fresh.lesson?.id, "g.s0.l1")
        XCTAssertEqual(fresh.stageTitle, "Setup")
        XCTAssertEqual(fresh.minutes, 5)
        XCTAssertEqual(fresh.buttonTitle, "Open chapter")

        let resume = TutorPathModel(course: c, progress: PathProgress(course: c, statuses: [
            "g.s0.l1": .completed, "g.s0.l2": .completed, "g.s1.l1": .inProgress])).continueCard
        XCTAssertEqual(resume.kind, .resume)
        XCTAssertEqual(resume.lesson?.id, "g.s1.l1")
        XCTAssertEqual(resume.stageNumber, 1)

        XCTAssertEqual(TutorPathModel.actionTitle(for: .completed), "Read again")
        XCTAssertNil(TutorPathModel.actionTitle(for: .locked))
    }

    @MainActor
    func testMarkingLessonsDoneSkipsAheadAndUndoes() throws {
        let store = try TutorStore.inMemory()
        try store.setLessonCompleted(lessonID: "g.s0.l1", instrument: .guitar, completed: true)
        try store.setLessonCompleted(lessonID: "g.s0.l2", instrument: .guitar, completed: true)
        let c = course()
        var progress = PathProgress(course: c, store: store)
        XCTAssertEqual(progress.continueTarget?.id, "g.s1.l1")
        XCTAssertEqual(store.progress(lessonID: "g.s0.l1", instrument: .guitar)?.attempts, 0)
        XCTAssertTrue(store.dueReviewCards(instrument: .guitar, asOf: .distantFuture, limit: 10).isEmpty)

        try store.setLessonCompleted(lessonID: "g.s0.l1", instrument: .guitar, completed: false)
        progress = PathProgress(course: c, store: store)
        XCTAssertEqual(progress.state(of: "g.s0.l1"), .available)
        XCTAssertEqual(progress.continueTarget?.id, "g.s0.l1")
    }

    func testStepSummariesFollowPageOrder() {
        var l = lesson("x", "X", chords: ["E"])
        l.steps.insert(.quiz(QuizStep(title: "Check", questions: [QuizQuestion(prompt: "?", choices: ["a", "b"], answerIndex: 0, explanation: "")])),
                       at: 1)
        let summaries = TutorStepSummary.summaries(for: l)
        XCTAssertEqual(summaries.map(\.kind), [.explain, .practice, .quiz], "check yourself moves to the end")
        XCTAssertEqual(summaries.map(\.usesMicrophone), [false, true, false])
        XCTAssertEqual(summaries.map(\.index), [0, 1, 2])
        XCTAssertEqual(summaries.map(\.kindLabel), ["Read", "Try it", "Check yourself"])
    }

    func testSectionLaunchNames() {
        XCTAssertEqual(TutorSection(launchName: "practice"), .practice)
        XCTAssertEqual(TutorSection(launchName: "Flashcards"), .flashcards)
        XCTAssertNil(TutorSection(launchName: "reviews"))
        XCTAssertNil(TutorSection(launchName: "review-session"))
        XCTAssertEqual(TutorSection.allCases.count, 8)
        XCTAssertEqual(TutorSection.path.title, "Contents")
    }

    // MARK: Flashcards

    func testFlashcardDeckFromDoneChaptersAndOrderOnly() {
        var c = course()
        c.stages[0].lessons[0].reviewItems = [ReviewItemSeed(id: "r1", kind: .fact, prompt: "P1", answer: "A1"),
                                               ReviewItemSeed(id: "r2", kind: .playNote, prompt: "Play A", answer: "A2")]
        c.stages[1].lessons[0].reviewItems = [ReviewItemSeed(id: "r3", kind: .playChord, prompt: "Play C then G", answer: "C, G")]
        let progress = PathProgress(course: c, statuses: ["g.s0.l1": .completed])
        let model = TutorFlashcardsModel(course: c, progress: progress, instrument: .guitar, seed: 5)
        XCTAssertEqual(model.allCards.count, 3)
        XCTAssertEqual(model.scope, .done, "starts on read chapters when any card qualifies")
        XCTAssertEqual(model.deck.map(\.id), ["r1", "r2"])
        XCTAssertEqual(model.current?.lessonTitle, "One")
        XCTAssertEqual(model.doneCardCount, 2)

        model.flip()
        XCTAssertTrue(model.revealed)
        model.again()
        XCTAssertEqual(model.deck.map(\.id), ["r2", "r1"], "Again moves the card to the back")
        XCTAssertFalse(model.revealed)
        model.gotIt()
        XCTAssertEqual(model.deck.map(\.id), ["r1"])
        XCTAssertEqual(model.gotItCount, 1)
        model.again()
        XCTAssertEqual(model.deck.map(\.id), ["r1"], "a single card stays")
        model.gotIt()
        XCTAssertTrue(model.isFinished)
        model.reset()
        XCTAssertEqual(model.remaining, 2)

        model.setScope(.all)
        XCTAssertEqual(model.deck.map(\.id), ["r1", "r2", "r3"])
        model.shuffle()
        XCTAssertEqual(Set(model.deck.map(\.id)), ["r1", "r2", "r3"])

        // Play cards hear their answer through the synth instead of grading.
        XCTAssertEqual(model.allCards[1].hearPitches, [[45]])
        XCTAssertTrue(model.allCards[1].isPlayCard)
        XCTAssertEqual(model.allCards[2].hearPitches.count, 2)
        XCTAssertEqual(model.allCards[2].kindLabel, "Play the chord")

        let none = TutorFlashcardsModel(course: c, progress: PathProgress(course: c, statuses: [:]), instrument: .guitar)
        XCTAssertEqual(none.scope, .all, "with nothing read, browse everything")
    }

    func testFlashcardPitchTokens() {
        XCTAssertEqual(TutorFlashcardBuilder.pitchTokens(in: "D3 (string 6, fret 10)"), ["D3"])
        XCTAssertEqual(TutorFlashcardBuilder.pitchTokens(in: "C3 (string 5 fret 3), then C4 (string 3 fret 5)."), ["C3", "C4"])
        XCTAssertEqual(TutorFlashcardBuilder.pitchTokens(in: "B♭4"), ["Bb4"])
        let piano = TutorFlashcardBuilder.hearPitches(for: ReviewItemSeed(id: "x", kind: .playChord, prompt: "", answer: "Am7"), instrument: .piano)
        XCTAssertEqual(piano.count, 1)
        XCTAssertEqual(piano[0].count, 4)
        XCTAssertEqual(TutorFlashcardBuilder.hearPitches(for: ReviewItemSeed(id: "y", kind: .fact, prompt: "", answer: "A2"), instrument: .guitar), [])
    }

    // MARK: Quick practice

    func testScaleSpecGuitarWindowAndPiano() {
        var spec = ScalePracticeSpec(root: .G, type: .major, octaves: 1, position: 1)
        let box = try! XCTUnwrap(spec.guitarPosition())
        XCTAssertEqual(box.fretRange, 2...5, "G major position 1 sits around the low-E G at fret 3")
        let up = spec.ascendingMIDI(instrument: .guitar)
        XCTAssertEqual(up.first, 43, "G2 is the lowest G in position 1")
        XCTAssertEqual(up.last, 55)
        XCTAssertEqual(up.count, 8)
        XCTAssertEqual(spec.pitches(instrument: .guitar).count, 15, "up and down")
        let diagram = spec.diagram(instrument: .guitar)
        XCTAssertEqual(diagram.kind, .fretboard)
        XCTAssertEqual(diagram.fretRange, [2, 5])
        XCTAssertEqual(diagram.scale, "G major")
        XCTAssertEqual(FretboardDiagramModel(diagram: diagram).dots.count, 8)

        spec.position = 3
        let moved = spec.ascendingMIDI(instrument: .guitar)
        XCTAssertEqual(PitchClass(moved.first!), SpelledNote.G.pitchClass)
        let third = try! XCTUnwrap(spec.guitarPosition())
        XCTAssertTrue(spec.guitarPositions().allSatisfy { (third.fretRange.lowerBound - 1...third.fretRange.upperBound + 1).contains($0.fret) })
        XCTAssertEqual(spec.launch(instrument: .guitar).position, 3)
        XCTAssertEqual(ScalePracticeSpec(launch: spec.launch(instrument: .guitar)), spec)

        spec.position = nil
        spec.octaves = 2
        XCTAssertEqual(spec.ascendingMIDI(instrument: .guitar).count, 15)
        let exercise = spec.exercise(instrument: .guitar, bpm: 90)
        XCTAssertEqual(exercise.pacing, .timed)
        XCTAssertEqual(exercise.bpm, 90)
        XCTAssertEqual(exercise.passage.events.count, 29)
        XCTAssertEqual(exercise.scale?.name, "G major")

        let piano = ScalePracticeSpec(root: SpelledNote("Eb")!, type: .minorPentatonic, octaves: 1, labels: .degrees)
        let pianoUp = piano.ascendingMIDI(instrument: .piano)
        XCTAssertEqual(pianoUp, [63, 66, 68, 70, 73, 75])
        let pd = piano.diagram(instrument: .piano)
        XCTAssertEqual(pd.kind, .keyboard)
        XCTAssertEqual(pd.labels, .degrees)
        XCTAssertEqual(pd.notes, ["Eb4", "Gb4", "Ab4", "Bb4", "Db5", "Eb5"], "spelled from the scale")
        XCTAssertEqual(KeyboardDiagramModel(diagram: pd).marks.count, 6)
    }

    func testChordSpecVoicingDiagramAndStyles() {
        var spec = ChordPracticeSpec(root: .A, quality: .minor, style: .block)
        XCTAssertEqual(spec.title, "Am")
        let gd = spec.diagram(instrument: .guitar)
        XCTAssertEqual(gd.kind, .fretboard)
        XCTAssertEqual(gd.labels, .fingers, "open shapes show finger numbers")
        XCTAssertEqual(FretboardDiagramModel(diagram: gd).dots.count, 5)
        let block = spec.example(instrument: .guitar, bpm: 80)
        XCTAssertEqual(block.notes.count, 1)
        XCTAssertEqual(block.notes[0].durationBeats, 4)
        spec.style = .arpeggio
        let arp = spec.example(instrument: .guitar, bpm: 80)
        XCTAssertEqual(arp.notes.count, 5 + 3)
        XCTAssertTrue(arp.notes.allSatisfy { $0.pitches.count == 1 })
        spec.style = .strum
        XCTAssertEqual(spec.example(instrument: .guitar, bpm: 80).notes.count, 8)

        let exercise = spec.exercise(instrument: .piano, bpm: 80)
        XCTAssertEqual(exercise.pacing, .wait)
        XCTAssertEqual(exercise.passage.events.count, 1)
        XCTAssertTrue(exercise.passage.events[0].octaveTolerant, "piano chord symbols carry no register")
        XCTAssertEqual(exercise.passage.events[0].chordName, "Am")
        XCTAssertEqual(spec.diagram(instrument: .piano).kind, .keyboard)
    }

    func testIntervalSpecDirectionsAndRange() {
        var spec = IntervalPracticeSpec(root: Pitch("C4")!, interval: .M3, direction: .up)
        XCTAssertEqual(spec.pitches(), [60, 64])
        XCTAssertEqual(spec.caption, "Major third: C4 → E4, 4 half steps")
        XCTAssertEqual(spec.example(instrument: .piano, bpm: 80).notes.count, 2)
        spec.direction = .down
        XCTAssertEqual(spec.pitches(), [60, 56])
        XCTAssertEqual(spec.otherPitch.name, "Ab3")
        spec.direction = .together
        XCTAssertEqual(spec.pitches(), [60, 64], "together sounds the root and the note above it")
        XCTAssertEqual(spec.example(instrument: .piano, bpm: 80).notes.count, 1)
        XCTAssertEqual(spec.exercise(instrument: .piano, bpm: 80).passage.events.count, 1)
        XCTAssertEqual(spec.diagram(instrument: .piano).kind, .keyboard)
        XCTAssertTrue(spec.fits(.piano))
        let low = IntervalPracticeSpec(root: Pitch("E2")!, interval: .P5, direction: .down)
        XCTAssertFalse(low.fits(.guitar))
        XCTAssertEqual(IntervalPracticeSpec.intervals.first, .m2)
        XCTAssertEqual(IntervalPracticeSpec.defaultRoot(.guitar).midi, 45)
    }

    func testRhythmSpecPresetsAndErrors() {
        let spec = RhythmPracticeSpec(tokens: "q q e e q")
        XCTAssertNil(spec.error)
        XCTAssertEqual(spec.title, "5 notes, 4 beats")
        let exercise = spec.exercise(instrument: .guitar, bpm: 80)
        XCTAssertEqual(exercise?.passage.events.count, 5)
        XCTAssertEqual(exercise?.pacing, .timed)
        XCTAssertEqual(spec.diagram().kind, .rhythm)
        let rests = RhythmPracticeSpec(tokens: "q qr q qr")
        XCTAssertEqual(rests.exercise(instrument: .piano, bpm: 60)?.passage.events.count, 2, "rests are silent")
        let bad = RhythmPracticeSpec(tokens: "q x")
        XCTAssertNotNil(bad.error)
        XCTAssertNil(bad.exercise(instrument: .guitar, bpm: 80))
        for preset in RhythmPracticeSpec.presets {
            XCTAssertNil(RhythmPracticeSpec(tokens: preset.tokens).error, preset.name)
        }
    }

    func testExerciseIndexGroupsByKindWithSectionLinks() {
        var c = course()
        c.stages[0].lessons[1].steps.insert(.quiz(QuizStep(title: "Check", questions: [QuizQuestion(prompt: "?", choices: ["a", "b"], answerIndex: 0, explanation: "")])),
                                             at: 1)
        c.stages[0].lessons[1].steps.append(.song(SongStep(title: "Ode", notes: [["E4"]], rhythm: "q", bpm: 80)))
        let entries = TutorExerciseIndex.entries(course: c)
        XCTAssertEqual(entries.map(\.title), ["Play", "Ode", "Play"])
        XCTAssertEqual(entries.map(\.group), [.chords, .songs, .chords])
        XCTAssertEqual(entries[0].stepIndex, 2, "the quiz was inserted before it")
        XCTAssertEqual(entries[0].sectionIndex, 1, "quiz sections move to the end, so the box is section 1")
        XCTAssertEqual(entries[0].location, "Part 0 · Two")
        XCTAssertEqual(entries[2].lessonID, "g.s1.l1")
        let grouped = TutorExerciseIndex.grouped(course: c)
        XCTAssertEqual(grouped.map(\.group), [.chords, .songs])
        XCTAssertEqual(grouped[0].entries.count, 2)
        XCTAssertEqual(ExerciseGroup.group(for: .scale), .scales)
        XCTAssertEqual(ExerciseGroup.group(for: .strumRhythm), .strumming)
    }

    func testRootLabels() {
        XCTAssertEqual(QuickPracticeRoots.all.count, 12)
        XCTAssertEqual(QuickPracticeRoots.label(SpelledNote("C#")!), "C♯ / D♭")
        XCTAssertEqual(QuickPracticeRoots.label(SpelledNote("Bb")!), "B♭ / A♯")
        XCTAssertEqual(QuickPracticeRoots.label(.G), "G")
    }

    // MARK: Glossary

    func testGlossarySearch() {
        let entries = [
            GlossaryEntry(term: "Major scale", definition: "W-W-H-W-W-W-H."),
            GlossaryEntry(term: "Scale degree", definition: "A note's position in a scale."),
            GlossaryEntry(term: "Octave", definition: "Same letter, double the frequency."),
            GlossaryEntry(term: "Pentatonic scale", definition: "Five notes."),
            GlossaryEntry(term: "Tonic", definition: "Home note of a scale."),
        ]
        XCTAssertEqual(TutorGlossarySearch.filter(entries, query: "").count, 5)
        XCTAssertEqual(TutorGlossarySearch.filter(entries, query: "scale").map(\.term),
                       ["Major scale", "Scale degree", "Pentatonic scale", "Tonic"])
        XCTAssertEqual(TutorGlossarySearch.filter(entries, query: "OCT").map(\.term), ["Octave"])
        XCTAssertEqual(TutorGlossarySearch.filter(entries, query: "frequency").map(\.term), ["Octave"])
        XCTAssertTrue(TutorGlossarySearch.filter(entries, query: "zzz").isEmpty)
        XCTAssertEqual(TutorGlossarySearch.sections(entries).map(\.letter), ["M", "S", "O", "P", "T"])
    }

    // MARK: Songs

    func testSongSuggestionAdapter() {
        let c = course()
        let songs = [
            TutorLibrarySong(fileID: UUID(), title: "Two chords", chords: ["E", "A", "E"]),
            TutorLibrarySong(fileID: UUID(), title: "Needs D", chords: ["E", "D"]),
            TutorLibrarySong(fileID: UUID(), title: "Far away", chords: ["F#m7", "Bb", "C#"]),
        ]
        let none = PathProgress(course: c, statuses: [:])
        XCTAssertTrue(TutorSongSuggestionAdapter.rows(songs: songs, course: c, progress: none).ready.isEmpty)

        let learnedEA = PathProgress(course: c, statuses: ["g.s0.l1": .completed, "g.s0.l2": .completed])
        let rows = TutorSongSuggestionAdapter.rows(songs: songs, course: c, progress: learnedEA)
        XCTAssertEqual(rows.ready.map(\.title), ["Two chords"])
        XCTAssertEqual(rows.ready.first?.fileID, songs[0].fileID)
        XCTAssertEqual(rows.ready.first?.chords, ["E", "A"])
        XCTAssertEqual(rows.almost.map(\.title), ["Needs D"])
        XCTAssertEqual(rows.almost.first?.missing, ["D"])
        XCTAssertEqual(TutorSongSuggestionAdapter.learnedChordSymbols(course: c, progress: learnedEA), ["E", "A"])
    }

    func testChordNamesFromCanonicalMusicXML() {
        let tab = CanonicalTab(title: "T", measures: [CanonicalMeasure(number: 1, chords: [CanonicalChord(name: "Am", positionInMeasure: 0),
                                                                              CanonicalChord(name: "F#m7", positionInMeasure: 0.5)]),
                                          CanonicalMeasure(number: 2, chords: [CanonicalChord(name: "Am", positionInMeasure: 0)])])
        let data = MusicXMLCodec.encode(tab)
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromMusicXML: data), ["Am", "F#m7"])
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromMusicXML: Data("<score-partwise/>".utf8)), [])
    }

    func testChordNamesFromTextTabs() throws {
        let tab = """
          G           C
        e|-3---3---|-0---0---|
        B|-0---0---|-1---1---|
        G|-0---0---|-0---0---|
        D|-0---0---|-2---2---|
        A|-2---2---|-3---3---|
        E|-3---3---|---------|
        """
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTabText: tab), ["G", "C"])

        // Chord sheet without tab staves: chord-symbol lines only.
        let sheet = "Verse\r\nAm      F       C\r\nA man walks down the road\r\nG   Am\r\n"
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTabText: sheet), ["Am", "F", "C", "G"])
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTabText: "Just some words here"), [])

        // File reads are cached by path and modification date, and skip large files.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chords-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(sheet.utf8).write(to: url)
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTextTabAt: url, cacheKey: url.path), ["Am", "F", "C", "G"])
        try Data(repeating: 0x41, count: TutorLibraryChordIndex.textTabByteLimit + 1).write(to: url)
        XCTAssertEqual(TutorLibraryChordIndex.chordNames(fromTextTabAt: url, cacheKey: url.path), [])
    }

    // MARK: Shell state

    func testShellStateInstrumentResetAndSeeding() throws {
        let store = try TutorStore.inMemory()
        let content = CurriculumContent(courses: [.guitar: course()], glossary: [], stageFiles: [:], loadIssues: [])
        let state = TutorShellState(store: store, library: CurriculumLibrary(content: content))
        state.refresh()
        XCTAssertEqual(state.progress?.continueTarget?.id, "g.s0.l1")

        state.seedProgress(firstLessons: 2)
        XCTAssertEqual(state.progress?.continueTarget?.id, "g.s1.l1")
        XCTAssertEqual(state.practiceDays, 1, "one day with chapters marked read")
        XCTAssertEqual(state.todayMinutes, 10, "minutes of the chapters marked read today")
        XCTAssertEqual(store.progress(lessonID: "g.s0.l1", instrument: .guitar)?.attempts, 0)
        XCTAssertTrue(store.dueReviewCards(instrument: .guitar, asOf: .distantFuture).isEmpty, "no cards are seeded")

        state.setInstrument(.piano)
        XCTAssertEqual(store.settings().instrument, .piano)
        XCTAssertNil(state.progress, "no piano course in this fixture")
        state.setInstrument(.guitar)

        state.setDailyGoal(200)
        XCTAssertEqual(state.dailyGoalMinutes, 60)

        store.setLatency(0.05, forRoute: "r")
        state.resetProgress(for: .guitar)
        XCTAssertTrue(store.allProgress(instrument: .guitar).isEmpty)
        XCTAssertEqual(state.progress?.continueTarget?.id, "g.s0.l1")
        XCTAssertEqual(store.latency(forRoute: "r"), 0.05, "reset keeps calibration")
    }

    func testDoneTogglesCountOnlyCompletedChapters() throws {
        let store = try TutorStore.inMemory()
        let c = course()
        let content = CurriculumContent(courses: [.guitar: c], glossary: [], stageFiles: [:], loadIssues: [])
        let state = TutorShellState(store: store, library: CurriculumLibrary(content: content))
        let first = c.stages[0].lessons[0]
        state.setLessonDone(first, done: true)
        XCTAssertEqual(state.progress?.state(of: first.id), .completed)
        XCTAssertEqual(state.todayMinutes, 5)
        state.setLessonDone(first, done: false)
        XCTAssertEqual(state.progress?.state(of: first.id), .available)
        XCTAssertEqual(state.todayMinutes, 0)
        XCTAssertEqual(state.practiceDays, 0)
    }

    // MARK: Games

    func testGameRegistry() {
        XCTAssertEqual(Set(TutorGameRegistry.entries.map(\.id)).count, TutorGameRegistry.entries.count)
        XCTAssertTrue(TutorGameRegistry.entries(for: .guitar).contains { $0.id == TutorGameID.fretboardHunt })
        XCTAssertFalse(TutorGameRegistry.entries(for: .piano).contains { $0.id == TutorGameID.fretboardHunt })
        for entry in TutorGameRegistry.entries {
            XCTAssertFalse(entry.instruments.isEmpty)
            if entry.instruments.contains(.guitar) {
                _ = TutorGameRegistry.isAvailable(entry, instrument: .guitar)   // must not crash
            }
        }
    }

    // MARK: Calibration

    func testCalibrationModelAudioSuccessAndFailure() async {
        let fake = FakeCalibrator()
        fake.audioResult = LatencyEstimate(latency: 0.062, spread: 0.01, matched: 7, cues: 8)
        let model = TutorCalibrationModel(calibrator: fake, instrument: .guitar, sleep: { _ in })
        XCTAssertFalse(model.isCalibrated)
        XCTAssertEqual(model.currentLatency, LatencyCalibrator.defaultLatency)

        await model.runAudio()
        XCTAssertEqual(fake.audioCalls, 1)
        XCTAssertEqual(fake.lastClicks, 8)
        XCTAssertEqual(model.step, .finished(fake.audioResult!, saved: true))
        XCTAssertTrue(model.isCalibrated)
        XCTAssertEqual(model.currentLatency, 0.062, accuracy: 1e-9)
        XCTAssertEqual(model.resultMessage?.hasPrefix("Saved 62 ms"), true)

        fake.audioResult = LatencyEstimate(latency: 0.2, spread: 0.1, matched: 3, cues: 8)
        await model.runAudio()
        XCTAssertEqual(model.step, .finished(fake.audioResult!, saved: false))
        XCTAssertEqual(model.currentLatency, 0.062, accuracy: 1e-9, "unreliable result is not saved")

        fake.audioResult = nil
        fake.failure = "No matching notes"
        await model.runAudio()
        XCTAssertEqual(model.step, .failed("No matching notes"))
    }

    func testCalibrationModelVisualPulses() async {
        let fake = FakeCalibrator()
        fake.visualResult = LatencyEstimate(latency: 0.09, spread: 0.02, matched: 8, cues: 8)
        let model = TutorCalibrationModel(calibrator: fake, instrument: .piano, sleep: { _ in })
        XCTAssertEqual(model.profile.instrument, .piano)
        await model.runVisual()
        XCTAssertEqual(fake.cues, TutorCalibrationModel.pulseCount)
        XCTAssertEqual(model.step, .finished(fake.visualResult!, saved: true))

        fake.beginSucceeds = false
        fake.failure = "Microphone access is off."
        await model.runVisual()
        XCTAssertEqual(model.step, .failed("Microphone access is off."))
    }

    func testRouteAndPitchCheckFormatting() {
        XCTAssertEqual(TutorCalibrationModel.routeDescription("out=Speaker;in=MicrophoneBuiltIn"),
                       "Speaker · Built-in microphone")
        XCTAssertTrue(TutorCalibrationModel.isBluetoothRoute("out=BluetoothA2DPOutput;in=MicrophoneBuiltIn"))
        XCTAssertFalse(TutorCalibrationModel.isBluetoothRoute("out=Speaker;in=MicrophoneBuiltIn"))
        XCTAssertEqual(TutorCalibrationModel.latencyText(0.0804), "80 ms")

        let target = TutorCalibrationModel.checkTarget(for: .guitar).midi
        XCTAssertEqual(target, 40)
        XCTAssertEqual(TutorCalibrationModel.checkTarget(for: .piano).midi, 60)
        XCTAssertEqual(TutorCalibrationModel.pitchCheck(midi: nil, cents: nil, target: target), .waiting)
        XCTAssertEqual(TutorCalibrationModel.pitchCheck(midi: 40, cents: -6.4, target: target), .match(cents: -6))
        XCTAssertEqual(TutorCalibrationModel.pitchCheck(midi: 52, cents: 0, target: target), .wrongOctave(heard: "E3"))
        XCTAssertEqual(TutorCalibrationModel.pitchCheck(midi: 45, cents: 0, target: target), .other(heard: "A2"))
        XCTAssertTrue(TutorCalibrationModel.pitchCheckMessage(.match(cents: 25), target: 40).contains("25 cents sharp"))
    }

    func testShellLatencyStoreWritesTutorStore() throws {
        let store = try TutorStore.inMemory()
        let route = "test-route-\(UUID().uuidString)"
        let latency = TutorShellLatency.store(store)
        latency.setLatency(0.07, forRoute: route)
        XCTAssertEqual(store.latency(forRoute: route), 0.07)
        XCTAssertEqual(latency.latency(forRoute: route), 0.07)
        UserDefaults.standard.removeObject(forKey: "tutor.latency." + route)
    }
}

@MainActor
private final class FakeCalibrator: TutorLatencyCalibrating {
    var audioResult: LatencyEstimate?
    var visualResult: LatencyEstimate?
    var failure: String?
    var beginSucceeds = true
    var stored: TimeInterval?
    private(set) var audioCalls = 0
    private(set) var lastClicks = 0
    private(set) var cues = 0

    func runAudioCalibration(profile: InstrumentProfile, clicks: Int, interval: TimeInterval) async -> LatencyEstimate? {
        audioCalls += 1
        lastClicks = clicks
        if let r = audioResult, r.isReliable { stored = r.latency }
        return audioResult
    }

    func beginVisualCalibration(profile: InstrumentProfile) async -> Bool {
        cues = 0
        return beginSucceeds
    }

    func registerVisualCue(hostTime: UInt64) { cues += 1 }

    func finishVisualCalibration() async -> LatencyEstimate? {
        if let r = visualResult, r.isReliable { stored = r.latency }
        return visualResult
    }

    func cancel() {}
    func currentLatency() -> TimeInterval { stored ?? LatencyCalibrator.defaultLatency }
    var isCalibrated: Bool { stored != nil }
    var failureMessage: String? { failure }
}
