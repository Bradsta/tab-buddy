# TabBuddy: project guide

This is the current product and implementation guide. Update it in the same commit as behavior changes. `README.md` is the quick start, `DESIGN.md` records interface decisions and design references, and `PROGRESS.md` is a dated history rather than a current feature inventory.

## Product intent

TabBuddy helps musicians find a score and practice it without managing files or playback engines. Guitar and bass tablature remain core uses; piano and other instruments share the library and original-score reader. The library should emphasize recent and frequently played songs, with search and tags for discovery. Reading and dependable scrolling are primary; synthesized audio is optional assistance.

Defaults should work without choosing a directory, having an iCloud account, or understanding the distinction between document storage and metadata databases. Advanced controls should not complicate the first-run flow.

## Current features

- Import PDFs, plain-text tablature, and Guitar Pro 3–8 files (`gp3`, `gp4`, `gp5`, `gpx`, `gp`). Imports copy files; source documents stay untouched. Folder imports preserve their hierarchy and duplicate filenames receive separate destinations. Imports commit the first successful file immediately, then batches of 100; completion, cancellation, and copy failures flush the remainder. Already copied songs remain in the catalog if a later file fails. The fast import phase only copies files and catalogs names/paths; metadata and text-tab preparation are opt-in through Settings → Prepare Library; automatic preparation defaults off. Files must finish copying before they are catalogued; this does not create playable placeholders before downloads finish.
- **… → Settings** groups library storage/offline access, backup export/restore, Generate Tab Data, Rescan Library, and Remove All Files. The main menu retains Select and Settings; removal still requires confirmation.
- Folder view supports selecting a folder and all nested scores, Select All includes folder contents, and folder context menus remove the selected references. External libraries retain source files; files still present are rediscovered on rescan. Managed libraries delete selected song files, without recursively deleting unrelated filesystem contents. Deletion waits for preparation and rescans to stop; stale conversion/fingerprint callbacks cannot write back to deleted models.
- Library search, instrument filtering (only instruments present in the active library, including Unspecified when needed), tags, favorites, recents, most-played sorting, folder browsing, metadata backup/restore, and share-extension imports.
- Tile metadata hides unknown instruments/tunings. Known instruments and tunings use tag-like editable chips that open Score details; tuning supports presets, custom text, and clearing. They remain structured fields rather than free-form tags, and tuning is searchable by raw value or normalized name. Tuning edits describe the arrangement and do not retune score tracks.
- Score details support multiple instruments, composer, arranger/transcriber, game/album/collection, arrangement description, and source name/link. Search includes these descriptive fields. Embedded descriptive fields are indexed by opt-in background preparation for locally available supported files; additional metadata is inferred when a score is opened/converted. Ambiguous instruments remain Unspecified. Saving user edits prevents automatic extraction from overwriting them. Guitar Pro instruments come from track MIDI programs and percussion flags (approximate for instruments without dedicated MIDI programs).
- **Add (+) → Find music online** is the sole library entry point for online discovery. It opens source-specific web searches with the library query and instrument prefilled, or the source homepage when the query is empty. Sources include ClassTab, GameTabs, GProTab, Mutopia, OpenScore Lieder, IMSLP, Sheet Happens, and Musicnotes. Search uses DuckDuckGo only after opening a source. Users download at the source, then import or share the file to TabBuddy. This first version does not aggregate results, scrape sources from the app, process purchases, or host a catalog.
- Original text/PDF viewing is the default. A saved text-player choice remains respected. PDF conversion is now an explicit **Create guitar arrangement** action, not an automatic step on opening a piano score. Parsing and PDF extraction remain best-effort.
- Native tab parsing, drawing, canonical conversion, Maker rendering, and plucked-string playback use the actual string count. Presets include 4/5/6-string bass, high-G ukulele, and 7/8-string guitar. Custom pitch spellings remain visible; unknown octaves do not produce invented MIDI pitches. Unlabeled six-row legacy tabs retain standard-guitar pitch inference. PDF extraction accepts explicit string counts or header evidence, with legacy six-string fallback; this is not universal instrument recognition.
- Guitar Pro rendering through the bundled alphaTab 1.8.4 runtime, fonts, and soundfont. These assets work without a network connection. Track selection and solo are available for multi-track files. The default notation honors the file, including piano staff notation; per-score overrides can select staff, tab, or both when the selected track supports them.
- Shared native practice controls: Smooth scroll and Follow measures, seeking, practice speed, loops, count-in, and a speed trainer. Smooth scroll starts without synthesized audio. Sound is an optional setting. Native audio graph setup and plucked-note samples are deferred until audio starts.
- Tuning normalization across the library and player. Recognizable note sequences use preset names; custom sequences, including repeated pitches, retain their labels. Unknown tuning information is not labeled Standard. Arbitrary tuning spellings do not necessarily provide enough octave information for accurate synthesized pitches.
- Tab Maker and tuner/transcription tools. Transcription and notation-to-tab arrangement still explicitly target guitar. Maker documents and device-specific presentation/preferences remain local unless explicitly described otherwise.

