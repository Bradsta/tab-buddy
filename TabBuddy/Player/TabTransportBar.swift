//
//  TabTransportBar.swift
//  TabBuddy
//
//  The one transport (DESIGN.md §5). Three fixed zones — [play cluster]
//  [position] [tools] — shared by the drawn Tab Player (playback), the
//  Original text/PDF views (auto-scroll; `OriginalTransportBar` below), and
//  the Tab Maker. Only the middle zone's meaning changes per surface.
//
//  Engine wiring is unchanged: the bar drives `PlaybackCoordinator` and the
//  engines; rendering-specific concerns stay in the host behind the
//  `onLoopChanged` / `onSeek` / `onBeforePlay` hooks.
//
//  Hosts supply Display-popover content as Form *sections* (no Form wrapper) —
//  on iPhone the bar adds its own absorbed controls (Sound, Count-in) above.
//

import SwiftUI

// MARK: - Shared transport primitives (DESIGN.md §5 control anatomy)

/// Bar container: BarTint material, top hairline, standard padding.
struct TransportChrome<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(BarMaterial())
            .overlay(alignment: .top) { Hairline() }
    }
}

/// The Play circle: accent fill, white glyph, soft accent shadow.
struct PlayCircleButton: View {
    @Environment(\.horizontalSizeClass) private var hSize
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        let d = hSize == .compact ? DS.playDiameterCompact : DS.playDiameter
        Button(action: action) {
            ZStack {
                Circle().fill(DS.accent)
                    .frame(width: d, height: d)
                    .shadow(color: DS.accent.opacity(0.34), radius: 8, y: 4)
                Image(systemName: isOn ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 44×44 icon tile (38 on iPhone), radius 11; label under it on iPad only.
struct TransportTileLabel: View {
    @Environment(\.horizontalSizeClass) private var hSize
    var icon: String
    var label: String
    var active: Bool

    var body: some View {
        let side = hSize == .compact ? DS.tileCompact : DS.tile
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: side, height: side)
                .background(active ? AnyShapeStyle(DS.accent) : AnyShapeStyle(DS.surfaceInset),
                            in: RoundedRectangle(cornerRadius: DS.radiusControl))
                .foregroundStyle(active ? Color.white : DS.fg1)
            if hSize != .compact {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? DS.accent : DS.fg2)
            }
        }
    }
}

struct TransportTile: View {
    var icon: String
    var label: String
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            TransportTileLabel(icon: icon, label: label, active: active)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Tempo pill: AccentSoft fill, AccentStrong content, percent as its label.
struct TempoPillLabel: View {
    @Environment(\.horizontalSizeClass) private var hSize
    var bpm: Int
    var percent: Int
    /// Overrides the percent sub-label (the maker shows "tempo" instead).
    var subLabel: String? = nil

    var body: some View {
        let h = hSize == .compact ? DS.tileCompact : DS.tile
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "music.note").font(.callout)
                Text("\(bpm)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .frame(height: h)
            .background(DS.accentSoft, in: Capsule())
            .foregroundStyle(DS.accentStrong)
            if hSize != .compact {
                Text(subLabel ?? "\(percent)%")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.fg2)
            }
        }
    }
}

/// Readout: mono value line + smaller sub-line (accent-tinted when looping).
struct TransportReadout: View {
    var value: String
    var sub: String
    var subAccented: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.fg1)
            Text(sub)
                .font(.system(size: 12))
                .foregroundStyle(subAccented ? DS.accent : DS.fg2)
                .monospacedDigit()
        }
    }
}

/// Token scrubber: 4pt track, accent fill, 22pt raised thumb. One component
/// for measure position and scroll speed.
struct TokenScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let frac = CGFloat((value - range.lowerBound) / span)
            let x = 11 + max(0, min(1, frac)) * (w - 22)
            ZStack(alignment: .leading) {
                Capsule().fill(DS.separatorStrong).frame(height: 4)
                Capsule().fill(DS.accent).frame(width: x, height: 4)
                Circle()
                    .fill(DS.surfaceRaised)
                    .overlay(Circle().stroke(DS.separator, lineWidth: 0.5))
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .position(x: x, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = max(0, min(1, (g.location.x - 11) / max(1, w - 22)))
                        var v = range.lowerBound + Double(f) * span
                        if step > 0 { v = (v / step).rounded() * step }
                        value = min(range.upperBound, max(range.lowerBound, v))
                    }
            )
        }
        .frame(height: 44)
    }
}

// MARK: - Player transport

