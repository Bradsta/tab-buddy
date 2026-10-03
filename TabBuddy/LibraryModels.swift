import Foundation
import SwiftData

enum LibraryMode: String, Codable, CaseIterable {
    case managedLocal
    case managedICloud
    case externalFolder
}

enum FileAvailability: String, Codable {
    case available
    case downloading
    case accessNeeded
    case missing
    case failed
}

@Model
final class LibraryDescriptor {
    var id: UUID = UUID()
    var modeRaw: String = LibraryMode.externalFolder.rawValue
    var displayName: String = "Library"
    var markerVersion: Int = 1
    var rootGeneration: Int = 1
    var createdAt: Date = Date.now

    var mode: LibraryMode {
        get { LibraryMode(rawValue: modeRaw) ?? .externalFolder }
        set { modeRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), mode: LibraryMode, displayName: String,
         markerVersion: Int = 1, rootGeneration: Int = 1) {
        self.id = id
        self.modeRaw = mode.rawValue
        self.displayName = displayName
        self.markerVersion = markerVersion
        self.rootGeneration = rootGeneration
    }
}

/// Device-local authorization and scan state. Bookmark data must never sync.
@Model
final class LibraryMount {
    var id: UUID = UUID()
    var libraryID: UUID = UUID()
    var bookmarkData: Data = Data()
    var authorized: Bool = false
    var modeOverrideRaw: String? = nil
    var lastSuccessfulScan: Date? = nil
    var rootGeneration: Int = 0

    init(libraryID: UUID, bookmarkData: Data = Data(), authorized: Bool,
         rootGeneration: Int) {
        self.libraryID = libraryID
        self.bookmarkData = bookmarkData
        self.authorized = authorized
        self.rootGeneration = rootGeneration
    }
}

/// Device-local reachability. A file can be present on one device and absent
/// or not downloaded on another, so this is deliberately outside CloudKit.
@Model
final class FilePresence {
    var id: UUID = UUID()
    var fileID: UUID = UUID()
    var availabilityRaw: String = FileAvailability.accessNeeded.rawValue
    var lastSeenAt: Date? = nil
    var failureDescription: String? = nil
    /// Why a record is `.missing` on this device (`FilePresence.Reason`). Optional
    /// and defaulted for lightweight migration; nil on older rows means unknown.
    var reasonRaw: String? = nil
    /// The record's relative path when it was found missing. A different current
    /// path (for example after another device's merge) triggers a re-check.
    var missingPath: String? = nil
    /// True once this device has had the file available or downloading. Optional
    /// for lightweight migration; older rows fall back to `lastSeenAt != nil`.
    var seenHere: Bool? = nil

    /// Only a completed full scan on this device proves a file is gone, and only for
    /// a file this device had before (`completedScan`). A file never seen here
    /// (`notSeenHere`, e.g. a copy the other device just added that iCloud Drive has
    /// not delivered) and a quick path check (`pathCheck`) never permit fingerprint joins.
    enum Reason: String { case completedScan, pathCheck, notSeenHere }

    var availability: FileAvailability {
        get { FileAvailability(rawValue: availabilityRaw) ?? .failed }
        set { availabilityRaw = newValue.rawValue }
    }

    var reason: Reason? {
        get { reasonRaw.flatMap(Reason.init(rawValue:)) }
        set { reasonRaw = newValue?.rawValue }
    }

    init(fileID: UUID, availability: FileAvailability,
         lastSeenAt: Date? = nil, failureDescription: String? = nil, reason: Reason? = nil) {
        self.fileID = fileID
        self.availabilityRaw = availability.rawValue
        self.lastSeenAt = lastSeenAt
        self.failureDescription = failureDescription
        self.reasonRaw = reason?.rawValue
        if availability == .available || availability == .downloading { seenHere = true }
    }

    var wasSeenHere: Bool {
        seenHere == true || lastSeenAt != nil || availability == .available || availability == .downloading
    }
}

@Model
final class LibraryMoveJob {
    var id: UUID = UUID()
    var libraryID: UUID = UUID()
    var destinationModeRaw: String = LibraryMode.externalFolder.rawValue
    var destinationBookmark: Data = Data()
    var completedPathsData: Data = Data()
    var startedAt: Date = Date.now
    var isComplete: Bool = false

    init(libraryID: UUID, destinationMode: LibraryMode, destinationBookmark: Data = Data()) {
        self.libraryID = libraryID
        self.destinationModeRaw = destinationMode.rawValue
        self.destinationBookmark = destinationBookmark
    }
}

struct LibraryMarker: Codable, Equatable {
    static let filename = ".tabbuddy-library.json"
    static let currentVersion = 1

    var libraryID: UUID
    var schemaVersion: Int
}

struct LibraryFileRecord: Sendable, Equatable {
    var relativePath: String
    var filename: String
    var byteSize: Int64
    var modificationDate: Date?
}

