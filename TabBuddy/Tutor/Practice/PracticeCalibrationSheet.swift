//
//  PracticeCalibrationSheet.swift
//  TabBuddy
//
//  Inline latency calibration for practice mode (LatencyCalibrator audio
//  mode), saved per audio route in the tutor store. The tutor's full
//  calibration screen (mic check, visual calibration) is linked below it.
//

import SwiftUI

struct PracticeCalibrationSheet: View {
    let instrument: TutorInstrument
    var onFinished: () -> Void = {}

    @StateObject private var calibrator = LatencyCalibrator(store: TutorLatency.store())
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("TabBuddy plays 8 clicks and listens. Keep the device where it will be while you play. On the speaker it measures the delay from the clicks themselves; with headphones, play one short note on each click.")
                        .font(.subheadline)
                        .foregroundStyle(DS.fg2)
                    if calibrator.routeNeedsWarning {
                        Label("Bluetooth adds a large, variable delay. Wired headphones or the speaker work better.",
                              systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(DS.cautionText)
                    }
                    Button {
                        Task { _ = await calibrator.runAudioCalibration(profile: .preset(for: instrument)) }
                    } label: {
                        Label(calibrator.phase == .running ? "Listening…" : "Start calibration",
                              systemImage: "metronome")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accent)
                    .disabled(calibrator.phase == .running)
                } footer: {
                    Text("Current delay for this audio route: \(Int((calibrator.currentLatency() * 1000).rounded())) ms\(calibrator.isCalibrated ? "" : " (standard value, not measured)").")
                }
                resultSection
                Section {
                    NavigationLink("Microphone check and other calibration") {
                        TutorCalibrationView(instrument: instrument)
                    }
                }
            }
            .navigationTitle("Timing calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { calibrator.cancelIfRunning(); onFinished(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch calibrator.phase {
        case .finished(let estimate):
            Section("Result") {
                Text("Measured \(Int((estimate.latency * 1000).rounded())) ms (spread \(Int((estimate.spread * 1000).rounded())) ms, \(estimate.matched) of \(estimate.cues) clicks).")
                Text(estimate.isReliable ? "Saved for this audio route."
                     : "Not saved: the clicks didn't line up closely enough. Try again in a quieter moment.")
                    .foregroundStyle(estimate.isReliable ? DS.fg2 : DS.cautionText)
            }
        case .failed(let message):
            Section("Result") { Text(message).foregroundStyle(DS.cautionText) }
        case .idle, .running:
            EmptyView()
        }
    }
}

private extension LatencyCalibrator {
    func cancelIfRunning() {
        if phase == .running { cancel() }
    }
}
