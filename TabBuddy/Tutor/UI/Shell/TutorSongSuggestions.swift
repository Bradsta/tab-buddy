//
//  TutorSongSuggestions.swift
//  TabBuddy
//
//  "Songs you know": library scores whose chord symbols the learner has
//  practiced. Chord names come from stored canonical MusicXML
//  (`CanonicalStore`, `<harmony>` elements) and, for text tabs that were never
//  converted, from the tab parser's chord lines (`MeasureMap` measure chords,
//  or chord-symbol lines in chord sheets without tab staves). Guitar Pro files
//  are not read (their chord names need the alphaTab page). Files are read off
//  the main thread; canonical results are cached per file and converter
//  version, text tabs per path and modification date, for the session. Text
//  tabs are only read when already on the device (no iCloud downloads) and
//  below `textTabByteLimit`.
//

import Foundation
import SwiftData

/// One library score with its chord symbols.
struct TutorLibrarySong: Hashable, Sendable {
    var fileID: UUID
    var title: String
    var chords: [String]
}

/// Minimal reference to a score with a stored canonical file.
struct TutorCanonicalRef: Hashable, Sendable {
    var fileID: UUID
    var title: String
    var canonicalFilename: String
    var canonicalVersion: Int
}

struct TutorSongRow: Hashable, Identifiable {
    var fileID: UUID
    var title: String
    var chords: [String]
    var missing: [String]
    var id: UUID { fileID }
}

enum TutorSongSuggestionAdapter {
    /// Full matches first, then songs missing one chord ("almost there").
    static func rows(songs: [TutorLibrarySong], course: Course, progress: PathProgress,
                     maxMissing: Int = 1) -> (ready: [TutorSongRow], almost: [TutorSongRow]) {
        let known = LibrarySongSuggester.learnedChords(in: course, completedLessonIDs: progress.completedLessonIDs)
        guard !known.isEmpty else { return ([], []) }
        let suggestions = LibrarySongSuggester.suggest(songs: songs.map { ($0.title, $0.chords) }, known: known,
                                                       maxMissing: maxMissing)
        let rows = suggestions.map { s in
            TutorSongRow(fileID: songs[s.index].fileID, title: s.title, chords: s.chords, missing: s.missing)
        }
        return (rows.filter { $0.missing.isEmpty }, rows.filter { !$0.missing.isEmpty })
    }

    /// Learned chord symbols for display ("E, A, D, Em").
    static func learnedChordSymbols(course: Course, progress: PathProgress) -> [String] {
        var seen = Set<LibrarySongSuggester.ChordKey>()
        var symbols: [String] = []
        for location in course.allLessonLocations where progress.completedLessonIDs.contains(location.lesson.id) {
            for step in location.lesson.steps {
                guard case .practice(let p) = step,
                      [.playChord, .chordChanges, .strumRhythm].contains(p.exercise.kind) else { continue }
                for symbol in p.exercise.chords ?? [] {
                    if let key = LibrarySongSuggester.ChordKey(symbol), seen.insert(key).inserted { symbols.append(symbol) }
                }
            }
        }
        return symbols
    }
}

/// Reads chord names from stored canonical files and text tabs, with a session cache.
enum TutorLibraryChordIndex {
    private static let lock = NSLock()
    private static var cache: [String: [String]] = [:]

    /// Upper bound per scan so a very large library stays responsive.
    static let scanLimit = 1500
    /// Unconverted text tabs read per scan (most recently opened first).
    static let textTabScanLimit = 300
    /// Larger text files are skipped.
    static let textTabByteLimit = 512 * 1024

