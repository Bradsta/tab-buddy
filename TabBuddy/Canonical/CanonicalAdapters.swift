//
//  CanonicalAdapters.swift
//  TabBuddy
//
//  Conversions between CanonicalTab and the rest of the app's models:
//    • MeasureMap  -> CanonicalTab   (text/PDF import path)
//    • CanonicalTab -> MeasureMap    (feed the existing PlaybackCoordinator)
//    • CanonicalTab <-> ComposedTab  (load into the Maker for correction)
//    • CanonicalTab -> ASCII         (text diff vs. the original)
//
//  Reuses StaffPitchMapper, FretSuggestionEngine, and MeasureMapBuilder.
//

import Foundation
import CoreGraphics

enum CanonicalAdapters {

    // MARK: - MeasureMap -> CanonicalTab  (import)

    /// Build a canonical from a parsed `MeasureMap`. Derives `midiPitch` and
    /// diatonic spelling from tuning + string + fret. Rhythm is treated as
    /// synthesized (the source rarely encodes precise durations).
    static func canonicalTab(from map: MeasureMap,
                             title: String,
                             artist: String? = nil,
                             sourceType: Provenance.SourceType) -> CanonicalTab {
        let tuning = tuningMIDI(forName: map.tuning) ?? GuitarTuning.standard.midiNotes
        let beats = map.timeSignature?.beats ?? 4
        let noteValue = map.timeSignature?.noteValue ?? 4
        let capo = map.capoSemitones ?? 0

        var measures: [CanonicalMeasure] = []
        var notesTotal = 0
        var notesWithDuration = 0

        for measure in map.allMeasures {
            let events = measure.notes ?? []
            let onsetCount = max(1, events.count)
            var canonNotes: [CanonicalNote] = []
            for (i, event) in events.enumerated() {
                var ev = event
                let hadDuration = ev.durationInBeats != nil
                if map.isFreeTime {
                    // Even spacing within the measure; durations genuinely synthesized.
                    ev.positionInMeasure = Double(i) / Double(onsetCount)
                    ev.durationInBeats = 1.0
                }
                let stack = canonicalNotes(from: ev, tuningMIDI: tuning, beats: beats, capo: capo)
                if hadDuration && !map.isFreeTime { notesWithDuration += stack.count }
                canonNotes.append(contentsOf: stack)
            }
            notesTotal += canonNotes.count
            let mBeats = map.isFreeTime ? onsetCount : measure.beatCount
            measures.append(CanonicalMeasure(number: measure.measureNumber,
                                             notes: canonNotes,
                                             beatCount: mBeats))
        }

        // Confidence: coverage of measures that actually carried notes.
        let withNotes = measures.filter { !$0.notes.isEmpty }.count
        let coverage = measures.isEmpty ? 0 : Double(withNotes) / Double(measures.count)
        let confidence = notesTotal == 0 ? 0.1 : min(1.0, 0.4 + 0.6 * coverage)

        // Rhythm is "authored" only when a real rhythm line drove ≥50% of notes.
        let rhythmSource: Provenance.RhythmSource =
            (map.rhythmAuthored && notesTotal > 0 &&
             Double(notesWithDuration) / Double(notesTotal) >= 0.5) ? .authored : .synthesized

        let provenance = Provenance(sourceType: sourceType,
                                    confidence: confidence,
                                    converterVersion: CanonicalConverterVersion.current,
                                    rhythmSource: rhythmSource,
                                    clipped: false,
                                    isFreeTime: map.isFreeTime)

        // Title resolution (`title` arg = filename fallback):
        //  • PDF text extraction is unreliable (music-font glyphs, fragments) →
        //    always use the filename.
        //  • If the filename already contains the in-file title, the filename is
        //    the more specific form (e.g. "Zelda Wind Waker - Outset Island" ⊇
        //    "Outset Island") → keep the filename.
        //  • Otherwise the in-file title is fuller/different → use it.
        let resolvedTitle: String = {
            guard sourceType != .pdfText,
                  let inFile = map.title?.trimmingCharacters(in: .whitespaces), !inFile.isEmpty
            else { return title }
            func norm(_ s: String) -> String {
                s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            }
            return norm(title).contains(norm(inFile)) ? title : inFile
        }()
        let resolvedArtist = map.artist ?? artist
        let capoOffsets = capo == 0 ? [] : Array(repeating: capo, count: tuning.count)

        return CanonicalTab(title: resolvedTitle,
                            artist: resolvedArtist,
                            comments: map.comments,
                            tuningMIDI: tuning,
                            tuningName: map.tuning ?? GuitarTuning.standard.name,
                            capoOffsets: capoOffsets,
                            beatsPerMeasure: beats,
                            noteValue: noteValue,
                            bpm: map.bpm,
                            measures: measures,
                            provenance: provenance)
    }

