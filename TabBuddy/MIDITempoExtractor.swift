//
//  MIDITempoExtractor.swift
//  TabBuddy
//
//  Extracts BPM and time signature from MIDI files using Apple's AudioToolbox.
//  Used to auto-populate tempo for tabs that have paired .mid files.
//

import AudioToolbox
import Foundation

struct MIDITempoData {
    /// Initial BPM of the piece
    let initialBPM: Double
    /// Time signature (beats per measure, note value)
    let timeSignature: (beats: Int, noteValue: Int)?
    /// All tempo changes in the piece (beat position, BPM)
    let tempoChanges: [(beat: Double, bpm: Double)]
}

struct MIDITempoExtractor {

    /// Extract tempo data from a MIDI file.
    static func extract(from url: URL) -> MIDITempoData? {
        var sequence: MusicSequence?
        guard NewMusicSequence(&sequence) == noErr,
              let seq = sequence else { return nil }
        defer { DisposeMusicSequence(seq) }

        // Load the MIDI file
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        guard MusicSequenceFileLoad(seq, url as CFURL,
                                    .midiType, .smf_ChannelsToTracks) == noErr
        else { return nil }

        // Get tempo track
        var tempoTrack: MusicTrack?
        guard MusicSequenceGetTempoTrack(seq, &tempoTrack) == noErr,
              let track = tempoTrack else { return nil }

        var tempoChanges: [(beat: Double, bpm: Double)] = []
        var timeSignature: (beats: Int, noteValue: Int)?

        // Iterate events in the tempo track
        var iterator: MusicEventIterator?
        guard NewMusicEventIterator(track, &iterator) == noErr,
              let iter = iterator else { return nil }
        defer { DisposeMusicEventIterator(iter) }

        var hasEvent: DarwinBoolean = false
        MusicEventIteratorHasCurrentEvent(iter, &hasEvent)

        while hasEvent.boolValue {
            var timestamp: MusicTimeStamp = 0
            var eventType: MusicEventType = 0
            var eventData: UnsafeRawPointer?
            var eventSize: UInt32 = 0

            MusicEventIteratorGetEventInfo(iter, &timestamp, &eventType,
                                           &eventData, &eventSize)

            switch eventType {
            case kMusicEventType_ExtendedTempo:
                // Extended tempo event: BPM as Float64
                if let data = eventData {
                    let bpm = data.load(as: Float64.self)
                    if bpm > 0 && bpm < 1000 {
                        tempoChanges.append((beat: timestamp, bpm: bpm))
                    }
                }

            case kMusicEventType_Meta:
                // Meta events: check for time signature (0x58) and tempo (0x51)
                if let data = eventData {
                    let meta = data.load(as: MIDIMetaEvent.self)

                    if meta.metaEventType == 0x58 && meta.dataLength >= 2 {
                        // Time signature: byte 0 = numerator, byte 1 = denominator as power of 2
                        let dataPtr = data.advanced(by: MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.data)!)
                        let numerator = Int(dataPtr.load(as: UInt8.self))
                        let denomPower = Int(dataPtr.advanced(by: 1).load(as: UInt8.self))
                        let denominator = 1 << denomPower  // 2^denomPower
                        if timeSignature == nil {
                            timeSignature = (numerator, denominator)
                        }
                    }

                    if meta.metaEventType == 0x51 && meta.dataLength >= 3 {
                        // Tempo: 3 bytes = microseconds per quarter note
                        let dataPtr = data.advanced(by: MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.data)!)
                        let b0 = UInt32(dataPtr.load(as: UInt8.self))
                        let b1 = UInt32(dataPtr.advanced(by: 1).load(as: UInt8.self))
                        let b2 = UInt32(dataPtr.advanced(by: 2).load(as: UInt8.self))
                        let usPerQuarter = (b0 << 16) | (b1 << 8) | b2
                        if usPerQuarter > 0 {
                            let bpm = 60_000_000.0 / Double(usPerQuarter)
                            tempoChanges.append((beat: timestamp, bpm: bpm))
                        }
                    }
                }

            default:
                break
            }

            MusicEventIteratorNextEvent(iter)
            MusicEventIteratorHasCurrentEvent(iter, &hasEvent)
        }

        // Sort by timestamp and pick the initial tempo
        tempoChanges.sort { $0.beat < $1.beat }
        guard let initialBPM = tempoChanges.first?.bpm else { return nil }

        return MIDITempoData(
            initialBPM: initialBPM,
            timeSignature: timeSignature,
            tempoChanges: tempoChanges
        )
    }

    /// Look for a sibling MIDI file with the same base name.
    /// E.g. "aguado_nuevo_metodo.txt" → "aguado_nuevo_metodo.mid"
    static func findPairedMIDI(for fileURL: URL) -> URL? {
        let dir = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent

        // Check common MIDI extensions
        for ext in ["mid", "midi", "MID", "MIDI"] {
            let candidate = dir.appendingPathComponent(baseName).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}
