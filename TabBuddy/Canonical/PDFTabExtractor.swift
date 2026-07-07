//
//  PDFTabExtractor.swift
//  TabBuddy
//
//  Spatial TAB extraction for rendered-score PDFs (Guitar Pro / engraving
//  exports), where `PDFPage.string` is scrambled glyph soup but every glyph
//  carries a position.
//
//  Pipeline per page:
//    1. Rasterize and detect long horizontal dark rows → staff/tab lines.
//       Groups of 6 evenly spaced lines are TAB staves (5 = notation).
//    2. Collect digit text glyphs with their bounds; snap each glyph's
//       vertical center to the nearest line of its TAB staff → string index;
//       x-order gives time. Adjacent glyphs merge into multi-digit frets
//       (with a per-digit fallback when dense engraving glues separate notes).
//    3. Synthesize ASCII tab (proportional column spacing) that the existing
//       TabParser consumes, so all downstream conversion is shared.
//
//  Corpus-validated against 458 rendered PDFs: ~97% of in-staff digit glyphs
//  placed; spot-checked note-for-note against a hand-authored text tab of the
//  same arrangement.
//
//  Limitation: bar lines are vector art we don't reconstruct yet, so each
//  system parses as one measure with proportional note positions (rhythm is
//  synthesized — same provenance quality as most text tabs).
//

import Foundation
import PDFKit
import CoreGraphics

enum PDFTabExtractor {

    /// A detected TAB staff: 6 line y-positions (PDF coords, top-first).
    private struct TabStaff {
        let lines: [Double]
        var top: Double { lines[0] }
        var bottom: Double { lines[5] }
        var spacing: Double { (lines[0] - lines[5]) / 5 }
    }

    private struct Glyph {
        let ch: Character
        let x: Double
        let cy: Double
        let w: Double
        let h: Double
    }

    private struct Note {
        let string: Int   // 0 = high e (top line)
        let fret: Int
        let x: Double
    }

    // MARK: - Public API

