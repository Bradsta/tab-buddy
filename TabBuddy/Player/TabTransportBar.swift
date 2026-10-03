//
//  TabTransportBar.swift
//  TabBuddy
//
//  The one transport (DESIGN.md §5). Three fixed zones — [play cluster]
//  [position] [tools] — shared by the drawn Tab Player (playback), the
//  Original text/PDF views (auto-scroll; `OriginalTransportBar` below), and
//  the Tab Maker. Only the middle zone's meaning changes per surface.
//
//  TabBuddy and Guitar Pro use this exact native transport. Guitar Pro
//  supplies PlayerPlaybackActions; PlaybackCoordinator mirrors its position
//  without starting another clock. Both hosts add format-specific Settings
//  sections beneath shared sound, metronome, and count-in controls.
//

import AVFoundation
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
        .accessibilityLabel(isOn ? "Pause" : "Play")
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
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "On" : "Off")
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
    var accessibilityValueOffset: Double = 1

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
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int(value + accessibilityValueOffset))")
        .accessibilityAdjustableAction { direction in
            let delta = max(1, step) * (direction == .increment ? 1 : -1)
            value = min(range.upperBound, max(range.lowerBound, value + delta))
        }
    }
}

/// Optional engine adapter: the shared transport never runs a second clock.
struct PlayerPlaybackActions {
    var play: () -> Void
    var pause: () -> Void
    var seek: (Int) -> Void
    var sound: (Bool) -> Void
    var tempo: (Double) -> Void
    var metronome: (Bool) -> Void
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
    var externalPlayback: PlayerPlaybackActions? = nil
    var isReady: Bool = true
    var elapsedSeconds: Double? = nil
    var allowsReferenceTempoEditing: Bool = true

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
    @AppStorage("player.countInBars") private var countInBars = 0

    @Environment(\.scenePhase) private var scenePhase
    @State private var showLoop = false
    @State private var showTempo = false
    @State private var refBPMText = ""
    @FocusState private var refBPMFocused: Bool
    @State private var showDisplay = false
    @State private var rampEnabled = false
    @State private var trainerPass = 0
    @State private var countingIn = false
    @State private var countInTask: Task<Void, Never>?

    private var tempoPercent: Int { max(1, Int((coordinator.bpm / max(1, originalBPM)) * 100 + 0.5)) }
    private var isCompact: Bool { hSize == .compact }

    /// Surfaced so a host can mirror the count-in state into its playhead.
    var isCountingIn: Bool { countingIn }

