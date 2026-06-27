//
//  MusicXMLCodec.swift
//  TabBuddy
//
//  Encodes/decodes a CanonicalTab to/from tab-flavored MusicXML (score-partwise).
//
//  Musical content (title, artist, tuning, key, time, tempo, notes with
//  string/fret/pitch/duration) maps to real MusicXML elements. TabBuddy-specific
//  data that MusicXML has no home for (provenance, per-string capo offsets,
//  tuning name, schema version) is preserved in <miscellaneous-field> entries so
//  round-trips stay lossless without smuggling musical content into private tags.
//
//  Note positions within a measure are *derived from rhythm* on decode (running
//  sum of durations, resetting on chord stacks) — the musically-correct
//  interpretation — rather than stored per-note.
//

import Foundation

enum MusicXMLCodec {

    /// MusicXML divisions per quarter note. 480 is highly divisible, so common
    /// durations (whole … 32nd, dotted, triplet) encode to integers exactly.
    static let divisions = 480

    private static let stepLetters = ["C", "D", "E", "F", "G", "A", "B"]

    // Misc-field keys for TabBuddy-private metadata.
    private enum MiscKey {
        static let provenance = "tabbuddy-provenance"
        static let capoOffsets = "tabbuddy-capo-offsets"
        static let tuningName = "tabbuddy-tuning-name"
        static let schemaVersion = "tabbuddy-schema-version"
    }

    // MARK: - Encode

    static func encode(_ tab: CanonicalTab) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">

