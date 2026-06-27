# TabBuddy — Canonical Library Architecture

This document is the design spec for TabBuddy's evolution from a viewer of
imported tab files into a system built around a **Tab Buddy-generated canonical
representation** of each tab, stored in a **Tab Buddy-controlled iCloud app
container** so a user's library follows them device-to-device.

It captures the full multi-phase vision. Only a subset is built at any given
time; see **Build phases** for status.

---

## 1. Motivation

Today TabBuddy stores each imported tab as a security-scoped **bookmark** to the
user's own `.txt`/`.pdf`, with metadata (tags, favorites, BPM, loops, play
counts) in a **local-only SwiftData store**. Two consequences:

1. **Nothing follows the user across devices.** Bookmarks are device-local;
   the SwiftData store is device-local. A 250 MB / ~5k-file library can't be
   carried in full.
2. **The view is inert.** PDFs render via PDFKit (no playback, highlight, or
   transform). Text tabs parse to a lossy `MeasureMap` used only for the
   playback-highlight overlay — the displayed content is still the raw original.

## 2. Core idea

Convert every imported tab into a **canonical** form — Tab Buddy-generated
**MusicXML** — that captures as much of the tab as the source allows: headers,
tuning/capo, tempo, time/key signature, and notes (string + fret + pitch +
duration). Then:

- **Drive a standardized TabBuddy display and playback from the canonical**, so
  every tab — regardless of whether it came from text, a PDF, or (later) a scan —
  becomes a first-class interactive tab.
- **Keep the original as a reference**, used for *diff* (canonical vs. source)
  and *correction*, not as the thing rendered.
- **Sync the small canonical + metadata** (kilobytes/file) via the iCloud app
  container. **Leave the heavy originals out of sync** — they become evictable
  and re-downloadable on demand.

The canonical is **best-effort and versioned**: faithful on what the source
encoded, inferred on what it didn't, and re-derivable as converters improve.

## 3. Layered data model

Each library entry has three layers:

| Layer | What | Lives where | Syncs? |
|---|---|---|---|
| **Original** | the imported `.txt`/`.pdf` | bookmark ref (as today); later evictable | no (heavy) |
| **Canonical** | generated `.musicxml` | iCloud container `canonical/<id>.musicxml` | yes (tiny) |
| **Metadata + provenance** | tags, favorites, BPM, loops, play counts, source/confidence/version | `library.json` manifest (+ SwiftData cache) | yes (tiny) |

**Identity is device-independent:** primary key `libraryPath` (relative path in
the library root), fallback `contentHash` (`FileItem.fingerprint`). The bookmark
is *not* identity — it's a device-local convenience for reaching the original.

### Provenance (per canonical)
- `sourceType`: `txtDirect` | `pdfText` | `ocr` (later) | `composed`
- `confidence`: 0–1 quality estimate of the conversion
- `converterVersion`: integer; lets us re-derive/upgrade canonicals in place
- `rhythmSource`: `synthesized` | `midiAligned` | `authored`
- `clipped`: bool — source appeared cut off (e.g. PDF page truncation)

## 4. In-memory types & the bridge

`CanonicalTab` (Codable value type) is the in-memory mirror of the MusicXML
document and the hub every path converges on:

```
                         ┌──────────────► MusicXML file (canonical, source of truth)
TabParser (.txt/.pdf) ─┐ │
PDFKit text extract  ──┼─► MeasureMap ─► CanonicalTab ─┼─► TabStaffView (standardized display)
(later) OCR          ──┘                               ├─► MeasureMap ─► PlaybackCoordinator
                          ComposedTab ◄────────────────┤    (existing playback engine)
                          (Maker edit) ────────────────┘
                                                        └─► ASCII (text diff vs original)
```

Existing reused building blocks:
- `TabParser.parse(_:) -> MeasureMap` (`TabBuddy/TabParser.swift`)
- `MeasureMap`/`MeasureSystem`/`Measure`/`NoteEvent` (`TabBuddy/MeasureMap.swift`)
- `ComposedTab`/`ComposedNote`/`GuitarTuning` (`TabBuddy/Maker/`) — editor model
- `StaffPitchMapper` (pitch↔staff step+accidental)
- `FretSuggestionEngine.suggest/allPositions` (pitch→string/fret)
- `MeasureMapBuilder.build(...)` (`[ComposedNote] -> MeasureMap`)
- `Maker/TabStaffView` (renders tab from notes + tuning — the standardized view)

