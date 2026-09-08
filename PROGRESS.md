# TabBuddy — Implementation Progress

Dated log of the canonical-library + card-redesign work. Architecture and
rationale live in `PROJECT.md` and `DESIGN.md`; this file records dated changes, where
it lives, and what's next. Newest first.

---

## 2026-09-07 — Readable downloaded-file collection

- Added a resumable organizer that copies raw corpus files into import-ready source/game-or-artist folders with readable game/artist - song names. Colliding arrangement names receive version numbers; raw downloads and queues remain unchanged.
- Initial pass prepared 27,224 files (8,536 GameTabs, 18,688 GProTab), including 2,103 version-disambiguated arrangements, with zero errors. All copied contents matched catalog SHA-256 checksums; all manifest paths existed after the pass. Two offline tests cover source title extraction, safe Unicode/path names, collision handling, content preservation, and idempotent reruns.
- Started a local incremental organizer process that checks for new downloads every minute. Output, logs, manifest, and PID are under the ignored `.local-tab-corpus/import-ready/` directory. This does not publish third-party content.

## 2026-09-07 — Large-library scan and removal performance

- Removed per-item full tag-index rebuilds, database saves, and presence-table fetches from Remove All and selection deletion. Bulk operations use one presence lookup, 250-item save groups, and one final tag rebuild. Added progress and failure reporting; retained external-file preservation and managed-file deletion behavior.
- Reconciliation accumulates availability privately and publishes once, preventing thousands of whole-library state notifications during setup/scan.
- All 20 storage tests passed and the signed device build succeeded. The initial installation connection reset; retry succeeded and the update is installed on Hunter’s iPad.
- The 5,000-score in-memory simulator benchmark took 1.93 seconds for catalog reconciliation and 0.94 seconds for bulk catalog removal. This does not measure iCloud enumeration, network transfer, or device database performance. Regression coverage checks bounded UI publications, retained inactive-library metadata/tags, and external file preservation.

## 2026-09-06 — Direct existing-folder selection

- Separated Use Existing Folder from Copy Library to New Folder in Advanced storage. Existing-folder adoption scans the exact selected root, retains previous catalogs/files, and reuses markers without creating a child folder. Reconnect remains a separate authorization action for the active identity.
- Metadata restore from the library UI now targets only the active library; matching paths in inactive catalogs remain unchanged.
- 24 targeted storage and metadata tests passed, including populated-folder adoption, no new subdirectory, repeat selection, preservation of the prior catalog, and targeted backup restore. Signed iOS build succeeded and the update was installed on Hunter’s iPad. Actual iCloud shared-folder selection requires the user's device picker grant.

## 2026-09-06 — iPad path-alias follow-up

- The on-device retry surfaced `invalidRelativePath`. Reproduced this class of failure with a picker folder alias and an enumerated real path. Replaced literal string-prefix comparisons with resolved path-component comparisons across relative-path and containment checks.
- Added regression coverage for aliases in both directions and a symlink that escapes the library, including a not-yet-created destination. All 19 targeted storage/import tests pass; signed build succeeded and was installed on the iPad. Actual source-folder success remains subject to the on-device retry.

## 2026-09-06 — iPad folder import diagnosis

- Confirmed the iPad has both `net.hweeks.tabbuddy` and `com.gamicarts.TabBuddy` installed. The legacy app retains its folder bookmark; the registered app selected a separate managed iCloud library. This is a cross-app migration gap, not evidence that existing files were deleted.
- Fixed hidden folder-import errors, picker permission lifetime, uncoordinated provider enumeration, swallowed enumeration failures, and misleading initial 0-of-1 progress. Empty folders now explain that no supported files were found.
- 18 targeted storage/import tests passed, including nested imports, duplicate paths, and empty/missing source errors. Signed build succeeded; installed and launched the updated registered app on Hunter’s iPad. Real iCloud folder import still needs an on-device retry with this build.

## 2026-09-06 — Instruments, original notation, and source discovery

- Removed fixed six-string row/voice assumptions from native parsing, layout, canonical conversion, Maker rendering, and playback. Added bass, ukulele, and extended guitar presets. Unknown custom pitches remain visible without fabricated MIDI notes. PDF extraction accepts string-count/header evidence and retains original-source fallback.
- Added multiple-instrument metadata, editable credits/arrangement/source details, instrument filtering, metadata-aware search, and version-2 backups with version-1 compatibility. Explicit user edits take precedence over extraction.
- Guitar Pro defaults to source notation, including piano staff notation, with per-score display preferences. PDF-to-guitar conversion is explicit. Deferred native audio graph/sample creation until audio is requested, so reading does not initialize audio output.
- Added Find music with eight source entries, instrument-aware web searches, access/format descriptions, and a return to the existing importer. This is the first source-search layer, not an aggregated catalog or automatic download adapter. No remote catalog was deployed.
- Added an original two-staff piano Guitar Pro fixture. Inspected test screenshots for source search, score details, piano notation, and shared controls.
- Validation: 75 tests passed on iOS 26.2 simulator, excluding three Guitar Pro playback tests after repeated simulator AURemoteIO RPC crashes (WebKit GPU on playback; native metronome initialization before the deferred-setup fix). Rendering and scrolling now pass. Playback/audio still require another simulator/device check. Both original Guitar Pro fixtures parse and generate MIDI using the bundled alphaTab runtime. Signed generic-iOS build succeeded with existing registered identifiers and entitlements. This does not verify live iCloud sync.
- Remaining scope: general MusicXML/MuseScore import, full native piano engraving, and cross-source result aggregation. Piano PDFs have original reading/smooth scrolling, not automatically detected precise measure following.

