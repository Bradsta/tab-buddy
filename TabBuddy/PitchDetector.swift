//
//  PitchDetector.swift
//  TabBuddy
//
//  Real-time pitch detection from microphone input using the YIN
//  autocorrelation algorithm. Detects monophonic pitched notes and
//  maps them to guitar string/fret positions.
//

import AVFoundation
import Accelerate
import Combine

/// A single note detected from microphone input.
struct DetectedNote: Identifiable {
    let id = UUID()
    let midi: Int
    let noteName: String
    let frequency: Double
    let timestamp: Date
    let guitarString: Int?   // 0 = high E, 5 = low E (nil if ambiguous)
    let fret: Int?           // fret number on that string
}

@MainActor
final class PitchDetector: ObservableObject {

    // MARK: - Published state

    @Published var currentFrequency: Double = 0
    @Published var currentNote: String = "-"
    @Published var currentMIDI: Int = 0
    @Published var confidence: Double = 0
    @Published var isListening: Bool = false
    @Published var permissionDenied: Bool = false
    @Published var detectedNotes: [DetectedNote] = []

    // MARK: - Audio engine

    private let engine = AVAudioEngine()
    private let sampleRate: Double = 44100
    private let bufferSize: AVAudioFrameCount = 4096

    // YIN parameters
    private let yinThreshold: Double = 0.15  // confidence threshold

    // Debounce: avoid rapid-fire duplicate detections
    private var lastDetectedMIDI: Int = -1
    private var lastDetectionTime: Date = .distantPast
    private let minNoteInterval: TimeInterval = 0.12  // seconds between distinct notes