**Why a file, not a SwiftData model:** since the iCloud container is the source
of truth, the `.musicxml` file *is* the canonical. SwiftData becomes a hydrated
cache/index. This also keeps imported canonicals out of the Maker's "my
compositions" `@Query` list. `ComposedTab` stays the editor's working format;
adapters convert `CanonicalTab <-> ComposedTab` for correction.

### Conversion fidelity (honest ceiling)
| Characteristic | MusicXML home | Fidelity |
|---|---|---|
| Headers (title/artist/comments) | `work-title`, `credit`, `words` | strong |
| Tuning / capo | `staff-tuning` (+ private per-string capo) | strong |
| Tempo, time/key sig | `sound tempo`, `metronome`, `time`, `key` | strong |
| Notes: string + fret | `technical/string` + `fret` | strong (lossless) |
| **Rhythm / durations** | `duration`, `type` | **synthesized** unless a paired `.mid` aligns it |
| Articulations (bend/HO/PO/slide) | `hammer-on`, `bend`, … | partial |
| Clipped-off content | — | unrecoverable |

MIDI is a **derived/auxiliary** format (timing source via `MIDITempoExtractor`,
ground-truth in the `Tools/` ML pipeline), **not** a canonical container — it
encodes pitch, not string+fret, and can't represent tab articulations.
MusicXML is the open interchange container because it has native `string`/`fret`.

## 5. Two classes of edit (keep separate)

- **Corrections** — "the converter misread this." These **mutate the canonical**
  (via Maker → `ComposedTab` → re-emit MusicXML). They are the diff target and
  raise fidelity. Layered on top of an immutable original so the diff anchor is
  preserved.
- **Lenses / transforms** — "the canonical is right; show it differently."
  **Ephemeral, non-destructive** reinterpretations at view time; never written
  back into the canonical. Examples:
  - *Remove a (possibly partial) capo*: add capo offset to fretted strings,
    holding sounding pitch constant — `new_fret = fret + capoOffset[string]`.
  - *"Too lazy to tune up"*: source assumes a string raised by k semitones; play
    it at standard and add k to that string's frets.

  Both are one operation: a per-string pitch-offset reconfiguration that
  re-solves fret numbers while **sounding pitch stays invariant** (audio,
  metronome, highlight untouched). Pure function
  `applyLens(CanonicalTab, LensConfig) -> (notes, tuningMIDI)` feeding the
  existing `TabStaffView`. Offer *literal* (shift on same string) vs *re-voiced*
  (`FretSuggestionEngine` re-picks for playability); clamp/flag out-of-range
  frets. Default ephemeral; opt-in "remember this view for this tab" as a saved
  preset that is explicitly **not** part of the canonical.

## 6. Confidence-gated display

The display inversion is **not** a hard cutover:
- High-confidence canonical → render the standardized `TabStaffView` + playback.
- Low-confidence / clipped → keep rendering the **original** (current PDFKit/text
  path) as fallback; canonical still available for playback-only / correction.
- User corrections **promote** a file from fallback → canonical over time.

The existing extension-branch in `TabViewerView` is retained as this fallback
path, gated by `provenance.confidence`.

## 7. iCloud app-container storage

Library data + canonical live in a **Tab Buddy-controlled iCloud app container**
(CloudDocuments ubiquity container), not CloudKit. Layout:

```
<ubiquity-container>/Documents/
  library.json              # manifest = portable source of truth for metadata
  canonical/<FileItem.id>.musicxml
  previews/<id>.png         # optional: cheap thumbnail for original-absent devices
```

- **Manifest is the source of truth**; local SwiftData is a hydrated cache.
  - On launch / iCloud change → read manifest, reconcile into SwiftData (key by
    `id`/`libraryPath`/`contentHash`).
  - On user edit → write SwiftData + debounced manifest write → iCloud
    propagates → other devices reconcile.
