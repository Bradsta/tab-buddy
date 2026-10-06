# TabBuddy × Gamic Arts — viewer/maker chrome revamp ("Quiet header", direction 1b)

For the current implemented feature and storage contract, see [PROJECT.md](PROJECT.md). Sections below include historical design targets and external reference assets; unchecked items are not claims of completed work.

Implementation spec for the TabBuddy iOS app (SwiftUI). Reference mockups:
`templates/tab-buddy-revamp/TabBuddyRevamp.dc.html` — option **1b** (iPad, 834×1194) and **2a** (iPhone, 390×844).
Design tokens live in the Gamic Arts design-system folder (`tokens/*.css`, entry `styles.css`); hex conversions for Swift are below.

## Library options: Local only, iCloud only, Hybrid (2026-09-25)

Supersedes the single **Sync library with iCloud** switch and the Advanced **Use Existing Folder** entry (see "Library sync and offline access" and "Existing folders and library moves" below, now historical).

- **One list, three options**, each with a one-line description and a checkmark: Local only ("Songs and library info stay on this device."), iCloud only ("Songs in TabBuddy's iCloud library. Library info syncs."), Hybrid ("Songs stay in a folder you choose. Library info syncs."). The same list is the first-run choice, with iCloud only suggested when available. iCloud only is dimmed with "Needs iCloud Drive on this device." when unavailable. The footer defines "library info".
- **Switching never copies.** Each option shows its own location; a short alert confirms the change and names both locations ("Songs aren't copied. The library will show songs in … Songs in … stay where they are."). When the folder stays the same (Local only ↔ Hybrid) the alert says only library info changes. A copy is never a side effect of choosing an option.
- **Current Location** section: Songs and Library info rows, plus Choose/Change Folder for Local only and Hybrid and Use App Folder Instead for a chosen Local only folder. Hybrid's footer says to choose the same folder on each device and that songs missing here are hidden, not deleted.
- **More Storage Options** (collapsed DisclosureGroup below Remove All Files) holds rarely used actions: Keep available offline (only for iCloud-backed folders), Reconnect Folder, and Copy Library to New Folder, the only explicit copy. Maintenance, backup, and Remove All Files stay where they were.
- **Unauthorized Hybrid folder on this device** shows a banner "Choose This Folder on This Device" naming the folder, with a Choose Folder… button, rather than an empty or broken library.
- **Removal wording states the scope**: chosen-folder removal says files stay in the folder; iCloud only and Hybrid say library info is removed on all devices; app-local deletion says files are deleted on this device. Local only on a store that has mirrored adds that removals apply on other devices if syncing is turned back on.
- **First sync on a device**: the switch alert to Hybrid or iCloud only adds **Export a Library Backup First** (exports, then the user switches again) and asks the user not to edit while library info merges.
- **Merge status**: while a duplicate merge runs, the bottom status panel shows a spinner, "Merging library info from your other devices… (n of total)", and "Please don't edit songs until this finishes." Only that subview observes merge progress; the library list refreshes once when the merge ends.
- **A chosen folder offers no file deletion.** Its card menu has only **Remove from Library** (catalog and metadata only; the file stays). **Delete** appears only for the app-managed library folder, and its alert names the relative path.
- **Marker errors** (evicted or conflicting `.tabbuddy-library.json`) appear as the library error text with the recovery step, instead of creating a new library.
- **Reader redirect**: if the open score's record is merged or removed from another device, the reader reopens on the surviving record, or closes with a "Song moved" alert.
- iPad-first sheet; rows and descriptions wrap in compact width. Screenshots checked on the iPad and iPhone simulators (unconfigured and Local only states).

## Tutor and Practice interface (2026-09-25; lessons as a textbook 2026-10-02)

iPad is the primary device; iPhone and narrow Split View/Stage Manager windows must still work in compact width.