### Tutor and Practice (added 2026-09-25)

Both features listen through the device microphone only (no MIDI input), work fully offline (no network calls, LLM, or downloaded models), and mute all app audio while listening; timing cues are visual (count-in, beat pulse, cursor). Grading checks sounding pitch, not string or fret. A detection the listener cannot decide is graded `uncertain` and shown as a neutral "not sure", never as a wrong note, and is excluded from accuracy.

- **Tutor** (graduation-cap **Tutor** button in the library toolbar beside Tuner; `AppPage.tutor`): acoustic guitar and piano courses, each a recommended path of stages 0–8 with optional side branches suggested after a named lesson. Every lesson is open: learners can start any lesson or use **Mark as done (skip)** in the lesson detail (undo: **Mark as not done**). Skipping records completion without an attempt and does not seed review cards. **Continue** points to the first main-path lesson that is not done.
  - Guitar: 56 main-path lessons and 4 branches (Rhythm reading, Fingerstyle basics, Songs you know, Blues shuffle; 12 lessons).
  - Piano: 45 main-path lessons and 2 branches (Reading the grand staff, Pedal basics; 7 lessons).
  - `tutor-glossary.json` has 253 terms.
  - Lessons mix explain, demo (synth playback with diagram highlighting; demos authored without a diagram show chord names in the playback strip plus an automatic fretboard diagram (guitar open fingering) or keyboard diagram for the current chord), mic-graded practice, quiz (tap, or answer by playing for note/interval/chord-quality questions), and song steps (public-domain or original excerpts, Wait or Play-along). Mic-graded steps offer "Skip for now" when the microphone is off.
  - Chord-change drills pass on an absolute clean-changes-per-minute goal that rises by stage: guitar 8/min through stage 3, 10 at stage 4, 12 at 5, 14 at 6–7, and 16 from 8. Piano uses the previous stage's goal.
  - Completing a lesson seeds spaced-repetition review cards (simplified FSRS). Reviews are self-graded facts, auto-graded multiple choice, or mic-graded play cards.
  - Other sections: Songs you know (library scores whose chord symbols use chords from completed lessons, read from stored canonical MusicXML `<harmony>` and from local text tabs, up to 300 files under 512 KB each, with no iCloud downloads; Guitar Pro chord names are not read), Games, Glossary, Calibration, and Tutor settings (instrument, daily goal, per-instrument progress reset).
