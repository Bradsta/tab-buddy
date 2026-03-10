//
//  TabParser.swift
//  TabBuddy
//
//  Rule-based parser for ASCII guitar tablature.
//  Extracts measure boundaries, note positions, timing metadata, and fret numbers.
//  Serves as ground truth labeler for ML training and as runtime fallback.
//

import Foundation

struct TabParser {

    // MARK: - Public API

    /// Parse raw text tab content into a structured MeasureMap.
    static func parse(_ text: String) -> MeasureMap {
        // Normalize line endings: \r\n → \n, stray \r → \n
        // (components(separatedBy: .newlines) splits \r and \n individually,
        //  inserting blanks between every line for \r\n files)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let metadata = parseMetadata(lines: lines)
        let systemGroups = detectSystems(lines: lines)

        var globalMeasureNumber = 1
        var systems: [MeasureSystem] = []

        for group in systemGroups {
            let (system, nextMeasure) = parseSystem(
                lines: lines,
                group: group,
                startMeasureNumber: globalMeasureNumber,
                metadata: metadata
            )
            if !system.measures.isEmpty {
                systems.append(system)
                globalMeasureNumber = nextMeasure
            }
        }

        return MeasureMap(
            bpm: metadata.bpm,
            timeSignature: metadata.timeSignature,
            key: metadata.key,
            tuning: metadata.tuning,
            systems: systems
        )
    }

    // MARK: - Metadata Parsing

    /// Extract tempo, time signature, key, and tuning from header lines.
    private static func parseMetadata(lines: [String]) -> TabMetadata {
        var meta = TabMetadata()

        // Only scan the first ~30 lines (headers appear before tab content)
        let headerLines = lines.prefix(30)

        for line in headerLines {
            let lower = line.lowercased()

            // Time signature: "time: 3/4", "time: 6/8", "(4/4)", "(3/4)"
            if meta.timeSignature == nil {
                if let timeSig = extractTimeSignature(lower) {
                    meta.timeSignature = timeSig
                }
            }

            // BPM: "tempo: 120 bpm", "tempo: 56", "♩ = 66", "q = 103"
            if meta.bpm == nil {
                if let bpm = extractBPM(line) {
                    meta.bpm = bpm
                }
            }

            // Tuning
            if meta.tuning == nil && lower.contains("tuning") {
                if lower.contains("standard") {
                    meta.tuning = "EADGBE"
                } else {
                    // Find the colon specifically after "tuning"
                    if let tuningRange = lower.range(of: "tuning"),
                       let colonIdx = line[tuningRange.upperBound...].firstIndex(of: ":") {
                        let after = String(line[line.index(after: colonIdx)...])
                            .trimmingCharacters(in: .whitespaces)
                        // Take only up to the next keyword (key:, time:, tempo:)
                        let tuningStr = extractField(from: after)
                        if tuningStr.count >= 4 {
                            meta.tuning = tuningStr
                        }
                    } else if lower.range(of: #"tuning\s*[-–]\s*"#, options: .regularExpression) != nil {
                        // "tuning - E A D G B E" format
                        if let dashRange = lower.range(of: #"[-–]\s*"#, options: .regularExpression) {
                            let after = String(line[dashRange.upperBound...])
                                .trimmingCharacters(in: .whitespaces)
                            let tuningStr = extractField(from: after)
                            if tuningStr.count >= 4 {
                                meta.tuning = tuningStr
                            }
                        }
                    }
                }
            }

            // Key: "key: A minor", "Key: C major"
            if meta.key == nil {
                // Find "key:" specifically (not just any colon on a line containing "key")
                if let keyRange = lower.range(of: #"keys?\s*:"#, options: .regularExpression) {
                    let afterColon = line[keyRange.upperBound...]
                        .trimmingCharacters(in: .whitespaces)
                    let keyStr = extractField(from: String(afterColon))
                    if !keyStr.isEmpty {
                        meta.key = keyStr.lowercased()
                    }
                }
            }
        }

        return meta
    }

