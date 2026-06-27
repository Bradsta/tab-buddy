# TabBuddy — Implementation Progress

Dated log of the canonical-library + card-redesign work. Architecture and
rationale live in `DESIGN.md`; this file tracks **what is actually built**, where
it lives, and what's next. Newest first.

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
