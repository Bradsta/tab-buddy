# TabBuddy Tutor — research and plan (proposal, 2026-09-25)

Status: **research and decision record.** Written as a proposal before implementation. Much of it was built on 2026-09-25, with differences; see `TUTOR_IMPLEMENTATION.md` for as-built notes and `PROJECT.md` for current behavior. The Basic Pitch / Core ML tier C described below was not adopted. Post-take transcription is an offline DSP transcriber.

Goal: turn TabBuddy into a built-in guitar tutor that teaches music theory through the instrument. It should cover beginner exercises through advanced concepts with explanation, practice, quizzes, and game-like drills. It should also listen to library songs and show how the player did. Piano is a later second instrument. The theory content should be written so piano can reuse it.

**Decisions (2026-09-25):**
- Primary instrument is an **acoustic guitar**, heard through the device microphone.
- **Device output is muted while listening.** Detection never has to separate the app's own sound from the player's.
- The tutor is **fully offline**. There is no network LLM, and all content ships with the app.
- The learning track is a **fixed path with optional side branches**.

The plan has three systems. They share two foundations:

```
                    ┌──────────────────────────────┐
                    │  Theory core (pure Swift)    │  notes, intervals, scales,
                    │  + Fretboard/Keyboard maps   │  chords, keys, tunings
                    └──────────────┬───────────────┘
                                   │
┌──────────────────┐   ┌───────────┴────────────┐   ┌──────────────────────────┐
│ 1. Listening     │──▶│ Performance assessment │◀──│ Expected notes           │
│   (mic → events) │   │ (align, grade, tempo)  │   │ (lesson or CanonicalTab) │
└──────────────────┘   └───────────┬────────────┘   └──────────────────────────┘
                                   │
               ┌───────────────────┼────────────────────┐
               ▼                   ▼                    ▼
      2. Learning track    3. Library practice    Games / quizzes
```

---

## 0. What exists today

| Piece | File | Relevance |
|---|---|---|
| Monophonic live note detection: spectral-flux onsets, YIN pitch voting, legato detection | `TabBuddy/NoteTranscriberCore.swift`, `PitchDetector.swift` | Good base for single-note exercises. Benchmark: ~55% recall / ~49% precision on a *polyphonic* amateur recording. It emits one pitch per onset, so it cannot do chords. |
| Tuner and live transcription UI | `TunerView.swift`, `LiveTranscriptionView.swift` | Existing mic permission flow and staff drawing |
| Offline benchmark with Needleman–Wunsch alignment against a tab | `.diag/authbench.swift` | This is already the core of the "compare playing to the score" algorithm |
| Structured song data with measures, beats, MIDI pitch, string/fret, and chords | `Canonical/CanonicalTab.swift`, `MeasureMap.swift` | This is the "expected notes" source for practice mode |
| Metronome, loops, count-in, speed trainer, and measure following | `MetronomeEngine.swift`, `Player/TabTransportBar.swift`, `PlaybackCoordinator.swift` | Practice mode builds on these instead of adding a parallel transport |

**Key finding:** the current detector solves the harder problem: *blind* transcription, where nothing is known about what is being played. A tutor almost never needs this. In lessons and library practice, the app **knows what should be played**. Checking whether expected notes are present is much more reliable than discovering unknown notes. Commercial apps (Yousician, Rocksmith+, Simply Piano) rely on this kind of score-informed check. Most of the listening design follows from this.

---

## 1. Listening to the player

### 1.1 Three detection tiers