    /// Extract time signature from a line. Returns (beats, noteValue) or nil.
    private static func extractTimeSignature(_ line: String) -> (Int, Int)? {
        // Look for patterns like "3/4", "6/8", "4/4"
        guard let match = line.range(of: #"\d+\s*/\s*\d+"#, options: .regularExpression) else {
            // Also check "Common Time (4/4)" or "Time Signature: Common Time"
            if line.lowercased().contains("common time") { return (4, 4) }
            return nil
        }

        let sub = String(line[match])
        let parts = sub.components(separatedBy: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        // Denominator must be a power of 2 (1, 2, 4, 8, 16) — rejects false hits like 12/13, 5/2 URLs
        let validDenoms: Set<Int> = [1, 2, 4, 8, 16]
        guard parts.count == 2, parts[0] > 0, parts[0] <= 12,
              validDenoms.contains(parts[1]) else { return nil }

        // Only accept if preceded by "time" or "(" or tempo notation or at/near line start
        let before = String(line[line.startIndex..<match.lowerBound]).lowercased()
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)

        // Accept if:
        let hasTimePrefix = before.contains("time")       // "time: 3/4"
        let hasParenPrefix = trimmedBefore.hasSuffix("(")  // "(4/4)"
        let atLineStart = trimmedBefore.isEmpty            // "4/4" at start
        let afterTempoNotation = trimmedBefore.range(of: #"[qehsw♩♪]\s*=\s*\d+\s*$"#, options: .regularExpression) != nil  // "Q=60  4/4"
        let isSignature = before.contains("signature")     // "Time Signature: ..."

        if hasTimePrefix || hasParenPrefix || atLineStart || afterTempoNotation || isSignature {
            return (parts[0], parts[1])
        }

        return nil
    }

    /// Extract BPM from a line. Handles various formats.
    private static func extractBPM(_ line: String) -> Double? {
        let lower = line.lowercased()

        // "tempo: 120 bpm" or "tempo: 56"
        if let range = lower.range(of: #"tempo\s*[:=]\s*\d+"#, options: .regularExpression) {
            return extractFirstNumber(from: String(lower[range]))
        }

        // "♩ = 66", "q = 103", "Q=60" (note value = BPM)
        if let range = lower.range(of: #"[♩♪qehsw]\s*=\s*\d+"#, options: .regularExpression) {
            return extractFirstNumber(from: String(lower[range]))
        }

        // "E = 140 bpm" — letter followed by = number AND "bpm" somewhere on the line
        if lower.contains("bpm") {
            if let range = lower.range(of: #"[a-z]\s*=\s*\d+"#, options: .regularExpression) {
                if let num = extractFirstNumber(from: String(lower[range])), num >= 30, num <= 300 {
                    return num
                }
            }
            // "115bpm", "100bpm", "60bpm", "80 BPM" — number before "bpm"
            if let range = lower.range(of: #"\d+\s*bpm"#, options: .regularExpression) {
                if let num = extractFirstNumber(from: String(lower[range])), num >= 30, num <= 300 {
                    return num
                }
            }
        }

        // "BPM: 120" or "BPM: Lento (45-55)" — extract first number or range
        if lower.range(of: #"bpm\s*:"#, options: .regularExpression) != nil {
            // Try to find a parenthesized range like "(45-55)"
            if let rangeMatch = lower.range(of: #"\(\d+\s*[-–]\s*\d+\)"#, options: .regularExpression) {
                let rangeStr = String(lower[rangeMatch])
                let numbers = rangeStr.components(separatedBy: .decimalDigits.inverted)
                    .compactMap { Double($0) }
                if numbers.count >= 2 {
                    return (numbers[0] + numbers[1]) / 2.0 // midpoint
                }
            }
            // Try direct number
            if let num = extractFirstNumber(from: lower), num >= 30, num <= 300 {
                return num
            }
        }

        // "suggested tempo around 120"
        if lower.contains("tempo") {
            if let num = extractFirstNumber(from: lower), num >= 30, num <= 300 {
                return num
            }
        }

        return nil
    }

    /// Extract the first integer from a string and return as Double.
    private static func extractFirstNumber(from text: String) -> Double? {
        var numStr = ""
        var found = false
        for ch in text {
            if ch.isNumber {
                numStr += String(ch)
                found = true
            } else if found {
                break
            }
        }
        guard let num = Double(numStr) else { return nil }
        return num
    }

    /// Extract a field value up to the next keyword separator (key:, time:, tempo:, etc.)
    private static func extractField(from text: String) -> String {
        // Split on common field separators
        let separators = ["key:", "time:", "tempo:", "tuning:", "capo:"]
        var result = text
        for sep in separators {
            if let range = result.lowercased().range(of: sep) {
                result = String(result[result.startIndex..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - System Detection

    /// A group of consecutive line indices that form one tab system.
    private struct SystemGroup {
        var lineIndices: [Int]          // all lines in the group (tab + context)
        var tabLineIndices: [Int]       // just the tab string lines
        var beatRulerIndex: Int?        // index of beat ruler line if present
        var rhythmLineIndex: Int?       // index of rhythm notation line if present
        var measureNumberLineIndex: Int? // index of line with leading measure number
    }

    /// Detect tab string lines and group them into systems.
    private static func detectSystems(lines: [String]) -> [SystemGroup] {
        var groups: [SystemGroup] = []
        var currentTabLines: [Int] = []
        var contextAbove: [Int] = []

        for (i, line) in lines.enumerated() {
            if isTabLine(line) {
                if currentTabLines.isEmpty {
                    // Capture up to 3 lines above as context (beat ruler, rhythm, etc.)
                    let start = max(0, i - 3)
                    contextAbove = Array(start..<i)
                }
                currentTabLines.append(i)
            } else if !currentTabLines.isEmpty {
                // End of a tab system — flush
                let group = buildSystemGroup(
                    tabLineIndices: currentTabLines,
                    contextAbove: contextAbove,
                    lines: lines
                )
                groups.append(group)
                currentTabLines = []
                contextAbove = []
            }
        }

        // Flush final group
        if !currentTabLines.isEmpty {
            let group = buildSystemGroup(
                tabLineIndices: currentTabLines,
                contextAbove: contextAbove,
                lines: lines
            )
            groups.append(group)
        }

        return groups
    }

    /// Check if a line is a tab string line.
    /// Handles: "e|--0--|", "E||--3--|", "e:--0--|", "||--3-2-0--|", "--3-2-0--|",
    ///          "e-6--6--8---", "E 4-------2---|", "d#|---", "E*--7---|"
    private static func isTabLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }

        // 1. Labeled with | or || separator: "e|", "E||", "B|", "d#|", "A#|"
        if trimmed.range(of: #"^[eEBbGgDdAaCcFf][#b]?\s*\|"#, options: .regularExpression) != nil {
            return true
        }

        // 2. Labeled with : separator: "e:", "G:"
        if trimmed.range(of: #"^[eEBbGgDdAaCcFf][#b]?\s*:"#, options: .regularExpression) != nil {
            // Verify it's tab content (dashes, numbers, special chars after separator)
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let after = trimmed[trimmed.index(after: colonIdx)...]
                let tabChars = after.filter { "-0123456789hpbr/\\~()xXsS.*|".contains($0) }
                return tabChars.count > after.count / 2
            }
        }

        // 3. Unlabeled: starts with || or ||o (repeat markers)
        if trimmed.hasPrefix("||") {
            let afterBars = trimmed.dropFirst(2)
            // Must have tab-like content (dashes, numbers, bars)
            if afterBars.hasPrefix("o") || afterBars.hasPrefix("-") || afterBars.first?.isNumber == true {
                return true
            }
        }

        // 4. Unlabeled continuation: starts with |- or |-- (tab content, no label)
        if trimmed.hasPrefix("|") && !trimmed.hasPrefix("||") {
            let afterBar = trimmed.dropFirst(1)
            if afterBar.hasPrefix("-") || afterBar.first?.isNumber == true {
                // Verify it's tab content, not a table or ruler
                let dashCount = trimmed.filter({ $0 == "-" }).count
                return dashCount > trimmed.count / 3
            }
        }

        // 5. Fully unlabeled: starts with dashes/numbers and contains | separators
        //    e.g. "--0--------2--L--3-------|--3---..."
        if (trimmed.first == "-" || trimmed.first?.isNumber == true) && trimmed.contains("|") {
            let dashCount = trimmed.filter({ $0 == "-" }).count
            let barCount = trimmed.filter({ $0 == "|" }).count
            // Must look like tab: many dashes, some bars, short non-dash content
            return dashCount > trimmed.count / 3 && barCount >= 1
        }

        // 6. Label followed directly by dash content (no separator)
        //    e.g. "e-6--6--8---", "E-----------", "E 4-------2---|",
        //         "E*--7---|", "d#-0---" (sharp labels)
        if trimmed.range(of: #"^[eEBbGgDdAaCcFf][#b*]?\s*[-0-9]"#, options: .regularExpression) != nil {
            let dashCount = trimmed.filter({ $0 == "-" }).count
            if dashCount > trimmed.count / 3 {
                return true
            }
        }

        return false
    }

    /// Build a SystemGroup from detected tab lines and their context.
    private static func buildSystemGroup(
        tabLineIndices: [Int],
        contextAbove: [Int],
        lines: [String]
    ) -> SystemGroup {
        var group = SystemGroup(
            lineIndices: contextAbove + tabLineIndices,
            tabLineIndices: tabLineIndices
        )

        // Check context lines above for beat ruler or rhythm notation
        for idx in contextAbove {
            let line = lines[idx]
            if isBeatRulerLine(line) {
                group.beatRulerIndex = idx
                // Beat ruler often has a leading measure number
                group.measureNumberLineIndex = idx
            } else if isRhythmNotationLine(line) {
                group.rhythmLineIndex = idx
            }
        }

        return group
    }

    /// Check if a line is a beat ruler (e.g. "1  |  .  .  |  .  .")
    private static func isBeatRulerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Must contain | and . (dots between bars indicate beats)
        let hasBars = trimmed.contains("|")
        let hasDots = trimmed.contains(".")
        // Must not look like a tab line
        let isTab = isTabLine(line)
        return hasBars && hasDots && !isTab && trimmed.count > 3
    }

    /// Check if a line is rhythm notation (e.g. "E  E  Q    Q       H.")
    private static func isRhythmNotationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, !isTabLine(line) else { return false }

        // Count rhythm tokens: E, Q, H, S, W (with optional . suffix)
        let tokens = trimmed.split(separator: " ").map(String.init)
        let rhythmTokens = tokens.filter { token in
            RhythmDuration.from(notation: token) != nil
        }

        // At least 2 rhythm tokens and they make up a significant portion
        return rhythmTokens.count >= 2 && Double(rhythmTokens.count) / Double(max(tokens.count, 1)) > 0.3
    }

    // MARK: - System Parsing

    /// Parse a single system into measures with note events.
    private static func parseSystem(
        lines: [String],
        group: SystemGroup,
        startMeasureNumber: Int,
        metadata: TabMetadata
    ) -> (MeasureSystem, Int) {

        guard let firstTabIdx = group.tabLineIndices.first,
              let lastTabIdx = group.tabLineIndices.last
        else {
            return (MeasureSystem(rect: .zero, lineRange: 0..<0, measures: []), startMeasureNumber)
        }

        let firstLine = lines[firstTabIdx]

        // Find bar line positions from the first tab line
        let barPositions = findBarPositions(in: firstLine)

        // Parse leading measure number from beat ruler or first tab line
        var leadingMeasureNumber: Int?
        if let rulerIdx = group.beatRulerIndex {
            leadingMeasureNumber = parseLeadingNumber(lines[rulerIdx])
        }
        if leadingMeasureNumber == nil {
            // Check if there's a number right before the first tab line
            if firstTabIdx > 0 {
                let prevLine = lines[firstTabIdx - 1].trimmingCharacters(in: .whitespaces)
                if let num = Int(prevLine), num > 0, num < 10000 {
                    leadingMeasureNumber = num
                }
            }
        }

        let currentMeasureStart = leadingMeasureNumber ?? startMeasureNumber

        // Parse beat ruler for per-measure beat counts
        var beatCountsPerMeasure: [Int]?
        if let rulerIdx = group.beatRulerIndex {
            beatCountsPerMeasure = parseBeatCounts(
                ruler: lines[rulerIdx],
                barPositions: barPositions
            )
        }

        // Parse rhythm notation for note durations
        var rhythmEvents: [(column: Int, duration: RhythmDuration)]?
        if let rhythmIdx = group.rhythmLineIndex {
            rhythmEvents = parseRhythmLine(lines[rhythmIdx])
        }

        // Build measures from bar positions
        let defaultBeats = metadata.timeSignature?.beats ?? 4
        var measures: [Measure] = []

        let measureRanges = barPositionsToRanges(barPositions, lineLength: firstLine.count)

        for (i, range) in measureRanges.enumerated() {
            let measureNum = currentMeasureStart + i
            let beats = beatCountsPerMeasure?[safe: i] ?? defaultBeats

            // Extract notes (fret numbers) from tab lines within this measure's column range
            let notes = extractNotes(
                tabLineIndices: group.tabLineIndices,
                lines: lines,
                columnRange: range,
                measureColumnRange: range,
                rhythmEvents: rhythmEvents,
                beatsInMeasure: beats
            )

            measures.append(Measure(
                rect: .zero, // Will be computed during rendering
                measureNumber: measureNum,
                beatCount: beats,
                notes: notes.isEmpty ? nil : notes,
                columnRange: range
            ))
        }

        // If no bar lines found, treat entire line as one measure
        if measures.isEmpty && !group.tabLineIndices.isEmpty {
            let tabContent = lines[firstTabIdx]
            // Determine where tab content starts by detecting label format
            let trimmedContent = tabContent.trimmingCharacters(in: .whitespaces)
            let isColonLabel = trimmedContent.range(of: #"^[eEBbGgDdAaCcFf][#b]?\s*:"#, options: .regularExpression) != nil
            let isLabelDash = !isColonLabel &&
                trimmedContent.range(of: #"^[eEBbGgDdAaCcFf][#b*]?\s*[-0-9]"#, options: .regularExpression) != nil

            let contentStart: Int
            if isColonLabel {
                let separatorIdx = tabContent.firstIndex(of: ":") ?? tabContent.firstIndex(of: "|")
                contentStart = separatorIdx
                    .map { tabContent.distance(from: tabContent.startIndex, to: $0) + 1 } ?? 0
            } else if isLabelDash {
                // Skip label character(s) + optional #/b/* + optional spaces
                if let match = tabContent.range(of: #"^(\s*[eEBbGgDdAaCcFf][#b*]?\s*)"#, options: .regularExpression) {
                    contentStart = tabContent.distance(from: tabContent.startIndex, to: match.upperBound)
                } else {
                    contentStart = 1 // skip at least the label character
                }
            } else {
                let separatorIdx = tabContent.firstIndex(of: "|") ?? tabContent.firstIndex(of: ":")
                contentStart = separatorIdx
                    .map { tabContent.distance(from: tabContent.startIndex, to: $0) + 1 } ?? 0
            }
            var range = contentStart..<tabContent.count

            let notes = extractNotes(
                tabLineIndices: group.tabLineIndices,
                lines: lines,
                columnRange: range,
                measureColumnRange: range,
                rhythmEvents: rhythmEvents,
                beatsInMeasure: defaultBeats
            )

            // Estimate beat count from content rather than fixed default
            let estimatedBeats = estimateBeats(
                notes: notes,
                rhythmEvents: rhythmEvents,
                columnRange: range,
                defaultBeats: defaultBeats
            )

            // Trim column range to last note + padding to avoid sweeping over trailing empty dashes
            var trimmedNotes = notes
            if let lastNote = notes.last, let lastCol = lastNote.column {
                let padding = max(4, range.count / 20) // ~5% padding
                let trimmedEnd = min(range.upperBound, lastCol + padding + 1)
                if trimmedEnd < range.upperBound - 4 { // only trim if meaningful
                    range = range.lowerBound..<trimmedEnd
                    // Recompute positionInMeasure relative to trimmed range
                    trimmedNotes = recomputeNotePositions(notes, in: range)
                }
            }

            measures.append(Measure(
                rect: .zero,
                measureNumber: currentMeasureStart,
                beatCount: estimatedBeats,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                columnRange: range
            ))
        }

        // For single-measure systems from bar lines (start+end bars only, no internal bars),
        // also trim trailing empty space and estimate beats
        if measures.count == 1, measureRanges.count == 1 {
            var m = measures[0]
            if let notes = m.notes, !notes.isEmpty, let colRange = m.columnRange {
                // Estimate beats from note density
                let estimatedBeats = estimateBeats(
                    notes: notes,
                    rhythmEvents: rhythmEvents,
                    columnRange: colRange,
                    defaultBeats: m.beatCount
                )
                m.beatCount = estimatedBeats

                // Trim trailing empty space
                if let lastNote = notes.last, let lastCol = lastNote.column {
                    let padding = max(4, colRange.count / 20)
                    let trimmedEnd = min(colRange.upperBound, lastCol + padding + 1)
                    if trimmedEnd < colRange.upperBound - 4 {
                        m.columnRange = colRange.lowerBound..<trimmedEnd
                        // Recompute positionInMeasure relative to trimmed range
                        m.notes = recomputeNotePositions(notes, in: m.columnRange!)
                    }
                }
                measures[0] = m
            }
        }

        // Use tab-only line range (not context lines above) for accurate highlight positioning
        let lineRange = firstTabIdx..<(lastTabIdx + 1)
        let system = MeasureSystem(
            rect: .zero, // Will be computed during rendering
            lineRange: lineRange,
            measures: measures
        )

        let nextMeasure = currentMeasureStart + measures.count
        return (system, nextMeasure)
    }

    // MARK: - Bar Line Detection

    /// Find column positions of bar lines (|) in a tab line.
    /// Handles double bar lines (||) for repeats, : separator, and label-dash format.
    private static func findBarPositions(in line: String) -> [Int] {
        var positions: [Int] = []
        let chars = Array(line)

        // Detect colon-separated label (e.g., "e:--0--3--|") — must check BEFORE |
        // because these lines may also contain | as internal bar lines or trailing decoration
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isColonLabel = trimmed.range(of: #"^[eEBbGgDdAaCcFf][#b]?\s*:"#, options: .regularExpression) != nil

        // Detect label-dash format: "E-6--6---|", "E 4---|", "d#-0---|"
        // Label directly followed by dash content, no | or : separator immediately after label
        let isLabelDash = !isColonLabel &&
            trimmed.range(of: #"^[eEBbGgDdAaCcFf][#b*]?\s*[-0-9]"#, options: .regularExpression) != nil &&
            trimmed.range(of: #"^[eEBbGgDdAaCcFf][#b]?\s*\|"#, options: .regularExpression) == nil

        if isColonLabel {
            // Colon is the label separator; content starts after :
            guard let colonIdx = line.firstIndex(of: ":") else { return positions }
            let colonPos = line.distance(from: line.startIndex, to: colonIdx)
            positions.append(colonPos) // treat : position as a bar

            var i = colonPos + 1
            while i < chars.count {
                if chars[i] == "|" {
                    positions.append(i)
                    while i + 1 < chars.count && chars[i + 1] == "|" { i += 1 }
                }
                i += 1
            }
            // Add end position if the line ends without a final |
            if let last = positions.last, last < chars.count - 1 {
                positions.append(chars.count)
            }
        } else if isLabelDash {
            // Label-dash: content starts right after the label character(s)
            // Find where the label ends (letter + optional #/b/* + optional spaces)
            var contentStart = 0
            if let match = line.range(of: #"^(\s*[eEBbGgDdAaCcFf][#b*]?\s*)"#, options: .regularExpression) {
                contentStart = line.distance(from: line.startIndex, to: match.upperBound)
            }

            // Place a virtual bar at content start
            // (subtract 1 so that contentStart+1 = first content column, matching barPositionsToRanges logic)
            positions.append(max(0, contentStart - 1))

            // Scan for internal | bar lines
            var i = contentStart
            while i < chars.count {
                if chars[i] == "|" {
                    positions.append(i)
                    while i + 1 < chars.count && (chars[i + 1] == "|" || chars[i + 1] == "o" || chars[i + 1] == "*") {
                        i += 1
                    }
                }
                i += 1
            }

            // Add end position if the line ends without a final |
            if let last = positions.last, last < chars.count - 1 {
                positions.append(chars.count)
            }
        } else {
            // Standard | separator — find the first | as content start
            var firstBarPos: Int? = nil
            for (i, ch) in chars.enumerated() {
                if ch == "|" {
                    firstBarPos = i
                    break
                }
            }

            // If line starts with tab content (dashes/numbers) before the first |,
            // insert a virtual bar at the start so the pre-bar content becomes a measure.
            // Without this, unlabeled continuation lines like "---0---|---3---|"
            // would skip everything before the first |.
            if let fbp = firstBarPos, fbp > 0 {
                let firstNonSpace = chars.firstIndex(where: { $0 != " " && $0 != "\t" }) ?? 0
                let firstContentChar = chars[firstNonSpace]
                if firstContentChar == "-" || firstContentChar.isNumber ||
                   "hpbr/\\~()xXsS.".contains(firstContentChar) {
                    positions.append(max(0, firstNonSpace - 1))
                }
            }

            var i = firstBarPos ?? 0
            while i < chars.count {
                if chars[i] == "|" {
                    positions.append(i)
                    // Skip consecutive | for double bars and repeat markers (||, ||o)
                    while i + 1 < chars.count && (chars[i + 1] == "|" || chars[i + 1] == "o" || chars[i + 1] == "*") {
                        i += 1
                    }
                }
                i += 1
            }

            // Add end position if the line ends without a final |
            if let last = positions.last, last < chars.count - 1 {
                positions.append(chars.count)
            }
        }

        return positions
    }

    /// Convert bar positions to column ranges for each measure.
    private static func barPositionsToRanges(_ positions: [Int], lineLength: Int) -> [Range<Int>] {
        guard positions.count >= 2 else {
            // Not enough bar lines to form measures
            return []
        }

        var ranges: [Range<Int>] = []
        for j in 0..<(positions.count - 1) {
            let start = positions[j] + 1  // skip the bar line character
            let end = positions[j + 1]
            if end > start {
                ranges.append(start..<end)
            }
        }
        return ranges
    }

    // MARK: - Beat Ruler Parsing

    /// Parse a beat ruler line to get beat counts per measure.
    /// E.g. "1  |  .  .  |  .  .  |  .  .  |  .  ." → [2, 2, 2, 2] (6/8 = 2 groups of 3)
    private static func parseBeatCounts(ruler: String, barPositions: [Int]) -> [Int] {
        let chars = Array(ruler)
        var counts: [Int] = []

        let ranges = barPositionsToRanges(barPositions, lineLength: ruler.count)
        for range in ranges {
            var dotCount = 0
            for col in range where col < chars.count {
                if chars[col] == "." {
                    dotCount += 1
                }
            }
            // Dots represent beats within the measure
            counts.append(max(dotCount, 1))
        }

        return counts
    }

    // MARK: - Rhythm Notation Parsing

    /// Parse a rhythm notation line into positioned duration events.
    /// E.g. "     E  E  Q    Q       H." → [(5, .eighth), (8, .eighth), (11, .quarter), ...]
    private static func parseRhythmLine(_ line: String) -> [(column: Int, duration: RhythmDuration)] {
        var events: [(column: Int, duration: RhythmDuration)] = []
        let chars = Array(line)
        var i = 0

        while i < chars.count {
            if chars[i] == " " || chars[i] == "|" {
                i += 1
                continue
            }

            // Try to read a rhythm token (1-2 chars: letter + optional dot)
            var token = String(chars[i])
            if i + 1 < chars.count && chars[i + 1] == "." {
                token += "."
            }

            if let dur = RhythmDuration.from(notation: token) {
                events.append((column: i, duration: dur))
                i += token.count
            } else {
                i += 1
            }
        }

        return events
    }

    // MARK: - Note Extraction

    /// Extract fret numbers from tab lines within a column range.
    /// Returns NoteEvents with fret positions and optional timing.
    private static func extractNotes(
        tabLineIndices: [Int],
        lines: [String],
        columnRange: Range<Int>,
        measureColumnRange: Range<Int>,
        rhythmEvents: [(column: Int, duration: RhythmDuration)]?,
        beatsInMeasure: Int
    ) -> [NoteEvent] {
        // Map string order: find which string each tab line represents
        // Standard order top to bottom: e, B, G, D, A, E
        let stringOrder = resolveStringOrder(tabLineIndices: tabLineIndices, lines: lines)

        // Find all note columns (columns that have a fret number on any string)
        var noteColumns = Set<Int>()
        for lineIdx in tabLineIndices {
            let chars = Array(lines[lineIdx])
            var col = columnRange.lowerBound
            while col < min(columnRange.upperBound, chars.count) {
                if chars[col].isNumber {
                    // Could be multi-digit fret (10, 12, etc.)
                    let startCol = col
                    while col + 1 < min(columnRange.upperBound, chars.count) && chars[col + 1].isNumber {
                        col += 1
                    }
                    noteColumns.insert(startCol)
                }
                col += 1
            }
        }

        let sortedColumns = noteColumns.sorted()
        guard !sortedColumns.isEmpty else { return [] }

        // Build NoteEvents for each note column
        var events: [NoteEvent] = []
        let measureWidth = Double(measureColumnRange.count)

        for col in sortedColumns {
            // Position within measure (0.0 to 1.0)
            let pos = measureWidth > 0
                ? Double(col - measureColumnRange.lowerBound) / measureWidth
                : 0.0

            // Read fret number from each string at this column
            var frets: [Int?] = Array(repeating: nil, count: 6)
            for (stringIdx, lineIdx) in stringOrder {
                let chars = Array(lines[lineIdx])
                if col < chars.count && chars[col].isNumber {
                    // Read multi-digit fret
                    var fretStr = String(chars[col])
                    var nextCol = col + 1
                    while nextCol < chars.count && chars[nextCol].isNumber {
                        fretStr += String(chars[nextCol])
                        nextCol += 1
                    }
                    if let fret = Int(fretStr) {
                        frets[stringIdx] = fret
                    }
                }
            }

            // Find matching rhythm duration if available
            var duration: Double?
            if let rhythmEvents = rhythmEvents {
                // Find the rhythm event closest to this column
                let closest = rhythmEvents.min(by: {
                    abs($0.column - col) < abs($1.column - col)
                })
                if let r = closest, abs(r.column - col) <= 2 {
                    duration = r.duration.rawValue
                }
            }

            events.append(NoteEvent(
                positionInMeasure: max(0, min(1, pos)),
                durationInBeats: duration,
                frets: frets,
                column: col
            ))
        }

        return events
    }

    /// Determine which string index (0=high E, 5=low E) each tab line represents.
    private static func resolveStringOrder(
        tabLineIndices: [Int],
        lines: [String]
    ) -> [(stringIndex: Int, lineIndex: Int)] {
        // Standard tuning order from top to bottom: e(0), B(1), G(2), D(3), A(4), E(5)
        // Case-sensitive canonical names
        let standardNames: [Character] = ["e", "B", "G", "D", "A", "E"]
        // Case-insensitive order for matching when tab uses uniform case
        let standardNamesLower: [Character] = ["e", "b", "g", "d", "a", "e"]

        // Extract the label character for each tab line
        var labels: [(char: Character, lineIdx: Int)] = []
        for lineIdx in tabLineIndices {
            let line = lines[lineIdx].trimmingCharacters(in: .whitespaces)
            guard let firstChar = line.first else { continue }
            labels.append((firstChar, lineIdx))
        }

        // First try exact case-sensitive matching
        var result: [(Int, Int)] = []
        var usedIndices = Set<Int>()
        var allMatched = true

        for (char, lineIdx) in labels {
            // Find the first unused match in standardNames
            if let idx = standardNames.indices.first(where: {
                standardNames[$0] == char && !usedIndices.contains($0)
            }) {
                result.append((idx, lineIdx))
                usedIndices.insert(idx)
            } else {
                allMatched = false
                break
            }
        }

        // If exact matching failed (e.g., all-uppercase E,B,G,D,A,E), try
        // case-insensitive matching with positional disambiguation
        if !allMatched {
            result = []
            usedIndices = []

            for (char, lineIdx) in labels {
                let lc = Character(char.lowercased())
                if let idx = standardNamesLower.indices.first(where: {
                    standardNamesLower[$0] == lc && !usedIndices.contains($0)
                }) {
                    result.append((idx, lineIdx))
                    usedIndices.insert(idx)
                } else {
                    // Fallback: assign by position (top = high string)
                    let posIdx = labels.firstIndex(where: { $0.lineIdx == lineIdx }) ?? 0
                    result.append((min(posIdx, 5), lineIdx))
                }
            }
        }

        return result
    }

    // MARK: - Beat Estimation

    /// Estimate beat count for a measure without explicit bar lines.
    /// Uses rhythm notation if available, otherwise infers from note spacing.
    private static func estimateBeats(
        notes: [NoteEvent],
        rhythmEvents: [(column: Int, duration: RhythmDuration)]?,
        columnRange: Range<Int>,
        defaultBeats: Int
    ) -> Int {
        // 1. If rhythm notation exists, sum the durations
        if let events = rhythmEvents, !events.isEmpty {
            // Only use rhythm events within this column range
            let relevant = events.filter { columnRange.contains($0.column) }
            if !relevant.isEmpty {
                let totalBeats = relevant.reduce(0.0) { $0 + $1.duration.rawValue }
                return max(1, Int(ceil(totalBeats)))
            }
        }

        // 2. Estimate from note spacing
        guard notes.count >= 2 else { return defaultBeats }

        let columns = notes.compactMap(\.column).sorted()
        guard columns.count >= 2 else { return defaultBeats }

        // Calculate average gap between consecutive notes
        var totalGap = 0
        for i in 1..<columns.count {
            totalGap += columns[i] - columns[i - 1]
        }
        let avgGap = Double(totalGap) / Double(columns.count - 1)

        // Heuristic: average gap of ~4 dashes ≈ eighth note (0.5 beats)
        //            average gap of ~8 dashes ≈ quarter note (1.0 beat)
        //            average gap of ~2 dashes ≈ sixteenth note (0.25 beats)
        let beatsPerNote = max(0.25, min(2.0, avgGap / 8.0))
        let estimatedBeats = Int(ceil(Double(notes.count) * beatsPerNote))

        // Clamp to reasonable range
        return max(2, min(estimatedBeats, 64))
    }

    /// Recompute positionInMeasure for notes after the column range has been trimmed.
    private static func recomputeNotePositions(_ notes: [NoteEvent], in range: Range<Int>) -> [NoteEvent] {
        let width = Double(range.count)
        guard width > 0 else { return notes }
        return notes.map { note in
            var updated = note
            if let col = note.column {
                updated.positionInMeasure = max(0, min(1, Double(col - range.lowerBound) / width))
            }
            return updated
        }
    }

    // MARK: - Helpers

    /// Parse a leading number from a line (e.g. "5  |  .  .  |" → 5)
    private static func parseLeadingNumber(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var numStr = ""
        for ch in trimmed {
            if ch.isNumber {
                numStr += String(ch)
            } else {
                break
            }
        }
        guard let num = Int(numStr), num > 0 else { return nil }
        return num
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