struct TabTransportBar<Display: View>: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    @ObservedObject var metronome: MetronomeEngine
    @ObservedObject var notePlayer: NotePlaybackEngine
    @Binding var userBPM: Double

    let originalBPM: Double
    let totalMeasures: Int
    let beatsPerMeasure: Int

    @Binding var loopEnabled: Bool
    @Binding var loopStart: Int?
    @Binding var loopEnd: Int?

    /// Host applies the loop to the coordinator, persists it, and resets any
    /// rendering state (e.g. the drawn scroll lock) after the bar mutates it.
    var onLoopChanged: () -> Void = {}

    /// Host persists the user-declared song tempo and updates originalBPM.
    var onSetReferenceBPM: (Double) -> Void = { _ in }
    /// Host hook on a seek/skip (e.g. stop notes, reset text scroll tracking).
    var onSeek: () -> Void = {}
    /// Host hook just before playback starts (e.g. force text layout).
    var onBeforePlay: () -> Void = {}

    /// Display-popover content as Form sections (the bar owns the Form).
    @ViewBuilder var displayContent: () -> Display

    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage("player.autoScroll") private var autoScrollRaw = AutoScrollMode.follow.rawValue
    @AppStorage("player.countInBars") private var countInBars = 0

    @State private var showTempo = false
    @State private var refBPMText = ""
    @FocusState private var refBPMFocused: Bool
    @State private var showDisplay = false
    @State private var rampEnabled = false
    @State private var trainerPass = 0
    @State private var countingIn = false
    @State private var countInTask: Task<Void, Never>?

    private var autoScroll: AutoScrollMode { AutoScrollMode(rawValue: autoScrollRaw) ?? .follow }
    private var tempoPercent: Int { max(1, Int((coordinator.bpm / max(1, originalBPM)) * 100 + 0.5)) }
    private var isCompact: Bool { hSize == .compact }

    /// Surfaced so a host can mirror the count-in state into its playhead.
    var isCountingIn: Bool { countingIn }

    var body: some View {
        TransportChrome {
            if isCompact {
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        playCluster
                        Spacer(minLength: 6)
                        tempoControl
                        control(icon: "metronome", label: "Metronome", active: metronome.isEnabled) {
                            metronome.isEnabled.toggle()
                        }
                        control(icon: "repeat", label: "Loop", active: loopEnabled) { toggleLoop() }
                        displayControl
                    }
                    scrubber
                }
            } else {
                HStack(spacing: 16) {
                    playCluster
                    scrubber
                    HStack(spacing: 12) {
                        tempoControl
                        control(icon: notePlayer.isEnabled ? "speaker.wave.2.fill" : "speaker.slash",
                                label: "Sound", active: notePlayer.isEnabled) { toggleSound() }
                        control(icon: "metronome", label: "Metronome", active: metronome.isEnabled) {
                            metronome.isEnabled.toggle()
                        }
                        countInControl
                        control(icon: "repeat", label: "Loop", active: loopEnabled) { toggleLoop() }
                        control(icon: autoScrollIcon, label: "Follow", active: autoScroll != .off) {
                            cycleAutoScroll()
                        }
                        displayControl
                    }
                }
            }
        }
        .onAppear {
            // Speed trainer: bump tempo each completed loop pass, capped at 100%.
            coordinator.onLoopCompleted = {
                guard rampEnabled else { return }
                setTempoPercent(min(100, tempoPercent + 5))
                trainerPass += 1
            }
        }
    }

    // MARK: Zones

    private var playCluster: some View {
        HStack(spacing: 12) {
            Button { skip() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.body)
                    .foregroundStyle(DS.fg1)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            PlayCircleButton(isOn: coordinator.isPlaying || countingIn) { togglePlay() }

            TransportReadout(
                value: "m. \(coordinator.currentMeasureIndex + 1)/\(max(1, totalMeasures))",
                sub: readout,
                subAccented: loopEnabled
            )
        }
    }

    private var readout: String {
        if countingIn { return "count-in…" }
        if loopEnabled { return "Loop · pass \(trainerPass + 1)" }
        let secs = coordinator.bpm > 0 ? coordinator.accumulatedBeats * 60.0 / coordinator.bpm : 0
        return minimalTime(secs)
    }

    private var scrubber: some View {
        TokenScrubber(
            value: Binding(
                get: { Double(coordinator.currentMeasureIndex) },
                set: { onSeek(); coordinator.seekToMeasure(Int($0.rounded())) }
            ),
            range: 0...Double(max(1, totalMeasures - 1))
        )
        .frame(minWidth: 120, maxWidth: .infinity)
    }

    private var tempoControl: some View {
        Button { showTempo = true } label: {
            TempoPillLabel(bpm: Int(coordinator.bpm), percent: tempoPercent)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTempo) {
            tempoPopover.presentationCompactAdaptation(.popover)
        }
    }

    private var countInControl: some View {
        Menu {
            Picker("Count-in", selection: $countInBars) {
                Text("Off").tag(0)
                Text("1 bar").tag(1)
                Text("2 bars").tag(2)
            }
        } label: {
            TransportTileLabel(icon: countInBars == 0 ? "number" : "\(countInBars).circle",
                               label: "Count-in", active: countInBars > 0)
        }
    }

    private var displayControl: some View {
        control(icon: "slider.horizontal.3", label: "Display", active: false) {
            showDisplay = true
        }
        .popover(isPresented: $showDisplay) {
            displayPopover.presentationCompactAdaptation(.popover)
        }
    }

    /// The Display popover. On iPhone it absorbs the controls that lost their
    /// tiles: Sound and Count-in (Follow already lives in the host sections).
    private var displayPopover: some View {
        Form {
            if isCompact {
                Section("Playback") {
                    Toggle("Sound", isOn: Binding(
                        get: { notePlayer.isEnabled },
                        set: { _ in toggleSound() }))
                    Picker("Count-in", selection: $countInBars) {
                        Text("Off").tag(0)
                        Text("1 bar").tag(1)
                        Text("2 bars").tag(2)
                    }
                }
            }
            displayContent()
        }
        .frame(minWidth: 320, minHeight: 420)
    }

    private func control(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        TransportTile(icon: icon, label: label, active: active, action: action)
    }

    private var autoScrollIcon: String {
        switch autoScroll {
        case .off: return "arrow.down.circle"
        case .follow: return "arrow.down"
        case .line: return "arrow.down.to.line"
        }
    }

    // MARK: Actions

    private func toggleSound() {
        notePlayer.isEnabled.toggle()
        // If turned on mid-playback, make sure the engine is running.
        if notePlayer.isEnabled && (coordinator.isPlaying || countingIn) {
            notePlayer.start()
        }
    }

    private func togglePlay() {
        if coordinator.isPlaying || countingIn { stopPlayback() } else { startPlayback() }
    }

    private func startPlayback() {
        onBeforePlay()
        metronome.start()
        if notePlayer.isEnabled { notePlayer.start() }
        if countInBars > 0 { runCountIn { coordinator.play() } } else { coordinator.play() }
    }

    private func stopPlayback() {
        countInTask?.cancel(); countingIn = false
        coordinator.pause()
        metronome.stop()
        notePlayer.stop()
    }

    private func skip() {
        onSeek()
        coordinator.seekToMeasure(loopEnabled ? (loopStart ?? 0) : 0)
    }

    private func runCountIn(_ then: @escaping () -> Void) {
        countInTask?.cancel()
        countingIn = true
        let beats = max(1, countInBars) * beatsPerMeasure
        let interval = UInt64((60.0 / max(1, coordinator.bpm)) * 1_000_000_000)
        countInTask = Task { @MainActor in
            for b in 0..<beats {
                if Task.isCancelled { countingIn = false; return }
                metronome.playClick(beatInMeasure: b % beatsPerMeasure, beatsPerMeasure: beatsPerMeasure)
                try? await Task.sleep(nanoseconds: interval)
            }
            if Task.isCancelled { countingIn = false; return }
            countingIn = false
            then()
        }
    }

    private func cycleAutoScroll() {
        switch autoScroll {
        case .off: autoScrollRaw = AutoScrollMode.follow.rawValue
        case .follow: autoScrollRaw = AutoScrollMode.line.rawValue
        case .line: autoScrollRaw = AutoScrollMode.off.rawValue
        }
    }

    private func toggleLoop() {
        loopEnabled.toggle()
        if loopEnabled, loopStart == nil || loopEnd == nil {
            let cur = coordinator.currentMeasureIndex
            loopStart = cur
            loopEnd = min(totalMeasures - 1, cur + 1)
        }
        onLoopChanged()
    }

    private func setTempoPercent(_ pct: Int) {
        let bpm = (originalBPM * Double(pct) / 100).rounded()
        coordinator.bpm = bpm
        userBPM = bpm
    }

    // MARK: Speed-trainer popover

    private var tempoPopover: some View {
        Form {
            Section {
                HStack {
                    Text("Song tempo").fontWeight(.semibold)
                    Spacer()
                    Button {
                        applyReferenceBPM(originalBPM - 5)
                    } label: { Image(systemName: "minus.circle").font(.title3) }
                        .buttonStyle(.borderless)
                    TextField("BPM", text: $refBPMText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .focused($refBPMFocused)
                        .monospacedDigit()
                    Button {
                        applyReferenceBPM(originalBPM + 5)
                    } label: { Image(systemName: "plus.circle").font(.title3) }
                        .buttonStyle(.borderless)
                    Text("BPM").foregroundStyle(DS.fg2)
                }
            } footer: {
                Text("The song's real tempo — set it here when the tab doesn't list one. Practice speed is relative to it.")
            }
            Section {
                HStack {
                    Text("Practice speed").fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(coordinator.bpm)) / \(Int(originalBPM)) BPM")
                        .foregroundStyle(DS.fg2).monospacedDigit()
                }
                Slider(
                    value: Binding(get: { coordinator.bpm }, set: { coordinator.bpm = $0; userBPM = $0 }),
                    in: max(30, originalBPM * 0.25)...max(60, originalBPM),
                    step: 1
                )
                .tint(DS.accent)
                HStack {
                    ForEach([50, 75, 90, 100], id: \.self) { pct in
                        Button { setTempoPercent(pct) } label: {
                            Text("\(pct)%").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(tempoPercent == pct ? DS.accent : nil)
                    }
                }
            }
            Section {
                Toggle(isOn: $rampEnabled) {
                    VStack(alignment: .leading) {
                        Text("Ramp up each loop")
                        Text("+5% → 100% over successive passes")
                            .font(.caption).foregroundStyle(DS.fg2)
                    }
                }
                .disabled(!loopEnabled)
            } footer: {
                if !loopEnabled { Text("Enable a loop to use the speed trainer.") }
            }
        }
        .frame(minWidth: 320, minHeight: 380)
        .onAppear { refBPMText = "\(Int(originalBPM))" }
        .onChange(of: originalBPM) { refBPMText = "\(Int($0))" }
        .onChange(of: refBPMFocused) { focused in
            if !focused { commitRefBPMText() }
        }
        .onSubmit { commitRefBPMText() }
    }

    /// Parse the typed song tempo and apply it (called on focus loss/submit).
    private func commitRefBPMText() {
        guard let typed = Double(refBPMText.trimmingCharacters(in: .whitespaces)),
              typed != originalBPM else {
            refBPMText = "\(Int(originalBPM))"
            return
        }
        applyReferenceBPM(typed)
    }

    /// Declare the song's true tempo: play at it (100%) and let the host persist it.
    private func applyReferenceBPM(_ value: Double) {
        let clamped = max(20, min(400, value.rounded()))
        refBPMText = "\(Int(clamped))"
        coordinator.bpm = clamped
        userBPM = clamped
        onSetReferenceBPM(clamped)
    }
}