| Tier | Question it answers | Method | Latency | Use |
|---|---|---|---|---|
| **A. Monophonic tracker** (exists) | "What single note is sounding?" | `NoteTranscriberCore` (YIN + onsets) | ~60–90 ms | Tuner, "play any C" drills, ear-training answers, single-line melodies |
| **B. Score-informed verifier** (new, main tool) | "Are the notes I expect present at about this time, and did anything else sound?" | For each expected pitch, measure harmonic salience in the whitened onset-difference spectrum; also run chroma template matching for chords. Compare against a rest/noise baseline. | ~50–100 ms | Lesson grading, live green/red feedback in practice, chord-change drills |
| **C. Polyphonic transcriber** (new, after the take) | "What did the player actually play?" including wrong notes | Spotify **Basic Pitch** (Apache-2.0, ships a Core ML export, under 20k params, 88-key range, onset + note + pitch-bend outputs) run over the recorded take | Seconds after the take | Review overlay ("you played G here, not A"), free improvisation scoring, future play-to-author upgrade |

Why tier B comes before C: tier B handles chords reliably because it only answers yes/no questions about 1–6 known pitches. Tier C is the general solution, but open-source polyphonic *guitar* transcription is still research-grade. Current models (TabCNN, FretNet, TART, 2025–2026 diffusion work) target desktop GPUs or offline use, and none is a proven real-time mobile model. Basic Pitch is general-instrument, small, and already packaged for Core ML. That makes it the realistic first choice for post-take analysis. It is not accurate enough to grade live.

### 1.2 Tier B design (score-informed verifier)

Inputs: the expected event (a set of MIDI pitches plus a target time window) and the live audio.

1. Reuse the `NoteTranscriberCore` front end: decimation, STFT, spectral flux onsets, and the whitened pre/post-onset difference spectrum. The benchmark memory notes that whitening body thump and using the *difference* spectrum were required to keep ringing strings from capturing detection. The same applies here.
2. For each expected pitch `p`, compute salience `S(p)`: a weighted sum of the first 4–6 harmonics in the difference spectrum, normalized by local spectral median. Guitar low E fundamentals are weak through phone mics, so harmonics carry most of the evidence.
3. Octave check: require `S(p)` to beat `S(p−12)` and `S(p+12)` by a margin. Octave confusion is the most common failure.
4. Extra-note check: scan for unexpected peaks with salience above threshold that are not harmonics of expected notes. These become "extra/wrong note" hints, flagged as low confidence.
5. Chord check: compare a 12-bin chroma vector against the expected chord template and near-miss templates (same root with a different quality, and neighboring chords). This catches "played Em instead of E" even when individual-pitch salience is ambiguous.
6. Output per expected event: `hit / partial (k of n pitches) / missed`, plus the onset time and a confidence value.

Tuning and string limits: tier B checks **pitch, not string/fret.** The mic cannot reliably tell which string produced an A4. Playing the right note at a different position counts as correct. The UI can mention the difference but should not mark it wrong.

### 1.3 Audio front-end requirements (all tiers)

- **One shared `AudioInputService`** that owns `AVAudioSession`/`AVAudioEngine`. Tuner, lessons, and practice all subscribe to it. Use `.measurement` mode to disable AGC and voice processing, which damage the attack and harmonic information.
- **Latency calibration**: a one-time "play along with 8 clicks" step that measures output→input round-trip latency. Store it per audio route (speaker, wired headphones, Bluetooth). Bluetooth adds 150–250 ms, so warn or require recalibration. Timing feedback is not credible without this.
- **Output muted while listening** (decided). Synthesized audio and the audible click are off during graded listening, and no echo cancellation is needed. Timing cues must therefore be visual: a pulsing beat indicator, a visual count-in, and the moving score cursor. Latency calibration is the one exception. It plays clicks briefly *before* listening starts, or asks the player to tap along with a visual pulse. An audible click through headphones could be offered later as an opt-in, but it is out of scope for now.
- **Noise floor / input check** before a session: "Play your open low E" confirms the level and that the guitar is in tune. The existing tuner can drive this.
- **Instrument profile**: tune thresholds for **acoustic guitar through the built-in mic** first (decided). Acoustic guitars have strong body resonance around 90–110 Hz and long sustain. The body-thump whitening and difference-spectrum approach from `NoteTranscriberCore` already targets this. Electric and interface profiles can come later.