- **Games**: Fretboard Hunt (guitar), Key Hunt (piano), Chord Change Sprint, Interval Duel, Name That Quality, Rhythm Tapper, Scale Runner, Note Rush. Games keep personal bests only, with no streaks. Chord Change Sprint (60 s) cites a starting point of about 8 (guitar) / 10 (piano) clean changes a minute and 30 (guitar) / 40 (piano) per game as a solid goal, matching the lesson goals. Ear games and tap fallbacks work without the microphone.
- **Calibration**: covers mic permission, input level with placement advice (iPad on a stand is the assumed setup), an instrument check (open low E / middle C with cents), and latency calibration. Latency is measured with 8 clicks, or 8 silent visual pulses as a fallback. It is saved per audio route and shared by lessons, games, and library practice. The default is 0.08 s until calibrated.
- **Library Practice** (`waveform.and.mic` tool in both transports): covers the open score with practice chrome. You choose a measure range, speed (25–150%, quick 50–100%), and instrument.
  - **Wait**: the cursor advances when the current target is heard; → skips it.
  - **Play-along**: the cursor moves at the chosen speed after a visual one-bar count-in (two bars when a bar is shorter than 2 s).
  - Live feedback turns heard notes green and never red. Native drawn tabs show the range drawn with an overlay; Guitar Pro, PDF, and MIDI sources show an event strip over the visible page.
  - After a take of at least 3 s, the recording is analyzed on device (live verifier results plus post-take DSP transcription, alignment, local tempo), saved, and shown in a review sheet. The review has a note lanes view, timing lane, tempo ribbon (tap to loop), accuracy/timing MAD/weakest measures, suggestions that set the loop and speed in the viewer, take playback with a cursor, and a per-measure history heatmap across takes.
  - A take in which nothing could be graded shows "couldn't hear this take clearly", is not scored, and stays out of the history heatmap.
  - Leaving practice mid-take discards takes shorter than 3 s. Longer takes are analyzed, saved, and offered for review the next time practice opens for that score.
  - Route changes and audio interruptions stop the take with an explanation.
  - The review is a large sheet on every size class (page-sized on iOS 18+). Neither practice nor the review resets the viewer or counts another play.
  - In compact width the Practice tool sits on the transport's second row.
  - **Library writes**: a suggestion's loop is stored in the file's loop measures (drawn tabs) or the Guitar Pro loop, and its speed in the viewer's BPM. If practice changes the speed on a drawn tab that has no stored reference tempo, the player's current reference is saved as `FileItem.referenceBPM` so the percentage stays true. Practice makes no other library metadata writes.
- **Practice availability**:
  - Available for text/drawn tabs, and PDFs with a created guitar arrangement, whose `MeasureMap` has systems and resolved open-string octaves.
  - Available for Guitar Pro once loaded (selected track exported from alphaTab).
  - Available for any score with a sibling MIDI file of the same name.
  - Otherwise the tool explains why it is unavailable: a tuning without octave information, or a PDF without structure.
  - Guitar-family parts (guitar, bass, ukulele, mandolin, banjo) practice as guitar. A part uses the bass listening profile when it is a bass track, the lowest open string is below D2, or the file lists bass and no other guitar-family instrument.

## Portable score metadata

Score details writes title, artist, composer, arranger, collection, arrangement, instruments, tuning, source name/URL/ID, and copyright inside supported library files. Deferred preparation reads these fields without requiring a sidecar. Catalog rescans (including Use Existing Folder) skip embedded content reads to avoid blocking on file providers; text and Guitar Pro readers also extract metadata when opened. User edits take precedence over inference. Personal tags, favorites, recents, loops, and practice settings remain library data and use the existing sync/backup flow.

- UTF-8 text: a readable `[TabBuddy Metadata v1]` header; the original body remains byte-identical. Values needing whitespace/newlines use JSON string escaping.
- GP3–5: native descriptive fields plus a marked notes header for extra fields. Existing unedited native blocks and the entire musical suffix remain byte-identical. Long notes fields use `> ` continuation lines. Native edited fields still have the format's 255-byte limit.
- PDF: standard document title plus a versioned `TabBuddyMetadata:v1:` keyword containing base64-encoded JSON **inside the PDF**. Existing author/subject/other keywords remain intact. PDFKit drops arbitrary custom document attributes, so this implementation does not claim XMP support. Protected PDFs reject writes; tests cover page text and annotations.
- GPX/newer `.gp`: native metadata is read by the player; score-details edits remain library-only until an archive-preserving writer is implemented. The UI states this limitation.

Writes coordinate access to the actual source, verify the result, and replace atomically. Missing sources cannot be edited through an offline fallback. Successful edits refresh offline copies. Catalog reconciliation explicitly saves every 100 entries before reporting progress and checks cancellation between batches, including when using an external iCloud folder in place. Discovery streams path records into durable 100-file catalog batches before enumeration finishes. Full rename/missing reconciliation runs afterward; only a completed full pass can mark unseen records missing. Preparation follows the catalog pass only when automatic preparation is enabled. Cancelled passes retain processed entries without marking unprocessed files missing or recording a successful scan. Embedded indexing skips cloud placeholders and files over 20 MB. Raw downloaded research originals remain untouched; enrichment applies only to separate import-ready copies.