    /// Reconstruct ASCII tab from a rendered-score PDF. Returns nil when no
    /// TAB staves with notes are found (not a tab score, or scanned image).
    static func asciiTab(from doc: PDFDocument) -> String? {
        var out: [String] = []
        var producedNotes = false

        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            if p == 0 {
                let header = headerLines(page)
                if !header.isEmpty { out.append(contentsOf: header); out.append("") }
            }
            guard let raster = Raster(page) else { continue }
            let rows = raster.lineRows(requireContinuous: false)
            let staves = tabStaves(from: rows)
            guard !staves.isEmpty else { continue }
            // A lead-sheet page can fake one 6-row group (5 lines + a ledger
            // band). Real TAB pages have TAB staves in proportion to notation
            // staves — if 5-line staves dominate, this page is notation-only.
            let fiveLine = staffGroups(from: rows, size: 5).count
            guard fiveLine < staves.count * 3 else { continue }
            let ds = digitGlyphs(on: page)

            for staff in staves {
                let ns = notes(for: staff, digits: ds)
                guard !ns.isEmpty else { continue }
                producedNotes = true
                // Real bar lines: vertical strokes spanning the staff. (TAB
                // staves have no stems inside, so candidates are reliable.)
                let bars = raster.barXs(topPDF: staff.top, bottomPDF: staff.bottom)
                out.append(contentsOf: asciiSystem(ns, spacing: staff.spacing, barXs: bars))
                out.append("")
            }
        }
        return producedNotes ? out.joined(separator: "\n") : nil
    }

    // MARK: - Staff-line detection (raster)

    /// A rendered page bitmap with helpers for line and bar detection.
    /// Rendered once per page; buffer row 0 is the TOP of the page.
    private struct Raster {
        let pixels: [UInt8]
        let w: Int
        let h: Int
        let scale: Double
        let originX: Double
        let originY: Double

        init?(_ page: PDFPage, scale: CGFloat = 2) {
            let box = page.bounds(for: .mediaBox)
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard w > 0, h > 0, w * h < 40_000_000,
                  let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
            page.draw(with: .mediaBox, to: ctx)
            guard let data = ctx.data else { return nil }
            let buf = data.bindMemory(to: UInt8.self, capacity: w * h)
            self.pixels = Array(UnsafeBufferPointer(start: buf, count: w * h))
            self.w = w
            self.h = h
            self.scale = Double(scale)
            self.originX = Double(box.origin.x)
            self.originY = Double(box.origin.y)
        }

        func pdfY(fromRow row: Double) -> Double { originY + (Double(h - 1) - row) / scale }
        func row(fromPDFY y: Double) -> Int { max(0, min(h - 1, Int((Double(h - 1) - (y - originY) * scale).rounded()))) }
        func pdfX(fromCol col: Double) -> Double { originX + col / scale }

        /// y-positions (PDF coords) of long horizontal dark rows — staff lines.
        ///
        /// `requireContinuous` demands one long unbroken run — right for
        /// notation staves (rejects bands of aligned ledger lines), wrong for
        /// TAB staves whose lines are knocked out behind every fret digit.
        func lineRows(requireContinuous: Bool = false) -> [Double] {
            let threshold = Int(Double(w) * 0.4)
            let runThreshold = requireContinuous ? Int(Double(w) * 0.5) : 0
            var centers: [Double] = []
            var runStart: Int? = nil
            for y in 0..<h {
                var count = 0
                var longest = 0
                var current = 0
                let base = y * w
                for x in 0..<w {
                    if pixels[base + x] < 160 {
                        count += 1
                        current += 1
                        if current > longest { longest = current }
                    } else {
                        current = 0
                    }
                }
                if count >= threshold, longest >= runThreshold {
                    if runStart == nil { runStart = y }
                } else if let s = runStart {
                    centers.append(Double(s + y - 1) / 2)
                    runStart = nil
                }
            }
            if let s = runStart { centers.append(Double(s + h - 1) / 2) }
            return centers.map { pdfY(fromRow: $0) }
        }

        /// PDF y of the notehead blob nearest `lastCy` in the column around
        /// `cx`: a dense run ~1 staff-spacing tall that doesn't extend
        /// sideways like a beam. Used when a glyph's selection box is a
        /// flattened text-run box carrying no per-glyph y.
        func noteheadBlobY(cx: Double, yLoPDF: Double, yHiPDF: Double,
                           spacing: Double, lastCy: Double) -> Double? {
            let colLo = max(0, Int((cx - spacing * 0.65 - originX) * scale))
            let colHi = min(w - 1, Int((cx + spacing * 0.65 - originX) * scale))
            guard colHi > colLo else { return nil }
            let rowTop = row(fromPDFY: yHiPDF)
            let rowBot = row(fromPDFY: yLoPDF)
            guard rowBot > rowTop else { return nil }
            let width = colHi - colLo + 1
            let need = Int(Double(width) * 0.7)
            var dense = [Bool](repeating: false, count: rowBot - rowTop + 1)
            for r in rowTop...rowBot {
                var c = 0
                for x in colLo...colHi where pixels[r * w + x] < 128 { c += 1 }
                dense[r - rowTop] = c >= need
            }
            let spacingPx = spacing * scale
            var best: Double? = nil
            var i = 0
            while i < dense.count {
                guard dense[i] else { i += 1; continue }
                var j = i
                while j + 1 < dense.count, dense[j + 1] { j += 1 }
                let runH = Double(j - i + 1)
                if runH >= spacingPx * 0.45, runH <= spacingPx * 1.5 {
                    let centerRow = Double(rowTop) + (Double(i) + Double(j)) / 2
                    // Beam check: a beam extends sideways across its full
                    // thickness; a staff line through a line-sitting notehead
                    // is only 1–2px tall. Probe several rows and take the
                    // MINIMUM extension so staff lines don't disqualify heads.
                    let cr = Int(centerRow)
                    let probeOffsets = [-Int(spacingPx * 0.25), 0, Int(spacingPx * 0.25)]
                    var minExtend = Int.max
                    for dy in probeOffsets {
                        let r = min(max(cr + dy, 0), h - 1)
                        var left = 0, right = 0
                        var x = colLo - 1
                        while x >= 0, pixels[r * w + x] < 128 { left += 1; x -= 1 }
                        x = colHi + 1
                        while x < w, pixels[r * w + x] < 128 { right += 1; x += 1 }
                        minExtend = min(minExtend, max(left, right))
                    }
                    if Double(minExtend) < spacingPx * 1.2 {
                        let py = pdfY(fromRow: centerRow)
                        if best == nil || abs(py - lastCy) < abs(best! - lastCy) { best = py }
                    }
                }
                i = j + 1
            }
            return best
        }

        /// x-positions (PDF coords) of vertical dark strokes spanning the full
        /// staff height between `topPDF` and `bottomPDF` — bar-line candidates.
        func barXs(topPDF: Double, bottomPDF: Double) -> [Double] {
            let r0 = row(fromPDFY: topPDF)      // smaller row index (top)
            let r1 = row(fromPDFY: bottomPDF)   // larger row index (bottom)
            guard r1 > r0 + 2 else { return [] }
            let span = r1 - r0 + 1
            let need = Int(Double(span) * 0.92)
            var centers: [Double] = []
            var runStart: Int? = nil
            for x in 0..<w {
                var count = 0
                for y in r0...r1 where pixels[y * w + x] < 160 { count += 1 }
                if count >= need {
                    if runStart == nil { runStart = x }
                } else if let s = runStart {
                    centers.append(Double(s + x - 1) / 2)
                    runStart = nil
                }
            }
            if let s = runStart { centers.append(Double(s + w - 1) / 2) }
            return centers.map { pdfX(fromCol: $0) }
        }
    }

    /// Group line rows into evenly spaced staves of `size` lines
    /// (6 = TAB, 5 = standard notation).
    private static func staffGroups(from rows: [Double], size: Int) -> [[Double]] {
        let sorted = rows.sorted()
        var groups: [[Double]] = []
        var group: [Double] = []

        func flush() {
            if group.count == size {
                groups.append(group.reversed())   // top-first
            }
            group = []
        }

        for y in sorted {
            if let last = group.last {
                let gap = y - last
                if group.count >= 2 {
                    let expected = (last - group[0]) / Double(group.count - 1)
                    if abs(gap - expected) > expected * 0.25 {
                        if group.count == 2 {
                            // The first row may be an outlier hugging the staff
                            // (e.g. a dense 16th-note beam reads as a line row):
                            // drop it and retry from the second row.
                            let keep = group[1]
                            flush()
                            group = [keep]
                        } else {
                            flush()
                        }
                    }
                } else if gap > 50 {   // line spacing ranges ~5–40pt across formats
                    flush()
                }
            }
            group.append(y)
            if group.count == 6 { flush() }   // 6 is the largest staff we accept
        }
        flush()
        return groups
    }

    private static func tabStaves(from rows: [Double]) -> [TabStaff] {
        staffGroups(from: rows, size: 6).map { TabStaff(lines: $0) }
            .sorted { $0.top > $1.top }
    }

    // MARK: - Glyphs

    private static func digitGlyphs(on page: PDFPage) -> [Glyph] {
        guard let text = page.string else { return [] }
        let ns = text as NSString
        var out: [Glyph] = []
        for i in 0..<ns.length {
            guard let scalar = UnicodeScalar(ns.character(at: i)) else { continue }
            let ch = Character(scalar)
            guard ch.isNumber else { continue }
            guard let sel = page.selection(for: NSRange(location: i, length: 1)) else { continue }
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0 else { continue }
            out.append(Glyph(ch: ch, x: b.origin.x, cy: b.origin.y + b.height / 2,
                             w: b.width, h: b.height))
        }
        return out
    }

    // MARK: - Note assembly

    private static func notes(for staff: TabStaff, digits: [Glyph]) -> [Note] {
        let spacing = staff.spacing
        var perString: [[Glyph]] = Array(repeating: [], count: 6)
        for d in digits {
            guard d.cy <= staff.top + spacing * 0.6, d.cy >= staff.bottom - spacing * 0.6 else { continue }
            // Music-font runs carry tall line boxes; real fret digits are staff-sized.
            guard d.h < spacing * 2.6 else { continue }
            var best = -1
            var bestDist = Double.infinity
            for (i, line) in staff.lines.enumerated() {
                let dist = abs(d.cy - line)
                if dist < bestDist { bestDist = dist; best = i }
            }
            guard best >= 0, bestDist <= spacing * 0.5 else { continue }
            perString[best].append(d)
        }

        var out: [Note] = []
        for (s, gsRaw) in perString.enumerated() {
            let gs = gsRaw.sorted { $0.x < $1.x }
            var i = 0
            while i < gs.count {
                var run = [gs[i]]
                var lastEnd = gs[i].x + gs[i].w
                var j = i + 1
                while j < gs.count, gs[j].x - lastEnd < spacing * 0.35 {
                    run.append(gs[j])
                    lastEnd = gs[j].x + gs[j].w
                    j += 1
                }
                let text = String(run.map(\.ch))
                if let fret = Int(text), fret <= 24 {
                    out.append(Note(string: s, fret: fret, x: run[0].x))
                } else {
                    // Dense engraving glued separate notes ("3"+"3" → 33):
                    // fall back to one note per digit.
                    for g in run {
                        if let fret = Int(String(g.ch)) {
                            out.append(Note(string: s, fret: fret, x: g.x))
                        }
                    }
                }
                i = j
            }
        }
        return out.sorted { $0.x < $1.x }
    }

    // MARK: - ASCII synthesis

    private static func asciiSystem(_ notes: [Note], spacing: Double,
                                    barXs: [Double] = []) -> [String] {
        guard let minX = notes.first?.x else { return [] }
        let labels = ["e", "B", "G", "D", "A", "E"]
        let scale = spacing * 0.4          // ~3pt per column at standard engraving
        let chordTol = spacing * 0.2
        var rows = labels.map { _ in "" }
        var lengths = [Int](repeating: 0, count: 6)

        var columns: [(x: Double, notes: [Note])] = []
        for n in notes {
            if var last = columns.last, abs(last.x - n.x) < chordTol {
                last.notes.append(n)
                columns[columns.count - 1] = last
            } else {
                columns.append((n.x, [n]))
            }
        }

        // Interleave detected bar lines. Bars past the last note are kept —
        // they delimit trailing whole-rest measures the chart still counts.
        var events: [(x: Double, bar: Bool, notes: [Note])] =
            columns.map { ($0.x, false, $0.notes) }
        for bx in barXs where bx > minX + spacing {
            events.append((bx, true, []))
        }
        events.sort { $0.x < $1.x }

        // Emit rows; remember each onset's and bar's final ASCII column so
        // durations can be derived afterwards.
        var onsetCols: [Int] = []
        var barCols: [Int] = []
        for ev in events {
            let target = 2 + Int(((ev.x - minX) / scale).rounded())
            if ev.bar {
                for s in 0..<6 {
                    let pad = max(target, lengths[s] + 1)
                    rows[s] += String(repeating: "-", count: max(0, pad - lengths[s])) + "|"
                    lengths[s] = pad + 1
                }
                barCols.append((lengths.max() ?? 1) - 1)
                continue
            }
            let width = ev.notes.map { String($0.fret).count }.max() ?? 1
            var placed = 0
            for s in 0..<6 {
                let pad = max(target, lengths[s] + 1)
                rows[s] += String(repeating: "-", count: max(0, pad - lengths[s]))
                if let n = ev.notes.first(where: { $0.string == s }) {
                    let fret = String(n.fret)
                    rows[s] += fret + String(repeating: "-", count: width - fret.count)
                } else {
                    rows[s] += String(repeating: "-", count: width)
                }
                placed = pad
                lengths[s] = pad + width
            }
            onsetCols.append(placed)
        }
        let maxLen = lengths.max() ?? 0

        // Rhythm line: proportional durations within each measure, snapped to
        // standard note values, written in the parser's native "Q E E H"
        // notation at the onset columns. 4/4 assumed — relative lengths stay
        // correct either way.
        var rhythm = [Character](repeating: " ", count: maxLen + 4)
        let boundaries = ([2] + barCols + [maxLen]).sorted()
        for (i, col) in onsetCols.enumerated() {
            let segStart = boundaries.last(where: { $0 <= col }) ?? 2
            let segEnd = boundaries.first(where: { $0 > col }) ?? maxLen
            guard segEnd > segStart else { continue }
            let nextOnset = (i + 1 < onsetCols.count && onsetCols[i + 1] < segEnd)
                ? onsetCols[i + 1] : segEnd
            let rawBeats = Double(nextOnset - col) / Double(segEnd - segStart) * 4.0
            let letter = RhythmDuration.nearest(toBeats: rawBeats).notation
            for (k, ch) in letter.enumerated() where col + k < rhythm.count {
                rhythm[col + k] = ch
            }
        }

        let stringRows = (0..<6).map { s in
            labels[s] + "|-" + rows[s]
                + String(repeating: "-", count: max(0, maxLen - lengths[s])) + "-|"
        }
        return ["   " + String(rhythm)] + stringRows
    }

    // MARK: - Debug introspection

    /// Extracted notation notes with page geometry, for diagnostics/overlay
    /// tooling. Page index, MIDI pitch, glyph x, and the snapped notehead
    /// center y (PDF coords).
    struct DebugNote {
        let page: Int
        let midi: Int
        let x: Double
        let snappedY: Double
    }

    /// Per-staff bar-line diagnostics: (page, staffTop, barXs after stem
    /// filtering, note count).
    static func debugStaffBars(from doc: PDFDocument) -> [(page: Int, top: Double, bars: [Double], notes: Int)] {
        var out: [(Int, Double, [Double], Int)] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p), let raster = Raster(page) else { continue }
            let staves = staffGroups(from: raster.lineRows(requireContinuous: true), size: 5)
                .map { NotationStaff(lines: $0) }
                .sorted { $0.top > $1.top }
            let gs = allGlyphs(on: page)
            for staff in staves {
                let pitches = melody(for: staff, glyphs: gs, raster: raster)
                let noteXs = pitches.map(\.x)
                let bars = raster.barXs(topPDF: staff.top, bottomPDF: staff.bottom)
                    .filter { bx in !noteXs.contains { abs($0 + staff.spacing * 0.5 - bx) < staff.spacing * 1.2 } }
                out.append((p, staff.top, bars, pitches.count))
            }
        }
        return out
    }

    /// Same pipeline as `asciiFromNotation`, but returns raw note geometry.
    static func debugNotationNotes(from doc: PDFDocument) -> [DebugNote] {
        var out: [DebugNote] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p), let raster = Raster(page) else { continue }
            let staves = staffGroups(from: raster.lineRows(requireContinuous: true), size: 5)
                .map { NotationStaff(lines: $0) }
                .sorted { $0.top > $1.top }
            guard !staves.isEmpty else { continue }
            let gs = allGlyphs(on: page)
            for staff in staves {
                for (midi, x, cy) in melody(for: staff, glyphs: gs, raster: raster) {
                    out.append(DebugNote(page: p, midi: midi, x: x, snappedY: cy))
                }
            }
        }
        return out
    }

    // MARK: - Notation (lead-sheet) melody extraction

    /// A 5-line notation staff.
    private struct NotationStaff {
        let lines: [Double]                   // top-first
        var top: Double { lines[0] }
        var bottom: Double { lines[4] }
        var mid: Double { lines[2] }
        var spacing: Double { (lines[0] - lines[4]) / 4 }
    }

    private static let noteheadChars = Set("œϖ˙wW")
    private static let letterSemis = [0, 2, 4, 5, 7, 9, 11]   // C D E F G A B

    /// Reconstruct a guitar-tab approximation of the melody in a notation-only
    /// PDF (lead sheet): notehead glyphs → staff step → pitch (treble clef +
    /// key signature) → string/fret via FretSuggestionEngine. Returns nil when
    /// no notation staves with notes are found.
    static func asciiFromNotation(from doc: PDFDocument) -> String? {
        let tuning = GuitarTuning.standard.midiNotes
        var out: [String] = []
        var produced = false

        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            if p == 0 {
                let header = headerLines(page)
                if !header.isEmpty { out.append(contentsOf: header); out.append("") }
            }
            guard let raster = Raster(page) else { continue }
            let staves = staffGroups(from: raster.lineRows(requireContinuous: true), size: 5)
                .map { NotationStaff(lines: $0) }
                .sorted { $0.top > $1.top }
            guard !staves.isEmpty else { continue }
            let gs = allGlyphs(on: page)

            for staff in staves {
                let pitches = melody(for: staff, glyphs: gs, raster: raster)
                guard !pitches.isEmpty else { continue }
                var notes: [Note] = []
                for (midi, x, _) in pitches {
                    // Fold into guitar range, then map to the lowest fret.
                    var m = midi
                    while m < tuning.min() ?? 40 { m += 12 }
                    while m > (tuning.max() ?? 64) + FretSuggestionEngine.maxFret { m -= 12 }
                    if let pos = FretSuggestionEngine.suggest(midiPitch: m, tuningMIDI: tuning) {
                        notes.append(Note(string: pos.string, fret: pos.fret, x: x))
                    }
                }
                guard !notes.isEmpty else { continue }
                produced = true
                // Bar candidates spanning the staff, minus note stems (a stem
                // always has a notehead glyph right next to it; a bar doesn't).
                let noteXs = pitches.map(\.x)
                let bars = raster.barXs(topPDF: staff.top, bottomPDF: staff.bottom)
                    .filter { bx in !noteXs.contains { abs($0 + staff.spacing * 0.5 - bx) < staff.spacing * 1.2 } }
                out.append(contentsOf: asciiSystem(notes, spacing: staff.spacing * 1.25, barXs: bars))
                out.append("")
            }
        }
        return produced ? out.joined(separator: "\n") : nil
    }

    private static func allGlyphs(on page: PDFPage) -> [Glyph] {
        guard let text = page.string else { return [] }
        let ns = text as NSString
        var out: [Glyph] = []
        for i in 0..<ns.length {
            guard let scalar = UnicodeScalar(ns.character(at: i)) else { continue }
            let ch = Character(scalar)
            guard ch.isNumber || ch == "#" || ch == "b" || noteheadChars.contains(ch) else { continue }
            guard let sel = page.selection(for: NSRange(location: i, length: 1)) else { continue }
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0 else { continue }
            out.append(Glyph(ch: ch, x: b.origin.x, cy: b.origin.y + b.height / 2,
                             w: b.width, h: b.height))
        }
        return out
    }

    /// Extract (midiPitch, x) melody notes for one notation staff.
    /// Treble clef assumed (lead sheets); key from the signature accidentals.
    private static func melody(for staff: NotationStaff, glyphs: [Glyph],
                                raster: Raster) -> [(midi: Int, x: Double, cy: Double)] {
        let spacing = staff.spacing

        var heads: [Glyph] = []
        for g in glyphs where noteheadChars.contains(g.ch) {
            guard g.cy < staff.top + spacing * 4, g.cy > staff.bottom - spacing * 4 else { continue }
            heads.append(g)
        }
        guard !heads.isEmpty else { return [] }
        heads.sort { $0.x < $1.x }

        // Key signature: accidental glyphs left of the first notehead.
        let firstX = heads[0].x
        var flats = 0, sharps = 0
        for g in glyphs where g.x < firstX && g.x > firstX - 120 {
            guard g.cy < staff.top + spacing * 2, g.cy > staff.bottom - spacing * 2 else { continue }
            if g.ch == "b" { flats += 1 }
            if g.ch == "#" { sharps += 1 }
        }
        let flatLetters = [6, 2, 5, 1, 4, 0, 3]    // B E A D G C F
        let sharpLetters = [3, 0, 4, 1, 5, 2, 6]   // F C G D A E B
        var keyAdjust = [Int](repeating: 0, count: 7)
        if flats > 0, flats <= 7 { for i in 0..<flats { keyAdjust[flatLetters[i]] = -1 } }
        else if sharps > 0, sharps <= 7 { for i in 0..<sharps { keyAdjust[sharpLetters[i]] = 1 } }

        var result: [(midi: Int, x: Double, cy: Double)] = []
        var lastCy = staff.mid   // melodic-continuity anchor
        for g in heads {
            // Notehead center. A bare head is its own box; a stemmed box has
            // the head at one END of the box (the stem extends from it) — but
            // which end is ambiguous from the box alone. Resolve by stem
            // direction consistency (stems point toward the middle line) and,
            // when both readings are plausible, by melodic continuity:
            // melodies move in steps, so prefer the reading nearest the
            // previous note.
            let headH = min(g.h, spacing * 1.1)
            let boxBottom = g.cy - g.h / 2
            let boxTop = g.cy + g.h / 2
            let cy: Double
            if g.h <= spacing * 1.4 {
                cy = g.cy
            } else if let blob = raster.noteheadBlobY(cx: g.x + g.w / 2,
                                                      yLoPDF: boxBottom - spacing * 0.5,
                                                      yHiPDF: boxTop + spacing * 0.5,
                                                      spacing: spacing, lastCy: lastCy) {
                // Tall box = flattened text-run box or notehead+stem; the
                // raster blob is the actual notehead either way.
                cy = blob
            } else {
                let headLow = boxBottom + headH / 2       // stem-up reading
                let headHigh = boxTop - headH / 2         // stem-down reading
                let upValid = headLow < staff.mid - spacing * 0.25
                let downValid = headHigh > staff.mid - spacing * 0.25
                if upValid && !downValid { cy = headLow }
                else if downValid && !upValid { cy = headHigh }
                else {
                    cy = abs(headLow - lastCy) <= abs(headHigh - lastCy) ? headLow : headHigh
                }
            }
            lastCy = cy

            // Staff step in half-spacings above the bottom line (E4, treble).
            let k = Int(((cy - staff.bottom) / (spacing / 2)).rounded())
            let absDia = 4 * 7 + 2 + k
            guard absDia >= 7, absDia <= 70 else { continue }
            let octave = absDia / 7
            let letter = absDia % 7
            let midi = (octave + 1) * 12 + letterSemis[letter] + keyAdjust[letter]
            // snapped notehead center for diagnostics
            let snapped = staff.bottom + Double(k) * (spacing / 2)
            result.append((midi, g.x, snapped))
        }
        return result
    }

    // MARK: - Header metadata

    /// Tempo/capo directives from the first page, in a form TabParser reads.
    private static func headerLines(_ page: PDFPage) -> [String] {
        guard let text = page.string else { return [] }
        var out: [String] = []
        for line in text.components(separatedBy: "\n").prefix(40) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()
            if lower.range(of: #"^[q♩]\s*=\s*\d+"#, options: .regularExpression) != nil {
                out.append("Tempo: " + t.filter(\.isNumber))
            } else if lower.hasPrefix("capo") {
                out.append(t)
            }
        }
        return out
    }
}
