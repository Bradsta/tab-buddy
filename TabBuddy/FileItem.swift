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

    /// Phase-3 storage identity. Additive/defaulted for CloudKit migration.
    var libraryID: UUID? = nil
    var storageRelativePath: String? = nil
    var byteSize: Int64 = 0
    var sourceModificationDate: Date? = nil
    var needsLibraryMigration: Bool = false

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

    /// Tuning name derived from the canonical (nil = unknown).
    /// Denormalized for fast card display / tuning filters.
    var tuning: String? = nil

    /// Foreword text (composer + comments) from the canonical, denormalized so
    /// the library search can match against the human header.
    var foreword: String? = nil

    /// User-assigned display name for this tab, set via Rename in the library.
    /// Non-destructive: it never touches the underlying file. Additive-optional.
    var customTitle: String? = nil

    /// Instrument classification derived at conversion ("guitar", "piano", …).
    /// nil = not yet classified. Additive-optional for existing libraries.
    var instrument: String? = nil
    /// A score may contain several instruments. User edits take precedence over extraction.
    var instruments: [String] = []
    var metadataEdited: Bool = false
    var composer: String? = nil
    var arranger: String? = nil
    var collectionTitle: String? = nil
    var arrangement: String? = nil
    var embeddedTitle: String? = nil
    var artist: String? = nil
    var sourceID: String? = nil
    var copyrightNotice: String? = nil
    var metadataReadVersion: Int = 0
    var backgroundProcessingVersion: Int = 0
    var sourceName: String? = nil
    var sourceURL: String? = nil
    var preferredNotation: String? = nil

    var instrumentKinds: [Instrument] {
        let values = instruments.compactMap(Instrument.init(rawValue:))
        if !values.isEmpty { return Array(Set(values)).sorted { $0.label < $1.label } }
        return [instrument.flatMap(Instrument.init(rawValue:)) ?? .unknown]
    }

    var searchableMetadata: String {
        ([embeddedTitle, artist, composer, arranger, collectionTitle, arrangement, sourceName].compactMap { $0 }
         + instrumentKinds.map(\.label)).joined(separator: " ")
    }

    struct InferredMetadata: Sendable {
        var instruments: [String] = []
        var composer: String?
        var arranger: String?
        var collection: String?
    }

    nonisolated static func inferredMetadata(from text: String) -> InferredMetadata {
        var result = InferredMetadata(instruments: Instrument.detectAll(inText: text).map(\.rawValue))
        for line in text.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            let lower = clean.lowercased()
            for prefix in ["composed by:", "composer:", "arranged by:", "arranger:", "game:", "album:"] where lower.hasPrefix(prefix) {
                let value = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                switch prefix {
                case "composed by:", "composer:": if result.composer == nil { result.composer = value }
                case "arranged by:", "arranger:": if result.arranger == nil { result.arranger = value }
                default: if result.collection == nil { result.collection = value }
                }
            }
        }
        return result
    }

    func applyInferredMetadata(_ value: InferredMetadata) {
        guard !metadataEdited else { return }
        if instruments.isEmpty && !value.instruments.isEmpty {
            instruments = value.instruments
            instrument = instruments.first
        }
        if composer == nil { composer = value.composer }
        if arranger == nil { arranger = value.arranger }
        if collectionTitle == nil { collectionTitle = value.collection }
    }

    func inferMetadata(from text: String) {
        guard !metadataEdited else { return }
        applyInferredMetadata(Self.inferredMetadata(from: text))
    }

    /// Display title for the library card: the user's custom title if set, else
    /// the filename with its extension stripped. (Auto-extracted `derivedTitle`
    /// is intentionally not used — extraction was too unreliable; users rename.)
    var displayTitle: String {
        if let t = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let title = embeddedTitle, !title.isEmpty { return title }
        return (filename as NSString).deletingPathExtension
    }

    /// Tuning name for display: canonical preset name when recognizable
    /// ("EADGBE" → "Standard"), else the raw derived text.
    var displayTuning: String {
        GuitarTuning.displayName(for: tuning)
    }

    /// First declared instrument, or unspecified.
    var instrumentKind: Instrument {
        instrumentKinds.first ?? .unknown
    }

    /// Whether the tuning is a non-standard tuning (drives the indigo pill).
    var isAltTuning: Bool {
        displayTuning != "Unknown" && displayTuning.caseInsensitiveCompare("Standard") != .orderedSame
    }

    /// True if a canonical has been generated for this file.
    var hasCanonical: Bool { canonicalFilename != nil }

    /// Decoded provenance for the canonical, if any. Not persisted directly —
    /// backed by `provenanceData`.
    var provenance: Provenance? {
        get { provenanceData.flatMap { try? JSONDecoder().decode(Provenance.self, from: $0) } }
        set { provenanceData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var effectiveRelativePath: String? { storageRelativePath ?? libraryPath }

    /// Legacy, side-effect-free bookmark resolution. New code must use
    /// `LibraryManager.acquireFile(_:)` so security scope has one owner.
    var url: URL? {
        if let lp = effectiveRelativePath, let root = LibraryManager.activeRoot {
            return root.appendingPathComponent(lp)
        }

        var stale = false
        guard let u = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                bookmarkDataIsStale: &stale)
        else { return nil }

        return u
    }

    /// Check if the file is reachable (library-relative path or resolvable
    /// bookmark), without starting a security scope.
    var isBookmarkValid: Bool {
        if effectiveRelativePath != nil, LibraryManager.activeRoot != nil { return true }
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
/// header keywords; ambiguous sources remain unspecified.
enum Instrument: String, CaseIterable {
    case guitar, bass, ukulele, piano, voice, sax, trumpet, flute, violin, cello, drums, mandolin, banjo, viola, clarinet, other, unknown

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
        case .unknown: return "Unspecified"
        case .sax: return "Saxophone"
        default:   return rawValue.capitalized
        }
    }

    static func fromMIDI(program: Int?, percussion: Bool) -> Instrument {
        if percussion { return .drums }
        guard let program else { return .unknown }
        switch program {
        case 0...7: return .piano
        case 24...31: return .guitar
        case 32...39: return .bass
        case 40: return .violin
        case 41: return .viola
        case 42: return .cello
        case 52...54: return .voice
        case 56: return .trumpet
        case 64...67: return .sax
        case 71: return .clarinet
        case 73: return .flute
        case 105: return .banjo
        default: return .other
        }
    }

    /// Keyword classification for non-tab sources. Returns nil when nothing
    /// obviously matches (caller decides the default).
    static func detect(inText text: String) -> Instrument? {
        detectAll(inText: text).first
    }

    static func detectAll(inText text: String) -> [Instrument] {
        let lower = text.lowercased()
        let keywords: [(Instrument, [String])] = [
            (.sax,     ["saxophone", "alto sax", "tenor sax", "bari sax", " sax "]),
            (.trumpet, ["trumpet"]),
            (.flute,   ["flute"]),
            (.violin,  ["violin"]),
            (.cello,   ["cello"]),
            (.drums,   ["drum kit", "drums", "percussion"]),
            (.voice,   ["vocal", "voice"]),
            (.mandolin, ["mandolin"]), (.banjo, ["banjo"]),
            (.viola, ["viola"]), (.clarinet, ["clarinet"]),
            (.ukulele, ["ukulele", "uke "]),
            (.bass,    ["bass guitar", "bass tab", "for bass"]),
            (.piano,   ["piano", "keyboard"]),
            (.guitar,  ["guitar"]),
        ]
        var result = keywords.compactMap { instrument, words in
            words.contains { word in
                lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word.trimmingCharacters(in: .whitespaces)) + "\\b", options: .regularExpression) != nil
            } ? instrument : nil
        }
        if lower.contains("bass guitar") && !lower.contains("and guitar") {
            result.removeAll { $0 == .guitar }
        }
        return result
    }
}
