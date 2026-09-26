//
//  PassageBuilder.swift
//  TabBuddy
//
//  Adapters that turn scores and exercises into an `ExpectedPassage`
//  (TUTOR_IMPLEMENTATION.md §5). Pure value code; no UI or audio I/O except the
//  MIDI file reader, which uses AudioToolbox like `MIDITempoExtractor`.
//
//  Beat units: MeasureMap and CanonicalTab sources count beats in the measure's
//  own beat unit (`Measure.beatCount`), which is what `PlaybackCoordinator`
//  advances at `bpm`. For x/4 meters this equals the quarter note. MIDI and
//  alphaTab sources count quarter notes.
//
//  `ExpectedPassage.beatsPerMeasure` is always in the passage's own beat unit
//  (it sets the count-in length and the accented pulse). For quarter-note
//  sources an x/8 bar is converted: 6/8 → 3, 12/8 → 6, 3/8 → 2 (1.5 rounded up);
//  bars that aren't a whole number of quarters (5/8, 7/8, 9/8) round up.
//

import AudioToolbox
import Foundation

enum PassageBuilder {

    /// Onsets closer than this (in beats) merge into one event.
    static let simultaneityBeats = 1.0 / 48.0
    /// Default tempo when a source has none.
    static let fallbackBPM = 90.0

    // MARK: - MeasureMap

    /// Builds a passage from a parsed tab.
    /// - Parameters:
    ///   - measureRange: 0-based indices into `measureMap.allMeasures`; nil = all.
    ///   - bpm: overrides `measureMap.bpm` (fallback 90).
    /// - Returns: nil when the tuning has no octave information
    ///   (`resolvedOpenStringMIDI == nil`) or the range holds no notes.
    static func from(measureMap: MeasureMap,
                     measureRange: ClosedRange<Int>? = nil,
                     bpm: Double? = nil,
                     instrument: TutorInstrument = .guitar) -> ExpectedPassage? {
        guard let open = measureMap.resolvedOpenStringMIDI else { return nil }
        let measures = measureMap.allMeasures
        guard !measures.isEmpty else { return nil }
        let range = clamp(measureRange, count: measures.count)
        guard let range else { return nil }
        let capo = measureMap.capoSemitones ?? 0

        var raw: [RawNote] = []
        var measureStart = 0.0
        for index in range {
            let measure = measures[index]
            let events = measure.notes ?? []
            // Free-time tabs are spaced evenly inside the measure (matches the canonical adapter).
            let beats = measureMap.isFreeTime ? Double(max(1, events.count)) : Double(max(1, measure.beatCount))
            for (i, event) in events.enumerated() {
                let position = measureMap.isFreeTime ? Double(i) / Double(max(1, events.count)) : event.positionInMeasure
                var pitches: [Int] = []
                var fretting: [FretPosition] = []
                for (string, fret) in event.frets.enumerated() {
                    guard let fret, fret >= 0, open.indices.contains(string) else { continue }
                    pitches.append(open[string] + capo + fret)
                    fretting.append(FretPosition(string: string, fret: fret))
                }
                guard !pitches.isEmpty else { continue }
                let chord = measure.chords?.first(where: { abs($0.position - position) < 0.02 })?.name
                raw.append(RawNote(beat: measureStart + position * beats,
                                   duration: measureMap.isFreeTime ? 1 : event.durationInBeats,
                                   pitches: pitches, measureIndex: index,
                                   positionInMeasure: position, chordName: chord, fretting: fretting))
            }
            measureStart += beats
        }
        let passageBPM = bpm ?? measureMap.bpm ?? fallbackBPM
        let beatsPerMeasure = measureMap.timeSignature?.beats ?? measures[range.lowerBound].beatCount
        return passage(from: raw, totalBeats: measureStart, beatsPerMeasure: beatsPerMeasure,
                       bpm: passageBPM, instrument: instrument, isFreeTime: measureMap.isFreeTime)
    }

    // MARK: - CanonicalTab

