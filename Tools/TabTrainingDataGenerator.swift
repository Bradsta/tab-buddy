//
//  TabTrainingDataGenerator.swift
//  Tab Buddy — ML Training Data Pipeline
//
//  Batch-runs TabParser across the entire tab library, producing:
//  1. Training data pairs: (filename, raw_text, MeasureMap_JSON)
//  2. Quality report for CHECKPOINT 3 review
//
//  Compile: swiftc -O -framework CoreGraphics TabParser.swift MeasureMap.swift TabTrainingDataGenerator.swift -o tab_training_gen
//  Run:     ./tab_training_gen /path/to/guitar-tabs /path/to/output-dir
//

import AudioToolbox
import Foundation
import CoreGraphics

// MARK: - Quality Signals

/// Per-file quality analysis produced alongside MeasureMap output.
struct ParseQuality {
    let filename: String
    let relativePath: String       // path relative to library root
    let source: String             // "classtab", "casual", "brads", "eh", "toplevel"
    let hasPairedMIDI: Bool
    let fileSize: Int              // bytes

    // Parse results
    let systemCount: Int
    let measureCount: Int
    let totalNotes: Int
    let tabLinesPerSystem: [Int]   // how many tab lines in each system
    let hasBarLines: Bool          // whether | bar lines were detected
    let usedColonSeparator: Bool   // whether : separator was used

    // Metadata detection
    let detectedBPM: Double?
    let detectedTimeSig: (Int, Int)?
    let detectedTuning: String?
    let detectedKey: String?

    // Confidence signals
    var confidence: Double {
        var score = 0.0
        let maxScore = 10.0

        // Systems detected (0-2 pts)
        if systemCount > 0 { score += 1.0 }
        if systemCount >= 3 { score += 1.0 }

        // Measures detected (0-2 pts)
        if measureCount > 0 { score += 1.0 }
        if measureCount >= 4 { score += 1.0 }

        // Notes extracted (0-2 pts)
        if totalNotes > 0 { score += 1.0 }
        if totalNotes >= 10 { score += 1.0 }

        // Tab line consistency (0-1 pt): most systems should have 6 lines
        let sixLineCount = tabLinesPerSystem.filter { $0 == 6 }.count
        if !tabLinesPerSystem.isEmpty {
            let ratio = Double(sixLineCount) / Double(tabLinesPerSystem.count)
            score += ratio
        }

        // Bar lines (0-1 pt)
        if hasBarLines { score += 1.0 }

        // Metadata (0-2 pts)
        if detectedBPM != nil { score += 0.5 }
        if detectedTimeSig != nil { score += 0.5 }
        if detectedTuning != nil { score += 0.5 }
        if hasPairedMIDI { score += 0.5 }

        return score / maxScore
    }

    /// Reasons this parse might be problematic
    var warnings: [String] {
        var w: [String] = []
        if systemCount == 0 { w.append("NO_SYSTEMS") }
        if measureCount == 0 { w.append("NO_MEASURES") }
        if totalNotes == 0 { w.append("NO_NOTES") }
        if !tabLinesPerSystem.isEmpty {
            let nonSix = tabLinesPerSystem.filter { $0 != 6 && $0 != 4 && $0 != 5 && $0 != 7 }
            if nonSix.count > tabLinesPerSystem.count / 2 {
                w.append("UNUSUAL_LINE_COUNT(\(tabLinesPerSystem.first ?? 0))")
            }
        }
        if !hasBarLines && measureCount > 0 { w.append("NO_BAR_LINES") }
        return w
    }
}

// MARK: - MeasureMap JSON Encoding

