//
//  TabTransportBar.swift
//  TabBuddy
//
//  The shared bottom transport used by both the drawn Tab Player and the raw
//  "Original" text view, so the two share one layout: skip-to-start, a large
//  play/pause, the measure + time/loop readout, a measure scrubber, the tempo
//  pill (with the speed-trainer popover), metronome, count-in, A/B loop, the
//  auto-scroll cycle, and a host-supplied Display popover.
//
//  It drives the shared `PlaybackCoordinator` / engines; rendering-specific
//  concerns (drawn playhead + scroll lock, or text highlight + text scroll)
//  stay in the host and are reached through the `onLoopChanged` / `onSeek` /
//  `onBeforePlay` hooks.
//

import SwiftUI

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
    /// Host hook on a seek/skip (e.g. stop notes, reset text scroll tracking).
    var onSeek: () -> Void = {}
    /// Host hook just before playback starts (e.g. force text layout).
    var onBeforePlay: () -> Void = {}

    @ViewBuilder var displayContent: () -> Display

    @AppStorage("player.autoScroll") private var autoScrollRaw = AutoScrollMode.follow.rawValue
    @AppStorage("player.countInBars") private var countInBars = 0

    @State private var showTempo = false
    @State private var showDisplay = false
    @State private var rampEnabled = false
    @State private var trainerPass = 0
    @State private var countingIn = false
    @State private var countInTask: Task<Void, Never>?

    private var autoScroll: AutoScrollMode { AutoScrollMode(rawValue: autoScrollRaw) ?? .follow }
    private var tempoPercent: Int { max(1, Int((coordinator.bpm / max(1, originalBPM)) * 100 + 0.5)) }

    /// Surfaced so a host can mirror the count-in state into its playhead.
    var isCountingIn: Bool { countingIn }

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 14) {
                Button { skip() } label: {
                    Image(systemName: "backward.end.fill").font(.body)
                }.buttonStyle(.borderless)

                Button { togglePlay() } label: {
                    ZStack {
                        Circle().fill(Color.accentColor)
                            .frame(width: 52, height: 52)
                            .shadow(color: Color.accentColor.opacity(0.34), radius: 8, y: 4)
                        Image(systemName: (coordinator.isPlaying || countingIn) ? "pause.fill" : "play.fill")
                            .font(.title2).foregroundColor(.white)
                    }
                }.buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text("m. \(coordinator.currentMeasureIndex + 1) / \(max(1, totalMeasures))")
                        .font(.callout).fontWeight(.semibold).monospacedDigit()
                    Text(readout).font(.caption)
                        .foregroundStyle(loopEnabled ? Color(uiColor: .systemIndigo) : .secondary)
                        .monospacedDigit()
                }
            }

            scrubber

            HStack(spacing: 14) {
                tempoControl
                control(icon: "metronome", label: "Metronome", active: metronome.isEnabled) {
                    metronome.isEnabled.toggle()
                }
                countInControl
                control(icon: "repeat", label: "Loop", active: loopEnabled) { toggleLoop() }
                control(icon: autoScrollIcon, label: "Scroll", active: autoScroll != .off) {
                    cycleAutoScroll()
                }
                control(icon: "slider.horizontal.3", label: "Display", active: false) {
                    showDisplay = true
                }
                .popover(isPresented: $showDisplay) {
                    displayContent().presentationCompactAdaptation(.popover)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
        .onAppear {
            // Speed trainer: bump tempo each completed loop pass, capped at 100%.
            coordinator.onLoopCompleted = {
                guard rampEnabled else { return }
                setTempoPercent(min(100, tempoPercent + 5))
                trainerPass += 1
            }
        }
    }

    // MARK: Pieces

    private var readout: String {
        if loopEnabled { return "Loop · pass \(trainerPass + 1)" }
        let secs = coordinator.bpm > 0 ? coordinator.accumulatedBeats * 60.0 / coordinator.bpm : 0
        return String(format: "%d:%02d", Int(secs) / 60, Int(secs) % 60)
    }

    private var scrubber: some View {
        let total = Double(max(1, totalMeasures - 1))
        return Slider(
            value: Binding(
                get: { Double(coordinator.currentMeasureIndex) },
                set: { onSeek(); coordinator.seekToMeasure(Int($0.rounded())) }
            ),
            in: 0...total,
            step: 1
        )
        .frame(minWidth: 120)
    }

    private var tempoControl: some View {
        Button { showTempo = true } label: {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Text("\u{2669}").font(.callout)
                    Text("\(Int(coordinator.bpm))").font(.callout).fontWeight(.semibold).monospacedDigit()
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                .foregroundStyle(Color.accentColor)
                Text("\(tempoPercent)%").font(.system(size: 10)).foregroundStyle(.secondary)
            }
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
            controlLabel(icon: countInBars == 0 ? "number" : "\(countInBars).circle",
                         label: "Count-in", active: countInBars > 0)
        }
    }

    private func control(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { controlLabel(icon: icon, label: label, active: active) }
            .buttonStyle(.plain)
    }

    private func controlLabel(icon: String, label: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 42, height: 42)
                .background(active ? Color.accentColor : Color(uiColor: .systemFill).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 11))
                .foregroundStyle(active ? Color.white : Color.primary)
            Text(label).font(.system(size: 10))
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
    }

    private var autoScrollIcon: String {
        switch autoScroll {
        case .off: return "arrow.down.circle"
        case .follow: return "arrow.down"
        case .line: return "arrow.down.to.line"
        }
    }

    // MARK: Actions

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
                    Text("Tempo").fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(coordinator.bpm)) / \(Int(originalBPM)) BPM")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(
                    value: Binding(get: { coordinator.bpm }, set: { coordinator.bpm = $0; userBPM = $0 }),
                    in: max(30, originalBPM * 0.25)...max(60, originalBPM),
                    step: 1
                )
                HStack {
                    ForEach([50, 75, 90, 100], id: \.self) { pct in
                        Button { setTempoPercent(pct) } label: {
                            Text("\(pct)%").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(tempoPercent == pct ? Color(uiColor: .systemIndigo) : nil)
                    }
                }
            }
            Section {
                Toggle(isOn: $rampEnabled) {
                    VStack(alignment: .leading) {
                        Text("Ramp up each loop")
                        Text("+5% → 100% over successive passes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!loopEnabled)
            } footer: {
                if !loopEnabled { Text("Enable a loop to use the speed trainer.") }
            }
        }
        .frame(minWidth: 320, minHeight: 320)
    }
}