- **Conflict resolution** reuses the field-level last-writer-wins merge already
  in `BackupManager.importJSON` (`lastOpenedAt` = max, etc.); per-`.musicxml`
  conflicts = last-writer-wins (or keep-both).
- Access via `NSFileCoordinator`/`NSFilePresenter`.
- **Canonical-present / original-absent** is the *normal* state on secondary
  devices: the viewer must render + play from `.musicxml` alone, and re-link an
  original later via `libraryPath`/`contentHash` if one appears locally.
- Originals stay where they are (bookmark), evictable; on-demand re-download is a
  later enhancement.

**External prerequisite:** iCloud capability + container
`iCloud.com.gamicarts.TabBuddy` must be enabled in the Apple Developer account
and provisioning profile (entitlements file change alone is insufficient).

## 8. On-the-go import (later)

"Someone hands me a tab" → slurp it in on device:
- Text / text-extractable PDF → fully on-device today (`TabParser` / PDFKit).
- Scanned/raster PDF or **photo** → on-device **Vision OCR** of fret digits +
  staff-line geometry → reconstructed ASCII → `TabParser` → canonical. New work;
  tablature is geometrically regular (6 staff lines, printed digits), far more
  tractable than general OMR.
- Needs a Share Sheet extension + camera/photo capture entry points (today only
  an in-app `fileImporter` exists; no `onOpenURL`/share target).
- Always keep the original for diff/correction.

## 9. V2 — guide construction of a guitar tab from other-instrument sheet music

Pipeline: `sheet music → note events → arrange/reduce to guitar →
pitch→string/fret → CanonicalTab → tab`. Stage 3 already exists
(`FretSuggestionEngine` + `StaffPitchMapper` + `MeasureMapBuilder`). Split:

- **v2a — digital input** (MusicXML/MIDI sheet music): no OMR; reuses the bridge,
  `FretSuggestionEngine`, and the Maker as the **guided** arrangement/voicing
  surface (piano is more polyphonic/wider than 6 strings + 4 fingers, so
  reduction is human-steered, not fully automatic). Reachable once the bridge
  exists.
- **v2b — image input** (photo/PDF of notation): gated on an on-device OMR
  CoreML model; defer until v2a proves the arrangement UX.

Everything in the current foundation (MusicXML container, `CanonicalTab` hub,
Maker correction surface, `FretSuggestionEngine`) is load-bearing for v2 too —
nothing here is a dead end.

---

## Build phases

See `PROGRESS.md` for the detailed, dated implementation log and file inventory.

- **Phase 0 — this doc.** ✅ Done.
- **Phase 1 — MusicXML bridge core** (pure, testable, no UI/iCloud):
  `CanonicalTab`, `MusicXMLCodec`, `CanonicalAdapters`. ✅ Done (10 unit tests).
- **Phase 2 — on-device convert + provenance + (partial) viewer**: extended
  `FileItem` (canonical ref + provenance + denormalized title/tuning),
  `CanonicalStore`, `CanonicalConverter` (batch + convert-on-open),
  `LibraryMigration` safety net, import wiring, **swappable viewer** (Original ↔
  TabBuddy canonical). ✅ Core done. ⏳ Remaining: full confidence-gated display
  inversion using `TabStaffView`; richer side-by-side diff UI.
- **Phase 3 — iCloud app-container storage**: entitlement/provisioning,
  `LibraryStore`, manifest-as-source-of-truth + SwiftData hydration, migration.
  ⏳ Not started (needs iCloud container enabled in the Apple Developer account).
- **Card Library redesign** (from the design handoff package): ✅ Screen 1 done
  (`FileCardView`, card grid, "Jump back in" rail, tuning/title denormalization).
  ⏳ Deferred: Collections model + split-view sidebar, canonical import-review
  sheet, drag-to-organize, group-by, color-coded tags.

### Out of scope until later (tracked above)
OCR/scan & camera import; full display-inversion rollout; ephemeral lens
transforms; original eviction / on-demand re-download; Share Sheet extension;
v2a/v2b arranger; Collections data model.
