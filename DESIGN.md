# TabBuddy × Gamic Arts — viewer/maker chrome revamp ("Quiet header", direction 1b)

Implementation spec for the TabBuddy iOS app (SwiftUI). Reference mockups:
`templates/tab-buddy-revamp/TabBuddyRevamp.dc.html` — option **1b** (iPad, 834×1194) and **2a** (iPhone, 390×844).
Design tokens live in the Gamic Arts design-system folder (`tokens/*.css`, entry `styles.css`); hex conversions for Swift are below.

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

Full-width bottom bar, same material as header, top hairline. All hit targets ≥ 44pt.
Replaces both `TabTransportBar`'s visual layer and `ScrollTransportBar`. Keep
`PlaybackCoordinator` / engine wiring and the `onSeek`/`onLoopChanged`/`onBeforePlay` hooks.

### Zone grammar

| Zone | Canonical player | Original text / PDF | Maker |
|---|---|---|---|
| **Play cluster** (left) | skip-to-start · **Play 52pt** · readout `m. 12/48` + `1:24` | back-to-top · **Play 52pt** (= auto-scroll) · readout `p. 1/3` + `scroll` | skip · **Play 52pt** · readout `bar 3/8` + elapsed |
| **Position** (center, flexible) | measure scrubber | speed slider (gauge icon + `NN px/s` readout) | insertion-point scrubber |
| **Tools** (right) | tempo pill · Sound · Metronome · Count-in · Loop · Follow · Display | Loop-to-top · Display | Listen (mic) · tempo pill · Play sits here on maker if preferred — see §6 |

Control anatomy:
- **Play:** 52pt circle (48 on iPhone), `Accent` fill, white icon, soft accent shadow.
  Pause state swaps glyph only. During count-in show pause + pulsing readout.
- **Icon tile:** 44×44, radius 11. Inactive: `SurfaceInset` bg, `Fg1` icon. Active: `Accent` bg,
  white icon. 10pt label under the tile in `Fg2` (`Accent` when active). Labels hide on iPhone.
- **Tempo pill:** height 44 (38 iPhone), `AccentSoft` bg, `AccentStrong` content:
  ♪ icon + BPM mono semibold; percent-of-original as its label ("94%"). Tap → existing tempo /
  speed-trainer popover (restyle with tokens; quick buttons 50/75/90/100 use `Accent` tint).
- **Scrubber:** 4pt track `SeparatorStrong`, filled `Accent`, 22pt `SurfaceRaised` thumb with
  shadow-2. Same component for measure position and scroll speed.
- **Readout:** mono, value 15 semibold `Fg1`, sub-line 12 `Fg2` (loop state may tint sub-line
  `Accent` — not indigo).
- **Display popover** (sliders icon) keeps per-surface contents: text size (original text),
  auto-scroll options, player display settings. On iPhone it also absorbs **Sound, Count-in,
  Follow** (see below).

### iPhone compact layout (mockup 2a)

Two rows inside the bar, then home-indicator inset:
1. **Controls row:** play cluster left, spacer, then (player) tempo pill · Metronome · Loop ·
   Display as 38pt tiles. Sound / Count-in / Follow move into Display.
2. **Slider row:** full-width scrubber (player/maker: position; PDF/text: speed with gauge icon
   and `px/s` readout).

### Semantics

- Original text + PDF share *identical* transports. `showDisplayButton` special-casing goes away
  (PDF Display popover can be empty of text-size and still offer scroll options).
- Loop on originals = loop-to-top (as today); keep the Loop seat so muscle memory holds.
- Auto-scroll speed 0 + play tap → nudge to default speed 8 (existing behavior, keep).

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
