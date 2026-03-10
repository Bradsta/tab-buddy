//
//  PlaybackCoordinator.swift
//  TabBuddy
//
//  BPM-driven playback timing engine. Consumes a MeasureMap and drives
//  the highlight position and scroll. Shared by text and PDF playback.
//

import Foundation
import QuartzCore
import Combine

@MainActor
final class PlaybackCoordinator: NSObject, ObservableObject {

    // MARK: - Published state

    /// Current BPM (user-adjustable)
    @Published var bpm: Double = 120

    /// Whether playback is active
    @Published var isPlaying: Bool = false

    /// Current measure index (0-based into measureMap.allMeasures)
    @Published var currentMeasureIndex: Int = 0

    /// Fractional position within the current measure (0.0–1.0)
    @Published var beatFraction: Double = 0

    /// Total accumulated beats since playback start
    @Published var accumulatedBeats: Double = 0

    // MARK: - Configuration

    /// The parsed tab structure driving playback
    var measureMap: MeasureMap? {
        didSet { reset() }
    }

    /// Loop boundaries (measure indices, inclusive)
    var loopStartMeasure: Int?
    var loopEndMeasure: Int?

    /// Callback when the current system changes (for scroll coordination)
    var onSystemChanged: ((Int) -> Void)?

    /// Callback each frame with the current measure index and beat fraction
    var onFrameUpdate: ((Int, Double) -> Void)?

    /// Callback on each beat boundary (for metronome)
    var onBeat: ((Int, Int) -> Void)?  // (beatInMeasure, beatsPerMeasure)

    /// Callback when playback reaches note positions within a measure
    var onNoteReached: (([NoteEvent]) -> Void)?

    // MARK: - Internal state

    private var displayLink: CADisplayLink?
    private var lastBeatInteger: Int = -1
    private var currentSystemIndex: Int = 0

    /// Tracking for note-level triggers (avoid re-triggering same notes)
    private var lastMeasureForNotes: Int = -1
    private var triggeredNotePositions: Set<Int> = []  // column-based dedup

    // MARK: - Playback Control

    func play() {
        guard measureMap != nil else { return }
        isPlaying = true
        lastBeatInteger = -1
        startDisplayLink()
    }

    func pause() {
        isPlaying = false
        stopDisplayLink()
    }

    func stop() {
        isPlaying = false
        stopDisplayLink()
        reset()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seekToMeasure(_ index: Int) {
        guard let map = measureMap else { return }
        let clamped = max(0, min(index, map.allMeasures.count - 1))
        currentMeasureIndex = clamped
        beatFraction = 0
        accumulatedBeats = beatsUpToMeasure(clamped)
        lastBeatInteger = Int(accumulatedBeats) - 1
        lastMeasureForNotes = -1
        triggeredNotePositions.removeAll()
        updateSystemIndex()
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        stopDisplayLink()
        // Use a non-@MainActor wrapper since CADisplayLink target must be NSObject
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        } else {
            link.preferredFramesPerSecond = 30
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let map = measureMap, !map.allMeasures.isEmpty else { return }

        let dt = link.targetTimestamp - link.timestamp
        let beatsPerSecond = bpm / 60.0
        let beatsElapsed = beatsPerSecond * dt

        accumulatedBeats += beatsElapsed

        // Determine which measure we're in
        let measures = map.allMeasures
        var beatsConsumed: Double = 0
        var measureIdx = 0

        for (i, measure) in measures.enumerated() {
            let measureBeats = Double(measure.beatCount)
            if accumulatedBeats < beatsConsumed + measureBeats {
                measureIdx = i
                beatFraction = (accumulatedBeats - beatsConsumed) / measureBeats
                break
            }
            beatsConsumed += measureBeats
            measureIdx = i

            // If we've passed the last measure
            if i == measures.count - 1 {
                // Check for loop
                if let loopEnd = loopEndMeasure, let loopStart = loopStartMeasure,
                   measureIdx >= loopEnd {
                    seekToMeasure(loopStart)
                    return
                }
                // End of piece
                stop()
                return
            }
        }

        // Handle loop
        if let loopEnd = loopEndMeasure, let loopStart = loopStartMeasure,
           measureIdx > loopEnd {
            seekToMeasure(loopStart)
            return
        }

        currentMeasureIndex = measureIdx
        beatFraction = max(0, min(1, beatFraction))

        // Fire beat callback on integer beat boundaries
        let currentBeatInt = Int(accumulatedBeats)
        if currentBeatInt != lastBeatInteger {
            lastBeatInteger = currentBeatInt
            let measure = measures[measureIdx]
            let beatInMeasure = Int(beatFraction * Double(measure.beatCount))
            onBeat?(beatInMeasure, measure.beatCount)
        }

        // Fire note-reached callback for notes at or before current position
        if onNoteReached != nil {
            if measureIdx != lastMeasureForNotes {
                // New measure — reset triggered notes
                triggeredNotePositions.removeAll()
                lastMeasureForNotes = measureIdx
            }
            if let notes = measures[measureIdx].notes {
                var triggered: [NoteEvent] = []
                for note in notes {
                    // Use column as unique identifier (position alone can have duplicates)
                    let key = note.column ?? Int(note.positionInMeasure * 10000)
                    if note.positionInMeasure <= beatFraction,
                       !triggeredNotePositions.contains(key) {
                        triggeredNotePositions.insert(key)
                        triggered.append(note)
                    }
                }
                if !triggered.isEmpty {
                    onNoteReached?(triggered)
                }
            }
        }

        // Fire frame update
        onFrameUpdate?(measureIdx, beatFraction)

        // Check if system changed
        updateSystemIndex()
    }

    // MARK: - Helpers

    private func reset() {
        currentMeasureIndex = 0
        beatFraction = 0
        accumulatedBeats = 0
        lastBeatInteger = -1
        currentSystemIndex = 0
        lastMeasureForNotes = -1
        triggeredNotePositions.removeAll()
    }

    /// Calculate total beats up to (but not including) a measure index.
    private func beatsUpToMeasure(_ index: Int) -> Double {
        guard let map = measureMap else { return 0 }
        return map.allMeasures.prefix(index).reduce(0.0) { $0 + Double($1.beatCount) }
    }

    /// Update the current system index and fire callback if changed.
    private func updateSystemIndex() {
        guard let map = measureMap else { return }
        var measuresSeen = 0
        for (sysIdx, system) in map.systems.enumerated() {
            measuresSeen += system.measures.count
            if currentMeasureIndex < measuresSeen {
                if sysIdx != currentSystemIndex {
                    currentSystemIndex = sysIdx
                    onSystemChanged?(sysIdx)
                }
                return
            }
        }
    }
}
