//
//  TabMakerViewModel.swift
//  TabBuddy
//
//  ViewModel for the tab maker editor. Manages note CRUD, draft state,
//  audio preview, and playback coordination.
//

import Foundation
import SwiftData
import Combine
import AVFoundation

/// The active editing tool
enum MakerTool: String, CaseIterable {
    case pencil
    case eraser
}

/// Transient state for a note being placed/dragged
struct DraftNote: Equatable {
    var measureIndex: Int
    var positionInMeasure: Double
    var staffStep: Int
    var accidental: Int
    var midiPitch: Int
    var suggestedString: Int?
    var suggestedFret: Int?
}

/// Duration options for the note value picker
enum NoteDuration: CaseIterable, Identifiable {
    case whole, half, quarter, eighth, sixteenth

    var id: String { label }

    var beats: Double {
        switch self {
        case .whole: return 4.0
        case .half: return 2.0
        case .quarter: return 1.0
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        }
    }

    var label: String {
        switch self {
        case .whole: return "W"
        case .half: return "H"
        case .quarter: return "Q"
        case .eighth: return "8"
        case .sixteenth: return "16"
        }
    }
}

@MainActor
final class TabMakerViewModel: ObservableObject {

    // MARK: - Published State

    @Published var activeTool: MakerTool = .pencil
    @Published var selectedDuration: NoteDuration = .quarter
    @Published var draftNote: DraftNote?
    @Published var notes: [ComposedNote] = []

    @Published var isPlaying: Bool = false
    @Published var playbackMeasureIndex: Int = 0
    @Published var playbackBeatFraction: Double = 0

    @Published var isTranscribing: Bool = false
    @Published var transcriptionNoteName: String = "-"
    @Published var transcriptionConfidence: Double = 0

    // MARK: - Model Reference

    let composedTab: ComposedTab

    /// Cached tuning MIDI to avoid JSON decode on every frame.
    /// Updated when tuning changes.
    private(set) var cachedTuningMIDI: [Int]

    // MARK: - Audio

    let notePlayer = NotePlaybackEngine()
    let playbackCoordinator = PlaybackCoordinator()

    private var lastPreviewedMIDI: Int?
    private var previousTool: MakerTool = .eraser

    // MARK: - Live Transcription

    let pitchDetector = PitchDetector()
    private var transcriptionCancellables = Set<AnyCancellable>()
    private var transcriptionCursorMeasure: Int = 0
    private var transcriptionCursorBeat: Double = 0
    private var lastProcessedNoteCount: Int = 0

    // MARK: - Sync debouncing

    private var needsSync = false

    // MARK: - Init

    init(composedTab: ComposedTab) {
        self.composedTab = composedTab
        self.notes = composedTab.notes
        self.cachedTuningMIDI = composedTab.tuningMIDI

        setupPlayback()
        setupTranscription()
    }

    // MARK: - Tool Management

    func toggleTool() {
        let current = activeTool
        activeTool = previousTool
        previousTool = current
    }

    // MARK: - Draft Note (during drag)

    func updateDraftNote(measureIndex: Int, positionInMeasure: Double, staffStep: Int) {
        let clamped = max(StaffPitchMapper.guitarLowestStep,
                          min(StaffPitchMapper.guitarHighestStep, staffStep))

        // Skip if step hasn't changed during a drag
        if let existing = draftNote,
           existing.measureIndex == measureIndex,
           existing.staffStep == clamped {
            return
        }

        let accidental = draftNote?.accidental ?? 0
        let midi = StaffPitchMapper.midiPitch(staffStep: clamped, accidental: accidental)
        let clampedMIDI = StaffPitchMapper.clampToGuitarRange(midi)

        let suggestion = FretSuggestionEngine.suggest(
            midiPitch: clampedMIDI,
            tuningMIDI: cachedTuningMIDI
        )

        draftNote = DraftNote(
            measureIndex: measureIndex,
            positionInMeasure: positionInMeasure,
            staffStep: clamped,
            accidental: accidental,
            midiPitch: clampedMIDI,
            suggestedString: suggestion?.string,
            suggestedFret: suggestion?.fret
        )

        if clampedMIDI != lastPreviewedMIDI {
            lastPreviewedMIDI = clampedMIDI
            notePlayer.start()
            notePlayer.playMIDI(clampedMIDI)
        }
    }