// MARK: - Originals transport (text + PDF)

/// The same transport grammar for the Original text and PDF views: play means
/// auto-scroll, the middle zone is the speed slider, tools are loop-to-top and
/// Display. Replaces the old ScrollTransportBar; text and PDF are identical.
struct OriginalTransportBar<Display: View>: View {
    @Binding var scrollSpeed: CGFloat
    @Binding var loopToTop: Bool
    var onBackToTop: () -> Void
    /// Display sections from the host (text size for text tabs; PDFs pass none).
    @ViewBuilder var displayContent: () -> Display

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showDisplay = false
    /// Speed to restore when play is tapped after a pause.
    @State private var resumeSpeed: CGFloat = 8

    private var scrolling: Bool { scrollSpeed > 0 }
    private var isCompact: Bool { hSize == .compact }

    var body: some View {
        TransportChrome {
            if isCompact {
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        playCluster
                        Spacer(minLength: 6)
                        tools
                    }
                    speedSlider
                }
            } else {
                HStack(spacing: 16) {
                    playCluster
                    speedSlider
                    tools
                }
            }
        }
    }

    private var playCluster: some View {
        HStack(spacing: 12) {
            Button { onBackToTop() } label: {
                Image(systemName: "arrow.up.to.line")
                    .font(.body)
                    .foregroundStyle(DS.fg1)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            PlayCircleButton(isOn: scrolling) { togglePlay() }

            TransportReadout(
                value: scrolling ? "\(Int(scrollSpeed)) px/s" : "Paused",
                sub: loopToTop ? "loop to top" : "scroll",
                subAccented: loopToTop
            )
        }
    }

    private var speedSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 15))
                .foregroundStyle(DS.fg2)
            TokenScrubber(
                value: Binding(get: { Double(scrollSpeed) }, set: { scrollSpeed = CGFloat($0) }),
                range: 0...40
            )
            .frame(minWidth: 120, maxWidth: .infinity)
        }
    }

    private var tools: some View {
        HStack(spacing: 12) {
            TransportTile(icon: "repeat", label: "Loop to top", active: loopToTop) {
                loopToTop.toggle()
            }
            TransportTile(icon: "slider.horizontal.3", label: "Display", active: false) {
                showDisplay = true
            }
            .popover(isPresented: $showDisplay) {
                Form {
                    displayContent()
                    Section("Scrolling") {
                        Toggle("Loop to top", isOn: $loopToTop)
                    }
                }
                .frame(minWidth: 300, minHeight: 220)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func togglePlay() {
        if scrolling {
            resumeSpeed = scrollSpeed
            scrollSpeed = 0
        } else {
            scrollSpeed = max(8, resumeSpeed)
        }
    }
}
