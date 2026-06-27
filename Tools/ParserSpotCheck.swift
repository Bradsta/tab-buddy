//
//  ParserSpotCheck.swift
//  Visual spot-check of parser output against raw tab content.
//  Shows detected systems, measure boundaries, and note positions.
//

import Foundation
import CoreGraphics

func spotCheck() {
    let lib = "/Users/Chronos/Library/Mobile Documents/com~apple~CloudDocs/guitar tabs"
    let fm = FileManager.default

    let testFiles: [(String, String)] = [
        // New pattern 6: letter-dash (no separator)
        ("Brads Tabs/Animal Crossing/Animal Crossing - Rainy Day.txt", "letter-dash, no bars"),
        ("classtab/bach_js_bwv0825_keyboard_partita_no1_in_bb_7_gigue.txt", "letter-dash with bars"),
        ("classtab/barrios_danza_paraguaya_1.txt", "E* repeat marker"),
        ("classtab/dowland_john_the_frog_galliard.txt", "E-space format"),
        // Sharp label
        ("Eh/bastion slingers song.txt", "sharp labels d#|"),
        // Regression checks (existing formats)
        ("classtab/abreu_amando_sobre_o_mar.txt", "standard pipe + beat ruler"),
        ("classtab/carulli_op027_duo_in_g_1_allegro.txt", "standard classtab"),
        ("Eh/ac 12pm.txt", "beat ruler + rest notation"),
    ]

    for (relPath, description) in testFiles {
        let fullPath = (lib as NSString).appendingPathComponent(relPath)
        guard let data = fm.contents(atPath: fullPath),
              let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .ascii)
                      ?? String(data: data, encoding: .isoLatin1)
        else {
            print("!! CANNOT READ: \(relPath)")
            continue
        }

        let result = TabParser.parse(text)
        let filename = (relPath as NSString).lastPathComponent

        print("")
        print("═══════════════════════════════════════════════════════════════")
        print("FILE: \(filename)")
        print("TYPE: \(description)")
        print("═══════════════════════════════════════════════════════════════")

        // Metadata
        print("BPM: \(result.bpm.map { String(format: "%.1f", $0) } ?? "not detected")")
        print("Time Sig: \(result.timeSignature.map { "\($0.beats)/\($0.noteValue)" } ?? "not detected")")
        print("Tuning: \(result.tuning ?? "not detected")")
        print("Key: \(result.key ?? "not detected")")
        print("Systems: \(result.systems.count)  |  Total measures: \(result.measureCount)")

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                              .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        // Show first 3 systems with measure overlay
        let systemsToShow = min(3, result.systems.count)
        for sysIdx in 0..<systemsToShow {
            let sys = result.systems[sysIdx]
            guard let lineRange = sys.lineRange else { continue }

            print("")
            print("── System \(sysIdx + 1) (lines \(lineRange.lowerBound)-\(lineRange.upperBound - 1), \(sys.measures.count) measures) ──")

            // Print the raw tab lines for this system
            for lineIdx in lineRange {
                if lineIdx < lines.count {
                    let lineNum = String(format: "%3d", lineIdx)
                    print("  \(lineNum)│ \(lines[lineIdx])")
                }
            }

            // Print measure boundary markers aligned to columns
            if let firstTabLine = lineRange.first, firstTabLine < lines.count {
                let tabLine = lines[firstTabLine]
                var markers = String(repeating: " ", count: tabLine.count + 6) // +6 for line number prefix
                for (mIdx, m) in sys.measures.enumerated() {
                    if let cr = m.columnRange {
                        let startPos = cr.lowerBound + 6 // offset for line number prefix
                        let endPos = min(cr.upperBound + 5, markers.count - 1)
                        if startPos < markers.count {
                            let label = "M\(m.measureNumber)"
                            var arr = Array(markers)
                            arr[startPos] = "["
                            for (i, ch) in label.enumerated() {
                                let pos = startPos + 1 + i
                                if pos < arr.count { arr[pos] = ch }
                            }
                            let closePos = startPos + 1 + label.count
                            if closePos < arr.count { arr[closePos] = "]" }
                            if endPos < arr.count { arr[endPos] = "◆" }
                            markers = String(arr)
                        }
                    }
                }
                print("     │ \(markers.dropFirst(6))")
            }

            // Print note summary for each measure
            for m in sys.measures {
                let noteCount = m.notes?.count ?? 0
                let noteDesc: String
                if let notes = m.notes, !notes.isEmpty {
                    let fretSummary = notes.prefix(5).map { n in
                        let frets = n.frets.compactMap { $0 }.map(String.init).joined(separator: ",")
                        return "[\(frets)]"
                    }.joined(separator: " ")
                    let more = noteCount > 5 ? " +\(noteCount - 5) more" : ""
                    noteDesc = "\(noteCount) notes: \(fretSummary)\(more)"
                } else {
                    noteDesc = "0 notes"
                }
                print("       M\(m.measureNumber): \(m.beatCount) beats, \(noteDesc)")
            }
        }

        if result.systems.count > systemsToShow {
            print("\n  ... \(result.systems.count - systemsToShow) more systems ...")
        }

        print("")
    }
}

@main
struct ParserSpotCheckMain {
    static func main() {
        spotCheck()
    }
}
