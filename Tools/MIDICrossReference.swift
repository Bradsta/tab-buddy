//
//  MIDICrossReference.swift
//  Tab Buddy — ML Training Data Pipeline
//
//  Cross-references parser output with paired MIDI files to:
//  1. Validate and enrich training labels with ground truth BPM/time-sig
//  2. Report discrepancies between parser and MIDI
//

import AudioToolbox
import Foundation
import CoreGraphics

// MARK: - Cross-Reference Result

struct MIDICrossRefResult {
    let relativePath: String
    let midPath: String

    // Parser values
    let parserBPM: Double?
    let parserTimeSig: (Int, Int)?
    let parserMeasureCount: Int

    // MIDI values
    let midiBPM: Double?
    let midiTimeSig: (Int, Int)?
    let midiTempoChanges: Int

    // Comparison
    var bpmMatch: BPMMatch {
        guard let pBPM = parserBPM, let mBPM = midiBPM else {
            if parserBPM == nil && midiBPM != nil { return .parserMissing }
            if parserBPM != nil && midiBPM == nil { return .midiMissing }
            return .bothMissing
        }
        let diff = abs(pBPM - mBPM)
        if diff < 1.0 { return .exact }
        if diff < 5.0 { return .close }
        // Check for double/half tempo (common discrepancy)
        if abs(pBPM - mBPM * 2) < 5.0 || abs(pBPM * 2 - mBPM) < 5.0 { return .doubleHalf }
        return .mismatch(parserBPM: pBPM, midiBPM: mBPM)
    }

    var timeSigMatch: TimeSigMatch {
        guard let pTS = parserTimeSig, let mTS = midiTimeSig else {
            if parserTimeSig == nil && midiTimeSig != nil { return .parserMissing }
            if parserTimeSig != nil && midiTimeSig == nil { return .midiMissing }
            return .bothMissing
        }
        if pTS.0 == mTS.0 && pTS.1 == mTS.1 { return .exact }
        return .mismatch(parser: pTS, midi: mTS)
    }
}

enum BPMMatch: CustomStringConvertible {
    case exact, close, doubleHalf, parserMissing, midiMissing, bothMissing
    case mismatch(parserBPM: Double, midiBPM: Double)

    var description: String {
        switch self {
        case .exact: return "EXACT"
        case .close: return "CLOSE"
        case .doubleHalf: return "DOUBLE/HALF"
        case .parserMissing: return "PARSER_MISSING"
        case .midiMissing: return "MIDI_MISSING"
        case .bothMissing: return "BOTH_MISSING"
        case .mismatch(let p, let m): return "MISMATCH(parser=\(String(format: "%.0f", p)), midi=\(String(format: "%.0f", m)))"
        }
    }

    var isAgreement: Bool {
        switch self {
        case .exact, .close: return true
        default: return false
        }
    }
}

enum TimeSigMatch: CustomStringConvertible {
    case exact, parserMissing, midiMissing, bothMissing
    case mismatch(parser: (Int, Int), midi: (Int, Int))

    var description: String {
        switch self {
        case .exact: return "EXACT"
        case .parserMissing: return "PARSER_MISSING"
        case .midiMissing: return "MIDI_MISSING"
        case .bothMissing: return "BOTH_MISSING"
        case .mismatch(let p, let m): return "MISMATCH(parser=\(p.0)/\(p.1), midi=\(m.0)/\(m.1))"
        }
    }

    var isAgreement: Bool {
        switch self {
        case .exact: return true
        default: return false
        }
    }
}

// MARK: - Main

