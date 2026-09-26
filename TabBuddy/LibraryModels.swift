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

    var availability: FileAvailability {
        get { FileAvailability(rawValue: availabilityRaw) ?? .failed }
        set { availabilityRaw = newValue.rawValue }
    }

    init(fileID: UUID, availability: FileAvailability,
         lastSeenAt: Date? = nil, failureDescription: String? = nil) {
        self.fileID = fileID
        self.availabilityRaw = availability.rawValue
        self.lastSeenAt = lastSeenAt
        self.failureDescription = failureDescription
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
