# TabBuddy

<div align="center">
  <img src="Images/icon.png" width="250" alt="Currently Playing">
</div>

A SwiftUI document viewer and organizer for iOS that helps you manage, tag, and read your text, PDF, and Guitar Pro scores with advanced auto-scrolling capabilities. Originally intended for easily reading and storing your personal guitar tabs. Published on the [iOS App Store](https://www.google.com/url?sa=t&source=web&rct=j&opi=89978449&url=https://apps.apple.com/ge/app/tab-buddy/id6742390560&ved=2ahUKEwj2msz6yqKRAxXPOEQIHWyQDW0QFnoECBsQAQ&usg=AOvVaw2RbC6g7kF9jWZ1Qoh4qqHs).

<div align="center">
  <img src="Images/collection-view.png" height="450" alt="Tab Collection View" />
  <img src="Images/tab-pdf-view.png" height="450" alt="Tab PDF View" />
</div>

See [PROJECT.md](PROJECT.md) for the current feature inventory, product intent, architecture, and known limitations.

## Features

### 📁 File Management
- **Import files and folders**: Support for both individual files and entire folder hierarchies
- **File browser**: Clean, organized view of all your imported documents
- **App-managed library**: Imports are copied into the app library; originals remain untouched
- **Storage choice**: three library options (Local only, iCloud only, Hybrid). Changing options never copies songs
- **Favorites**: Mark frequently used files as favorites for quick access

### 🏷️ Smart Tagging System
- **Tag your files**: Organize documents with custom tags
- **Tag statistics**: See tag usage counts and filter by tags
- **Bulk tagging**: Apply tags to multiple files at once
- **Tag management**: Rename and reorganize tags with long-press gestures

### 📖 Advanced Reading Experience
- **Multi-format support**: View text files, PDFs, and Guitar Pro 3–8 files (`.gp3`, `.gp4`, `.gp5`, `.gpx`, `.gp`)
- **Guitar Pro practice player**: Offline notation and audio, track selection/solo, metronome, practice speed, zoom, and saved bar-range loops
- **Auto-scrolling**: Customizable auto-scroll with adjustable speed
- **Typography controls**: Adjustable font size with monospaced font support
- **Zoom and pan**: Smooth scaling and navigation
- **Reading progress**: Tracks last opened time and reading position

### 🎓 Tutor and Practice
- **Tutor**: guitar and piano courses laid out like a textbook: chapters you read at your own pace with inline diagrams, playable examples, and "Try it" boxes; a Practice section for scales, chords, intervals, and rhythms at any tempo; flashcards; ear and fretboard games; and a glossary
- **Practice a library song**: TabBuddy listens through the microphone, compares what you play with the score, and reviews accuracy and tempo
- **Offline and on device**: no account, network, or MIDI cable needed

### 💾 Data Persistence
- **SwiftData integration**: Modern Core Data replacement for reliable storage
- **File metadata**: Stores import dates, scroll speeds, and user preferences
- **Undo support**: Full undo/redo functionality throughout the app

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/tab-buddy.git
   ```

2. Open `TabBuddy.xcodeproj` in Xcode

3. Build and run the project on your iOS device or simulator

## Usage

### Importing Files
1. Tap the import button in the file browser
2. Choose between importing individual files or entire folders
3. Select your documents from the iOS file picker
4. Files are copied into your Tab Buddy library; the source files remain unchanged

When importing a folder, **Finding files…** appears before the file count is known. Access/copy errors and folders with no supported scores show an explanation.

If you used the older development app, keep it installed: the new registered app has separate storage. Import your original folder into the new app, then export metadata from the old app and restore that backup in the new one after selecting/scanning the intended library folder.

### Library Storage

The **Settings** sheet also contains Generate Tab Data, metadata backup export/restore, and Remove All Files. Removal still requires confirmation.
On first launch, choose one of three library options, then tap **Get Started** (or **Choose Folder…** for Hybrid). iCloud only is suggested when iCloud Drive is available.

- **Local only**: songs are in a folder on this device (the app's own library, or a folder you choose); library info (tags, favorites, recents, play counts, score details) stays on this device.
- **iCloud only**: songs are in TabBuddy's iCloud library; library info syncs through iCloud.
- **Hybrid**: songs are read in place from a folder you choose, for example your own iCloud Drive folder; library info syncs through iCloud between your devices. Choose the same folder on each device.

Open **… → Settings → Library** to change options. **Changing options never copies, moves, or deletes songs.** Each option shows the songs in its own location; songs in the previous location stay where they are and reappear when you switch back. A short confirmation says which location the library will show. Local only and Hybrid show the current folder with **Choose Folder…** / **Change Folder…**; Local only with a chosen folder also offers **Use App Folder Instead**. Switching between Local only and Hybrid keeps the same folder and only changes whether library info syncs. The library screen briefly reloads when library-info sync turns on or off. If an existing iCloud library becomes unavailable, it stays selected and shows a retry message instead of silently creating an empty replacement.

In Hybrid, a song whose file is not in this device's folder is hidden on this device, not deleted; its library info stays for your other devices. When the same song was catalogued on two devices before syncing, TabBuddy merges the two entries automatically (matching by path inside the folder, then by file fingerprint for renamed files after a full rescan on this device), keeping tags, favorites, play counts, loops and practice settings, and practice history. While a merge runs, the bottom status panel shows **Merging library info from your other devices…**; please don't edit songs until it finishes. If this device hasn't opened the Hybrid folder yet, the library asks you to **Choose This Folder on This Device**.

The first time you switch a device to Hybrid or iCloud only, the confirmation offers **Export a Library Backup First**. Use it: it saves tags, favorites, loops, and score details to a file you can restore. If the folder's hidden library marker hasn't downloaded from iCloud Drive yet, choosing the folder shows "Waiting for the library marker to download from iCloud Drive"; open the folder in the Files app, let it download, and choose it again. On a second device, choose the folder only after the first device has finished setting it up.

Less common actions are under **More Storage Options**: **Keep available offline** (iCloud-backed folders only), **Reconnect Folder…**, and **Copy Library to New Folder…**, the one explicit action that copies songs (into a new Tab Buddy Library subfolder you pick).

Opening the app uses your saved library without rescanning the folder. After changing files outside TabBuddy, choose **… → Settings → Rescan Library**. You can keep browsing and opening songs while it runs; progress and Cancel appear in a bottom overlay without moving the library, with found, checked, newly added, and existing file counts. A summary remains after the scan.

**Keep available offline** (More Storage Options, iCloud-backed folders only) downloads additional local song copies. Downloads refresh after scans/imports and can be retried with Refresh Downloads. Turning it off removes only those extra copies.

**Remove All Files** and Delete Selected say what they do before you confirm: for a chosen folder (Local only or Hybrid) they remove catalog entries only and your files stay in the folder; in Hybrid and iCloud only the removed library info is removed on all your devices; the app's own libraries delete the song files. In Hybrid, songs hidden on this device are never removed from it. The same applies in Local only on a device that has synced library info before, because those removals would reach your other devices if you turn Hybrid or iCloud only back on; the confirmation says so.

TabBuddy never deletes files in a folder you chose. A card's **Remove from Library** removes the song and its library info; the file stays in the folder. Delete it in the Files app if you want it gone. **Delete** is offered only for TabBuddy's own library folder.

Signing uses `com.gamicarts.TabBuddy` and the `iCloud.com.gamicarts.TabBuddy.library` container. Simulator tests cover local fallback, option switching without copying, metadata connection changes, duplicate merging with simulated two-device stores, and offline copies through isolated storage roots. They do not use CloudKit; a signed build on two devices signed into the same iCloud account is needed to verify live synchronization.

### Finding Music and Choosing an Instrument
Open **Add (+) → Find music online** in the library. Choose an instrument and enter a song, composer, artist, or game. Tap a source to open its web search; with an empty query, the source homepage opens. Free and purchase sources show the file formats to look for. Download a supported file, then use **Import Downloaded Files** or share it to TabBuddy.

The library instrument filter lists only instruments present in the current library, including scores containing several instruments. Search, tags, and folder navigation do not narrow its choices. Open **Score details** from a card's context menu or the viewer's title menu to edit instruments, credits, arrangement, and source. Your edits take precedence over automatic detection. Embedded metadata and text-tab data can be prepared through **Settings → Prepare Library** in resumable batches when files are available locally. Rescanning an existing folder skips embedded content reads so file-provider downloads cannot block cataloguing. Files without clear instrument information can remain **Unspecified** until opened or edited. Score details saves descriptive metadata inside UTF-8 text, PDF, and GP3–5 library files, so it travels with the file. GPX/newer `.gp` edits currently remain library-only; personal practice history and tags still use library sync/backup.

### Original Notation
PDFs and text start in their original form; Guitar Pro starts with the notation stored in the file. Piano parts remain staff notation. Use the player settings to choose another supported display. For a PDF, **Create guitar arrangement** is an explicit, best-effort conversion that preserves the source.

Bass, ukulele, and extended-range guitar tabs retain their string counts. Smooth scrolling works for original scores; precise measure following requires parsed tabs or a supported structured score. General MusicXML and MuseScore import are not yet available.

### Tutor
Tap **Tutor** (graduation cap) in the library toolbar. Choose **Guitar** or **Piano** at the top of the sidebar (iPad) or home screen (iPhone). The tutor is written for an acoustic guitar or an acoustic/digital piano played into the device microphone.

- **Contents**: the course is a book. Parts 0–8 are a recommended order, not a gate; every chapter opens. **Next up** is the first chapter you have not marked read. Tap a chapter to see its sections and open it (or jump to one section). **Mark as done** means read; **Mark as not done** undoes it. Nothing is scored. Side branches such as Rhythm reading, Fingerstyle basics, Blues shuffle, Reading the grand staff, and Pedal basics are optional detours suggested after a named chapter.
- **Chapters**: one scrolling page with a table of contents at the top (on iPad) and in the Contents menu. Reading sections put the diagram beside the text with a **Hear it** button; **Example** cards play on the built-in synth and light up the diagram; **Try it** boxes let you practice an exercise at your own pace: **Play example** at any tempo, **Loop**, tempo chips, and a **Listen** switch that turns the notes it hears green (choose **Wait for me** or **Play along** with a visual count-in). Songs are Try it boxes too. **Check yourself** questions sit at the end of the chapter: tap a choice or **Show answer** to see the answer and why; **New set** draws new generated questions. Keyboard: Space plays the example, L toggles Listen, ⌘D marks the chapter done, Escape closes. Without microphone access everything except Listen still works.
- **Practice**: scales (any root and type, one or two octaves, a fret position on guitar), chords (any root and quality, block / arpeggio / strum), intervals (any interval from a movable root, up / down / together), and rhythms (presets or your own tokens such as `q q e e q`), each with Play example, loop, tempo, and Listen. **Exercises** lists every Try it box and song in the course by kind and opens its chapter at that section.
- **Flashcards**: the facts, notes, and chords from chapters you have marked read (or all chapters). Flip a card; **Got it** keeps it out for the session, **Again** sends it to the back. Play cards offer **Hear it** instead of listening. Nothing is graded.
- **Games**: Fretboard Hunt / Key Hunt, Chord Change Sprint, Interval Duel, Name That Quality, Rhythm Tapper, Scale Runner, and Note Rush. Each keeps a personal best; there are no streaks.
- **Songs you know**: library songs whose chord symbols use chords you have learned. Tap one to open it in the reader. Chords are read from converted scores and from text tabs already on the device; Guitar Pro chord names are not read yet.
- **Tutor settings**: instrument, a daily goal in minutes (counted from chapters you mark read), and **Reset progress** for one instrument. Reset keeps calibration and your practice takes.

When TabBuddy listens it checks which pitches sound, not which string or fret you used, and only ever adds green for what it heard. When it cannot tell, it shows a gray "not sure". All app sound stops while it listens, so follow the on-screen count-in and beat pulse.

### Calibrating the microphone
Open **Tutor → Calibration** before you first use Listen or Library Practice, and again after changing headphones or an audio interface. Calibration is saved separately for each audio route.
1. Allow microphone access.
2. Check the input level. On iPad, stand it on a music stand within about 1 m of the guitar, with the top edge (where the microphones are) toward the sound hole. For piano, put it on the music desk with the top edge toward the strings or open lid. Keep the case and your hands off that edge, and turn off fans, music, or the TV.
3. Play the check note (open low E, or middle C) and confirm the detected note.
4. Run latency calibration: play along with 8 clicks, or use the silent visual pulses if you prefer no sound.

### Practicing a library song
Open a song and tap the **Practice** tool (waveform and microphone) in the bottom transport.
- **Available** for text tabs with readable tuning, PDFs after **Create guitar arrangement**, Guitar Pro files (the selected track), and any score with a MIDI file of the same name beside it. Otherwise the tool explains why it cannot listen.
- Set the **range** (defaults to your loop or the current system), **speed** (25–150%), and **instrument**.
- **Wait** mode waits on each note or chord until it hears it; → skips one. **Play-along** moves the cursor at your speed after a visual count-in. Space starts or stops a take; Escape leaves practice.
- During a take, heard notes turn green. Nothing turns red while you play.
- After the take, the **review** shows:
  - each expected note: hit, partial, wrong pitch with what you played, missed, or not sure
  - early/late timing
  - a **tempo ribbon** of your actual BPM per measure; tap a section to loop it
  - accuracy and weakest measures
  - playback of your recording
  - **suggestions** such as "loop measures 9–12 at 80%", which set the loop and speed in the reader
- If TabBuddy could not hear a take clearly, the review says so instead of scoring it. Leaving practice mid-take keeps takes longer than 3 seconds for review next time.
- **Past takes** lists earlier attempts with a per-measure accuracy history. Only the 10 newest takes per song keep audio.

Results come from on-device listening tuned on synthetic recordings. Accuracy with your instrument and room may vary, and "not sure" marks are expected.

### Privacy
Microphone audio is processed on the device and never uploaded. Practice recordings and tutor progress are kept in the app's local storage, not in iCloud or library backups. Deleting a take removes its recording.

### Organizing with Tags
1. Long-press on any file to edit tags
2. Add custom tags to categorize your documents
3. Use the tag header to filter files by specific tags
4. Long-press on tag chips to rename or manage tags

### Reading Documents
1. Tap any file in the browser to open it
2. Use pinch gestures to zoom in/out
3. Tap the auto-scroll button to start/stop automatic scrolling
4. Adjust scroll speed with the slider
5. Change font size using the typography controls

## Architecture

TabBuddy is built using modern iOS development practices:

- **SwiftUI**: Declarative user interface framework
- **SwiftData**: Modern data persistence with `@Model` classes
- **Async/Await**: Swift concurrency for file operations
- **MVVM Pattern**: Clean separation of concerns
- **Security-Scoped Bookmarks**: Secure file access across app launches

### Key Components

- `ContentView`: Main app navigation and coordination
- `FileBrowserView`: File listing and organization interface
- `TabViewerView`: Document reading and interaction
- `FileItem`: SwiftData model for file metadata
- `TagIndexer`: Tag statistics and management system

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

### Development Setup

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with SwiftUI and SwiftData
- Uses iOS security-scoped bookmarks for file access
- Inspired by the need for a simple, powerful document organizer

## Support

If you encounter any issues or have questions, please file an issue on GitHub or reach out to the development team.

---

**Note**: This app requires file access permissions to import and view your documents. All file access is handled securely using iOS sandbox and security-scoped bookmarks.

Imports save progress incrementally: the first song immediately, then batches of 100. Cancelling or encountering a later copy error keeps completed songs, including the last partial batch. If an older build copied songs without listing them, use Settings → Rescan Library to recover those catalog entries.

Import first copies/catalogs files without parsing. Use **Settings → Prepare Library** to prepare metadata and text tabs in batches of 100. Unfinished work resumes through **Settings → Prepare Library**, or on opening when **Prepare library automatically** is enabled (off by default); Pause is available in the status panel. It pauses when you leave the app and does not automatically download cloud-only scores or create guitar arrangements from PDFs.

For an external iCloud folder used as the library, Rescan Library indexes files in place without copying them. During enumeration, catalog entries are saved every 100 files; preparation is opt-in for locally available scores.

Starting a rescan while preparation is running pauses and finishes that preparation step first, then scans; unfinished preparation resumes only when automatic preparation is enabled. The bottom panel shows one active operation at a time.

In folder view, enter Select mode and tap folders to select their nested songs, or long-press a folder and choose **Remove Folder References** for an external library. This keeps iCloud source files intact. Managed-library removal deletes the selected score files.

Tiles hide unknown instruments and tunings. Tap a known instrument or tuning chip to edit Score details; use the tile’s Score details menu to add missing values. Tuning accepts presets or custom text and can be cleared. These are descriptive library fields, not changes to the score’s notes.

During external-folder rescans, **found** counts discovered paths while **saved to catalog** counts durable entries. Saved batches and their folders survive closing the app even before discovery completes. Run Rescan Library again to discover the remainder.

Preparation progress distinguishes prepared files, known cloud placeholders waiting for download, and read failures; failures show the latest filename and reason. Only the status panel observes progress, refreshed at most four times per second during preparation plus batch checkpoints; a dismissible summary retains unresolved results. Available file contents use coordinated content reads; cloud placeholders are checked before opening and remain pending. No bulk download is started by preparation.

Large-library responsiveness: scan and preparation counters are observed by their status subviews, not the library filter/sort view. Preparation fetches lightweight pending identifiers and processes at most 100 models at a time; text inference and conversion run on utility workers, with bounded catalog commits and time for UI work between batches. Discovery uses one path index and inserts new entries incrementally, without rebuilding the full catalog/tag index per discovery batch. Full reconciliation skips unchanged file-field writes. Folder mode is still catalog-backed; direct one-folder filesystem browsing is a proposed follow-up, not implemented.

Library sorting/search use a cached value index, with displayed-title sort keys prepared once per catalog snapshot. Filtering and sorting run on a cancellable worker; typing is debounced by 120 ms, while pickers start immediately. Catalog snapshots are refreshed in yielding chunks after saves or query membership changes, coalescing overlapping refresh requests. Returning from a score reuses the completed query. The grid renders 200 matches initially and adds more as the user scrolls; counts and Select All cover every match. Folder membership, instrument choices, and the recent rail reuse cached results. Startup no longer maintains a second filename-sorted library query or opens files to derive folder labels.

PDF opening displays file-access and coordinated-read errors with Retry instead of an empty viewer or a generic iCloud explanation. Known iCloud placeholders can reach the coordinated reader to download on demand; genuinely missing paths still fail. Opportunistic fingerprints are read on a utility worker and skip known cloud-only files.

Name sorting follows the visible score title, including embedded titles and user renames. Normalized tuning labels remain searchable. While the first index is loading, the library says Loading library rather than No scores. Returning to a cached filter invalidates any older pending search. Preparation guidance points external-folder users to Files for downloads. Text score parsing and derived-file writing run off the UI thread; PDFs cancel loading on exit and show read errors with Retry.

Player display menus omit the read-only Tuning & capo section; it offered no adjustment. Score details still supports descriptive tuning metadata, and score-defined tuning/capo continue to govern notation and playback.

Original/TabBuddy switching retains the reader surfaces for the currently open score, preserving scroll positions and avoiding repeated PDF loads or text-view creation. Switching pauses playback and scrolling, hides the inactive surface from touch/accessibility, and defers the preference save out of the gesture. Render models and canonical presentation are prepared off-main and reused; per-note layout uses one resolved string count/tuning per score. These caches last only for the open viewer session.

Opening, closing, and switching a score saves reading preferences after a short delay, including when you return to the library; leaving the app flushes pending saves. These actions avoid initializing audio or rebuilding the entire library index for practice-setting changes. Recents, play counts, and metadata searches continue to update.