## 2026-09-06 — Local discovery-source corpus

- Added a resumable collector for GameTabs public text and GProTab.net public downloads, with source metadata, hashes, preserved pages, robots rules, rate limits, and bounded retries. Excluded ClassTab and existing-library inventory at the user's request.
- Downloaded material and acquisition state remain outside app resources and are ignored by git. Protected GameTabs attachments are recorded as requiring login.
- Added `Tools/TAB_CORPUS.md` with operation instructions and preliminary rehosting constraints. No commercial redistribution permissions have been obtained and no cloud assets have been published.
- Validation: four offline collector tests passed; five initial downloaded GP4/GP5/GPX files loaded and generated playback data using the bundled alphaTab runtime. The GameTabs pilot extracted three public song texts. Both full collectors were started as resumable background processes; acquisition is not yet complete. The initial GameTabs sitemap exposed 8,539 song pages and 1,649 game pages.

## 2026-09-05 — Unified library sync and offline access

- One device-local sync preference now controls iCloud song storage and CloudKit metadata mirroring. Local-only setup starts without metadata sync. Existing managed-library choices are adopted on upgrade.
- Changing the preference saves and reloads the same SwiftData stores, rebuilding the library UI. Cloud files and records remain intact when sync is disabled.
- Added an offline-copy cache, download progress, retry, and cached-file access without turning sync off. Turning off offline access removes only cached copies.
- Added tests for sync configuration, metadata retention across connection reload, and offline-cache access/update/removal. Live two-device iCloud behavior remains a device-validation requirement.
- Added `PROJECT.md` as the current product/architecture guide and `AGENTS.md` documentation-maintenance instructions. Updated README and design guidance to remove the former split-sync ambiguity.
- Final review fixed custom-folder authorization without a prior device mount. Validation: all 71 unit tests passed, including 16 storage architecture checks; the signed iOS device build succeeded. Live two-device sync was not tested.

## 2026-09-05 — Guitar Pro, shared practice controls, and managed storage

- Added offline Guitar Pro 3–8 support with bundled alphaTab, native transport/Settings, track selection, and practice loops. Downloaded arrangements remain local-only test inputs.
- Unified Smooth scroll and Follow measures controls across native and Guitar Pro players. Synthesized sound is secondary. Fixed tuning normalization, repeated pitches, and flat-note spellings.
- Added app-managed local/iCloud storage setup, verified migration, Advanced custom folders, and iCloud metadata discovery. Registered app and extension signing succeeded.
- Review fixed partial-import reconciliation, identical-song relinking, failed folder setup, and duplicate processing of shared imports.
- Validation at commit `ae9d331`: all 67 unit tests passed, followed by 22 targeted regression checks. Live two-device synchronization was not tested.

## 2026-06-27 — Native drawn Tab Player (Guitar sheet music app density2)

Replaced the monospaced `UITextView` + overlay rendering for text tabs with a
structured, **drawn** tab player built from the `MeasureMap`, per the
`density2` design handoff. PDFs keep their PDFKit fallback; the generator is
unchanged (no converter-version bump).

New files under `TabBuddy/Player/`:
- **`TabRenderModel.swift`** — pure value model + builder: `MeasureMap` →
  systems → measures → note columns (frets high-E-first, `RhythmDuration`),
  plus playhead-fraction and active-column geometry. Unit-tested
  (`TabRenderModelTests`, 4 cases).
- **`DrawnTabSystemView.swift`** — SwiftUI `Canvas` drawing one system:
  measure-number gutter + section/loop-A-B flags, rhythm-letter row, optional
  5-line standard staff (clef + noteheads/stems/flags by melody pitch), the
  6-string tab staff with barlines and knockout fret numbers, the accent
  playhead (with focus-mode glow), the inverted active-note pill, and the A/B
  loop band. Light + dark `TabPalette`s. Tap-to-seek via `SpatialTapGesture`.
- **`TabPlayerView.swift`** — host: a `ScrollViewReader` stack of systems with
  **follow / line-by-line auto-scroll**, the full transport (skip, big
  play/pause, `m. x / N` + time/loop readout, measure scrubber, tempo pill,
  metronome, count-in, **A/B loop**, auto-scroll cycle, display, focus), a
  **Display** popover (notation Tab-only/Tab+staff, rhythm letters, size A±,
  auto-scroll mode, tuning/capo), a **tempo / speed-trainer** popover (BPM
  slider + 50/75/90/100% presets + "ramp +5% each loop"), and a dark
  **focus mode** (`fullScreenCover`). View prefs persist via `@AppStorage`.

