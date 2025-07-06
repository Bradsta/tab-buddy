import Foundation

struct FileMetadata: Identifiable, Codable, Equatable {
    let id: UUID
    var bookmarkData: Data
    var isFavorite: Bool
    var tags: [String]

    var url: URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            bookmarkDataIsStale: &isStale
        )
    }

    var filename: String {
        url?.lastPathComponent ?? "Missing File"
    }

}
