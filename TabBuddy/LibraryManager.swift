import Foundation
import SwiftData

@MainActor
final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    private static let bookmarkKey = "libraryDirectoryBookmark"
    @Published var libraryName: String?
    @Published var isConfigured: Bool = false
    @Published var isRescanning: Bool = false
    @Published var rescanTotal: Int = 0
    @Published var rescanProcessed: Int = 0

    private init() {
        refreshState()
    }

    // MARK: - Library Folder Setup

    func setLibraryFolder(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        refreshState()
    }

    func removeLibraryFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        refreshState()
    }

    func resolveLibraryURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            return nil
        }

        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            bookmarkDataIsStale: &stale
        ) else { return nil }

        // Re-bookmark if stale
        if stale {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData() {
                UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
            }
        }

        return url
    }

    // MARK: - Copy to Library

    /// Copies files into the library, preserving subfolder structure relative to `relativeTo`.
    /// Returns `(destinationURL, libraryRelativePath)` tuples for successfully copied files.
    func copyFilesToLibrary(
        sourceURLs: [URL],
        relativeTo folderRoot: URL?
    ) -> [(url: URL, relativePath: String)] {
        guard let libraryURL = resolveLibraryURL() else { return [] }
        guard libraryURL.startAccessingSecurityScopedResource() else { return [] }
        defer { libraryURL.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default
        var results: [(URL, String)] = []

        for source in sourceURLs {
            let relativePath: String
            if let root = folderRoot {
                // Preserve subfolder structure
                let rootPath = root.standardizedFileURL.path(percentEncoded: false)
                let sourcePath = source.standardizedFileURL.path(percentEncoded: false)
                if sourcePath.hasPrefix(rootPath) {
                    relativePath = String(sourcePath.dropFirst(rootPath.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                } else {
                    relativePath = source.lastPathComponent
                }
            } else {
                relativePath = source.lastPathComponent
            }

            let dest = libraryURL.appendingPathComponent(relativePath)

            // Create intermediate directories
            let destDir = dest.deletingLastPathComponent()
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            // Copy (skip if already exists)
            if !fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                do {
                    try fm.copyItem(at: source, to: dest)
                } catch {
                    continue
                }
            }

            results.append((dest, relativePath))
        }

        return results
    }

    // MARK: - Rescan Library

    func rescan(context: ModelContext) {
        guard !isRescanning else { return }
        guard let libraryURL = resolveLibraryURL() else { return }
        guard libraryURL.startAccessingSecurityScopedResource() else { return }

        isRescanning = true
        rescanProcessed = 0
        rescanTotal = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                libraryURL.stopAccessingSecurityScopedResource()
                return
            }

            let fm = FileManager.default

            // 1. Enumerate all PDF/TXT in library recursively
            guard let enumerator = fm.enumerator(
                at: libraryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                libraryURL.stopAccessingSecurityScopedResource()
                await MainActor.run { self.isRescanning = false }
                return
            }

            var discoveredFiles: [(url: URL, relativePath: String)] = []
            let libraryPath = libraryURL.standardizedFileURL.path(percentEncoded: false)

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "pdf" || ext == "txt" else { continue }

                let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
                let relative = String(filePath.dropFirst(libraryPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                discoveredFiles.append((fileURL, relative))
            }

            await MainActor.run { self.rescanTotal = discoveredFiles.count }

            // 2. Fast pass on main actor: match by path and name (no I/O)
            let unmatchedIndices: [Int] = await MainActor.run {
                let existing = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
                var byLibPath: [String: FileItem] = [:]
                var byName: [String: FileItem] = [:]
                for item in existing {
                    if let lp = item.libraryPath { byLibPath[lp] = item }
                    if byName[item.filename] == nil { byName[item.filename] = item }
                }

                var matched = Set<UUID>()
                var needsHash: [Int] = []

                for (i, (fileURL, relativePath)) in discoveredFiles.enumerated() {
                    let filename = fileURL.lastPathComponent
                    let folderName = fileURL.deletingLastPathComponent().lastPathComponent

                    if let m = byLibPath[relativePath], !matched.contains(m.id) {
                        matched.insert(m.id)
                        if let freshBookmark = try? fileURL.bookmarkData() {
                            m.bookmark = freshBookmark
                        }
                        m.filename = filename
                        m.libraryPath = relativePath
                        m.folderName = folderName
                    } else if let m = byName[filename], !matched.contains(m.id) {
                        matched.insert(m.id)
                        if let freshBookmark = try? fileURL.bookmarkData() {
                            m.bookmark = freshBookmark
                        }
                        m.libraryPath = relativePath
                        m.folderName = folderName
                    } else {
                        needsHash.append(i)
                    }
                }

                self.rescanProcessed = discoveredFiles.count - needsHash.count
                return needsHash
            }

            // 3. Slow pass: only fingerprint unmatched files (moved/renamed/new)
            var hashResults: [(index: Int, hash: String?)] = []
            if !unmatchedIndices.isEmpty {
                hashResults = await withTaskGroup(of: (Int, String?).self) { group in
                    var buf: [(Int, String?)] = []
                    var cursor = 0

                    func enqueue() {
                        guard cursor < unmatchedIndices.count else { return }
                        let idx = unmatchedIndices[cursor]
                        cursor += 1
                        let url = discoveredFiles[idx].url
                        group.addTask { (idx, FileItem.fingerprint(of: url)) }
                    }

                    for _ in 0..<8 { enqueue() }

                    var completed = 0
                    for await result in group {
                        buf.append(result)
                        completed += 1
                        if completed % 20 == 0 {
                            let done = discoveredFiles.count - unmatchedIndices.count + completed
                            await MainActor.run { self.rescanProcessed = done }
                        }
                        enqueue()
                    }
                    return buf
                }
            }

            // 4. Commit hash-matched and new files on main actor
            await MainActor.run {
                self.rescanProcessed = discoveredFiles.count

                let existing = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
                var byHash: [String: FileItem] = [:]
                for item in existing {
                    if let ch = item.contentHash { byHash[ch] = item }
                }

                // Collect IDs already matched in the fast pass
                var matched = Set<UUID>()
                for item in existing where item.libraryPath != nil {
                    // Items updated in fast pass have a libraryPath that exists in discovered
                    matched.insert(item.id)
                }

                for (idx, hash) in hashResults {
                    let (fileURL, relativePath) = discoveredFiles[idx]
                    let filename = fileURL.lastPathComponent
                    let folderName = fileURL.deletingLastPathComponent().lastPathComponent

                    if let h = hash, let m = byHash[h], !matched.contains(m.id) {
                        matched.insert(m.id)
                        if let freshBookmark = try? fileURL.bookmarkData() {
                            m.bookmark = freshBookmark
                        }
                        m.filename = filename
                        m.libraryPath = relativePath
                        m.folderName = folderName
                        m.contentHash = h
                    } else {
                        // Truly new file
                        guard let bookmarkData = try? fileURL.bookmarkData() else { continue }
                        let newItem = FileItem(
                            bookmark: bookmarkData,
                            filename: filename,
                            folderName: folderName,
                            libraryPath: relativePath,
                            contentHash: hash
                        )
                        context.insert(newItem)
                    }
                }

                try? context.save()
                TagIndexer.rebuild(in: context)

                libraryURL.stopAccessingSecurityScopedResource()
                self.isRescanning = false
            }
        }
    }

    // MARK: - Private

    private func refreshState() {
        if let url = resolveLibraryURL() {
            libraryName = url.lastPathComponent
            isConfigured = true
        } else {
            libraryName = nil
            isConfigured = false
        }
    }
}