/// Encode MeasureMap to JSON-compatible dictionary for training output.
func measureMapToDict(_ map: MeasureMap) -> [String: Any] {
    var dict: [String: Any] = [:]

    if let bpm = map.bpm { dict["bpm"] = bpm }
    if let ts = map.timeSignature {
        dict["timeSignature"] = ["beats": ts.beats, "noteValue": ts.noteValue]
    }
    if let key = map.key { dict["key"] = key }
    if let tuning = map.tuning { dict["tuning"] = tuning }

    dict["systems"] = map.systems.map { sys -> [String: Any] in
        var sysDict: [String: Any] = [:]
        if let lr = sys.lineRange {
            sysDict["lineRange"] = ["start": lr.lowerBound, "end": lr.upperBound]
        }
        sysDict["measures"] = sys.measures.map { m -> [String: Any] in
            var mDict: [String: Any] = [
                "measureNumber": m.measureNumber,
                "beatCount": m.beatCount
            ]
            if let cr = m.columnRange {
                mDict["columnRange"] = ["start": cr.lowerBound, "end": cr.upperBound]
            }
            if let notes = m.notes {
                mDict["notes"] = notes.map { n -> [String: Any] in
                    var nDict: [String: Any] = [
                        "position": n.positionInMeasure,
                        "frets": n.frets.map { $0 as Any }
                    ]
                    if let dur = n.durationInBeats { nDict["duration"] = dur }
                    if let col = n.column { nDict["column"] = col }
                    return nDict
                }
            }
            return mDict
        }
        return sysDict
    }

    return dict
}

// MARK: - Library Scanner

/// Categorize a file's source based on its path relative to the library root.
func categorize(relativePath: String) -> String {
    let lower = relativePath.lowercased()
    if lower.hasPrefix("classtab/") { return "classtab" }
    if lower.hasPrefix("brads tabs/") { return "brads" }
    if lower.hasPrefix("eh/") { return "eh" }
    if lower.hasPrefix("classical/") { return "classical" }
    if !relativePath.contains("/") { return "toplevel" }
    return "other"
}

/// Check for a paired MIDI file (same basename, .mid extension).
func hasPairedMIDI(for txtPath: String) -> Bool {
    let basePath = (txtPath as NSString).deletingPathExtension
    let midPath = basePath + ".mid"
    return FileManager.default.fileExists(atPath: midPath)
}

/// Analyze whether a tab uses bar lines and/or colon separators.
func analyzeTabFormat(_ text: String) -> (hasBarLines: Bool, usesColon: Bool) {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")

    var hasBarInTab = false
    var usesColon = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Check for colon-labeled tab line
        if trimmed.range(of: #"^[eEBbGgDdAaCcFf]\s*:"#, options: .regularExpression) != nil {
            usesColon = true

            // Check if it also has internal | bar lines
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let after = trimmed[trimmed.index(after: colonIdx)...]
                if after.contains("|") {
                    hasBarInTab = true
                }
            }
            continue
        }

        // Check for pipe-labeled tab line with internal bars
        if trimmed.range(of: #"^[eEBbGgDdAaCcFf]\s*\|"#, options: .regularExpression) != nil {
            // Count | characters — need at least 3 for measure boundaries (start | content | end)
            let barCount = trimmed.filter { $0 == "|" }.count
            if barCount >= 3 {
                hasBarInTab = true
            }
            continue
        }

        // Unlabeled tab lines with |
        if (trimmed.hasPrefix("|") || trimmed.hasPrefix("-")) && trimmed.contains("|") {
            let dashCount = trimmed.filter { $0 == "-" }.count
            let barCount = trimmed.filter { $0 == "|" }.count
            if dashCount > trimmed.count / 3 && barCount >= 2 {
                hasBarInTab = true
            }
        }
    }

    return (hasBarInTab, usesColon)
}

// MARK: - Main