Plumbing:
- `PlaybackCoordinator` gained an `onLoopCompleted` callback (drives the speed
  trainer's per-pass tempo ramp).
- `FileItem` gained `loopStartMeasure` / `loopEndMeasure` (additive-optional;
  measure-based A/B loop persistence for the drawn player).
- `TabViewerView` now routes non-PDF parseable tabs to `TabPlayerView`
  (its own transport replaces the legacy playback bar), adds a Tuning · Capo ·
  Key · TimeSig subtitle, and hides the redundant scroll-speed slider.

Verified: app + tests build clean, 38 tests green, launches on simulator
(SwiftData migration for the new loop fields is clean).

## 2026-06-27 — Generator refinement v4 (titles / phantom measures / tuplets / playback)

Converter version bumped 3→4 (re-derives on open).

- **Title heuristic, much stricter** (`isLikelyTitle`): rejects URLs, credit lines
  ("Tabbed from…"), timestamps, over-long sentences, and PDF music-font garbage
  ("Υ ∀∀"). Directive check is now **anchored** so a title containing "Time"/"Key"
  ("Ocarina of Time - Song of Storms") is no longer mistaken for a directive.
- **Title resolution** (adapter): **PDFs always use the filename** (their text
  layer is unreliable); when the **filename already contains** the in-file title
  it wins (e.g. "Zelda Wind Waker - Outset Island" ⊇ "Outset Island"); otherwise
  the fuller in-file title wins ("World of Warcraft: Taverns of Azeroth").
- **Over-segmentation / phantom measures**: drop measures that are empty AND <4
  columns (edge artifacts from "-|"/"|-" decorations). Corpus empty-measure rate
  8.7% → 3.3%, tiny 6.5% → 0.9% (~15.5k phantoms removed). Confirmed the "runaway"
  files (Satie 405, Bach 839) are **legitimate** — they concatenate 6 transcriber
  versions, not a bug.
- **Tuplet brackets** ("|--3--|  |--3--|") drawn above the staff are no longer
  parsed as their own tiny measures (`isTupletBracketLine`). Windmill Hut: 10
  systems/29 measures → 9/25.
- **playback** audibly improved as a side effect — the parser now feeds real
  per-note durations (rhythm letters + beat rulers) and time signatures into the
  `MeasureMap` the `PlaybackCoordinator` plays, instead of uniform synthesized
  beats.

Tests: +6 in `ForewordCapoRhythmFreeTimeTests.swift` (34 total green).

---

## 2026-06-27 — Generator refinement v3 (full foreword / beat ruler / search / play-gate)

Converter version bumped 2→3 (re-derives on open).

- **Full verbatim foreword** — `comments` now preserves the *whole* human header
  (subtitle, "Tabbed and Arranged by:", "Playing Instructions:", and directive
  lines like Tempo/Capo/Tuning/Rhythm), only dropping musical lines/separators.
  Section labels ("Intro:", "[Verse]") now end the foreword (no leak). "Rhythm:/
  Rhytm:/metrum" time signatures recognized. (Display deferred per user — capture
  only for now.)
- **Numeric beat-ruler durations** — `"1 2 3"` rulers (classtab/Satie style) now
  drive per-note durations via proportional column spacing scaled to the measure
  beat count, snapped to standard note values. `isNumericRulerLine` +
  `proportionalRhythm` path in `extractNotes`.
- **Searchable forewords** — `FileItem.foreword` (composer + comments)
  denormalized by `CanonicalConverter`; library search now matches `derivedTitle`
  + `foreword` in addition to filename/tags/folder.
- **play-count dwell gate** — `playCount` no longer increments on quick opens;
  `TabViewerView` counts a play only after the tab stays open ~3s (cancelled on
  early dismiss). `FileBrowserView.open()` now only updates `lastOpenedAt`.

**Corpus impact (whole library, v2 → v3):** rhythm-authored 16.3% → **52.4%**;
metered files 11.5% → **20.8%**; notes-with-duration 15.9% → **27.8%**; time
signatures 73.3% → **73.4%** (incl. "Rhythm:" forms). Title still 98.5%.

Files: `TabBuddy/TabParser.swift`, `TabBuddy/Canonical/CanonicalTab.swift`,
`TabBuddy/Canonical/CanonicalConverter.swift`, `TabBuddy/FileItem.swift`,
`TabBuddy/FileBrowserView.swift`, `TabBuddy/TabViewerView.swift`.
Tests: +3 in `ForewordCapoRhythmFreeTimeTests.swift` (28 total green).

**Still deferred:** over-segmentation (Satie → 405 measures vs ~78; hurts beat-
ruler coverage on long pieces); section/loop model; foreword *display* (next
chunk — the Tab Player); articulations.

---

## 2026-06-27 — Generator refinement v2 (foreword / capo / rhythm / free-time)

Data-driven against the real iCloud library (4096 `.txt`). Bumped
`CanonicalConverterVersion` 1→2 so existing canonicals re-derive on open.

