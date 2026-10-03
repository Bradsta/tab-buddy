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
//  Note positions within a measure ride MusicXML's own timeline: <forward> and
//  <backup> move the cursor to each onset, and a note's written <duration> is
//  clamped to the distance to the next onset so the cursor lands exactly on
//  it. When the true duration is longer (notes left ringing), the extra length
//  goes in the standard `release` attribute (divisions past the written end).
//  Each measure's beat count is written as <time> whenever it changes. A
//  measure is `beatCount` beats of `divisions` each (the app's beat unit, the
//  same one `durationInBeats` uses). Files written before this scheme (no
//  `tabbuddy-timing` marker) derive positions from the running duration sum;
//  see `MusicXMLParserDelegate.closeMeasure`.
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
        /// Value `explicitTimingValue` when positions are encoded with
        /// <forward>/<backup>/release instead of implied by duration sums.
        static let timing = "tabbuddy-timing"
        /// Global beats per measure, written only when it differs from the
        /// first measure's beat count (which owns the first <time>).
        static let beatsPerMeasure = "tabbuddy-beats-per-measure"
    }

    fileprivate static let explicitTimingValue = "explicit"

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
        let measures = tab.measures.isEmpty
            ? [CanonicalMeasure(number: 1, beatCount: tab.beatsPerMeasure)]
            : tab.measures
        xml += miscField(MiscKey.timing, explicitTimingValue)
        if measures[0].beatCount != tab.beatsPerMeasure {
            xml += miscField(MiscKey.beatsPerMeasure, String(tab.beatsPerMeasure))
        }
        xml += "    </miscellaneous>\n"
        xml += "  </identification>\n"

        // –– part list ––
        xml += "  <part-list>\n"
        xml += "    <score-part id=\"P1\"><part-name>Guitar</part-name></score-part>\n"
        xml += "  </part-list>\n"

        // –– the single guitar part ––
        xml += "  <part id=\"P1\">\n"

        var previousBeats = measures[0].beatCount
        for (i, measure) in measures.enumerated() {
            xml += "    <measure number=\"\(measure.number)\">\n"

            // Full attributes + tempo in the first measure; afterwards a bare
            // <time> whenever the measure's beat count changes.
            if i == 0 {
                xml += attributesXML(for: tab, firstMeasureBeats: measure.beatCount)
                if let bpm = tab.bpm {
                    xml += "      <direction placement=\"above\"><sound tempo=\"\(fmt(bpm))\"/></direction>\n"
                }
            } else if measure.beatCount != previousBeats {
                xml += "      <attributes><time><beats>\(measure.beatCount)</beats>"
                xml += "<beat-type>\(tab.noteValue)</beat-type></time></attributes>\n"
            }
            previousBeats = measure.beatCount

            let measureDivs = measureLengthDivs(beatCount: measure.beatCount)

            // Harmonies come before any note, so <offset> is from measure start.
            for chord in measure.chords {
                xml += harmonyXML(chord, measureDivs: measureDivs)
            }

            xml += notesXML(measure.notes, measureDivs: measureDivs)

            xml += "    </measure>\n"
        }

        xml += "  </part>\n"
        xml += "</score-partwise>\n"

        return Data(xml.utf8)
    }

    /// Length of a measure in divisions. Shared by encoder and decoder so
    /// positions/offsets are always measured against the same beat count.
    static func measureLengthDivs(beatCount: Int, divisionsPerBeat: Int = divisions) -> Int {
        max(beatCount, 1) * max(divisionsPerBeat, 1)
    }

    private static func attributesXML(for tab: CanonicalTab, firstMeasureBeats: Int) -> String {
        var s = "      <attributes>\n"
        s += "        <divisions>\(divisions)</divisions>\n"
        if let fifths = tab.keyFifths {
            s += "        <key><fifths>\(fifths)</fifths></key>\n"
        }
        s += "        <time><beats>\(firstMeasureBeats)</beats><beat-type>\(tab.noteValue)</beat-type></time>\n"
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

    /// MusicXML <harmony>: root parsed from the chord name; the remainder is
    /// carried in kind's display text; offset encodes the in-measure position.
    private static func harmonyXML(_ chord: CanonicalChord, measureDivs: Int) -> String {
        var root = ""
        var alter = 0
        var rest = chord.name
        if let first = rest.first, ("A"..."G").contains(String(first)) {
            root = String(first)
            rest.removeFirst()
            if rest.first == "#" { alter = 1; rest.removeFirst() }
            else if rest.first == "b" { alter = -1; rest.removeFirst() }
        }
        guard !root.isEmpty else { return "" }
        let offset = onsetDivs(chord.positionInMeasure, measureDivs: measureDivs)
        var s = "      <harmony>\n"
        s += "        <root><root-step>\(root)</root-step>"
        if alter != 0 { s += "<root-alter>\(alter)</root-alter>" }
        s += "</root>\n"
        s += "        <kind text=\"\(esc(rest))\">other</kind>\n"
        if offset > 0 { s += "        <offset>\(offset)</offset>\n" }
        s += "      </harmony>\n"
        return s
    }

    /// Fractional in-measure position → onset in divisions (non-negative).
    private static func onsetDivs(_ position: Double, measureDivs: Int) -> Int {
        guard position.isFinite, position > 0 else { return 0 }
        let divs = (position * Double(measureDivs)).rounded()
        return divs < Double(Int32.max) ? Int(divs) : Int(Int32.max)
    }

    /// True duration in divisions (at least 1 — MusicXML notes need a duration).
    private static func durationDivs(_ beats: Double) -> Int {
        guard beats.isFinite, beats > 0 else { return 1 }
        let divs = (beats * Double(divisions)).rounded()
        return max(1, divs < Double(Int32.max) ? Int(divs) : Int(Int32.max))
    }

    /// Emit a measure's notes on an explicit timeline. A chord group (head +
    /// following `isChordedWithPrevious` notes) starts at the head's onset.
    /// The cursor is moved there with <forward>/<backup>; each written
    /// <duration> is clamped to the next group's onset (or the barline) and
    /// any remainder of the true duration is carried in `release`.
    private static func notesXML(_ notes: [CanonicalNote], measureDivs: Int) -> String {
        // Group indices: each group starts at a non-chorded note (or index 0).
        var groups: [Range<Int>] = []
        var start = 0
        for i in notes.indices where i > 0 && !notes[i].isChordedWithPrevious {
            groups.append(start..<i)
            start = i
        }
        if !notes.isEmpty { groups.append(start..<notes.count) }

        let onsets = groups.map { onsetDivs(notes[$0.lowerBound].positionInMeasure, measureDivs: measureDivs) }

        var s = ""
        var cursor = 0
        for (g, range) in groups.enumerated() {
            let onset = onsets[g]
            if onset > cursor {
                s += "      <forward><duration>\(onset - cursor)</duration></forward>\n"
            } else if onset < cursor {
                s += "      <backup><duration>\(cursor - onset)</duration></backup>\n"
            }
            // Room before the next onset; at the last group, room to the barline.
            let next = g + 1 < onsets.count ? onsets[g + 1] : measureDivs
            let room = next - onset

            var headWritten = 0
            for i in range {
                let trueDivs = durationDivs(notes[i].durationInBeats)
                let written = room > 0 ? min(trueDivs, room) : trueDivs
                if i == range.lowerBound { headWritten = written }
                s += noteXML(notes[i], writtenDivs: written, releaseDivs: trueDivs - written)
            }
            cursor = onset + headWritten
        }
        return s
    }

    private static func noteXML(_ note: CanonicalNote, writtenDivs: Int, releaseDivs: Int) -> String {
        var s = releaseDivs > 0 ? "      <note release=\"\(releaseDivs)\">\n" : "      <note>\n"
        if note.isChordedWithPrevious { s += "        <chord/>\n" }

        let (letter, octave, alter) = pitchParts(staffStep: note.staffStep, accidental: note.accidental)
        s += "        <pitch><step>\(letter)</step>"
        if alter != 0 { s += "<alter>\(alter)</alter>" }
        s += "<octave>\(octave)</octave></pitch>\n"

        s += "        <duration>\(writtenDivs)</duration>\n"
        s += "        <voice>1</voice>\n"
        if let type = noteType(forBeats: Double(writtenDivs) / Double(divisions)) {
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
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    }

    private static func esc(_ s: String) -> String {
        // XML 1.0 forbids C0 controls other than tab, LF and CR; XMLParser rejects them.
        let legal = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r"
        }))
        return legal.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // Expose misc keys to the parser delegate.
    fileprivate static var miscProvenanceKey: String { MiscKey.provenance }
    fileprivate static var miscCapoKey: String { MiscKey.capoOffsets }
    fileprivate static var miscTuningNameKey: String { MiscKey.tuningName }
    fileprivate static var miscSchemaKey: String { MiscKey.schemaVersion }
    fileprivate static var miscTimingKey: String { MiscKey.timing }
    fileprivate static var miscBeatsPerMeasureKey: String { MiscKey.beatsPerMeasure }
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
    private var beats = 4                // time signature in effect (per measure)
    private var firstBeats: Int?         // first <time> seen = global unless overridden
    private var globalBeatsOverride: Int?
    private var beatType = 4
    private var fileDivisions = MusicXMLCodec.divisions
    private var explicitTiming = false   // written by the forward/backup encoder
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
    private var curNoteOnsets: [Int] = []  // onset (divisions) per entry in curNotes
    private var cursorDivs = 0             // MusicXML timeline cursor within the measure
    private var lastHeadOnset = 0          // onset of the current chord group's head

    // <forward>/<backup>
    private var inForward = false
    private var inBackup = false
    private var moveDivs = 0

    // Current harmony being assembled
    private var inHarmony = false
    private var harmonyRootStep = ""
    private var harmonyRootAlter = 0
    private var harmonyKindText = ""
    private var harmonyOffsetDivs = 0
    private var curChords: [(name: String, onsetDivs: Int)] = []

    // Current note being assembled
    private var inNote = false
    private var noteIsChord = false
    private var noteStep: String?
    private var noteAlter = 0
    private var noteOctave: Int?
    private var noteDurationDivs: Int?
    private var noteReleaseDivs = 0
    private var noteIsRest = false
    private var noteIsGrace = false
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
            curNoteOnsets = []
            curChords = []
            cursorDivs = 0
            lastHeadOnset = 0
        case "harmony":
            inHarmony = true
            harmonyRootStep = ""; harmonyRootAlter = 0
            harmonyKindText = ""; harmonyOffsetDivs = 0
        case "kind":
            if inHarmony { harmonyKindText = attributeDict["text"] ?? "" }
        case "note":
            inNote = true
            noteIsChord = false
            noteStep = nil; noteAlter = 0; noteOctave = nil
            noteDurationDivs = nil; noteString = nil; noteFret = nil
            noteReleaseDivs = Int(attributeDict["release"] ?? "") ?? 0
            noteIsRest = false; noteIsGrace = false
        case "chord":
            noteIsChord = true
        case "rest":
            if inNote { noteIsRest = true }
        case "grace":
            if inNote { noteIsGrace = true }
        case "forward":
            inForward = true; moveDivs = 0
        case "backup":
            inBackup = true; moveDivs = 0
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
            if stack.contains("time"), let b = Int(trimmed) {
                beats = b
                if firstBeats == nil { firstBeats = b }
            }
        case "divisions":
            if let d = Int(trimmed), d > 0 { fileDivisions = d }
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
            else if inForward || inBackup { moveDivs = max(0, Int(trimmed) ?? 0) }
        case "forward":
            if inForward { cursorDivs += moveDivs }
            inForward = false
        case "backup":
            if inBackup { cursorDivs = max(0, cursorDivs - moveDivs) }
            inBackup = false
        case "string":
            if inNote { noteString = (Int(trimmed)).map { $0 - 1 } }
        case "fret":
            if inNote { noteFret = Int(trimmed) }
        case "note":
            finishNote()
            inNote = false
        case "root-step":
            if inHarmony { harmonyRootStep = trimmed }
        case "root-alter":
            if inHarmony { harmonyRootAlter = Int(trimmed) ?? 0 }
        case "offset":
            if inHarmony { harmonyOffsetDivs = Int(trimmed) ?? 0 }
        case "harmony":
            if !harmonyRootStep.isEmpty {
                let accidental = harmonyRootAlter == 1 ? "#" : (harmonyRootAlter == -1 ? "b" : "")
                // <offset> is relative to the current cursor (0 for our files).
                curChords.append((harmonyRootStep + accidental + harmonyKindText,
                                  cursorDivs + harmonyOffsetDivs))
            }
            inHarmony = false
        case "measure":
            closeMeasure()
        case "miscellaneous-field":
            handleMisc(name: curMiscName, value: trimmed)
            curMiscName = nil

        default:
            break
        }
    }

    // MARK: Builders

    /// Place a note on the measure timeline. Chord tones share their head's
    /// onset; any other note (pitched, rest, or unpitched) advances the cursor
    /// by its written duration. Positions are resolved in `closeMeasure`.
    private func finishNote() {
        let writtenDivs = noteIsGrace ? 0 : (noteDurationDivs ?? fileDivisions)
        let onset: Int
        if noteIsChord {
            onset = lastHeadOnset
        } else {
            onset = cursorDivs
            lastHeadOnset = onset
            cursorDivs += max(0, writtenDivs)
        }

        guard !noteIsRest, let step = noteStep, let oct = noteOctave,
              let ss = MusicXMLCodec.staffStep(letter: step, octave: oct) else { return }
        let soundingDivs = max(0, writtenDivs + noteReleaseDivs)
        let durBeats = Double(soundingDivs) / Double(fileDivisions)
        let midi = StaffPitchMapper.midiPitch(staffStep: ss, accidental: noteAlter)

        let note = CanonicalNote(positionInMeasure: 0,   // resolved in closeMeasure
                                 durationInBeats: durBeats,
                                 midiPitch: midi,
                                 staffStep: ss,
                                 accidental: noteAlter,
                                 string: noteString,
                                 fret: noteFret,
                                 isChordedWithPrevious: noteIsChord)
        curNotes.append(note)
        curNoteOnsets.append(onset)
    }

    /// Convert collected onsets (divisions) to fractional positions against
    /// this measure's beat count, then store the measure.
    ///
    /// Legacy files (written before `tabbuddy-timing`) carry no gaps and their
    /// durations need not tile the bar, so the running sum can overrun it
    /// (eight 1-beat notes in 4/4). The old decoder clamped every overrunning
    /// onset to 1.0; instead, when any onset reaches the barline, scale the
    /// onsets by the total running length so the notes keep their order and
    /// relative spacing inside the bar.
    private func closeMeasure() {
        let measureDivs = Double(MusicXMLCodec.measureLengthDivs(beatCount: beats,
                                                                  divisionsPerBeat: fileDivisions))
        var scale = measureDivs
        if !explicitTiming, cursorDivs > 0,
           curNoteOnsets.contains(where: { Double($0) >= measureDivs }) {
            scale = Double(cursorDivs)
        }
        func position(_ divs: Int) -> Double {
            max(0, min(1, Double(divs) / scale))
        }

        var notes = curNotes
        for i in notes.indices { notes[i].positionInMeasure = position(curNoteOnsets[i]) }
        let chords = curChords.map {
            CanonicalChord(name: $0.name,
                           positionInMeasure: max(0, min(1, Double($0.onsetDivs) / measureDivs)))
        }
        measures.append(CanonicalMeasure(number: curMeasureNumber,
                                         notes: notes,
                                         beatCount: beats,
                                         chords: chords))
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
        case MusicXMLCodec.miscTimingKey:
            explicitTiming = value == MusicXMLCodec.explicitTimingValue
        case MusicXMLCodec.miscBeatsPerMeasureKey:
            globalBeatsOverride = Int(value)
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
                            beatsPerMeasure: globalBeatsOverride ?? firstBeats ?? beats,
                            noteValue: beatType,
                            keyFifths: keyFifths,
                            bpm: bpm,
                            measures: measures,
                            provenance: provenance)
    }
}
