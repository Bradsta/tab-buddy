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

    /// persisted loop marker positions (scroll Y offsets) — used by the legacy
    /// scroll-based viewer / PDF auto-scroll loop.
    var loopStartY: Double? = nil
    var loopEndY: Double? = nil

    /// persisted A/B loop boundaries as measure indices (0-based, inclusive),
    /// used by the drawn Tab Player. Additive-optional; nil = no loop saved.
    var loopStartMeasure: Int? = nil
    var loopEndMeasure: Int? = nil

    /// Per-file preferred viewer for text tabs ("player" or "original").
    /// nil = default ("original"). Additive-optional; remembers the last view
    /// the user chose for this song.
    var preferredTextMode: String? = nil

    /// relative path from the library root (nil for non-library files)
    var libraryPath: String? = nil

    /// lightweight content fingerprint for detecting moved/renamed files
    var contentHash: String? = nil

    /// number of times this tab has been opened
    var playCount: Int = 0

    /// user-specified BPM for playback (nil = use auto-detected or default)
    var userBPM: Double? = nil

    // MARK: Canonical (Phase 2)

    /// Filename of the generated canonical MusicXML in `CanonicalStore`
    /// (nil = not yet converted). Additive-optional: existing stores migrate
    /// in place without touching any metadata above.
    var canonicalFilename: String? = nil

    /// JSON-encoded `Provenance` for the canonical (nil = none).
    var provenanceData: Data? = nil

    /// Converter version that produced the current canonical (0 = none).
    /// Lets us find entries needing re-derivation as the converter improves.
    var canonicalVersion: Int = 0

    /// Title derived from the file's contents at conversion (nil = use filename).
    /// Denormalized from the canonical for fast card display.
    var derivedTitle: String? = nil

    /// Tuning name derived from the canonical (nil = unknown → treat as Standard).
    /// Denormalized for fast card display / tuning filters.
    var tuning: String? = nil

    /// Foreword text (composer + comments) from the canonical, denormalized so
    /// the library search can match against the human header.
    var foreword: String? = nil

    /// Display title for the library card: derived title if present, else the
    /// filename with its extension stripped.
    var displayTitle: String {
        if let t = derivedTitle, !t.isEmpty { return t }
        return (filename as NSString).deletingPathExtension
    }

    /// Whether the tuning is a non-standard tuning (drives the indigo pill).
    var isAltTuning: Bool {
        guard let t = tuning else { return false }
        return t.caseInsensitiveCompare("Standard") != .orderedSame
    }

    /// True if a canonical has been generated for this file.
    var hasCanonical: Bool { canonicalFilename != nil }

    /// Decoded provenance for the canonical, if any. Not persisted directly —
    /// backed by `provenanceData`.
    var provenance: Provenance? {
        get { provenanceData.flatMap { try? JSONDecoder().decode(Provenance.self, from: $0) } }
        set { provenanceData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// Resolve the bookmark and *activate* its security scope.
    /// Caller is responsible for calling `stopAccessingSecurityScopedResource()` when done.
    var url: URL? {
        var stale = false
        guard let u = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                bookmarkDataIsStale: &stale)
        else { return nil }

        if !u.startAccessingSecurityScopedResource() { return nil }
        return u
    }

    /// Check if the bookmark can still be resolved, without starting a security scope.
    var isBookmarkValid: Bool {
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale)) != nil
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
        let digest = hasher.finalize()
        let hexChars = Array("0123456789abcdef".unicodeScalars)
        var hex = String()
        hex.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            hex.unicodeScalars.append(hexChars[Int(byte >> 4)])
            hex.unicodeScalars.append(hexChars[Int(byte & 0x0F)])
        }
        return hex
    }
}