    // Standard tuning open-string MIDI notes (low E to high E)
    private static let openStringMIDI: [Int] = [40, 45, 50, 55, 59, 64]
    // Note names
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F",
                                     "F#", "G", "G#", "A", "A#", "B"]

    // MARK: - Lifecycle

    func startListening() {
        guard !isListening else { return }

        // Request mic permission
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.permissionDenied = true
                    return
                }
                self?.permissionDenied = false
                self?.setupAndStart()
            }
        }
    }

    func stopListening() {
        guard isListening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isListening = false
    }

    func clearNotes() {
        detectedNotes.removeAll()
        lastDetectedMIDI = -1
    }

    // MARK: - Setup

    private func setupAndStart() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
            return
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install tap — buffers arrive on a background thread
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            try engine.start()
            isListening = true
        } catch {
            print("Engine start error: \(error)")
        }
    }

    // MARK: - Buffer processing (background thread)

    private nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let data = Array(UnsafeBufferPointer(start: channelData[0], count: frames))

        // Check RMS level — skip silent buffers
        var rms: Float = 0
        vDSP_measqv(data, 1, &rms, vDSP_Length(frames))
        rms = sqrtf(rms)
        guard rms > 0.01 else {
            DispatchQueue.main.async { [weak self] in
                self?.confidence = 0
                self?.currentNote = "-"
                self?.currentFrequency = 0
            }
            return
        }

        // Run YIN pitch detection
        let actualSampleRate = buffer.format.sampleRate
        let result = yinDetect(data: data, sampleRate: actualSampleRate)

        DispatchQueue.main.async { [weak self] in
            self?.handleDetectionResult(result)
        }
    }

    // MARK: - YIN algorithm

    /// YIN fundamental frequency estimator.
    /// Returns (frequency, confidence) where confidence is 0.0–1.0.
    private nonisolated func yinDetect(data: [Float], sampleRate: Double) -> (Double, Double) {
        let halfLen = data.count / 2

        // Step 1: Difference function
        var diff = [Float](repeating: 0, count: halfLen)
        for tau in 0..<halfLen {
            var sum: Float = 0
            for i in 0..<halfLen {
                let delta = data[i] - data[i + tau]
                sum += delta * delta
            }
            diff[tau] = sum
        }

        // Step 2: Cumulative mean normalized difference
        var cmndf = [Float](repeating: 0, count: halfLen)
        cmndf[0] = 1.0
        var runningSum: Float = 0
        for tau in 1..<halfLen {
            runningSum += diff[tau]
            cmndf[tau] = diff[tau] * Float(tau) / runningSum
        }

        // Step 3: Absolute threshold — find first dip below threshold
        // Skip very short periods (frequencies above ~2kHz are likely noise)
        let minTau = Int(sampleRate / 2000)  // ~2000 Hz max
        let maxTau = Int(sampleRate / 60)    // ~60 Hz min (below low E)

        var bestTau = -1
        for tau in max(2, minTau)..<min(halfLen, maxTau) {
            if cmndf[tau] < Float(yinThreshold) {
                // Find the local minimum near this threshold crossing
                while tau + 1 < halfLen && cmndf[tau + 1] < cmndf[tau] {
                    bestTau = tau + 1
                    break
                }
                if bestTau < 0 { bestTau = tau }
                break
            }
        }

        guard bestTau > 0 else { return (0, 0) }

        // Step 4: Parabolic interpolation for sub-sample accuracy
        let s0 = cmndf[max(0, bestTau - 1)]
        let s1 = cmndf[bestTau]
        let s2 = cmndf[min(halfLen - 1, bestTau + 1)]
        let adjustment = (s0 - s2) / (2.0 * (s0 - 2.0 * s1 + s2))
        let refinedTau = Double(bestTau) + Double(adjustment)

        let frequency = sampleRate / refinedTau
        let conf = 1.0 - Double(cmndf[bestTau])

        // Sanity check: guitar range is roughly E2 (82 Hz) to E6 (~1320 Hz)
        guard frequency > 70 && frequency < 1400 else { return (0, 0) }

        return (frequency, max(0, min(1, conf)))
    }

    // MARK: - Result handling

    private func handleDetectionResult(_ result: (Double, Double)) {
        let (frequency, conf) = result

        confidence = conf
        guard conf > 0.5, frequency > 0 else {
            currentNote = "-"
            currentFrequency = 0
            return
        }

        currentFrequency = frequency

        // Frequency → MIDI → note name
        let midi = frequencyToMIDI(frequency)
        currentMIDI = midi
        currentNote = midiToNoteName(midi)

        // Debounce: only record a new note if it's different or enough time passed
        let now = Date()
        if midi != lastDetectedMIDI || now.timeIntervalSince(lastDetectionTime) > 0.5 {
            guard now.timeIntervalSince(lastDetectionTime) >= minNoteInterval else { return }

            lastDetectedMIDI = midi
            lastDetectionTime = now

            let guitar = mapToGuitar(midi)
            let note = DetectedNote(
                midi: midi,
                noteName: midiToNoteName(midi),
                frequency: frequency,
                timestamp: now,
                guitarString: guitar?.string,
                fret: guitar?.fret
            )
            detectedNotes.append(note)
        }
    }

    // MARK: - Pitch utilities

    private func frequencyToMIDI(_ freq: Double) -> Int {
        // MIDI 69 = A4 = 440 Hz
        Int(round(69.0 + 12.0 * log2(freq / 440.0)))
    }

    private func midiToNoteName(_ midi: Int) -> String {
        let name = Self.noteNames[midi % 12]
        let octave = (midi / 12) - 1
        return "\(name)\(octave)"
    }

    /// Map a MIDI note to the most natural guitar string + fret position.
    /// Prefers lower fret numbers; breaks ties by favoring middle strings.
    func mapToGuitar(_ midi: Int) -> (string: Int, fret: Int)? {
        // openStringMIDI is [40, 45, 50, 55, 59, 64] (low E to high E)
        // We store strings as 0=high E, 5=low E (matching NoteEvent convention)
        var best: (string: Int, fret: Int)? = nil
        var bestScore = Int.max

        for (physIdx, openMIDI) in Self.openStringMIDI.enumerated() {
            let fret = midi - openMIDI
            guard fret >= 0 && fret <= 24 else { continue }

            // String index: physIdx 0 = low E (string 5), physIdx 5 = high E (string 0)
            let stringIdx = 5 - physIdx

            // Score: prefer lower frets, slightly prefer middle strings
            let fretPenalty = fret * 10
            let stringPenalty = abs(physIdx - 3) * 2  // middle strings preferred
            let score = fretPenalty + stringPenalty

            if score < bestScore {
                bestScore = score
                best = (string: stringIdx, fret: fret)
            }
        }

        return best
    }
}