    func commitDraftNote() {
        guard let draft = draftNote else { return }

        let note = ComposedNote(
            measureIndex: draft.measureIndex,
            positionInMeasure: draft.positionInMeasure,
            durationInBeats: selectedDuration.beats,
            midiPitch: draft.midiPitch,
            staffStep: draft.staffStep,
            accidental: draft.accidental,
            selectedString: draft.suggestedString,
            selectedFret: draft.suggestedFret
        )

        notes.append(note)
        syncNotesToModel()
        draftNote = nil
        lastPreviewedMIDI = nil
    }

    func cancelDraft() {
        draftNote = nil
        lastPreviewedMIDI = nil
    }

    // MARK: - Note Editing

    func noteAt(measureIndex: Int, positionInMeasure: Double, staffStep: Int) -> ComposedNote? {
        let positionThreshold = 0.05
        let stepThreshold = 1

        return notes.first { note in
            note.measureIndex == measureIndex &&
            abs(note.positionInMeasure - positionInMeasure) < positionThreshold &&
            abs(note.staffStep - staffStep) <= stepThreshold
        }
    }

    func moveNote(id: UUID, toStaffStep staffStep: Int) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(StaffPitchMapper.guitarLowestStep,
                          min(StaffPitchMapper.guitarHighestStep, staffStep))

        // Skip if step hasn't changed
        guard notes[index].staffStep != clamped else { return }

        let accidental = notes[index].accidental
        let midi = StaffPitchMapper.clampToGuitarRange(
            StaffPitchMapper.midiPitch(staffStep: clamped, accidental: accidental)
        )

        notes[index].staffStep = clamped
        notes[index].midiPitch = midi

        if let suggestion = FretSuggestionEngine.suggest(
            midiPitch: midi,
            tuningMIDI: cachedTuningMIDI
        ) {
            notes[index].selectedString = suggestion.string
            notes[index].selectedFret = suggestion.fret
        }

        scheduleSyncNotesToModel()

