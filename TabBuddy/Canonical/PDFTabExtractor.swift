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
import Vision

enum PDFTabExtractor {

    /// A detected TAB staff: 6 line y-positions (PDF coords, top-first).
    private struct TabStaff {
        let lines: [Double]
        var top: Double { lines[0] }
        var bottom: Double { lines[lines.count - 1] }
        var spacing: Double { (top - bottom) / Double(max(1, lines.count - 1)) }
    }

    private struct Glyph {
        let ch: Character
        let x: Double
        let cy: Double
        let w: Double
        let h: Double
        /// From the OCR fallback (looser boxes → stricter merge rules).
        var ocr: Bool = false
    }

    private struct Note {
        let string: Int   // 0 = high e (top line)
        let fret: Int
        let x: Double
    }

    // MARK: - Public API

    /// Reconstruct ASCII tab from a rendered-score PDF. Returns nil when no
    /// TAB staves with notes are found (not a tab score, or scanned image).
    static func asciiTab(from doc: PDFDocument, stringCount requestedCount: Int? = nil) -> String? {
        let header = doc.page(at: 0)?.string ?? ""
        let map = TabParser.parse(header)
        let instrument = Instrument.detect(inText: header)
        let declaredCount = header.range(of: #"\b(?:[4-9]|1[0-2])[- ]strings?\b"#, options: [.regularExpression, .caseInsensitive])
            .flatMap { Int(header[$0].prefix(while: \.isNumber)) }
        let stringCount = requestedCount ?? declaredCount ?? (map.tuning == nil ? nil : map.resolvedOpenStringMIDI?.count)
            ?? ((instrument == .bass || instrument == .ukulele) ? 4 : 6)
        guard (2...12).contains(stringCount) else { return nil }
        let knownTuning = map.resolvedOpenStringMIDI.flatMap { $0.count == stringCount ? $0 : nil }
        let fallback = instrument == .bass && stringCount == 4 ? GuitarTuning.bass4 :
            instrument == .ukulele && stringCount == 4 ? GuitarTuning.ukulele : nil
        let spelledLabels = GuitarTuning.noteSpelling(map.tuning ?? "").flatMap { $0.count == stringCount ? Array($0.reversed()) : nil }
        let labels = (knownTuning ?? fallback?.midiNotes).map { GuitarTuning(name: "", midiNotes: $0).noteNames }
            ?? spelledLabels ?? (stringCount == 6 && map.tuning == nil ? GuitarTuning.standard.noteNames : Array(repeating: "", count: stringCount))
        var out: [String] = map.tuning.map { ["Tuning: " + $0, ""] } ?? []
        var producedNotes = false

        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            if p == 0 {
                let header = headerLines(page)
                if !header.isEmpty { out.append(contentsOf: header); out.append("") }
            }
            guard let raster = Raster(page) else { continue }
            let rows = raster.lineRows(requireContinuous: false)
            let staves = tabStaves(from: rows, count: stringCount)
            guard !staves.isEmpty else { continue }
            // A lead-sheet page can fake one 6-row group (5 lines + a ledger
            // band). Real TAB pages have TAB staves in proportion to notation
            // staves — if 5-line staves dominate, this page is notation-only.
            let fiveLine = staffGroups(from: rows, size: 5).count
            guard stringCount == 5 || fiveLine < staves.count * 3 else { continue }
            var ds = digitGlyphs(on: page)
            // Image-only scan (no text layer): OCR the fret digits instead.
            if ds.isEmpty { ds = ocrDigitGlyphs(on: page, staves: staves) }

            for staff in staves {
                let ns = notes(for: staff, digits: ds)
                guard !ns.isEmpty else { continue }
                producedNotes = true
                // Real bar lines: vertical strokes spanning the staff. (TAB
                // staves have no stems inside, so candidates are reliable.)
                var bars = raster.barXs(topPDF: staff.top, bottomPDF: staff.bottom)
                // Repeat/double barlines are stroke PAIRS — collapse them so
                // they don't mint sliver measures; drop bars left of the
                // first note (frame line, clef/time-signature gap).
                bars = bars.reduce(into: [Double]()) { acc, x in
                    if let last = acc.last, x - last < staff.spacing * 1.2 { return }
                    acc.append(x)
                }
                if let firstX = ns.first?.x {
                    bars.removeAll { $0 < firstX - staff.spacing * 0.8 }
                }
                if ProcessInfo.processInfo.environment["OCR_DEBUG"] != nil {
                    print("STAFF top=\(Int(staff.top)) firstNote=\(Int(ns.first?.x ?? -1)) bars=\(bars.map { Int($0) })")
                    for n in ns.prefix(4) { print("  NOTE x=\(Int(n.x)) s=\(n.string) f=\(n.fret)") }
                }
                out.append(contentsOf: asciiSystem(ns, spacing: staff.spacing, barXs: bars, labels: labels))
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
            if group.count == max(6, size) { flush() }   // Keep five-line notation distinct from six-line tablature.
        }
        flush()
        return groups
    }

    private static func tabStaves(from rows: [Double], count: Int = 6) -> [TabStaff] {
        staffGroups(from: rows, size: count).map { TabStaff(lines: $0) }
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

    /// OCR stats from the most recent asciiTab run (image-only pages):
    /// candidates = digit-sized ink blobs found in staves, classified = blobs
    /// a digit could be read from. Drives honest provenance confidence.
    /// Per-conversion counters. The library converter runs several documents at
    /// once, so each job binds its own instance (`$ocrStats.withValue`); unbound
    /// callers (tools, tests) share a fallback instance.
    final class OCRStats: @unchecked Sendable {
        private let lock = NSLock()
        private var value = (candidates: 0, classified: 0)
        var current: (candidates: Int, classified: Int) { lock.withLock { value } }
        func add(candidates: Int, classified: Int) {
            lock.withLock { value = (value.candidates + candidates, value.classified + classified) }
        }
        func reset() { lock.withLock { value = (0, 0) } }
    }
    @TaskLocal static var ocrStats: OCRStats?
    private static let unboundOCRStats = OCRStats()
    private static var activeOCRStats: OCRStats { ocrStats ?? unboundOCRStats }
    static var lastOCRStats: (candidates: Int, classified: Int) { activeOCRStats.current }

    /// OCR fallback for image-only pages (scans with TAB staves but no text
    /// layer), built for 1:1 fidelity on engraved scores:
    ///
    ///   1. Segment each staff band into connected ink components. In these
    ///      engravings every fret digit is an isolated blob (staff lines are
    ///      knocked out around digits; slurs/arcs are separate components),
    ///      so segmentation yields exact digit positions.
    ///   2. Filter blobs by digit geometry (size vs staff spacing, ink
    ///      density) — kills arcs, barlines, oversized time-sig numerals.
    ///   3. Classify blobs by compositing them onto a spaced sheet and
    ///      recognizing it with Vision in one pass (solo retry for gaps).
    ///   4. Skip digits flanked by paren blobs — ties, already sounding.
    private static func ocrDigitGlyphs(on page: PDFPage, staves: [TabStaff]) -> [Glyph] {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 4
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, w * h < 60_000_000,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        guard let data = ctx.data else { return [] }
        let pix = data.bindMemory(to: UInt8.self, capacity: w * h)

        struct Blob {
            var minX: Int, maxX: Int, minY: Int, maxY: Int   // image rows/cols
            var count: Int
            var bw: Int { maxX - minX + 1 }
            var bh: Int { maxY - minY + 1 }
            var density: Double { Double(count) / Double(bw * bh) }
        }

        /// Connected components (8-neighbor) of dark pixels within a row band.
        func components(rowLo: Int, rowHi: Int) -> [Blob] {
            let lo = max(0, rowLo), hi = min(h - 1, rowHi)
            guard lo < hi else { return [] }
            var visited = [Bool](repeating: false, count: (hi - lo + 1) * w)
            var blobs: [Blob] = []
            var stack: [Int] = []
            for y in lo...hi {
                for x in 0..<w {
                    let vi = (y - lo) * w + x
                    guard !visited[vi], pix[y * w + x] < 160 else { continue }
                    var blob = Blob(minX: x, maxX: x, minY: y, maxY: y, count: 0)
                    stack.removeAll(keepingCapacity: true)
                    stack.append(vi)
                    visited[vi] = true
                    while let cur = stack.popLast() {
                        let cy = cur / w + lo, cx = cur % w
                        blob.count += 1
                        blob.minX = min(blob.minX, cx); blob.maxX = max(blob.maxX, cx)
                        blob.minY = min(blob.minY, cy); blob.maxY = max(blob.maxY, cy)
                        for dy in -1...1 {
                            for dx in -1...1 where dy != 0 || dx != 0 {
                                let ny = cy + dy, nx = cx + dx
                                guard ny >= lo, ny <= hi, nx >= 0, nx < w else { continue }
                                let nvi = (ny - lo) * w + nx
                                guard !visited[nvi], pix[ny * w + nx] < 160 else { continue }
                                visited[nvi] = true
                                stack.append(nvi)
                            }
                        }
                    }
                    blobs.append(blob)
                }
            }
            return blobs
        }

        // Structural erasure: long horizontal strokes (slur/tie arcs, residual
        // staff line segments) and long vertical strokes (barlines, stems,
        // frame lines) get blanked so digits touching them still segment as
        // isolated components. Digits are at most ~1.45 spacings in either
        // dimension, so these thresholds never bite into digit ink.
        if let minSpacing = staves.map(\.spacing).min() {
            let spx = minSpacing * Double(scale)
            let hRun = Int(spx * 1.6)
            let vRun = Int(spx * 2.2)
            // Vertical first: barlines must still be continuous full-height
            // runs here (horizontal erasure would slice them into digit-sized
            // stubs at every staff-line crossing).
            for x in 0..<w {
                var y = 0
                while y < h {
                    if pix[y * w + x] < 160 {
                        var end = y
                        while end + 1 < h && pix[(end + 1) * w + x] < 160 { end += 1 }
                        if end - y + 1 >= vRun {
                            for yy in y...end { pix[yy * w + x] = 255 }
                        }
                        y = end + 1
                    } else {
                        y += 1
                    }
                }
            }
            for y in 0..<h {
                var x = 0
                while x < w {
                    if pix[y * w + x] < 160 {
                        var end = x
                        while end + 1 < w && pix[y * w + end + 1] < 160 { end += 1 }
                        if end - x + 1 >= hRun {
                            for xx in x...end { pix[y * w + xx] = 255 }
                        }
                        x = end + 1
                    } else {
                        x += 1
                    }
                }
            }
        }

        var totalCandidates = 0
        var totalClassified = 0
        var out: [Glyph] = []

        // ---- Phase A: per-staff segmentation + dense-sheet classification.
        struct StaffData {
            let staff: TabStaff
            let sp: Double
            var digits: [Blob]
            var parens: [Blob]
            var labels: [Character?]
            var reads: [String?]
            var tiedByRead: [Bool]
        }
        var staffData: [StaffData] = []

        for staff in staves {
            let sp = staff.spacing * Double(scale)     // spacing in pixels
            let bandTop = Int((Double(box.maxY) - (staff.top + staff.spacing * 1.0)) * Double(scale))
            let bandBottom = Int((Double(box.maxY) - (staff.bottom - staff.spacing * 1.0)) * Double(scale))
            let all = components(rowLo: bandTop, rowHi: bandBottom)

            var digits: [Blob] = []
            var parens: [Blob] = []
            for b in all {
                let bh = Double(b.bh), bw = Double(b.bw)
                let aspect = bw / max(1, bh)
                // Parens first: tall, thin, sparse curves — must never reach
                // the digit classifier (a ')' template-matches '0').
                // Thin tall blobs: paren, '1', or strum-wave fragment.
                //  • wave fragment: some row has TWO disjoint ink runs
                //    (the squiggle crosses twice) → junk, skip.
                //  • paren: ink is stroke-thin on every row.
                //  • '1': its base serif makes at least one wide ink row.
                if bh > sp * 0.5 && bh < sp * 1.9 && bw <= sp * 0.4 && b.density <= 0.72 {
                    var maxRowInk = 0
                    var multiRunRows = 0
                    for y in b.minY...b.maxY {
                        var c = 0
                        var runs = 0
                        var inRun = false
                        var gap = 0
                        for x in b.minX...b.maxX {
                            if pix[y * w + x] < 160 {
                                c += 1
                                if !inRun && (runs == 0 || gap >= 2) { runs += 1 }
                                inRun = true
                                gap = 0
                            } else {
                                inRun = false
                                gap += 1
                            }
                        }
                        maxRowInk = max(maxRowInk, c)
                        if runs >= 2 { multiRunRows += 1 }
                    }
                    // A wave crosses doubly on most rows; a digit's rare
                    // anti-aliasing break doesn't.
                    if multiRunRows >= max(3, b.bh / 3) { continue }
                    // Stroke-thin on EVERY row = curve, never a digit (even
                    // '1' has a wide serif row): paren if tall, else junk.
                    if Double(maxRowInk) <= sp * 0.16 {
                        if bh > sp * 0.68 { parens.append(b) }
                        continue
                    }
                }
                // Squarish compact blobs are arrowheads, not digits. Solid
                // (dense) up to nearly a full spacing wide; hollow wide
                // glyphs like '0' stay.
                if aspect > 0.78 && aspect < 1.25 && bw < sp * 0.8 { continue }
                if aspect > 0.78 && aspect < 1.25 && bw < sp * 0.95 && b.density > 0.42 { continue }
                if bh > sp * 0.62 && bh < sp * 1.45 && bw > sp * 0.18 && bw < sp * 1.7
                    && b.density > 0.28 && b.count > Int(sp * sp * 0.06) {
                    digits.append(b)
                }
            }
            totalCandidates += digits.count

            var labels = [Character?](repeating: nil, count: digits.count)
            var reads = [String?](repeating: nil, count: digits.count)
            var tiedByRead = [Bool](repeating: false, count: digits.count)

            func mapChar(_ ch: Character) -> Character? {
                ch.isNumber ? ch : (ch == "O" || ch == "o" ? "0" : (ch == "l" || ch == "I" ? "1" : nil))
            }

            // Dense text-like sheet: Vision reads packed rows reliably where
            // it skips isolated glyphs entirely.
            if !digits.isEmpty {
                let sorted = digits.enumerated().sorted { $0.element.minX < $1.element.minX }
                let avgW = max(6, digits.map(\.bw).reduce(0, +) / digits.count)
                let avgH = max(10, digits.map(\.bh).reduce(0, +) / digits.count)
                let gap = max(3, Int(Double(avgW) * 0.55))
                let rowH = avgH * 3
                let maxRowW = 1900
                var layout: [(idx: Int, x: Int, row: Int)] = []
                var cursorX = gap * 2
                var rowIdx = 0
                for (i, b) in sorted {
                    if cursorX + b.bw + gap * 2 > maxRowW { rowIdx += 1; cursorX = gap * 2 }
                    layout.append((i, cursorX, rowIdx))
                    cursorX += b.bw + gap
                }
                let sheetW = maxRowW, sheetH = (rowIdx + 1) * rowH
                var sheet = [UInt8](repeating: 255, count: sheetW * sheetH)
                for item in layout {
                    let b = digits[item.idx]
                    let baseline = item.row * rowH + rowH - avgH / 2
                    let oy = baseline - b.maxY
                    let ox = item.x - b.minX
                    for y in b.minY...b.maxY {
                        for x in b.minX...b.maxX where pix[y * w + x] < 160 {
                            let sy = y + oy, sx = x + ox
                            if sy >= 0, sy < sheetH, sx >= 0, sx < sheetW {
                                sheet[sy * sheetW + sx] = pix[y * w + x]
                            }
                        }
                    }
                }
                sheet.withUnsafeMutableBytes { raw in
                    guard let sctx = CGContext(data: raw.baseAddress, width: sheetW, height: sheetH,
                                               bitsPerComponent: 8, bytesPerRow: sheetW,
                                               space: CGColorSpaceCreateDeviceGray(),
                                               bitmapInfo: CGImageAlphaInfo.none.rawValue),
                          let sheetImage = sctx.makeImage() else { return }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    guard (try? VNImageRequestHandler(cgImage: sheetImage).perform([request])) != nil,
                          let observations = request.results else { return }
                    for obs in observations {
                        guard let cand = obs.topCandidates(1).first else { continue }
                        let bb = obs.boundingBox
                        let rowOfObs = Int((1 - bb.midY) * Double(sheetH)) / rowH
                        let x0 = bb.minX * Double(sheetW)
                        let x1 = bb.maxX * Double(sheetW)
                        let hit = layout.filter {
                            $0.row == rowOfObs
                                && Double($0.x + digits[$0.idx].bw / 2) > x0 - Double(gap)
                                && Double($0.x + digits[$0.idx].bw / 2) < x1 + Double(gap)
                        }.sorted { $0.x < $1.x }
                        // Per-char paren context: only characters inside a
                        // MATCHED "( )" pair are tied — an unclosed stray
                        // paren must not poison the rest of the word.
                        let rawChars = cand.string.filter { $0 != " " }.map { $0 }
                        var tiedIdx = Set<Int>()
                        var openStack: [Int] = []
                        for (k, ch) in rawChars.enumerated() {
                            if ch == "(" { openStack.append(k) }
                            else if ch == ")", let open = openStack.popLast() {
                                for j in (open + 1)..<k { tiedIdx.insert(j) }
                            }
                        }
                        let chars = rawChars.enumerated().map { (ch: $0.element, tied: tiedIdx.contains($0.offset)) }
                        if chars.count == hit.count {
                            for (k, slot) in hit.enumerated() where labels[slot.idx] == nil {
                                labels[slot.idx] = mapChar(chars[k].ch) ?? "?"
                                reads[slot.idx] = String(chars[k].ch)
                                if chars[k].tied { tiedByRead[slot.idx] = true }
                            }
                        } else {
                            let wordW = max(1.0, x1 - x0)
                            for (k, item) in chars.enumerated() {
                                let cx = x0 + (Double(k) + 0.5) * wordW / Double(chars.count)
                                if let slot = hit.min(by: {
                                    abs(Double($0.x + digits[$0.idx].bw / 2) - cx)
                                        < abs(Double($1.x + digits[$1.idx].bw / 2) - cx)
                                }), labels[slot.idx] == nil {
                                    labels[slot.idx] = mapChar(item.ch) ?? "?"
                                    reads[slot.idx] = String(item.ch)
                                    if item.tied { tiedByRead[slot.idx] = true }
                                }
                            }
                        }
                    }
                }
            }
            staffData.append(StaffData(staff: staff, sp: sp, digits: digits,
                                       parens: parens, labels: labels, reads: reads,
                                       tiedByRead: tiedByRead))
        }

        // ---- Phase B: document-level template matching. The engraving
        // repeats identical glyphs, so every confidently-labeled blob on the
        // page trains the classifier for every other staff.
        let tW = 36, tH = 36
        func bitmap(_ b: Blob) -> [Float]? {
            guard b.bw <= tW, b.bh <= tH else { return nil }
            var outB = [Float](repeating: 0, count: tW * tH)
            let ox = (tW - b.bw) / 2 - b.minX
            let oy = (tH - b.bh) / 2 - b.minY
            for y in b.minY...b.maxY {
                for x in b.minX...b.maxX where pix[y * w + x] < 160 {
                    outB[(y + oy) * tW + (x + ox)] = 1
                }
            }
            return outB
        }
        var sums: [Character: [Float]] = [:]
        var counts: [Character: Int] = [:]
        for sd in staffData {
            for (i, b) in sd.digits.enumerated() {
                guard let l = sd.labels[i], l != "?", l.isNumber, let bm = bitmap(b) else { continue }
                if sums[l] == nil { sums[l] = [Float](repeating: 0, count: tW * tH) }
                for k in 0..<(tW * tH) { sums[l]![k] += bm[k] }
                counts[l, default: 0] += 1
            }
        }
        var templates: [Character: [Float]] = [:]
        for (ch, sum) in sums {
            let n = Float(counts[ch] ?? 1)
            templates[ch] = sum.map { $0 / n }
        }
        func score(of bm: [Float], vs t: [Float], bNorm: Float) -> Float {
            var dot: Float = 0
            var tNorm: Float = 0
            for k in 0..<(tW * tH) { dot += bm[k] * t[k]; tNorm += t[k] * t[k] }
            return dot / (bNorm * sqrt(max(1e-6, tNorm)))
        }
        func classify(_ b: Blob) -> (ch: Character, score: Float)? {
            guard let bm = bitmap(b), !templates.isEmpty else { return nil }
            let bNorm = sqrt(bm.reduce(0) { $0 + $1 * $1 })
            guard bNorm > 0 else { return nil }
            var best: (Character, Float)? = nil
            var second: Float = 0
            for (ch, t) in templates {
                var dot: Float = 0
                var tNorm: Float = 0
                for k in 0..<(tW * tH) { dot += bm[k] * t[k]; tNorm += t[k] * t[k] }
                let score = dot / (bNorm * sqrt(max(1e-6, tNorm)))
                if best == nil || score > best!.1 {
                    second = best?.1 ?? 0
                    best = (ch, score)
                } else if score > second {
                    second = score
                }
            }
            guard let b2 = best, b2.1 >= 0.85 || (b2.1 >= 0.78 && b2.1 - second >= 0.04) else { return nil }
            return b2
        }
        for si in staffData.indices {
            for (i, b) in staffData[si].digits.enumerated() {
                if let t = classify(b) {
                    if staffData[si].labels[i] == nil || staffData[si].labels[i] == "?" {
                        staffData[si].labels[i] = t.ch
                    } else if let l = staffData[si].labels[i], l != t.ch, l.isNumber,
                              let bm = bitmap(b), let lt = templates[l] {
                        // Override only when the bitmap clearly prefers the
                        // template class over the Vision-read class.
                        let bNorm = sqrt(bm.reduce(0) { $0 + $1 * $1 })
                        if bNorm > 0, t.score - score(of: bm, vs: lt, bNorm: bNorm) >= 0.08 {
                            staffData[si].labels[i] = t.ch
                        }
                    }
                }
            }
        }

        // Solo Vision as last resort (classes with no template anywhere).
        for si in staffData.indices {
            let sp = staffData[si].sp
            for (i, b) in staffData[si].digits.enumerated()
            where staffData[si].labels[i] == nil || staffData[si].labels[i] == "?" {
                let px = Int(sp * 0.6)
                let cx = max(0, b.minX - px), cw = min(w - 1, b.maxX + px) - cx + 1
                let cy = max(0, b.minY - px), chh = min(h - 1, b.maxY + px) - cy + 1
                guard let crop = ctx.makeImage()?.cropping(to: CGRect(x: cx, y: cy, width: cw, height: chh)) else { continue }
                let up = 3
                guard let bigCtx = CGContext(data: nil, width: cw * up, height: chh * up,
                                             bitsPerComponent: 8, bytesPerRow: cw * up,
                                             space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
                bigCtx.interpolationQuality = .high
                bigCtx.draw(crop, in: CGRect(x: 0, y: 0, width: cw * up, height: chh * up))
                guard let big = bigCtx.makeImage() else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try? VNImageRequestHandler(cgImage: big).perform([request])
                if let str = request.results?.first?.topCandidates(1).first?.string {
                    staffData[si].reads[i] = str
                    if str.contains("("), str.contains(")") { staffData[si].tiedByRead[i] = true }
                    if let ch = str.first(where: { $0.isNumber }) {
                        staffData[si].labels[i] = ch
                    }
                }
            }
        }

        // ---- Phase C: clef exclusion, tie skip, emission.
        for sd in staffData {
            let sp = sd.sp
            let digits = sd.digits
            let parens = sd.parens
            let labels = sd.labels
            let reads = sd.reads

            if ProcessInfo.processInfo.environment["OCR_DEBUG"] != nil {
                for pb in parens {
                    let px = Double(box.origin.x) + Double(pb.minX) / Double(scale)
                    let py = Double(box.maxY) - (Double(pb.minY + pb.maxY) / 2) / Double(scale)
                    print("PAREN x=\(Int(px)) y=\(Int(py)) w=\(pb.bw) h=\(pb.bh) d=\(String(format: "%.2f", pb.density))")
                }
            }
            let clefLetters: Set<String> = ["T", "A", "B", "TA", "AB", "TAB"]
            let clefBlobs = digits.enumerated().filter {
                (reads[$0.offset].map { clefLetters.contains($0.uppercased()) } ?? false)
                    && Double($0.element.minX) < Double(w) * 0.12
            }
            if ProcessInfo.processInfo.environment["OCR_DEBUG"] != nil {
                for (i, b) in digits.enumerated() where Double(b.minX) < Double(w) * 0.15 {
                    print("LEFT top=\(Int(sd.staff.top)) xpx=\(b.minX) w=\(b.bw) h=\(b.bh) label=\(labels[i].map(String.init) ?? "nil") read=\(reads[i] ?? "-")")
                }
            }
            // Two stacked letters is proof; a single letter counts only when
            // it hugs the far-left margin (T often reads as 'I', B gets
            // shape-filtered — one clean 'A' may be all that survives).
            let soloClef = clefBlobs.contains {
                Double($0.element.minX) < Double(w) * 0.09
                    && Double($0.element.bw) >= sp * 0.6   // letter-wide, not an arrow/digit
            }
            let clefMaxX = (clefBlobs.count >= 2 || soloClef)
                ? clefBlobs.map { Double($0.element.maxX) }.max() : nil
            let contentStartX = clefMaxX.map { $0 + sp * 2.4 } ?? -1

            func isTied(_ b: Blob) -> Bool {
                let flankGap = sp * 0.75
                let hasLeft = parens.contains { $0.maxX < b.minX && Double(b.minX - $0.maxX) < flankGap
                    && abs(Double($0.minY + $0.maxY) / 2 - Double(b.minY + b.maxY) / 2) < sp * 0.7 }
                let hasRight = parens.contains { $0.minX > b.maxX && Double($0.minX - b.maxX) < flankGap
                    && abs(Double($0.minY + $0.maxY) / 2 - Double(b.minY + b.maxY) / 2) < sp * 0.7 }
                // One paren suffices: its twin routinely merges into the tie
                // arc or strum arrow and goes undetected.
                return hasLeft || hasRight
            }

            for (i, b) in digits.enumerated() {
                if ProcessInfo.processInfo.environment["OCR_DEBUG"] != nil {
                    let px = Double(box.origin.x) + Double(b.minX) / Double(scale)
                    let py = Double(box.maxY) - (Double(b.minY + b.maxY) / 2) / Double(scale)
                    let status = labels[i] == nil ? "nil" : String(labels[i]!)
                    let dropped = Double(b.minX) < contentStartX ? " CLEF" : (isTied(b) ? " TIED" : "")
                    print("BLOB x=\(Int(px)) y=\(Int(py)) w=\(b.bw) h=\(b.bh) label=\(status)\(dropped)")
                }
                guard let label = labels[i], label != "?" else { continue }
                totalClassified += 1
                guard Double(b.minX) >= contentStartX else { continue }
                guard !isTied(b), !sd.tiedByRead[i] else { continue }
                // Engraved digits are ≤ ~0.6 spacing wide; a wider blob that
                // read as a single character is structure debris (arrowhead).
                if Double(b.bw) > sp * 0.62 {
                    if ProcessInfo.processInfo.environment["OCR_DEBUG"] != nil {
                        let px = Double(box.origin.x) + Double(b.minX) / Double(scale)
                        let py = Double(box.maxY) - (Double(b.minY + b.maxY) / 2) / Double(scale)
                        print("WIDE-DROP x=\(Int(px)) y=\(Int(py)) w=\(b.bw) h=\(b.bh) label=\(label)")
                    }
                    continue
                }
                let gx = Double(box.origin.x) + Double(b.minX) / Double(scale)
                let gw = Double(b.bw) / Double(scale)
                let gh = Double(b.bh) / Double(scale)
                let gcy = Double(box.maxY) - (Double(b.minY + b.maxY) / 2) / Double(scale)
                out.append(Glyph(ch: label, x: gx, cy: gcy, w: gw, h: gh, ocr: true))
            }
        }

        activeOCRStats.add(candidates: totalCandidates, classified: totalClassified)
        return out
    }

    /// Reset per-document OCR stats (call before a document conversion).
    static func resetOCRStats() { activeOCRStats.reset() }

    // MARK: - Note assembly

    private static func notes(for staff: TabStaff, digits: [Glyph]) -> [Note] {
        let spacing = staff.spacing
        var perString: [[Glyph]] = Array(repeating: [], count: staff.lines.count)
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
                var maxGap = 0.0
                var j = i + 1
                while j < gs.count, gs[j].x - lastEnd < spacing * 0.35 {
                    maxGap = max(maxGap, gs[j].x - lastEnd)
                    run.append(gs[j])
                    lastEnd = gs[j].x + gs[j].w
                    j += 1
                }
                let text = String(run.map(\.ch))
                let ocrRun = run.contains { $0.ocr }
                // OCR slot positions are approximate, so only merge into the
                // plausible two-digit range (10-19) when the slots touch;
                // "2 0" pull-off pairs must not become fret 20.
                let mergeOK = run.count == 1 || !ocrRun
                    || ((10...19).contains(Int(text) ?? -1) && maxGap < spacing * 0.3)
                if let fret = Int(text), fret <= 24, mergeOK {
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
        // Overlapping OCR passes can register one digit twice at slightly
        // different x. Real adjacent notes sit a full column apart, so a
        // same-string same-fret pair closer than ~0.7 spacing is one note.
        var deduped: [Note] = []
        for n in out.sorted(by: { $0.x < $1.x }) {
            if let last = deduped.last(where: { $0.string == n.string }),
               last.fret == n.fret, n.x - last.x < spacing * 0.7 { continue }
            deduped.append(n)
        }
        return deduped
    }

    // MARK: - ASCII synthesis

    private static func asciiSystem(_ notes: [Note], spacing: Double,
                                    barXs: [Double] = [],
                                    beatsPerMeasure: Int = 4,
                                    chords: [(name: String, x: Double)] = [],
                                    labels: [String] = ["e", "B", "G", "D", "A", "E"]) -> [String] {
        guard let minX = notes.first?.x else { return [] }
        let scale = spacing * 0.4          // ~3pt per column at standard engraving
        let chordTol = spacing * 0.2
        var rows = labels.map { _ in "" }
        var lengths = [Int](repeating: 0, count: labels.count)

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
                for s in labels.indices {
                    let pad = max(target, lengths[s] + 1)
                    rows[s] += String(repeating: "-", count: max(0, pad - lengths[s])) + "|"
                    lengths[s] = pad + 1
                }
                barCols.append((lengths.max() ?? 1) - 1)
                continue
            }
            let width = ev.notes.map { String($0.fret).count }.max() ?? 1
            var placed = 0
            for s in labels.indices {
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
            let rawBeats = Double(nextOnset - col) / Double(segEnd - segStart) * Double(beatsPerMeasure)
            let letter = RhythmDuration.nearest(toBeats: rawBeats).notation
            for (k, ch) in letter.enumerated() where col + k < rhythm.count {
                rhythm[col + k] = ch
            }
        }

        // If a detected end-frame bar already closed the system, don't
        // append a second close — that mints a one-column sliver measure.
        let endsWithBar = rows.allSatisfy { $0.hasSuffix("|") }
        let labelWidth = labels.map(\.count).max() ?? 0
        let stringRows = labels.indices.map { s in
            labels[s].padding(toLength: labelWidth, withPad: " ", startingAt: 0) + "|-" + rows[s]
                + String(repeating: "-", count: max(0, maxLen - lengths[s]))
                + (endsWithBar ? "" : "-|")
        }

        // Chord-symbol line above the system (parser attaches by column).
        var result: [String] = []
        if !chords.isEmpty {
            var chordRow = [Character](repeating: " ", count: maxLen + 16)
            var nextFree = 0
            for (name, cx) in chords.sorted(by: { $0.x < $1.x }) {
                let target = max(nextFree, max(0, 2 + Int(((cx - minX) / scale).rounded())))
                guard target + name.count < chordRow.count else { break }
                for (k, ch) in name.enumerated() { chordRow[target + k] = ch }
                nextFree = target + name.count + 1
            }
            result.append("   " + String(chordRow))
        }
        result.append("   " + String(rhythm))
        return result + stringRows
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
    /// Placed TAB notes with page positions (same pipeline as asciiTab,
    /// including the OCR fallback) — for overlay verification renders.
    static func debugTabNotes(from doc: PDFDocument) -> [(page: Int, string: Int, fret: Int, x: Double, y: Double)] {
        var out: [(Int, Int, Int, Double, Double)] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p), let raster = Raster(page) else { continue }
            let rows = raster.lineRows(requireContinuous: false)
            let staves = tabStaves(from: rows)
            guard !staves.isEmpty else { continue }
            let fiveLine = staffGroups(from: rows, size: 5).count
            guard fiveLine < staves.count * 3 else { continue }
            var ds = digitGlyphs(on: page)
            if ds.isEmpty { ds = ocrDigitGlyphs(on: page, staves: staves) }
            for staff in staves {
                for n in notes(for: staff, digits: ds) {
                    out.append((p, n.string, n.fret, n.x, staff.lines[n.string]))
                }
            }
        }
        return out
    }

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

        // Pass 1: extract everything so the octave shift is a global decision.
        struct StaffData {
            let pitches: [(midi: Int, x: Double, cy: Double)]
            let chords: [(name: String, x: Double)]
            let bars: [Double]
            let spacing: Double
        }
        var header: [String] = []
        var staffData: [StaffData] = []
        var emittedNotationHeader = false
        var beatsPerMeasure = 4

        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            if p == 0 { header = headerLines(page) }
            guard let raster = Raster(page) else { continue }
            let staves = staffGroups(from: raster.lineRows(requireContinuous: true), size: 5)
                .map { NotationStaff(lines: $0) }
                .sorted { $0.top > $1.top }
            guard !staves.isEmpty else { continue }
            let gs = allGlyphs(on: page)

            for staff in staves {
                let pitches = melody(for: staff, glyphs: gs, raster: raster)
                guard !pitches.isEmpty else { continue }

                if !emittedNotationHeader {
                    emittedNotationHeader = true
                    let extra = notationHeader(staff: staff, glyphs: gs,
                                               firstNoteX: pitches[0].x)
                    header.append(contentsOf: extra)
                    for line in extra where line.hasPrefix("Time: ") {
                        beatsPerMeasure = Int(line.dropFirst(6).prefix(while: \.isNumber)) ?? 4
                    }
                }
                let noteXs = pitches.map(\.x)
                let bars = raster.barXs(topPDF: staff.top, bottomPDF: staff.bottom)
                    .filter { bx in !noteXs.contains { abs($0 + staff.spacing * 0.5 - bx) < staff.spacing * 1.2 } }
                staffData.append(StaffData(pitches: pitches,
                                           chords: chordSymbols(for: staff, glyphs: gs),
                                           bars: bars,
                                           spacing: staff.spacing))
            }
        }
        guard !staffData.isEmpty else { return nil }

        // Global octave shift: center the piece's median pitch near D4 so the
        // tab sits in low positions instead of fret 12+. Whole octaves only,
        // so intervals and contour are untouched.
        let allMidis = staffData.flatMap { $0.pitches.map(\.midi) }.sorted()
        let median = Double(allMidis[allMidis.count / 2])
        let octaveShift = max(-24, min(24, Int(((62 - median) / 12.0).rounded()) * 12))

        var out: [String] = header
        if !out.isEmpty { out.append("") }

        var produced = false
        for sd in staffData {
            // Cluster near-simultaneous noteheads into chord onsets: chord
            // members sit on alternating sides of a shared stem, ~a notehead
            // width apart in x.
            let clusterTol = sd.spacing * 1.7
            var onsets: [(x: Double, midis: [Int])] = []
            for p in sd.pitches.sorted(by: { $0.x < $1.x }) {
                if var last = onsets.last, p.x - last.x < clusterTol {
                    last.midis.append(p.midi)
                    onsets[onsets.count - 1] = last
                } else {
                    onsets.append((p.x, [p.midi]))
                }
            }

            var notes: [Note] = []
            for onset in onsets {
                let shifted = onset.midis.map { $0 + octaveShift }
                // Known-chord shape when a stack coincides with a chord symbol.
                if shifted.count >= 3,
                   let sym = sd.chords.last(where: { $0.x <= onset.x + sd.spacing }),
                   let voicing = ChordShapes.voicing(for: sym.name) {
                    for (string, fret) in voicing.enumerated() {
                        if let fret { notes.append(Note(string: string, fret: fret, x: onset.x)) }
                    }
                    continue
                }
                // Joint assignment: each pitch on its own string, high to low.
                var used = Set<Int>()
                for m in shifted.sorted(by: >) {
                    var best: (string: Int, fret: Int)? = nil
                    outer: for candidate in [m, m + 12, m - 12, m + 24] {
                        for st in tuning.indices where !used.contains(st) {
                            let fret = candidate - tuning[st]
                            guard fret >= 0, fret <= 15 else { continue }
                            if best == nil || fret < best!.fret { best = (st, fret) }
                        }
                        if best != nil { break outer }
                    }
                    if let b = best {
                        used.insert(b.string)
                        notes.append(Note(string: b.string, fret: b.fret, x: onset.x))
                    }
                }
            }
            guard !notes.isEmpty else { continue }
            produced = true
            out.append(contentsOf: asciiSystem(notes, spacing: sd.spacing * 1.25,
                                               barXs: sd.bars,
                                               beatsPerMeasure: beatsPerMeasure,
                                               chords: sd.chords))
            out.append("")
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
            guard ch.isNumber || ch.isLetter || noteheadChars.contains(ch)
                || "#b¨‹ŒŠ„/()°ø∆.©∏∑".contains(ch) else { continue }
            guard let sel = page.selection(for: NSRange(location: i, length: 1)) else { continue }
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0 else { continue }
            out.append(Glyph(ch: ch, x: b.origin.x, cy: b.origin.y + b.height / 2,
                             w: b.width, h: b.height))
        }
        return out
    }