    /// Builds a passage from a canonical tab. `midiPitch` already includes the capo.
    static func from(canonical: CanonicalTab,
                     measureRange: ClosedRange<Int>? = nil,
                     bpm: Double? = nil,
                     instrument: TutorInstrument = .guitar) -> ExpectedPassage? {
        guard let range = clamp(measureRange, count: canonical.measures.count) else { return nil }
        var raw: [RawNote] = []
        var measureStart = 0.0
        for index in range {
            let measure = canonical.measures[index]
            let beats = Double(max(1, measure.beatCount))
            for note in measure.notes where note.midiPitch >= 0 && note.midiPitch <= 127 {
                let fret = (note.string != nil && note.fret != nil)
                    ? [FretPosition(string: note.string!, fret: note.fret!)] : []
                let chord = measure.chords.first(where: { abs($0.positionInMeasure - note.positionInMeasure) < 0.02 })?.name
                raw.append(RawNote(beat: measureStart + note.positionInMeasure * beats,
                                   duration: note.durationInBeats, pitches: [note.midiPitch],
                                   measureIndex: index, positionInMeasure: note.positionInMeasure,
                                   chordName: chord, fretting: fret))
            }
            measureStart += beats
        }
        return passage(from: raw, totalBeats: measureStart, beatsPerMeasure: canonical.beatsPerMeasure,
                       bpm: bpm ?? canonical.bpm ?? fallbackBPM, instrument: instrument,
                       isFreeTime: canonical.provenance.isFreeTime)
    }

    // MARK: - MIDI file

    /// Builds a passage from a Standard MIDI File.
    /// - Parameters:
    ///   - track: index among the file's tracks in file order, tempo track excluded;
    ///     nil merges every track except channel 10 (drums).
    ///   - measureRange: 0-based measures computed from the first time signature.
    ///   - bpm: overrides the file's first tempo. Later tempo changes are ignored.
    static func from(midiFileURL url: URL,
                     track: Int? = nil,
                     measureRange: ClosedRange<Int>? = nil,
                     bpm: Double? = nil,
                     instrument: TutorInstrument = .piano) -> ExpectedPassage? {
        var sequence: MusicSequence?
        guard NewMusicSequence(&sequence) == noErr, let seq = sequence else { return nil }
        defer { DisposeMusicSequence(seq) }
        // Empty flags keep the file's track order (the conductor track becomes the tempo track).
        guard MusicSequenceFileLoad(seq, url as CFURL, .midiType, MusicSequenceLoadFlags()) == noErr else { return nil }

        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(seq, &trackCount)
        var notes: [(beat: Double, duration: Double, midi: Int)] = []
        for t in 0..<Int(trackCount) where track == nil || track == t {
            var musicTrack: MusicTrack?
            guard MusicSequenceGetIndTrack(seq, UInt32(t), &musicTrack) == noErr, let mt = musicTrack else { continue }
            notes += midiNotes(in: mt, skipDrums: track == nil)
        }
        guard !notes.isEmpty else { return nil }

        let tempo = MIDITempoExtractor.extract(from: url)
        let numerator = tempo?.timeSignature?.beats ?? 4
        let noteValue = tempo?.timeSignature?.noteValue ?? 4
        let measureQuarters = Double(numerator) * 4 / Double(max(1, noteValue))
        let beatsPerMeasure = quarterBeats(numerator: numerator, noteValue: noteValue)
        let firstMeasure = measureRange?.lowerBound ?? 0
        let offset = Double(firstMeasure) * measureQuarters

        var raw: [RawNote] = []
        for note in notes {
            let measure = Int((note.beat + 1e-6) / measureQuarters)
            if let measureRange, !measureRange.contains(measure) { continue }
            let position = (note.beat - Double(measure) * measureQuarters) / measureQuarters
            raw.append(RawNote(beat: note.beat - offset, duration: note.duration, pitches: [note.midi],
                               measureIndex: measure, positionInMeasure: max(0, min(0.999999, position)),
                               chordName: nil, fretting: []))
        }
        let lastMeasure = raw.map(\.measureIndex).max() ?? firstMeasure
        let total = Double(lastMeasure + 1) * measureQuarters - offset
        return passage(from: raw, totalBeats: total, beatsPerMeasure: beatsPerMeasure,
                       bpm: bpm ?? tempo?.initialBPM ?? 120, instrument: instrument, isFreeTime: false)
    }

    private static func midiNotes(in track: MusicTrack, skipDrums: Bool) -> [(beat: Double, duration: Double, midi: Int)] {
        var iterator: MusicEventIterator?
        guard NewMusicEventIterator(track, &iterator) == noErr, let iter = iterator else { return [] }
        defer { DisposeMusicEventIterator(iter) }
        var out: [(beat: Double, duration: Double, midi: Int)] = []
        var hasEvent: DarwinBoolean = false
        MusicEventIteratorHasCurrentEvent(iter, &hasEvent)
        while hasEvent.boolValue {
            var timestamp: MusicTimeStamp = 0
            var type: MusicEventType = 0
            var data: UnsafeRawPointer?
            var size: UInt32 = 0
            MusicEventIteratorGetEventInfo(iter, &timestamp, &type, &data, &size)
            if type == kMusicEventType_MIDINoteMessage, let data {
                let message = data.load(as: MIDINoteMessage.self)
                if message.velocity > 0 && !(skipDrums && message.channel == 9) {
                    out.append((timestamp, Double(message.duration), Int(message.note)))
                }
            }
            MusicEventIteratorNextEvent(iter)
            MusicEventIteratorHasCurrentEvent(iter, &hasEvent)
        }
        return out
    }

