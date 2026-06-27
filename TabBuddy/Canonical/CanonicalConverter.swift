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
        let title: String
    }

    /// Result of converting one job, applied back on the main actor.
    private struct Outcome {
        let id: UUID
        let canonicalFilename: String?
        let provenanceData: Data?
        let version: Int
        let title: String?
        let tuning: String?
        let succeeded: Bool

        static func failure(_ id: UUID) -> Outcome {
            Outcome(id: id, canonicalFilename: nil, provenanceData: nil,
                    version: 0, title: nil, tuning: nil, succeeded: false)
        }
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
        let jobs = pending.map { Job(id: $0.id, bookmark: $0.bookmark, title: Self.titleFromFilename($0.filename)) }
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
                    group.addTask { Self.process(job) }
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

    /// Just-in-time conversion when a file is opened. Idempotent — does nothing
    /// if the file already has a current canonical. For text tabs the viewer has
    /// already parsed, pass `prebuilt` to reuse the parse (near-zero cost); for
    /// PDFs (no prebuilt parse) the read/extract/parse runs off the main actor.
    func convertOnOpen(_ item: FileItem,
                       context: ModelContext,
                       prebuilt: (map: MeasureMap, source: Provenance.SourceType)? = nil) {
        guard item.canonicalVersion < CanonicalConverterVersion.current else { return }

        if let prebuilt {
            let canonical = CanonicalAdapters.canonicalTab(
                from: prebuilt.map,
                title: Self.titleFromFilename(item.filename),
                sourceType: prebuilt.source)
            persist(canonical, to: item, context: context)
            return
        }

        let job = Job(id: item.id, bookmark: item.bookmark, title: Self.titleFromFilename(item.filename))
        Task.detached(priority: .utility) { [weak self] in
            let outcome = Self.process(job)
            await MainActor.run {
                guard self != nil else { return }
                self?.applyOutcome(outcome, to: item)
                try? context.save()
            }
        }
    }

    /// Encode + store a canonical and stamp the FileItem (main actor).
    private func persist(_ canonical: CanonicalTab, to item: FileItem, context: ModelContext) {
        let data = MusicXMLCodec.encode(canonical)
        let filename = CanonicalStore.filename(for: item.id)
        do {
            try CanonicalStore.write(data, filename: filename)
        } catch {
            return
        }
        item.canonicalFilename = filename
        item.provenance = canonical.provenance
        item.canonicalVersion = canonical.provenance.converterVersion
        item.derivedTitle = canonical.title
        item.tuning = canonical.tuningName
        try? context.save()
    }

    /// Convert a single file synchronously-ish (used for small, just-imported
    /// sets). Returns whether a canonical was produced.
    @discardableResult
    func convert(_ item: FileItem, context: ModelContext) -> Bool {
        let job = Job(id: item.id, bookmark: item.bookmark, title: Self.titleFromFilename(item.filename))
        let outcome = Self.process(job)
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
        guard outcome.succeeded else { return }
        item.canonicalFilename = outcome.canonicalFilename
        item.provenanceData = outcome.provenanceData
        item.canonicalVersion = outcome.version
        item.derivedTitle = outcome.title
        item.tuning = outcome.tuning
    }

    // MARK: - Off-main work

    /// Read, parse, encode, and write the canonical for one job. Pure value I/O —
    /// safe to run off the main actor.
    private nonisolated static func process(_ job: Job) -> Outcome {
        guard let (text, source) = extractText(bookmark: job.bookmark),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(job.id)
        }

        let map = TabParser.parse(text)
        let canonical = CanonicalAdapters.canonicalTab(from: map,
                                                       title: job.title,
                                                       sourceType: source)
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
                       succeeded: true)
    }

    /// Resolve a bookmark and extract tab text from the original file.
    private nonisolated static func extractText(bookmark: Data) -> (String, Provenance.SourceType)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                 bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

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
            return (s, .pdfText)

        default:
            return nil
        }
    }

    private nonisolated static func titleFromFilename(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }
}
