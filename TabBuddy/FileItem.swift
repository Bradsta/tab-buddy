import Foundation
import SwiftData         // ⬅️ new

@Model                   // ➊ marks a SwiftData model
final class FileItem {
    // MARK: Stored properties
    @Attribute(.unique)  var id: UUID
    var bookmark: Data
    var filename: String
    var isFavorite: Bool
    var tags: [String]
    var importedAt   : Date          // creation time
    var lastOpenedAt : Date          // always at least the import time

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
         tags: [String] = [],
         importedAt: Date = .now) {

        self.id         = id
        self.bookmark   = bookmark
        self.filename   = filename
        self.isFavorite = isFavorite
        self.tags       = tags
        self.importedAt   = importedAt
        self.lastOpenedAt = importedAt        // ← default to import date
    }
}
