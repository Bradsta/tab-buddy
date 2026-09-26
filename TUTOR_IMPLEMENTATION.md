# TabBuddy Tutor — implementation plan (2026-09-25)

Companion to `TUTOR_PLAN.md` (research and product decisions). This file is the build contract for every work package. Status (2026-09-25): **implemented; unit-tested on the simulator with synthetic audio; not yet validated with a real microphone or on a device.** `PROJECT.md` is the source of truth for current behavior. The notes marked *As built* record where the implementation differs from the original plan.

Decisions that bind all packages:
- Guitar (acoustic) and piano are both taught through **microphone listening only**. There is no MIDI input.
- **App audio output is muted while listening.** Timing cues during graded play are visual: beat pulse, visual count-in, and score cursor.
- **Fully offline.** There are no network calls, no LLM, and no downloaded models. Everything ships in the bundle.
- The learning track is a **recommended path with optional side branches**. (Changed 2026-09-25 at the user's request: every lesson is open and can be marked done to skip it; originally lessons unlocked in order.)
- **iPad is the primary device.** Every tutor and practice screen must be first class on iPad:
  - Use regular-width layouts: split/sidebar navigation, a diagram beside the explanation, and the review overlay beside the stats. Don't stretch phone layouts.
  - Support all orientations, Split View / Stage Manager resizing, and pointer + hardware keyboard (space = start/stop listening, arrows = step navigation).
  - Use large tap targets readable from a music stand.
  - Latency calibration and mic checks account for the iPad mic position and distance from the instrument.
  - iPhone must still work in compact width.
  - Verify on an iPad simulator.
- Grading checks **pitch, not string/fret**. When unsure, report `uncertain` instead of marking the note wrong.

## 1. Code layout

All new code lives in file-system-synchronized folders, so **no `project.pbxproj` edits are needed to add files**:

```
TabBuddy/Tutor/                 (synchronized group → TabBuddy app target)
  Shared/TutorContracts.swift   cross-package data types (do not change without updating this doc)
  Theory/                       WP-A  pure theory core
  Listening/                    WP-B  audio input, calibration, detectors, synth
  Assessment/                   WP-C  alignment, tempo, expected-event adapters
  Store/                        WP-C  SwiftData tutor store (separate container)
  Curriculum/                   WP-D  content model loader, generators, SRS
  Content/                      WP-D  bundled JSON (tutor-*.json, unique file names; bundle is flat)
  UI/                           WP-E  tutor home, lesson player, quizzes, diagrams, calibration
  Games/                        WP-G  drills/games
  Practice/                     WP-F  library practice mode + review
TabBuddyTests/Tutor/            (synchronized group → TabBuddyTests target)
```

Rules:
- Keep existing SwiftData stores (`cloud`/`local`) and `FileItem` untouched. Tutor data uses its **own** `ModelContainer` at `Application Support/Tutor/tutor.store`, local only, with no CloudKit.
- Edit existing files only at the integration points listed in §8.
- Swift 5 language mode, iOS 17 deployment target, SwiftUI, and the existing `DesignSystem.swift` tokens/colors.
- No new third-party dependencies.

## 2. Shared contracts (`Tutor/Shared/TutorContracts.swift`)

Defines `TutorInstrument`, `ExpectedEvent`, `ExpectedPassage`, `DetectedEvent`, `EventGrade`, `GradedEvent`, `ExtraNote`, `TempoSample`, `TakeAnalysis`, `VerificationResult`, and `InstrumentProfile`. Pitches are sounding MIDI numbers after capo. Times are seconds on the take clock, measured from the first sample after listening starts and already latency-corrected.

*As built:*
- Beats count from the passage start in the passage's own beat unit, and `bpm` is in that unit. MIDI, alphaTab, and exercise passages use quarter notes. MeasureMap and Canonical passages use the measure's beat (e.g. the eighth in 3/8).
- `ExpectedEvent.octaveTolerant` grades by pitch class: any octave, voicing, or inversion. Only slash chords (a `chordName` containing `/`) also require the lowest expected pitch class in the bass. It is used for chord exercises whose symbols carry no register.
- `TutorInstrument` is `guitar | piano`. Bass is a listening profile, not a third instrument.

## 3. WP-A — Theory core (`Tutor/Theory`)

Pure Swift. No UI or audio imports. All types are `Codable, Hashable, Sendable`.

- `PitchClass` (0–11), `NoteLetter`, `SpelledNote` (letter + accessor offset, e.g. F#, Bb, Cx), `Pitch` (spelled note + octave → MIDI; scientific pitch notation, C4 = 60).
- Parsing: `Pitch("E2")`, `Pitch("C#4")`, `Pitch("Bb3")`; `SpelledNote("F#")`.
- `Interval`: quality + number (P1…P8, m2…M7, A4/d5, up to 13ths), semitones, `name` ("major third"), `shortName` ("M3"), and spelled transposition (`SpelledNote.transposed(by:)` keeps correct letters: C + M3 = E, E + m3 = G, F# + M3 = A#).
- `ScaleType`: major, natural/harmonic/melodic minor, major/minor pentatonic, blues, and the seven modes, chromatic. `Scale(root:type:)` produces spelled notes and `degrees`. Parse "C major", "A minor pentatonic", "D dorian".
- `ChordQuality`: maj, min, dim, aug, sus2, sus4, 5 (power), 6, m6, 7, maj7, m7, m7b5, dim7, add9, 9, m9, maj9. `Chord(root:quality:bass:)` gives spelled tones, `symbol` ("Am7", "C/G"), and a parser for common symbols ("A", "Am", "A7", "Amaj7", "AM7", "A-7", "Asus4", "A5", "C/G", "Bbm7b5", "F#dim7").
- `Key` (tonic + major/minor): `signature` (fifths count, accidentals list), `diatonicTriads` / `diatonicSevenths`, `romanNumeral(for: Chord)`, `chord(forRoman: "V7")`, relative/parallel keys, and `circleOfFifths` ordering.
- Rhythm: `NoteValue` (whole…sixteenth, dotted, triplet) with beat lengths; `RhythmPattern` parsed from tokens `"q q e e q"` (w h q e s, `.` dotted, `r` rest suffix e.g. `qr`, `t` triplet e.g. `te`).
- `FretboardLayout(tuningMIDI: [Int] (high→low string order, index 0 = highest string, matching `MeasureMap`), fretCount: 20, capo: 0)`: `midi(string:fret:)`, `positions(of pitch/pitchClass)`, `positions(in scale, fretRange)`, and common open-chord fingerings for maj/min/7 open chords (E A D G C Am Em Dm E7 A7 D7 G7 C7 B7 Fmaj7 Cadd9) plus movable barre forms (E- and A-root). Presets: standard guitar, reusing `GuitarTuning` values where practical.
- `KeyboardLayout(lowestMIDI: 21, highestMIDI: 108)`: `isBlack(midi)`, white-key index, and the key range for an octave view.
- `NoteNaming`: prefer sharps/flats by key context; `displayName(midi:, in key:)`.
- Tests: `TabBuddyTests/Tutor/TheoryTests.swift`, covering spelling correctness (all 12 major keys' scales and signatures), interval math, chord parsing round-trips, Roman numerals, rhythm parsing, and fretboard positions.

## 4. WP-B — Listening (`Tutor/Listening`)

- `TutorAudioSession` (@MainActor singleton): owns one `AVAudioEngine` input tap for the tutor. Uses category `.playAndRecord` and mode `.measurement`. It requests mic permission and publishes `isListening`, `inputLevel`, and `permissionDenied`. When listening starts it posts `Notification.Name.tutorListeningWillStart` and sets `TutorAudioSession.outputMuted = true`. Any app audio that plays during listening must stop. The synth refuses to play while muted, and existing engines are wired in §8. It posts `.tutorListeningDidStop` on stop. It records the take to a `.caf` file (mono, 16-bit or float, input rate) for review playback and post-analysis. The take clock starts at 0 on the first buffer.
- `LatencyCalibrator`: plays 8 clicks, then listens for the player's matching strums/taps. It measures median offset per audio route (`AVAudioSession.currentRoute` output port type) and persists it via the tutor store (`CalibrationRecord`). The fallback is visual-pulse tap calibration with no audio out. A default of 0.08 s is used until calibrated.
- *As built — timing:* detections are stamped at their sample position minus the calibrated input→detection latency. `TutorListener.takeClock`, which drives visual cues and timed arming, is the **host clock mapped onto the take clock** through the tap buffers' timestamps. It is not the raw sample count, which lags by the tap's delivery delay. The two clocks agree when the player plays on the cue, whatever the buffer size. Fresh takes record to `tmp/TutorTakes/*.caf` (mono Float32).
- *As built — calibration store and routes:* `TutorLatency.store()` is the one latency store for lessons, games, practice, and the calibration screen. It reads and writes `CalibrationRecord` in the tutor store, mirrored to `UserDefaults` `tutor.latency.<routeKey>`. `TutorAudioSession.currentRouteKey()` returns `out=<ports>;in=<ports>` for the route listening will use: receiver→speaker, HFP→A2DP. When not recording, the input is predicted from the preferred or available inputs (USB/headset/line-in before the built-in mic), so the key is stable before, during, and after listening. Keys with `in=none`/`out=none` are ignored. Calibration measures cue→detected-onset delay; for audio clicks the output latency is removed, since graded cues are visual.
- `InstrumentProfile` presets (`.acousticGuitar`, `.piano`, and *as built* `.bassGuitar`, which practice selects for bass tracks, tunings whose lowest open string is below D2, or files listing bass without another guitar-family instrument): pitch range, whitening band (guitar body 73–110 Hz; piano none), harmonic count, inharmonicity coefficient (piano B ≈ 0.0004 scaled by register; guitar ≈ 0), silence gate, and onset thresholds.
- `ExpectedNoteVerifier` (tier B): offline-testable and sample-clock driven like `NoteTranscriberCore`, which it may share code with or reuse. API: `process(samples:)`; `arm(_ events: [ExpectedEvent], window:)`; emits `VerificationResult` per armed event. It computes harmonic salience per expected pitch on the whitened onset-difference spectrum, with octave-competitor checks (±12, and −19/+19 for the fifth-harmonic confusion) and extra-note scanning. It also runs a chroma chord check against the expected chord and near-miss templates. It supports a *wait mode*, where one armed event with no time window is satisfied on its first confident match, and a *timed mode*, where events come with expected times and ± windows.
- `PolyphonicTranscriber` (tier C, post-take): protocol `transcribe(url:, profile:) async -> [DetectedEvent]`. The default implementation is `IterativeHarmonicTranscriber`: onset segmentation, then per-segment iterative harmonic-sum multipitch estimation with spectral subtraction (Klapuri-style) up to 6 pitches for guitar and 10 for piano, with piano inharmonicity. Keep the protocol so a Core ML model can be added later; do not add one now.
- `MonophonicListener`: a thin adapter that runs `NoteTranscriberCore` on the tutor tap and emits `DetectedEvent`s (source `.monophonic`) for "play any C" and ear-training answers. Also exposes the live frequency/cents value for the tuner-style needle.
- `TutorListener` (@MainActor ObservableObject), the facade UIs use: `start(profile:)`, `stop()`, `arm(...)`, `onVerification`, `onDetected`, `takeURL`, `takeClock`, and `latency`.
- `TutorSynth`: `AVAudioUnitSampler` loading bundled `GuitarProAssets/soundfont/sonivox.sf2` (program 0 = piano, 25 = steel guitar). API: `play(pitches:, style: .block/.arpeggio/.sequence, bpm:)`, `playClick()`, and `stop()`. It refuses output while `outputMuted`.
- Test signal synthesis for tests (`TabBuddyTests/Tutor/SyntheticAudio.swift`): Karplus–Strong plucked strings with body-resonance noise, additive piano tones with inharmonicity and decay, room noise, and silence.
- Tests: `ListeningTests.swift`. Verifier hit rate on synthetic single notes E2–E5 and 8 open chords; **false-hit rate on silence and noise ≈ 0**; wrong-chord (E vs Em) rejection; octave-error rejection; piano notes A0–C8 sampled and triads; polyphonic transcriber precision/recall on synthetic chords. Real-recording thresholds are validated later with the fixture corpus (§9); synthetic results are not proof of real-world accuracy.

## 5. WP-C — Assessment + store (`Tutor/Assessment`, `Tutor/Store`)

- `PassageBuilder`:
  - `from(measureMap:, measureRange:, bpm:)` uses `MeasureMap` + `resolvedOpenStringMIDI` + capo and `NoteEvent.positionInMeasure/frets`.
  - `from(canonical: CanonicalTab, …)`.
  - `from(midiFileURL:, track:)` via AudioToolbox `MusicSequence` (like `MIDITempoExtractor`).
  - `from(alphaTabNotes: [[String: Any]])` for Guitar Pro export messages (WP-F sends them). *As built*, the keys are `track, bar, start, duration, midi[], tempo, ticksPerQuarter (960), barStartTick, beatsPerBar, beatValue`. Ticks are in score order, and repeats are not expanded. Tied continuations, dead notes, grace notes, rests, and percussion staves are skipped.
  - *As built*, beat units: `beatsPerMeasure` is in the passage's beat unit. For quarter-note sources, x/8 bars convert as 6/8→3, 12/8→6, 3/8→2; 5/8, 7/8, and 9/8 round up.
  - `from(lesson exercise …)` helpers for sequences/scales/chords.
  - Merges simultaneous notes into one event. Skips unknown pitches (tunings without octave information).
- `PerformanceAligner`: global alignment of `[DetectedEvent]` to `[ExpectedEvent]`. It uses a chord-aware Needleman–Wunsch/DTW with pitch-set similarity (Jaccard with octave-tolerant partial credit) plus a timing cost against an estimated tempo line. It is robust to skipped or repeated passages and outputs `GradedEvent`s + `ExtraNote`s. The port and generalization of `.diag/authbench.swift` ideas start here.
- `TempoAnalyzer`: from matched pairs (beat, time), removes latency/global offset, does sliding ~2-bar robust (Theil–Sen) local tempo → `[TempoSample]`, and per-note offset (ms) from the *local* line. Also computes drift classification per measure (rushing/dragging/steady) and timing MAD. Free-time passages skip timing.
- `TakeAnalyzer`: glue that combines verifier results from the live run with the tier-C transcription, aligns them, analyzes tempo, and outputs `TakeAnalysis`. Also produces suggestions: the weakest measure range, and a loop at a reduced tempo percentage.
- `TutorStore` (separate `ModelContainer`, local file `Application Support/Tutor/tutor.store`, no CloudKit). Models:
  - `LessonProgressRecord(lessonID, instrument, status, bestScore, attempts, completedAt)`
  - `ReviewCardRecord(itemID, instrument, kind, prompt, answer, due, stability, difficulty, reps, lapses, lastReview)`
  - `PracticeTakeRecord(id, scoreKey (FileItem.id UUID string), scoreTitle, date, firstMeasure, lastMeasure, bpm, accuracy, timingMADms, analysisJSON: Data, audioFileName?)`
  - `CalibrationRecord(routeKey, latencySeconds, date)`
  - `TutorSettingsRecord(currentInstrument, dailyGoalMinutes)`
  - Take audio is stored in `Application Support/Tutor/Takes/`, capped at the 10 most recent takes per score, deleting older take **audio** only. Analysis records are kept. *As built*, saved audio is also re-encoded to AAC `.m4a` in the background and excluded from backup. There is a global cap of 200 files / 500 MB, oldest first. `analysisJSON` holds a `PracticeTakeArchive`: the `TakeAnalysis` keys plus the passage and take settings.
- Tests: `AssessmentTests.swift` (alignment with inserted/deleted/wrong notes, chords, tempo drift detection on synthetic rushed/dragged timelines, MIDI passage parsing with a generated MIDI file, MeasureMap passages from a text tab fixture) and `TutorStoreTests.swift` (in-memory container CRUD, take-audio pruning).

## 6. WP-D — Curriculum (`Tutor/Curriculum`, `Tutor/Content`)

- Content model (`CurriculumModel.swift`), all `Codable`:
  - `Course(instrument, title, stages)` is assembled by the loader from `tutor-<instrument>-stage-NN.json` files.
  - `Stage(id, order, title, summary, lessons, branches)`
  - `Branch(id, title, summary, unlocksAfter: lessonID, lessons)`
  - `Lesson(id, title, summary, minutes, steps, reviewItems, glossaryTerms)`
  - `LessonStep`: a tagged enum with `type` field `explain | demo | practice | quiz | song`.
  - `ExplainStep(title, body markdown, diagram?)`
  - `Diagram(kind: fretboard|keyboard|staff|circleOfFifths|rhythm|intervalLadder, scale?, chord?, notes?: [String], key?, rhythm?, labels: noteNames|degrees|intervals|none)`
  - `DemoStep(title, caption, playback: PlaybackSpec)` with `PlaybackSpec(notes?: [[String]], chords?: [String], scale?, rhythm?, bpm, style)`
  - `PracticeStep(exercise: ExerciseSpec, mistakeTips: [String])`
  - `ExerciseSpec(kind, prompt, notes?, chords?, scale?, octaves?, key?, bpm?, tempoSteps?: [Double], durationSec?, rhythm?, repetitions?, pitchClass?, passAccuracy (default 0.8))`
  - `ExerciseKind`: `playNote | findAllNotes | playSequence | playChord | chordChanges | strumRhythm | scale | intervalPlayback | melodyEcho | improvise`
  - `QuizStep(questions?: [QuizQuestion], generator?: QuizGeneratorSpec, count)`
  - `QuizQuestion(prompt, choices, answerIndex, explanation, playback?, diagram?)`
  - `QuizGeneratorSpec(kind: noteOnFretboard|noteOnKeyboard|intervalByEar|intervalByName|chordQualityByEar|chordSpelling|keySignature|romanNumeral|scaleDegreeByEar|rhythmCount|scaleSpelling, params)`
  - `SongStep(title, notes: [[String]] per event or chords, rhythm, bpm)` for short excerpts written in-app. Songs must be public domain or original melodies; do not transcribe copyrighted songs. Library songs are suggested separately by chord content.
- `CurriculumLoader`: loads and validates all bundled JSON at startup. Validation parses every pitch/chord/scale/key/rhythm through the WP-A parsers. A unit test runs the validator on every content file.
- `ExerciseGenerator` / `QuizGenerator`: produce concrete `ExpectedPassage` / questions from specs using WP-A (e.g. `scale: "G major", octaves: 1` → fretboard-appropriate pitches; `intervalByEar` → random root in range + interval set).
- `ReviewScheduler`: FSRS-style (simplified: stability/difficulty update on grade Again/Hard/Good/Easy, due-date math), using `ReviewCardRecord`s. It seeds cards from `Lesson.reviewItems` on lesson completion.
- `PathProgress`: computes locked/available/completed per lesson on the fixed path (sequential), with branches unlocking after `unlocksAfter` and never blocking the path.
- `FeedbackCoach`: rules. After 3 consecutive misses on the same target, show the step's `mistakeTips` in rotation; after 3 clean runs with `tempoSteps`, offer the next tempo; after a pass, say which item was weakest.
- **Content** (JSON, written in plain encouraging prose, accurate theory; every stage ends with a review quiz):
  - Guitar stages 0–8 per `TUTOR_PLAN.md` §2.2, with side branches: Rhythm reading (after stage 2), Fingerstyle basics (after stage 3), Songs you know (library suggestions, after 3), Blues shuffle (after 6).
  - Piano stages 0–8: 0 setup/mic check/finding middle C; 1 keyboard geography and note names; 2 pulse and rhythm; 3 five-finger positions C and G, hands separately; 4 major scale and intervals; 5 triads, inversions, left-hand chords; 6 keys, Roman numerals, progressions; 7 hands together and accompaniment patterns; 8 minor scales, 7th chords, blues. Branches: Reading the grand staff (after 1), Pedal basics (after 5).
  - `tutor-glossary.json`: `[{term, definition, seeAlso}]` covering every term used in content.
- Tests: `CurriculumTests.swift` (all content decodes and validates, generators produce valid passages, scheduler math, path unlocking).

## 7. WP-E — Tutor UI (`Tutor/UI`)

- Entry: `AppPage.tutor` in `ContentView`, and a **Tutor** item (`graduationcap`) in the `FileBrowserView` toolbar next to Tuner.
- *As built — shell:* `TutorRootView` draws its own sidebar (300 pt) plus detail pane in regular width, inside the app's `NavigationStack`. It does not use `NavigationSplitView`, which cannot nest there. Compact width uses one scrolling home whose sections push onto the app stack. Sections are Path, Reviews, Songs you know, Games, Glossary, Calibration, and Tutor settings. Lessons, reviews, and games are full-screen covers. There is no separate `TutorHomeView`; the home is `TutorPathView` with a Continue hero and summary cards.
- `TutorHomeView`: instrument switch (Guitar | Piano). A path map shows stages as a vertical path with lesson nodes (available/in progress/done; none locked, with Mark as done to skip) and side-branch nodes off the path. Also includes a "Reviews due (n)" card, a "Continue" button, and access to Glossary and Calibration.
- `LessonPlayerView`: step pager with progress, and one renderer per step type:
  - `ExplainStepView` (markdown + `DiagramView`)
  - `DemoStepView` (plays via `TutorSynth`, highlights diagram in sync)
  - `PracticeStepView` (live listening via `TutorListener`; wait-mode progression through the passage; green check per satisfied event; neutral otherwise; visual beat pulse for timed exercises; mistake tips from `FeedbackCoach`; pass/fail summary)
  - `QuizStepView` (multiple choice; ear questions play audio first; *or answer by playing*; explanation after answer)
  - `SongStepView`
  - Completion screen writes `LessonProgressRecord` and seeds review cards.
- Diagrams: `FretboardView` (tuning-aware, highlights, labels, tap to hear), `KeyboardView` (range, highlights, tap to hear), `MiniStaffView` (treble/bass, spelled notes, may reuse drawing ideas from `LiveTranscriptionView`), `CircleOfFifthsView`, `RhythmStripView`, `IntervalLadderView`.
- `ReviewSessionView` (due SRS cards, self-graded or auto-graded answers), `GlossaryView` (searchable), `CalibrationView` (mic permission, input-level check, "play open low E / middle C" check, latency calibration).
- Mic permission denied → a clear message with a Settings deep link. Quizzes still work without the mic.

## 8. WP-F — Library practice mode (`Tutor/Practice` + integration)

- Integration points (the only existing files edited):
  - `TabViewerView` / `TabTransportBar` get a **Practice** control (`waveform.and.mic`), enabled when the open score yields a passage: text/PDF-canonical via `MeasureMap`, Guitar Pro via alphaTab export, or a sibling MIDI.
  - `GuitarProAssets/player.js` + `GuitarProPlayer` get an `exportNotes` command returning `[{track, bar, beatStart (ticks), duration, midi[], tempo}]` for the selected track.
  - `NotePlaybackEngine`, `MetronomeEngine`, `PlaybackCoordinator`, and `GuitarProPlayer` observe `.tutorListeningWillStart` and pause/stop output.
- `PracticeSessionController`: modes **Wait** (cursor advances when the expected event is verified) and **Play-along** (cursor moves at chosen tempo %, visual count-in and beat pulse, audio muted). Loop range comes from the existing loop selection. Records the take. At the end it runs `TakeAnalyzer` in the background and saves `PracticeTakeRecord`.
- `PracticeOverlay`: live light feedback over the native drawn tab (`DrawnTabSystemView`), where satisfied events tint green. For alphaTab/PDF, show a compact event strip above the transport instead of drawing over the page.
- *As built:* `PracticeModeView` is an overlay on `TabViewerView` (practice bar, range/speed/instrument, Space/→/Escape). Tempo is 25–150%. Play-along uses a one-bar visual count-in, or two bars when a bar is under 2 s. Takes under 3 s, or stopped in the count-in, are discarded. A route change or interruption stops the take.
- `TakeReviewView` (sheet; *as built*, a large sheet on every size class, page-sized on iOS 18+):
  - Per-system note strip with expected notes, hits green, misses hollow, wrong pitch as a red played note name beside the expected note, and extras as small gray marks.
  - Timing lane with early/late ticks.
  - Tempo ribbon (BPM vs measure, target line, tap-to-loop region).
  - Summary: accuracy, timing MAD, weakest measures, and a suggested next step button that sets loop + tempo.
  - Take playback synced to a cursor.
  - History: a per-measure accuracy heatmap across takes for this score.
- Piano scores: practice is available when structure exists (Guitar Pro piano track, sibling MIDI). PDFs without structure show why Practice is unavailable.

## 9. WP-G — Games (`Tutor/Games`)

Games open from the Tutor home "Games" shelf and also appear as lesson practice steps where relevant. Each game has instrument variants, a best-score record, and generated content from WP-A. *As built*, the best-score record is a `LessonProgressRecord` with id `game.<id>.<instrument>`, plus `.level<n>` above level 1; Chord Change Sprint appends `.<chord-pair>` for a non-default pair. Game ids are `fretboard-hunt`, `key-hunt`, `chord-change-sprint`, `interval-duel`, `name-that-quality`, `rhythm-tapper`, `scale-runner`, and `note-rush`. Games are full-screen from the Games shelf; they are not embedded as lesson steps.
- Fretboard/Keyboard Hunt: find every position of a pitch class in 30 s.
- Chord Change Sprint: count clean changes in 60 s.
- Interval Duel: by ear, answer by tap or by playing.
- Name That Quality: by ear.
- Rhythm Tapper: tap-screen or play; onset timing graded.
- Scale Runner: speed ladder.
- Note Rush: sight-read notes on the staff and play them.

## 10. Validation and docs (WP-H)

- Unit tests per package, run on the iOS 26.2 simulator. The app must build with `CODE_SIGNING_ALLOWED=NO`.
- Offline benchmark: extend `.diag/authbench.swift` with a `--verifier` mode and a fixture manifest format (`fixtures.json`: audio path, expected passage, instrument). Real recordings are user-supplied and git-ignored. *Not done yet.*
- **Not provable in this environment:** real microphone accuracy on an acoustic guitar or piano, latency on hardware, and learning quality. These need your on-device testing and the recorded fixture set.
- Docs: update `PROJECT.md` (features, Tutor store contract, limits), `README.md` (Tutor + Practice workflow), `DESIGN.md` (tutor UI decisions), and `PROGRESS.md` (dated validation notes).

## 11. Build order

1. Scaffold: synchronized folders, contracts (done by the coordinator).
2. Parallel: WP-A theory, WP-B listening, WP-C assessment/store, WP-D curriculum model + content (content authoring can start immediately against this schema; the loader/validator waits for WP-A).
3. Parallel: WP-E tutor UI, WP-F practice mode.
4. WP-G games; WP-H validation, docs, and a full review pass with fixes.
