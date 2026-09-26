//
//  CurriculumValidator.swift
//  TabBuddy
//
//  Checks loaded content against the theory parsers and the generators:
//  every pitch, chord, scale, key, rhythm, and interval string; diagram notes
//  and ranges; the fields each exercise kind needs; quiz answers and
//  generator params; song rhythm/event counts; id uniqueness; branch targets;
//  and glossary coverage (warnings).
//

import Foundation

enum CurriculumValidator {
    static func validate(_ content: CurriculumContent) -> [CurriculumIssue] {
        var issues = content.loadIssues
        var seenStageIDs: [String: String] = [:]
        var seenLessonIDs: [String: String] = [:]
        var seenBranchIDs: [String: String] = [:]
        var seenReviewIDs: [String: String] = [:]

        func unique(_ id: String, _ kind: String, in seen: inout [String: String], file: String,
                    lessonID: String? = nil, path: String = "") {
            if let other = seen[id] {
                issues.append(CurriculumIssue(severity: .error, file: file, lessonID: lessonID, path: path,
                                              message: "duplicate \(kind) id \"\(id)\" (also in \(other))"))
            } else {
                seen[id] = file
            }
        }

        for instrument in TutorInstrument.allCases {
            guard let course = content.courses[instrument] else {
                issues.append(CurriculumIssue(severity: .warning, file: "tutor-\(instrument.rawValue)-stage-*.json",
                                              message: "no stages found for \(instrument.rawValue)"))
                continue
            }
            let context = InstrumentContext.standard(instrument)
            let mainIDs = Set(course.mainPathLessons.map(\.id))
            let branchLessonIDs = Set(course.allBranches.flatMap(\.lessons).map(\.id))
            var orders = Set<Int>()

            for stage in course.stages {
                let file = content.stageFiles[stage.id] ?? "tutor-\(instrument.rawValue)-stage-??.json"
                unique(stage.id, "stage", in: &seenStageIDs, file: file)
                if !orders.insert(stage.order).inserted {
                    issues.append(CurriculumIssue(severity: .error, file: file, path: "order",
                                                  message: "stage order \(stage.order) is used twice for \(instrument.rawValue)"))
                }
                if stage.lessons.isEmpty {
                    issues.append(CurriculumIssue(severity: .error, file: file, message: "stage has no lessons"))
                }
                if let last = stage.lessons.last,
                   !last.steps.contains(where: { if case .quiz = $0 { return true } else { return false } }) {
                    issues.append(CurriculumIssue(severity: .warning, file: file, lessonID: last.id,
                                                  message: "the stage's last lesson has no quiz (stages should end with a review quiz)"))
                }

                var lessons: [(Lesson, String)] = stage.lessons.enumerated().map { ($1, "lessons[\($0)]") }
                for (b, branch) in stage.branches.enumerated() {
                    let path = "branches[\(b)]"
                    unique(branch.id, "branch", in: &seenBranchIDs, file: file, path: path)
                    if !mainIDs.contains(branch.unlocksAfter) {
                        let message = branchLessonIDs.contains(branch.unlocksAfter)
                            ? "unlocksAfter \"\(branch.unlocksAfter)\" is a branch lesson; it should be a main-path lesson"
                            : "unlocksAfter \"\(branch.unlocksAfter)\" is not a lesson in the \(instrument.rawValue) course"
                        issues.append(CurriculumIssue(severity: .error, file: file, path: path + ".unlocksAfter", message: message))
                    }
                    if branch.lessons.isEmpty {
                        issues.append(CurriculumIssue(severity: .error, file: file, path: path, message: "branch has no lessons"))
                    }
                    lessons += branch.lessons.enumerated().map { ($1, "\(path).lessons[\($0)]") }
                }

                for (lesson, _) in lessons {
                    unique(lesson.id, "lesson", in: &seenLessonIDs, file: file, lessonID: lesson.id)
                    var checker = Checker(file: file, lessonID: lesson.id, context: context)
                    checker.checkLesson(lesson, course: course)
                    for (i, item) in lesson.reviewItems.enumerated() {
                        unique(item.id, "review item", in: &seenReviewIDs, file: file, lessonID: lesson.id,
                               path: "reviewItems[\(i)]")
                    }
                    for term in lesson.glossaryTerms where content.glossaryEntry(for: term) == nil {
                        checker.warn("glossaryTerms", "term \"\(term)\" is not in tutor-glossary.json")
                    }
                    issues += checker.issues
                }
            }
        }

        // Glossary
        let glossaryFile = CurriculumLoader.glossaryFileName
        if content.glossary.isEmpty {
            issues.append(CurriculumIssue(severity: .warning, file: glossaryFile, message: "glossary is empty or missing"))
        }
        var terms: Set<String> = []
        for entry in content.glossary {
            if !terms.insert(entry.id).inserted {
                issues.append(CurriculumIssue(severity: .error, file: glossaryFile, path: entry.term, message: "duplicate term"))
            }
            if entry.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(CurriculumIssue(severity: .error, file: glossaryFile, path: entry.term, message: "empty definition"))
            }
        }
        for entry in content.glossary {
            for ref in entry.seeAlso where content.glossaryEntry(for: ref) == nil {
                issues.append(CurriculumIssue(severity: .warning, file: glossaryFile, path: entry.term,
                                              message: "seeAlso \"\(ref)\" is not a glossary term"))
            }
        }
        return issues
    }

    // MARK: - Per-lesson checks

    private struct Checker {
        let file: String
        let lessonID: String
        let context: InstrumentContext
        var stepIndex: Int?
        var issues: [CurriculumIssue] = []

        init(file: String, lessonID: String, context: InstrumentContext) {
            self.file = file
            self.lessonID = lessonID
            self.context = context
        }

        var instrument: TutorInstrument { context.instrument }

        mutating func error(_ path: String, _ message: String) {
            issues.append(CurriculumIssue(severity: .error, file: file, lessonID: lessonID, stepIndex: stepIndex,
                                          path: path, message: message))
        }

        mutating func warn(_ path: String, _ message: String) {
            issues.append(CurriculumIssue(severity: .warning, file: file, lessonID: lessonID, stepIndex: stepIndex,
                                          path: path, message: message))
        }

        /// Runs a parser; records an error with the parser's message on failure.
        @discardableResult
        mutating func parse<T>(_ text: String, _ path: String, _ make: (String) throws -> T) -> T? {
            do { return try make(text) } catch let e as TheoryParseError {
                error(path, e.description)
            } catch {
                self.error(path, "\(error)")
            }
            return nil
        }

        mutating func checkLesson(_ lesson: Lesson, course: Course) {
            if lesson.minutes <= 0 { warn("minutes", "minutes should be positive") }
            if lesson.steps.isEmpty { error("steps", "lesson has no steps") }
            for (i, step) in lesson.steps.enumerated() {
                stepIndex = i
                switch step {
                case .explain(let s):
                    if let d = s.diagram { checkDiagram(d, "diagram") }
                    if let p = s.playback { checkPlayback(p, "playback") }
                case .demo(let s):
                    checkPlayback(s.playback, "playback")
                    if let d = s.diagram { checkDiagram(d, "diagram") }
                case .practice(let s):
                    checkExercise(s.exercise, lesson: lesson, course: course)
                case .quiz(let s):
                    checkQuiz(s)
                case .song(let s):
                    checkSong(s)
                }
            }
            stepIndex = nil
            for (i, item) in lesson.reviewItems.enumerated() { checkReviewItem(item, "reviewItems[\(i)]") }
        }

        // MARK: Diagrams

        mutating func checkDiagram(_ d: Diagram, _ path: String) {
            if let s = d.scale { parse(s, path + ".scale", Scale.init(parsing:)) }
            if let c = d.chord {
                if let chord = parse(c, path + ".chord", Chord.init(parsing:)), d.kind == .fretboard,
                   ChordFingering.open(for: chord) == nil,
                   ChordFingering.BarreForm.allCases.allSatisfy({ ChordFingering.barre(chord, form: $0) == nil }),
                   d.notes == nil {
                    warn(path + ".chord", "no stored fingering for \(c); list the positions in \"notes\"")
                }
            }
            if let k = d.key { parse(k, path + ".key", Key.init(parsing:)) }
            if let r = d.rhythm { parse(r, path + ".rhythm", RhythmPattern.init(parsing:)) }

            switch d.kind {
            case .fretboard:
                let layout = context.fretboard
                var range: ClosedRange<Int>?
                if let fr = d.fretRange {
                    if fr.count != 2 || fr[0] < 0 || fr[0] > fr[1] || fr[1] > layout.fretCount {
                        error(path + ".fretRange", "fretRange must be [low, high] within 0…\(layout.fretCount), got \(fr)")
                    } else {
                        range = fr[0]...fr[1]
                    }
                }
                if d.pitchRange != nil { warn(path + ".pitchRange", "pitchRange is ignored on fretboards") }
                for (i, note) in (d.notes ?? []).enumerated() {
                    guard let pos = parse(note, path + ".notes[\(i)]", FretPosition.init(parsing:)) else { continue }
                    if pos.string >= layout.stringCount || pos.fret > layout.fretCount {
                        error(path + ".notes[\(i)]", "\"\(note)\" is off the \(layout.stringCount)-string, \(layout.fretCount)-fret neck")
                    } else if let range, !range.contains(pos.fret) {
                        warn(path + ".notes[\(i)]", "\"\(note)\" is outside fretRange \(range.lowerBound)…\(range.upperBound)")
                    }
                }
            case .keyboard, .staff, .intervalLadder:
                var range: ClosedRange<Int>?
                if let pr = d.pitchRange {
                    let parsed = pr.enumerated().compactMap { parse($1, path + ".pitchRange[\($0)]", Pitch.init(parsing:)) }
                    if pr.count != 2 {
                        error(path + ".pitchRange", "pitchRange must hold two pitches, got \(pr.count)")
                    } else if parsed.count == 2 {
                        if parsed[0].midi > parsed[1].midi {
                            error(path + ".pitchRange", "pitchRange runs high to low")
                        } else if d.kind == .keyboard, !(21...108).contains(parsed[0].midi) || !(21...108).contains(parsed[1].midi) {
                            error(path + ".pitchRange", "pitchRange leaves the 88-key piano (A0…C8)")
                        } else {
                            range = parsed[0].midi...parsed[1].midi
                        }
                    }
                }
                if d.fretRange != nil { warn(path + ".fretRange", "fretRange only applies to fretboards") }
                for (i, note) in (d.notes ?? []).enumerated() {
                    if note.contains(":") {
                        error(path + ".notes[\(i)]", "\"\(note)\" is a string:fret position; \(d.kind.rawValue) diagrams take pitches like \"C4\"")
                        continue
                    }
                    guard let p = parse(note, path + ".notes[\(i)]", Pitch.init(parsing:)) else { continue }
                    if let range, !range.contains(p.midi) {
                        warn(path + ".notes[\(i)]", "\(note) is outside pitchRange")
                    }
                }
            case .circleOfFifths, .rhythm:
                break
            }
            if d.kind == .rhythm, d.rhythm == nil { error(path, "rhythm diagram without \"rhythm\"") }
            if d.kind == .circleOfFifths, d.key == nil, d.notes == nil { warn(path, "circleOfFifths diagram without a key to highlight") }
            if d.labels == .fingers, d.chord == nil, d.kind == .fretboard, d.notes == nil {
                warn(path + ".labels", "fingers labels need a chord")
            }
        }

        // MARK: Playback

        mutating func checkPlayback(_ p: PlaybackSpec, _ path: String) {
            if p.bpm <= 0 { error(path + ".bpm", "bpm must be positive") }
            var eventCount = 0
            if let notes = p.notes {
                eventCount = notes.count
                for (i, group) in notes.enumerated() {
                    for (j, n) in group.enumerated() {
                        if let pitch = parse(n, path + ".notes[\(i)][\(j)]", Pitch.init(parsing:)),
                           !context.playableRange.contains(pitch.midi) {
                            warn(path + ".notes[\(i)][\(j)]", "\(n) is outside the \(instrument.rawValue) range")
                        }
                    }
                }
            }
            if let chords = p.chords {
                if p.notes == nil { eventCount = chords.count }
                for (i, c) in chords.enumerated() { parse(c, path + ".chords[\(i)]", Chord.init(parsing:)) }
            }
            if let s = p.scale { parse(s, path + ".scale", Scale.init(parsing:)) }
            if p.notes == nil, p.chords == nil, p.scale == nil, p.rhythm == nil {
                error(path, "playback has nothing to play (notes, chords, scale, or rhythm)")
            }
            if let r = p.rhythm, let rhythm = parse(r, path + ".rhythm", RhythmPattern.init(parsing:)), eventCount > 0,
               rhythm.events.count != eventCount, rhythm.noteCount > 0, eventCount % rhythm.noteCount != 0 {
                warn(path + ".rhythm", "\(rhythm.events.count) rhythm tokens for \(eventCount) events; the pattern will repeat unevenly")
            }
            do { _ = try ExerciseGenerator.playback(for: p, context: context) } catch {
                self.error(path, "playback cannot be built: \(error)")
            }
        }

        // MARK: Exercises

        mutating func checkExercise(_ e: ExerciseSpec, lesson: Lesson, course: Course) {
            let path = "exercise"
            if !(0.0...1.0).contains(e.passAccuracy) || e.passAccuracy == 0 {
                error(path + ".passAccuracy", "passAccuracy must be in (0, 1], got \(e.passAccuracy)")
            }
            if let bpm = e.bpm, bpm <= 0 { error(path + ".bpm", "bpm must be positive") }
            if let steps = e.tempoSteps {
                if steps.contains(where: { $0 <= 0 }) || steps != steps.sorted() {
                    error(path + ".tempoSteps", "tempoSteps must be positive and ascending")
                }
                if let bpm = e.bpm, let first = steps.first, abs(first - bpm) > 0.5 {
                    warn(path + ".tempoSteps", "tempoSteps start at \(first) but bpm is \(bpm)")
                }
            }
            if let d = e.durationSec, d <= 0 { error(path + ".durationSec", "durationSec must be positive") }
            if let r = e.repetitions, r <= 0 { error(path + ".repetitions", "repetitions must be positive") }
            if let k = e.key { parse(k, path + ".key", Key.init(parsing:)) }
            if let s = e.scale { parse(s, path + ".scale", Scale.init(parsing:)) }
            if let pc = e.pitchClass { parse(pc, path + ".pitchClass", PitchClass.init(parsing:)) }
            let rhythm = e.rhythm.flatMap { parse($0, path + ".rhythm", RhythmPattern.init(parsing:)) }
            for (i, n) in (e.notes ?? []).enumerated() {
                if let p = parse(n, path + ".notes[\(i)]", Pitch.init(parsing:)), !context.playableRange.contains(p.midi) {
                    error(path + ".notes[\(i)]", "\(n) is outside the \(instrument.rawValue) range")
                }
            }
            for (i, c) in (e.chords ?? []).enumerated() { parse(c, path + ".chords[\(i)]", Chord.init(parsing:)) }
            if let d = e.diagram { checkDiagram(d, path + ".diagram") }

            // Required fields per kind.
            func need(_ present: Bool, _ field: String) {
                if !present { error(path + "." + field, "\(e.kind.rawValue) needs \"\(field)\"") }
            }
            let hasNotes = !(e.notes ?? []).isEmpty, hasChords = !(e.chords ?? []).isEmpty
            switch e.kind {
            case .playNote, .playSequence, .melodyEcho:
                need(hasNotes, "notes")
            case .playChord:
                need(hasChords, "chords")
            case .chordChanges:
                need((e.chords ?? []).count >= 2, "chords")
                if e.durationSec == nil { warn(path + ".durationSec", "chordChanges without durationSec defaults to 60 s") }
            case .strumRhythm:
                need(hasChords, "chords"); need(e.rhythm != nil, "rhythm"); need(e.bpm != nil, "bpm")
                if let rhythm, rhythm.measureCount(beatsPerMeasure: 4) == nil, rhythm.measureCount(beatsPerMeasure: 3) == nil {
                    warn(path + ".rhythm", "strum pattern (\(rhythm.totalBeats) beats) is not a whole bar")
                }
            case .scale:
                need(e.scale != nil, "scale")
                if e.octaves == nil { warn(path + ".octaves", "scale without octaves defaults to 1") }
            case .findAllNotes:
                need(e.pitchClass != nil, "pitchClass")
                if e.durationSec == nil { warn(path + ".durationSec", "findAllNotes without durationSec defaults to 30 s") }
            case .intervalPlayback:
                need(hasNotes, "notes")
                if (e.notes ?? []).count > 2 { error(path + ".notes", "intervalPlayback takes a root, or a root and the upper note") }
            case .improvise:
                need(e.scale != nil || e.key != nil, "scale")
            }
            if e.kind == .playSequence, let rhythm, let notes = e.notes, !notes.isEmpty {
                if rhythm.events.contains(where: \.isRest) {
                    warn(path + ".rhythm", "playSequence rhythm should have one token per note and no rests")
                }
                if rhythm.events.count != notes.count {
                    if notes.count % rhythm.events.count == 0 {
                        warn(path + ".rhythm", "\(rhythm.events.count) rhythm tokens for \(notes.count) notes; the pattern repeats")
                    } else {
                        error(path + ".rhythm", "\(rhythm.events.count) rhythm tokens for \(notes.count) notes")
                    }
                }
            }
            if e.kind == .melodyEcho, let rhythm, let notes = e.notes, rhythm.noteCount != notes.count {
                error(path + ".rhythm", "\(rhythm.noteCount) sounded rhythm tokens for \(notes.count) notes")
            }

            // The generator must produce a usable passage.
            do {
                let intervals = ExerciseGenerator.intervalsTaught(through: lesson.id, in: course)
                let generated = try ExerciseGenerator.generate(e, context: context, intervals: intervals,
                                                               stage: ExerciseGenerator.stage(ofLessonID: lesson.id))
                if e.kind != .improvise, generated.rounds.contains(where: { $0.expected.events.isEmpty }) {
                    error(path, "generated passage is empty")
                }
            } catch {
                self.error(path, "cannot generate: \(error)")
            }
        }

        // MARK: Quizzes

        mutating func checkQuiz(_ q: QuizStep) {
            let fixed = q.questions ?? []
            if fixed.isEmpty, q.generator == nil { error("questions", "quiz needs questions or a generator") }
            for (i, question) in fixed.enumerated() {
                let path = "questions[\(i)]"
                if question.choices.count < 2 { error(path + ".choices", "needs at least two choices") }
                if !question.choices.indices.contains(question.answerIndex) {
                    error(path + ".answerIndex", "answerIndex \(question.answerIndex) is out of range for \(question.choices.count) choices")
                }
                if Set(question.choices).count != question.choices.count { error(path + ".choices", "duplicate choices") }
                if question.explanation.trimmingCharacters(in: .whitespaces).isEmpty { warn(path + ".explanation", "empty explanation") }
                if let p = question.playback { checkPlayback(p, path + ".playback") }
                if let d = question.diagram { checkDiagram(d, path + ".diagram") }
            }
            if let g = q.generator {
                if q.count <= 0 { error("count", "generated quiz count must be positive") }
                let result = QuizGenerator.check(g, instrument: instrument)
                for m in result.errors { error("generator.params", m) }
                for m in result.warnings { warn("generator.params", m) }
            }
        }

        // MARK: Songs

        mutating func checkSong(_ s: SongStep) {
            if s.bpm <= 0 { error("bpm", "bpm must be positive") }
            if s.notes == nil, s.chords == nil { error("notes", "song needs notes or chords") }
            if s.notes != nil, s.chords != nil { warn("chords", "song has both notes and chords; notes are used") }
            guard let rhythm = parse(s.rhythm, "rhythm", RhythmPattern.init(parsing:)) else { return }
            if let notes = s.notes {
                for (i, group) in notes.enumerated() {
                    for (j, n) in group.enumerated() {
                        if let p = parse(n, "notes[\(i)][\(j)]", Pitch.init(parsing:)), !context.playableRange.contains(p.midi) {
                            error("notes[\(i)][\(j)]", "\(n) is outside the \(instrument.rawValue) range")
                        }
                    }
                }
                if notes.count != rhythm.events.count {
                    error("rhythm", "\(rhythm.events.count) rhythm tokens for \(notes.count) events")
                } else {
                    for (i, (group, token)) in zip(notes, rhythm.events).enumerated() {
                        if group.isEmpty, !token.isRest {
                            warn("rhythm", "event \(i) is empty but token \"\(token.token)\" is not a rest")
                        } else if !group.isEmpty, token.isRest {
                            warn("rhythm", "event \(i) has notes but token \"\(token.token)\" is a rest")
                        }
                    }
                }
            } else if let chords = s.chords {
                for (i, c) in chords.enumerated() { parse(c, "chords[\(i)]", Chord.init(parsing:)) }
                if chords.count != rhythm.events.count {
                    error("rhythm", "\(rhythm.events.count) rhythm tokens for \(chords.count) chords")
                }
            }
            if rhythm.measureCount(beatsPerMeasure: Double(s.beatsPerMeasure)) == nil {
                warn("rhythm", "song length \(rhythm.totalBeats) beats is not a whole number of \(s.beatsPerMeasure)-beat measures")
            }
            if !(0.0...1.0).contains(s.passAccuracy) { error("passAccuracy", "passAccuracy must be in 0…1") }
            if (s.notes?.count ?? s.chords?.count) == rhythm.events.count {
                do { _ = try ExerciseGenerator.passage(for: s, context: context) } catch {
                    self.error("", "song passage cannot be built: \(error)")
                }
            }
        }

        // MARK: Review items

        mutating func checkReviewItem(_ item: ReviewItemSeed, _ path: String) {
            if item.prompt.trimmingCharacters(in: .whitespaces).isEmpty { error(path + ".prompt", "empty prompt") }
            if item.answer.trimmingCharacters(in: .whitespaces).isEmpty { error(path + ".answer", "empty answer") }
            if let p = item.playback { checkPlayback(p, path + ".playback") }
            if let d = item.diagram { checkDiagram(d, path + ".diagram") }
            let firstWord = item.answer.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""
            switch item.kind {
            case .playNote:
                if Pitch(firstWord) == nil { warn(path + ".answer", "playNote answer should start with a pitch like \"A2\", got \"\(item.answer)\"") }
            case .playChord:
                if Chord(firstWord) == nil { warn(path + ".answer", "playChord answer should start with a chord symbol, got \"\(item.answer)\"") }
            case .earInterval:
                if item.playback == nil { warn(path + ".playback", "earInterval card needs playback") }
                if ExerciseGenerator.parseIntervalName(item.answer) == nil {
                    warn(path + ".answer", "\"\(item.answer)\" is not an interval name")
                }
            case .earQuality:
                if item.playback == nil { warn(path + ".playback", "earQuality card needs playback") }
            case .noteName:
                if item.diagram == nil, item.playback == nil { warn(path, "noteName card needs a diagram or playback") }
            case .fact:
                break
            }
        }
    }
}
