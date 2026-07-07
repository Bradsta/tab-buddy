//
//  TunerView.swift
//  TabBuddy
//
//  Chromatic guitar tuner. Reuses PitchDetector's live pitch stream
//  (NoteTranscriberCore under the hood) for a fast, steady needle.
//  Tap a string pill to hear its reference note.
//

import SwiftUI

struct TunerView: View {

    @StateObject private var detector = PitchDetector()
    @StateObject private var player = NotePlaybackEngine()

    /// Standard tuning, low E first.
    private static let strings: [(name: String, midi: Int)] = [
        ("E2", 40), ("A2", 45), ("D3", 50), ("G3", 55), ("B3", 59), ("E4", 64)
    ]

    /// Smoothed needle position (cents).
    @State private var needleCents: Double = 0
    @State private var displayNote: String = "-"
    @State private var displayHz: Double = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // MARK: - Note readout
            VStack(spacing: 4) {
                Text(displayNote)
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(inTune && hasSignal ? .green : .primary)
                    .contentTransition(.identity)
                Text(hasSignal ? String(format: "%.1f Hz", displayHz) : " ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // MARK: - Cents gauge
            gauge
                .frame(height: 120)
                .padding(.horizontal, 24)

            Text(centsLabel)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(hasSignal ? (inTune ? .green : .orange) : .secondary)

            Spacer()

            // MARK: - String reference pills
            VStack(spacing: 10) {
                Text("Tap a string to hear it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Self.strings, id: \.midi) { s in
                        stringPill(s)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .padding()
        .navigationTitle("Tuner")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            detector.startListening()
            player.isEnabled = true
            player.start()
        }
        .onDisappear {
            detector.stopListening()
            player.stop()
        }
        .onChange(of: detector.currentCents) { _, newValue in
            guard detector.currentFrequency > 0 else { return }
            withAnimation(.linear(duration: 0.08)) {
                needleCents = needleCents * 0.6 + newValue * 0.4
            }
            displayNote = detector.currentNote
            displayHz = detector.currentFrequency
        }
        .overlay {
            if detector.permissionDenied {
                micPermissionOverlay
            }
        }
    }

    private var hasSignal: Bool { detector.currentFrequency > 0 }
    private var inTune: Bool { abs(needleCents) <= 5 }

    private var centsLabel: String {
        guard hasSignal else { return "listening…" }
        if inTune { return "in tune" }
        let c = Int(needleCents.rounded())
        return c > 0 ? "+\(c)¢ sharp" : "\(c)¢ flat"
    }

    // MARK: - Gauge

    private var gauge: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w / 2

            ZStack {
                // Tick marks: -50…+50 cents
                Canvas { context, size in
                    for cents in stride(from: -50, through: 50, by: 5) {
                        let x = size.width / 2 + CGFloat(cents) / 50 * (size.width / 2 - 12)
                        let major = cents % 25 == 0
                        let tickH: CGFloat = major ? 22 : 12
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height * 0.62 - tickH))
                        path.addLine(to: CGPoint(x: x, y: size.height * 0.62))
                        context.stroke(path, with: .color(major ? .primary.opacity(0.6) : .gray.opacity(0.35)),
                                       lineWidth: major ? 2 : 1)
                        if major {
                            let label = cents == 0 ? "0" : "\(cents > 0 ? "+" : "")\(cents)"
                            context.draw(Text(label).font(.caption2).foregroundColor(.secondary),
                                         at: CGPoint(x: x, y: size.height * 0.62 + 12), anchor: .center)
                        }
                    }
                }

                // In-tune zone
                RoundedRectangle(cornerRadius: 3)
                    .fill(.green.opacity(0.15))
                    .frame(width: (w / 2 - 12) * (10.0 / 50.0) * 2, height: 44)
                    .position(x: cx, y: h * 0.62 - 22)

                // Needle
                if hasSignal {
                    let x = cx + CGFloat(max(-50, min(50, needleCents))) / 50 * (w / 2 - 12)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(inTune ? Color.green : Color.orange)
                        .frame(width: 4, height: 56)
                        .position(x: x, y: h * 0.62 - 28)
                        .shadow(color: (inTune ? Color.green : Color.orange).opacity(0.5), radius: 4)
                }
            }
        }
    }

    // MARK: - String pills

    private func stringPill(_ s: (name: String, midi: Int)) -> some View {
        let isNearest = hasSignal && nearestString?.midi == s.midi
        return Button {
            player.playMIDI(s.midi)
        } label: {
            Text(s.name)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isNearest ? (inTune ? Color.green.opacity(0.25) : Color.orange.opacity(0.25))
                                        : Color(.systemGray6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isNearest ? (inTune ? Color.green : Color.orange) : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }

    private var nearestString: (name: String, midi: Int)? {
        guard hasSignal else { return nil }
        let midiF = 69.0 + 12.0 * log2(detector.currentFrequency / 440.0)
        return Self.strings.min(by: { abs(Double($0.midi) - midiF) < abs(Double($1.midi) - midiF) })
    }

    // MARK: - Permission overlay

    private var micPermissionOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Microphone Access Required")
                .font(.headline)
            Text("Tab Buddy needs microphone access to hear your guitar. Enable it in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}