    // MARK: - alphaTab export (Guitar Pro)

    /// One note group exported by the Guitar Pro web player (WP-F `exportNotes`).
    ///
    /// JSON object per played beat (one entry per alphaTab `Beat`, chords carry
    /// several `midi` values):
    ///
    /// | key               | type     | meaning |
    /// |-------------------|----------|---------|
    /// | `track`           | Int      | 0-based track index in the score |
    /// | `bar`             | Int      | 0-based master-bar index (score order, repeats not expanded) |
    /// | `start`           | Double   | onset tick, absolute from score start, score order (alphaTab `Beat.absoluteDisplayStart`) |
    /// | `duration`        | Double   | length in ticks |
    /// | `midi`            | [Int]    | sounding MIDI pitches (tuning + capo + fret, or the staff pitch); values outside 0...127 are skipped |
    /// | `tempo`           | Double   | quarter-note BPM in effect at the onset |
    /// | `ticksPerQuarter` | Int      | optional, default 960 |
    /// | `barStartTick`    | Double   | absolute tick of the bar's start |
    /// | `beatsPerBar`     | Int      | time-signature numerator of the bar |
    /// | `beatValue`       | Int      | optional time-signature denominator, default 4 |
    ///
    /// Tied continuations and dead/muted notes should be omitted by the exporter.
    /// Numbers may arrive as `Int`, `Double`, `NSNumber` or numeric `String`.
    struct AlphaTabNote: Codable, Hashable, Sendable {
        var track: Int
        var bar: Int
        var start: Double
        var duration: Double
        var midi: [Int]
        var tempo: Double
        var ticksPerQuarter: Int = 960
        var barStartTick: Double
        var beatsPerBar: Int
        var beatValue: Int = 4

