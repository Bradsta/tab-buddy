//
//  TabViewerView.swift
//  TabBuddy
//

import SwiftUI
import UniformTypeIdentifiers
import QuartzCore

struct TabViewerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager

    @Binding var file: FileItem?
    @Binding var path: [AppPage]
    
    @State private var fontSize: CGFloat = 18
    @State private var scrollSpeed: CGFloat = 0
    @State private var currentScale: CGFloat = 1.0
    @State private var isAutoScrolling: Bool = false
    @State private var timer: Timer?
    @State private var scrollViewProxy: UIScrollView?
    @State private var textViewProxy: UITextView?
    @State private var textContent: String = "Loading…"

    @State private var displayLink: CADisplayLink?
    @StateObject private var coordinator = ScrollCoordinator(
        scrollViewProxy: nil, textViewProxy: nil,
        currentFile: nil, scrollSpeed: 0
    )

    var monospacedFont: Font {
        Font(UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
    }

    // loop markers
    @State private var loopStartY: CGFloat? = nil
    @State private var loopEndY: CGFloat? = nil

    // local UI for rename / tag editing
    @State private var showRename = false
    @State private var newName    = ""
    @State private var showTags   = false
    @State private var hasAccess = false

    // MARK: - Playback state
    @StateObject private var playbackCoordinator = PlaybackCoordinator()
    @StateObject private var metronome = MetronomeEngine()
    @StateObject private var notePlayer = NotePlaybackEngine()
    @State private var measureMap: MeasureMap?
    @State private var highlightOverlay = PlaybackHighlightOverlay()
    @State private var userBPM: Double = 120

    @MainActor
    private func loadText() {
        guard let url = file?.url else {
            textContent = NSLocalizedString("failed_load_permissions", comment: "")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let contents = try String(contentsOf: url)
                DispatchQueue.main.async {
                    // Normalize line endings (\r\n → \n) so UITextView and parser agree
                    textContent = contents.replacingOccurrences(of: "\r\n", with: "\n")
                                         .replacingOccurrences(of: "\r", with: "\n")
                    // Parse immediately after loading (don't rely solely on .onChange)
                    if file?.url?.pathExtension.lowercased() != "pdf" {
                        parseTextTab()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    textContent = error.localizedDescription
                }
            }
        }
    }
    
    private var currentScrollY: CGFloat {
        if let sv = scrollViewProxy {
            return sv.contentOffset.y
        } else if let tv = textViewProxy {
            return tv.contentOffset.y
        }
        return 0
    }

    private func syncLoopToCoordinator() {
        coordinator.loopStartY = loopStartY
        coordinator.loopEndY = loopEndY
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                if measureMap != nil {
                    playbackBar
                }
                Divider()
                viewerBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onAppear {
            // restore saved scroll speed for this file
            if let saved = file?.scrollSpeed {
                scrollSpeed = CGFloat(saved)
            }
            // restore saved BPM
            if let saved = file?.userBPM {
                userBPM = saved
                playbackCoordinator.bpm = saved
            }
            if !hasAccess {
                hasAccess = file?.url?.startAccessingSecurityScopedResource() ?? false
                loadText()
            } else {
                loadText()
            }
            // automatically start auto-scroll if a saved speed exists (delay to ensure PDF proxy is set)
            if scrollSpeed > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    startAutoScroll()
                }
            }
            // Set up playback coordinator callbacks
            setupPlaybackCallbacks()
        }
        .onDisappear {
            if hasAccess {
                file?.url?.stopAccessingSecurityScopedResource()
                hasAccess = false
            }
            stopAutoScroll()
            playbackCoordinator.stop()
            metronome.stop()
            notePlayer.stop()
            lastScrolledSystem = -1
            // persist scrollSpeed, loop markers, and BPM on exit
            file?.scrollSpeed = Double(scrollSpeed)
            file?.loopStartY = loopStartY.map { Double($0) }
            file?.loopEndY = loopEndY.map { Double($0) }
            file?.userBPM = userBPM
            try? context.save()
            // clear loop on coordinator for safety
            coordinator.loopStartY = nil
            coordinator.loopEndY = nil
        }
        .onChange(of: scrollSpeed) { newSpeed in
            coordinator.scrollSpeed = newSpeed
            if newSpeed > 0 && !isAutoScrolling {
                startAutoScroll()
            } else if newSpeed == 0 && isAutoScrolling {
                stopAutoScroll()
            }
        }
        .onChange(of: textViewProxy) { proxy in
            coordinator.textViewProxy = proxy
        }
        .onChange(of: textContent) { _ in
            // Parse tab structure when text content loads
            if file?.url?.pathExtension.lowercased() != "pdf" {
                parseTextTab()
            }
        }
        .onChange(of: playbackCoordinator.isPlaying) { isPlaying in
            if !isPlaying {
                highlightOverlay.isHighlightVisible = false
            }
        }
        .onChange(of: scrollViewProxy) { proxy in
            coordinator.scrollViewProxy = proxy
            // restart auto-scroll for PDF when the proxy becomes available
            guard file?.url?.pathExtension.lowercased() == "pdf",
                  proxy != nil,
                  scrollSpeed > 0 else { return }
            DispatchQueue.main.async {
                stopAutoScroll()
                startAutoScroll()
            }
        }
        .sheet(isPresented: $showTags)   { TagEditorView(file: file!) }
            .sheet(isPresented: $showRename) { renameSheet               }
            .onDisappear { stopAutoScroll() }           // safety
    }
    
    private func startAutoScroll() {
        stopAutoScroll()
        guard scrollSpeed > 0 else { return }
        isAutoScrolling = true

        coordinator.scrollViewProxy = scrollViewProxy
        coordinator.textViewProxy = textViewProxy
        coordinator.currentFile = file
        coordinator.scrollSpeed = scrollSpeed
        syncLoopToCoordinator()

        let link = CADisplayLink(target: coordinator, selector: #selector(ScrollCoordinator.handleScrollStep(_:)))

        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        } else {
            link.preferredFramesPerSecond = 30
        }

        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAutoScroll() {
        displayLink?.invalidate()
        displayLink = nil
        isAutoScrolling = false
    }

    private func readFileContent(fileURL: URL) -> String {
        do {
            print("Loading TXT: \(fileURL)")
            
            guard fileURL.startAccessingSecurityScopedResource() else {
                return "\(LocalizedStringKey("failed_load_permissions"))"
            }
            
            return try String(contentsOf: fileURL)
        } catch {
            return error.localizedDescription
        }
    }
    
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Spacer(minLength: 8)

            // ★ favourite toggle
            Button {
                let wasFavorite = file!.isFavorite
                file!.isFavorite.toggle()
                try? context.save()

                undoManager?.registerUndo(withTarget: context) { ctx in
                    file!.isFavorite = wasFavorite
                    try? ctx.save()
                }
                undoManager?.setActionName(wasFavorite
                                          ? "Unfavorite File"
                                          : "Favorite File")
            } label: {
                Image(systemName: file!.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(file!.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)

            // filename (tap to rename)
            Text(file!.filename)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            // tag chips (show first 2 + overflow count)
            if let tags = file?.tags, !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags.prefix(2), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                    if tags.count > 2 {
                        Text("+\(tags.count - 2)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // loop indicator
            if loopStartY != nil && loopEndY != nil {
                Text("\u{27F3} Loop")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            // scroll-speed slider with fine-tune buttons
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down")
                    .foregroundStyle(.secondary)
                Text("\(Int(scrollSpeed))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    scrollSpeed = max(scrollSpeed - 1, 4)
                } label: {
                    Image(systemName: "minus.circle")
                }
                Slider(value: $scrollSpeed,
                       in: 0...40,
                       step: 1)
                    .frame(width: 150)
                Button {
                    scrollSpeed = min(scrollSpeed + 1, 40)
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
            Spacer(minLength: 8)

            // overflow menu
            Menu {
                Button("Rename…") { newName = file!.filename; showRename = true }
                Button("Edit Tags…") { showTags = true }
                Button("Close") { path.removeLast() }

                Divider()

                Button("Set Loop Start") {
                    loopStartY = currentScrollY
                }

                Button("Set Loop End") {
                    guard loopStartY != nil else { return }
                    loopEndY = currentScrollY
                    // swap if end < start
                    if let s = loopStartY, let e = loopEndY, e < s {
                        loopStartY = e
                        loopEndY = s
                    }
                    syncLoopToCoordinator()
                }
                .disabled(loopStartY == nil)

                if loopStartY != nil || loopEndY != nil {
                    Button("Clear Loop", role: .destructive) {
                        loopStartY = nil
                        loopEndY = nil
                        syncLoopToCoordinator()
                    }
                }

                if let f = file,
                   f.loopStartY != nil && f.loopEndY != nil,
                   loopStartY == nil && loopEndY == nil {
                    Button("Resume Last Loop") {
                        loopStartY = f.loopStartY.map { CGFloat($0) }
                        loopEndY = f.loopEndY.map { CGFloat($0) }
                        syncLoopToCoordinator()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal)          // keeps existing 16-pt side insets
        }

        // --------------------------------------------------------------------
        @ViewBuilder
        private var viewerBody: some View {
            if file?.url?.pathExtension.lowercased() == "pdf" {
                if let url = file?.url {
                    TabPDFView(url: url, scrollViewProxy: $scrollViewProxy)
                        .padding()
                }
            } else {
                TabText(fontSize: $fontSize,
                        content: textContent,
                        textViewProxy: $textViewProxy,
                        highlightOverlay: highlightOverlay,
                        onTapAtCharacter: { charIndex in
                            seekToCharacter(charIndex)
                        })
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / currentScale
                                currentScale = value
                                fontSize *= delta
                                stopAutoScroll()
                            }
                            .onEnded { _ in
                                currentScale = 1.0
                                startAutoScroll()
                            }
                    )
                    .padding()
            }
        }

        // --------------------------------------------------------------------
        private var renameSheet: some View {
            NavigationStack {
                Form {
                    TextField("File name", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .navigationTitle("Rename")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: commitRename)
                            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showRename = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }

        @MainActor
        private func commitRename() {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let oldURL = file?.url else { return }

            let newURL = oldURL.deletingLastPathComponent()
                               .appendingPathComponent(trimmed)

            do {
                _ = oldURL.startAccessingSecurityScopedResource()
                defer { oldURL.stopAccessingSecurityScopedResource() }

                try FileManager.default.moveItem(at: oldURL, to: newURL)

                file?.bookmark = try newURL.bookmarkData()
                file?.filename = trimmed
                try context.save()
                showRename = false
            } catch {
                print("Rename failed:", error)
            }
        }

    // MARK: - Playback Bar

    private var playbackBar: some View {
        HStack(spacing: 12) {
            // Play/Pause
            Button {
                if playbackCoordinator.isPlaying {
                    playbackCoordinator.pause()
                    metronome.stop()
                    notePlayer.stop()
                    // Resume constant-speed auto-scroll if speed > 0
                    if scrollSpeed > 0 { startAutoScroll() }
                } else {
                    // Stop constant-speed auto-scroll when playback starts
                    stopAutoScroll()
                    // Force full text layout so highlight Y positions and
                    // contentSize are accurate for the entire document.
                    // UITextView uses lazy layout and may not have computed
                    // positions for text that hasn't been scrolled to yet.
                    if let tv = textViewProxy {
                        tv.layoutManager.ensureLayout(for: tv.textContainer)
                    }
                    metronome.start()
                    notePlayer.start()
                    playbackCoordinator.play()
                }
            } label: {
                Image(systemName: playbackCoordinator.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)

            // Stop
            Button {
                playbackCoordinator.stop()
                metronome.stop()
                notePlayer.stop()
                highlightOverlay.isHighlightVisible = false
                lastScrolledSystem = -1
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 20)

            // BPM control
            HStack(spacing: 4) {
                Text("BPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Int(userBPM))")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(minWidth: 30)
                Button {
                    userBPM = max(userBPM - 5, 30)
                    playbackCoordinator.bpm = userBPM
                } label: {
                    Image(systemName: "minus.circle")
                }
                Slider(value: $userBPM, in: 30...300, step: 1)
                    .frame(width: 100)
                    .onChange(of: userBPM) { newVal in
                        playbackCoordinator.bpm = newVal
                    }
                Button {
                    userBPM = min(userBPM + 5, 300)
                    playbackCoordinator.bpm = userBPM
                } label: {
                    Image(systemName: "plus.circle")
                }
            }

            Divider().frame(height: 20)

            // Metronome toggle
            Button {
                metronome.isEnabled.toggle()
            } label: {
                Image(systemName: metronome.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .foregroundStyle(metronome.isEnabled ? .primary : .secondary)
            }
            .buttonStyle(.borderless)

            // Note playback toggle
            Button {
                notePlayer.isEnabled.toggle()
            } label: {
                Image(systemName: notePlayer.isEnabled ? "music.note" : "music.note.list")
                    .foregroundStyle(notePlayer.isEnabled ? .blue : .secondary)
            }
            .buttonStyle(.borderless)

            // Measure counter
            if let map = measureMap {
                Text("\(playbackCoordinator.currentMeasureIndex + 1)/\(map.measureCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Playback Integration

    private func setupPlaybackCallbacks() {
        // Parse tab for text files
        if file?.url?.pathExtension.lowercased() != "pdf" {
            parseTextTab()
        }

        // Try to find paired MIDI for auto-BPM
        if let fileURL = file?.url {
            if let midiURL = MIDITempoExtractor.findPairedMIDI(for: fileURL),
               let tempoData = MIDITempoExtractor.extract(from: midiURL) {
                if file?.userBPM == nil {
                    userBPM = tempoData.initialBPM
                    playbackCoordinator.bpm = tempoData.initialBPM
                }
                if measureMap?.timeSignature == nil,
                   let ts = tempoData.timeSignature {
                    measureMap?.timeSignature = ts
                }
            }
        }

        // Beat callback → metronome click
        playbackCoordinator.onBeat = { [weak metronome] beatInMeasure, beatsPerMeasure in
            metronome?.playClick(beatInMeasure: beatInMeasure, beatsPerMeasure: beatsPerMeasure)
        }

        // Note callback → note playback
        // Merge all simultaneously-triggered notes into one chord to avoid
        // .interrupts killing all but the last note in a batch
        playbackCoordinator.onNoteReached = { [weak notePlayer] notes in
            guard let player = notePlayer, player.isEnabled else { return }
            if notes.count == 1 {
                player.playNotes(notes[0].frets)
            } else {
                // Merge frets from all notes — latest position wins on conflict
                var merged: [Int?] = Array(repeating: nil, count: 6)
                for note in notes.sorted(by: { $0.positionInMeasure < $1.positionInMeasure }) {
                    for (i, fret) in note.frets.enumerated() {
                        if let f = fret { merged[i] = f }
                    }
                }
                player.playNotes(merged)
            }
        }

        // Frame update → highlight position
        playbackCoordinator.onFrameUpdate = { [weak highlightOverlay] measureIdx, fraction in
            guard let overlay = highlightOverlay,
                  let map = measureMap,
                  let textView = textViewProxy else { return }

            let allMeasures = map.allMeasures
            guard measureIdx < allMeasures.count else { return }

            let measure = allMeasures[measureIdx]

            // Find which system this measure is in
            var measuresInPriorSystems = 0
            var currentSystem: MeasureSystem?
            for sys in map.systems {
                if measureIdx < measuresInPriorSystems + sys.measures.count {
                    currentSystem = sys
                    break
                }
                measuresInPriorSystems += sys.measures.count
            }

            guard let system = currentSystem else { return }

            let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let charWidth = PlaybackHighlightOverlay.monoCharWidth(for: font)

            let rect = PlaybackHighlightOverlay.calculateRect(
                measure: measure,
                beatFraction: fraction,
                system: system,
                textView: textView,
                charWidth: charWidth
            )

            overlay.highlightRect = rect
            overlay.isHighlightVisible = true
        }

        // System changed → scroll to keep visible
        playbackCoordinator.onSystemChanged = { _ in
            scrollToCurrentSystem()
        }
    }

    private func parseTextTab() {
        guard !textContent.isEmpty, textContent != "Loading…" else { return }
        let parsed = TabParser.parse(textContent)
        measureMap = parsed
        playbackCoordinator.measureMap = parsed

        // Use parsed BPM if available and user hasn't set one
        if file?.userBPM == nil, let parsedBPM = parsed.bpm {
            userBPM = parsedBPM
            playbackCoordinator.bpm = parsedBPM
        }
    }

    /// Track the last system we scrolled to, to avoid redundant scroll commands
    @State private var lastScrolledSystem: Int = -1

    private func scrollToCurrentSystem() {
        guard let map = measureMap,
              let textView = textViewProxy else { return }

        // Find the system containing the current measure
        var measuresInPriorSystems = 0
        for (sysIdx, sys) in map.systems.enumerated() {
            if playbackCoordinator.currentMeasureIndex < measuresInPriorSystems + sys.measures.count {
                // Skip if we already scrolled to this system
                guard sysIdx != lastScrolledSystem else { return }
                lastScrolledSystem = sysIdx

                if let lineRange = sys.lineRange {
                    // Use layoutManager for precise Y position instead of estimated lineHeight.
                    // The simple lineRange.lowerBound * lineHeight calculation drifts due to
                    // line wrapping, paragraph spacing, and other layout differences.
                    let lines = textContent.components(separatedBy: "\n")
                    var charIndex = 0
                    for i in 0..<min(lineRange.lowerBound, lines.count) {
                        charIndex += lines[i].count + 1 // +1 for newline
                    }

                    let safeCharIndex = min(charIndex, max(0, textView.text.count - 1))
                    let nsRange = NSRange(location: safeCharIndex, length: 1)
                    let glyphRange = textView.layoutManager.glyphRange(
                        forCharacterRange: nsRange, actualCharacterRange: nil
                    )
                    let lineRect = textView.layoutManager.boundingRect(
                        forGlyphRange: glyphRange, in: textView.textContainer
                    )

                    let systemY = textView.textContainerInset.top + lineRect.origin.y
                    let maxY = max(0, textView.contentSize.height - textView.bounds.height)
                    let targetY = min(maxY, max(0, systemY - textView.bounds.height / 3))

                    // Only scroll if the target is meaningfully different from current position
                    let currentY = textView.contentOffset.y
                    guard abs(targetY - currentY) > 5 else { return }

                    textView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                }
                return
            }
            measuresInPriorSystems += sys.measures.count
        }
    }

    private func seekToCharacter(_ charIndex: Int) {
        guard let map = measureMap else { return }
        notePlayer.stopNotes()
        lastScrolledSystem = -1
        // Find which measure contains this character index
        // Convert character index to approximate column position
        let lines = textContent.components(separatedBy: "\n")
        var charCount = 0
        var targetLine = 0
        var targetCol = 0
        for (i, line) in lines.enumerated() {
            if charCount + line.count >= charIndex {
                targetLine = i
                targetCol = charIndex - charCount
                break
            }
            charCount += line.count + 1 // +1 for newline
        }

        // Find the measure at this line/column
        for (sysIdx, system) in map.systems.enumerated() {
            guard let lineRange = system.lineRange,
                  lineRange.contains(targetLine) else { continue }
            var globalIdx = 0
            for s in map.systems.prefix(sysIdx) {
                globalIdx += s.measures.count
            }
            for (mIdx, measure) in system.measures.enumerated() {
                if let colRange = measure.columnRange, colRange.contains(targetCol) {
                    playbackCoordinator.seekToMeasure(globalIdx + mIdx)
                    return
                }
            }
            // Default to first measure in this system
            playbackCoordinator.seekToMeasure(globalIdx)
            return
        }
    }
    }
