//
//  LiveTranscriptionView.swift
//  TabBuddy
//
//  Real-time microphone pitch detection playground.
//  Shows detected notes on a music staff and generates naive tablature.
//

import SwiftUI

struct LiveTranscriptionView: View {

    @StateObject private var detector = PitchDetector()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Live indicator
            liveIndicator
                .padding(.horizontal)
                .padding(.top, 8)

            Divider().padding(.top, 8)

            // MARK: - Staff display
            staffView
                .frame(height: 180)
                .padding(.horizontal)

            Divider()

            // MARK: - Tablature output
            tabOutputView
                .frame(maxHeight: .infinity)

            Divider()

            // MARK: - Controls
            controlBar
                .padding(.horizontal)
                .padding(.vertical, 10)
        }
        .overlay {
            if detector.permissionDenied {
                VStack(spacing: 12) {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Microphone Access Required")
                        .font(.headline)
                    Text("Tab Buddy needs microphone access to detect the notes you play. Enable it in Settings.")
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
        .navigationTitle("Live Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            detector.stopListening()
        }
    }

    // MARK: - Live Indicator

    private var liveIndicator: some View {
        HStack(spacing: 16) {
            // Recording dot
            if detector.isListening {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .shadow(color: .red.opacity(0.6), radius: 4)
            }

            // Note name
            Text(detector.currentNote)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 90)

            VStack(alignment: .leading, spacing: 4) {
                // Frequency
                if detector.currentFrequency > 0 {
                    Text(String(format: "%.1f Hz", detector.currentFrequency))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Confidence bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(.systemGray5))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(confidenceColor)
                            .frame(width: geo.size.width * detector.confidence)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var confidenceColor: Color {
        if detector.confidence > 0.8 { return .green }
        if detector.confidence > 0.5 { return .yellow }
        return .red
    }

    // MARK: - Staff View

    private var staffView: some View {
        Canvas { context, size in
            let staffTop: CGFloat = 40
            let lineSpacing: CGFloat = 12
            let staffBottom = staffTop + 4 * lineSpacing

            // Draw 5 staff lines
            for i in 0..<5 {
                let y = staffTop + CGFloat(i) * lineSpacing
                var path = Path()
                path.move(to: CGPoint(x: 16, y: y))
                path.addLine(to: CGPoint(x: size.width - 16, y: y))
                context.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
            }

            // Draw detected notes
            let notes = detector.detectedNotes
            let maxVisible = 20
            let visibleNotes = notes.suffix(maxVisible)
            guard !visibleNotes.isEmpty else { return }

            let noteSpacing = max(24, (size.width - 64) / CGFloat(maxVisible))
            let startX: CGFloat = 32

            for (idx, note) in visibleNotes.enumerated() {
                let x = startX + CGFloat(idx) * noteSpacing
                let y = staffYForMIDI(note.midi, staffTop: staffTop,
                                       lineSpacing: lineSpacing)

                // Draw ledger lines if needed
                drawLedgerLines(context: context, x: x, y: y,
                                staffTop: staffTop, staffBottom: staffBottom,
                                lineSpacing: lineSpacing)

                // Note head (filled oval)
                let noteRect = CGRect(x: x - 7, y: y - 5, width: 14, height: 10)
                context.fill(Ellipse().path(in: noteRect), with: .color(.primary))

                // Accidental (sharp/flat)
                let noteName = note.noteName
                if noteName.contains("#") {
                    context.draw(
                        Text("#").font(.system(size: 11, weight: .bold)),
                        at: CGPoint(x: x - 14, y: y),
                        anchor: .center
                    )
                }

                // Note name below staff
                context.draw(
                    Text(note.noteName)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary),
                    at: CGPoint(x: x, y: staffBottom + 20),
                    anchor: .center
                )
            }
        }
    }

    /// Map MIDI note to Y position on the staff.
    /// Uses treble clef: middle C (MIDI 60) is one ledger line below.
    /// Each semitone step maps to half a line spacing for natural notes.
    private func staffYForMIDI(_ midi: Int, staffTop: CGFloat, lineSpacing: CGFloat) -> CGFloat {
        // Staff positions (steps from bottom line E4=64):
        // Bottom line = E4 (MIDI 64), each staff position = half lineSpacing
        // E4=0, F4=1, G4=2, A4=3, B4=4, C5=5, D5=6, E5=7, F5=8
        //
        // Map MIDI to diatonic position relative to C
        let noteInOctave = midi % 12
        let octave = (midi / 12) - 1

        // Chromatic to diatonic: C=0, D=1, E=2, F=3, G=4, A=5, B=6
        let chromaticToDiatonic: [Int] = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
        let diatonicInOctave = chromaticToDiatonic[noteInOctave]

        // Absolute diatonic position (C4 = 0)
        let diatonicPos = (octave - 4) * 7 + diatonicInOctave

        // Staff reference: bottom line (E4) = diatonic pos 2 in octave 4
        let e4Diatonic = 2  // E in octave 4
        let stepsFromE4 = diatonicPos - e4Diatonic

        // Bottom line of staff is at staffTop + 4*lineSpacing
        // Each diatonic step goes UP by half lineSpacing
        let bottomLineY = staffTop + 4 * lineSpacing
        let y = bottomLineY - CGFloat(stepsFromE4) * (lineSpacing / 2)

        return y
    }

    /// Draw ledger lines for notes above or below the staff.
    private func drawLedgerLines(context: GraphicsContext, x: CGFloat, y: CGFloat,
                                  staffTop: CGFloat, staffBottom: CGFloat,
                                  lineSpacing: CGFloat) {
        let ledgerWidth: CGFloat = 22

        // Below staff
        if y > staffBottom {
            var ly = staffBottom + lineSpacing
            while ly <= y + 2 {
                var path = Path()
                path.move(to: CGPoint(x: x - ledgerWidth / 2, y: ly))
                path.addLine(to: CGPoint(x: x + ledgerWidth / 2, y: ly))
                context.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                ly += lineSpacing
            }
        }

        // Above staff
        if y < staffTop {
            var ly = staffTop - lineSpacing
            while ly >= y - 2 {
                var path = Path()
                path.move(to: CGPoint(x: x - ledgerWidth / 2, y: ly))
                path.addLine(to: CGPoint(x: x + ledgerWidth / 2, y: ly))
                context.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                ly -= lineSpacing
            }
        }
    }

    // MARK: - Tab Output

    private var tabOutputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(generateTab())
                    .font(Font(UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)))
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("tabBottom")
            }
            .onChange(of: detector.detectedNotes.count) { _ in
                withAnimation {
                    proxy.scrollTo("tabBottom", anchor: .bottom)
                }
            }
        }
    }

    /// Generate naive tablature text from detected notes.
    private func generateTab() -> String {
        let notes = detector.detectedNotes
        guard !notes.isEmpty else {
            return """
            e|--
            B|--
            G|--
            D|--
            A|--
            E|--
            """
        }

        let lineLabels = ["e", "B", "G", "D", "A", "E"]
        let maxCharsPerLine = 60

        // Group notes into systems of maxCharsPerLine
        var systems: [String] = []
        var currentOffset = 0

        while currentOffset < notes.count {
            let chunkEnd = min(currentOffset + maxCharsPerLine / 4, notes.count)
            let chunk = Array(notes[currentOffset..<chunkEnd])

            var lines = lineLabels.map { "\($0)|" }

            for note in chunk {
                if let string = note.guitarString, let fret = note.fret,
                   string >= 0 && string < 6 {
                    let fretStr = String(fret)
                    // Pad other strings with dashes
                    for i in 0..<6 {
                        if i == string {
                            lines[i] += fretStr
                        } else {
                            lines[i] += String(repeating: "-", count: fretStr.count)
                        }
                    }
                    // Add separator dash
                    for i in 0..<6 { lines[i] += "-" }
                } else {
                    // Unknown string — put ? on all lines
                    for i in 0..<6 { lines[i] += "?-" }
                }
            }

            // Pad to equal length and close
            let maxLen = lines.map(\.count).max() ?? 0
            for i in 0..<6 {
                let pad = maxLen - lines[i].count
                if pad > 0 { lines[i] += String(repeating: "-", count: pad) }
                lines[i] += "|"
            }

            systems.append(lines.joined(separator: "\n"))
            currentOffset = chunkEnd
        }

        return systems.joined(separator: "\n\n")
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 20) {
            // Mic toggle
            Button {
                if detector.isListening {
                    detector.stopListening()
                } else {
                    detector.startListening()
                }
            } label: {
                Label(
                    detector.isListening ? "Stop" : "Listen",
                    systemImage: detector.isListening ? "mic.fill" : "mic"
                )
                .font(.headline)
                .foregroundStyle(detector.isListening ? .red : .accentColor)
            }
            .buttonStyle(.bordered)
            .tint(detector.isListening ? .red : .accentColor)

            Spacer()

            // Note count
            Text("\(detector.detectedNotes.count) notes")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Clear
            Button {
                detector.clearNotes()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .disabled(detector.detectedNotes.isEmpty)
        }
    }
}
