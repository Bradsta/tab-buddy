//
//  TutorCalibrationView.swift
//  TabBuddy
//
//  Microphone setup: permission, live input level with noise floor and
//  placement advice, an instrument check ("play your open low E" / "play
//  middle C") with the detected note and cents, and latency calibration
//  (8 clicks, or 8 silent visual pulses) saved per audio route in TutorStore.
//

import AVFoundation
import SwiftUI

struct TutorCalibrationView: View {
    var instrument: TutorInstrument = .guitar

    @StateObject private var listener: TutorListener
    @StateObject private var model: TutorCalibrationModel
    @ObservedObject private var session = TutorAudioSession.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var permission = TutorMicPermission.current
    @State private var micError: String?
    @State private var bestCheck: TutorCalibrationModel.PitchCheck = .waiting
    @State private var calibrationTask: Task<Void, Never>?

    init(instrument: TutorInstrument = .guitar) {
        self.instrument = instrument
        let latencyStore = TutorShellLatency.store()
        _listener = StateObject(wrappedValue: TutorListener(latencyStore: latencyStore))
        _model = StateObject(wrappedValue: TutorCalibrationModel(
            calibrator: LatencyCalibrator(store: latencyStore), instrument: instrument))
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var target: (midi: Int, prompt: String) { TutorCalibrationModel.checkTarget(for: instrument) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if sizeClass != .compact {
                    Text("Calibration").font(.largeTitle.weight(.bold))
                }
                Text("Set up the microphone once per room and audio route. The tutor grades what it hears, so a good level and a measured delay make grading fairer.")
                    .font(sizeClass == .compact ? .body : .title3)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                permissionSection
                levelSection
                latencySection
            }
            .padding(sizeClass == .compact ? 16 : 32)
            .tutorReadableWidth(820)
        }
        .background(DS.paper)
        .onAppear { permission = TutorMicPermission.current; model.refresh() }
        .onDisappear(perform: stopEverything)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopEverything() }
            permission = TutorMicPermission.current
        }
        .onReceive(listener.$stoppedUnexpectedly) { stopped in
            if stopped { micError = TutorListeningCopy.stoppedUnexpectedly }
        }
        .onChange(of: listener.livePitch) { _, live in
            let check = TutorCalibrationModel.pitchCheck(midi: live?.midi, cents: live?.cents, target: target.midi)
            if check != .waiting, !bestCheck.isMatch { bestCheck = check }
            if check.isMatch { bestCheck = check }
        }
    }

    // MARK: Permission

    @ViewBuilder
    private var permissionSection: some View {
        switch permission {
        case .denied:
            TutorShellMicDeniedNotice()
        case .undetermined:
            TutorShellCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Microphone", systemImage: "mic").font(.headline)
                    Text("Listening happens on this device. Audio never leaves it.")
                        .foregroundStyle(DS.fg2)
                    Button("Allow microphone") {
                        Task {
                            _ = await AVAudioApplication.requestRecordPermission()
                            permission = TutorMicPermission.current
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        case .granted:
            Label("Microphone access is on", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(DS.accentStrong)
        }
    }

    // MARK: Level + instrument check

    private var levelSection: some View {
        TutorShellCard {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        levelTitle
                        Spacer()
                        micCheckButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        levelTitle
                        micCheckButton
                    }
                }
                Text(target.prompt + " Let it ring. The meter should jump well above the noise floor.")
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)

                TutorLevelMeter(levelDB: listener.isListening ? session.inputLevelDBFS : -120,
                                noiseDB: listener.isListening ? session.noiseFloorDBFS : -120,
                                peakDB: listener.isListening ? session.peakDBFS : -120)
                    .frame(height: 28)

                if listener.isListening {
                    let advice = InputLevelAdvisor.assess(peakDBFS: session.peakDBFS, noiseFloorDBFS: session.noiseFloorDBFS,
                                                         instrument: instrument, isPad: isPad)
                    Label(advice.message, systemImage: advice.status == .good ? "checkmark.circle" : "info.circle")
                        .foregroundStyle(advice.status == .good ? DS.accentStrong : DS.fg1)
                        .fixedSize(horizontal: false, vertical: true)
                    pitchReadout
                }
                if let micError {
                    Text(micError).foregroundStyle(DS.cautionText)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Placement").font(.subheadline.weight(.semibold)).foregroundStyle(DS.fg2)
                    Text(InputLevelAdvisor.placementTip(instrument: instrument, isPad: isPad))
                        .font(.subheadline)
                        .foregroundStyle(DS.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var levelTitle: some View {
        Label("1. Level and instrument check", systemImage: "waveform")
            .font(.title3.weight(.semibold))
            .fixedSize()
    }

    private var micCheckButton: some View {
        Button(listener.isListening ? "Stop" : "Start mic check") { toggleMicCheck() }
            .buttonStyle(.borderedProminent)
            .disabled(model.step.isRunning || permission == .denied)
            .keyboardShortcut("l", modifiers: .command)
    }

    private var pitchReadout: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(spacing: 2) {
                Text(listener.livePitch.map { Pitch(midi: $0.midi).name } ?? "–")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.fg1)
                    .monospacedDigit()
                Text(listener.livePitch.map { cents in
                    let c = Int(cents.cents.rounded())
                    return c == 0 ? "in tune" : "\(c > 0 ? "+" : "")\(c) cents"
                } ?? "listening")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(DS.fg2)
            }
            .frame(minWidth: 120)
            Text(TutorCalibrationModel.pitchCheckMessage(bestCheck, target: target.midi))
                .font(.body)
                .foregroundStyle(bestCheck.isMatch ? DS.accentStrong : DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
    }

    // MARK: Latency

    private var latencySection: some View {
        TutorShellCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("2. Latency", systemImage: "timer").font(.title3.weight(.semibold))
                Text("Sound takes a moment to travel through the device. The app plays 8 clicks; \(instrument == .guitar ? "strum one short note (or tap the guitar body)" : "play one short key") on each click. On a speaker the microphone may hear the clicks themselves, which also works.")
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Audio route", value: TutorCalibrationModel.routeDescription(session.routeKey))
                    LabeledContent("Latency", value: model.isCalibrated
                                   ? TutorCalibrationModel.latencyText(model.currentLatency)
                                   : "Not measured (using \(TutorCalibrationModel.latencyText(LatencyCalibrator.defaultLatency)))")
                }
                .font(.body)

                if TutorCalibrationModel.isBluetoothRoute(session.routeKey) {
                    Label("Bluetooth output adds a long, changing delay. Use the speaker or wired headphones while the tutor listens.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.cautionText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.cautionSoft, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                }

                if case .visual(let pulse) = model.step {
                    TutorPulseRow(count: TutorCalibrationModel.pulseCount, active: pulse)
                    Text(pulse < 0 ? "Get ready…" : "Play one short note on each flash.")
                        .foregroundStyle(DS.fg2)
                } else if model.step == .runningAudio {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Listening… play one short note on each click.")
                    }
                } else if model.step == .finishing {
                    ProgressView("Measuring…")
                }

                if let message = model.resultMessage {
                    Text(message)
                        .foregroundStyle(model.step == .idle ? DS.fg2 : (isFailure ? DS.cautionText : DS.accentStrong))
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { calibrationButtons }
                    VStack(alignment: .leading, spacing: 12) { calibrationButtons }
                }
                Text("No sound, or Bluetooth? The visual version flashes 8 pulses silently; play along with them.")
                    .font(.footnote)
                    .foregroundStyle(DS.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = model.step { return true }
        if case .finished(_, let saved) = model.step { return !saved }
        return false
    }

    @ViewBuilder
    private var calibrationButtons: some View {
        if model.step.isRunning {
            Button("Cancel", role: .cancel) {
                calibrationTask?.cancel()
                model.cancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else {
            Button {
                runCalibration(visual: false)
            } label: {
                Label("Calibrate with clicks", systemImage: "metronome")
                    .frame(minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(permission == .denied)
            Button {
                runCalibration(visual: true)
            } label: {
                Label("Visual pulses", systemImage: "circle.dotted")
                    .frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(permission == .denied)
        }
    }

    // MARK: Actions

    private func toggleMicCheck() {
        if listener.isListening || listener.isStarting {
            listener.stop()     // also cancels a start in progress
            return
        }
        micError = nil
        bestCheck = .waiting
        Task {
            do {
                try await listener.start(profile: .preset(for: instrument), recordTake: false)
            } catch {
                micError = error.localizedDescription
            }
            permission = TutorMicPermission.current
        }
    }

    private func runCalibration(visual: Bool) {
        listener.stop()
        TutorSynth.shared.stop()
        calibrationTask = Task {
            if visual { await model.runVisual() } else { await model.runAudio() }
            permission = TutorMicPermission.current
        }
    }

    private func stopEverything() {
        listener.stop()
        if model.step.isRunning {
            calibrationTask?.cancel()
            model.cancel()
        }
    }
}

/// Horizontal level meter (-80…0 dBFS) with the noise floor and peak marked.
struct TutorLevelMeter: View {
    var levelDB: Float
    var noiseDB: Float
    var peakDB: Float

    private func fraction(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db + 80) / 80))) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(DS.surfaceInset)
                RoundedRectangle(cornerRadius: 6)
                    .fill(levelDB > -3 ? DS.cautionText : DS.accent)
                    .frame(width: w * fraction(levelDB))
                    .animation(DS.motionFast, value: levelDB)
                // Noise floor
                Rectangle().fill(DS.fg3).frame(width: 2).offset(x: w * fraction(noiseDB))
                // Peak
                Rectangle().fill(DS.fg1).frame(width: 2).offset(x: max(0, w * fraction(peakDB) - 2))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text(levelDB > -119 ? "\(Int(levelDB.rounded())) dB · noise \(Int(noiseDB.rounded())) dB" : "Off")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(DS.fg2)
                .padding(.horizontal, 6)
                .offset(y: 18)
        }
        .padding(.bottom, 16)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(levelDB > -119 ? "\(Int(levelDB)) decibels" : "off")
    }
}

/// Row of pulse dots for visual latency calibration.
struct TutorPulseRow: View {
    var count: Int
    var active: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == active ? DS.accent : (i < active ? DS.accentSoft : DS.surfaceInset))
                    .frame(width: i == active ? 40 : 28, height: i == active ? 40 : 28)
                    .animation(.easeOut(duration: 0.08), value: active)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityLabel(active >= 0 ? "Pulse \(active + 1) of \(count)" : "Get ready")
    }
}