- **Shell.** In regular width, a 300 pt sidebar holds the instrument switch, the book's parts (stages), and sections (Contents, Practice, Flashcards, Songs you know, Games, Glossary, Calibration, Tutor settings; ⌘1–⌘8), with a detail pane beside it. The two columns are drawn inside the pushed Tutor page, because a `NavigationSplitView` cannot nest in `ContentView`'s `NavigationStack`. In compact width, one scrolling contents page pushes sections onto the app stack. Chapters and games open full screen; Practice and Flashcards are panes. Chapter details are a popover on iPad and a sheet on iPhone, and list the chapter's sections as jump links.
- **The course reads like a book.** Contents shows stages as parts and lessons as chapters; the hero reads "Next up", never "test". The order is a recommendation, not a gate. **Done means read**: the chapter page and its detail offer **Mark as done** / **Mark as not done**; nothing records attempts, scores, or cards. Side branches stay optional detours.
- **A chapter is one page.** Header, a table of contents card with jump links (regular width) plus a Contents menu in the top bar, then numbered sections with headings: prose first, diagrams and "Hear it" beside the text they illustrate, worked examples as figure cards with the caption underneath ("Example 2."), exercises as **Try it** boxes done at the learner's pace, songs as Try it boxes grouped by measure, and **Check yourself** questions at the end with tap-to-reveal answers. No step gating, no progress bar, no completion screen, no score. The Done toggle lives in the top bar and at the bottom of the page.
- **Try it boxes never grade.** They offer Play example (synth) with loop and tempo, and a Listen switch that only adds green for heard notes: wait mode moves the ring to the next target when the current one is heard (Next skips, the cursor wraps around), play along counts in visually and moves the cursor at the tempo. Misses stay neutral text ("Heard A♯2", "Not sure"); there is no pass, run end, goal, or rotating tip. Tips are a static disclosure. Playing the example pauses the microphone and resumes it.
- **Check yourself and Flashcards reveal, they do not score.** Any tapped choice reveals the correct answer in green and the explanation; the tapped choice is marked "your pick" in neutral gray. Flashcards flip; Got it / Again only reorder the session's deck.
- **Wide layouts put things side by side**, not stretched phone columns. Reading sections put the diagram beside the text. Try it boxes put the stage beside a control panel. Games put options and stats in a side column. The glossary shows list and entry together. The take review uses two columns at ≥ 680 pt in regular width.
- **Honest listening.** An `uncertain` detection is a gray "?" / "not sure" and never counts against the player. Red is used only in the Library Practice post-take review, for a confidently heard wrong pitch and for low-accuracy heatmap cells. Live feedback in chapters, Practice, and takes only adds green (heard) and an accent ring on the current target.
- **Visual timing.** App audio is muted while listening, so the count-in, beat pulse (accented downbeat), and cursor are visual. Demos and ear-training sounds play with listening stopped. Calibration offers silent visual pulses as well as clicks.
- **Chapters step one section at a time** (2026-10-05). Method research (Fender Play 3–5 min lessons, Skoove's Listen/Learn/Play, JustinGuitar module routines) favours short chunks and repeated short practice. So a chapter is overview → one section per page → a timed routine repeated daily, with dots for "you are here" and the whole page one toggle away. Each Try it page shows its controls on screen, without scrolling, on iPad portrait.
- **Practice section: choose on the instrument, not in menus** (2026-10-05). Research (JustinGuitar, Fender Play Chord Challenge, ChordBank, oolimo, RCM/ABRSM charts, Piano Marvel) found no product that leads with dropdowns.
  - Keys come from a circle of fifths on guitar (inner ring for minors on Chords) or a keyboard strip on piano. Scale types are chips. Guitar positions are boxes on a full-neck fretboard. Chords are the key's I–vii° chips.
  - Practice opens filled in from "For you" or from a chapter's "Practice this", so the common case takes one tap.
  - On wide layouts the pickers sit beside or above the stage; the Try it card shows no second fretboard when the neck is on screen.
  - The Tutor sidebar hides itself in Practice on iPad portrait so the instrument gets the width.
  - One Minute Changes is the one Practice item that shows a count. It is the learner's own number against their history, never a pass/fail.
  - Guitar single notes in a Try it strip read as tab (fret over string name), and a long measure wraps inside its box.
- **Practice mode covers the reader** without leaving it. A practice bar takes the header seat, and a practice transport has a large Start/Stop target. Drawn tabs render the practice range natively with an overlay; Guitar Pro, PDF, and MIDI sources keep the page visible with an event strip. The Practice tool lives in the transport tools zone and moves to the second row in compact width.
- **Review as a sheet.** The take review is a large sheet on every size class (page-sized on iOS 18+), so the reader underneath stays mounted: its teardown does not run and no play is counted. A take the detector could not hear says so instead of showing a score.
- **Keyboard.** In a chapter: Space plays/stops the Try it example, L toggles Listen, N skips the current target, ⌘D marks the chapter done, Escape closes. In Library Practice: Space starts/stops a take, → skips the current Wait target. 1–4 (up to 9) answer ear games; 1 / 2 are Again / Got it on a flashcard and Space flips it. ⌘F searches the glossary, ⌘L starts the mic check, ⌘1–⌘8 switch sections.
- **Tap targets** are at least 44 pt, with larger primary actions readable from a music stand.
- **Placement advice** assumes an iPad on a stand 0.5–1.5 m from the instrument. It names where the microphones are and suggests moving the device before asking the player to play louder.
- **Games and goals without pressure.** Games keep personal bests only; there are no streaks, lives, or loss for missed days. The daily goal is described as a guide, not a streak. Games explain what they train and whether they use the microphone, and offer a tap alternative when the microphone is off. Levels keep separate bests so higher levels are compared fairly.
- **Listening stopped mid-game.** A full-screen "Listening stopped" state (mic.slash) explains that the microphone was stopped and the game was not scored. It offers Retry (primary; Space or Return) and Back. On iPad the message sits in a card with the actions in a side column.
- **Microphone denied.** The Listen switch explains how to enable it in Settings. Reading, examples, Play example, Check yourself, flashcards, ear games, and the glossary keep working.

## Large-operation feedback (2026-09-07)

Bulk removal displays processed/total progress, yields between batches, and reports failures. Catalog scanning publishes availability once rather than redrawing the library for every score. Existing external-folder versus managed-file deletion semantics remain distinct.

## Existing folders and library moves (2026-09-06; option entry superseded 2026-09-25)

Advanced separates **Use Existing Folder** (adopt the exact selected directory and scan in place) from **Copy Library to New Folder** (create a named child folder and copy the current library). A generic Choose Folder action must not silently choose between these operations. Switching to another existing collection retains the previous catalog and files; backup restoration targets only the selected collection.

## Implemented multi-instrument decisions (2026-09-06)

- Use one shared library with an instrument filter, not separate global guitar/piano modes. A score can belong to multiple instruments. Recents remain the landing view when no filter is selected.
- Keep format, instrument, and arrangement separate. Show a short instrument badge on a card; edit fuller credits and provenance in Score details. Uncertain detection reads Unspecified. Explicit user edits win.
- Preserve original notation by default. Guitar arrangement generation is a deliberate PDF action. Guitar Pro notation choices are per score and hide tablature options for non-string tracks.
- Keep Find music beside the instrument filter, also reachable from Add and empty search results. Carry the current query/filter into discovery. Source cards explain formats and access; websites handle accounts and purchases, and the existing file importer handles acquisition.
- This is a source-link directory with web search, not an aggregated result list. A combined catalog and automated source adapters are future work. Do not suggest that third-party arrangements are commercially cleared.

## 1. Goal

One chrome for every way you read a tab. Today the top bar and bottom transport differ between
text tabs, PDFs, "Original" renders, and the TabBuddy (canonical) player. After this change:

- **One header** (52pt, translucent) shared by every viewer surface and the Tab Maker.
- **One transport grammar** — three fixed zones: `[play cluster] [position] [tools]`. Only the
  middle zone's meaning changes per surface.
- **The `⋯` ellipsis menu is deleted.** Rename / Edit tags / details move into a menu on the
  title itself (title shows a small caret; tap opens it).
- **Play always means "go":** playback on the canonical player, auto-scroll on original text/PDF.
  Same button, same size, same seat.

Out of scope: library/browser (card grid already shipped), Collections, OCR import, lens/diff
implementation (surfaced in direction 1c; hooks noted in §8).

## 2. Delete list

- `TabViewerView.header` (custom HStack header): favorite star inline, tag chips, loop pill,
  wand quick-toggle, `Menu { … ellipsis.circle }` — all gone, replaced per §4.
- `ScrollTransportBar` as a separate layout — merge into the shared transport (§5).
- `TabMakerToolbar` as a *top* toolbar — the maker's tools move into the bottom transport (§6).

## 3. Tokens → Swift

Add these as asset-catalog colors (light / dark). CSS var names given for cross-reference.

| Asset name | CSS var | Light | Dark |
|---|---|---|---|
| `Paper` (app canvas) | `--paper` | `#FDFBF7` | `#1B1613` |
| `Surface` (cards, bars) | `--surface` | `#FFFFFC` | `#27221E` |
| `SurfaceInset` (wells, inactive tiles) | `--surface-inset` | `#F5F2ED` | `#322D29`* |
| `SurfaceRaised` (sheets, popovers, thumb) | `--surface-raised` | `#FFFFFF` | `#322D29` |
| `Fg1` primary text | `--fg-1` | `#231C18` | warm near-white (see `tokens/dark.css`) |
| `Fg2` secondary | `--fg-2` | `#60564F` | — |
| `Fg3` tertiary/placeholder | `--fg-3` | `#8D827A` | — |
| `Separator` hairlines | `--separator` | `#E2DDD7` | — |
| `SeparatorStrong` (track bg) | `--separator-strong` | `#D1CBC4` | — |
| `Accent` (TabBuddy rose) | `--accent-tabbuddy` | `#DB6868` | `#F07E79` |
| `AccentStrong` (pressed / soft-fill text) | derived | `#C24D4F` | — |
| `AccentSoft` (tinted fills: tempo pill, active-measure highlight) | derived | `#FFE5E4` | — |
| `AccentSofter` (badges, tinted rows) | derived | `#FFF2F1` | — |
| `CautionSoft` / `CautionText` (low-confidence badge) | `--caution-soft` | `#FCEED6` / `#8B5F00` | — |
| `BarTint` (header/transport material) | `--bar-tint` | `#FDFBF7` @ 78% + system blur | dark paper @ 78% |

\* dark values for the full neutral ramp are in `tokens/dark.css`; convert the same way if needed.

**Replace all uses of** `Color.accentColor` (system blue today), `.yellow` favorite stars, and
`Color(uiColor: .systemIndigo)` loop tint → `Accent`. Semantic green/red stay for meaning only.

Type: SF Pro via system styles — header title `.headline` (17 semibold), subtitle 12 regular,
readouts `Spline Sans Mono`-equivalent = `.monospacedDigit()` on SF (the suite uses Spline Sans
Mono on web; on iOS use SF Mono or monospaced digits). Tab content stays monospaced.
Radii: control 11, small chip 8, pills `Capsule`. Motion: 140/240ms ease-out, no bounces.

## 4. Header (shared: text / PDF / canonical / maker)

Height 52pt, background = `BarTint` + `.ultraThinMaterial`-style blur, bottom hairline
`Separator`. Layout `[leading 1fr | center auto | trailing 1fr]`:

- **Leading:** back chevron in `Accent`. iPad: chevron + previous-screen word ("Library" /
  "Compositions"). iPhone: chevron only. Keep the interactive swipe-back enabler.
- **Center — title cluster (tappable, one hit target):**
  - Title, 17 semibold `Fg1`, middle truncation, tiny caret-down (11–12pt, `Fg3`) after it.
  - Subtitle 12 `Fg2`: viewer → `Tuning · TimeSig · first tag` (omit unknowns, lowercase tags);
    PDF → `PDF · N pages · tag`; maker → `Tuning · TimeSig · N bars`.
  - **Confidence badge** (viewer only, when a canonical exists): capsule, mono 10pt,
    dot + `NN%`. ≥ threshold: `AccentSofter` bg / `AccentStrong` text. Below: `CautionSoft` /
    `CautionText`. iPad: badge sits beside the title; iPhone: beside the subtitle.
  - Tapping the cluster opens a menu/sheet: **Rename…, Edit tags…, Favorite ⭐︎ toggle,
    file details** (source, converter version, confidence). This replaces the ellipsis.
- **Trailing:**
  - iPad: favorite star (filled `Accent` when on) + **view switch**.
  - iPhone: view switch only (favorite lives in the title menu).
  - **View switch** = segmented capsule on `SurfaceInset`, selected segment `SurfaceRaised` +
    shadow-1. Viewer: `✦ TabBuddy | 🗎 Original` (icons: sparkle / file-text; iPhone icon-only,
    38×30 segments). Maker: `✎ Edit | 👁 Preview`. Persist per-file (`preferredTextMode` /
    `renderMode` as today). Hide the switch when no canonical exists yet.

Title block on the *page* (mockup shows title printed large in 1a only) — **not** used in 1b;
content starts directly under the header.

## 5. Transport (shared bar)

TabBuddy's drawn score and Guitar Pro use the **same `TabTransportBar` SwiftUI
component**, including popovers and count-in / speed-trainer behavior. Guitar Pro
supplies engine actions and mirrors score position; it never starts the native
playback clock. Its web content contains only the score and loading/error state.

The bar has the same material, accent, hit targets, and labels across formats.

- **iPhone:** restart, play/pause, flexible space, speed, loop, Settings on the
  first row. Bar/time readout plus the position scrubber on the second row.
- **iPad:** the same controls on one row with the readout beside Play and the
  scrubber taking the flexible space. No extra row of rarely used icon tiles.
- **Speed:** 25–150%, quick 50/75/100/125% buttons, optional +5% per loop capped
  at 100%. Editable reference BPM appears only where the source needs it.
- **Loop:** explicit repeat toggle, start/end bar steppers, set start/end to the
  current bar, and clear. The readout shows the range and pass number.
- **Settings:** sound, metronome, count-in, notation, size, auto-scroll, tuning,
  and capo. Multi-track files add track selection and solo. Native text tabs
  retain their rhythm-letter option.
- **Score taps always seek**, even with a loop enabled; they never change loop
  bounds. The loop editor is the only place to edit a practice range.
- **Count-in:** audible even with the metronome disabled; cancels on pause,
  navigation, or app backgrounding. Both players use the same implementation.
- **Display preferences:** notation, size, and follow mode are shared. Saved
  Guitar Pro speed, track, solo, sound, and bar-range settings remain per file.

`PlayerDisplaySections` owns common display controls; each renderer supplies the
score-specific extras. Guitar Pro keeps notation details and its audio engine;
TabBuddy keeps its native text/canonical renderer. Both use the warm paper/rose
palette, including dark appearance.

Original text and PDF retain auto-scroll semantics and their existing compact
transport, using the same Play, Settings, tiles, and scrubber primitives. Maker
continues to use these primitives with its editing controls.

## 6. Tab Maker

- Top `TabMakerToolbar` is removed. Header per §4 (editable title stays in the center cluster —
  dashed underline affordance, tap to edit; Edit/Preview switch trailing).
- Bottom transport, three zones (iPad): **tools** (pencil, eraser — pencil active by default;
  duration chips `1/2 1/4 1/8 1/16` as 32pt mono chips, active = `AccentSoft`) · **position**
  (`bar N/M` + scrubber) · **playback** (mic "Listen", tempo pill, Play 52).
  Time-signature / tuning / measure ± move into the Display popover (they're set rarely).
  iPhone: tools row 1, playback row 2 (mockup 2a, third frame).
- Mic active state: use `Accent`, not `.red` (red is reserved for destructive/negative).
- Fret-suggestion popover (already in `FretSuggestionEngine` + `NoteInputOverlay`): card
  `SurfaceRaised`, radius 15, shadow-3; headline "F♯4 · easiest reach here"; alternatives as
  capsules — recommended = `AccentSoft`/`AccentStrong`, others `SurfaceInset`/`Fg2`.

## 7. Confidence-gated fallback (PDF)

When a canonical exists but `provenance.confidence` is below the display threshold and the
Original is showing, insert a one-line notice card above the PDF (Surface bg, hairline, radius 11):

> `62%` badge + "Showing the original — the TabBuddy version isn't stage-ready yet. **Review**"

"Review" opens the canonical view (later: the correction/diff flow). Dismissable per file.
Copy is Gamic voice: sentence case, plain, no exclamation points.

## 8. Future hooks (do not build now, don't paint into a corner)

- **Diff view:** third state of the view switch (`columns` icon) — keep the switch enum extensible.
- **Lens (capo/tuning transforms):** non-destructive; when active, render a dismissable chip
  under the header: `⇄ Lens: no capo (−2) — sounds the same, frets shift` on `AccentSofter`.
  Never mutates the canonical.

## 9. Code touchpoints

- `TabViewerView.swift` — delete `header`; adopt shared `ViewerHeader` (new) via safe-area top
  inset; route rename/tags/favorite into the title menu; drop `usingDrawnPlayer` quick-toggle
  button (view switch covers it).
- `TabTransportBar.swift` — restyle to §5 tokens/anatomy; keep engine logic, hooks, speed
  trainer; move Sound/Count-in/Follow into Display on compact width (`horizontalSizeClass`).
- `ScrollTransportBar.swift` — delete; originals use the shared transport with the
  scroll-speed middle zone.
- `TabMakerView.swift` / `TabMakerToolbar.swift` — toolbar → bottom transport per §6; title
  field moves into `ViewerHeader` center slot.
- `TabPlayerView.swift` — active-measure highlight → `AccentSoft`; playhead `Accent`.
- Global: asset-catalog colors from §3; app accent = rose; kill `.yellow` / `.systemIndigo` /
  system-blue accents.

## 10. QA checklist

- [ ] Header pixel-identical (except center/trailing content) across text-original, text-player, PDF-original, PDF-canonical, maker.
- [ ] Play button same size/position on every surface, both size classes.
- [ ] No `⋯` anywhere; rename/tags/favorite reachable from the title menu in ≤ 2 taps.
- [ ] View switch persists per file; hidden when no canonical exists.
- [ ] Confidence badge tint flips at the threshold; notice card only on gated PDFs.
- [ ] Dark mode: lifted accent `#F07E79`, dark neutral ramp from `tokens/dark.css`.
- [ ] All hit targets ≥ 44pt; transport labels visible on iPad, hidden on iPhone.


### Practice navigation and tuning labels

Library discovery centers on recents, most played, search, and tags. Tuning labels use one normalization rule: recognized note sequences show their preset name; custom sequences retain every string pitch, including repeated pitches. Missing tuning information is shown as Unknown. Existing derived files refresh through converter version 18.

Both native tabs and Guitar Pro expose Smooth scroll and Follow measures directly above their transport. Smooth scroll is the initial preference and uses a separate scrolling speed, pause, back-to-top, and loop-to-top; it does not start synthesized audio. Follow measures uses score timing, bar seeking, and practice loops. Sound remains an optional setting; Guitar Pro sound defaults off. Switching navigation modes pauses motion. Manual dragging temporarily takes precedence over automatic scrolling.


## Library sync and offline access (historical; superseded 2026-09-25)

Use one primary **Sync library with iCloud** switch for songs and library metadata together. “Local” must not silently continue syncing tags, favorites, or recents. First-run setup offers iCloud when available and a usable local library otherwise. Changing the connection briefly returns the user to the library after saved changes and verified file copying.

Keep **Keep available offline** separate: users should not turn sync off merely to practice without a connection. Show download progress and errors; preserve completed copies. Custom folders belong under Advanced. Disabling sync or changing folders preserves the previous cloud data; deleting cloud data is a separate, unimplemented operation.


## Portable score details

Keep descriptive edits in Score details, with a format-specific footer explaining whether they travel inside the file. Save shows progress, prevents duplicate submission/dismissal, and reports write failures without claiming success. Embedded credits take precedence over inferred title keywords; artist and composer are distinct. Personal practice state stays outside shared score files.

The library instrument dropdown offers All instruments plus only instruments represented in the active library. Include Unspecified only when needed. Derive choices before search/tag/folder filters; reset to All instruments if the selected instrument disappears after edits, deletion, or a library switch. Score details and online discovery retain their full instrument choices.

Online discovery belongs only in the Add (+) submenu as Find music online. Do not repeat it beside library filters or in empty/search-result states.

Rescan progress must advance during catalog reconciliation and Cancel must stop between bounded batches. Existing-folder setup must not wait for embedded metadata reads across the collection. Retain already catalogued songs after cancellation, without declaring unprocessed songs missing.

Opening/foregrounding the app must display the saved library immediately. Do not schedule a full rescan or offline refresh based on elapsed time. Keep external-folder discovery under the explicit Rescan Library action; initial folder setup and direct imports still update the catalog.

Rescan status uses a bottom overlay that does not shift the grid. Keep browsing, search, and score opening available; display file counts once known and a Finding files label during enumeration. Cancel remains a 44-point control.

Settings consolidates storage/offline controls, maintenance (Rescan Library and Generate Tab Data), metadata backup export/restore, and destructive removal. Keep the main ellipsis menu to Select and Settings. Dismiss Settings before showing a file picker, exporter, or removal confirmation; do not stack competing presentations.

Show an indeterminate bar during file discovery, honoring Reduce Motion, alongside the running supported-file count. Switch to a determinate bar once the total is known. Report checked, added-to-library, and existing counts; a rescan does not import/copy files. Retain a dismissible completion/cancellation summary so users can read the result.

Large imports retain successful work: publish the first copied song immediately, commit subsequent songs in batches of 100, and flush the final partial batch on success, cancellation, or failure. A late error must not make earlier copied songs disappear from the catalog. Folder discovery still precedes copying.

Use one compact bottom panel for scans, imports, generation, and background preparation. Its appearance must not inset or push down the main library. Fast import catalogs copied names/paths first; bulk preparation is opt-in and saves progress every 100 files. Opening a library starts it only when the saved automatic-preparation setting is enabled (off by default). Pause is visible, and storage settings explain when preparation must be paused before moving files.

External-folder rescans must save catalog checkpoints before advancing each 100-file progress batch. Distinguish enumeration, in-place catalog additions, and later processing; do not label these additions as copied imports.

Rescan and background preparation are sequential. Show Pausing preparation during the handoff, await its current work before starting enumeration, and show one active status at a time. Retained summaries are displayed only when no active operation has priority.

Folder cards show descendant score counts and whole/partial selection indicators. Selection includes nested songs and excludes similarly named sibling folders. External-folder removal is labeled Remove Folder References and explains source preservation and rediscovery; managed removal is labeled Delete Folder Scores. Build folder membership in one pass for large collections.

Unknown instrument/tuning values do not produce tile chips. Known values use the same restrained treatment as tags and open Score details when tapped. Instruments and tuning stay structured so edits retain consistent filtering/search; do not infer them by interpreting arbitrary personal tags. Tuning includes presets, custom entry, and clear, with an explanation that this is descriptive metadata.

External-folder discovery must stream durable catalog batches before full enumeration completes. Display both found and saved-to-catalog counts so a large discovery count cannot imply unsaved folders are retained. Reconcile missing paths only after a successful complete manifest; partial/cancelled discovery retains saved entries.

Preparation progress distinguishes prepared files, known cloud placeholders waiting for download, and read failures; failures show the latest filename and reason. Only the status panel observes progress, refreshed at most four times per second during preparation plus batch checkpoints; a dismissible summary retains unresolved results. Available file contents use coordinated content reads; cloud placeholders are checked before opening and remain pending. No bulk download is started by preparation.

Large-library responsiveness: scan and preparation counters are observed by their status subviews, not the library filter/sort view. Preparation fetches lightweight pending identifiers and processes at most 100 models at a time; text inference and conversion run on utility workers, with bounded catalog commits and time for UI work between batches. Discovery uses one path index and inserts new entries incrementally, without rebuilding the full catalog/tag index per discovery batch. Full reconciliation skips unchanged file-field writes. Folder mode is still catalog-backed; direct one-folder filesystem browsing is a proposed follow-up, not implemented.

Library sorting/search use a cached value index, with displayed-title sort keys prepared once per catalog snapshot. Filtering and sorting run on a cancellable worker; typing is debounced by 120 ms, while pickers start immediately. Catalog snapshots are refreshed in yielding chunks after saves or query membership changes, coalescing overlapping refresh requests. Returning from a score reuses the completed query. The grid renders 200 matches initially and adds more as the user scrolls; counts and Select All cover every match. Folder membership, instrument choices, and the recent rail reuse cached results. Startup no longer maintains a second filename-sorted library query or opens files to derive folder labels.

PDF opening displays file-access and coordinated-read errors with Retry instead of an empty viewer or a generic iCloud explanation. Known iCloud placeholders can reach the coordinated reader to download on demand; genuinely missing paths still fail. Opportunistic fingerprints are read on a utility worker and skip known cloud-only files.

Name sorting follows the visible score title, including embedded titles and user renames. Normalized tuning labels remain searchable. While the first index is loading, the library says Loading library rather than No scores. Returning to a cached filter invalidates any older pending search. Preparation guidance points external-folder users to Files for downloads. Text score parsing and derived-file writing run off the UI thread; PDFs cancel loading on exit and show read errors with Retry.

Player display menus omit the read-only Tuning & capo section; it offered no adjustment. Score details still supports descriptive tuning metadata, and score-defined tuning/capo continue to govern notation and playback.

Original/TabBuddy switching retains the reader surfaces for the currently open score, preserving scroll positions and avoiding repeated PDF loads or text-view creation. Switching pauses playback and scrolling, hides the inactive surface from touch/accessibility, and defers the preference save out of the gesture. Render models and canonical presentation are prepared off-main and reused; per-note layout uses one resolved string count/tuning per score. These caches last only for the open viewer session.

Animate the Original/TabBuddy control selection without crossfading or animating the full score surfaces. Retained text readers should not invalidate document layout when the font and content are unchanged. Opening and returning to the library must not synchronously save preferences or initialize optional audio. Coalesce reader saves outside navigation gestures, retaining them after dismissal and flushing on inactivity; reader-only settings should not invalidate library filtering or sorting.