func run() {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        print("Usage: tab_training_gen <library-path> <output-dir>")
        print("  library-path: Root of the guitar tab library")
        print("  output-dir:   Directory for training data and quality report")
        exit(1)
    }

    let libraryPath = args[1]
    let outputDir = args[2]
    let fm = FileManager.default

    // Create output directory
    try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    // Find all .txt files
    print("Scanning library at: \(libraryPath)")
    let enumerator = fm.enumerator(atPath: libraryPath)
    var txtFiles: [String] = []
    while let file = enumerator?.nextObject() as? String {
        if file.hasSuffix(".txt") {
            txtFiles.append(file)
        }
    }
    txtFiles.sort()
    print("Found \(txtFiles.count) .txt files")

    // Process each file
    var qualities: [ParseQuality] = []
    var trainingPairs: [[String: Any]] = []
    var errorFiles: [(String, String)] = []
    let startTime = Date()

    for (idx, relPath) in txtFiles.enumerated() {
        let fullPath = (libraryPath as NSString).appendingPathComponent(relPath)

        guard let data = fm.contents(atPath: fullPath),
              let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .ascii)
                      ?? String(data: data, encoding: .isoLatin1)
        else {
            errorFiles.append((relPath, "UNREADABLE"))
            continue
        }

        // Skip very small files (likely not tabs) and very large files (likely not tabs)
        if text.count < 20 {
            errorFiles.append((relPath, "TOO_SMALL(\(text.count) chars)"))
            continue
        }
        if text.count > 500_000 {
            errorFiles.append((relPath, "TOO_LARGE(\(text.count) chars)"))
            continue
        }

        // Parse
        let result = TabParser.parse(text)

        // Analyze format
        let format = analyzeTabFormat(text)

        // MIDI enrichment: extract BPM and time sig from paired MIDI if available
        let hasMIDI = hasPairedMIDI(for: fullPath)
        var midiBPM: Double?
        var midiTimeSig: (Int, Int)?
        var midiTempoChanges: Int = 0
        if hasMIDI {
            let midPath = (fullPath as NSString).deletingPathExtension + ".mid"
            let midURL = URL(fileURLWithPath: midPath)
            if let midiData = MIDITempoExtractor.extract(from: midURL) {
                midiBPM = midiData.initialBPM
                midiTimeSig = midiData.timeSignature.map { ($0.beats, $0.noteValue) }
                midiTempoChanges = midiData.tempoChanges.count
            }
        }

        // Determine best BPM: prefer MIDI (ground truth), fall back to parser
        let bestBPM = midiBPM ?? result.bpm
        let bpmSource: String = midiBPM != nil ? "midi" : (result.bpm != nil ? "parser" : "none")

        // Determine best time signature: prefer parser if matches MIDI, else MIDI
        let parserTS = result.timeSignature.map { ($0.beats, $0.noteValue) }
        let bestTimeSig: (Int, Int)?
        let timeSigSource: String
        if let pTS = parserTS, let mTS = midiTimeSig, pTS.0 == mTS.0 && pTS.1 == mTS.1 {
            bestTimeSig = pTS
            timeSigSource = "both"
        } else if let mTS = midiTimeSig {
            bestTimeSig = mTS
            timeSigSource = "midi"
        } else if let pTS = parserTS {
            bestTimeSig = pTS
            timeSigSource = "parser"
        } else {
            bestTimeSig = nil
            timeSigSource = "none"
        }

        // Build quality record
        let quality = ParseQuality(
            filename: (relPath as NSString).lastPathComponent,
            relativePath: relPath,
            source: categorize(relativePath: relPath),
            hasPairedMIDI: hasMIDI,
            fileSize: text.count,
            systemCount: result.systems.count,
            measureCount: result.measureCount,
            totalNotes: result.systems.flatMap(\.measures).compactMap(\.notes).flatMap { $0 }.count,
            tabLinesPerSystem: result.systems.compactMap { sys in
                guard let lr = sys.lineRange else { return nil }
                return lr.count
            },
            hasBarLines: format.hasBarLines,
            usedColonSeparator: format.usesColon,
            detectedBPM: bestBPM,
            detectedTimeSig: bestTimeSig,
            detectedTuning: result.tuning,
            detectedKey: result.key
        )
        qualities.append(quality)

        // Training pair — enriched with MIDI ground truth
        var mapDict = measureMapToDict(result)
        // Override with best available BPM and time sig
        if let bpm = bestBPM { mapDict["bpm"] = bpm }
        if let ts = bestTimeSig { mapDict["timeSignature"] = ["beats": ts.0, "noteValue": ts.1] }

        var pair: [String: Any] = [
            "filename": relPath,
            "source": quality.source,
            "confidence": quality.confidence,
            "hasPairedMIDI": hasMIDI,
            "bpmSource": bpmSource,
            "timeSigSource": timeSigSource,
            "measureMap": mapDict
        ]
        if let mbpm = midiBPM { pair["midiBPM"] = mbpm }
        if midiTempoChanges > 1 { pair["midiTempoChanges"] = midiTempoChanges }
        trainingPairs.append(pair)

        // Progress
        if (idx + 1) % 500 == 0 || idx == txtFiles.count - 1 {
            let elapsed = Date().timeIntervalSince(startTime)
            let rate = Double(idx + 1) / elapsed
            print("  Processed \(idx + 1)/\(txtFiles.count) (\(String(format: "%.0f", rate)) files/sec)")
        }
    }

    // MARK: - Quality Report

    let totalParsed = qualities.count
    let withSystems = qualities.filter { $0.systemCount > 0 }.count
    let withMeasures = qualities.filter { $0.measureCount > 0 }.count
    let withNotes = qualities.filter { $0.totalNotes > 0 }.count
    let withBPM = qualities.filter { $0.detectedBPM != nil }.count
    let withTimeSig = qualities.filter { $0.detectedTimeSig != nil }.count
    let withTuning = qualities.filter { $0.detectedTuning != nil }.count
    let withKey = qualities.filter { $0.detectedKey != nil }.count
    let withMIDI = qualities.filter { $0.hasPairedMIDI }.count
    let withBarLines = qualities.filter { $0.hasBarLines }.count
    let withColon = qualities.filter { $0.usedColonSeparator }.count

    // Confidence distribution
    let confidences = qualities.map(\.confidence).sorted()
    let avgConfidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
    let medianConfidence = confidences.isEmpty ? 0 : confidences[confidences.count / 2]
    let highConfidence = qualities.filter { $0.confidence >= 0.7 }.count
    let medConfidence = qualities.filter { $0.confidence >= 0.4 && $0.confidence < 0.7 }.count
    let lowConfidence = qualities.filter { $0.confidence < 0.4 }.count

    // Per-source breakdown
    let sources = ["classtab", "brads", "eh", "toplevel", "classical", "other"]
    var sourceStats: [(String, Int, Int, Int, Double)] = []  // (source, total, withMeasures, withNotes, avgConf)
    for src in sources {
        let subset = qualities.filter { $0.source == src }
        guard !subset.isEmpty else { continue }
        let meas = subset.filter { $0.measureCount > 0 }.count
        let notes = subset.filter { $0.totalNotes > 0 }.count
        let avg = subset.map(\.confidence).reduce(0, +) / Double(subset.count)
        sourceStats.append((src, subset.count, meas, notes, avg))
    }

    // Worst 20 parses
    let worst20 = qualities
        .sorted { $0.confidence < $1.confidence }
        .prefix(20)

    // System line count distribution
    let allLineCounts = qualities.flatMap(\.tabLinesPerSystem)
    var lineCountDist: [Int: Int] = [:]
    for lc in allLineCounts {
        lineCountDist[lc, default: 0] += 1
    }

    // Measure count distribution
    let measureCounts = qualities.map(\.measureCount)
    let avgMeasures = measureCounts.isEmpty ? 0.0 : Double(measureCounts.reduce(0, +)) / Double(measureCounts.count)
    let maxMeasures = measureCounts.max() ?? 0

    // Note count distribution
    let noteCounts = qualities.map(\.totalNotes)
    let avgNotes = noteCounts.isEmpty ? 0.0 : Double(noteCounts.reduce(0, +)) / Double(noteCounts.count)

    // Warning distribution
    var warningCounts: [String: Int] = [:]
    for q in qualities {
        for w in q.warnings {
            warningCounts[w, default: 0] += 1
        }
    }

    // Build report
    var report = """
    ══════════════════════════════════════════════════════════════
    TAB TRAINING DATA — QUALITY REPORT (CHECKPOINT 3)
    Generated: \(ISO8601DateFormatter().string(from: Date()))
    ══════════════════════════════════════════════════════════════

    LIBRARY OVERVIEW
    ────────────────────────────────────────
    Total .txt files found:    \(txtFiles.count)
    Successfully parsed:       \(totalParsed)
    Errors (unreadable/skip):  \(errorFiles.count)

    PARSE SUCCESS RATES
    ────────────────────────────────────────
    Systems detected:          \(withSystems)/\(totalParsed) (\(pct(withSystems, totalParsed)))
    Measures detected:         \(withMeasures)/\(totalParsed) (\(pct(withMeasures, totalParsed)))
    Notes extracted:           \(withNotes)/\(totalParsed) (\(pct(withNotes, totalParsed)))
    Bar lines found:           \(withBarLines)/\(totalParsed) (\(pct(withBarLines, totalParsed)))
    Colon separator used:      \(withColon)/\(totalParsed) (\(pct(withColon, totalParsed)))

    METADATA DETECTION
    ────────────────────────────────────────
    BPM detected:              \(withBPM)/\(totalParsed) (\(pct(withBPM, totalParsed)))
    Time signature detected:   \(withTimeSig)/\(totalParsed) (\(pct(withTimeSig, totalParsed)))
    Tuning detected:           \(withTuning)/\(totalParsed) (\(pct(withTuning, totalParsed)))
    Key detected:              \(withKey)/\(totalParsed) (\(pct(withKey, totalParsed)))
    Paired MIDI found:         \(withMIDI)/\(totalParsed) (\(pct(withMIDI, totalParsed)))

    CONFIDENCE DISTRIBUTION
    ────────────────────────────────────────
    Average confidence:        \(String(format: "%.2f", avgConfidence))
    Median confidence:         \(String(format: "%.2f", medianConfidence))
    High (≥0.7):               \(highConfidence) (\(pct(highConfidence, totalParsed)))
    Medium (0.4-0.7):          \(medConfidence) (\(pct(medConfidence, totalParsed)))
    Low (<0.4):                \(lowConfidence) (\(pct(lowConfidence, totalParsed)))

    MEASURE STATISTICS
    ────────────────────────────────────────
    Average measures/file:     \(String(format: "%.1f", avgMeasures))
    Max measures in a file:    \(maxMeasures)
    Average notes/file:        \(String(format: "%.1f", avgNotes))

    TAB LINES PER SYSTEM
    ────────────────────────────────────────
    """

    for (count, freq) in lineCountDist.sorted(by: { $0.key < $1.key }) {
        report += "\(count) lines: \(freq) systems"
        if count == 6 { report += " (standard guitar)" }
        else if count == 4 { report += " (ukulele/bass)" }
        else if count == 7 { report += " (7-string or extra line)" }
        report += "\n"
    }

    report += """

    PER-SOURCE BREAKDOWN
    ────────────────────────────────────────
    """
    for (src, total, meas, notes, avg) in sourceStats {
        report += "\(src.padding(toLength: 12, withPad: " ", startingAt: 0))  "
        report += "total=\(String(total).padding(toLength: 5, withPad: " ", startingAt: 0))  "
        report += "measures=\(pct(meas, total).padding(toLength: 6, withPad: " ", startingAt: 0))  "
        report += "notes=\(pct(notes, total).padding(toLength: 6, withPad: " ", startingAt: 0))  "
        report += "avgConf=\(String(format: "%.2f", avg))\n"
    }

    report += """

    WARNING DISTRIBUTION
    ────────────────────────────────────────
    """
    for (warning, count) in warningCounts.sorted(by: { $0.value > $1.value }) {
        report += "\(warning.padding(toLength: 30, withPad: " ", startingAt: 0))  \(count) files\n"
    }

    report += """

    WORST 20 PARSES (lowest confidence — review these)
    ────────────────────────────────────────
    """
    for (i, q) in worst20.enumerated() {
        report += "\(i + 1). [\(String(format: "%.2f", q.confidence))] \(q.relativePath)\n"
        report += "   systems=\(q.systemCount) measures=\(q.measureCount) notes=\(q.totalNotes)"
        report += " bpm=\(q.detectedBPM.map { String(format: "%.0f", $0) } ?? "nil")"
        report += " timeSig=\(q.detectedTimeSig.map { "\($0.0)/\($0.1)" } ?? "nil")"
        report += " midi=\(q.hasPairedMIDI ? "YES" : "no")"
        if !q.warnings.isEmpty {
            report += "\n   ⚠️  \(q.warnings.joined(separator: ", "))"
        }
        report += "\n"
    }

    if !errorFiles.isEmpty {
        report += """

        SKIPPED FILES
        ────────────────────────────────────────
        """
        for (path, reason) in errorFiles.prefix(50) {
            report += "\(reason.padding(toLength: 25, withPad: " ", startingAt: 0))  \(path)\n"
        }
        if errorFiles.count > 50 {
            report += "... and \(errorFiles.count - 50) more\n"
        }
    }

    report += """

    ══════════════════════════════════════════════════════════════
    END OF REPORT
    ══════════════════════════════════════════════════════════════
    """

    // Write report
    let reportPath = (outputDir as NSString).appendingPathComponent("quality_report.txt")
    try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
    print("\nQuality report written to: \(reportPath)")
    print(report)

    // Write full quality data as JSON (for programmatic analysis)
    let qualityData: [[String: Any]] = qualities.map { q in
        var d: [String: Any] = [
            "filename": q.filename,
            "relativePath": q.relativePath,
            "source": q.source,
            "hasPairedMIDI": q.hasPairedMIDI,
            "fileSize": q.fileSize,
            "systemCount": q.systemCount,
            "measureCount": q.measureCount,
            "totalNotes": q.totalNotes,
            "tabLinesPerSystem": q.tabLinesPerSystem,
            "hasBarLines": q.hasBarLines,
            "usedColonSeparator": q.usedColonSeparator,
            "confidence": q.confidence,
            "warnings": q.warnings
        ]
        if let bpm = q.detectedBPM { d["detectedBPM"] = bpm }
        if let ts = q.detectedTimeSig { d["detectedTimeSig"] = "\(ts.0)/\(ts.1)" }
        if let t = q.detectedTuning { d["detectedTuning"] = t }
        if let k = q.detectedKey { d["detectedKey"] = k }
        return d
    }
    if let jsonData = try? JSONSerialization.data(withJSONObject: qualityData, options: [.prettyPrinted, .sortedKeys]),
       let jsonStr = String(data: jsonData, encoding: .utf8) {
        let qualityPath = (outputDir as NSString).appendingPathComponent("quality_data.json")
        try? jsonStr.write(toFile: qualityPath, atomically: true, encoding: .utf8)
        print("Quality data JSON written to: \(qualityPath)")
    }

    // Write training pairs JSON (the actual ML training data)
    // Filter to high-confidence parses only for training
    let highConfPairs = trainingPairs.filter { ($0["confidence"] as? Double ?? 0) >= 0.4 }
    if let pairData = try? JSONSerialization.data(withJSONObject: highConfPairs, options: [.sortedKeys]),
       let pairStr = String(data: pairData, encoding: .utf8) {
        let pairsPath = (outputDir as NSString).appendingPathComponent("training_pairs.json")
        try? pairStr.write(toFile: pairsPath, atomically: true, encoding: .utf8)
        print("Training pairs written to: \(pairsPath) (\(highConfPairs.count) pairs, confidence ≥ 0.4)")
    }

    // Summary stats for MIDI enrichment
    let midiEnriched = trainingPairs.filter { ($0["bpmSource"] as? String) == "midi" }.count
    let bothTimeSig = trainingPairs.filter { ($0["timeSigSource"] as? String) == "both" }.count
    let midiTimeSig = trainingPairs.filter { ($0["timeSigSource"] as? String) == "midi" }.count
    let multiTempo = trainingPairs.filter { ($0["midiTempoChanges"] as? Int ?? 0) > 1 }.count
    print("\nMIDI ENRICHMENT SUMMARY")
    print("────────────────────────────────────────")
    print("BPM from MIDI:             \(midiEnriched) files")
    print("TimeSig agreed (both):     \(bothTimeSig) files")
    print("TimeSig from MIDI only:    \(midiTimeSig) files")
    print("Multi-tempo pieces:        \(multiTempo) files")

    let elapsed = Date().timeIntervalSince(startTime)
    print("\nCompleted in \(String(format: "%.1f", elapsed)) seconds")
}

func pct(_ num: Int, _ total: Int) -> String {
    guard total > 0 else { return "0%" }
    return "\(Int(round(Double(num) / Double(total) * 100)))%"
}

@main
struct TabTrainingDataGeneratorMain {
    static func main() {
        run()
    }
}