    var body: some View {
        TransportChrome {
            if isCompact {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        playCluster
                        Spacer(minLength: 0)
                        tempoControl
                        loopControl
                        displayControl
                    }
                    // Practice sits beside the flexible scrubber so the top row
                    // keeps its width in Slide Over.
                    HStack(spacing: 12) {
                        positionReadout
                        scrubber
                        PracticeToolButton()
                    }
                }
            } else {
                HStack(spacing: 16) {
                    playCluster
                    scrubber
                    tempoControl
                    loopControl
                    PracticeToolButton()
                    displayControl
                }
            }
        }
        .disabled(!isReady || totalMeasures == 0)
        .onChange(of: coordinator.bpm) { externalPlayback?.tempo($0) }
        .onChange(of: metronome.isEnabled) { externalPlayback?.metronome($0) }
        .onChange(of: scenePhase) { if $0 != .active { stopPlayback() } }
        // A call, Siri, unplugged headphones, or an engine reconfiguration stops the
        // audio engines; stop the transport too rather than run a silent playhead.
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began { stopPlayback() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            if reason == .oldDeviceUnavailable { stopPlayback() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)) { _ in
            if coordinator.isPlaying || countingIn { stopPlayback() }
        }
        .onDisappear {
            stopPlayback()
            coordinator.onLoopCompleted = nil
        }
        .onAppear {
            // Speed trainer: bump tempo each completed loop pass, capped at 100%.
            coordinator.onLoopCompleted = {
                trainerPass += 1
                guard rampEnabled, tempoPercent < 100 else { return }
                setTempoPercent(min(100, tempoPercent + 5))
            }
        }
    }

    // MARK: Zones

    private var playCluster: some View {
        HStack(spacing: isCompact ? 6 : 12) {
            Button { skip() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.body)
                    .foregroundStyle(DS.fg1)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restart")

            PlayCircleButton(isOn: coordinator.isPlaying || countingIn) { togglePlay() }

            if !isCompact { positionReadout }
        }
    }

    private var positionReadout: some View {
        TransportReadout(
            value: "Bar \(coordinator.currentMeasureIndex + 1)/\(max(1, totalMeasures))",
            sub: readout,
            subAccented: loopEnabled
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private var readout: String {
        if countingIn { return "count-in…" }
        if loopEnabled { return "Loop \((loopStart ?? 0) + 1)–\((loopEnd ?? 0) + 1) · pass \(trainerPass + 1)" }
        let secs = elapsedSeconds ?? (coordinator.bpm > 0 ? coordinator.accumulatedBeats * 60.0 / coordinator.bpm : 0)
        return minimalTime(secs)
    }

    private var scrubber: some View {
        TokenScrubber(
            value: Binding(
                get: { Double(coordinator.currentMeasureIndex) },
                set: { seek(Int($0.rounded())) }
            ),
            range: 0...Double(max(0, totalMeasures - 1))
        )
        .frame(minWidth: 80, maxWidth: .infinity)
        .accessibilityLabel("Bar")
    }

    private var tempoControl: some View {
        Button { showTempo = true } label: {
            TempoPillLabel(bpm: Int(coordinator.bpm), percent: tempoPercent)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("Practice speed")
        .accessibilityValue("\(tempoPercent) percent")
        .popover(isPresented: $showTempo) {
            tempoPopover.presentationCompactAdaptation(.popover)
        }
    }

    private var displayControl: some View {
        control(icon: "slider.horizontal.3", label: "Settings", active: false) {
            showDisplay = true
        }
        .popover(isPresented: $showDisplay) {
            displayPopover.presentationCompactAdaptation(.popover)
        }
    }

    /// One Settings panel on both size classes, with format-specific sections.
    private var displayPopover: some View {
        Form {
            Section("Playback") {
                Toggle("Sound", isOn: Binding(get: { notePlayer.isEnabled }, set: { _ in toggleSound() }))
                Toggle("Metronome", isOn: $metronome.isEnabled)
                Picker("Count-in", selection: $countInBars) {
                    Text("Off").tag(0)
                    Text("1 bar").tag(1)
                    Text("2 bars").tag(2)
                }
            }
            displayContent()
        }
        .frame(minWidth: 320, minHeight: 420)
    }

    private func control(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        TransportTile(icon: icon, label: label, active: active, action: action)
    }

    // MARK: Actions

    private func toggleSound() {
        notePlayer.isEnabled.toggle()
        if let externalPlayback { externalPlayback.sound(notePlayer.isEnabled); return }
        // If turned on mid-playback, make sure the engine is running.
        if !notePlayer.isEnabled {
            notePlayer.stop()
        } else if coordinator.isPlaying || countingIn {
            notePlayer.start()
        }
    }

    private func togglePlay() {
        if coordinator.isPlaying || countingIn { stopPlayback() } else { startPlayback() }
    }

    private func startPlayback() {
        guard isReady, totalMeasures > 0 else { return }
        onBeforePlay()
        if externalPlayback == nil {
            metronome.start()
            if notePlayer.isEnabled { notePlayer.start() }
        } else if countInBars > 0 { metronome.start() }
        let start = {
            if let externalPlayback { metronome.stop(); externalPlayback.play() }
            else { coordinator.play() }
        }
        if countInBars > 0 { runCountIn(start) } else { start() }
    }

    private func stopPlayback() {
        countInTask?.cancel(); countingIn = false
        if let externalPlayback { externalPlayback.pause() } else { coordinator.pause() }
        metronome.stop()
        notePlayer.stop()
    }

    private func seek(_ measure: Int) {
        onSeek()
        let clamped = max(0, min(max(0, totalMeasures - 1), measure))
        if let externalPlayback { externalPlayback.seek(clamped) }
        else { coordinator.seekToMeasure(clamped) }
    }

    private func skip() {
        seek(loopEnabled ? (loopStart ?? 0) : 0)
    }

    private func runCountIn(_ then: @escaping () -> Void) {
        countInTask?.cancel()
        countingIn = true
        let meter = max(1, beatsPerMeasure)
        let beats = max(1, countInBars) * meter
        let interval = UInt64((60.0 / max(1, coordinator.bpm)) * 1_000_000_000)
        countInTask = Task { @MainActor in
            // A cancelled task must not touch countingIn: stopPlayback/runCountIn own it,
            // and a newer count-in may already be running when this one wakes.
            for b in 0..<beats {
                if Task.isCancelled { return }
                metronome.playClick(beatInMeasure: b % meter, beatsPerMeasure: meter, force: true)
                try? await Task.sleep(nanoseconds: interval)
            }
            if Task.isCancelled { return }
            countingIn = false
            then()
        }
    }

    private var loopControl: some View {
        control(icon: "repeat", label: "Loop", active: loopEnabled) { showLoop = true }
            .popover(isPresented: $showLoop) {
                Form {
                    Section {
                        Toggle("Repeat section", isOn: Binding(get: { loopEnabled }, set: { enabled in
                            loopEnabled = enabled
                            if loopStart == nil || loopEnd == nil {
                                loopStart = coordinator.currentMeasureIndex
                                loopEnd = min(totalMeasures - 1, coordinator.currentMeasureIndex + 1)
                            }
                            onLoopChanged()
                        }))
                        Stepper("From bar \((loopStart ?? 0) + 1)", value: loopBound(isStart: true), in: 1...max(1, totalMeasures))
                        Stepper("To bar \((loopEnd ?? 0) + 1)", value: loopBound(isStart: false), in: 1...max(1, totalMeasures))
                        Button("Start at current bar") { loopBound(isStart: true).wrappedValue = coordinator.currentMeasureIndex + 1 }
                        Button("End at current bar") { loopBound(isStart: false).wrappedValue = coordinator.currentMeasureIndex + 1 }
                        Button("Clear loop") {
                            loopEnabled = false; loopStart = nil; loopEnd = nil; trainerPass = 0
                            onLoopChanged()
                        }
                    } footer: {
                        Text("Tap the score or drag the position slider to seek. Set the bars to repeat here.")
                    }
                }
                .frame(minWidth: 300, minHeight: 340)
                .presentationCompactAdaptation(.popover)
            }
    }

    private func loopBound(isStart: Bool) -> Binding<Int> {
        Binding(get: { (isStart ? loopStart : loopEnd).map { $0 + 1 } ?? 1 }, set: { value in
            let index = max(0, min(totalMeasures - 1, value - 1))
            if isStart {
                loopStart = index
                loopEnd = max(index, loopEnd ?? index)
            } else {
                loopEnd = index
                loopStart = min(index, loopStart ?? index)
            }
            loopEnabled = true
            trainerPass = 0
            onLoopChanged()
        })
    }

    private func setTempoPercent(_ pct: Int) {
        let bpm = (originalBPM * Double(pct) / 100).rounded()
        coordinator.bpm = bpm
        userBPM = bpm
    }

    // MARK: Speed-trainer popover

    private var tempoPopover: some View {
        Form {
            if allowsReferenceTempoEditing {
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
                    in: max(1, originalBPM * 0.25)...max(1, originalBPM * 1.5),
                    step: 1
                )
                .tint(DS.accent)
                HStack {
                    ForEach([50, 75, 100, 125], id: \.self) { pct in
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
                    HStack(spacing: 12) {
                        speedSlider
                        PracticeToolButton()
                    }
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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to top")

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
                range: 0...40, accessibilityValueOffset: 0
            )
            .frame(minWidth: 120, maxWidth: .infinity)
            .accessibilityLabel("Scroll speed")
        }
    }

    private var tools: some View {
        HStack(spacing: 12) {
            TransportTile(icon: "repeat", label: "Loop to top", active: loopToTop) {
                loopToTop.toggle()
            }
            if !isCompact { PracticeToolButton() }
            TransportTile(icon: "slider.horizontal.3", label: "Settings", active: false) {
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
            scrollSpeed = resumeSpeed > 0 ? resumeSpeed : 8
        }
    }
}

/// The same notation, size, and follow preferences for both score renderers.
struct PlayerDisplaySections: View {
    @Binding var notation: String
    @Binding var scale: Double
    @Binding var autoScroll: String
    var rhythm: Binding<Bool>? = nil
    var supportsOriginal = false
    var supportsTab = true

    var body: some View {
        Section("Notation") {
            Picker("Notation", selection: $notation) {
                if supportsOriginal {
                    Text("Original").tag(NotationMode.original.rawValue)
                    Text("Sheet music").tag(NotationMode.staffOnly.rawValue)
                }
                if supportsTab {
                    Text("Tab only").tag(NotationMode.tabOnly.rawValue)
                    Text("Tab + staff").tag(NotationMode.tabAndStaff.rawValue)
                }
            }
            if let rhythm { Toggle("Rhythm letters", isOn: rhythm) }
            Stepper("Size: \(Int((scale * 100).rounded()))%", value: $scale, in: 0.8...1.8, step: 0.1)
        }
        Section("Auto-scroll") {
            Picker("Auto-scroll", selection: $autoScroll) {
                Text("Smooth scroll").tag(AutoScrollMode.smooth.rawValue)
                Text("Off").tag(AutoScrollMode.off.rawValue)
                Text("Follow playback").tag(AutoScrollMode.follow.rawValue)
                Text("Line by line").tag(AutoScrollMode.line.rawValue)
            }
        }
    }
}