    /// Expand one `NoteEvent` (which may sound several strings) into a chord
    /// stack of `CanonicalNote`s — first non-nil string is the chord head.
    /// `capo` shifts the *sounding* pitch (string + capo + fret); the physical
    /// `string`/`fret` fingering the ASCII encodes is preserved as-is.
    private static func canonicalNotes(from event: NoteEvent,
                                       tuningMIDI: [Int],
                                       beats: Int,
                                       capo: Int) -> [CanonicalNote] {
        var out: [CanonicalNote] = []
        let duration = event.durationInBeats ?? 1.0
        for (s, fret) in event.frets.enumerated() {
            guard let fret, s < tuningMIDI.count else { continue }
            let midi = tuningMIDI[s] + capo + fret
            let pos = StaffPitchMapper.staffPosition(midiPitch: midi)
            out.append(CanonicalNote(positionInMeasure: event.positionInMeasure,
                                     durationInBeats: duration,
                                     midiPitch: midi,
                                     staffStep: pos.staffStep,
                                     accidental: pos.accidental,
                                     string: s,
                                     fret: fret,
                                     isChordedWithPrevious: !out.isEmpty))
        }
        return out
    }

    // MARK: - CanonicalTab -> MeasureMap  (playback)

    /// Produce a `MeasureMap` for the existing `PlaybackCoordinator`, reusing
    /// `MeasureMapBuilder` so playback semantics match the Maker exactly.
    static func measureMap(from tab: CanonicalTab) -> MeasureMap {
        let notes = composedNotes(from: tab)
        return MeasureMapBuilder.build(notes: notes,
                                       beatsPerMeasure: tab.beatsPerMeasure,
                                       noteValue: tab.noteValue,
                                       measureCount: max(tab.measureCount, 1),
                                       bpm: tab.bpm ?? 120,
                                       tuningMIDI: tab.tuningMIDI)
    }

    // MARK: - CanonicalTab <-> ComposedTab  (Maker correction surface)

    /// Map canonical notes to the Maker's `[ComposedNote]` working format.
    static func composedNotes(from tab: CanonicalTab) -> [ComposedNote] {
        var out: [ComposedNote] = []
        for (mIndex, measure) in tab.measures.enumerated() {
            for note in measure.notes {
                out.append(ComposedNote(measureIndex: mIndex,
                                        positionInMeasure: note.positionInMeasure,
                                        durationInBeats: note.durationInBeats,
                                        midiPitch: note.midiPitch,
                                        staffStep: note.staffStep,
                                        accidental: note.accidental,
                                        selectedString: note.string,
                                        selectedFret: note.fret))
            }
        }
        return out
    }

    /// Instantiate a `ComposedTab` (Maker document) from a canonical. Not
    /// inserted into any `ModelContext` — the caller decides persistence.
    static func makeComposedTab(from tab: CanonicalTab) -> ComposedTab {
        let composed = ComposedTab(title: tab.title,
                                   beatsPerMeasure: tab.beatsPerMeasure,
                                   noteValue: tab.noteValue,
                                   tuning: GuitarTuning(name: tab.tuningName, midiNotes: tab.tuningMIDI),
                                   bpm: tab.bpm ?? 120,
                                   measureCount: max(tab.measureCount, 1))
        composed.notes = composedNotes(from: tab)
        return composed
    }

    /// Rebuild a canonical from an edited `ComposedTab` (re-emit after the user
    /// fixes a fret in the Maker). Preserves prior provenance but marks the
    /// rhythm/source as authored where the user has touched it.
    static func canonicalTab(from composed: ComposedTab,
                             basedOn previous: Provenance? = nil) -> CanonicalTab {
        let composedNotes = composed.notes
        let tuning = composed.tuningMIDI

        var measures: [CanonicalMeasure] = []
        for mIndex in 0..<max(composed.measureCount, 1) {
            let notesForMeasure = composedNotes
                .filter { $0.measureIndex == mIndex }
                .sorted { $0.positionInMeasure < $1.positionInMeasure }

            var canon: [CanonicalNote] = []
            var lastPosition: Double? = nil
            for n in notesForMeasure {
                let string = n.selectedString
                    ?? FretSuggestionEngine.suggest(midiPitch: n.midiPitch, tuningMIDI: tuning)?.string
                let fret = n.selectedFret
                    ?? FretSuggestionEngine.suggest(midiPitch: n.midiPitch, tuningMIDI: tuning)?.fret
                let chorded = (lastPosition != nil) && abs((lastPosition ?? -1) - n.positionInMeasure) < 1e-6
                canon.append(CanonicalNote(positionInMeasure: n.positionInMeasure,
                                           durationInBeats: n.durationInBeats,
                                           midiPitch: n.midiPitch,
                                           staffStep: n.staffStep,
                                           accidental: n.accidental,
                                           string: string,
                                           fret: fret,
                                           isChordedWithPrevious: chorded))
                lastPosition = n.positionInMeasure
            }
            measures.append(CanonicalMeasure(number: mIndex + 1,
                                             notes: canon,
                                             beatCount: composed.beatsPerMeasure))
        }

        var provenance = previous ?? Provenance()
        provenance.sourceType = .composed
        provenance.rhythmSource = .authored
        provenance.confidence = max(provenance.confidence, 0.99)
        provenance.converterVersion = CanonicalConverterVersion.current

        return CanonicalTab(title: composed.title,
                            tuningMIDI: tuning,
                            tuningName: composed.tuningName,
                            beatsPerMeasure: composed.beatsPerMeasure,
                            noteValue: composed.noteValue,
                            bpm: composed.bpm,
                            measures: measures,
                            provenance: provenance)
    }

