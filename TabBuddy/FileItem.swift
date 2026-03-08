import Foundation
import SwiftData
import CryptoKit

@Model                   // ➊ marks a SwiftData model
final class FileItem : Equatable {
    // MARK: Stored properties
    @Attribute(.unique)  var id: UUID
    var bookmark: Data
    var filename: String
    var isFavorite: Bool
    var tags: [String]
    var importedAt   : Date          // creation time
    var lastOpenedAt : Date          // always at least the import time

    /// persisted scroll speed (points per second) last used for this file
    var scrollSpeed: Double = 0

    /// name of the parent folder the file was imported from
    var folderName: String = ""

    /// persisted loop marker positions (scroll Y offsets)
    var loopStartY: Double? = nil
    var loopEndY: Double? = nil

    /// relative path from the library root (nil for non-library files)
    var libraryPath: String? = nil

    /// lightweight content fingerprint for detecting moved/renamed files
    var contentHash: String? = nil

    /// number of times this tab has been opened
    var playCount: Int = 0

    /// Resolve the bookmark and *activate* its security scope
    var url: URL? {
        var stale = false
        let opts: URL.BookmarkResolutionOptions = []

        guard let u = try? URL(
                resolvingBookmarkData: bookmark,
                options: opts,
                bookmarkDataIsStale: &stale)
        else { return nil }

        // Start the scope (no-op on iOS but required on macOS)
        if !u.startAccessingSecurityScopedResource() { return nil }
        return u
    }

    init(id: UUID = .init(),
         bookmark: Data,
         filename: String,
         isFavorite: Bool = false,
         scrollSpeed: Double = 0,
         tags: [String] = [],
         folderName: String = "",
         libraryPath: String? = nil,
         contentHash: String? = nil,
         importedAt: Date = .now) {

        self.id         = id
        self.bookmark   = bookmark
        self.filename   = filename
        self.isFavorite = isFavorite
        self.tags       = tags
        self.folderName   = folderName
        self.libraryPath  = libraryPath
        self.contentHash  = contentHash
        self.importedAt   = importedAt
        self.lastOpenedAt = importedAt        // ← default to import date
        self.scrollSpeed = scrollSpeed
    }

    /// SHA-256 of the first 8 KB + file size. Fast and stable across moves/renames.
    static func fingerprint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 8192)
        guard !head.isEmpty else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        var hasher = SHA256()
        hasher.update(data: head)
        withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}