### 1.4 Validation (extend the existing harness)

- Grow `.diag/authbench.swift` into a fixture corpus. Record short clips with known ground truth: each open string, notes at frets 0–12 on each string, the 8 common open chords, a C major scale, a pentatonic run, strumming at 60/90/120 BPM, and one or two library songs. Record on both iPhone and iPad if both are targets. Keep recordings out of git, following the existing corpus policy.
- Public benchmark: **GuitarSet** (annotated solo guitar, hexaphonic ground truth) for tier C and tier B chord checks. Check its license before use. It is research data, not app content.
- Metrics: tier B hit precision/recall per event type (single note, dyad, triad, full chord); false "hit" rate when the player is silent or plays something else, which matters most; timing error distribution after latency calibration. Set a ship bar such as ≥95% correct on single notes and ≥90% on open chords, with near-zero false hits during silence.

---

## 2. Learning track

### 2.1 Content principles

- **Theory is taught through the guitar and heard immediately.** Every concept has three views: the sound (the app plays it), the fretboard, and the name/notation.
- **Instrument-agnostic concepts, instrument-specific rendering.** "Major triad = root, major 3rd, perfect 5th" is one concept. Guitar shows fretboard positions; piano later shows keys. This keeps the piano path open without duplicating the curriculum.
- **Every lesson loop:** Explain (short, interactive) → Demo (listen) → Guided practice (mic-graded, with wait mode) → Quiz (answerable with or without the guitar) → scheduled review.
- **Spaced repetition** for anything memorized (note names, chord spellings, intervals by ear, key signatures). Use FSRS or SM-2 per *item*, not per lesson.
- **Connect lessons to the user's library.** After learning E, A, and D, suggest library songs whose canonical chord data uses only those chords. `CanonicalMeasure.chords` already stores that data.

### 2.2 Proposed curriculum (novice → advanced)

Each stage lists theory, guitar skill, ear training, and what the mic can grade.

| Stage | Theory | Guitar skill | Ear | Mic-graded? |
|---|---|---|---|---|
| **0. Setup** | Parts of the guitar, string names (E A D G B E) | Tuning with the tuner; input calibration | Hearing "in tune" vs "out of tune" | Yes (tuner) |
| **1. The musical alphabet** | 12 notes, half/whole steps, sharps/flats, octaves | Finding notes on the low E and A strings (the root strings for later chords) | Higher vs lower; same note vs different | Yes (tier A: "play any G") |
| **2. Pulse and rhythm** | Beats, bars, time signatures, quarter/eighth notes, rests | Picking steady quarters and eighths with a metronome | Clapping back rhythms | Yes: onsets only, very reliable |
| **3. First chords** | What a chord is: root/3rd/5th; major vs minor | E, A, D, Em, Am, G, C; one-minute chord changes; basic strumming | Major vs minor | Yes (tier B chord check) |
| **4. Major scale and intervals** | W-W-H-W-W-W-H, scale degrees, interval names | One- and two-octave major scale fingerings; alternate picking | Intervals with song references; scale-degree recognition | Yes (tier A/B sequence) |
| **5. Keys and harmony** | Diatonic chords, Roman numerals, I–IV–V, I–V–vi–IV, circle of fifths, capo transposition | Progressions in several keys; capo usage | Hearing I/IV/V changes | Yes |
| **6. Pentatonic and blues** | Minor/major pentatonic, blues scale, 12-bar blues | Pentatonic positions 1–5; bends, hammer-ons, pull-offs, slides; first improvisation over a loop | Call-and-response phrases | Partly: in-key percentage and rhythm for improvisation |
| **7. Fretboard system** | CAGED (five movable chord forms), inversions, triads on string sets | Barre chords, all notes on all strings, triads across the neck | Chord inversions | Yes |
| **8. Beyond** | 7th chords, modes, arpeggios, chord-tone soloing, secondary dominants, reading standard notation | Arpeggios through changes; sight-reading single lines | Chord quality (maj7, m7, 7, m7b5); melodic dictation | Yes; dictation can use Tab Maker |

