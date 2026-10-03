//
//  TabViewerView.swift
//  TabBuddy
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import QuartzCore

/// Which representation the viewer renders.
enum ViewerRenderMode: String { case original, canonical }

/// For text tabs: the drawn native player vs. the raw original monospaced text.
enum TextViewMode: String { case player, original }

/// Keep database work out of reader gestures. Pending writes outlive a popped
/// viewer, coalesce on the owning context, and flush when the app leaves active use.
@MainActor
enum ReaderPersistence {
    private static var pendingSaves: [ObjectIdentifier: Task<Void, Never>] = [:]

    static func scheduleSave(_ context: ModelContext) {
        let key = ObjectIdentifier(context)
        pendingSaves[key]?.cancel()
        pendingSaves[key] = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            flush(context)
        }
    }

    static func flush(_ context: ModelContext) {
        pendingSaves.removeValue(forKey: ObjectIdentifier(context))?.cancel()
        guard context.hasChanges else { return }
        do { try context.save() }
        catch { LibraryManager.shared.lastError = "Could not save reading preferences: \(error.localizedDescription)" }
    }
}

struct TabViewerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager

    /// Global preference for which representation to show (per-user, sticky).
    @State private var renderMode: ViewerRenderMode = .original
    @State private var hasShownPlayer = false
    @State private var preparedRenderModel: TabRenderModel = .empty
    @State private var canonicalLoadTask: Task<Void, Never>?
    @State private var canonicalLoadedKey: String?
    /// Text-tab display, remembered per song. Defaults to the raw original text;
    /// the user can switch a given song to the drawn Tab Player and it sticks.
    private var textMode: TextViewMode {
        TextViewMode(rawValue: file?.preferredTextMode ?? "") ?? .original
    }
    /// Cached canonical ASCII rendering (decoded from the stored MusicXML).
    @State private var canonicalText: String? = nil
    /// Counts a "play" only after the tab has stayed open a few seconds.
    @State private var playCountTask: Task<Void, Never>?
    private static let playDwellSeconds: UInt64 = 3

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
    @State private var showDetails = false
    @State private var creatingArrangement = false
    @State private var fileLease: FileAccessLease?
    @State private var resolvedFileURL: URL?
    @State private var fileAccessError: String?
    @State private var fileAccessTask: Task<Void, Never>?
    @State private var textParseTask: Task<Void, Never>?
    @State private var midiLoadTask: Task<Void, Never>?
    @State private var pairedMIDI: MIDITempoData?
    @State private var isVisible = false
    @State private var textLoadGeneration = UUID()

    // MARK: - Playback state
    @StateObject private var playbackCoordinator = PlaybackCoordinator()
    @StateObject private var metronome = MetronomeEngine()
    @StateObject private var notePlayer = NotePlaybackEngine()
    @State private var measureMap: MeasureMap?
    @State private var highlightOverlay = PlaybackHighlightOverlay()
    @State private var userBPM: Double = 120

    // Loop-to-top for the Original file view's auto-scroll transport.
    @State private var loopToTopText = false

    // Tutor practice mode (TUTOR_IMPLEMENTATION.md §8).
    @State private var practiceContext: PracticeScoreContext?
    /// Ends the practice session when the viewer really leaves the screen.
    @State private var practiceSession = PracticeSessionHandle()
    /// The drawn player's 100% tempo, captured when it configures (mirrors
    /// `TabPlayerView.configure()`), so practice speeds match the player's.
    @State private var drawnReferenceBPM: Double?

    /// Set on the first appear of this viewer; a later appear is a return from
    /// a presentation, not a new visit (no play count, no file re-resolve).
    @State private var viewerSession: TabViewerLifecycle.Session?

    private func resolveFile() {
        fileAccessTask?.cancel()
        fileAccessError = nil
        PerfTrace.lap("open", "lease requested")
        fileAccessTask = Task {
            guard let file else { return }
            PerfTrace.lap("open", "lease task running")
            do {
                let lease = try await LibraryManager.shared.acquireFile(file)
                guard !Task.isCancelled else { lease.close(); return }
                PerfTrace.lap("open", "lease")
                fileLease?.close()
                fileLease = lease
                resolvedFileURL = lease.url
                if !isGuitarPro && !isPDF { loadText() }
                setupPlaybackCallbacks()
            } catch {
                guard !Task.isCancelled else { return }
                fileAccessError = error.localizedDescription
                textContent = error.localizedDescription
            }
        }
    }

    @MainActor
    private func loadText() {
        guard let url = resolvedFileURL else {
            textContent = NSLocalizedString("failed_load_permissions", comment: "")
            return
        }

        let generation = UUID()
        textLoadGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Coordinated read: downloads iCloud placeholders before reading.
                var readResult: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { readURL in
                    readResult = Result { try String(contentsOf: readURL) }
                }
                let contents = try readResult.get()
                DispatchQueue.main.async {
                    guard textLoadGeneration == generation else { return }
                    PerfTrace.lap("open", "text read")
                    // Normalize line endings (\r\n → \n) so UITextView and parser agree
                    textContent = contents.replacingOccurrences(of: "\r\n", with: "\n")
                                         .replacingOccurrences(of: "\r", with: "\n")
                    // The text change schedules one cancellable parse off the UI thread.
                }
            } catch {
                DispatchQueue.main.async {
                    guard textLoadGeneration == generation else { return }
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
        viewerBody
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DS.paper.ignoresSafeArea())
            // One header for every surface (DESIGN.md §4), via safe-area inset
            // so SwiftUI scroll surfaces slide under the translucent bar.
            .safeAreaInset(edge: .top, spacing: 0) { viewerHeader }
            // The drawn Tab Player carries its own transport; every other
            // (scrollable) render — raw text and PDF — gets the shared
            // scroll transport along its bottom.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showScrollTransport && practiceContext == nil {
                    originalTransport
                }
            }
        // Hide the empty system nav bar (reclaims top space) but keep the
        // interactive swipe-back — `navigationBarBackButtonHidden` is what
        // disables that edge gesture, so we deliberately don't set it.
        .toolbar(.hidden, for: .navigationBar)
        .environment(\.practiceTool, PracticeToolState(resolveStatus: { practiceStatus }, open: { openPractice() }))
        .overlay {
            if let practiceContext {
                PracticeModeView(context: practiceContext, session: practiceSession) { self.practiceContext = nil }
            }
        }
        .sheet(isPresented: $showDetails) { if let file { ScoreDetailsView(file: file) } }
        .onAppear {
            PerfTrace.lap("open", "viewer appeared")
            isVisible = true
            if viewerSession != nil {
                // Back from something that covered the viewer: keep the file,
                // loops, and play count; only resume auto-scroll.
                if scrollSpeed > 0 && !isGuitarPro {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { startAutoScroll() }
                }
                return
            }
            viewerSession = TabViewerLifecycle.Session(depth: path.count)
            if textMode == .player { hasShownPlayer = true }
            // restore saved scroll speed for this file
            if let saved = file?.scrollSpeed {
                scrollSpeed = CGFloat(saved)
            }
            // restore saved BPM
            if let saved = file?.userBPM {
                userBPM = saved
                playbackCoordinator.bpm = saved
            }
            resolveFile()
            // automatically start auto-scroll if a saved speed exists (delay to ensure PDF proxy is set)
            if scrollSpeed > 0 && !isGuitarPro {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    startAutoScroll()
                }
            }
            // Set up playback coordinator callbacks
            // PDFs stay original; guitar arrangement generation is an explicit action.
            if let file, file.filename.lowercased().hasSuffix(".pdf") {
                file.inferMetadata(from: file.displayTitle)
                // Already-converted PDFs can offer the drawn Tab Player now.
                loadCanonicalMap()
            }

            if renderMode == .canonical { loadCanonicalText() }

            // Count a play only if the tab stays open past the dwell threshold.
            playCountTask?.cancel()
            playCountTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.playDwellSeconds * 1_000_000_000)
                guard !Task.isCancelled, let file else { return }
                file.playCount += 1
                try? context.save()
            }
        }
        .onChange(of: usingDrawnPlayer) { _, _ in
            stopAutoScroll()
            playbackCoordinator.pause()
            metronome.stop()
            notePlayer.stop()
        }
        .onChange(of: renderMode) { mode in
            if mode == .canonical { loadCanonicalText() }
        }
        .onChange(of: file?.canonicalVersion) { _ in
            // Convert-on-open finished while the PDF is showing — refresh the
            // player map so a stale (older-converter) map never sticks around.
            if isPDF { loadCanonicalMap() }
        }
        .onDisappear {
            PerfTrace.lap("back", "viewer gone")
            isVisible = false
            stopAutoScroll()
            playbackCoordinator.pause()
            metronome.stop()
            notePlayer.stop()
            persistReaderState()
            // A full-screen presentation over the viewer also triggers this;
            // the viewer is still the top page then, so keep its state.
            if let session = viewerSession, session.isCovered(path: path) { return }
            viewerSession = nil
            practiceSession.close()
            practiceContext = nil
            playCountTask?.cancel()
            fileAccessTask?.cancel()
            canonicalLoadTask?.cancel()
            textParseTask?.cancel()
            midiLoadTask?.cancel()
            textLoadGeneration = UUID()
            fileLease?.close()
            fileLease = nil
            resolvedFileURL = nil
            stopAutoScroll()
            playbackCoordinator.stop()
            metronome.stop()
            notePlayer.stop()
            lastScrolledSystem = -1
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
            if !isPDF && !isGuitarPro {
                if textContent != "Loading…" { PerfTrace.endAfterCommit("open", "text") }
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
            guard isPDF,
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
    
    /// Persists scroll speed, loop markers, and BPM.
    private func persistReaderState() {
        guard let file, file.modelContext != nil, !file.isDeleted else { return }
        if file.scrollSpeed != Double(scrollSpeed) { file.scrollSpeed = Double(scrollSpeed) }
        let start = loopStartY.map { Double($0) }
        let end = loopEndY.map { Double($0) }
        if file.loopStartY != start { file.loopStartY = start }
        if file.loopEndY != end { file.loopEndY = end }
        if file.userBPM != userBPM { file.userBPM = userBPM }
        ReaderPersistence.scheduleSave(context)
    }

    private func startAutoScroll() {
        stopAutoScroll()
        guard isVisible, scrollSpeed > 0, !usingDrawnPlayer else { return }
        isAutoScrolling = true

        coordinator.scrollViewProxy = scrollViewProxy
        coordinator.textViewProxy = textViewProxy
        coordinator.currentFile = file
        coordinator.isPDF = file?.filename.lowercased().hasSuffix(".pdf") ?? false
        coordinator.scrollSpeed = scrollSpeed
        coordinator.loopToTop = loopToTopText
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
            
            return try String(contentsOf: fileURL)
        } catch {
            return error.localizedDescription
        }
    }
    
    // MARK: - Header (shared chrome, DESIGN.md §4)

    private var viewerHeader: some View {
        ViewerHeader(
            title: file?.displayTitle ?? "",
            subtitle: headerSubtitle,
            confidence: file?.hasCanonical == true ? file?.provenance?.confidence : nil,
            isFavorite: file?.isFavorite ?? false,
            onToggleFavorite: file == nil ? nil : { toggleFavorite() },
            onRename: { newName = file?.displayTitle ?? ""; showRename = true },
            onEditTags: { showTags = true },
            onEditDetails: { showDetails = true },
            detailRows: headerDetailRows,
            // Original is the primary reading surface; the TabBuddy render
            // is opt-in per track until extraction earns more trust.
            switchSegments: [
                ViewSwitchSegment(id: 1, icon: "doc.text", label: "Original"),
                ViewSwitchSegment(id: 0, icon: "sparkles", label: "TabBuddy"),
            ],
            switchSelection: playerAvailable ? viewSwitchSelection : nil,
            backLabel: "Library",
            onBack: { if !path.isEmpty { PerfTrace.begin("back"); path.removeLast() } }
        )
    }

    /// Viewer subtitle per surface: player/text → `Tuning · TimeSig · tag`;
    /// PDF original → `PDF · tag`. Unknowns omitted, tags lowercase.
    private var headerSubtitle: String {
        var parts: [String] = []
        if isGuitarPro {
            parts.append("Guitar Pro")
        } else if isPDF && !usingDrawnPlayer {
            parts.append("PDF")
        } else if let map = measureMap {
            if let tuning = map.tuning { parts.append(tuning) }
            if let ts = map.timeSignature { parts.append("\(ts.beats)/\(ts.noteValue)") }
        }
        if let tag = file?.tags.first { parts.append(tag.lowercased()) }
        return parts.joined(separator: " · ")
    }

    private var headerDetailRows: [String] {
        guard let file else { return [] }
        var rows: [String] = [file.filename]
        if isGuitarPro {
            rows.append("Player: alphaTab 1.8.4 · MPL-2.0")
            rows.append("Source: github.com/CoderLine/alphaTab")
        }
        if let p = file.provenance {
            rows.append("Source: \(p.sourceType.rawValue)")
            rows.append("Converter v\(p.converterVersion)")
            rows.append("Confidence \(Int((p.confidence * 100).rounded()))%")
        }
        return rows
    }

    /// View switch: 0 = TabBuddy (drawn player), 1 = Original. Per-file sticky.
    private var viewSwitchSelection: Binding<Int> {
        Binding(
            get: { usingDrawnPlayer ? 0 : 1 },
            set: { idx in
                if idx == 0 { hasShownPlayer = true }
                file?.preferredTextMode = (idx == 0 ? TextViewMode.player : .original).rawValue
                ReaderPersistence.scheduleSave(context)
            }
        )
    }

    private func toggleFavorite() {
        guard let file else { return }
        let wasFavorite = file.isFavorite
        file.isFavorite.toggle()
        try? context.save()

        undoManager?.registerUndo(withTarget: context) { ctx in
            file.isFavorite = wasFavorite
            try? ctx.save()
        }
        undoManager?.setActionName(wasFavorite ? "Unfavorite File" : "Favorite File")
    }

    // MARK: - Confidence-gated fallback notice (DESIGN.md §7)

    /// Shown on the Original PDF render when a canonical exists but its
    /// extraction confidence is below the display threshold.
    private var showConfidenceNotice: Bool {
        guard let file, isPDF, !usingDrawnPlayer, !file.confidenceNoticeDismissed,
              file.hasCanonical, playerAvailable,
              let conf = file.provenance?.confidence else { return false }
        return conf < ViewerHeader.confidenceThreshold
    }

    private var confidenceNoticeCard: some View {
        let conf = file?.provenance?.confidence ?? 0
        return HStack(spacing: 10) {
            Text("\(Int((conf * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(DS.cautionSoft, in: Capsule())
                .foregroundStyle(DS.cautionText)
            Text("Showing the original — the TabBuddy version isn't stage-ready yet.")
                .font(.system(size: 13))
                .foregroundStyle(DS.fg2)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Review") {
                viewSwitchSelection.wrappedValue = 0
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.accentStrong)
            .buttonStyle(.plain)
            Button {
                file?.confidenceNoticeDismissed = true
                try? context.save()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.fg3)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusControl)
                .stroke(DS.separator, lineWidth: 1)
        )
    }

        // --------------------------------------------------------------------
        /// Binary Guitar Pro files use their dedicated offline player.
        private var isGuitarPro: Bool {
            GuitarProFileType.contains(file?.filename ?? "")
        }

        /// Whether the file is a PDF (governs the PDFKit fallback).
        private var isPDF: Bool {
            file?.filename.lowercased().hasSuffix(".pdf") == true
        }

        /// True when this tab *can* show the drawn player (parsed into at
        /// least one system). Text tabs parse directly; PDFs get a map from
        /// their canonical (spatial/notation extraction) once converted.
        /// Governs whether the View toggle is offered.
        private var playerAvailable: Bool {
            measureMap?.systems.isEmpty == false
        }

        /// The drawn Tab Player is used for a player-capable tab unless the user
        /// switched that tab to the raw "Original" text. PDFs keep their PDFKit
        /// render (per the standing preference) until native display matures.
        private var usingDrawnPlayer: Bool {
            playerAvailable && textMode == .player
        }

        /// Header subtitle: Tuning · Capo · Key · TimeSig, omitting unknowns.
        private var subtitleText: String {
            guard let map = measureMap else { return "" }
            var parts: [String] = []
            if let tuning = map.tuning { parts.append(tuning) }
            if let capo = map.capoSemitones, capo > 0 { parts.append("Capo \(capo)") }
            if let key = map.key, !key.isEmpty { parts.append(key) }
            if let ts = map.timeSignature { parts.append("\(ts.beats)/\(ts.noteValue)") }
            return parts.joined(separator: " · ")
        }

        /// The scroll transport backs every scrollable original render — the raw
        /// text view *and* the PDF view — i.e. anything that isn't the drawn
        /// player (which carries its own playback transport).
        private var showScrollTransport: Bool {
            !usingDrawnPlayer && !isGuitarPro
        }

        /// Shared transport for the Original file views (text + PDF): play =
        /// auto-scroll, speed slider in the middle zone, loop-to-top + Display.
        private var originalTransport: some View {
            OriginalTransportBar(
                scrollSpeed: $scrollSpeed,
                loopToTop: Binding(
                    get: { loopToTopText },
                    set: { on in
                        loopToTopText = on
                        coordinator.loopToTop = on
                        // Looping is meaningless with no scroll motion — give it a
                        // gentle default speed when turned on from a standstill.
                        if on && scrollSpeed == 0 { scrollSpeed = 8 }
                    }),
                onBackToTop: { scrollToTop() },
                displayContent: { originalDisplaySections }
            )
        }

        /// Display sections for the Original views (the transport owns the
        /// Form). Text tabs offer text size; PDFs have no text controls.
        @ViewBuilder
        private var originalDisplaySections: some View {
            if isPDF, let file {
                Section("Arrangement") {
                    Button(creatingArrangement ? "Creating arrangement…" : "Create guitar arrangement") {
                        creatingArrangement = true
                        Task { @MainActor in
                            let succeeded = await CanonicalConverter.shared.convert(file, context: context)
                            creatingArrangement = false
                            if succeeded { loadCanonicalMap() }
                            else { LibraryManager.shared.lastError = "Could not create a guitar arrangement from this score. The original is still available." }
                        }
                    }.disabled(creatingArrangement)
                    Text("Optional, approximate conversion. Your original sheet music stays unchanged.").font(.caption)
                }
            }
            if !isPDF {
                Section("Text") {
                    HStack {
                        Text("Size")
                        Spacer()
                        Button { fontSize = max(6, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                        Text("\(Int(fontSize))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button { fontSize = min(28, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                    }.buttonStyle(.borderless)
                }
            }
        }

        private func scrollToTop() {
            // The auto-scroll CADisplayLink rewrites contentOffset every frame, so
            // it would immediately cancel an animated jump. Pause it, jump, then
            // resume once the jump has settled.
            let wasAutoScrolling = isAutoScrolling
            stopAutoScroll()

            if let tv = textViewProxy {
                tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: -tv.adjustedContentInset.top), animated: true)
            }
            if let sv = scrollViewProxy {
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: -sv.adjustedContentInset.top), animated: true)
            }

            if wasAutoScrolling && scrollSpeed > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { startAutoScroll() }
            }
        }

        @ViewBuilder
        private var viewerBody: some View {
            if isGuitarPro {
                if let url = resolvedFileURL, let file {
                    GuitarProView(url: url, fileID: file.id, file: file).id(file.id)
                } else {
                    Text(textContent).padding()
                }
            } else {
                ZStack {
                    originalBody
                        .opacity(usingDrawnPlayer ? 0 : 1)
                        .allowsHitTesting(!usingDrawnPlayer)
                        .accessibilityHidden(usingDrawnPlayer)
                    if let map = measureMap, hasShownPlayer || usingDrawnPlayer {
                        TabPlayerView(map: map, file: file, subtitle: subtitleText,
                                      coordinator: playbackCoordinator, metronome: metronome,
                                      notePlayer: notePlayer, userBPM: $userBPM,
                                      preparedModel: preparedRenderModel, isActive: drawnPlayerActive)
                            // Mirrors TabPlayerView.configure(), which runs on the same events.
                            .onAppear { if drawnPlayerActive { captureDrawnReference() } }
                            .onChange(of: drawnPlayerActive) { _, active in if active { captureDrawnReference() } }
                            .opacity(usingDrawnPlayer ? 1 : 0)
                            .allowsHitTesting(usingDrawnPlayer)
                            .accessibilityHidden(!usingDrawnPlayer)
                    }
                }
                // Animate the segmented control, not two full score surfaces.
                .transaction { $0.animation = nil }
            }
        }

        @ViewBuilder
        private var originalBody: some View {
            if isPDF, renderMode == .canonical, file?.hasCanonical == true, let text = canonicalText {
                // PDF → standardized TabBuddy ASCII rendering (read-only).
                TabText(fontSize: $fontSize,
                        content: text,
                        textViewProxy: $textViewProxy,
                        highlightOverlay: nil,
                        onTapAtCharacter: nil)
                    .padding(.horizontal, 4)
            } else if isPDF {
                if let url = resolvedFileURL {
                    VStack(spacing: 0) {
                        if showConfidenceNotice {
                            confidenceNoticeCard
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                        }
                        TabPDFView(url: url, scrollViewProxy: $scrollViewProxy)
                            .padding()
                    }
                } else if let error = fileAccessError {
                    VStack(spacing: 12) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { resolveFile() }
                    }.padding()
                } else {
                    ProgressView("Opening PDF…")
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
                    Section {
                        TextField("Song name", text: $newName)
                            .autocorrectionDisabled()
                    } footer: {
                        if let f = file {
                            Text("Sets the display name in your library. The original file (\(f.filename)) is untouched.")
                        }
                    }
                }
                .navigationTitle("Rename")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: commitRename)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showRename = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }

        /// Sets a non-destructive display title; empty clears it (revert to filename).
        @MainActor
        private func commitRename() {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            file?.customTitle = trimmed.isEmpty ? nil : trimmed
            try? context.save()
            showRename = false
        }

    // MARK: - Practice (listening)

    /// The drawn player pauses while practice mode covers it; when practice
    /// closes it configures again and picks up a loop practice set, keeping
    /// its identity (scroll position, auto-scroll settings).
    private var drawnPlayerActive: Bool { usingDrawnPlayer && practiceContext == nil }

    private func captureDrawnReference() {
        guard let map = measureMap else { return }
        let reference = file?.referenceBPM ?? map.bpm ?? userBPM
        drawnReferenceBPM = reference > 0 ? reference : 120
    }

    /// Whether the open score yields expected notes, and if not, why.
    private var practiceStatus: PracticeToolState.Status {
        if isGuitarPro {
            guard let file, PracticeSourceRegistry.guitarPro(for: file.id)?.ready == true else {
                return .unavailable("The score is still loading. Try again in a moment.")
            }
            return .available
        }
        if let map = measureMap, !map.systems.isEmpty, map.resolvedOpenStringMIDI != nil { return .available }
        if pairedMIDI != nil { return .available }
        if measureMap?.systems.isEmpty == false {
            return .unavailable("This tab's tuning doesn't say which octave each string is in, so TabBuddy can't tell which pitches to listen for. A MIDI file with the same name beside it would work.")
        }
        if isPDF {
            return .unavailable("This PDF has no structured notes to listen for. Create a guitar arrangement (Settings → Arrangement), or keep a MIDI file with the same name beside the PDF.")
        }
        return .unavailable("No notes have been read from this tab yet.")
    }

    private func openPractice() {
        guard let file else { return }
        stopAutoScroll()
        playbackCoordinator.pause()
        metronome.stop()
        notePlayer.stop()
        let key = file.id.uuidString
        if isGuitarPro {
            guard let player = PracticeSourceRegistry.guitarPro(for: file.id), player.ready else { return }
            player.actions.pause()
            let track = player.selectedTrack
            var loop: ClosedRange<Int>?
            if player.loopEnabled, let a = player.loopStart, let b = player.loopEnd { loop = min(a, b)...max(a, b) }
            practiceContext = PracticeScoreContext(
                scoreKey: key, title: file.displayTitle,
                source: .alphaTab(track: track, export: { [weak player] in await player?.exportNotes() ?? [] }),
                totalMeasures: player.total,
                initialRange: loop ?? PracticeDefaults.span(from: player.coordinator.currentMeasureIndex, count: player.total),
                referenceBPM: nil,
                tempoPercent: player.coordinator.bpm / max(1, player.originalBPM) * 100,
                instrument: PracticeDefaults.instrument(trackInstrument: player.tracks.first { $0.id == track }?.instrument,
                                                        fileInstruments: file.instrumentKinds, isTablature: false),
                isBass: PracticeDefaults.isBass(trackInstrument: player.tracks.first { $0.id == track }?.instrument,
                                                fileInstruments: file.instrumentKinds, openStringMIDI: nil),
                applyToViewer: { [weak player] loop, percent in
                    guard let player else { return }
                    if let loop { player.loopEnabled = true; player.loopStart = loop.lowerBound; player.loopEnd = loop.upperBound }
                    if let percent {
                        let bpm = (player.originalBPM * percent / 100).rounded()
                        player.coordinator.bpm = bpm
                        player.userBPM = bpm
                    }
                    player.applyOptions()
                })
            return
        }
        if let map = measureMap, !map.systems.isEmpty, map.resolvedOpenStringMIDI != nil {
            // Same reference tempo as TabPlayerView's originalBPM.
            let reference = max(1, file.referenceBPM ?? map.bpm ?? drawnReferenceBPM ?? userBPM)
            var loop: ClosedRange<Int>?
            if let a = file.loopStartMeasure, let b = file.loopEndMeasure { loop = min(a, b)...max(a, b) }
            let model = preparedRenderModel.systems.isEmpty ? TabRenderModelBuilder.build(from: map) : preparedRenderModel
            practiceContext = PracticeScoreContext(
                scoreKey: key, title: file.displayTitle, source: .measureMap(map, model),
                totalMeasures: map.measureCount,
                initialRange: loop ?? PracticeDefaults.systemRange(containing: playbackCoordinator.currentMeasureIndex, in: map),
                referenceBPM: reference, tempoPercent: userBPM / reference * 100,
                instrument: PracticeDefaults.instrument(trackInstrument: nil, fileInstruments: file.instrumentKinds,
                                                        isTablature: true),
                isBass: PracticeDefaults.isBass(trackInstrument: nil, fileInstruments: file.instrumentKinds,
                                                openStringMIDI: map.resolvedOpenStringMIDI),
                applyToViewer: { loop, percent in
                    if let loop {
                        // The drawn player reads the loop when practice closes.
                        file.loopStartMeasure = loop.lowerBound
                        file.loopEndMeasure = loop.upperBound
                        ReaderPersistence.scheduleSave(context)
                    }
                    if let percent {
                        // Without a stored reference the player would take the new
                        // BPM as its 100% when it configures again; keep the one
                        // it showed so the percentage stays true.
                        if file.referenceBPM == nil && map.bpm == nil {
                            file.referenceBPM = reference
                            ReaderPersistence.scheduleSave(context)
                        }
                        userBPM = (reference * percent / 100).rounded()
                        playbackCoordinator.bpm = userBPM
                    }
                })
            return
        }
        if let midi = pairedMIDI {
            let reference = max(1, midi.initialBPM)
            practiceContext = PracticeScoreContext(
                scoreKey: key, title: file.displayTitle,
                source: .midi(load: { await Self.copyPairedMIDI(for: file) }),
                totalMeasures: 0, initialRange: nil, referenceBPM: nil,
                tempoPercent: userBPM / reference * 100,
                instrument: PracticeDefaults.instrument(trackInstrument: nil, fileInstruments: file.instrumentKinds,
                                                        isTablature: false),
                isBass: PracticeDefaults.isBass(trackInstrument: nil, fileInstruments: file.instrumentKinds,
                                                openStringMIDI: nil),
                applyToViewer: { _, percent in
                    guard let percent else { return }
                    userBPM = (reference * percent / 100).rounded()
                    playbackCoordinator.bpm = userBPM
                })
        }
    }

    /// Copies the sibling MIDI file to a temporary file while holding the score's access lease.
    private static func copyPairedMIDI(for file: FileItem) async -> URL? {
        guard let lease = try? await LibraryManager.shared.acquireFile(file) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            defer { lease.close() }
            guard let source = MIDITempoExtractor.findPairedMIDI(for: lease.url) else { return nil }
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("practice-\(UUID().uuidString).mid")
            return (try? FileManager.default.copyItem(at: source, to: copy)) == nil ? nil : copy
        }.value
    }

    // MARK: - Playback Integration

    private func setupPlaybackCallbacks() {
        guard !isGuitarPro else { return }
        // Parse tab for text files
        if !isPDF {
            parseTextTab()
        }

        loadPairedMIDI()

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
                player.playNotes(notes[0].frets, tuningMIDI: measureMap?.resolvedOpenStringMIDI?.map { $0 + (measureMap?.capoSemitones ?? 0) } ?? [])
            } else {
                // Merge frets from all notes — latest position wins on conflict
                var merged: [Int?] = Array(repeating: nil, count: notes.map { $0.frets.count }.max() ?? 0)
                for note in notes.sorted(by: { $0.positionInMeasure < $1.positionInMeasure }) {
                    for (i, fret) in note.frets.enumerated() {
                        if let f = fret { merged[i] = f }
                    }
                }
                player.playNotes(merged, tuningMIDI: measureMap?.resolvedOpenStringMIDI?.map { $0 + (measureMap?.capoSemitones ?? 0) } ?? [])
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

    /// Load + cache the canonical's ASCII rendering from the stored MusicXML.
    private func loadCanonicalText() { loadCanonicalPresentation() }

    private func loadCanonicalMap() { loadCanonicalPresentation() }

    private func loadPairedMIDI() {
        midiLoadTask?.cancel()
        guard let file else { return }
        midiLoadTask = Task {
            // The worker retains its own security scope even if the viewer closes.
            guard let lease = try? await LibraryManager.shared.acquireFile(file) else { return }
            guard !Task.isCancelled else { lease.close(); return }
            let work = Task.detached(priority: .utility) {
                defer { lease.close() }
                guard !Task.isCancelled,
                      let url = MIDITempoExtractor.findPairedMIDI(for: lease.url),
                      !Task.isCancelled else { return nil as MIDITempoData? }
                return MIDITempoExtractor.extract(from: url)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let result else { return }
            pairedMIDI = result
            if file.userBPM == nil {
                userBPM = result.initialBPM
                playbackCoordinator.bpm = result.initialBPM
            }
            if measureMap?.timeSignature == nil { measureMap?.timeSignature = result.timeSignature }
        }
    }

    private func loadCanonicalPresentation() {
        guard let file, file.hasCanonical, let filename = file.canonicalFilename else { return }
        let key = "\(filename):\(file.canonicalVersion)"
        guard canonicalLoadedKey != key else { return }
        canonicalLoadTask?.cancel()
        canonicalLoadTask = Task {
            let work = Task.detached(priority: .userInitiated) { () -> (String, MeasureMap, TabRenderModel, Double?)? in
                guard let data = CanonicalStore.read(filename: filename),
                      let canonical = MusicXMLCodec.decode(data) else { return nil }
                let map = CanonicalAdapters.measureMap(from: canonical)
                return (CanonicalAdapters.asciiTab(from: canonical), map,
                        TabRenderModelBuilder.build(from: map), canonical.bpm)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let result else { return }
            canonicalLoadedKey = key
            canonicalText = result.0
            if isPDF && !result.1.systems.isEmpty {
                preparedRenderModel = result.2
                measureMap = result.1
                playbackCoordinator.measureMap = result.1
                if file.userBPM == nil, let bpm = pairedMIDI?.initialBPM ?? result.3 {
                    userBPM = bpm
                    playbackCoordinator.bpm = bpm
                }
            }
        }
    }

    private func parseTextTab() {
        textParseTask?.cancel()
        guard !textContent.isEmpty, textContent != "Loading…", let item = file else { return }
        let text = textContent
        let title = item.displayTitle
        textParseTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                let parsed = TabParser.parse(text)
                let inference = FileItem.inferredMetadata(from: title + "\n" + text.components(separatedBy: "\n").prefix(128).joined(separator: "\n"))
                return (parsed, inference, EmbeddedScoreMetadata.parseHeader(text), TabRenderModelBuilder.build(from: parsed))
            }
            let (parsed, inference, metadata, renderModel) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, item.modelContext != nil, !item.isDeleted, textContent == text else { return }
            preparedRenderModel = renderModel
            var map = parsed
            if map.timeSignature == nil { map.timeSignature = pairedMIDI?.timeSignature }
            measureMap = map
            playbackCoordinator.measureMap = parsed
            if item.userBPM == nil, let bpm = pairedMIDI?.initialBPM ?? parsed.bpm {
                userBPM = bpm
                playbackCoordinator.bpm = bpm
            }
            item.applyInferredMetadata(inference)
            if let metadata { item.applyEmbeddedMetadata(metadata) }
            if !item.metadataEdited && item.tuning == nil { item.tuning = parsed.tuning }
            ReaderPersistence.scheduleSave(context)
            CanonicalConverter.shared.convertOnOpen(item, context: context, prebuilt: (parsed, .txtDirect))
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

/// Tells a real departure from the viewer apart from a presentation that
/// covers it (a full-screen cover also fires `onDisappear`).
enum TabViewerLifecycle {
    struct Session: Equatable {
        /// Navigation depth when the viewer first appeared.
        var depth: Int

        /// True while the viewer is still the top page at its own depth.
        func isCovered(path: [AppPage]) -> Bool {
            path.count == depth && path.last == .viewer
        }
    }
}
