import Foundation
import SwiftData

@MainActor
final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    private static let bookmarkKey = "libraryDirectoryBookmark"
    private static let appGroupID = "group.com.gamicarts.TabBuddy"
    private static let pendingDir = "PendingImports"

    @Published var libraryName: String?
    @Published var isConfigured: Bool = false

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
        guard let libraryURL = resolveLibraryURL() else { return }
        guard libraryURL.startAccessingSecurityScopedResource() else { return }
        defer { libraryURL.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default

        // 1. Enumerate all PDF/TXT in library recursively
        guard let enumerator = fm.enumerator(
            at: libraryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

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

        // 2. Fetch existing FileItems, group by filename
        let existing = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
        let byName = Dictionary(grouping: existing, by: \.filename)

        // 3. Match discovered files to existing FileItems
        for (fileURL, relativePath) in discoveredFiles {
            let filename = fileURL.lastPathComponent
            let folderName = fileURL.deletingLastPathComponent().lastPathComponent

            if let matches = byName[filename], let match = matches.first {
                // Update existing FileItem with fresh bookmark and path
                if let freshBookmark = try? fileURL.bookmarkData() {
                    match.bookmark = freshBookmark
                }
                match.libraryPath = relativePath
                match.folderName = folderName
            } else {
                // Create new FileItem for unmatched file
                guard let bookmarkData = try? fileURL.bookmarkData() else { continue }
                let newItem = FileItem(
                    bookmark: bookmarkData,
                    filename: filename,
                    folderName: folderName,
                    libraryPath: relativePath
                )
                context.insert(newItem)
            }
        }

        // 4. Leave unmatched FileItems alone (their bookmark may still work)
        try? context.save()
        TagIndexer.rebuild(in: context)
    }

    // MARK: - Pending Imports (from Share Extension)

    static var pendingImportsURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(pendingDir)
    }

    func processPendingImports(context: ModelContext) {
        guard let pendingURL = Self.pendingImportsURL else { return }
        let fm = FileManager.default

        guard fm.fileExists(atPath: pendingURL.path(percentEncoded: false)) else { return }

        guard let files = try? fm.contentsOfDirectory(
            at: pendingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), !files.isEmpty else { return }

        let existingNames = Set(
            (try? context.fetch(FetchDescriptor<FileItem>()))?.map(\.filename) ?? []
        )

        let libraryURL = resolveLibraryURL()
        let hasLibrary = libraryURL != nil
        if hasLibrary {
            _ = libraryURL!.startAccessingSecurityScopedResource()
        }
        defer {
            if hasLibrary { libraryURL!.stopAccessingSecurityScopedResource() }
        }

        for file in files {
            let ext = file.pathExtension.lowercased()
            guard ext == "pdf" || ext == "txt" else {
                try? fm.removeItem(at: file)
                continue
            }

            let filename = file.lastPathComponent
            guard !existingNames.contains(filename) else {
                try? fm.removeItem(at: file)
                continue
            }

            let finalURL: URL
            var libraryRelPath: String? = nil

            if let libURL = libraryURL {
                // Move to library
                let dest = libURL.appendingPathComponent(filename)
                do {
                    if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                        try fm.removeItem(at: dest)
                    }
                    try fm.moveItem(at: file, to: dest)
                    finalURL = dest
                    libraryRelPath = filename
                } catch {
                    // Fallback: bookmark in place
                    finalURL = file
                }
            } else {
                finalURL = file
            }

            guard let bookmarkData = try? finalURL.bookmarkData() else {
                try? fm.removeItem(at: file)
                continue
            }

            let item = FileItem(
                bookmark: bookmarkData,
                filename: filename,
                folderName: finalURL.deletingLastPathComponent().lastPathComponent,
                libraryPath: libraryRelPath
            )
            context.insert(item)
        }

        try? context.save()
        TagIndexer.rebuild(in: context)

        // Clean up pending directory
        try? fm.removeItem(at: pendingURL)
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