        /// Parses one dictionary from a script message. Returns nil when a required key is missing.
        init?(dictionary d: [String: Any]) {
            func num(_ key: String) -> Double? {
                switch d[key] {
                case let v as Double: return v
                case let v as Int: return Double(v)
                case let v as NSNumber: return v.doubleValue
                case let v as String: return Double(v)
                default: return nil
                }
            }
            guard let bar = num("bar"), let start = num("start"), let barStart = num("barStartTick") else { return nil }
            let rawMidi: [Double]
            switch d["midi"] {
            case let list as [Any]:
                rawMidi = list.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? String).flatMap(Double.init) }
            case let single as NSNumber: rawMidi = [single.doubleValue]
            default: return nil
            }
            self.track = Int(num("track") ?? 0)
            self.bar = Int(bar)
            self.start = start
            self.duration = num("duration") ?? 0
            self.midi = rawMidi.map { Int($0.rounded()) }
            self.tempo = num("tempo") ?? 0
            self.ticksPerQuarter = Int(num("ticksPerQuarter") ?? 960)
            self.barStartTick = barStart
            self.beatsPerBar = Int(num("beatsPerBar") ?? 4)
            self.beatValue = Int(num("beatValue") ?? 4)
        }

        private enum CodingKeys: String, CodingKey {
            case track, bar, start, duration, midi, tempo, ticksPerQuarter, barStartTick, beatsPerBar, beatValue
        }

        /// JSON decoding with the same defaults as the dictionary parser.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            track = try c.decodeIfPresent(Int.self, forKey: .track) ?? 0
            bar = try c.decode(Int.self, forKey: .bar)
            start = try c.decode(Double.self, forKey: .start)
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            midi = try c.decode([Int].self, forKey: .midi)
            tempo = try c.decodeIfPresent(Double.self, forKey: .tempo) ?? 0
            ticksPerQuarter = try c.decodeIfPresent(Int.self, forKey: .ticksPerQuarter) ?? 960
            barStartTick = try c.decode(Double.self, forKey: .barStartTick)
            beatsPerBar = try c.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4
            beatValue = try c.decodeIfPresent(Int.self, forKey: .beatValue) ?? 4
        }

        init(track: Int, bar: Int, start: Double, duration: Double, midi: [Int], tempo: Double,
             ticksPerQuarter: Int = 960, barStartTick: Double, beatsPerBar: Int, beatValue: Int = 4) {
            self.track = track; self.bar = bar; self.start = start; self.duration = duration
            self.midi = midi; self.tempo = tempo; self.ticksPerQuarter = ticksPerQuarter
            self.barStartTick = barStartTick; self.beatsPerBar = beatsPerBar; self.beatValue = beatValue
        }
    }

    /// Builds a passage from alphaTab export dictionaries (see `AlphaTabNote`).
    /// Entries that fail to parse are skipped.
    static func from(alphaTabNotes dictionaries: [[String: Any]],
                     track: Int? = nil,
                     measureRange: ClosedRange<Int>? = nil,
                     bpm: Double? = nil,
                     instrument: TutorInstrument = .guitar) -> ExpectedPassage? {
        from(alphaTabNotes: dictionaries.compactMap(AlphaTabNote.init(dictionary:)),
             track: track, measureRange: measureRange, bpm: bpm, instrument: instrument)
    }

    /// Typed variant of the alphaTab adapter. `measureRange` filters on `bar`;
    /// beat 0 is the start of the first included bar.
    static func from(alphaTabNotes notes: [AlphaTabNote],
                     track: Int? = nil,
                     measureRange: ClosedRange<Int>? = nil,
                     bpm: Double? = nil,
                     instrument: TutorInstrument = .guitar) -> ExpectedPassage? {
        let selectedTrack = track ?? notes.first?.track
        let kept = notes.filter { $0.track == selectedTrack && (measureRange?.contains($0.bar) ?? true) }
            .sorted { $0.start < $1.start }
        guard let first = kept.min(by: { $0.bar < $1.bar }) else { return nil }
        let origin = kept.filter { $0.bar == first.bar }.map(\.barStartTick).min() ?? first.barStartTick
        var raw: [RawNote] = []
        var endBeat = 0.0
        for note in kept {
            let tpq = Double(max(1, note.ticksPerQuarter))
            let barTicks = Double(max(1, note.beatsPerBar)) * 4 / Double(max(1, note.beatValue)) * tpq
            let pitches = note.midi.filter { (0...127).contains($0) }
            endBeat = max(endBeat, (note.barStartTick + barTicks - origin) / tpq)
            guard !pitches.isEmpty else { continue }
            let position = max(0, min(0.999999, (note.start - note.barStartTick) / barTicks))
            raw.append(RawNote(beat: (note.start - origin) / tpq, duration: note.duration / tpq,
                               pitches: pitches, measureIndex: note.bar, positionInMeasure: position,
                               chordName: nil, fretting: []))
        }
        let tempo = bpm ?? kept.first(where: { $0.tempo > 0 })?.tempo ?? 120
        return passage(from: raw, totalBeats: endBeat,
                       beatsPerMeasure: quarterBeats(numerator: first.beatsPerBar, noteValue: first.beatValue),
                       bpm: tempo, instrument: instrument, isFreeTime: false)
    }

    /// A bar of `numerator`/`noteValue` in quarter notes, as a whole count
    /// (rounded up, at least 1). 4/4 → 4, 6/8 → 3, 2/2 → 4, 7/8 → 4.
    static func quarterBeats(numerator: Int, noteValue: Int) -> Int {
        let quarters = Double(max(1, numerator)) * 4 / Double(max(1, noteValue))
        return max(1, Int((quarters - 1e-9).rounded(.up)))
    }

    // MARK: - Exercises

    /// Builds a passage from explicit pitch groups (one group per event; an empty group is a rest).
    /// - Parameters:
    ///   - durations: beats per event; nil = one beat each. Shorter arrays repeat their last value.
    static func from(pitchEvents: [[Int]],
                     durations: [Double]? = nil,
                     bpm: Double,
                     beatsPerMeasure: Int = 4,
                     instrument: TutorInstrument,
                     isFreeTime: Bool = false,
                     chordNames: [String?]? = nil) -> ExpectedPassage {
        var raw: [RawNote] = []
        var beat = 0.0
        let bpmMeasure = Double(max(1, beatsPerMeasure))
        for (i, group) in pitchEvents.enumerated() {
            let duration = max(0.0001, durations.flatMap { $0.isEmpty ? nil : $0[min(i, $0.count - 1)] } ?? 1)
            let pitches = group.filter { (0...127).contains($0) }
            if !pitches.isEmpty {
                let measure = Int((beat + 1e-9) / bpmMeasure)
                raw.append(RawNote(beat: beat, duration: duration, pitches: pitches, measureIndex: measure,
                                   positionInMeasure: (beat - Double(measure) * bpmMeasure) / bpmMeasure,
                                   chordName: chordNames?[safeIndex: i] ?? nil, fretting: []))
            }
            beat += duration
        }
        return passage(from: raw, totalBeats: beat, beatsPerMeasure: beatsPerMeasure, bpm: bpm,
                       instrument: instrument, isFreeTime: isFreeTime, mergeSimultaneous: false)
            ?? ExpectedPassage(events: [], beatsPerMeasure: beatsPerMeasure, bpm: bpm, instrument: instrument,
                               isFreeTime: isFreeTime)
    }

    /// A single-note line (scale, melody), `beatsEach` beats per note.
    static func sequence(_ pitches: [Int], beatsEach: Double = 1, bpm: Double,
                         beatsPerMeasure: Int = 4, instrument: TutorInstrument) -> ExpectedPassage {
        from(pitchEvents: pitches.map { [$0] }, durations: [beatsEach], bpm: bpm,
             beatsPerMeasure: beatsPerMeasure, instrument: instrument)
    }

    /// Chords played in turn, each `repetitions` times for `beatsEach` beats (chord changes, strumming).
    static func chords(_ chords: [[Int]], names: [String]? = nil, beatsEach: Double = 4, repetitions: Int = 1,
                       bpm: Double, beatsPerMeasure: Int = 4, instrument: TutorInstrument) -> ExpectedPassage {
        var groups: [[Int]] = []
        var labels: [String?] = []
        for (i, chord) in chords.enumerated() {
            for _ in 0..<max(1, repetitions) {
                groups.append(chord)
                labels.append(names?[safeIndex: i])
            }
        }
        return from(pitchEvents: groups, durations: [beatsEach], bpm: bpm, beatsPerMeasure: beatsPerMeasure,
                    instrument: instrument, chordNames: labels)
    }

    // MARK: - Shared assembly

    private struct RawNote {
        var beat: Double
        var duration: Double?
        var pitches: [Int]
        var measureIndex: Int
        var positionInMeasure: Double
        var chordName: String?
        var fretting: [FretPosition]
    }

    private static func clamp(_ range: ClosedRange<Int>?, count: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        guard let range else { return 0...(count - 1) }
        let lo = max(0, range.lowerBound), hi = min(count - 1, range.upperBound)
        return lo <= hi ? lo...hi : nil
    }

    /// Sorts, merges simultaneous onsets, and fills durations from the next onset when missing.
    private static func passage(from raw: [RawNote], totalBeats: Double, beatsPerMeasure: Int, bpm: Double,
                                instrument: TutorInstrument, isFreeTime: Bool,
                                mergeSimultaneous: Bool = true) -> ExpectedPassage? {
        guard !raw.isEmpty else { return nil }
        let sorted = raw.sorted { $0.beat < $1.beat }
        var merged: [RawNote] = []
        for note in sorted {
            if mergeSimultaneous, var last = merged.last, abs(note.beat - last.beat) < simultaneityBeats {
                for (p, pitch) in note.pitches.enumerated() where !last.pitches.contains(pitch) {
                    last.pitches.append(pitch)
                    if note.fretting.indices.contains(p) { last.fretting.append(note.fretting[p]) }
                }
                last.chordName = last.chordName ?? note.chordName
                if let d = note.duration { last.duration = max(last.duration ?? 0, d) }
                merged[merged.count - 1] = last
            } else {
                merged.append(note)
            }
        }
        var events: [ExpectedEvent] = []
        for (i, note) in merged.enumerated() {
            let next = i + 1 < merged.count ? merged[i + 1].beat : max(totalBeats, note.beat + (note.duration ?? 1))
            let gap = max(0.0001, next - note.beat)
            let duration = note.duration.flatMap { $0 > 0 ? $0 : nil } ?? gap
            let pitches = Array(Set(note.pitches)).sorted()
            let fretting = note.fretting.isEmpty ? nil : note.fretting.sorted { $0.string < $1.string }
            events.append(ExpectedEvent(id: i, pitches: pitches, beat: note.beat, durationBeats: duration,
                                        measureIndex: note.measureIndex, positionInMeasure: note.positionInMeasure,
                                        chordName: note.chordName, fretting: fretting))
        }
        return ExpectedPassage(events: events, beatsPerMeasure: max(1, beatsPerMeasure),
                               bpm: bpm > 0 ? bpm : fallbackBPM, instrument: instrument, isFreeTime: isFreeTime)
    }
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