This order follows common guitar pedagogy, similar to JustinGuitar and Berklee method sequencing. **You are a novice, so you cannot easily judge the correctness of theory content I draft. Cross-check each stage against a trusted reference** (for example musictheory.net or a method book) before treating it as final.

### 2.3 Exercise types and games

Generated procedurally from the theory core where possible, so drills never run out:

- **Fretboard Hunt**: "Play every C you can find in 30 s" (tier A). Tracks found positions.
- **Chord Change Sprint**: alternate two chords for 60 s; score = clean changes (tier B).
- **Interval Duel / Name That Quality**: hear it, then answer by tapping *or by playing it back*.
- **Rhythm Tapper**: tap or strum a displayed rhythm; score timing per beat.
- **Scale Runner**: play a scale up and down at a target BPM; the speed trainer raises the tempo after clean runs.
- **Wait-mode song**: the score waits until the right note or chord is heard, then advances. This is standard for beginners and uses tier B only.
- **Boss level**: a stage's final challenge is a real song or excerpt, ideally from your library.
- Quizzes without a guitar: note names, chord spellings, key signatures, and Roman numerals, for practicing away from the instrument.

Progress should be shown as a skill map with per-item mastery. Avoid manipulative streak mechanics. A gentle practice-days count is fine.

### 2.4 Content format

- Lessons as bundled, versioned data (JSON or a small Swift DSL): text blocks, interactive diagrams, audio demos, and exercise specs such as `{type: chordChange, chords: [E, A], durationSec: 60}`.
- Exercises reference theory-core objects, not hard-coded frets, so transposition, tuning, and future piano rendering work automatically.
- **Offline, scripted tutor** (decided). All explanations are authored content. The tutor feel comes from context-aware feedback rules, not open-ended chat. Examples: after three misses on the same chord, show that chord's common-mistakes card; after a clean run, offer the next tempo step. A searchable glossary answers "what is a 3rd?" lookups.
- **Fixed path with side branches** (decided). The main path is the stage order in §2.2. Side branches are optional detours unlocked along the way, such as a fingerstyle branch after Stage 3, a rhythm-reading branch after Stage 2, and a song branch after each stage. Branches never block progress on the main path.

---

## 3. Practice mode for library songs

### 3.1 The flow

1. Choose a song and optionally a loop range (existing loop controls). Choose **Play-along** (the score moves at the set tempo) or **Wait mode** (the score waits for you).
2. Count-in, then play. Live feedback is intentionally light. Expected notes turn green when hit and stay neutral otherwise. Flashing red during play distracts and punishes detector errors.
3. At the end of the take, the app records it and runs full analysis (tier B for all events, plus tier C in the background).
4. **Review screen** (the main UX):
   - **Overlay on the tab/staff**: expected notes drawn normally; hits tinted green; misses hollow or gray; wrong pitches drawn as a small red note next to the expected one, labeled with the played note name; extra notes as small gray marks between events.
   - **Timing lane** under each system: a tick per played note offset from its target position. Early is left of target and late is right; color intensity shows milliseconds.
   - **Tempo ribbon**: local tempo over the take (BPM vs measure), with the target BPM as a line. Rushing and dragging sections are visible at a glance. Tap a region to loop it.
   - **Summary**: accuracy %, timing spread (median absolute deviation in ms), weakest measures, and a suggested next step ("Loop measures 9–12 at 80%").
   - **Playback of your take** synced to the overlay, with optional A/B against the synthesized reference.
5. **History**: per-song, per-measure accuracy heatmap across takes, showing which sections are improving.

### 3.2 Alignment and tempo algorithm