        """

        // –– work / identification ––
        xml += "  <work><work-title>\(esc(tab.title))</work-title></work>\n"
        xml += "  <identification>\n"
        if let artist = tab.artist {
            xml += "    <creator type=\"composer\">\(esc(artist))</creator>\n"
        }
        xml += "    <encoding><software>TabBuddy</software></encoding>\n"
        xml += "    <miscellaneous>\n"
        xml += miscField(MiscKey.schemaVersion, String(tab.schemaVersion))
        xml += miscField(MiscKey.tuningName, tab.tuningName)
        xml += miscField(MiscKey.capoOffsets, tab.capoOffsets.map(String.init).joined(separator: ","))
        if let provJSON = encodeJSON(tab.provenance) {
            xml += miscField(MiscKey.provenance, provJSON)
        }
        if let comments = tab.comments {
            xml += miscField("tabbuddy-comments", comments)
        }
        xml += "    </miscellaneous>\n"
        xml += "  </identification>\n"

        // –– part list ––
        xml += "  <part-list>\n"
        xml += "    <score-part id=\"P1\"><part-name>Guitar</part-name></score-part>\n"
        xml += "  </part-list>\n"

        // –– the single guitar part ––
        xml += "  <part id=\"P1\">\n"

        let measures = tab.measures.isEmpty
            ? [CanonicalMeasure(number: 1, beatCount: tab.beatsPerMeasure)]
            : tab.measures

        for (i, measure) in measures.enumerated() {
            xml += "    <measure number=\"\(measure.number)\">\n"

            // Attributes + tempo only in the first measure.
            if i == 0 {
                xml += attributesXML(for: tab)
                if let bpm = tab.bpm {
                    xml += "      <direction placement=\"above\"><sound tempo=\"\(fmt(bpm))\"/></direction>\n"
                }
            }

            for note in measure.notes {
                xml += noteXML(note)
            }

            xml += "    </measure>\n"
        }

        xml += "  </part>\n"
        xml += "</score-partwise>\n"

        return Data(xml.utf8)
    }

    private static func attributesXML(for tab: CanonicalTab) -> String {
        var s = "      <attributes>\n"
        s += "        <divisions>\(divisions)</divisions>\n"
        if let fifths = tab.keyFifths {
            s += "        <key><fifths>\(fifths)</fifths></key>\n"
        }
        s += "        <time><beats>\(tab.beatsPerMeasure)</beats><beat-type>\(tab.noteValue)</beat-type></time>\n"
        s += "        <clef><sign>TAB</sign><line>5</line></clef>\n"
        s += "        <staff-details>\n"
        s += "          <staff-lines>\(tab.tuningMIDI.count)</staff-lines>\n"
        // MusicXML staff-tuning line 1 = bottom line = lowest string.
        // Our tuning array is high-E-first, so line L ↔ array index (count - L).
        let count = tab.tuningMIDI.count
        for line in 1...max(count, 1) where count > 0 {
            let idx = count - line
            guard idx >= 0, idx < count else { continue }
            let (letter, octave, alter) = pitchParts(midi: tab.tuningMIDI[idx])
            s += "          <staff-tuning line=\"\(line)\">"
            s += "<tuning-step>\(letter)</tuning-step>"
            if alter != 0 { s += "<tuning-alter>\(alter)</tuning-alter>" }
            s += "<tuning-octave>\(octave)</tuning-octave></staff-tuning>\n"
        }
        s += "        </staff-details>\n"
        s += "      </attributes>\n"
        return s
    }

    private static func noteXML(_ note: CanonicalNote) -> String {
        var s = "      <note>\n"
        if note.isChordedWithPrevious { s += "        <chord/>\n" }

        let (letter, octave, alter) = pitchParts(staffStep: note.staffStep, accidental: note.accidental)
        s += "        <pitch><step>\(letter)</step>"
        if alter != 0 { s += "<alter>\(alter)</alter>" }
        s += "<octave>\(octave)</octave></pitch>\n"

        let dur = max(1, Int((note.durationInBeats * Double(divisions)).rounded()))
        s += "        <duration>\(dur)</duration>\n"
        s += "        <voice>1</voice>\n"
        if let type = noteType(forBeats: note.durationInBeats) {
            s += "        <type>\(type)</type>\n"
        }

        if let string = note.string, let fret = note.fret {
            s += "        <notations><technical>"
            s += "<string>\(string + 1)</string><fret>\(fret)</fret>"
            s += "</technical></notations>\n"
        }

        s += "      </note>\n"
        return s
    }

    // MARK: - Decode

    static func decode(_ data: Data) -> CanonicalTab? {
        let parser = XMLParser(data: data)
        let delegate = MusicXMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse(), delegate.sawScore else { return nil }
        return delegate.buildTab()
    }

    // MARK: - Pitch helpers

    /// (stepLetter, octaveNumber, alter) for a diatonic staff step (0 = C4).
    static func pitchParts(staffStep: Int, accidental: Int) -> (String, Int, Int) {
        let stepInOctave = ((staffStep % 7) + 7) % 7
        let octaveRel = Int(floor(Double(staffStep) / 7.0))
        return (stepLetters[stepInOctave], octaveRel + 4, accidental)
    }

    /// (stepLetter, octaveNumber, alter) for an absolute MIDI pitch (sharps).
    static func pitchParts(midi: Int) -> (String, Int, Int) {
        let pos = StaffPitchMapper.staffPosition(midiPitch: midi)
        return pitchParts(staffStep: pos.staffStep, accidental: pos.accidental)
    }

    /// staffStep for a (letter, octave) pair.
    static func staffStep(letter: String, octave: Int) -> Int? {
        guard let stepInOctave = stepLetters.firstIndex(of: letter.uppercased()) else { return nil }
        return (octave - 4) * 7 + stepInOctave
    }

    // MARK: - Misc

    private static func noteType(forBeats beats: Double) -> String? {
        switch beats {
        case 4.0:   return "whole"
        case 3.0:   return "half"      // dotted half (dot omitted; cosmetic)
        case 2.0:   return "half"
        case 1.5:   return "quarter"   // dotted quarter
        case 1.0:   return "quarter"
        case 0.75:  return "eighth"
        case 0.5:   return "eighth"
        case 0.375: return "16th"
        case 0.25:  return "16th"
        case 0.125: return "32nd"
        default:    return nil
        }
    }

    private static func miscField(_ name: String, _ value: String) -> String {
        "      <miscellaneous-field name=\"\(esc(name))\">\(esc(value))</miscellaneous-field>\n"
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        // Deterministic key order → byte-stable MusicXML (diffable, sync-friendly).
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // Expose misc keys to the parser delegate.
    fileprivate static var miscProvenanceKey: String { MiscKey.provenance }
    fileprivate static var miscCapoKey: String { MiscKey.capoOffsets }
    fileprivate static var miscTuningNameKey: String { MiscKey.tuningName }
    fileprivate static var miscSchemaKey: String { MiscKey.schemaVersion }
}

// MARK: - XML parsing delegate

private final class MusicXMLParserDelegate: NSObject, XMLParserDelegate {

    var sawScore = false

    // Accumulated text for the current leaf element.
    private var text = ""
    // Element stack for context.
    private var stack: [String] = []

    // Header
    private var title = "Untitled"
    private var artist: String?
    private var comments: String?
    private var tuningName = GuitarTuning.standard.name
    private var schemaVersion = 1
    private var capoOffsets: [Int] = []
    private var provenance = Provenance()
    private var keyFifths: Int?
    private var beats = 4
    private var beatType = 4
    private var bpm: Double?

    // Tuning collected from staff-tuning (line → midi); rebuilt high-E-first.
    private var tuningByLine: [Int: Int] = [:]
    private var curTuningLine: Int?
    private var curTuningStep: String?
    private var curTuningAlter = 0
    private var curTuningOctave: Int?

    // Misc field
    private var curMiscName: String?

    // Measures / notes
    private var measures: [CanonicalMeasure] = []
    private var curMeasureNumber = 1
    private var curNotes: [CanonicalNote] = []
    private var runningBeats = 0.0       // position accumulator within the measure
    private var lastHeadPosition = 0.0   // position of the current chord group's head

    // Current note being assembled
    private var inNote = false
    private var noteIsChord = false
    private var noteStep: String?
    private var noteAlter = 0
    private var noteOctave: Int?
    private var noteDurationDivs: Int?
    private var noteString: Int?
    private var noteFret: Int?

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        text = ""
        stack.append(elementName)

        switch elementName {
        case "score-partwise":
            sawScore = true
        case "measure":
            curMeasureNumber = Int(attributeDict["number"] ?? "") ?? (measures.count + 1)
            curNotes = []
            runningBeats = 0
            lastHeadPosition = 0
        case "note":
            inNote = true
            noteIsChord = false
            noteStep = nil; noteAlter = 0; noteOctave = nil
            noteDurationDivs = nil; noteString = nil; noteFret = nil
        case "chord":
            noteIsChord = true
        case "sound":
            if let t = attributeDict["tempo"], let v = Double(t) { bpm = v }
        case "staff-tuning":
            curTuningLine = Int(attributeDict["line"] ?? "")
            curTuningStep = nil; curTuningAlter = 0; curTuningOctave = nil
        case "miscellaneous-field":
            curMiscName = attributeDict["name"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if !stack.isEmpty { stack.removeLast() }
            text = ""
        }

        switch elementName {
        case "work-title":
            title = trimmed.isEmpty ? title : trimmed
        case "creator":
            if artist == nil, !trimmed.isEmpty { artist = trimmed }
        case "fifths":
            keyFifths = Int(trimmed)
        case "beats":
            if stack.contains("time") { beats = Int(trimmed) ?? beats }
        case "beat-type":
            beatType = Int(trimmed) ?? beatType

        // staff-tuning
        case "tuning-step":
            if stack.contains("staff-tuning") { curTuningStep = trimmed }
        case "tuning-alter":
            if stack.contains("staff-tuning") { curTuningAlter = Int(trimmed) ?? 0 }
        case "tuning-octave":
            if stack.contains("staff-tuning") { curTuningOctave = Int(trimmed) }
        case "staff-tuning":
            if let line = curTuningLine, let step = curTuningStep, let oct = curTuningOctave,
               let ss = MusicXMLCodec.staffStep(letter: step, octave: oct) {
                tuningByLine[line] = StaffPitchMapper.midiPitch(staffStep: ss, accidental: curTuningAlter)
            }
            curTuningLine = nil

        // note internals
        case "step":
            if inNote { noteStep = trimmed }
        case "alter":
            if inNote { noteAlter = Int(trimmed) ?? 0 }
        case "octave":
            if inNote { noteOctave = Int(trimmed) }
        case "duration":
            if inNote { noteDurationDivs = Int(trimmed) }
        case "string":
            if inNote { noteString = (Int(trimmed)).map { $0 - 1 } }
        case "fret":
            if inNote { noteFret = Int(trimmed) }
        case "note":
            finishNote()
            inNote = false
        case "measure":
            measures.append(CanonicalMeasure(number: curMeasureNumber,
                                             notes: curNotes,
                                             beatCount: beats))
        case "miscellaneous-field":
            handleMisc(name: curMiscName, value: trimmed)
            curMiscName = nil

        default:
            break
        }
    }

    // MARK: Builders

    private func finishNote() {
        guard let step = noteStep, let oct = noteOctave,
              let ss = MusicXMLCodec.staffStep(letter: step, octave: oct) else { return }
        let durBeats = Double(noteDurationDivs ?? MusicXMLCodec.divisions) / Double(MusicXMLCodec.divisions)
        let midi = StaffPitchMapper.midiPitch(staffStep: ss, accidental: noteAlter)

        // Position is derived from rhythm: chord notes share their head's
        // position; sequential notes advance by their predecessor's duration.
        let beatsPerMeasure = Double(max(beats, 1))
        let position: Double
        if noteIsChord {
            position = lastHeadPosition
        } else {
            position = min(1.0, runningBeats / beatsPerMeasure)
            lastHeadPosition = position
        }

        let note = CanonicalNote(positionInMeasure: position,
                                 durationInBeats: durBeats,
                                 midiPitch: midi,
                                 staffStep: ss,
                                 accidental: noteAlter,
                                 string: noteString,
                                 fret: noteFret,
                                 isChordedWithPrevious: noteIsChord)
        curNotes.append(note)
        if !noteIsChord { runningBeats += durBeats }
    }

    private func handleMisc(name: String?, value: String) {
        guard let name else { return }
        switch name {
        case MusicXMLCodec.miscSchemaKey:
            schemaVersion = Int(value) ?? schemaVersion
        case MusicXMLCodec.miscTuningNameKey:
            if !value.isEmpty { tuningName = value }
        case MusicXMLCodec.miscCapoKey:
            capoOffsets = value.split(separator: ",").compactMap { Int($0) }
        case MusicXMLCodec.miscProvenanceKey:
            if let data = value.data(using: .utf8),
               let p = try? JSONDecoder().decode(Provenance.self, from: data) {
                provenance = p
            }
        case "tabbuddy-comments":
            comments = value.isEmpty ? nil : value
        default:
            break
        }
    }

    func buildTab() -> CanonicalTab {
        // Rebuild tuning high-E-first from line map (line 1 = lowest string).
        let lines = tuningByLine.keys.sorted(by: >)  // highest line first = high E first
        let tuning = lines.isEmpty
            ? GuitarTuning.standard.midiNotes
            : lines.compactMap { tuningByLine[$0] }

        return CanonicalTab(title: title,
                            artist: artist,
                            comments: comments,
                            tuningMIDI: tuning,
                            tuningName: tuningName,
                            capoOffsets: capoOffsets,
                            beatsPerMeasure: beats,
                            noteValue: beatType,
                            keyFifths: keyFifths,
                            bpm: bpm,
                            measures: measures,
                            provenance: provenance)
    }
}