## Storage and sync contract

### One library sync choice

**Sync library with iCloud** controls song storage and CloudKit metadata mirroring together on this device. The metadata includes tags, favorites, recency, play counts, score credits/instruments/source details, and file properties stored in `FileItem`. Metadata backups use version 2; version 1 backups remain readable. Restoring metadata targets the currently selected library, preserving inactive catalogs.

- First run offers sync when iCloud Drive is available. Otherwise Get Started creates an app-managed local library.
- Local-only setup does not enable metadata mirroring merely because an Apple account exists.
- Enabling sync copies and verifies song files into the app's iCloud library, then enables metadata mirroring.
- Disabling sync copies and verifies the songs locally, then reopens the metadata stores without CloudKit mirroring. Existing cloud files and cloud records are retained. Disabling sync on one device does not disable other devices.
- The app uses the same persistent-store URLs when changing the connection. It saves changes, waits for library database work, removes the old UI/model container, and rebuilds the connection. Navigation returns to the library; no user-managed app restart is required.
- Failed file migration leaves the sync preference unchanged. Conflicting destination files are reported instead of overwritten.
- Temporary account or iCloud availability changes do not overwrite the user's sync preference. Cached data remains local, and an unavailable existing cloud library is not silently replaced by an empty one.

### Offline access is separate

**Keep available offline** creates additional verified song copies in Application Support, outside iCloud's evictable document storage. It leaves library sync enabled. Downloads refresh after successful library scans/imports and metadata edits while the preference is enabled; Refresh Downloads can retry a failed download.

A cached song can open when its cloud file is unavailable. Partial download failures retain completed copies and report the error. Disabling offline access removes only the extra cache, not the actual library. The cache is excluded from device backup because its source files remain in the library.

### Advanced storage

Advanced offers **Use Existing Folder**, which adopts the exact selected directory, scans scores in place, and reuses its library marker when present. It does not copy songs or create a child directory. The previous library and catalog remain intact. **Copy Library to New Folder** is a separate operation that creates a Tab Buddy Library child folder and copies/verifies current songs. **Reconnect Folder** renews authorization for the current library identity. TabBuddy's library sync is disabled when switching to custom storage; the folder's own provider may synchronize it independently. Imports still copy into that folder. Existing-folder authorization uses a device-local security-scoped bookmark.

Switching storage retains the previous file copies. There is no automatic cloud purge or destructive conflict resolution.

### Tutor data (local only)

Tutor and Practice data live in a separate SwiftData container at `Application Support/Tutor/tutor.store` (configuration `tutor`, `cloudKitDatabase: .none`). The library `cloud`/`local` stores and `FileItem` are not opened or modified by it, and it is not part of library sync or metadata backup. If the file store cannot open, the tutor falls back to an in-memory store for that session.

| Model | Contents |
|---|---|
| `LessonProgressRecord` | Lesson status, best score, attempts per lesson and instrument. Game personal bests use ids `game.<id>.<instrument>`, with `.level<n>` above level 1 (Chord Change Sprint: `.<chord-pair>` for a non-default pair). |
| `ReviewCardRecord` | Spaced-repetition cards per instrument. |
| `PracticeTakeRecord` | `scoreKey` = `FileItem.id` UUID string, title, measures, BPM, accuracy, timing MAD, `analysisJSON` (a `TakeAnalysis` plus the passage and take settings), optional audio file name. |
| `CalibrationRecord` | Latency seconds per route key, e.g. `out=Speaker;in=MicrophoneBuiltIn`. |
| `TutorSettingsRecord` | Current instrument, daily goal (5–60 min). |