- **Offline (after the take):** align detected events to expected events with DTW or Needleman–Wunsch over onset times *and* pitch sets. `.diag/authbench.swift` already does order-based NW. Add timing costs and chord-aware matching (a chord is one event; partial matches allowed). Handle skipped or repeated sections with a band-free global alignment on loops.
- **Online (during Play-along and Wait mode):** Play-along knows the expected clock, so check each expected event within a window of about ±150 ms scaled by tempo. Wait mode only needs to verify the next event. Neither requires full score following. Free-tempo following, where the score follows *your* tempo, needs an online time-warping or HMM follower (Dixon's OLTW or Antescofo-style). It is a later feature.
- **Tempo:** from aligned pairs `(scoreBeat_i, time_i)`, fit local tempo with a sliding window of about 2 bars using robust regression. Report per-note deviation relative to that *local* line to separate "uneven notes" from "gradual drift". Remove the global offset and calibrated latency first.
- Rubato and fermatas: songs marked free-time (`Provenance.isFreeTime`) should skip timing grades and grade notes only.

### 3.3 Data and storage

- Practice takes (audio + analysis) are local by default and capped by size, for example the last N takes per song. Analysis JSON is small and can sync; audio should not sync by default.
- Progress, mastery, and SRS state belong in a **new SwiftData model group** rather than changes to `FileItem`. This keeps the existing `cloud`/`local` store schemas migration-compatible per `PROJECT.md`. Sync of learning progress can use the same "Sync library with iCloud" choice later. Test it as a migration boundary.

---

## 4. Roadmap

Each phase ends with something usable, so the design can be checked with real playing before more is built.

| Phase | Build | Done when |
|---|---|---|
| **0. Foundations** | Theory core module (pitch classes, spelling, intervals, scales, chords, keys, tuning-aware fretboard map) with unit tests; `AudioInputService`; latency calibration; fixture recording set + `authbench` extensions for tier B | Theory tests pass; calibrated round-trip latency measured on your device(s); fixture corpus recorded |
| **1. Verifier + lesson runner spike** | Tier B single notes and open chords; minimal lesson runner; Stages 0–1 and part of 3 (tuning, musical alphabet, E/A/D + chord change sprint) | Meets the §1.4 targets on the fixtures; you can complete the lessons on your guitar and the grading feels fair |
| **2. Library practice v1** | Wait mode + Play-along with take recording; review overlay for hits/misses (no tempo yet) on text and Guitar Pro tabs with canonical data | You can loop a section of a library song and see an accurate hit/miss overlay |
| **3. Timing and tempo** | Alignment with timing; timing lane, tempo ribbon, weakest-measure loop suggestion; take history heatmap | Tempo ribbon matches a deliberately rushed/dragged test take |
| **4. Curriculum depth** | Stages 2–6 content, ear training, SRS reviews, quizzes, skill map, library song suggestions | End-to-end path from Stage 0 to 12-bar blues |
| **5. Polyphonic review** | Basic Pitch Core ML on takes for wrong-note identification and free improvisation scoring; evaluate on GuitarSet + fixtures | Wrong-note labels are right often enough to show, measured against fixtures and not assumed |
| **6. Games + advanced** | Remaining games, Stages 7–8, optional free-tempo score following | — |
| **7. Piano** | Keyboard rendering of the same concepts; piano tier B profile; piano stage 0–2 | — |

**Recommended first step:** Phase 0 + the tier B part of Phase 1. It is the riskiest part: if grading is not trustworthy, nothing built on it will feel fair. It also needs your input, which is ~15 minutes of recordings on your guitar and device.

---

## 5. Risks and open questions

**Risks**
- Phone mic + acoustic guitar + room noise may push tier B below the target for low-string chords. Mitigation: harmonic-based salience, calibration, and an interface/electric profile. If needed, relax chord grading to "k of n strings".
- Poor or inaccurate *source tabs* in the library produce unfair grades. Grade only songs with trustworthy canonical data (`Provenance.confidence`), and let users mark a note as a tab error.
- Content effort: a curriculum is a lot of writing and checking. Procedural exercises reduce this; explanations still need review.
- False feedback erodes trust faster than missing feedback. Prefer "not sure" to a wrong red mark.

**Open questions**
- Which devices will you practice on: iPhone, iPad, or both? Mic placement and latency differ, so fixtures should be recorded on each.

---

## 6. Piano: advantages TabBuddy already has or can get

**1. A MIDI keyboard removes the detection problem.** If the piano is a digital piano or MIDI keyboard, CoreMIDI reports exactly which keys were pressed, when, and how hard. There are no detection errors and no chord limit. Grading, timing, and tempo analysis in §3 all work unchanged, because they consume note events regardless of source. TabBuddy has no CoreMIDI input today; `MIDITempoExtractor.swift` only reads MIDI *files*. Adding a MIDI input is a small feature. **This is the largest piano advantage, and it only applies if the piano has USB/Bluetooth MIDI.**

**2. Mic-based piano transcription is better solved than guitar.** Piano is the most-researched transcription domain. It has large aligned datasets (MAESTRO) and a published real-time mobile model (Mobile-AMT, EUSIPCO 2024). Tier B score-informed checking also transfers directly. The difficulties are different from guitar: the sustain pedal blurs note endings, and two hands produce denser chords.

**3. The keyboard is the clearest layout for theory.** White keys are the C major scale. Half and whole steps are visible as adjacent keys. Guitar is better at *transposing* (a movable chord form works in every key), while piano is better at *seeing* the notes. Learning theory on guitar first means piano mostly adds a new motor skill, not new concepts. This is why §2.1 keeps concepts separate from instrument rendering.

**4. Library support already exists in part.**
- Piano PDFs import and scroll today (reading only, no structured notes).
- Guitar Pro files with piano tracks render staff notation through alphaTab, and they carry exact notes for practice-mode grading.
- The library already links sources with free piano scores (Mutopia, OpenScore, IMSLP). Mutopia also publishes MIDI files, and TabBuddy already detects sibling `.mid` files for tempo. Parsing that MIDI into expected notes is a smaller job than building PDF note recognition.
- `Canonical/MusicXMLCodec.swift` exists for the canonical bridge. General MusicXML *import* is listed as not implemented in `PROJECT.md`, and it would be the next source of structured piano content.

**Gaps**
- Native grand-staff engraving is not implemented. Piano PDFs cannot be graded without structured data.
- Tab Maker and fret suggestion are guitar-only by design.
- Piano needs its own beginner motor-skill stages (hand position, fingering numbers, hands separately and then together). These do not map to the guitar stages. The theory stages can be shared.

**Recommended piano path (after the guitar Stage 0–4 content ships):**
1. CoreMIDI input as an alternate event source (if your keyboard supports MIDI).
2. Keyboard rendering for the shared theory concepts.
3. Piano beginner stages.
4. MIDI-file expected notes for practice mode.
5. Mic-based piano detection last, only if an acoustic piano is the target.

## References

- Spotify Basic Pitch (Apache-2.0; Core ML/TFLite/ONNX exports): https://github.com/spotify/basic-pitch
- Mobile-AMT, real-time polyphonic *piano* transcription on mobile (EUSIPCO 2024): https://eurasip.org/Proceedings/Eusipco/Eusipco2024/pdfs/0000036.pdf
- TART, technique-aware audio-to-tab guitar transcription: https://arxiv.org/pdf/2510.02597
- Detecting music performance errors with transformers (AAAI; notes DTW's limits for overlapping notes): https://arxiv.org/pdf/2501.02030
- Score-informed transcription for automatic piano tutoring: https://www.researchgate.net/publication/261349869_Score-informed_transcription_for_automatic_piano_tutoring
- Score-informed networks for performance assessment: https://arxiv.org/pdf/2008.00203