    /// Score references with a canonical file (main actor, property fetch only).
    @MainActor
    static func canonicalRefs(in context: ModelContext) -> [TutorCanonicalRef] {
        var descriptor = FetchDescriptor<FileItem>(predicate: #Predicate { $0.canonicalFilename != nil },
                                                   sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
        descriptor.fetchLimit = scanLimit
        descriptor.propertiesToFetch = [\.id, \.canonicalFilename, \.canonicalVersion, \.filename,
                                        \.customTitle, \.derivedTitle, \.embeddedTitle]
        let items = (try? context.fetch(descriptor)) ?? []
        return items.compactMap { item in
            guard let name = item.canonicalFilename else { return nil }
            return TutorCanonicalRef(fileID: item.id, title: item.displayTitle, canonicalFilename: name,
                                     canonicalVersion: item.canonicalVersion)
        }
    }

    /// Chord names for each ref (off the main thread). Songs without chords are omitted.
    static func songs(for refs: [TutorCanonicalRef],
                      read: @escaping @Sendable (String) -> Data? = { CanonicalStore.read(filename: $0) }) async -> [TutorLibrarySong] {
        await Task.detached(priority: .utility) {
            var songs: [TutorLibrarySong] = []
            for ref in refs {
                if Task.isCancelled { break }
                let key = "\(ref.canonicalFilename):\(ref.canonicalVersion)"
                let cached: [String]? = lock.withLock { cache[key] }
                let chords = cached ?? {
                    let names = read(ref.canonicalFilename).map(chordNames(fromMusicXML:)) ?? []
                    lock.withLock { cache[key] = names }
                    return names
                }()
                if !chords.isEmpty { songs.append(TutorLibrarySong(fileID: ref.fileID, title: ref.title, chords: chords)) }
            }
            return songs
        }.value
    }

    /// Unconverted text tabs, most recently opened first (main actor).
    @MainActor
    static func unconvertedTextTabs(in context: ModelContext) -> [FileItem] {
        var descriptor = FetchDescriptor<FileItem>(
            predicate: #Predicate { $0.canonicalFilename == nil && $0.filename.localizedStandardContains(".txt") },
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
        descriptor.fetchLimit = textTabScanLimit * 2
        let items = (try? context.fetch(descriptor)) ?? []
        return Array(items.filter { $0.filename.lowercased().hasSuffix(".txt") }.prefix(textTabScanLimit))
    }

    /// Chord names from text tabs already on the device. Each file is read and
    /// parsed off the main thread; songs without chords are omitted.
    @MainActor
    static func textTabSongs(for items: [FileItem]) async -> [TutorLibrarySong] {
        var songs: [TutorLibrarySong] = []
        for item in items {
            if Task.isCancelled { break }
            guard item.modelContext != nil, !item.isDeleted,
                  let lease = try? await LibraryManager.shared.acquireFile(item) else { continue }
            let key = item.effectiveRelativePath ?? item.filename
            let (id, title) = (item.id, item.displayTitle)
            let chords = await Task.detached(priority: .utility) { () -> [String] in
                defer { lease.close() }
                return chordNames(fromTextTabAt: lease.url, cacheKey: key)
            }.value
            if !chords.isEmpty { songs.append(TutorLibrarySong(fileID: id, title: title, chords: chords)) }
        }
        return songs
    }

    /// Reads a local text tab (skipping iCloud placeholders and large files),
    /// cached by `cacheKey` plus the modification date.
    static func chordNames(fromTextTabAt url: URL, cacheKey: String) -> [String] {
        var url = url
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                         .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return [] }
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current { return [] }
        guard let size = values.fileSize, size > 0, size <= textTabByteLimit else { return [] }
        let stamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let key = "txt:\(cacheKey):\(stamp)"
        if let cached = lock.withLock({ cache[key] }) { return cached }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        let names = chordNames(fromTabText: text)
        lock.withLock { cache[key] = names }
        return names
    }

    /// Distinct chord symbols of a text tab in first-appearance order: the
    /// parser's measure chords, else chord-symbol lines (chord sheets).
    static func chordNames(fromTabText raw: String) -> [String] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var seen = Set<String>()
        var names: [String] = []
        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted { names.append(trimmed) }
        }
        for measure in TabParser.parse(text).allMeasures {
            for chord in measure.chords ?? [] { add(chord.name) }
        }
        if names.isEmpty {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(4000) {
                let line = String(line)
                guard TabParser.isChordSymbolLine(line) else { continue }
                for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) { add(String(token)) }
            }
        }
        return names
    }

    /// Distinct chord symbols in first-appearance order; empty without `<harmony>` elements.
    static func chordNames(fromMusicXML data: Data) -> [String] {
        guard data.range(of: Data("<harmony".utf8)) != nil, let tab = MusicXMLCodec.decode(data) else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for measure in tab.measures {
            for chord in measure.chords {
                let name = chord.name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, seen.insert(name).inserted { names.append(name) }
            }
        }
        return names
    }
}