- Takes record to a mono Float32 `.caf` in the temporary `TutorTakes` folder. Saved takes move to `Application Support/Tutor/Takes/` (excluded from device backup) and are re-encoded to AAC `.m4a` in the background; the original is kept if encoding fails.
- Audio pruning keeps the 10 newest takes per score, and at most 200 files / 500 MB overall (oldest first). Pruning removes audio only; take records and analyses stay. Takes shorter than 3 s, or stopped during the count-in, are discarded.
- Calibration goes through `TutorLatency.store()`: the tutor store, mirrored to `UserDefaults` keys `tutor.latency.<routeKey>`. Route keys describe the listening route (`.playAndRecord`, speaker default, A2DP not HFP). The input is predicted when the session is not recording, so the key is the same before and during listening. Keys containing `in=none`/`out=none` are ignored.
- **Tutor settings → Reset progress** deletes lesson progress (including game bests) and review cards for one instrument. Settings, calibration, and library practice takes are kept. Deleting a take from the review removes its record and audio.

## Implementation map

| Concern | Main code |
|---|---|
| SwiftData configuration and live connection reload | `TabBuddy/TabBuddyApp.swift` (`LibraryPersistence`) |
| Device-local sync intent | `LibrarySyncPreference` in `TabBuddy/LibraryModels.swift` |
| Library setup, catalog reconciliation, migration, offline progress | `TabBuddy/LibraryManager.swift` |
| Coordinated file access, iCloud discovery, verified copying, offline cache | `TabBuddy/LibraryFileService.swift` |
| First-run and storage controls | `TabBuddy/FileBrowserView.swift`, `TabBuddy/LibraryStorageSettings.swift`, `TabBuddy/LibraryBrowserIndex.swift` |
| Shared player controls and scrolling | `TabBuddy/Player/TabTransportBar.swift`, `PracticeNavigation.swift` |
| Guitar Pro native/web adapter | `TabBuddy/GuitarProView.swift`, `TabBuddy/GuitarProAssets/player.js` |
| External-source links and editable score details | `TabBuddy/ScoreDiscoveryView.swift` |
| Parsing, tuning names, native drawing | `TabBuddy/TabParser.swift`, `Maker/ComposedNote.swift`, `Player/TabRenderModel.swift` |
| Tutor shared types (`ExpectedEvent`, `TakeAnalysis`, …) | `TabBuddy/Tutor/Shared/TutorContracts.swift` |
| Theory core (pitch, interval, scale, chord, key, rhythm, fretboard/keyboard) | `TabBuddy/Tutor/Theory/` |
| Mic input, mute, take clock, route keys, calibration, detectors, synth | `TabBuddy/Tutor/Listening/` (`TutorAudioSession`, `TutorListener`, `ExpectedNoteVerifier`, `PolyphonicTranscriber`, `LatencyCalibrator`, `InstrumentProfile`, `TutorSynth`) |
| Expected passages, alignment, tempo, take analysis | `TabBuddy/Tutor/Assessment/` |
| Tutor SwiftData store and take audio | `TabBuddy/Tutor/Store/` |
| Curriculum loading/validation, generators, SRS, path progress, song suggestions | `TabBuddy/Tutor/Curriculum/`, content in `TabBuddy/Tutor/Content/tutor-*.json` |
| Tutor shell, lesson player, diagrams | `TabBuddy/Tutor/UI/Shell`, `UI/Lesson`, `UI/Diagrams`, `UI/Common` |
| Games | `TabBuddy/Tutor/Games/` (registry in `UI/Shell/TutorGameRegistry.swift`) |
| Library practice mode and take review | `TabBuddy/Tutor/Practice/`; viewer integration in `TabViewerView.swift` (`practiceStatus`, `openPractice`), `Player/TabTransportBar.swift` (`PracticeToolButton`), `GuitarProView.swift` + `GuitarProAssets/player.js` (`exportNotes`) |
| App audio mute while listening | `.tutorListeningWillStart` observers in `MetronomeEngine`, `NotePlaybackEngine`, `PlaybackCoordinator`, `GuitarProPlayer`; `TutorAudioSession.outputMuted` guards |

`TabBuddy/Tutor` and `TabBuddyTests/Tutor` are Xcode file-system-synchronized groups for the app and test targets. New files there need no `project.pbxproj` edits. The bundle is flat, so content files use unique `tutor-` names.

