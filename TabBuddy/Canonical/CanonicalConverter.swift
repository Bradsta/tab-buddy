//
//  CanonicalConverter.swift
//  TabBuddy
//
//  Generates canonical MusicXML for imported tabs, on-device.
//
//  Pipeline: original (.txt / text-extractable .pdf) -> text -> TabParser ->
//  MeasureMap -> CanonicalAdapters -> CanonicalTab -> MusicXMLCodec -> CanonicalStore.
//  The owning FileItem records the canonical filename, provenance, and converter
//  version. Existing metadata (tags, favorites, BPM, …) is never touched.
//
//  Batch conversion backfills the existing library and is idempotent: it only
//  (re)converts files whose canonical is missing or stale (older converter
//  version), unless `force` is set.
//

import Foundation
import SwiftData
import PDFKit

@MainActor
final class CanonicalConverter: ObservableObject {
    static let shared = CanonicalConverter()

    @Published var isConverting = false
    @Published var total = 0
    @Published var processed = 0
    @Published var converted = 0   // succeeded
    @Published var skipped = 0     // could not extract text (e.g. scanned PDF)

    private init() {}

    /// Captured, value-type snapshot of a FileItem for off-main work.
    private struct Job {
        let id: UUID
        let bookmark: Data
        let relativePath: String?
        let title: String
    }

    /// Result of converting one job, applied back on the main actor.
    struct Outcome: Sendable {
        let id: UUID
        let canonicalFilename: String?
        let provenanceData: Data?
        let version: Int
        let title: String?
        let tuning: String?
        let foreword: String?
        let instrument: String?
        let succeeded: Bool

        static func failure(_ id: UUID) -> Outcome {
            Outcome(id: id, canonicalFilename: nil, provenanceData: nil,
                    version: 0, title: nil, tuning: nil, foreword: nil,
                    instrument: nil, succeeded: false)
        }
    }

