//
//  TabMakerToolbar.swift
//  TabBuddy
//
//  Top toolbar for the tab maker: tool picker, note duration,
//  time signature, tuning, BPM, and playback controls.
//

import SwiftUI

struct TabMakerToolbar: View {
    @ObservedObject var viewModel: TabMakerViewModel

    @State private var showTuningPicker = false
    @State private var showTimeSigPicker = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool picker
            toolPicker

            Divider().frame(height: 28)

            // Note duration picker
            durationPicker

            Divider().frame(height: 28)

            // Time signature
            timeSigButton

            // Tuning
            tuningButton

            Spacer()

            // BPM
            bpmControl

            Divider().frame(height: 28)

            // Measures
            measureControls

            Divider().frame(height: 28)

            // Playback
            playbackControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Tool Picker

    private var toolPicker: some View {
        HStack(spacing: 4) {
            ForEach(MakerTool.allCases, id: \.rawValue) { tool in
                Button {
                    viewModel.activeTool = tool
                } label: {
                    Image(systemName: tool == .pencil ? "pencil" : "eraser")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 36)
                        .background(viewModel.activeTool == tool
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Duration Picker

    private var durationPicker: some View {
        HStack(spacing: 2) {
            ForEach(NoteDuration.allCases) { duration in
                Button {
                    viewModel.selectedDuration = duration
                } label: {
                    Text(duration.label)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(width: 32, height: 32)
                        .background(viewModel.selectedDuration == duration
                                    ? Color.accentColor.opacity(0.2)
                                    : Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Time Signature

    private var timeSigButton: some View {
        Button {
            showTimeSigPicker = true
        } label: {
            Text("\(viewModel.composedTab.beatsPerMeasure)/\(viewModel.composedTab.noteValue)")
                .font(.system(size: 16, weight: .medium, design: .serif))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTimeSigPicker) {
            VStack(spacing: 0) {
                ForEach(TimeSignature.common) { sig in
                    Button {
                        viewModel.setTimeSignature(beats: sig.beats, noteValue: sig.noteValue)
                        showTimeSigPicker = false
                    } label: {
                        Text(sig.display)
                            .font(.system(size: 18, design: .serif))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if sig != TimeSignature.common.last {
                        Divider()
                    }
                }
            }
            .padding(8)
            .frame(width: 100)
        }
    }

    // MARK: - Tuning

    private var tuningButton: some View {
        Button {
            showTuningPicker = true
        } label: {
            Text(viewModel.composedTab.tuningName)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTuningPicker) {
            VStack(spacing: 0) {
                ForEach(GuitarTuning.allPresets) { tuning in
                    Button {
                        viewModel.setTuning(tuning)
                        showTuningPicker = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tuning.name)
                                .font(.system(size: 15, weight: .medium))
                            Text(tuning.displayString)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                    if tuning != GuitarTuning.allPresets.last {
                        Divider()
                    }
                }
            }
            .padding(4)
            .frame(width: 200)
        }
    }

    // MARK: - BPM

    private var bpmControl: some View {
        HStack(spacing: 6) {
            Text("BPM")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Button {
                    viewModel.composedTab.bpm = max(30, viewModel.composedTab.bpm - 5)
                } label: {
                    Image(systemName: "minus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Text("\(Int(viewModel.composedTab.bpm))")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .frame(width: 36)

                Button {
                    viewModel.composedTab.bpm = min(300, viewModel.composedTab.bpm + 5)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Measure Controls

    private var measureControls: some View {
        HStack(spacing: 4) {
            Image(systemName: "rectangle.split.3x1")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                viewModel.removeMeasure()
            } label: {
                Image(systemName: "minus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.composedTab.measureCount <= 1)

            Text("\(viewModel.composedTab.measureCount)")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(width: 24)

            Button {
                viewModel.addMeasure()
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 8) {
            // Mic / live transcription
            Button {
                viewModel.toggleTranscription()
            } label: {
                Image(systemName: viewModel.isTranscribing ? "mic.fill" : "mic")
                    .font(.system(size: 18))
                    .foregroundStyle(viewModel.isTranscribing ? .red : .accentColor)
                    .frame(width: 36, height: 36)
                    .background(viewModel.isTranscribing
                                ? Color.red.opacity(0.15)
                                : Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            // Live indicator
            if viewModel.isTranscribing {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text(viewModel.transcriptionNoteName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(minWidth: 28)
                }
            }

            // Play/stop
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(viewModel.isPlaying ? .red : .accentColor)
                    .frame(width: 36, height: 36)
                    .background(viewModel.isPlaying
                                ? Color.red.opacity(0.15)
                                : Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isTranscribing)
        }
    }
}
