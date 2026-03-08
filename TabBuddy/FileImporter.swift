import Foundation
import SwiftData

/// Recursively imports every `.pdf` / `.txt` in the chosen files / folders.
/// Shows progress, supports cancel, avoids Swift-6 data-race violations.
@MainActor
final class FolderImporter: ObservableObject {
    @Published var total     = 0          // files discovered
    @Published var processed = 0          // files imported so far
    @Published var isRunning = false
    
    private var task: Task<Void, Never>?
    
    // MARK: – Public API -----------------------------------------------------
    func start(urls: [URL], context: ModelContext) {
        cancel()
        isRunning  = true
        processed  = 0
        total      = 0
        
        // snapshot existing names for O(1) duplicate checks
        let existingNames = Set(
            (try? context.fetch(FetchDescriptor<FileItem>()))?.map(\.filename) ?? []
        )
        
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // ── 1️⃣  Gather URLs while directory scope is OPEN ───────────────
            var openedDirs: [URL] = []
            var gathered: [URL] = []

            for root in urls {
                if root.hasDirectoryPath {
                    if root.startAccessingSecurityScopedResource() {
                        openedDirs.append(root)
                        if let enumr = FileManager.default.enumerator(
                            at: root,
                            includingPropertiesForKeys: [.isRegularFileKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        ) {
                            for case let f as URL in enumr where await Self.accepts(f) {
                                gathered.append(f)
                            }
                        }
                    }
                } else if await Self.accepts(root) {
                    gathered.append(root)
                }
            }

            let candidates = gathered
            await MainActor.run { self.total = candidates.count }

            // Snapshot existing names before we hop into the group
            var seen = existingNames

            // ── 2️⃣  MAKE BOOKMARKS (Swift-6-safe) ───────────────────────────
            let fresh: [(name: String, data: Data, folder: String, hash: String?)] =
                (try? await withThrowingTaskGroup(of: (String, Data, String, String?)?.self) { group in
                    var next = candidates.startIndex
                    func queue() {
                        guard next < candidates.endIndex else { return }
                        let url = candidates[next]; next = candidates.index(after: next)
                        group.addTask {
                            guard let data = try? url.bookmarkData() else { return nil }
                            let folder = url.deletingLastPathComponent().lastPathComponent
                            let hash = FileItem.fingerprint(of: url)
                            return (url.lastPathComponent, data, folder, hash)
                        }
                    }
                    for _ in 0..<4 { queue() }

                    var buffer: [(String, Data, String, String?)] = []

                    for try await result in group {
                        await MainActor.run { self.processed += 1 }
                        if let pair = result, seen.insert(pair.0).inserted {
                            buffer.append(pair)
                        }
                        queue()
                    }
                    return buffer
                }) ?? []

            // ── 3️⃣  Commit inserts on main actor ────────────────────────────
            await MainActor.run {
                for rec in fresh {
                    context.insert(
                        FileItem(bookmark: rec.data,
                                 filename: rec.name,
                                 isFavorite: false,
                                 tags: [],
                                 folderName: rec.folder,
                                 contentHash: rec.hash,
                                 importedAt: Date())
                    )
                }
                try? context.save()
                TagIndexer.rebuild(in: context)
            }

            // ── 4️⃣  Close directory scopes & finish ─────────────────────────
            for dir in openedDirs { dir.stopAccessingSecurityScopedResource() }
            await MainActor.run { self.finish(cancelled: false) }
        }
    }
    
    // MARK: – Library Copy Import ------------------------------------------------
    func startWithLibraryCopy(urls: [URL], context: ModelContext, libraryManager: LibraryManager) {
        cancel()
        isRunning  = true
        processed  = 0
        total      = 0

        // snapshot existing names for O(1) duplicate checks
        let existingNames = Set(
            (try? context.fetch(FetchDescriptor<FileItem>()))?.map(\.filename) ?? []
        )

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // ── 1️⃣  Gather source files while directory scope is OPEN ──────────
            var openedDirs: [URL] = []
            var gathered: [URL] = []
            var folderRoot: URL? = nil

            for root in urls {
                if root.hasDirectoryPath {
                    if root.startAccessingSecurityScopedResource() {
                        openedDirs.append(root)
                        folderRoot = root
                        if let enumr = FileManager.default.enumerator(
                            at: root,
                            includingPropertiesForKeys: [.isRegularFileKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        ) {
                            for case let f as URL in enumr where await Self.accepts(f) {
                                gathered.append(f)
                            }
                        }
                    }
                } else if await Self.accepts(root) {
                    // For individual files, start access to read them
                    if root.startAccessingSecurityScopedResource() {
                        openedDirs.append(root)
                    }
                    gathered.append(root)
                }
            }

            let candidates = gathered
            await MainActor.run { self.total = candidates.count }

            // ── 2️⃣  Copy to library on main actor (needs security scope) ──────
            let copied = await MainActor.run {
                libraryManager.copyFilesToLibrary(
                    sourceURLs: candidates,
                    relativeTo: folderRoot
                )
            }

            // ── 3️⃣  Create bookmarks for the copied files ─────────────────────
            var seen = existingNames
            var fresh: [(name: String, data: Data, folder: String, libPath: String, hash: String?)] = []

            for (destURL, relativePath) in copied {
                await MainActor.run { self.processed += 1 }

                let name = destURL.lastPathComponent
                guard seen.insert(name).inserted else { continue }
                guard let data = try? destURL.bookmarkData() else { continue }
                let folder = destURL.deletingLastPathComponent().lastPathComponent
                let hash = FileItem.fingerprint(of: destURL)
                fresh.append((name, data, folder, relativePath, hash))
            }

            // ── 4️⃣  Commit inserts on main actor ──────────────────────────────
            await MainActor.run {
                for rec in fresh {
                    context.insert(
                        FileItem(bookmark: rec.data,
                                 filename: rec.name,
                                 folderName: rec.folder,
                                 libraryPath: rec.libPath,
                                 contentHash: rec.hash,
                                 importedAt: Date())
                    )
                }
                try? context.save()
                TagIndexer.rebuild(in: context)
            }

            // ── 5️⃣  Close directory scopes & finish ───────────────────────────
            for dir in openedDirs { dir.stopAccessingSecurityScopedResource() }
            await MainActor.run { self.finish(cancelled: false) }
        }
    }

    /// Cancel any running import.
    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }
    
    // MARK: – Helpers -------------------------------------------------------
    private func finish(cancelled: Bool) {
        task = nil
        isRunning = false
        if cancelled { processed = 0; total = 0 }
    }
    
    private static func accepts(_ url: URL) -> Bool {
        ["pdf", "txt"].contains(url.pathExtension.lowercased())
    }
}