        if midi != lastPreviewedMIDI {
            lastPreviewedMIDI = midi
            notePlayer.start()
            notePlayer.playMIDI(midi)
        }
    }

    func deleteNote(id: UUID) {
        let countBefore = notes.count
        notes.removeAll { $0.id == id }
        if notes.count != countBefore {
            syncNotesToModel()
        }
    }

    func eraseAt(measureIndex: Int, positionInMeasure: Double, staffStep: Int) {
        if let note = noteAt(measureIndex: measureIndex,
                             positionInMeasure: positionInMeasure,
                             staffStep: staffStep) {
            deleteNote(id: note.id)
        }
    }

    // MARK: - Document Settings

    func setTuning(_ tuning: GuitarTuning) {
        composedTab.tuningName = tuning.name
        composedTab.tuningMIDI = tuning.midiNotes
        cachedTuningMIDI = tuning.midiNotes

        for i in notes.indices {
            if let suggestion = FretSuggestionEngine.suggest(
                midiPitch: notes[i].midiPitch,
                tuningMIDI: tuning.midiNotes
            ) {
                notes[i].selectedString = suggestion.string
                notes[i].selectedFret = suggestion.fret
            }
        }
        syncNotesToModel()
    }

    func setTimeSignature(beats: Int, noteValue: Int) {
        composedTab.beatsPerMeasure = beats
        composedTab.noteValue = noteValue
    }

    func addMeasure() {
        composedTab.measureCount += 1
    }

    func removeMeasure() {
        guard composedTab.measureCount > 1 else { return }
        let lastIndex = composedTab.measureCount - 1
        notes.removeAll { $0.measureIndex == lastIndex }
        composedTab.measureCount -= 1
        syncNotesToModel()
    }

    // MARK: - Playback

    private func setupPlayback() {
        playbackCoordinator.onFrameUpdate = { [weak self] measureIdx, fraction in
            guard let self else { return }
            self.playbackMeasureIndex = measureIdx
            self.playbackBeatFraction = fraction
        }

        playbackCoordinator.onNoteReached = { [weak self] noteEvents in
            guard let self else { return }
            var mergedFrets: [Int?] = Array(repeating: nil, count: 6)
            for event in noteEvents {
                for (i, fret) in event.frets.enumerated() {
                    if fret != nil { mergedFrets[i] = fret }
                }
            }
            self.notePlayer.playNotes(mergedFrets, tuningMIDI: self.cachedTuningMIDI)
        }
    }

    func togglePlayback() {
        if isPlaying { stopPlayback() } else { startPlayback() }
    }

    func startPlayback() {
        let map = buildMeasureMap()
        playbackCoordinator.measureMap = map
        playbackCoordinator.bpm = composedTab.bpm
        notePlayer.isEnabled = true
        notePlayer.start()
        playbackCoordinator.play()
        isPlaying = true
    }

    func stopPlayback() {
        playbackCoordinator.stop()
        notePlayer.stopNotes()
        isPlaying = false
        playbackMeasureIndex = 0
        playbackBeatFraction = 0
    }

    func buildMeasureMap() -> MeasureMap {
        MeasureMapBuilder.build(
            notes: notes,
            beatsPerMeasure: composedTab.beatsPerMeasure,
            noteValue: composedTab.noteValue,
            measureCount: composedTab.measureCount,
            bpm: composedTab.bpm,
            tuningMIDI: cachedTuningMIDI
        )
    }

    // MARK: - Live Transcription

    private func setupTranscription() {
        pitchDetector.$detectedNotes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] allNotes in
                guard let self, self.isTranscribing else { return }
                let newCount = allNotes.count
                guard newCount > self.lastProcessedNoteCount else { return }
                for i in self.lastProcessedNoteCount..<newCount {
                    self.handleDetectedNote(allNotes[i])
                }
                self.lastProcessedNoteCount = newCount
            }
            .store(in: &transcriptionCancellables)

        pitchDetector.$currentNote
            .receive(on: DispatchQueue.main)
            .assign(to: &$transcriptionNoteName)

        pitchDetector.$confidence
            .receive(on: DispatchQueue.main)
            .assign(to: &$transcriptionConfidence)
    }

    func toggleTranscription() {
        if isTranscribing { stopTranscription() } else { startTranscription() }
    }

    func startTranscription() {
        if isPlaying { stopPlayback() }

        if let lastNote = notes.max(by: {
            ($0.measureIndex, $0.positionInMeasure) < ($1.measureIndex, $1.positionInMeasure)
        }) {
            transcriptionCursorMeasure = lastNote.measureIndex
            transcriptionCursorBeat = lastNote.positionInMeasure * Double(composedTab.beatsPerMeasure)
                + lastNote.durationInBeats
            advanceCursorIfNeeded()
        } else {
            transcriptionCursorMeasure = 0
            transcriptionCursorBeat = 0
        }

        lastProcessedNoteCount = pitchDetector.detectedNotes.count
        pitchDetector.startListening()
        isTranscribing = true
    }

    func stopTranscription() {
        pitchDetector.stopListening()
        isTranscribing = false
    }

    private func handleDetectedNote(_ detected: DetectedNote) {
        let midi = detected.midi
        let (staffStep, accidental) = StaffPitchMapper.staffPosition(midiPitch: midi)
        let clampedMIDI = StaffPitchMapper.clampToGuitarRange(midi)
        let beatsPerMeasure = Double(composedTab.beatsPerMeasure)
        let positionInMeasure = transcriptionCursorBeat / beatsPerMeasure

        while transcriptionCursorMeasure >= composedTab.measureCount {
            composedTab.measureCount += 1
        }

        let suggestion = FretSuggestionEngine.suggest(
            midiPitch: clampedMIDI,
            tuningMIDI: cachedTuningMIDI
        )

        let note = ComposedNote(
            measureIndex: transcriptionCursorMeasure,
            positionInMeasure: max(0, min(1, positionInMeasure)),
            durationInBeats: selectedDuration.beats,
            midiPitch: clampedMIDI,
            staffStep: staffStep,
            accidental: accidental,
            selectedString: suggestion?.string,
            selectedFret: suggestion?.fret
        )

        notes.append(note)
        syncNotesToModel()

        transcriptionCursorBeat += selectedDuration.beats
        advanceCursorIfNeeded()
    }

    private func advanceCursorIfNeeded() {
        let beatsPerMeasure = Double(composedTab.beatsPerMeasure)
        while transcriptionCursorBeat >= beatsPerMeasure {
            transcriptionCursorBeat -= beatsPerMeasure
            transcriptionCursorMeasure += 1
        }
    }

    // MARK: - Persistence

    private func syncNotesToModel() {
        composedTab.notes = notes
        needsSync = false
    }

    /// Deferred sync for hot paths (drag operations). Commits on next run loop
    /// if not already synced by a direct call.
    private func scheduleSyncNotesToModel() {
        guard !needsSync else { return }
        needsSync = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsSync else { return }
            self.syncNotesToModel()
        }
    }
}