struct LibraryMoveRecord: Sendable {
    var relativePath: String
    var byteSize: Int64
    var knownFingerprint: String?
}

struct LibraryMoveResult: Sendable {
    var configuration: LibraryConfiguration
    var rootURL: URL
}

struct LibraryConfiguration: Sendable {
    var id: UUID
    var mode: LibraryMode
    var displayName: String
    var externalBookmark: Data?
}

enum LibraryFileError: LocalizedError, Equatable {
    case notConfigured
    case libraryBusy
    case iCloudUnavailable
    case accessDenied
    case invalidRelativePath
    case markerMismatch
    case fileMissing
    case unsupportedFile
    case noImportableFiles
    case copyFailed(String)
    /// The folder's `.tabbuddy-library.json` exists but is still in iCloud Drive
    /// (not downloaded) or could not be read. A new marker is never written then.
    case markerNotDownloaded
    /// iCloud Drive kept conflicting copies of the marker (for example `.tabbuddy-library 2.json`).
    case markerConflict([String])
    /// The saved folder's marker names a different library than the catalog expects.
    case markerIdentityMismatch(expected: UUID, found: UUID)
    case trashUnavailable(String)
    case externalFileDeletionNotAllowed

    var errorDescription: String? {
        switch self {
        case .libraryBusy: return "Please wait for the library storage change to finish, then import again."
        case .notConfigured: return "No library is configured."
        case .iCloudUnavailable: return "iCloud Drive is unavailable."
        case .accessDenied: return "Access to the library folder is required."
        case .invalidRelativePath: return "The file path is outside the library."
        case .markerMismatch: return "That folder belongs to a different Tab Buddy library."
        case .fileMissing: return "The file is missing from the library."
        case .noImportableFiles: return "No supported files were found in the selected folder. Choose a folder containing PDF, .txt, or Guitar Pro files. If it is in iCloud Drive, check that its contents are available in Files, then try again."
        case .unsupportedFile: return "Supported files: PDF, text, and Guitar Pro (.gp3, .gp4, .gp5, .gpx, .gp)."
        case .copyFailed(let message): return "The file could not be copied: \(message)"
        case .markerNotDownloaded:
            return "Waiting for the library marker to download from iCloud Drive. Open the folder in the Files app to download it, then try again."
        case .markerConflict(let names):
            return "iCloud Drive kept more than one library marker in this folder (\(names.joined(separator: ", "))). Use Settings → Resolve Library Marker to keep the one that matches this library; the other copy moves to the Trash."
        case .markerIdentityMismatch(let expected, let found):
            return "The folder’s library marker (\(found.uuidString.prefix(8))) doesn’t match this device’s library (\(expected.uuidString.prefix(8))). Nothing was changed. Choose the folder again in Settings."
        case .externalFileDeletionNotAllowed:
            return "TabBuddy never deletes files in a folder you chose. Remove the song from the library instead; the file stays in the folder."
        case .trashUnavailable(let path):
            return "“\(path)” couldn’t be moved to the Trash, so it wasn’t deleted. Delete it in the Files app if you still want to remove it."
        }
    }
}

/// The device-local library choice. Each option shows the songs in its own
/// location; changing options never copies, moves, or deletes song files.
/// Account availability never silently changes this choice.
enum LibraryStorageOption: String, CaseIterable, Identifiable, Sendable {
    /// Songs in the app's local folder or a folder you choose; library info stays on this device.
    case localOnly
    /// Songs in TabBuddy's iCloud library; library info syncs through iCloud.
    case iCloudOnly
    /// Songs read in place from a folder you choose; library info syncs through iCloud.
    case hybrid

    static let key = "library.storageOption"
    static let didChange = Notification.Name("TabBuddy.libraryStorageOptionChanged")
    /// Set once library info has been (or was asked to be) mirrored from this store.
    /// Local only keeps the same store; its persistent history is exported when
    /// mirroring resumes, so removals made in Local only would then reach other devices.
    static let mirroredKey = "library.storeHasMirrored"

