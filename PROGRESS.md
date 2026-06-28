# TabBuddy — Implementation Progress

Dated log of the canonical-library + card-redesign work. Architecture and
rationale live in `DESIGN.md`; this file tracks **what is actually built**, where
it lives, and what's next. Newest first.

---

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