func runCrossRef() {
    // Disable stdout buffering so progress appears in real time
    setbuf(stdout, nil)

    let args = CommandLine.arguments
    guard args.count >= 3 else {
        print("Usage: midi_cross_ref <library-path> <output-dir>")
        exit(1)
    }

    let libraryPath = args[1]
    let outputDir = args[2]
    let fm = FileManager.default

    try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    // Find all .txt files with paired .mid
    print("Scanning library at: \(libraryPath)")
    let enumerator = fm.enumerator(atPath: libraryPath)
    var pairedFiles: [(txt: String, mid: String)] = []
    while let file = enumerator?.nextObject() as? String {
        if file.hasSuffix(".txt") {
            let basePath = (file as NSString).deletingPathExtension
            let midFile = basePath + ".mid"
            let midFullPath = (libraryPath as NSString).appendingPathComponent(midFile)
            if fm.fileExists(atPath: midFullPath) {
                pairedFiles.append((txt: file, mid: midFile))
            }
        }
    }
    pairedFiles.sort { $0.txt < $1.txt }
    print("Found \(pairedFiles.count) paired .txt + .mid files")

    var results: [MIDICrossRefResult] = []
    let startTime = Date()

    for (idx, pair) in pairedFiles.enumerated() {
        let txtFullPath = (libraryPath as NSString).appendingPathComponent(pair.txt)
        let midFullPath = (libraryPath as NSString).appendingPathComponent(pair.mid)

        // Parse text
        guard let data = fm.contents(atPath: txtFullPath),
              let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .ascii)
                      ?? String(data: data, encoding: .isoLatin1)
        else { continue }

        let parseResult = TabParser.parse(text)

        // Extract MIDI tempo
        let midURL = URL(fileURLWithPath: midFullPath)
        let midiData = MIDITempoExtractor.extract(from: midURL)

        let result = MIDICrossRefResult(
            relativePath: pair.txt,
            midPath: pair.mid,
            parserBPM: parseResult.bpm,
            parserTimeSig: parseResult.timeSignature.map { ($0.beats, $0.noteValue) },
            parserMeasureCount: parseResult.measureCount,
            midiBPM: midiData?.initialBPM,
            midiTimeSig: midiData?.timeSignature.map { ($0.beats, $0.noteValue) },
            midiTempoChanges: midiData?.tempoChanges.count ?? 0
        )
        results.append(result)

        if (idx + 1) % 500 == 0 || idx == pairedFiles.count - 1 {
            let elapsed = Date().timeIntervalSince(startTime)
            let rate = Double(idx + 1) / elapsed
            print("  Processed \(idx + 1)/\(pairedFiles.count) (\(String(format: "%.0f", rate)) files/sec)")
        }
    }

    // MARK: - Report

    let total = results.count

    // BPM comparison
    let bpmExact = results.filter { $0.bpmMatch.isAgreement }.count
    let bpmDoubleHalf = results.filter { if case .doubleHalf = $0.bpmMatch { return true }; return false }.count
    let bpmParserMissing = results.filter { if case .parserMissing = $0.bpmMatch { return true }; return false }.count
    let bpmMidiMissing = results.filter { if case .midiMissing = $0.bpmMatch { return true }; return false }.count
    let bpmBothMissing = results.filter { if case .bothMissing = $0.bpmMatch { return true }; return false }.count
    let bpmMismatch = results.filter { if case .mismatch = $0.bpmMatch { return true }; return false }.count

    // Time sig comparison
    let tsExact = results.filter { $0.timeSigMatch.isAgreement }.count
    let tsParserMissing = results.filter { if case .parserMissing = $0.timeSigMatch { return true }; return false }.count
    let tsMidiMissing = results.filter { if case .midiMissing = $0.timeSigMatch { return true }; return false }.count
    let tsBothMissing = results.filter { if case .bothMissing = $0.timeSigMatch { return true }; return false }.count
    let tsMismatch = results.filter { if case .mismatch = $0.timeSigMatch { return true }; return false }.count

    // Files where MIDI provides data the parser missed
    let midiEnrichesBPM = results.filter {
        if case .parserMissing = $0.bpmMatch { return true }; return false
    }
    let midiEnrichesTS = results.filter {
        if case .parserMissing = $0.timeSigMatch { return true }; return false
    }

    // Tempo change complexity
    let singleTempo = results.filter { $0.midiTempoChanges <= 1 }.count
    let multiTempo = results.filter { $0.midiTempoChanges > 1 }.count
    let complexTempo = results.filter { $0.midiTempoChanges > 5 }.count

    // BPM mismatches (for review)
    let mismatches = results.filter { if case .mismatch = $0.bpmMatch { return true }; return false }
    let doubleHalves = results.filter { if case .doubleHalf = $0.bpmMatch { return true }; return false }

    // Time sig mismatches
    let tsMismatches = results.filter { if case .mismatch = $0.timeSigMatch { return true }; return false }

    func pct(_ n: Int, _ t: Int) -> String {
        guard t > 0 else { return "0%" }
        return "\(Int(round(Double(n) / Double(t) * 100)))%"
    }

    var report = """
    ══════════════════════════════════════════════════════════════
    MIDI CROSS-REFERENCE REPORT
    Generated: \(ISO8601DateFormatter().string(from: Date()))
    ══════════════════════════════════════════════════════════════

    OVERVIEW
    ────────────────────────────────────────
    Paired .txt + .mid files:      \(total)

    BPM COMPARISON
    ────────────────────────────────────────
    Exact/close match:             \(bpmExact)/\(total) (\(pct(bpmExact, total)))
    Double/half tempo:             \(bpmDoubleHalf)/\(total) (\(pct(bpmDoubleHalf, total)))
    True mismatch:                 \(bpmMismatch)/\(total) (\(pct(bpmMismatch, total)))
    Parser missing, MIDI has:      \(bpmParserMissing)/\(total) (\(pct(bpmParserMissing, total)))
    MIDI missing, parser has:      \(bpmMidiMissing)/\(total) (\(pct(bpmMidiMissing, total)))
    Both missing:                  \(bpmBothMissing)/\(total) (\(pct(bpmBothMissing, total)))

    → MIDI can enrich \(midiEnrichesBPM.count) files with BPM the parser didn't detect

    TIME SIGNATURE COMPARISON
    ────────────────────────────────────────
    Exact match:                   \(tsExact)/\(total) (\(pct(tsExact, total)))
    True mismatch:                 \(tsMismatch)/\(total) (\(pct(tsMismatch, total)))
    Parser missing, MIDI has:      \(tsParserMissing)/\(total) (\(pct(tsParserMissing, total)))
    MIDI missing, parser has:      \(tsMidiMissing)/\(total) (\(pct(tsMidiMissing, total)))
    Both missing:                  \(tsBothMissing)/\(total) (\(pct(tsBothMissing, total)))

    → MIDI can enrich \(midiEnrichesTS.count) files with time sig the parser didn't detect

    TEMPO COMPLEXITY
    ────────────────────────────────────────
    Single tempo:                  \(singleTempo) (\(pct(singleTempo, total)))
    Multiple tempo changes:        \(multiTempo) (\(pct(multiTempo, total)))
    Complex (>5 changes):          \(complexTempo) (\(pct(complexTempo, total)))

    """

    if !mismatches.isEmpty {
        report += """
        BPM MISMATCHES (review these — possible parser errors)
        ────────────────────────────────────────
        """
        for r in mismatches.prefix(30) {
            report += "\(r.relativePath)\n"
            report += "   parser=\(r.parserBPM.map { String(format: "%.0f", $0) } ?? "nil") "
            report += "midi=\(r.midiBPM.map { String(format: "%.0f", $0) } ?? "nil") "
            report += "tempoChanges=\(r.midiTempoChanges)\n"
        }
        if mismatches.count > 30 {
            report += "... and \(mismatches.count - 30) more\n"
        }
        report += "\n"
    }

    if !doubleHalves.isEmpty {
        report += """
        DOUBLE/HALF TEMPO (common discrepancy — parser and MIDI disagree by 2x)
        ────────────────────────────────────────
        """
        for r in doubleHalves.prefix(20) {
            report += "\(r.relativePath)\n"
            report += "   parser=\(r.parserBPM.map { String(format: "%.0f", $0) } ?? "nil") "
            report += "midi=\(r.midiBPM.map { String(format: "%.0f", $0) } ?? "nil")\n"
        }
        if doubleHalves.count > 20 {
            report += "... and \(doubleHalves.count - 20) more\n"
        }
        report += "\n"
    }

    if !tsMismatches.isEmpty {
        report += """
        TIME SIGNATURE MISMATCHES
        ────────────────────────────────────────
        """
        for r in tsMismatches.prefix(30) {
            report += "\(r.relativePath)\n"
            if case .mismatch(let p, let m) = r.timeSigMatch {
                report += "   parser=\(p.0)/\(p.1) midi=\(m.0)/\(m.1)\n"
            }
        }
        if tsMismatches.count > 30 {
            report += "... and \(tsMismatches.count - 30) more\n"
        }
        report += "\n"
    }

    report += """
    ══════════════════════════════════════════════════════════════
    END OF REPORT
    ══════════════════════════════════════════════════════════════
    """

    // Write report
    let reportPath = (outputDir as NSString).appendingPathComponent("midi_cross_ref_report.txt")
    try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
    print("\nReport written to: \(reportPath)")
    print(report)

    let elapsed = Date().timeIntervalSince(startTime)
    print("\nCompleted in \(String(format: "%.1f", elapsed)) seconds")
}

@main
struct MIDICrossRefMain {
    static func main() {
        runCrossRef()
    }
}