    /// Key + time signature header lines for the first notated staff, in the
    /// directive format TabParser reads ("Key: A", "Time: 4/4").
    private static func notationHeader(staff: NotationStaff, glyphs: [Glyph],
                                       firstNoteX: Double) -> [String] {
        let spacing = staff.spacing
        var out: [String] = []

        // Key signature accidentals ('#'/'b') left of the first notehead.
        var flats = 0, sharps = 0
        for g in glyphs where g.x < firstNoteX && g.x > firstNoteX - 120 {
            guard g.cy < staff.top + spacing * 2, g.cy > staff.bottom - spacing * 2 else { continue }
            if g.ch == "b" { flats += 1 }
            if g.ch == "#" { sharps += 1 }
        }
        let fifths = sharps > 0 ? min(sharps, 7) : -min(flats, 7)
        if fifths != 0 {
            let sharpNames = ["C", "G", "D", "A", "E", "B", "F#", "C#"]
            let flatNames = ["C", "F", "Bb", "Eb", "Ab", "Db", "Gb", "Cb"]
            out.append("Key: " + (fifths > 0 ? sharpNames[fifths] : flatNames[-fifths]))
        }

        // Time signature: a vertically stacked digit pair before the first note.
        let sigDigits = glyphs.filter {
            $0.ch.isNumber && $0.x < firstNoteX && $0.x > firstNoteX - 80
                && $0.cy < staff.top + spacing && $0.cy > staff.bottom - spacing
        }
        for top in sigDigits {
            for bottom in sigDigits {
                guard abs(top.x - bottom.x) < 3, top.cy > bottom.cy + spacing else { continue }
                if let n = Int(String(top.ch)), let d = Int(String(bottom.ch)),
                   n >= 2, n <= 12, [2, 4, 8, 16].contains(d) {
                    out.append("Time: \(n)/\(d)")
                    return out
                }
            }
        }
        return out
    }