- **Foreword capture** (`TabParser.parseMetadata`): in-file title, composer
  ("Composed by:" / "by …"), and prose comments, bounded to the header block
  above the first tab system; excludes section headers, rhythm/ruler lines,
  separators. New `TabMetadata`/`MeasureMap` fields; flowed to
  `CanonicalTab.title/artist/comments`.
- **Capo** → `capoOffsets` + applied to **sounding pitch** (`canonicalNotes`
  adds `string + capo + fret`); physical fret fingering preserved.
- **Authored rhythm**: `Provenance.rhythmSource = .authored` when a real rhythm
  line drove ≥50% of notes (was hardcoded `.synthesized`); `asciiTab` renders a
  duration row (W/H/Q/E/S via `RhythmDuration.nearest/notation`) — byte-identical
  early-return when not authored (protects the diff surface).
- **Free-time**: detect unmetered tabs (no time sig / rhythm / internal bars);
  even-spaced positions + uniform 1.0 durations; `Provenance.isFreeTime` flag.
- **"Timing:" time signatures** now detected (classtab uses "Timing:" widely).
- **Data-integrity fix**: new `Provenance.isFreeTime` added via a custom
  `init(from:)` using `decodeIfPresent` — the call sites decode with a swallowing
  `try?`, so a required key would have silently wiped provenance on every
  existing canonical. (Caught by the design workflow + test #14.)

**Corpus impact (whole library, before → after):** Latin-1 read failures
306 → **0**; title captured **98.7%**; time signatures 66.8% → **73.3%**;
rhythm-authored **666 files**; free-time correctly isolated to **52 files**.
On the two example files: Comet now captures title/Koji Kondo/Capo 2/6/4 +
renders durations; accf is correctly free-time.

Files: `TabBuddy/MeasureMap.swift`, `TabBuddy/TabParser.swift`,
`TabBuddy/Canonical/CanonicalTab.swift`, `TabBuddy/Canonical/CanonicalAdapters.swift`.
Tests: `TabBuddyTests/ForewordCapoRhythmFreeTimeTests.swift` (13 new; 25 total green).

**Deferred:** numeric beat-ruler (`1 2 3`) duration inference (~356 classtab
files, currently 0 durations — biggest remaining capture gap); section/loop
model; over-segmentation (39 files at 400–839 measures); articulations.

---

## 2026-06-27 — Card Library redesign (Screen 1) + swappable viewer

### Card Library (design handoff "Screen 1")
- **`TabBuddy/FileCardView.swift`** (new) — card unit per the design tokens:
  12pt radius, 0.5pt hairline border, soft shadow, 11×13 padding; favorite star;
  title (16pt semibold, extension stripped, 2-line); meta row (tuning pill —
  muted "Standard" vs indigo alt; relative last-opened; `▸ playCount`; PDF badge);
  neutral `#tag` pills (Treatment A) capped at 2 + overflow; folder eyebrow.
  Tap = open (or toggle-select in edit mode); context menu for
  open/favorite/tags/rename/delete.
- **`TabBuddy/FileBrowserView.swift`** — replaced the `List`/`FileRowView` layout
  with a `LazyVGrid` card grid (adaptive min 206pt) + a **"Jump back in"** rail
  (tabs opened in last 7 days, root only). Preserved: folders (now folder cards),
  `.searchable`, `TagHeader` tag filter, toolbar, import plumbing, and
  multi-select (re-implemented as tap-to-select with check badges, since grids
  lack `List` selection).
- `FileRowView.swift` is now unused by the browser but left in place.

### Swappable viewer
- **`TabBuddy/TabViewerView.swift`** — ⋯ menu gains a **View** picker
  (Original ↔ TabBuddy), enabled only when the file has a canonical. "TabBuddy"
  mode decodes the stored MusicXML → `CanonicalAdapters.asciiTab` and renders it
  (read-only; gives PDFs an interactive text view). Sticky via
  `@AppStorage("viewer.renderMode")`.

### Supporting
- **`TabBuddy/FileItem.swift`** — added `derivedTitle: String?`, `tuning: String?`
  (denormalized from the canonical for fast card display) + `displayTitle` /
  `isAltTuning` helpers. Additive-optional → lightweight migration.
- **`CanonicalConverter`** now stamps `derivedTitle`/`tuning` onto the FileItem
  whenever it produces a canonical (batch, convert-on-open, single).

### Deferred (rest of the design package)
Collections `@Model` + membership (two-layer source/organization); split-view
sidebar (folders/tags/smart groups); canonical import-review sheet; drag-to-
organize edit mode; group-by sections; color-coded tag treatment (C).

---

## 2026-06-27 — Phase 2: convert + provenance + migration safety

### Schema + migration (verified non-destructive on the real device library)
- **`TabBuddy/FileItem.swift`** — added `canonicalFilename: String?`,
  `provenanceData: Data?`, `canonicalVersion: Int = 0` + `hasCanonical` /
  `provenance` accessors. Additive-optional = SwiftData lightweight migration;
  existing metadata (tags/favorites/BPM/loops/play counts) untouched.
- **`TabBuddy/Canonical/LibraryMigration.swift`** (new) — on first launch after
  the upgrade, writes a full JSON metadata snapshot to `Documents/Backups/`
  (reuses `BackupManager.exportJSON`) as a safety net. Keyed by a
  `UserDefaults` schema-version flag; runs once; skips empty libraries.
  Hooked in `ContentView.onAppear`.

### Conversion pipeline
- **`TabBuddy/Canonical/CanonicalStore.swift`** (new) — local `.musicxml`
  storage in Application Support (`<id>.musicxml`). Phase 3 relocates this to the
  iCloud container.
- **`TabBuddy/Canonical/CanonicalConverter.swift`** (new) — reads original
  (`.txt`, or text-extractable `.pdf` via PDFKit) → `TabParser` →
  `CanonicalTab` → MusicXML → store; records provenance/confidence/version.
  - `convertLibrary` — concurrent batch backfill, idempotent (skips
    missing/stale only), published progress.
  - `convertOnOpen` — JIT on file open; text tabs reuse the viewer's existing
    parse (near-zero cost), PDFs run off-main; version-aware auto-upgrade.
  - `convert` — single-item.
- **`FileBrowserView`** — ⋯ → **Generate Tab Data** action, progress overlay,
  and auto-backfill after import completes.
- **`TabViewerView`** — convert-on-open hooks (text in `parseTextTab`, PDF in
  `onAppear`).

### Tests
- **`TabBuddyTests/CanonicalMigrationTests.swift`** (new) — metadata preserved
  under new schema; provenance accessor round-trip; `CanonicalStore` I/O.

---

## 2026-06-27 — Phase 1: MusicXML bridge core

- **`TabBuddy/Canonical/CanonicalTab.swift`** (new) — `Codable` canonical model
  (headers, tuning, per-string capo offsets, time/key/tempo, measures of
  string+fret+pitch+duration notes) + `Provenance` (sourceType / confidence /
  converterVersion / rhythmSource / clipped) + `CanonicalConverterVersion`.
- **`TabBuddy/Canonical/MusicXMLCodec.swift`** (new) — encode/decode tab-flavored
  `score-partwise` MusicXML. Musical data → real elements (`staff-tuning`,
  `technical/string`+`fret`, pitch, duration); TabBuddy-private data
  (provenance, capo, tuning name) → `miscellaneous-field`. Note positions are
  reconstructed from rhythm on decode. JSON keys sorted → **byte-stable** output
  (diff/sync-friendly).
- **`TabBuddy/Canonical/CanonicalAdapters.swift`** (new) — `MeasureMap →
  CanonicalTab` (import), `CanonicalTab → MeasureMap` (playback via
  `MeasureMapBuilder`), `CanonicalTab ↔ ComposedTab` (Maker correction),
  `CanonicalTab → ASCII` (diff/render).
- **`TabBuddyTests/CanonicalBridgeTests.swift`** (new) — round-trip field
  preservation, byte-idempotent re-encode, XML shape, high-E-first tuning/string
  mapping, chord reconstruction, full text→canonical→MusicXML pipeline.

---

## Also in this stream
- **Sort/view/filter persistence** — `FileBrowserView` `sortMode` / `browseMode`
  / `filterFavorite` / `activeTagFilter` moved from `@State` to `@AppStorage`
  (persist across launches). `folderPath` intentionally stays ephemeral.
- **`DESIGN.md`** — full architecture/vision spec (canonical inversion, two edit
  classes, lenses, confidence-gated display, iCloud storage model, v2 arranger).

## Test / build status
- 10 unit tests passing (7 bridge + 3 migration).
- Builds clean (`xcodebuild … CODE_SIGNING_ALLOWED=NO`).
- Deployed + launched on device (iPad Pro 11" M4) — schema migrations verified
  against the real library.
- **Nothing committed yet** — all changes are in the working tree.

## Menu cleanup (2026-06-27)
- Deleted dead `FileRowView.swift` (card grid replaced it; carried a defunct
  `revealInFinder`).
- Viewer overflow: removed the greyed "TabBuddy view unavailable" row (the
  Original/TabBuddy picker now appears only when a canonical exists); removed the
  redundant "Close" (nav back button covers it).
- Library overflow: moved "Compose Tab" + "Live Transcribe" into the **Add (+)**
  menu so the overflow is purely library management.

## Known follow-ups / notes
- Test target deploys to iOS 16.4 while the app needs 17.0 → tests run with
  `IPHONEOS_DEPLOYMENT_TARGET=17.0`. Consider bumping the test target setting.
- TabBuddy canonical viewer is read-only (no playback-highlight remapping yet).
- Next candidates: full confidence-gated `TabStaffView` rendering; Phase 3 iCloud
  (needs container enabled in Apple Developer account); Collections + sidebar.

## 2026-09-07 — Embedded descriptive metadata

Implemented a shared embedded-metadata codec and Score details write-back for UTF-8 text, PDF, and GP3–5. Added portable title/artist/source ID/copyright fields, import/rescan indexing, backup coverage, and precedence over inferred metadata. Writes coordinate the real library source and cannot modify an offline fallback; successful edits refresh offline downloads. Personal tags/history/practice data remain in the library. GPX/newer `.gp` edits remain library-only and are labeled accordingly.

Text bodies and GP musical suffixes are retained byte-for-byte; original native GP metadata blocks are retained when unedited. Escaped multiline values and continued long notes fields round-trip. PDFs use standard title plus an embedded versioned keyword payload because PDFKit discards arbitrary custom attributes; author, subject, other keywords, text, and annotations are retained in tested fixtures. This is not XMP support.

The organizer now enriches separate import copies using the app's same codec, records raw/output hashes, and protects user-modified copies during upgrades. As of this pass: 8,536 GameTabs and 19,311 GProTab files processed; one GProTab header (`homesick-4`) rejected, leaving its existing/raw copies intact. Organizer resumed for ongoing downloads. Some source formats are copied unchanged; manifests are internal provenance, not required sidecars for app import.

Validation: 83 selected simulator tests passed (three known audio/WebKit playback tests excluded); after final escaping/continuation changes, all 8 canonical/metadata tests passed again. Six Python tooling tests passed, with the organizer's two tests rerun after adding user-edit preservation coverage. Ninety real GP3/4/5 original/enriched pairs produced identical track counts, bar counts, and generated MIDI events in the bundled alphaTab runtime. Signed device build succeeded and installed on the existing registered iPad app. Live two-device metadata/file synchronization was not tested. No downloaded arrangements added to git.

## 2026-09-07 — Library instrument dropdown

Limited the main library filter to instruments represented in the active library, retaining All instruments and showing Unspecified only when present. Choices use the full active library rather than search/tag/folder results, include every instrument in multi-instrument scores, and update as metadata changes. A stale selection falls back to All instruments and is cleared. Score-details assignment choices remain unrestricted. Updated feature/design documentation. Signed iOS build passed; no new tests added for this small UI-only change.

## 2026-09-07 — Consolidate online discovery

Kept Find music online only under Add (+). Removed the duplicate filter-row action and empty-results Search online button, preserving balanced empty-state spacing. Updated README, project guide, and design intent. Verified one remaining discovery trigger and a successful signed iOS build; no new tests needed for removing duplicate buttons.

## 2026-09-07 — Fix existing-folder scan stall and cancellation

Identified a regression from embedded metadata indexing: complete catalog reconciliation synchronously awaited a coordinated content read for every score, potentially waiting on a provider at 0/N, and did not check cancellation. Complete rescans now skip embedded extraction; explicit import still indexes metadata. Existing text/GP readers continue extraction when opened. Reconciliation reports progress and yields every 100 records, checks cancellation, retains completed entries, and does not mark unprocessed files missing or record scan success after cancellation. Existing conditional fingerprint-based rename matching remains unchanged apart from a cancellation check before each candidate.

Validation: all 23 LibraryArchitectureTests passed, including new tests for interruption after 100 of 4,800 records, retention of unprocessed availability, and no embedded extraction during rescans while explicit imports still extract. The 5,000-record in-memory catalog test completed in 2.03 seconds (not a live iCloud timing). Signed iOS build passed. Updated current feature documentation to remove the earlier claim that rescans extract embedded fields.

## 2026-09-07 — Stop foreground-triggered full scans

Removed the scene-activation rule that rescanned after 60 seconds and otherwise triggered an offline refresh (which also enumerates the full source folder). Opening/returning now uses the saved catalog, checks storage availability, and handles pending shared imports. Setup, explicit imports, manual rescans, and explicit offline refresh remain available. External file changes require Rescan Library; no periodic external-folder watcher is implemented. Also removed the spurious not-configured error on ordinary activation before setup. Updated user/project/design documentation. Signed iOS build passed; inspected remaining browser scan triggers to verify they are explicit user actions. No new tests added for this UI lifecycle trigger removal.

## 2026-09-07 — Non-blocking rescans

Replaced the full-screen scan overlay with an inline status row containing file counts, progress, and Cancel. Browse/search/open remain available. Directory enumeration now runs in a utility task and releases the file-service actor so opening files need not queue behind enumeration; cancellation propagates to the worker and file coordinator. Reconciliation continues yielding every 100 records. Imports, removal, and embedded metadata saves cancel/await an active scan before mutation, and a scan cannot start during imports. Automatic foreground scans remain disabled.

Validation: all 23 storage architecture tests passed, including scan cancellation and 5,000-record reconciliation. Signed device build passed with no new Sendable capture warning after isolating the cancellable coordinator in a documented wrapper. Updated README, project guide, and design contract. Live provider responsiveness still depends on the provider's response to individual file operations.

## 2026-09-07 — Consolidated Settings sheet

Moved Library Storage, Export Backup, Restore Backup, Remove All Files, Generate Tab Data, and Rescan Library out of the main dropdown into the Settings sheet. The dropdown now contains Select and Settings. Storage/offline controls remain in the sheet alongside maintenance and metadata backup sections. Actions that need another presentation are dispatched after Settings dismisses; destructive removal retains the existing confirmation. Online discovery remains only under Add (+). The preceding menu-lag investigation was cancelled at the user's request; no performance fix is claimed here.

Validation: signed iOS build succeeded and all 23 existing library architecture tests passed. Updated README, project guide, and design intent.

## 2026-09-07 — Detailed rescan progress

Added a visible indeterminate bar (with Reduce Motion support) and batched supported-file discovery counts while the total is unknown. Reconciliation shows determinate progress, checked count, new catalog additions, and existing entries. Completed/cancelled scans retain a dismissible summary. Counts describe catalog changes, not file copies or downloads. Enumeration callbacks are guarded by scan generation so delayed updates cannot affect another scan.

Validation: signed iOS build passed; all 23 architecture tests passed with added assertions for 5,000 new entries, zero additions on a repeated scan, and 100 retained additions after cancellation. Updated README, project guide, and design documentation.

## 2026-09-07 — Fast catalog imports and resumable preparation

Split imports into copy/catalog and deferred processing. The first copy is catalogued immediately, then batches of 100; completion/cancellation/failure flush any remainder through an independent catalog commit. Imports no longer parse metadata while copying or committing. The background worker reads locally available metadata and prepares native TXT canonical data afterward. It saves completed processing versions, checkpoints every 100 prepared files, and skips completed work on subsequent library openings. Text parsing runs on a utility task using already-read input; PDFs are not automatically converted into guitar arrangements. Pending cloud-only/read-failing files are deferred. Background work pauses on app inactivity and database reload, and resumes on library opening/return; this does not request iOS execution while suspended.

Moved scan/import/manual-generation/preparation status to a compact bottom overlay without changing the library grid layout. Import and generation progress no longer use blocking screen covers. Pause is available for preparation; mutation paths stop/await it and Settings can pause it before changing storage. Manual full generation waits for the preparation worker to stop.

Validation: 33 storage/canonical tests passed after introducing deferred processing. Two interrupted-import tests were then rerun with real six-string text content and passed, verifying immediate catalog availability, retained partial batches, deferred metadata, generated canonical data, persisted processing versions, and no repeated work when already current. Signed device build succeeded. Updated README, PROJECT, and DESIGN with foreground-only execution, supported-format/size limits, and fixed-position progress. The preceding intermediate implementation that parsed copied metadata inline was superseded before deployment of this feature.

Final validation for this pass: all 87 selected non-playback tests passed (three previously documented simulator audio/WebKit tests excluded). Final signed build also includes a foreground-eligibility guard so a completing scan cannot restart preparation after app inactivity. Installed the consolidated update on the iPad.

## 2026-09-07 — External iCloud library checkpoint clarification

The user's active workflow is Use Existing Folder on an external iCloud directory, not copying an import into managed storage. Found that rescan reconciliation yielded/reported every 100 entries but only saved at the end/cancellation. It now explicitly saves each checkpoint before advancing progress. Folder enumeration still completes first, followed by in-place catalog reconciliation and deferred local-content processing. No external song copies or moves occur. Catalog checkpoint failures now stop with an error instead of reporting cancellation/success.

Validation: all 25 storage architecture tests passed. The cancellation test now reads through a separate ModelContext at the 100-file boundary to verify durability before stopping. The 5,000-record simulated scan took 1.76 seconds; this is not an iCloud enumeration timing. Signed device build passed. Updated README, PROJECT, and DESIGN.

## 2026-09-07 — Sequential status handoff and folder removal

Rescan now awaits the cancelled preparation task before enumerating or reconciling. The bottom panel presents a single active operation, labels the transition Pausing preparation, and hides retained summaries while another operation is active. Unfinished preparation resumes after scanning.

Folder cards support selecting all descendant songs, partial/whole selection indicators, and removal through their context menu. Select All includes nested folder contents. External-library confirmation explicitly removes references only and warns that extant source files return on rescan. Managed removal deletes selected score files, not arbitrary filesystem directory contents. Membership is indexed in one pass per rendered section to avoid per-folder full-library scans.

Single-file catalog removal now uses the guarded batch-removal path. Explicit underlying-file deletion also waits for scans/preparation. Pending mutations suppress automatic worker restart during a cancelled scan's completion, and stale conversion/fingerprint results check model validity before applying. These address plausible deletion races; no crash report was retrieved, so the user's reported crash is not independently diagnosed.

Validation: all 26 storage tests passed, including a new nested-folder reference removal test that preserves external files and similarly named sibling folders while stopping preparation. Interrupted-import tests also verify scan/preparation handoff and subsequent resumption. Signed device build passed. Updated README, PROJECT, and DESIGN.

## 2026-09-07 — Editable instrument/tuning chips

Tiles omit unknown instrument labels, including unknown entries in mixed instrument arrays. Known instruments and tuning use restrained tag-style chips and open Score details on tap. Score details now supports tuning presets, custom text, and clearing; saves use the existing embedded-metadata/library-only format policy. Raw and normalized tuning values participate in library search. These remain structured descriptive fields, and tuning changes do not modify notes or retune tracks. Updated README, PROJECT, and DESIGN. Signed iOS build passed; no new tests added for this small presentation/editor change.

## 2026-09-07 — Persist external-folder discovery before completion

Fixed the remaining gap in the external iCloud root rescan workflow: previously Finding files could count tens of thousands of paths while none had reached catalog reconciliation. Discovery now streams 100-record batches to independent durable catalog commits during enumeration, with a final partial batch. UI distinguishes found paths from saved catalog entries and new references. A closed/cancelled scan retains committed folders without copying source files. Directory enumeration errors stop the scan rather than allowing a partial manifest to mark unseen songs missing.

Full rename/missing reconciliation follows complete discovery. Untouched provisional path records can merge back into their original identity, preserving tags/favorites; provisional user edits prevent merging. Cancelled/incomplete manifests never mark unprocessed entries missing. Remote iCloud-query additions also arrive in catalog batches once the query returns.

Validation: all 27 library architecture tests passed. A new disk-backed test cancels during discovery and reopens the store, verifying 100 saved New Folder references survive while all 250 source files remain intact. The rename test was then rerun against provisional discovery records and passed with original identity/tags/favorite retained. Signed build passed. These tests use local external-folder fixtures, not a live reproduction of the user's 22k-file iCloud session. Updated current documentation; previous enumeration-before-save descriptions are superseded.

## 2026-09-07 — Preparation progress and file-provider reads

Corrected embedded-content reads to use content coordination instead of metadata-only coordination. Cloud placeholders can reach the availability check even when fileExists is false. Preparation publishes every outcome, separates read failures from awaiting-download counts, preserves the latest failure in a dismissible summary, and reports save errors. Added regression assertions for successful preparation and a missing file remaining retryable rather than being mislabeled cloud-only. Validation: all 27 LibraryArchitectureTests passed; signed device build succeeded. Live external-iCloud behavior still requires device verification.

## 2026-09-07 — Opt-in preparation and responsive scan updates

Automatic bulk preparation now defaults off and is a persisted setting; Settings offers Prepare Library. Progress observation is isolated from the library screen. Preparation uses pending identifiers, batches of at most 100, utility-thread text inference/conversion, and bounded model commits; completed batches survive pause. Startup availability is published once. Discovery no longer fetches/reconciles the entire catalog or rebuilds tag indexes per 100-file batch; it inserts unknown paths using one scan index. Final reconciliation avoids unchanged file writes. Added tests for 10,000 progress updates causing no manager notifications, preference persistence, and 250-file batch pause/resume. Direct folder enumeration remains a follow-up. Validation: 29 LibraryArchitectureTests passed, including 10,000 progress notifications isolated from the library and 250-file preparation pause/resume; signed iPad build passed. Live 10k+ iCloud UI responsiveness has not been measured.

## 2026-09-07 — Cached asynchronous library queries and navigation

Replaced repeated live-model filtering/sorting with value snapshots and cancellable worker queries. Filename keys are normalized once; folder groups, library instruments, and recents are cached. Snapshot refreshes yield every 100 rows and coalesce saves without starving under continuous imports. Grid exposure grows in 200-result increments; selection retains all matching rows. Reuse completed results when returning from a score. Removed the navigation container’s redundant sorted FileItem query, guarded bootstrap against repeated appearances, and derive folder labels from stored relative paths rather than acquiring every source file. Validation: 32 LibraryArchitectureTests passed, including query semantics, cancellation, edit/deletion refresh, stale-result rejection, and a synthetic 28,000-row query (~43 ms on the simulator worker, not an iPad UI latency measurement).

## 2026-09-07 — PDF opening diagnostics and file access

Viewer acquisition accepts known cloud placeholders so PDF coordination can hydrate them. File-access failures now render an error and Retry for PDFs; reader coordination errors are preserved. Acquisition is cancelled on exit and late leases are closed. Moved opportunistic fingerprint I/O off the inherited main actor and skip known placeholders. PDF representable replaces its document when input changes. Added an external-folder PDF opening/missing-source regression. Validation: all 33 LibraryArchitectureTests passed, including an actual one-page PDF opened through an adopted external folder and a missing-source error. Live iPad failure cause is not confirmed.

## 2026-09-07 — Pre-production performance/UI/code review

Extracted LibraryBrowserIndex into its own source file. Fixed a same-revision async search race when returning to a cached query; sort by display title and index normalized tuning labels. Added loading-state copy and correct external-folder download guidance. PDF loading now uses a cancellable task, retains document bytes for lazy rendering, and only samples page background in dark mode. Fingerprinting waits two seconds before optional I/O. Text tabs now parse once on a cancellable worker; canonical conversion/encoding/writes also run off-main, preserve edited tuning, and reject deleted-model writes. Late text-read callbacks cannot update a closed viewer. Tightened actor annotations/captures in persistence and conversion. Validation: broad suite 95 unit tests and 6 existing UI/launch tests passed; three known unreliable/local-corpus Guitar Pro playback tests excluded. Final 34 focused library tests and 6 tooling tests passed; final signed Release archive succeeded at /tmp/TabBuddy-release-review.xcarchive. No production upload or version change. Live 28k-library latency and two-device CloudKit behavior remain device checks.

## 2026-09-07 — Remove non-adjustable tuning/capo menu section

Removed the read-only Tuning & capo sections from native and Guitar Pro player display menus at user request. Descriptive metadata editing and score-defined playback pitches remain supported. Signed device build passed after the menu removal.
