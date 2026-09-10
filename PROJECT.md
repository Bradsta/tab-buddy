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
- The committed Guitar Pro fixtures are original guitar and two-staff piano exercises. Downloaded GProTab arrangements are ignored local test inputs and must not be added to the repository or app. Bundled third-party assets retain their licenses and notices.

## Documentation maintenance

For each behavior change, update the relevant feature and storage contracts here, revise user-facing instructions in README when needed, and add a dated progress entry with actual validation results and remaining limitations. Keep proposed behavior clearly separate from implemented behavior. Do not mark live service behavior verified based only on simulated tests or a signed build.

Player display menus omit the read-only Tuning & capo section; it offered no adjustment. Score details still supports descriptive tuning metadata, and score-defined tuning/capo continue to govern notation and playback.

Original/TabBuddy switching retains the reader surfaces for the currently open score, preserving scroll positions and avoiding repeated PDF loads or text-view creation. Switching pauses playback and scrolling, hides the inactive surface from touch/accessibility, and defers the preference save out of the gesture. Render models and canonical presentation are prepared off-main and reused; per-note layout uses one resolved string count/tuning per score. These caches last only for the open viewer session.

Reader opening, closing, and mode changes coalesce context saves after a 500 ms delay; pending saves survive viewer dismissal and flush when the app becomes inactive. Saves of reader-only preferences leave the library query cache valid. Recency, play counts, and searchable metadata edits refresh the affected snapshot rows; membership/instrument changes and unrecognized save notifications still request full reconciliation. Native audio engines, player nodes, reverb, formats, and click samples are allocated only when audio starts. Sibling MIDI lookup/extraction runs on a cancellable worker with its own file-access lease. Unchanged text fonts are not reassigned during control updates, and mode changes do not animate entire score surfaces. Delayed scroll-start callbacks cannot restart a closed reader.