    /// Chord-symbol tokens above a staff: glyph runs grouped by x-gap, with
    /// the engraving font's ligature glyphs normalized (¨→b, ‹→m, Œ„Š→maj).
    private static func chordSymbols(for staff: NotationStaff, glyphs: [Glyph]) -> [(name: String, x: Double)] {
        let spacing = staff.spacing
        var band = glyphs.filter {
            !noteheadChars.contains($0.ch)
                && $0.cy > staff.top + spacing * 0.5 && $0.cy < staff.top + spacing * 9
        }
        band.sort { $0.x < $1.x }
        guard !band.isEmpty else { return [] }

        let subs: [Character: String] = ["¨": "b", "‹": "m", "Œ": "m", "„": "a", "Š": "j",
                                         "°": "dim", "ø": "m7b5", "∆": "maj",
                                         // second engraving font: © = sharp, ∏ = flat, ∑ = natural
                                         "©": "#", "∏": "b", "∑": ""]
        var out: [(String, Double)] = []
        var token = ""
        var tokenX = band[0].x
        var lastEnd = band[0].x

        func flush() {
            if !token.isEmpty, let first = token.first, ("A"..."G").contains(String(first)),
               TabParser.isChordSymbolLine(token) {
                out.append((token, tokenX))
            }
            token = ""
        }

        for g in band {
            if g.x - lastEnd > 7 { flush(); tokenX = g.x }
            if token.isEmpty { tokenX = g.x }
            token += subs[g.ch] ?? String(g.ch)
            lastEnd = g.x + g.w
        }
        flush()
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

    // MARK: - Chord shapes

    /// Standard movable guitar voicings for named chords. Used when a
    /// lead-sheet chord stack coincides with a chord symbol — a guitarist
    /// plays the shape, not the piano voicing.
    enum ChordShapes {
        /// Absolute frets high-E-first (nil = muted), or nil when the chord
        /// name isn't recognized.
        static func voicing(for name: String) -> [Int?]? {
            var rest = name
            // root
            guard let first = rest.first, ("A"..."G").contains(String(first)) else { return nil }
            let steps: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
            var pc = steps[first]!
            rest.removeFirst()
            if rest.first == "#" { pc = (pc + 1) % 12; rest.removeFirst() }
            else if rest.first == "b" { pc = (pc + 11) % 12; rest.removeFirst() }
            // slash bass: shape from the main chord
            if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
            let q = rest.lowercased()

            enum Quality { case maj, min, dom7, min7, maj7, sus4 }
            let quality: Quality
            if q.contains("maj") { quality = q.contains(where: \.isNumber) ? .maj7 : .maj }
            else if q.contains("sus") { quality = .sus4 }
            else if q.contains("dim") || q.contains("°") || q.contains("ø") || q.contains("m7b5") { quality = .min7 }
            else if q.hasPrefix("m") { quality = q.contains(where: \.isNumber) ? .min7 : .min }
            else if q.contains(where: \.isNumber) || q.contains("alt") { quality = .dom7 }
            else { quality = .maj }

            // Root fret on the 6th (E) or 5th (A) string; prefer the lower.
            let fE = (pc - 4 + 12) % 12
            let fA = (pc - 9 + 12) % 12
            let useE = fE <= fA

            // Shapes low→high relative to the barre fret.
            let eForm: [Quality: [Int?]] = [
                .maj:  [0, 2, 2, 1, 0, 0],
                .min:  [0, 2, 2, 0, 0, 0],
                .dom7: [0, 2, 0, 1, 0, 0],
                .min7: [0, 2, 0, 0, 0, 0],
                .maj7: [0, 2, 1, 1, 0, 0],
                .sus4: [0, 2, 2, 2, 0, 0],
            ]
            let aForm: [Quality: [Int?]] = [
                .maj:  [nil, 0, 2, 2, 2, 0],
                .min:  [nil, 0, 2, 2, 1, 0],
                .dom7: [nil, 0, 2, 0, 2, 0],
                .min7: [nil, 0, 2, 0, 1, 0],
                .maj7: [nil, 0, 2, 1, 2, 0],
                .sus4: [nil, 0, 2, 2, 3, 0],
            ]
            let base = useE ? fE : fA
            guard let shape = (useE ? eForm : aForm)[quality] else { return nil }
            // low→high with barre offset → high-E-first
            return shape.map { $0.map { $0 + base } }.reversed()
        }
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