    /// Combined searchable foreword text from a canonical (composer + comments).
    private nonisolated static func forewordText(_ canonical: CanonicalTab) -> String? {
        let parts = [canonical.artist, canonical.comments].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: - Public API

    /// Convert files lacking a current canonical. Pass `items` to limit scope,
    /// or nil to scan the whole library. `force` re-converts everything.
    func convertLibrary(items: [FileItem]? = nil,
                        context: ModelContext,
                        force: Bool = false) {
        guard !isConverting else { return }

        let all = items ?? ((try? context.fetch(FetchDescriptor<FileItem>())) ?? [])
        let pending = all.filter { force || $0.canonicalVersion < CanonicalConverterVersion.current }
        guard !pending.isEmpty else { return }

        // Snapshot on the main actor; index for commit.
        let jobs = pending.map { Job(id: $0.id, bookmark: $0.bookmark, relativePath: $0.effectiveRelativePath, title: Self.titleFromFilename($0.filename)) }
        var byID: [UUID: FileItem] = [:]
        for item in pending { byID[item.id] = item }

        isConverting = true
        total = jobs.count
        processed = 0
        converted = 0
        skipped = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Outcome.self) { group in
                var cursor = 0
                let width = 6

                func enqueue() {
                    guard cursor < jobs.count else { return }
                    let job = jobs[cursor]
                    cursor += 1
                    group.addTask { await Self.process(job) }
                }

                for _ in 0..<width { enqueue() }

                var pendingCommits: [Outcome] = []
                for await outcome in group {
                    pendingCommits.append(outcome)
                    enqueue()

                    if pendingCommits.count >= 25 {
                        let batch = pendingCommits
                        pendingCommits.removeAll(keepingCapacity: true)
                        await self.commit(batch, byID: byID, context: context)
                    }
                }
                if !pendingCommits.isEmpty {
                    await self.commit(pendingCommits, byID: byID, context: context)
                }
            }

            await MainActor.run { self.isConverting = false }
        }
    }

    /// Value-only preparation; callers retain model ownership on their own actor.
    nonisolated static func prepareText(id: UUID, title: String, text: String) -> Outcome {
        processText(Job(id: id, bookmark: Data(), relativePath: nil, title: title), text: text, source: .txtDirect)
    }

    func applyPreparedText(_ outcome: Outcome, to item: FileItem) {
        guard item.canonicalVersion < CanonicalConverterVersion.current else { return }
        applyOutcome(outcome, to: item)
    }

    /// Background TXT preparation reuses the already-read text and never converts PDFs.
    func backfillText(_ item: FileItem, text: String) async {
        guard !isConverting, item.canonicalVersion < CanonicalConverterVersion.current else { return }
        let job = Job(id: item.id, bookmark: Data(), relativePath: nil, title: item.displayTitle)
        let work = Task.detached(priority: .utility) { Self.processText(job, text: text, source: .txtDirect) }
        let outcome = await work.value
        guard !Task.isCancelled, item.modelContext != nil else { return }
        applyOutcome(outcome, to: item)
    }

    /// Just-in-time conversion when a file is opened. Idempotent — does nothing
    /// if the file already has a current canonical. For text tabs the viewer has
    /// already parsed, pass `prebuilt` to reuse the parse (near-zero cost); for
    /// PDFs (no prebuilt parse) the read/extract/parse runs off the main actor.
    func convertOnOpen(_ item: FileItem,
                       context: ModelContext,
                       prebuilt: (map: MeasureMap, source: Provenance.SourceType)? = nil) {
        // Canonical files are device-local. A record synced (or merged) from another
        // device can name a current canonical this device never generated; a text tab
        // with a prebuilt parse regenerates it here.
        let missingLocally = prebuilt != nil && item.canonicalFilename.map { !CanonicalStore.exists(filename: $0) } == true
        guard item.canonicalVersion < CanonicalConverterVersion.current || missingLocally else { return }

        if let prebuilt {
            guard prebuilt.map.resolvedOpenStringMIDI != nil else { return }
            let title = Self.titleFromFilename(item.filename)
            Task {
                let canonical = await Task.detached(priority: .utility) {
                    CanonicalAdapters.canonicalTab(from: prebuilt.map, title: title, sourceType: prebuilt.source)
                }.value
                guard item.modelContext != nil, !item.isDeleted else { return }
                await persist(canonical, to: item, context: context)
            }
            return
        }

        let job = Job(id: item.id, bookmark: item.bookmark, relativePath: item.effectiveRelativePath, title: Self.titleFromFilename(item.filename))
        Task.detached(priority: .utility) { [weak self] in
            let outcome = await Self.process(job)
            guard let self else { return }
            await MainActor.run {
                self.applyOutcome(outcome, to: item)
                try? context.save()
            }
        }
    }

    /// Encode + store a canonical and stamp the FileItem (main actor).
    private func persist(_ canonical: CanonicalTab, to item: FileItem, context: ModelContext) async {
        let filename = CanonicalStore.filename(for: item.id)
        do {
            try await Task.detached(priority: .utility) {
                try CanonicalStore.write(MusicXMLCodec.encode(canonical), filename: filename)
            }.value
        } catch { return }
        guard item.modelContext != nil, !item.isDeleted else { return }
        item.canonicalFilename = filename
        item.provenance = canonical.provenance
        item.canonicalVersion = canonical.provenance.converterVersion
        item.derivedTitle = canonical.title
        if !item.metadataEdited && item.tuning == nil { item.tuning = canonical.tuningName }
        item.foreword = Self.forewordText(canonical)
        // Prebuilt parses come from the text-tab viewer — guitar by definition.
        item.inferMetadata(from: [canonical.title, canonical.artist, canonical.comments].compactMap { $0 }.joined(separator: "\n"))
        if !item.metadataEdited && item.instruments.isEmpty {
            let kind: Instrument = canonical.tuningName.hasPrefix("Bass") ? .bass : canonical.tuningName.hasPrefix("Ukulele") ? .ukulele : .guitar
            item.instrument = kind.rawValue
            item.instruments = [kind.rawValue]
        }
        try? context.save()
    }

    /// Convert a single file synchronously-ish (used for small, just-imported
    /// sets). Returns whether a canonical was produced.
    @discardableResult
    func convert(_ item: FileItem, context: ModelContext) async -> Bool {
        let job = Job(id: item.id, bookmark: item.bookmark, relativePath: item.effectiveRelativePath, title: Self.titleFromFilename(item.filename))
        let outcome = await Self.process(job)
        applyOutcome(outcome, to: item)
        try? context.save()
        return outcome.succeeded
    }

    // MARK: - Commit (main actor)

    private func commit(_ outcomes: [Outcome], byID: [UUID: FileItem], context: ModelContext) {
        for outcome in outcomes {
            processed += 1
            if outcome.succeeded { converted += 1 } else { skipped += 1 }
            if let item = byID[outcome.id] {
                applyOutcome(outcome, to: item)
            }
        }
        try? context.save()
    }

    private func applyOutcome(_ outcome: Outcome, to item: FileItem) {
        guard outcome.succeeded, item.modelContext != nil else { return }
        item.canonicalFilename = outcome.canonicalFilename
        item.provenanceData = outcome.provenanceData
        item.canonicalVersion = outcome.version
        item.derivedTitle = outcome.title
        if !item.metadataEdited && item.tuning == nil { item.tuning = outcome.tuning }
        item.foreword = outcome.foreword
        if !item.metadataEdited {
            if item.instruments.isEmpty { item.instrument = outcome.instrument }
            item.inferMetadata(from: [outcome.title, outcome.foreword].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    // MARK: - Off-main work

    /// Read, parse, encode, and write the canonical for one job. Pure value I/O —
    /// safe to run off the main actor.
    private nonisolated static func process(_ job: Job) async -> Outcome {
        // Jobs run concurrently; OCR stats must belong to this document only.
        await PDFTabExtractor.$ocrStats.withValue(PDFTabExtractor.OCRStats()) {
            guard let (text, source) = await extractText(bookmark: job.bookmark, relativePath: job.relativePath),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(job.id)
            }
            return processText(job, text: text, source: source)
        }
    }

    private nonisolated static func processText(_ job: Job, text: String, source: Provenance.SourceType) -> Outcome {
        let map = TabParser.parse(text)

        // Prefer explicit instrument evidence; plain notation does not identify an instrument.
        let hasNotes = map.allMeasures.contains { !($0.notes ?? []).isEmpty }
        let instrument: Instrument
        switch source {
        case .pdfSpatial, .ocr:
            instrument = Instrument.detect(inText: job.title + "\n" + text) ?? .guitar
        case .notation:
            // A lead sheet is never a guitar tab even though we synthesize one.
            // Classify from the filename (the extracted melody has no keywords).
            instrument = Instrument.detect(inText: job.title) ?? .unknown
        case .txtDirect:
            instrument = Instrument.detect(inText: text) ?? (hasNotes ? .guitar : .unknown)
        default:
            instrument = Instrument.detect(inText: text) ?? (hasNotes ? .guitar : .unknown)
        }

        guard map.resolvedOpenStringMIDI != nil else { return .failure(job.id) }
        var canonical = CanonicalAdapters.canonicalTab(from: map,
                                                       title: job.title,
                                                       sourceType: source)
        if source == .ocr {
            // OCR confidence = measure coverage scaled by how much of the
            // page's digit ink was actually classified.
            let stats = PDFTabExtractor.lastOCRStats
            if stats.candidates > 0 {
                canonical.provenance.confidence *= Double(stats.classified) / Double(stats.candidates)
            }
        }
        let data = MusicXMLCodec.encode(canonical)
        let filename = CanonicalStore.filename(for: job.id)
        do {
            try CanonicalStore.write(data, filename: filename)
        } catch {
            return .failure(job.id)
        }

        let provData = try? JSONEncoder().encode(canonical.provenance)
        return Outcome(id: job.id,
                       canonicalFilename: filename,
                       provenanceData: provData,
                       version: canonical.provenance.converterVersion,
                       title: canonical.title,
                       tuning: canonical.tuningName,
                       foreword: forewordText(canonical),
                       instrument: instrument.rawValue,
                       succeeded: true)
    }

    /// Resolve the file (library-relative path first, else bookmark) and
    /// extract tab text from it.
    private nonisolated static func extractText(bookmark: Data, relativePath: String?) async -> (String, Provenance.SourceType)? {
        let lease: FileAccessLease
        if let relativePath {
            guard let acquired = try? await LibraryFileService.shared.acquireFile(relativePath: relativePath) else { return nil }
            lease = acquired
        } else {
            guard let acquired = try? await LibraryFileService.shared.acquireLegacyFile(bookmark: bookmark) else { return nil }
            lease = acquired
        }
        defer { lease.close() }
        let url = lease.url

        switch url.pathExtension.lowercased() {
        case "txt":
            let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            return text.map { ($0, .txtDirect) }

        case "pdf":
            guard let doc = PDFDocument(url: url) else { return nil }
            var s = ""
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let ps = page.string {
                    s += ps
                    s += "\n"
                }
            }
            // Monospace text-export PDFs parse directly. Rendered scores
            // (Guitar Pro / engraving exports) have scrambled text, so
            // reconstruct the TAB spatially from glyph positions instead.
            func fretTotal(_ text: String) -> Int {
                TabParser.parse(text).allMeasures
                    .compactMap(\.notes).flatMap { $0 }
                    .flatMap(\.frets).compactMap { $0 }.count
            }
            PDFTabExtractor.resetOCRStats()
            if looksLikeAsciiTab(s) {
                // PDF text extraction can mangle line layout and silently
                // truncate the parse (Tw2 tavern: 3 of 7 systems). If the
                // spatial reconstruction reads more notes, trust it instead.
                if let spatial = PDFTabExtractor.asciiTab(from: doc),
                   fretTotal(spatial) > fretTotal(s) {
                    let ocr = PDFTabExtractor.lastOCRStats.candidates > 0
                    return (spatial, ocr ? .ocr : .pdfSpatial)
                }
                return (s, .pdfText)
            }
            if let spatial = PDFTabExtractor.asciiTab(from: doc) {
                // No text layer → the OCR fallback ran; record it honestly.
                let ocr = PDFTabExtractor.lastOCRStats.candidates > 0
                return (spatial, ocr ? .ocr : .pdfSpatial)
            }
            // Notation-only score (lead sheet): approximate the melody as tab.
            if let melody = PDFTabExtractor.asciiFromNotation(from: doc) {
                return (melody, .notation)
            }
            return (s, .pdfText)

        default:
            return nil
        }
    }

    private nonisolated static func titleFromFilename(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    /// Any line dominated by dashes/sustains ⇒ a monospace ASCII tab export.
    private nonisolated static func looksLikeAsciiTab(_ text: String) -> Bool {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 8 else { continue }
            let dashes = t.filter { $0 == "-" || $0 == "=" }.count
            if dashes >= 6, Double(dashes) / Double(t.count) >= 0.3 { return true }
        }
        return false
    }
}
