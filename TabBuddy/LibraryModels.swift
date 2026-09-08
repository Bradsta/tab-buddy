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

/// Device-local intent. Account availability never silently changes this choice.
enum LibrarySyncPreference {
    static let key = "library.syncEnabled"
    static let didChange = Notification.Name("TabBuddy.librarySyncPreferenceChanged")

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        let changed = defaults.object(forKey: key) == nil || isEnabled(in: defaults) != enabled
        defaults.set(enabled, forKey: key)
        if changed { NotificationCenter.default.post(name: didChange, object: defaults) }
    }
}

struct LibraryProcessingInput: Sendable {
    var metadata: EmbeddedScoreMetadata
    var text: String?
}
