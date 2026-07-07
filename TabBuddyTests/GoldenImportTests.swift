//
//  GoldenImportTests.swift
//  TabBuddyTests
//
//  Golden-master import tests: each fixture must parse note-for-note into
//  the frozen .golden.txt next to it. Goldens are per-measure event lists
//  ("m12: D2 G2 [e0+B2]"), so any change to extraction, OCR, or parsing
//  that alters a single note fails loudly with a measure-level diff.
//
//  Coverage: image-only OCR PDFs (ard-skellig — hand-verified 1:1 against
//  the engraving), notation lead-sheets (corridors-of-time), text-glyph
//  rendered PDFs (lazy-afternoons), Ultimate-Guitar-style text tabs
//  (comet-observatory, taverns-alliance), and classtab.org format
//  (classtab-segovia, classtab-aguado).
//
//  Regenerate a golden (after VERIFYING the new output is correct!) with
//  the mkgolden harness — see .diag notes / project memory.
//

import XCTest
import PDFKit
@testable import TabBuddy

final class GoldenImportTests: XCTestCase {

    // MARK: - Pipeline

    /// Mirrors the mkgolden harness — keep in sync.
    private func serialize(_ map: MeasureMap) -> String {
        let names = ["e", "B", "G", "D", "A", "E"]
        var lines: [String] = []
        for (mi, measure) in map.allMeasures.enumerated() {
            var parts: [String] = []
            for ev in (measure.notes ?? []).sorted(by: { $0.positionInMeasure < $1.positionInMeasure }) {
                var toks: [String] = []
                for (si, f) in ev.frets.enumerated() where f != nil {
                    toks.append("\(names[si])\(f!)")
                }
                if toks.count > 1 { parts.append("[" + toks.joined(separator: "+") + "]") }
                else if let t = toks.first { parts.append(t) }
            }
            lines.append("m\(mi + 1): " + parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
                      "missing fixture \(name).\(ext)")
    }

    private func importText(_ name: String) throws -> String {
        let raw = try String(contentsOf: fixture(name, "txt"))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return serialize(TabParser.parse(raw))
    }

    private func importPDF(_ name: String) throws -> String {
        let doc = try XCTUnwrap(PDFDocument(url: fixture(name, "pdf")))
        let ascii: String
        if let tab = PDFTabExtractor.asciiTab(from: doc) {
            ascii = tab
        } else {
            ascii = try XCTUnwrap(PDFTabExtractor.asciiFromNotation(from: doc),
                                  "no extraction produced for \(name)")
        }
        return serialize(TabParser.parse(ascii))
    }

    private func assertGolden(_ produced: String, _ name: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let golden = try String(contentsOf: fixture("\(name).golden", "txt"))
        guard produced != golden else { return }
        // Debug aid: full produced output for offline diffing (simulator
        // shares the host filesystem).
        try? produced.write(toFile: "/tmp/\(name).produced.txt", atomically: true, encoding: .utf8)
        // Fail with a per-measure diff, not a wall of text.
        let a = produced.components(separatedBy: "\n")
        let b = golden.components(separatedBy: "\n")
        var diffs: [String] = []
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "<missing>"
            let y = i < b.count ? b[i] : "<missing>"
            if x != y { diffs.append("  got:      \(x)\n  expected: \(y)") }
            if diffs.count >= 8 { diffs.append("  …"); break }
        }
        XCTFail("\(name) diverged from golden (\(diffs.count) differing measures shown):\n"
                + diffs.joined(separator: "\n"), file: file, line: line)
    }

    // MARK: - Image-only PDF (OCR path; hand-verified 1:1 vs the engraving)

    func testArdSkelligOCRImport() throws {
        try assertGolden(try importPDF("ard-skellig"), "ard-skellig")
    }

    // MARK: - Notation lead-sheet PDF

    func testCorridorsOfTimeNotationImport() throws {
        try assertGolden(try importPDF("corridors-of-time"), "corridors-of-time")
    }

    // MARK: - Text-glyph rendered PDF

    func testLazyAfternoonsSpatialImport() throws {
        try assertGolden(try importPDF("lazy-afternoons"), "lazy-afternoons")
    }

    // MARK: - Ultimate-Guitar-style text tabs

    func testCometObservatoryTextImport() throws {
        try assertGolden(try importText("comet-observatory"), "comet-observatory")
    }

    func testTavernsAllianceTextImport() throws {
        try assertGolden(try importText("taverns-alliance"), "taverns-alliance")
    }

    // MARK: - classtab.org format

    func testClasstabSegoviaImport() throws {
        try assertGolden(try importText("classtab-segovia"), "classtab-segovia")
    }

    func testClasstabAguadoImport() throws {
        try assertGolden(try importText("classtab-aguado"), "classtab-aguado")
    }
}