    static func hasEverMirrored(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: mirroredKey)
    }

    static func noteMirroring(in defaults: UserDefaults = .standard) {
        if !defaults.bool(forKey: mirroredKey) { defaults.set(true, forKey: mirroredKey) }
    }

    var id: String { rawValue }
    /// Whether CloudKit mirroring of library info is requested (it still needs an iCloud account).
    var syncsMetadata: Bool { self != .localOnly }

    var title: String {
        switch self {
        case .localOnly: return "Local only"
        case .iCloudOnly: return "iCloud only"
        case .hybrid: return "Hybrid"
        }
    }

    var summary: String {
        switch self {
        case .localOnly: return "Songs and library info stay on this device."
        case .iCloudOnly: return "Songs in TabBuddy’s iCloud library. Library info syncs."
        case .hybrid: return "Songs stay in a folder you choose. Library info syncs."
        }
    }

    var symbol: String {
        switch self {
        case .localOnly: return "internaldrive"
        case .iCloudOnly: return "icloud"
        case .hybrid: return "externaldrive.badge.icloud"
        }
    }

    /// The saved choice, or one derived from the pre-option `library.syncEnabled` flag.
    /// nil means the library has never been set up on this device.
    static func stored(in defaults: UserDefaults = .standard) -> LibraryStorageOption? {
        if let raw = defaults.string(forKey: key), let option = LibraryStorageOption(rawValue: raw) { return option }
        guard defaults.object(forKey: LibrarySyncPreference.key) != nil else { return nil }
        return defaults.bool(forKey: LibrarySyncPreference.key) ? .iCloudOnly : .localOnly
    }

    /// One-time migration from the sync flag plus the active library's location:
    /// iCloud library with sync → iCloud only; app-local or chosen folder without
    /// sync → Local only. A chosen folder is never switched to Hybrid here.
    @discardableResult
    static func migrateIfNeeded(in defaults: UserDefaults = .standard, activeMode: LibraryMode?) -> LibraryStorageOption? {
        if let raw = defaults.string(forKey: key), let option = LibraryStorageOption(rawValue: raw) { return option }
        let hadFlag = defaults.object(forKey: LibrarySyncPreference.key) != nil
        let option: LibraryStorageOption
        if hadFlag {
            let synced = defaults.bool(forKey: LibrarySyncPreference.key)
            switch (synced, activeMode) {
            case (true, .externalFolder): option = .hybrid   // Not produced by earlier versions; keeps sync on.
            case (true, _): option = .iCloudOnly
            case (false, _): option = .localOnly
            }
        } else if let activeMode {
            option = activeMode == .managedICloud ? .iCloudOnly : .localOnly
        } else {
            return nil
        }
        defaults.set(option.rawValue, forKey: key)
        defaults.set(option.syncsMetadata, forKey: LibrarySyncPreference.key)
        if option.syncsMetadata { noteMirroring(in: defaults) }
        // A connection opened before any flag existed had mirroring off.
        if !hadFlag && option.syncsMetadata {
            NotificationCenter.default.post(name: LibrarySyncPreference.didChange, object: defaults)
        }
        return option
    }

    /// Saves the choice and mirrors it into the legacy flag. Posts
    /// `LibrarySyncPreference.didChange` only when metadata mirroring changes, which
    /// rebuilds the database connection against the same store files.
    static func set(_ option: LibraryStorageOption, in defaults: UserDefaults = .standard) {
        let hadFlag = defaults.object(forKey: LibrarySyncPreference.key) != nil
        let previousSync = LibrarySyncPreference.isEnabled(in: defaults)
        let previous = stored(in: defaults)
        defaults.set(option.rawValue, forKey: key)
        defaults.set(option.syncsMetadata, forKey: LibrarySyncPreference.key)
        if option.syncsMetadata { noteMirroring(in: defaults) }
        if previous != option { NotificationCenter.default.post(name: didChange, object: defaults) }
        if !hadFlag || previousSync != option.syncsMetadata {
            NotificationCenter.default.post(name: LibrarySyncPreference.didChange, object: defaults)
        }
    }
}

/// Device-local metadata-mirroring intent, derived from `LibraryStorageOption`.
/// Account availability never silently changes this choice.
enum LibrarySyncPreference {
    static let key = "library.syncEnabled"
    static let didChange = Notification.Name("TabBuddy.librarySyncPreferenceChanged")

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        LibraryStorageOption.stored(in: defaults)?.syncsMetadata ?? false
    }

    /// Compatibility entry point: turning sync on keeps a syncing option (iCloud only
    /// by default); turning it off selects Local only. Neither copies songs.
    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        let current = LibraryStorageOption.stored(in: defaults)
        let option: LibraryStorageOption = enabled
            ? (current?.syncsMetadata == true ? current! : .iCloudOnly)
            : .localOnly
        LibraryStorageOption.set(option, in: defaults)
    }
}

/// Where an option's songs live on this device. Remembered per option so that
/// switching back shows the same songs again.
struct LibraryOptionLocation: Codable, Equatable, Sendable {
    var libraryID: UUID
    var mode: LibraryMode

    private static func key(_ option: LibraryStorageOption) -> String { "library.option.\(option.rawValue).location" }

    static func remembered(for option: LibraryStorageOption, in defaults: UserDefaults) -> LibraryOptionLocation? {
        defaults.data(forKey: key(option)).flatMap { try? JSONDecoder().decode(LibraryOptionLocation.self, from: $0) }
    }

    static func remember(_ location: LibraryOptionLocation, for option: LibraryStorageOption, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(location) { defaults.set(data, forKey: key(option)) }
    }
}

struct LibraryProcessingInput: Sendable {
    var metadata: EmbeddedScoreMetadata
    var text: String?
}