The SwiftData `cloud` store contains `FileItem` and `LibraryDescriptor`; the name describes its historical role, not whether it is currently syncing. The `local` store contains derived tag indexes, Maker documents, authorization mounts, reachability, and migration jobs. Store names and schemas must remain migration-compatible.

Production identifiers are `com.gamicarts.TabBuddy`, `iCloud.com.gamicarts.TabBuddy.library`, and `group.com.gamicarts.TabBuddy.shared`. Keep app, extension, entitlements, and runtime constants aligned. Do not invent replacement identifiers to work around provisioning errors.

## Moving from the older development app

The earlier `net.hweeks.tabbuddy` build and registered `com.gamicarts.TabBuddy` build are separate iOS apps with separate sandboxes and iCloud containers. Installing the registered app does not migrate the development app’s library or metadata. Keep the old app installed, import its source folder into the new library, then export/restore metadata using the existing JSON backup flow. Cross-app bookmark permissions are not transferable. This is separate from same-app SwiftData schema migration.

Folder imports retain the picker’s security-scoped access through completion, coordinate enumeration with file providers, and surface errors or no-supported-files results. Enumeration displays Finding files before reporting an actual file count. Path comparisons resolve filesystem aliases and compare whole components; equivalent provider paths are accepted, while symlinks that escape the library remain rejected.

## Large libraries

Rescans show an indeterminate discovery bar and running found count, then determinate progress with checked/new/existing counts. New means added to the catalog, not copied. Completion/cancellation leaves a dismissible summary. Discovery count updates and catalog commits are batched every 100 supported files. The UI distinguishes found from saved-to-catalog counts. Scan/import/conversion/preparation status is pinned in a bottom overlay that does not change the grid layout. Rescans run with a progress/Cancel row while the library remains browsable and scores can open. Starting a rescan cancels and awaits preparation before enumeration, then resumes unfinished preparation after the scan only if automatic preparation is enabled. The status panel displays only the active phase; the handoff reads Pausing preparation, and old scan summaries do not stack with active work. Folder enumeration runs on a utility task, releasing the file-service actor; catalog reconciliation yields between batches. Untouched provisional discovery records can be merged back into original records during rename matching, retaining original identity and metadata; provisional user edits prevent this merge. Imports, deletions, and embedded metadata saves first cancel and await an active scan to avoid conflicting catalog updates.

Settings → Prepare Library starts a resumable preparation pass for catalog entries whose background-processing version is stale. Opening or returning starts it only when Prepare library automatically is enabled; this saved preference defaults off. Preparation reads embedded metadata for TXT/PDF/GP3–5 and generates canonical tab data for TXT up to 2 MB, sequentially on utility tasks with database checkpoints every 100 files. It never automatically creates guitar arrangements from PDFs; GPX/newer GP native track metadata/rendering remains on-open. Files larger than 20 MB skip embedded indexing. Cloud-only or failing files remain pending for a later preparation pass; this does not intentionally hydrate the whole cloud library. A preparation version is saved even for text with no convertible notes so it is not repeatedly attempted until changed or the converter version advances. Pause is available, leaving completed work saved. App inactivity and database reload stop the pass; imports/deletions/metadata edits stop and await it first. Storage changes require pausing preparation. This is foreground background work, not an iOS BGProcessingTask or a guarantee of work while the app is suspended.

Opening or returning to the app uses the saved catalog without a timed full rescan or automatic offline refresh. It still checks storage/account availability and imports pending shared files. Setup/adopting a folder scans once; explicit imports reconcile their new files. Use Rescan Library to discover files added, renamed, or removed outside TabBuddy, and Refresh Downloads to refresh offline copies.

Catalog scans publish availability once per reconciliation rather than once per file. Bulk removal fetches presence records once, saves in 250-item groups, and rebuilds tags once, with progress and deletion-error reporting. External-folder removal clears catalog entries only; managed-library removal still deletes the selected underlying song files. Actual iCloud downloads and file deletion can take longer than catalog operations.

