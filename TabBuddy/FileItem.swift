import Foundation
import SwiftData
import CryptoKit

@Model                   // ➊ marks a SwiftData model
final class FileItem : Equatable {
    // MARK: Stored properties
    // CloudKit-compatible: no unique constraints, every property has a default.
    // (`id` uniqueness is by convention — items are only created via init.)
    var id: UUID = UUID()
    var bookmark: Data = Data()
    var filename: String = ""
    var isFavorite: Bool = false
    var tags: [String] = []
    var importedAt   : Date = Date.now   // creation time
    var lastOpenedAt : Date = Date.now   // always at least the import time

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

    /// user-declared true tempo of the song (nil = trust the tab/parse).
    /// Playback practice speed is a percentage of this.
    var referenceBPM: Double? = nil

    /// user dismissed the low-confidence notice card on this file's PDF view
    var confidenceNoticeDismissed: Bool = false

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

    /// User-assigned display name for this tab, set via Rename in the library.
    /// Non-destructive: it never touches the underlying file. Additive-optional.
    var customTitle: String? = nil

    /// Instrument classification derived at conversion ("guitar", "piano", …).
    /// nil = not yet classified → treated as guitar (this is a guitar-tab app;
    /// everything predating classification is a guitar tab). Additive-optional.
    var instrument: String? = nil

    /// Display title for the library card: the user's custom title if set, else
    /// the filename with its extension stripped. (Auto-extracted `derivedTitle`
    /// is intentionally not used — extraction was too unreliable; users rename.)
    var displayTitle: String {
        if let t = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return (filename as NSString).deletingPathExtension
    }

    /// Tuning name for display: canonical preset name when recognizable
    /// ("EADGBE" → "Standard"), else the raw derived text.
    var displayTuning: String {
        if let name = GuitarTuning.canonicalName(for: tuning) { return name }
        // Show a raw tuning string only if it actually looks like one
        // (note letters) — stale metadata occasionally carries junk like a
        // time signature, which must never render in the tuning pill.
        if let t = tuning?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
           t.range(of: "^[A-Ga-g][#b]?( ?[A-Ga-g][#b]?){3,7}$", options: .regularExpression) != nil {
            return t
        }
        return "Standard"
    }

    /// Typed instrument (nil/unknown string → guitar).
    var instrumentKind: Instrument {
        instrument.flatMap { Instrument(rawValue: $0) } ?? .guitar
    }

    /// Whether the tuning is a non-standard tuning (drives the indigo pill).
    var isAltTuning: Bool {
        displayTuning.caseInsensitiveCompare("Standard") != .orderedSame
    }

    /// True if a canonical has been generated for this file.
    var hasCanonical: Bool { canonicalFilename != nil }

    /// Decoded provenance for the canonical, if any. Not persisted directly —
    /// backed by `provenanceData`.
    var provenance: Provenance? {
        get { provenanceData.flatMap { try? JSONDecoder().decode(Provenance.self, from: $0) } }
        set { provenanceData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// Resolve this item's file URL.
    ///
    /// Library items resolve as `library root + libraryPath` — the root's
    /// security scope is held open by `LibraryManager`, so no per-file scope
    /// (or bookmark) is needed. Ad-hoc imports fall back to their per-file
    /// bookmark, whose scope is activated here; callers balance with
    /// `stopAccessingSecurityScopedResource()` (a harmless no-op on
    /// library-derived URLs).
    var url: URL? {
        if let lp = libraryPath, let root = LibraryManager.activeRoot {
            return root.appendingPathComponent(lp)
        }

        var stale = false
        guard let u = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                bookmarkDataIsStale: &stale)
        else { return nil }

        if !u.startAccessingSecurityScopedResource() { return nil }
        return u
    }

    /// Check if the file is reachable (library-relative path or resolvable
    /// bookmark), without starting a security scope.
    var isBookmarkValid: Bool {
        if libraryPath != nil, LibraryManager.activeRoot != nil { return true }
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

    // (see Instrument at the bottom of this file)

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

// MARK: - Instrument

/// Instrument classification for library files. Guitar tabs are detected
/// structurally (ASCII tab / TAB staves); everything else is classified from
/// header keywords, defaulting to piano for plain notation (lead sheets).
enum Instrument: String, CaseIterable {
    case guitar, bass, ukulele, piano, voice, sax, trumpet, flute, violin, cello, drums

    /// SF Symbol for the library card affordance.
    var symbol: String {
        switch self {
        case .guitar, .bass, .ukulele: return "guitars"
        case .piano:                   return "pianokeys"
        case .voice:                   return "music.mic"
        case .drums:                   return "metronome"
        default:                       return "music.note"
        }
    }

    var label: String {
        switch self {
        case .sax: return "Sax"
        default:   return rawValue.capitalized
        }
    }

    /// Keyword classification for non-tab sources. Returns nil when nothing
    /// obviously matches (caller decides the default).
    static func detect(inText text: String) -> Instrument? {
        let lower = text.lowercased()
        let keywords: [(Instrument, [String])] = [
            (.sax,     ["saxophone", "alto sax", "tenor sax", "bari sax", " sax "]),
            (.trumpet, ["trumpet"]),
            (.flute,   ["flute"]),
            (.violin,  ["violin"]),
            (.cello,   ["cello"]),
            (.drums,   ["drum kit", "drums", "percussion"]),
            (.voice,   ["vocal", "voice", "lyrics by"]),
            (.ukulele, ["ukulele", "uke "]),
            (.bass,    ["bass guitar", "bass tab", "for bass"]),
            (.piano,   ["piano", "keyboard"]),
            (.guitar,  ["guitar"]),
        ]
        for (inst, words) in keywords {
            for w in words where lower.contains(w) { return inst }
        }
        return nil
    }
}