// MARK: - Backup / Restore

struct FileItemBackup: Codable {
    var filename: String
    var isFavorite: Bool
    var tags: [String]
    var importedAt: Date
    var lastOpenedAt: Date
    var scrollSpeed: Double
    var folderName: String
    var loopStartY: Double?
    var loopEndY: Double?
    var libraryPath: String?
    var playCount: Int
}

struct LibraryBackup: Codable {
    var version: Int = 1
    var exportedAt: Date
    var files: [FileItemBackup]
}

enum BackupManager {

    static func exportJSON(context: ModelContext) -> Data? {
        let items = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []

        let entries = items.map { item in
            FileItemBackup(
                filename: item.filename,
                isFavorite: item.isFavorite,
                tags: item.tags,
                importedAt: item.importedAt,
                lastOpenedAt: item.lastOpenedAt,
                scrollSpeed: item.scrollSpeed,
                folderName: item.folderName,
                loopStartY: item.loopStartY,
                loopEndY: item.loopEndY,
                libraryPath: item.libraryPath,
                playCount: item.playCount
            )
        }

        let backup = LibraryBackup(exportedAt: .now, files: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(backup)
    }

    @MainActor
    static func importJSON(data: Data, context: ModelContext) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(LibraryBackup.self, from: data) else {
            return 0
        }

        let existing = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
        var byPath: [String: FileItem] = [:]
        var byName: [String: FileItem] = [:]
        for item in existing {
            if let lp = item.libraryPath { byPath[lp] = item }
            if byName[item.filename] == nil { byName[item.filename] = item }
        }

        var restored = 0
        for entry in backup.files {
            let match = (entry.libraryPath.flatMap { byPath[$0] }) ?? byName[entry.filename]
            guard let match else { continue }

            match.isFavorite = entry.isFavorite
            match.tags = entry.tags
            match.scrollSpeed = entry.scrollSpeed
            match.loopStartY = entry.loopStartY
            match.loopEndY = entry.loopEndY
            match.playCount = entry.playCount
            if entry.lastOpenedAt > match.lastOpenedAt {
                match.lastOpenedAt = entry.lastOpenedAt
            }
            restored += 1
        }

        try? context.save()
        TagIndexer.rebuild(in: context)
        return restored
    }
}