Preparation progress distinguishes prepared files, known cloud placeholders waiting for download, and read failures; failures show the latest filename and reason. Only the status panel observes progress, refreshed at most four times per second during preparation plus batch checkpoints; a dismissible summary retains unresolved results. Available file contents use coordinated content reads; cloud placeholders are checked before opening and remain pending. No bulk download is started by preparation.

Large-library responsiveness: scan and preparation counters are observed by their status subviews, not the library filter/sort view. Preparation fetches lightweight pending identifiers and processes at most 100 models at a time; text inference and conversion run on utility workers, with bounded catalog commits and time for UI work between batches. Discovery uses one path index and inserts new entries incrementally, without rebuilding the full catalog/tag index per discovery batch. Full reconciliation skips unchanged file-field writes. Folder mode is still catalog-backed; direct one-folder filesystem browsing is a proposed follow-up, not implemented.

Library sorting/search use a cached value index, with displayed-title sort keys prepared once per catalog snapshot. Filtering and sorting run on a cancellable worker; typing is debounced by 120 ms, while pickers start immediately. Catalog snapshots are refreshed in yielding chunks after saves or query membership changes, coalescing overlapping refresh requests. Returning from a score reuses the completed query. The grid renders 200 matches initially and adds more as the user scrolls; counts and Select All cover every match. Folder membership, instrument choices, and the recent rail reuse cached results. Startup no longer maintains a second filename-sorted library query or opens files to derive folder labels.

PDF opening displays file-access and coordinated-read errors with Retry instead of an empty viewer or a generic iCloud explanation. Known iCloud placeholders can reach the coordinated reader to download on demand; genuinely missing paths still fail. Opportunistic fingerprints wait two seconds before reading on a utility worker and skip known cloud-only files. Text tabs use a single cancellable worker parse; canonical encoding/writes are asynchronous and preserve user-edited tuning. PDF reads are cancelled on exit, retain their bytes for lazy page rendering, and skip the background-detection thumbnail in light mode.

## Validation and known limits

Local discovery-source acquisition is documented in `Tools/TAB_CORPUS.md`. `Tools/collect_tabs.py` supports resumable anonymous collection from GameTabs and GProTab.net into the git-ignored `.local-tab-corpus/` directory. This is separate research tooling, not the in-app source-link search or a commercially cleared catalog. ClassTab is excluded from this collection pass. `Tools/prepare_tab_library.py` builds a separate checksum-verified import-ready collection with readable game/artist and song filenames, retaining version distinctions and provenance; `--watch` includes newly downloaded files incrementally.

- General MusicXML/MuseScore/LilyPond import and full native piano engraving are not implemented. The native staff preview is a simplified melody aid. Piano PDFs support original reading/smooth scrolling; precise measure following requires a structured supported file such as Guitar Pro. OpenScore repository files must be exported to PDF first. Source access and PDF purchase options may change; inspect the source before buying.
- Run the `TabBuddyTests` suite using the TabBuddy Xcode scheme. The suite covers parsing/golden fixtures, rendering, imports, migration integrity, sync configuration, metadata persistence across connection reload, and offline copies.
- Unsigned simulator tests explicitly disable real CloudKit mirroring. Temporary test roots simulate file migration and offline availability; they do not prove live iCloud synchronization.
- Signed device builds with the registered identifiers and iCloud entitlements have succeeded. Live two-device sync, in-flight CloudKit behavior during connection changes, account changes, and production CloudKit schema deployment still require device validation.
- Re-enabling sync after independently editing copies can encounter destination conflicts. The current policy is to report the conflict and retain both locations, not silently choose a winner.
- Tutor/Practice tests (`TabBuddyTests/Tutor`) cover:
  - the theory core
  - curriculum decoding, plus the content validator run on every bundled JSON file
  - generators, SRS math, and path progress (open path, skip/undo)
  - the detectors on synthetic audio (Karplus–Strong strings, additive inharmonic piano, room noise, silence)
  - alignment and tempo on synthetic timelines
  - store CRUD and take-audio pruning
  - route-key prediction and the shared latency store
  - practice and game state machines, driven through fakes

  `LessonUISnapshotTests` and `PracticeSnapshotTests` render PNGs only when `TEST_RUNNER_TUTOR_SNAPSHOT_DIR` / `TEST_RUNNER_PRACTICE_SNAPSHOT_DIR` is set. They are layout aids, not assertions, and skip in a normal run.
