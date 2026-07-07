//
//  TabMakerToolbar.swift
//  TabBuddy
//
//  The maker's bottom transport (DESIGN.md §6) — the old top toolbar is gone.
//  Zones: [tools: pencil/eraser + duration chips + Display] [position: bar
//  readout + scrubber] [playback: Listen mic · tempo pill · Play]. Rarely-set
//  controls (time signature, tuning, measure count) live in Display.
//

import SwiftUI

struct MakerTransportBar: View {
    @ObservedObject var viewModel: TabMakerViewModel
    @ObservedObject var coordinator: PlaybackCoordinator

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showDisplay = false
    @State private var showTempo = false

    private var isCompact: Bool { hSize == .compact }
    private var measureCount: Int { max(1, viewModel.composedTab.measureCount) }

    var body: some View {
        TransportChrome {
            if isCompact {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        toolTiles
                        durationChips
                        Spacer(minLength: 4)
                        displayControl
                    }
                    HStack(spacing: 10) {
                        micControl
                        tempoControl
                        positionReadout
                        scrubber
                        PlayCircleButton(isOn: viewModel.isPlaying) { viewModel.togglePlayback() }
                            .disabled(viewModel.isTranscribing)
                            .opacity(viewModel.isTranscribing ? 0.4 : 1)
                    }
                }
            } else {
                HStack(spacing: 16) {
                    HStack(spacing: 10) {
                        toolTiles
                        durationChips
                        displayControl
                    }
                    positionReadout
                    scrubber
                    HStack(spacing: 12) {
                        micControl
                        tempoControl
                        PlayCircleButton(isOn: viewModel.isPlaying) { viewModel.togglePlayback() }
                            .disabled(viewModel.isTranscribing)
                            .opacity(viewModel.isTranscribing ? 0.4 : 1)
                    }
                }
            }
        }
    }

    // MARK: Tools

    private var toolTiles: some View {
        HStack(spacing: 8) {
            TransportTile(icon: "pencil", label: "Draw",
                          active: viewModel.activeTool == .pencil) {
                viewModel.activeTool = .pencil
            }
            TransportTile(icon: "eraser", label: "Erase",
                          active: viewModel.activeTool == .eraser) {
                viewModel.activeTool = .eraser
            }
        }
    }

    /// 32pt mono chips; active = AccentSoft fill with AccentStrong text.
    private var durationChips: some View {
        HStack(spacing: 4) {
            ForEach(NoteDuration.allCases) { duration in
                let active = viewModel.selectedDuration == duration
                Button {
                    viewModel.selectedDuration = duration
                } label: {
                    Text(duration.label)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(width: 32, height: 32)
                        .background(active ? AnyShapeStyle(DS.accentSoft) : AnyShapeStyle(DS.surfaceInset),
                                    in: RoundedRectangle(cornerRadius: DS.radiusChip))
                        .foregroundStyle(active ? DS.accentStrong : DS.fg2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(duration.label) note")
            }
        }
    }

    private var displayControl: some View {
        TransportTile(icon: "slider.horizontal.3", label: "Display", active: false) {
            showDisplay = true
        }
        .popover(isPresented: $showDisplay) {
            displayPopover.presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Position

    private var positionReadout: some View {
        TransportReadout(
            value: "bar \(min(viewModel.playbackMeasureIndex + 1, measureCount))/\(measureCount)",
            sub: viewModel.isTranscribing ? "listening · \(viewModel.transcriptionNoteName)" : elapsed,
            subAccented: viewModel.isTranscribing
        )
    }

    private var elapsed: String {
        let bpm = viewModel.composedTab.bpm
        let secs = bpm > 0 ? coordinator.accumulatedBeats * 60.0 / bpm : 0
        return minimalTime(secs)
    }

    private var scrubber: some View {
        TokenScrubber(
            value: Binding(
                get: { Double(viewModel.playbackMeasureIndex) },
                set: { coordinator.seekToMeasure(Int($0.rounded())) }
            ),
            range: 0...Double(max(1, measureCount - 1))
        )
        .frame(minWidth: 100, maxWidth: .infinity)
    }

    // MARK: Playback

    private var micControl: some View {
        TransportTile(icon: viewModel.isTranscribing ? "mic.fill" : "mic",
                      label: "Listen",
                      active: viewModel.isTranscribing) {
            viewModel.toggleTranscription()
        }
    }

    private var tempoControl: some View {
        Button { showTempo = true } label: {
            TempoPillLabel(bpm: Int(viewModel.composedTab.bpm), percent: 100, subLabel: "tempo")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTempo) {
            Form {
                Section("Tempo") {
                    HStack {
                        Button {
                            viewModel.composedTab.bpm = max(30, viewModel.composedTab.bpm - 5)
                        } label: { Image(systemName: "minus.circle").font(.title3) }
                            .buttonStyle(.borderless)
                        Text("\(Int(viewModel.composedTab.bpm)) BPM")
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                        Button {
                            viewModel.composedTab.bpm = min(300, viewModel.composedTab.bpm + 5)
                        } label: { Image(systemName: "plus.circle").font(.title3) }
                            .buttonStyle(.borderless)
                    }
                    Slider(
                        value: Binding(
                            get: { viewModel.composedTab.bpm },
                            set: { viewModel.composedTab.bpm = $0.rounded() }
                        ),
                        in: 30...300, step: 1
                    )
                    .tint(DS.accent)
                }
            }
            .frame(minWidth: 280, minHeight: 160)
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Display popover — rarely-set document settings

    private var displayPopover: some View {
        Form {
            Section("Time signature") {
                Picker("Time signature", selection: Binding(
                    get: { "\(viewModel.composedTab.beatsPerMeasure)/\(viewModel.composedTab.noteValue)" },
                    set: { sel in
                        if let sig = TimeSignature.common.first(where: { $0.display == sel }) {
                            viewModel.setTimeSignature(beats: sig.beats, noteValue: sig.noteValue)
                        }
                    })) {
                    ForEach(TimeSignature.common) { sig in
                        Text(sig.display).tag(sig.display)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Tuning") {
                ForEach(GuitarTuning.allPresets) { tuning in
                    Button {
                        viewModel.setTuning(tuning)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tuning.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(DS.fg1)
                                Text(tuning.displayString)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(DS.fg2)
                            }
                            Spacer()
                            if viewModel.composedTab.tuningName == tuning.name {
                                Image(systemName: "checkmark").foregroundStyle(DS.accent)
                            }
                        }
                    }
                }
            }
            Section("Measures") {
                HStack {
                    Text("\(viewModel.composedTab.measureCount) bars")
                        .monospacedDigit()
                    Spacer()
                    Button {
                        viewModel.removeMeasure()
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.composedTab.measureCount <= 1)
                    Button {
                        viewModel.addMeasure()
                    } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 420)
    }
}