    // MARK: - CanonicalTab -> ASCII  (diff surface)

    /// Render a canonical as 6-line ASCII tab for diffing against the original.
    /// Measures are laid out left-to-right, wrapped into systems.
    static func asciiTab(from tab: CanonicalTab,
                         measuresPerSystem: Int = 4,
                         measureWidth: Int = 16) -> String {
        let stringCount = tab.tuningMIDI.count
        guard stringCount > 0 else { return "" }
        let labels = stringLabels(for: tab.tuningMIDI)

        var lines: [String] = []
        // Header
        lines.append(tab.title)
        if let artist = tab.artist { lines.append(artist) }
        var tuningLine = "Tuning: \(tab.tuningName)  (\(labels.joined()))"
        if let capo = tab.capoOffsets.first, capo > 0 { tuningLine += "  Capo \(capo)" }
        if let bpm = tab.bpm { tuningLine += "  Tempo: \(Int(bpm))" }
        lines.append(tuningLine)
        if tab.provenance.isFreeTime { lines.append("(free time — unmetered, even spacing)") }
        lines.append("")

        // Show the rhythm row only when durations are authored (real rhythm line).
        let showRhythm = tab.provenance.rhythmSource == .authored
        let measures = tab.measures
        var index = 0
        while index < measures.count {
            let slice = Array(measures[index..<min(index + measuresPerSystem, measures.count)])
            lines.append(contentsOf: renderSystem(slice,
                                                  stringCount: stringCount,
                                                  labels: labels,
                                                  measureWidth: measureWidth,
                                                  showRhythm: showRhythm))
            lines.append("")
            index += measuresPerSystem
        }

        return lines.joined(separator: "\n")
    }

    private static func renderSystem(_ measures: [CanonicalMeasure],
                                     stringCount: Int,
                                     labels: [String],
                                     measureWidth: Int,
                                     showRhythm: Bool) -> [String] {
        // One row buffer per string, high-E-first (index 0 on top).
        var rows = (0..<stringCount).map { s -> [Character] in
            Array("\(labels[s])|")
        }
        // Rhythm row, aligned to the same prefix width as the string rows.
        let prefixWidth = (labels.first?.count ?? 1) + 1
        var rhythmRow = Array(String(repeating: " ", count: prefixWidth))

        for measure in measures {
            // Start each measure with a dash field, then a trailing barline.
            var fields = rows.indices.map { _ in Array(repeating: Character("-"), count: measureWidth) }
            var rhythmField = Array(repeating: Character(" "), count: measureWidth)

            for note in measure.notes {
                guard let s = note.string, let f = note.fret, s < stringCount else { continue }
                let digits = Array("\(f)")
                let col = max(0, min(measureWidth - digits.count,
                                     Int((note.positionInMeasure * Double(measureWidth - 1)).rounded())))
                for (k, ch) in digits.enumerated() where col + k < measureWidth {
                    fields[s][col + k] = ch
                }
                // One rhythm letter per onset (chord head), same column as the fret.
                if showRhythm, !note.isChordedWithPrevious {
                    let letter = Array(RhythmDuration.nearest(toBeats: note.durationInBeats).notation)
                    for (k, ch) in letter.enumerated() where col + k < measureWidth {
                        rhythmField[col + k] = ch
                    }
                }
            }

            if showRhythm {
                rhythmRow.append(contentsOf: rhythmField)
                rhythmRow.append(" ")
            }
            for s in rows.indices {
                rows[s].append(contentsOf: fields[s])
                rows[s].append("|")
            }
        }

        let stringLines = rows.map { String($0) }
        return showRhythm ? [String(rhythmRow)] + stringLines : stringLines
    }

    // MARK: - Helpers

    /// Single-letter string labels (high-E-first) from open-string MIDI notes.
    private static func stringLabels(for tuningMIDI: [Int]) -> [String] {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return tuningMIDI.map { midi in
            let name = names[((midi % 12) + 12) % 12]
            // lowercase single letter where possible for the classic tab look
            return name.count == 1 ? name.lowercased() : name
        }
    }

    /// Best-effort tuning lookup by name (e.g. "Drop D"); nil if unrecognized.
    private static func tuningMIDI(forName name: String?) -> [Int]? {
        guard let name else { return nil }
        return GuitarTuning.allPresets.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.midiNotes
    }
}