- **Not verified:**
  - real microphone accuracy on an acoustic guitar, piano, or bass, including iPad placement at music-stand distance
  - device latency and the calibration procedure on hardware
  - Bluetooth/USB routes
  - learning quality of the curriculum and games

  Detector thresholds were tuned on synthetic audio only, so synthetic hit rates are not real-world accuracy. The recorded fixture corpus and `.diag/authbench.swift --verifier` benchmark in the plan do not exist yet. Post-take transcription is an offline DSP harmonic-sum transcriber, not a Core ML model; Basic Pitch is not bundled. The tutor store is local, so it does not change live iCloud behavior. That is by construction, not something a two-device test has confirmed.
- The committed Guitar Pro fixtures are original guitar and two-staff piano exercises. Downloaded GProTab arrangements are ignored local test inputs and must not be added to the repository or app. Bundled third-party assets retain their licenses and notices.

## Developer launch arguments (DEBUG builds only)

| Argument | Effect |
|---|---|
| `-TutorOpen` | Open the Tutor on launch. |
| `-TutorInstrument guitar\|piano` | Tutor instrument (also selects a game's instrument). |
| `-TutorSeedProgress <n>` | Mark the first n main-path lessons complete and make their cards due. |
| `-TutorSection path\|reviews\|songs\|games\|glossary\|calibration\|settings\|review-session` | Open a tutor section. |
| `-TutorCalibration` | Open the tutor on Calibration. |
| `-TutorReviewKind <ReviewKind>` | Show due cards of that kind first. |
| `-TutorLessonDemo <lessonID>` / `-TutorLessonStep <n>` | Open a lesson, optionally at a 0-based step. |
| `-TutorDiagramGallery` (+ `-TutorGalleryPiano`) | Every diagram kind. |
| `-TutorGame <id>` / `-TutorGamePhase play\|results\|countdown\|mic-off` | Open a game; a phase uses fake silent audio and an in-memory score store. |
| `-TutorForceWidth <pt>` | Lay debug lesson/game screens out in a fixed-width column (Split View/compact check). |

Game ids: `fretboard-hunt`, `key-hunt`, `chord-change-sprint`, `interval-duel`, `name-that-quality`, `rhythm-tapper`, `scale-runner`, `note-rush`. `PracticeDemoData` (DEBUG) supplies a scripted take for previews and snapshot tests; there is no launch argument for practice mode.

## Documentation maintenance

For each behavior change, update the relevant feature and storage contracts here, revise user-facing instructions in README when needed, and add a dated progress entry with actual validation results and remaining limitations. Keep proposed behavior clearly separate from implemented behavior. Do not mark live service behavior verified based only on simulated tests or a signed build.

Player display menus omit the read-only Tuning & capo section; it offered no adjustment. Score details still supports descriptive tuning metadata, and score-defined tuning/capo continue to govern notation and playback.

Original/TabBuddy switching retains the reader surfaces for the currently open score, preserving scroll positions and avoiding repeated PDF loads or text-view creation. Switching pauses playback and scrolling, hides the inactive surface from touch/accessibility, and defers the preference save out of the gesture. Render models and canonical presentation are prepared off-main and reused; per-note layout uses one resolved string count/tuning per score. These caches last only for the open viewer session.

Reader opening, closing, and mode changes coalesce context saves after a 500 ms delay; pending saves survive viewer dismissal and flush when the app becomes inactive. Saves of reader-only preferences leave the library query cache valid. Recency, play counts, and searchable metadata edits refresh the affected snapshot rows; membership/instrument changes and unrecognized save notifications still request full reconciliation. Native audio engines, player nodes, reverb, formats, and click samples are allocated only when audio starts. Sibling MIDI lookup/extraction runs on a cancellable worker with its own file-access lease. Unchanged text fonts are not reassigned during control updates, and mode changes do not animate entire score surfaces. Delayed scroll-start callbacks cannot restart a closed reader.
