import Foundation
import SwiftData
import CoreData

@MainActor
final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    static let legacyBookmarkKey = "libraryDirectoryBookmark"
    nonisolated(unsafe) private(set) static var activeRoot: URL?

    private let files: LibraryFileService
    private let defaults: UserDefaults
    @Published var automaticallyProcessesLibrary: Bool {
        didSet {
            defaults.set(automaticallyProcessesLibrary, forKey: "library.automaticPreparation")
            if !automaticallyProcessesLibrary { pauseBackgroundProcessing() }
        }
    }
    private var processingAllowed = true
    private var processingTask: Task<Void, Never>?
    @Published private(set) var isProcessingLibrary = false
    let preparationProgress = LibraryPreparationProgress()
    var processingChecked: Int { preparationProgress.value.checked }
    var processingTotal: Int { preparationProgress.value.total }
    var processingPrepared: Int { preparationProgress.value.prepared }
    var processingDeferred: Int { preparationProgress.value.deferred }
    var processingFailed: Int { preparationProgress.value.failed }
    var processingLastFailure: String? { preparationProgress.value.lastFailure }
    @Published var processingSummary: String?
    private var scanTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?
    private var importingSharedFiles = false
    private var activeImports = 0
    private var pendingMutations = 0
    private var offlineTask: Task<Void, Never>?
    private var offlineRefreshNeeded = false
    private var offlineRevision = 0
    private var cachedFileIDs: Set<UUID> = []
    @Published private(set) var keepAvailableOffline = false
    @Published private(set) var isPreparingOffline = false
    @Published private(set) var offlineProcessed = 0
    @Published private(set) var offlineTotal = 0
    @Published private(set) var iCloudAvailable: Bool?
    @Published private(set) var isConfiguring = false
    @Published private(set) var activeLibraryID: UUID?
    private static let activeLibraryKey = "library.activeID"
    @Published var libraryName: String?
    @Published var mode: LibraryMode?
    @Published var accessNeeded = false
    @Published var lastError: String?
    @Published var lastSuccessfulScan: Date?
    var isConfigured: Bool { libraryName != nil }
    @Published var isRescanning: Bool = false
    let scanProgress = LibraryScanProgress()
    var rescanTotal: Int { get { scanProgress.total } set { scanProgress.total = newValue } }
    var rescanProcessed: Int { get { scanProgress.processed } set { scanProgress.processed = newValue } }
    var rescanFound: Int { get { scanProgress.found } set { scanProgress.found = newValue } }
    var rescanAdded: Int { get { scanProgress.added } set { scanProgress.added = newValue } }
    @Published var rescanSummary: String?
    private var scanGeneration = UUID()
    @Published private(set) var isRemoving = false
    @Published private(set) var removalProcessed = 0
    @Published private(set) var removalTotal = 0
    @Published var isMoving = false
    @Published var moveProcessed = 0
    @Published var moveTotal = 0
    @Published private(set) var availabilityByFileID: [UUID: FileAvailability] = [:]
    /// Device-local library choice (nil until the library is set up on this device).
    @Published private(set) var storageOption: LibraryStorageOption?
    /// True when the active songs folder is iCloud-backed (TabBuddy's iCloud library or
    /// a chosen iCloud Drive folder), so extra offline copies are meaningful.
    @Published private(set) var isCloudBackedLocation = false
    @Published private(set) var isMergingDuplicates = false
    private var mergeTask: Task<LibraryDuplicateMerger.Summary, Never>?
    private var mergeScheduleTask: Task<Void, Never>?
    private var mergeRequestedAt: Date?
    private weak var observedContext: ModelContext?
    private var remoteObservers: [NSObjectProtocol] = []
    /// The score open in the reader. Duplicate merging leaves its group for a later pass.
    var readerFileID: UUID?
    /// Moves Tutor practice takes when a duplicate catalog entry is merged away.
    var rekeyPracticeTakes: @MainActor (_ from: String, _ to: String) -> Void = { from, to in
        _ = try? TutorStore.shared.rekeyTakes(from: from, to: to)
    }
    private static let pendingScanKey = "library.pendingScanLibraryID"

    init(files: LibraryFileService = .shared, defaults: UserDefaults = .standard, automaticallyProcessesLibrary: Bool = false) {
        self.automaticallyProcessesLibrary = (defaults.object(forKey: "library.automaticPreparation") as? Bool) ?? automaticallyProcessesLibrary
        self.files = files
        self.defaults = defaults
        // Merge duplicate catalog entries after iCloud imports another device's records.
        remoteObservers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil, event.succeeded else { return }
            Task { @MainActor in self?.remoteChangesArrived() }
        })
    }

    func bootstrap(context: ModelContext) {
        observedContext = context
        let presences = (try? context.fetch(FetchDescriptor<FilePresence>())) ?? []
        var availability: [UUID: FileAvailability] = [:]
        for presence in presences { availability[presence.fileID] = presence.availability }
        availabilityByFileID = availability
        refreshStorageAvailability()
        if let descriptor = activeDescriptor(context: context) {
            apply(descriptor: descriptor, context: context)
            finishBootstrap(context: context)
            return
        }

        // Adopt the previously configured root without changing any files.
        if let bookmark = defaults.data(forKey: Self.legacyBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                  bookmarkDataIsStale: &stale) {
                let descriptor = LibraryDescriptor(mode: .externalFolder,
                                                   displayName: url.lastPathComponent)
                context.insert(descriptor)
                let mount = LibraryMount(libraryID: descriptor.id,
                                         bookmarkData: bookmark,
                                         authorized: true,
                                         rootGeneration: descriptor.rootGeneration)
                context.insert(mount)
                migrateLegacyItems(to: descriptor, root: url, context: context)
                try? context.save()
                apply(descriptor: descriptor, context: context)
                Task { try? await files.connectExternalRoot(url, libraryID: descriptor.id,
                                                            displayName: descriptor.displayName) }
                finishBootstrap(context: context)
                return
            }
        }
        libraryName = nil
        activeLibraryID = nil
        Self.activeRoot = nil
        mode = nil
        accessNeeded = false
        storageOption = LibraryStorageOption.stored(in: defaults)
    }

    /// Migrates the pre-option sync flag, remembers where this option's songs live,
    /// resumes a scan interrupted by a database reload, and merges duplicates that
    /// iCloud may have imported while the app was closed.
    private func finishBootstrap(context: ModelContext) {
        storageOption = LibraryStorageOption.migrateIfNeeded(in: defaults, activeMode: mode)
        if let option = storageOption, let id = activeLibraryID, let mode,
           LibraryOptionLocation.remembered(for: option, in: defaults) == nil {
            LibraryOptionLocation.remember(.init(libraryID: id, mode: mode), for: option, in: defaults)
        }
        if let pending = defaults.string(forKey: Self.pendingScanKey), pending == activeLibraryID?.uuidString {
            rescan(context: context)
        } else if storageOption?.syncsMetadata == true {
            scheduleDuplicateMerge(context: context, delay: .seconds(3))
        }
    }

    private func markPendingScan(_ libraryID: UUID) {
        defaults.set(libraryID.uuidString, forKey: Self.pendingScanKey)
    }

    func refreshStorageAvailability() {
        Task { iCloudAvailable = await files.isICloudAvailable() }
    }

    /// Initial setup of the app-managed library (Local only or iCloud only). With a
    /// library already set up, this switches options instead; switching never copies songs.
    func configureManaged(context: ModelContext, useICloud: Bool = true) {
        guard !isProcessingLibrary, !isRemoving, !isConfiguring, !isRescanning, !isMoving else { return }
        if activeDescriptor(context: context) != nil {
            _ = switchStorageOption(to: useICloud ? .iCloudOnly : .localOnly, context: context)
            return
        }
        isConfiguring = true
        Task {
            defer { isConfiguring = false }
            do {
                let available = await files.isICloudAvailable()
                iCloudAvailable = available
                let mode: LibraryMode = useICloud && available ? .managedICloud : .managedLocal
                let id = try await files.existingManagedLibraryID(mode: mode) ?? UUID()
                let descriptor = LibraryDescriptor(id: id, mode: mode, displayName: LibraryFileService.managedFolderName)
                let root = try await files.configureManagedLibrary(id: descriptor.id, mode: mode)
                // Publish the descriptor only after its folder is usable.
                context.insert(descriptor)
                let mount = LibraryMount(libraryID: descriptor.id, authorized: true,
                                         rootGeneration: descriptor.rootGeneration)
                mount.modeOverrideRaw = mode.rawValue
                context.insert(mount)
                try context.save()
                Self.activeRoot = root
                accessNeeded = false
                lastError = nil
                markUnrootedLegacyItems(context: context)
                apply(descriptor: descriptor, context: context)
                let option: LibraryStorageOption = mode == .managedICloud ? .iCloudOnly : .localOnly
                LibraryOptionLocation.remember(.init(libraryID: id, mode: mode), for: option, in: defaults)
                markPendingScan(id)
                // Turning on mirroring rebuilds the connection; the scan then resumes from bootstrap.
                if !option.syncsMetadata { rescan(context: context) }
                LibraryStorageOption.set(option, in: defaults)
                storageOption = option
                if mode != .managedICloud { importPendingSharedFiles(context: context) }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Adopt the exact selected folder and read its songs in place, as the location of
    /// Local only (a folder you choose) or Hybrid. Never copies or creates a child folder.
    func useExistingFolder(url: URL, context: ModelContext, option: LibraryStorageOption = .localOnly) {
        guard !isProcessingLibrary, !isRemoving, !isConfiguring, !isMoving, !isRescanning, !isPreparingOffline, activeImports == 0 else { return }
        let option: LibraryStorageOption = option == .iCloudOnly ? .localOnly : option
        isConfiguring = true
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                isConfiguring = false
            }
            do {
                let id = try LibraryFileService.existingLibraryID(at: url) ?? UUID()
                let descriptors = try context.fetch(FetchDescriptor<LibraryDescriptor>())
                let descriptor = descriptors.first { $0.id == id }
                    ?? LibraryDescriptor(id: id, mode: .externalFolder, displayName: url.lastPathComponent)
                let bookmark = try await files.connectExternalRoot(url, libraryID: id, displayName: url.lastPathComponent)
                if !descriptors.contains(where: { $0.id == id }) { context.insert(descriptor) }
                let mounts = try context.fetch(FetchDescriptor<LibraryMount>())
                let mount = mounts.first { $0.libraryID == id }
                    ?? LibraryMount(libraryID: id, authorized: true, rootGeneration: descriptor.rootGeneration)
                if !mounts.contains(where: { $0.libraryID == id }) { context.insert(mount) }
                mount.bookmarkData = bookmark
                mount.authorized = true
                mount.modeOverrideRaw = LibraryMode.externalFolder.rawValue
                try context.save()
                defaults.set(bookmark, forKey: Self.legacyBookmarkKey)
                Self.activeRoot = url
                apply(descriptor: descriptor, context: context)
                libraryName = url.lastPathComponent
                lastError = nil
                accessNeeded = false
                LibraryOptionLocation.remember(.init(libraryID: id, mode: .externalFolder), for: option, in: defaults)
                let reloads = (LibraryStorageOption.stored(in: defaults)?.syncsMetadata ?? false) != option.syncsMetadata
                markPendingScan(id)
                if !reloads { rescan(context: context) }
                LibraryStorageOption.set(option, in: defaults)
                storageOption = option
            } catch {
                lastError = error.localizedDescription
                if let previous = activeDescriptor(context: context) { apply(descriptor: previous, context: context) }
            }
        }
    }

    /// Renews this device's authorization for the current library folder (Reconnect
    /// Folder, or choosing a synced Hybrid folder on another device). Keeps the option.
    func configureExternal(url: URL, context: ModelContext) {
        guard !isProcessingLibrary, !isRemoving, !isConfiguring, !isMoving, !isRescanning else { return }
        isConfiguring = true
        let existingDescriptor = activeDescriptor(context: context)
        let descriptor = existingDescriptor
            ?? LibraryDescriptor(mode: .externalFolder, displayName: url.lastPathComponent)
        Task {
            defer { isConfiguring = false }
            do {
                let bookmark = try await files.connectExternalRoot(
                    url, libraryID: descriptor.id, displayName: url.lastPathComponent,
                    mayCreateMarker: existingDescriptor == nil
                )
                if existingDescriptor == nil { context.insert(descriptor) }
                if descriptor.mode != .managedICloud {
                    descriptor.mode = .externalFolder
                    descriptor.displayName = url.lastPathComponent
                }
                let mounts = (try? context.fetch(FetchDescriptor<LibraryMount>())) ?? []
                if let mount = mounts.first(where: { $0.libraryID == descriptor.id }) {
                    mount.modeOverrideRaw = LibraryMode.externalFolder.rawValue
                    mount.bookmarkData = bookmark
                    mount.authorized = true
                    mount.rootGeneration = descriptor.rootGeneration
                } else {
                    let mount = LibraryMount(libraryID: descriptor.id,
                                             bookmarkData: bookmark,
                                             authorized: true,
                                             rootGeneration: descriptor.rootGeneration)
                    mount.modeOverrideRaw = LibraryMode.externalFolder.rawValue
                    context.insert(mount)
                }
                defaults.set(bookmark, forKey: Self.legacyBookmarkKey)
                Self.activeRoot = url
                try context.save()
                markUnrootedLegacyItems(context: context)
                apply(descriptor: descriptor, context: context)
                lastError = nil
                let option = storageOption == .hybrid ? LibraryStorageOption.hybrid : .localOnly
                LibraryOptionLocation.remember(.init(libraryID: descriptor.id, mode: .externalFolder), for: option, in: defaults)
                if storageOption != option {
                    LibraryStorageOption.set(option, in: defaults)
                    storageOption = option
                }
                rescan(context: context)
            } catch {
                lastError = error.localizedDescription
                accessNeeded = true
            }
        }
    }

    // MARK: - Storage options

    enum StorageSwitchResult: Equatable { case started, needsFolder, unavailable, busy, unchanged }

    private var isBusyForStorageChange: Bool {
        isProcessingLibrary || isRemoving || isConfiguring || isRescanning || isMoving || isPreparingOffline || activeImports > 0 || isMergingDuplicates
    }

    private var currentLocation: LibraryOptionLocation? {
        guard let activeLibraryID, let mode else { return nil }
        return .init(libraryID: activeLibraryID, mode: mode)
    }

    /// Where `option` would show songs on this device. nil for Hybrid means a folder must be chosen.
    /// A managed location whose library ID is not known yet is returned with a placeholder ID.
    func plannedLocation(for option: LibraryStorageOption) -> LibraryOptionLocation? {
        if let remembered = LibraryOptionLocation.remembered(for: option, in: defaults) { return remembered }
        switch option {
        case .iCloudOnly:
            return .init(libraryID: Self.unresolvedLibraryID, mode: .managedICloud)
        case .localOnly:
            if let current = currentLocation, current.mode == .externalFolder { return current }
            return .init(libraryID: Self.unresolvedLibraryID, mode: .managedLocal)
        case .hybrid:
            if let current = currentLocation, current.mode == .externalFolder { return current }
            return nil
        }
    }

    private static let unresolvedLibraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Human-readable songs location for confirmations and Settings.
    func locationName(_ location: LibraryOptionLocation?, context: ModelContext) -> String {
        guard let location else { return "a folder you choose" }
        switch location.mode {
        case .managedLocal: return "the app library on this device"
        case .managedICloud: return "TabBuddy’s iCloud library"
        case .externalFolder:
            let descriptors = (try? context.fetch(FetchDescriptor<LibraryDescriptor>())) ?? []
            let name = descriptors.first(where: { $0.id == location.libraryID })?.displayName
                ?? (location.libraryID == activeLibraryID ? libraryName : nil) ?? "your folder"
            return "“\(name)”"
        }
    }

    /// The confirmation shown before switching. Songs are never copied.
    func switchConfirmation(to option: LibraryStorageOption, context: ModelContext) -> String {
        let old = locationName(currentLocation, context: context)
        if let planned = plannedLocation(for: option), planned == currentLocation {
            return option.syncsMetadata
                ? "Songs aren’t copied or moved. The library keeps showing songs in \(old), and library info syncs through iCloud."
                : "Songs aren’t copied or moved. The library keeps showing songs in \(old), and library info stays on this device."
        }
        guard let planned = plannedLocation(for: option) else {
            return "Songs aren’t copied. Choose the folder that holds your songs; the library will show the songs in it. Songs in \(old) stay where they are."
        }
        return "Songs aren’t copied. The library will show songs in \(locationName(planned, context: context)). Songs in \(old) stay where they are."
    }

    /// Switch this device's library option. Each option shows the songs in its own
    /// location; nothing is copied, moved, or deleted. Library info mirroring follows
    /// the option (the database connection reloads against the same store files).
    @discardableResult
    func switchStorageOption(to option: LibraryStorageOption, context: ModelContext) -> StorageSwitchResult {
        guard !isBusyForStorageChange else { return .busy }
        guard option != storageOption else { return .unchanged }
        if option == .iCloudOnly && iCloudAvailable != true {
            lastError = LibraryFileError.iCloudUnavailable.localizedDescription
            return .unavailable
        }
        guard let planned = plannedLocation(for: option) else { return .needsFolder }
        let previous = currentLocation
        isConfiguring = true
        Task {
            defer { isConfiguring = false }
            do {
                var location = planned
                if location.libraryID == Self.unresolvedLibraryID {
                    let id = try await files.existingManagedLibraryID(mode: location.mode) ?? UUID()
                    location = .init(libraryID: id, mode: location.mode)
                }
                try await activate(location, context: context)
                LibraryOptionLocation.remember(location, for: option, in: defaults)
                let reloads = (storageOption?.syncsMetadata ?? false) != option.syncsMetadata
                let changedLocation = location != previous
                if changedLocation { markPendingScan(location.libraryID) }
                if changedLocation && !reloads { rescan(context: context) }
                LibraryStorageOption.set(option, in: defaults)
                storageOption = option
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
        return .started
    }

    /// Local only: show the app's own library folder instead of a chosen folder.
    /// The chosen folder and its songs stay as they are.
    func useAppFolder(context: ModelContext) {
        guard !isBusyForStorageChange, storageOption == .localOnly, mode == .externalFolder else { return }
        isConfiguring = true
        Task {
            defer { isConfiguring = false }
            do {
                let id = try await files.existingManagedLibraryID(mode: .managedLocal) ?? UUID()
                let location = LibraryOptionLocation(libraryID: id, mode: .managedLocal)
                try await activate(location, context: context)
                LibraryOptionLocation.remember(location, for: .localOnly, in: defaults)
                markPendingScan(id)
                rescan(context: context)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Point this device at an existing location without touching any song file.
    private func activate(_ location: LibraryOptionLocation, context: ModelContext) async throws {
        let descriptors = try context.fetch(FetchDescriptor<LibraryDescriptor>())
        var descriptor = descriptors.first { $0.id == location.libraryID }
        switch location.mode {
        case .managedLocal, .managedICloud:
            let root = try await files.configureManagedLibrary(id: location.libraryID, mode: location.mode)
            if descriptor == nil {
                let created = LibraryDescriptor(id: location.libraryID, mode: location.mode,
                                                displayName: LibraryFileService.managedFolderName)
                context.insert(created)
                descriptor = created
            }
            Self.activeRoot = root
        case .externalFolder:
            guard descriptor != nil else { throw LibraryFileError.notConfigured }
        }
        guard let descriptor else { throw LibraryFileError.notConfigured }
        let mounts = try context.fetch(FetchDescriptor<LibraryMount>())
        let mount = mounts.first { $0.libraryID == location.libraryID } ?? {
            let created = LibraryMount(libraryID: location.libraryID, authorized: location.mode != .externalFolder,
                                       rootGeneration: descriptor.rootGeneration)
            context.insert(created)
            return created
        }()
        mount.modeOverrideRaw = location.mode.rawValue
        if location.mode != .externalFolder { mount.authorized = true }
        try context.save()
        apply(descriptor: descriptor, context: context)
    }

    // MARK: - Visibility and removal

    /// Songs whose file is not in this device's folder are hidden, never deleted:
    /// a completed scan marks them missing, and in Hybrid a record synced from another
    /// device stays hidden until this device confirms the file.
    nonisolated static func isShown(presence: FileAvailability?, inActiveLibrary: Bool,
                                    option: LibraryStorageOption?) -> Bool {
        if presence == .missing { return false }
        if presence == nil && inActiveLibrary && option == .hybrid { return false }
        return true
    }

    func isShownOnThisDevice(_ item: FileItem) -> Bool {
        Self.isShown(presence: availabilityByFileID[item.id],
                     inActiveLibrary: item.libraryID != nil && item.libraryID == activeLibraryID,
                     option: storageOption)
    }

    struct RemovalConfirmation: Equatable {
        var title: String
        var message: String
        var button: String
    }

    /// Removal wording follows what actually happens: a chosen folder keeps its files
    /// (catalog only); synced options remove library info on every device.
    nonisolated static func removalConfirmation(count: Int, all: Bool, option: LibraryStorageOption?,
                                                mode: LibraryMode?, folderName: String?) -> RemovalConfirmation {
        let songs = count == 1 ? "1 song" : "\(count) songs"
        let folder = folderName.map { "“\($0)”" } ?? "your folder"
        if mode == .externalFolder {
            let title = all ? "Remove all songs from the library?" : "Remove \(songs) from the library?"
            let message = option == .hybrid
                ? "Library info for these songs is removed on all your devices that use this library. Files stay in \(folder). Songs not in this device’s folder aren’t affected."
                : "Files stay in \(folder). Rescan Library finds them again."
            return .init(title: title, message: message, button: "Remove from Library")
        }
        let title = all ? "Delete all songs?" : "Delete \(songs)?"
        let message = option == .iCloudOnly || mode == .managedICloud
            ? "This deletes the song files from TabBuddy’s iCloud library and removes their library info on all your devices."
            : "This deletes the song files from the library on this device, including songs in selected folders."
        return .init(title: title, message: message, button: "Delete")
    }

    func removalConfirmation(count: Int, all: Bool) -> RemovalConfirmation {
        Self.removalConfirmation(count: count, all: all, option: storageOption, mode: mode, folderName: libraryName)
    }

    func acquireFile(_ item: FileItem) async throws -> FileAccessLease {
        if let relative = item.effectiveRelativePath {
            return try await files.acquireFile(relativePath: relative, allowCloudPlaceholder: true)
        }
        guard !item.bookmark.isEmpty else { throw LibraryFileError.fileMissing }
        return try await files.acquireLegacyFile(bookmark: item.bookmark)
    }

    func importFiles(_ urls: [URL], context: ModelContext,
                     progress: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> Int {
        await finishScanBeforeMutation()
        guard activeImports == 0, !isRemoving, !isMoving, !isConfiguring else { throw LibraryFileError.libraryBusy }
        guard let descriptor = activeDescriptor(context: context) else {
            throw LibraryFileError.notConfigured
        }
        activeImports += 1
        defer { activeImports -= 1 }
        defer {
            refreshOfflineCopies(context: context)
            Task { startBackgroundProcessing(context: context) }
        }
        let commit: @MainActor @Sendable ([LibraryFileRecord]) async throws -> Void = { records in
            await self.reconcile(records: records, descriptor: descriptor, context: context, isCompleteScan: false, readMetadata: false)
            try context.save()
        }
        let records = try await files.importFiles(urls, progress: progress, onImported: { records in
            // Cancellation must not abandon copies already committed on disk.
            try await Task { @MainActor in try await commit(records) }.value
        })
        return records.count
    }

    func saveMetadata(_ metadata: EmbeddedScoreMetadata, for item: FileItem, context: ModelContext) async throws {
        await finishScanBeforeMutation()
        guard !isMoving, !isConfiguring, !isRemoving, !isRescanning else { throw LibraryFileError.libraryBusy }
        guard let path = item.effectiveRelativePath, item.libraryID == activeLibraryID else { throw LibraryFileError.notConfigured }
        activeImports += 1
        defer { activeImports -= 1 }
        try await files.writeEmbeddedMetadata(metadata, relativePath: path)
        item.applyEmbeddedMetadata(metadata, overwrite: true)
        item.metadataEdited = true
        item.metadataReadVersion = 1
        item.contentHash = nil
        item.canonicalVersion = 0
        item.backgroundProcessingVersion = 0
        try context.save()
        refreshOfflineCopies(context: context)
    }

    func importPendingSharedFiles(context: ModelContext) {
        guard isConfigured, !importingSharedFiles,
              let pending = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.com.gamicarts.TabBuddy.shared")?
                .appendingPathComponent("PendingImports"),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: pending, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ), !urls.isEmpty else { return }
        importingSharedFiles = true
        Task {
            defer { importingSharedFiles = false }
            do {
                _ = try await importFiles(urls, context: context)
                for url in urls { try? FileManager.default.removeItem(at: url) }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func migrateLegacyImports(context: ModelContext) {
        guard let descriptor = activeDescriptor(context: context) else { return }
        let legacy = ((try? context.fetch(FetchDescriptor<FileItem>())) ?? [])
            .filter { $0.needsLibraryMigration && !$0.bookmark.isEmpty }
        guard !legacy.isEmpty else { return }
        Task {
            for item in legacy {
                do {
                    let source = try await files.acquireLegacyFile(bookmark: item.bookmark)
                    let records = try await files.importFiles([source.url])
                    source.close()
                    guard let record = records.first else { continue }
                    item.libraryID = descriptor.id
                    item.storageRelativePath = record.relativePath
                    item.libraryPath = record.relativePath
                    item.filename = record.filename
                    item.folderName = parentName(of: record.relativePath)
                    item.byteSize = record.byteSize
                    item.sourceModificationDate = record.modificationDate
                    item.needsLibraryMigration = false
                    upsertPresence(fileID: item.id, availability: .available,
                                   seenAt: .now, context: context)
                    try context.save()
                } catch {
                    lastError = error.localizedDescription
                }
            }
            TagIndexer.rebuild(in: context)
        }
    }

    func rescan(context: ModelContext) {
        guard !isRemoving, !isRescanning, !isMoving, activeImports == 0, let descriptor = activeDescriptor(context: context) else { return }
        pauseBackgroundProcessing()
        isRescanning = true
        rescanProcessed = 0
        rescanTotal = 0
        rescanFound = 0
        rescanAdded = 0
        rescanSummary = nil
        let generation = UUID()
        scanGeneration = generation
        scanTask = Task {
            do {
                // Cancellation is a request, not completion. Finish the current
                // preparation read/commit before enumerating or changing catalog state.
                await processingTask?.value
                try Task.checkCancellation()
                let initial = ((try? context.fetch(FetchDescriptor<FileItem>())) ?? []).filter { $0.libraryID == descriptor.id || $0.libraryID == nil }
                let initialIDs = Set(initial.map(\.id))
                let initialPaths = Set(initial.compactMap(\.effectiveRelativePath))
                let discovery = LibraryDiscoveryIndex(paths: initialPaths)
                let commitBatch: @MainActor @Sendable ([LibraryFileRecord]) async throws -> Void = { batch in
                    // Discovery only adds unknown paths. Reconcile existing metadata once,
                    // after enumeration, instead of rebuilding the whole catalog per batch.
                    let added = discovery.insert(batch, libraryID: descriptor.id, context: context)
                    self.availabilityByFileID.merge(discovery.drainInsertedPresence()) { _, new in new }
                    if added > 0 { try context.save() }
                    self.rescanAdded += added
                    self.rescanProcessed += batch.count
                    try await Task.sleep(for: .milliseconds(25))
                }
                let records = try await files.scan(onDiscovered: { count in
                    Task { @MainActor in
                        guard self.scanGeneration == generation, self.isRescanning, self.rescanTotal == 0 else { return }
                        self.rescanFound = max(self.rescanFound, count)
                    }
                }, onBatch: { batch in
                    // Retain a delivered discovery batch even if cancellation arrives.
                    try await Task { @MainActor in try await commitBatch(batch) }.value
                })
                guard !Task.isCancelled else { throw CancellationError() }
                rescanFound = records.count
                rescanTotal = records.count
                let newPaths = Set(records.map(\.relativePath)).subtracting(initialPaths)
                let reconciled = await reconcile(records: records, descriptor: descriptor, context: context,
                                                 provisionalPaths: newPaths, reportProgress: false)
                try Task.checkCancellation()
                guard reconciled else { throw LibraryFileError.copyFailed(lastError ?? "Could not save the library catalog.") }
                rescanProcessed = records.count
                rescanAdded = ((try? context.fetch(FetchDescriptor<FileItem>())) ?? []).filter { $0.libraryID == descriptor.id && !initialIDs.contains($0.id) }.count
                rescanSummary = "Scan complete: \(rescanProcessed) checked · \(rescanAdded) added to library · \(rescanProcessed - rescanAdded) existing"
                lastSuccessfulScan = .now
                updateMountScanDate(descriptor.id, context: context)
                if defaults.string(forKey: Self.pendingScanKey) == descriptor.id.uuidString {
                    defaults.removeObject(forKey: Self.pendingScanKey)
                }
                accessNeeded = false
                lastError = nil
                refreshOfflineCopies(context: context)
                scheduleDuplicateMerge(context: context, delay: .milliseconds(500))
            } catch is CancellationError {
                // Completed catalog batches are retained; unprocessed files are never marked missing.
                rescanSummary = "Scan cancelled: \(rescanProcessed) checked · \(rescanAdded) added to library"
            } catch {
                lastError = error.localizedDescription
                if error as? LibraryFileError == .accessDenied { accessNeeded = true }
            }
            isRescanning = false
            startBackgroundProcessing(context: context)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func finishScanBeforeMutation() async {
        pendingMutations += 1
        defer { pendingMutations -= 1 }
        pauseBackgroundProcessing()
        await processingTask?.value
        mergeScheduleTask?.cancel()
        if let mergeTask {
            mergeTask.cancel()
            _ = await mergeTask.value
        }
        guard isRescanning else { return }
        scanTask?.cancel()
        await scanTask?.value
    }

    /// Remove a selection with one presence lookup and one tag-index rebuild.
    /// External-folder removal affects the catalog only, as with single removal.
    func removeItems(_ items: [FileItem], context: ModelContext) async {
        await finishScanBeforeMutation()
        guard !isRemoving, !isMoving, !isConfiguring, !isRescanning, !isPreparingOffline, activeImports == 0 else { return }
        isRemoving = true
        activeImports += 1
        removalProcessed = 0
        removalTotal = items.count
        defer { isRemoving = false; activeImports -= 1 }
        lastError = nil
        let deleteFiles = mode != .externalFolder
        // In Hybrid, a song hidden here may be present on another device: never remove it from here.
        let items = items.filter { $0.modelContext != nil && (storageOption != .hybrid || isShownOnThisDevice($0)) }
        removalTotal = items.count
        do {
            let presences = try context.fetch(FetchDescriptor<FilePresence>())
            let byFile = Dictionary(grouping: presences, by: \.fileID)
            var availability = availabilityByFileID
            var failures = 0
            var firstFailure: String?
            for (index, item) in items.enumerated() {
                do {
                    // A song already missing from the folder has no file to delete.
                    if deleteFiles && availability[item.id] != .missing {
                        guard let relative = item.effectiveRelativePath else { throw LibraryFileError.invalidRelativePath }
                        try await files.deleteUnderlyingFile(relativePath: relative)
                    }
                    for presence in byFile[item.id] ?? [] { context.delete(presence) }
                    availability.removeValue(forKey: item.id)
                    context.delete(item)
                } catch {
                    failures += 1
                    if firstFailure == nil { firstFailure = error.localizedDescription }
                }
                if (index + 1) % 250 == 0 {
                    try context.save()
                    removalProcessed = index + 1
                    await Task.yield()
                }
            }
            try context.save()
            availabilityByFileID = availability
            TagIndexer.rebuild(in: context)
            removalProcessed = items.count
            if failures > 0 { lastError = "Could not remove \(failures) files. \(firstFailure ?? "")" }
        } catch { lastError = error.localizedDescription }
    }

    private func removeFromCatalog(_ item: FileItem, context: ModelContext) {
        if let presence = presence(for: item.id, context: context) { context.delete(presence) }
        availabilityByFileID.removeValue(forKey: item.id)
        context.delete(item)
        try? context.save()
        TagIndexer.rebuild(in: context)
    }

    func deleteUnderlyingFile(_ item: FileItem, context: ModelContext) async throws {
        await finishScanBeforeMutation()
        guard !isRemoving, !isMoving, !isConfiguring, activeImports == 0, item.modelContext != nil else { throw LibraryFileError.libraryBusy }
        guard let relative = item.effectiveRelativePath else { throw LibraryFileError.invalidRelativePath }
        isRemoving = true
        activeImports += 1
        defer { isRemoving = false; activeImports -= 1 }
        do {
            try await files.deleteUnderlyingFile(relativePath: relative)
            removeFromCatalog(item, context: context)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Whole path-component matching includes descendants but excludes sibling prefixes.
    static func folderItems(in items: [FileItem], relativeFolder: String) -> [FileItem] {
        let prefix = relativeFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        return items.filter { $0.effectiveRelativePath?.hasPrefix(prefix) == true }
    }

    func moveLibrary(to destinationMode: LibraryMode, externalParent: URL? = nil,
                     context: ModelContext) {
        guard !isProcessingLibrary, !isRemoving, !isMoving, !isConfiguring, !isRescanning, !isPreparingOffline, let descriptor = activeDescriptor(context: context),
              destinationMode != mode || destinationMode == .externalFolder else { return }
        isMoving = true
        moveProcessed = 0
        moveTotal = 0

        moveTask = Task {
            do {
                // Moving from the live filesystem manifest prevents a stale or
                // cancelled catalog scan from silently omitting source files.
                let manifest = try await files.scan()
                try Task.checkCancellation()
                let items = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
                var fingerprintByPath: [String: String] = [:]
                for item in items where item.libraryID == descriptor.id {
                    if let path = item.effectiveRelativePath,
                       let fingerprint = item.contentHash {
                        fingerprintByPath[path] = fingerprint
                    }
                }
                let records = manifest.map {
                    LibraryMoveRecord(relativePath: $0.relativePath,
                                      byteSize: $0.byteSize,
                                      knownFingerprint: fingerprintByPath[$0.relativePath])
                }
                moveTotal = records.count
                let job = LibraryMoveJob(libraryID: descriptor.id,
                                         destinationMode: destinationMode)
                context.insert(job)
                try context.save()
                let checkpointWriter = LibraryMoveCheckpointWriter(job: job,
                                                                   context: context)
                let result = try await files.moveLibrary(
                    to: destinationMode, externalParent: externalParent,
                    records: records, libraryID: descriptor.id
                ) { path, done, total in
                    await checkpointWriter.record(path: path, done: done, total: total)
                    await MainActor.run {
                        self.moveProcessed = done
                        self.moveTotal = total
                    }
                }
                // Keeping a local copy is a device choice; do not turn off iCloud on other devices.
                if destinationMode == .managedICloud || descriptor.mode != .managedICloud {
                    descriptor.mode = result.configuration.mode
                }
                if destinationMode == .managedICloud || descriptor.mode != .managedICloud {
                    descriptor.displayName = result.configuration.displayName
                    descriptor.rootGeneration += 1
                }
                let mounts = (try? context.fetch(FetchDescriptor<LibraryMount>())) ?? []
                if let mount = mounts.first(where: { $0.libraryID == descriptor.id }) {
                    mount.modeOverrideRaw = destinationMode == .managedICloud ? nil : destinationMode.rawValue
                    mount.bookmarkData = result.configuration.externalBookmark ?? Data()
                    mount.authorized = true
                    mount.rootGeneration = descriptor.rootGeneration
                } else {
                    let mount = LibraryMount(libraryID: descriptor.id,
                        bookmarkData: result.configuration.externalBookmark ?? Data(),
                        authorized: true, rootGeneration: descriptor.rootGeneration)
                    mount.modeOverrideRaw = destinationMode == .managedICloud ? nil : destinationMode.rawValue
                    context.insert(mount)
                }
                job.isComplete = true
                Self.activeRoot = result.rootURL
                try context.save()
                apply(descriptor: descriptor, context: context)
                lastError = nil
                // Copying is explicit. The copy becomes this option's location; copying
                // out of TabBuddy's iCloud library into a folder keeps library info syncing (Hybrid).
                let current = storageOption ?? .localOnly
                let option: LibraryStorageOption
                switch destinationMode {
                case .managedICloud: option = .iCloudOnly
                case .managedLocal: option = .localOnly
                case .externalFolder: option = current == .iCloudOnly ? .hybrid : current
                }
                LibraryOptionLocation.remember(.init(libraryID: descriptor.id, mode: destinationMode), for: option, in: defaults)
                LibraryStorageOption.set(option, in: defaults)
                storageOption = option
            } catch {
                if !(error is CancellationError) {
                    lastError = error.localizedDescription
                }
            }
            isMoving = false
            moveTask = nil
        }
    }

    // MARK: - Duplicate merging (library info synced from several devices)

    private func remoteChangesArrived() {
        guard storageOption?.syncsMetadata == true, let context = observedContext else { return }
        scheduleDuplicateMerge(context: context, delay: .seconds(5))
    }

    /// Debounced: a burst of iCloud imports produces one pass, but a pass still runs
    /// at least every 30 seconds while imports keep arriving.
    func scheduleDuplicateMerge(context: ModelContext, delay: Duration = .seconds(5)) {
        if mergeScheduleTask != nil, let requested = mergeRequestedAt, Date().timeIntervalSince(requested) > 30 { return }
        if mergeScheduleTask == nil { mergeRequestedAt = Date() }
        mergeScheduleTask?.cancel()
        mergeScheduleTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.mergeScheduleTask = nil
            self.mergeRequestedAt = nil
            await self.mergeDuplicates(context: context)
        }
    }

    /// Runs one merge pass on the main actor in bounded, yielding batches. Library
    /// work (imports, scans, removal, storage changes) takes priority; a busy library
    /// reschedules the pass.
    @discardableResult
    func mergeDuplicates(context: ModelContext) async -> LibraryDuplicateMerger.Summary? {
        guard mergeTask == nil else { return nil }
        // Preparation (including a user-started Prepare Library) is not interrupted; merge afterwards.
        if isRescanning || isRemoving || isMoving || isConfiguring || isProcessingLibrary || activeImports > 0 || pendingMutations > 0 {
            scheduleDuplicateMerge(context: context, delay: .seconds(10))
            return nil
        }
        isMergingDuplicates = true
        let presence = availabilityByFileID
        let protected: Set<UUID> = readerFileID.map { [$0] } ?? []
        let libraryID = activeLibraryID
        let task = Task { @MainActor in
            await LibraryDuplicateMerger.merge(context: context, presence: presence,
                                               fingerprintLibraryID: libraryID, protectedIDs: protected)
        }
        mergeTask = task
        let summary = await task.value
        mergeTask = nil
        isMergingDuplicates = false
        applyMergeResult(summary, context: context)
        if storageOption == .hybrid { await verifyUnknownPresence(context: context) }
        startBackgroundProcessing(context: context)
        return summary
    }

    /// Follow merged records everywhere a file ID is used outside the synced catalog.
    private func applyMergeResult(_ summary: LibraryDuplicateMerger.Summary, context: ModelContext) {
        guard !summary.remapped.isEmpty else { return }
        let presences = (try? context.fetch(FetchDescriptor<FilePresence>())) ?? []
        var availability: [UUID: FileAvailability] = [:]
        for presence in presences { availability[presence.fileID] = presence.availability }
        availabilityByFileID = availability
        for (old, new) in summary.remapped {
            if cachedFileIDs.remove(old) != nil { cachedFileIDs.insert(new) }
            rekeyPracticeTakes(old.uuidString, new.uuidString)
            for prefix in ["guitarPro.practice.", "practice.unreviewedTake."] {
                guard let value = defaults.object(forKey: prefix + old.uuidString) else { continue }
                if defaults.object(forKey: prefix + new.uuidString) == nil { defaults.set(value, forKey: prefix + new.uuidString) }
                defaults.removeObject(forKey: prefix + old.uuidString)
            }
            if readerFileID == old { readerFileID = new }
        }
    }

    /// In Hybrid, records synced from another device have no presence here yet. Check
    /// whether their files are in this device's folder (downloaded or not) so present
    /// songs show and the rest stay hidden. Nothing is deleted.
    func verifyUnknownPresence(context: ModelContext) async {
        guard storageOption == .hybrid, !accessNeeded, let libraryID = activeLibraryID else { return }
        let optionalID: UUID? = libraryID
        let items = ((try? context.fetch(FetchDescriptor<FileItem>(predicate: #Predicate { $0.libraryID == optionalID }))) ?? [])
            .filter { availabilityByFileID[$0.id] == nil && $0.effectiveRelativePath != nil }
        guard !items.isEmpty else { return }
        let paths = items.compactMap(\.effectiveRelativePath)
        guard let present = try? await files.existingPaths(paths), activeLibraryID == libraryID else { return }
        var updated = availabilityByFileID
        let now = Date.now
        for item in items where item.modelContext != nil && updated[item.id] == nil {
            let found = item.effectiveRelativePath.map(present.contains) ?? false
            let availability: FileAvailability = found ? .available : .missing
            context.insert(FilePresence(fileID: item.id, availability: availability, lastSeenAt: found ? now : nil))
            updated[item.id] = availability
        }
        try? context.save()
        availabilityByFileID = updated
    }

    /// Reloading SwiftData must not leave work holding the previous model context.
    func finishDatabaseWork() async {
        pauseBackgroundProcessing()
        await processingTask?.value
        mergeScheduleTask?.cancel()
        mergeScheduleTask = nil
        if let mergeTask {
            mergeTask.cancel()
            _ = await mergeTask.value
        }
        while activeImports > 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        scanTask?.cancel()
        await scanTask?.value
        scanTask = nil
        await moveTask?.value
        moveTask = nil
        offlineRefreshNeeded = false
        offlineTask?.cancel()
        await offlineTask?.value
        offlineTask = nil
    }

    func cancelMove() {
        moveTask?.cancel()
    }

    func setKeepAvailableOffline(_ enabled: Bool, context: ModelContext) {
        guard let id = activeLibraryID else { return }
        offlineRevision += 1
        let revision = offlineRevision
        keepAvailableOffline = enabled
        defaults.set(enabled, forKey: "library.offline.\(id.uuidString)")
        Task { await files.setOfflineAccess(enabled) }
        if enabled { refreshOfflineCopies(context: context) }
        else {
            let cancelledTask = offlineTask
            cancelledTask?.cancel()
            cachedFileIDs = []
            Task {
                await cancelledTask?.value
                guard revision == offlineRevision, !keepAvailableOffline else { return }
                try? await files.removeOfflineCopies(libraryID: id)
            }
        }
    }

    func refreshOfflineCopies(context: ModelContext) {
        guard keepAvailableOffline, isCloudBackedLocation, let id = activeLibraryID else { return }
        guard !isPreparingOffline else { offlineRefreshNeeded = true; return }
        isPreparingOffline = true
        offlineProcessed = 0
        offlineTotal = 0
        offlineTask = Task {
            do {
                let records = try await files.scan()
                offlineTotal = records.count
                try await files.prepareOfflineCopies(records: records) { done, total in
                    await MainActor.run { self.offlineProcessed = done; self.offlineTotal = total }
                }
            } catch is CancellationError {
                // Completed cached copies remain usable.
            } catch { lastError = error.localizedDescription }
            await updateCachedAvailability(libraryID: id, context: context)
            isPreparingOffline = false
            offlineTask = nil
            if offlineRefreshNeeded {
                offlineRefreshNeeded = false
                refreshOfflineCopies(context: context)
            }
        }
    }

    private func updateCachedAvailability(libraryID: UUID, context: ModelContext) async {
        let paths = (try? await files.cachedPaths(libraryID: libraryID)) ?? []
        let items = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
        cachedFileIDs = Set(items.filter { $0.libraryID == libraryID && paths.contains($0.effectiveRelativePath ?? "") }.map(\.id))
    }

    func availability(of item: FileItem, context: ModelContext) -> FileAvailability {
        if keepAvailableOffline && cachedFileIDs.contains(item.id) { return .available }
        if accessNeeded { return .accessNeeded }
        return availabilityByFileID[item.id] ?? .available
    }

    func removeLibraryFolder(context: ModelContext) {
        // Disconnect local authorization, but retain the synced catalog.
        defaults.removeObject(forKey: Self.legacyBookmarkKey)
        Self.activeRoot = nil
        accessNeeded = true
        libraryName = libraryName ?? "Library"
        if let descriptor = activeDescriptor(context: context) {
            let mounts = (try? context.fetch(FetchDescriptor<LibraryMount>())) ?? []
            if let mount = mounts.first(where: { $0.libraryID == descriptor.id }) {
                mount.bookmarkData = Data()
                mount.authorized = false
                try? context.save()
            }
            Task {
                await files.configure(LibraryConfiguration(id: descriptor.id,
                    mode: descriptor.mode, displayName: descriptor.displayName,
                    externalBookmark: nil))
            }
        }
    }

    private func activeDescriptor(context: ModelContext) -> LibraryDescriptor? {
        let descriptors = (try? context.fetch(FetchDescriptor<LibraryDescriptor>())) ?? []
        if let id = defaults.string(forKey: Self.activeLibraryKey).flatMap(UUID.init(uuidString:)),
           let selected = descriptors.first(where: { $0.id == id }) { return selected }
        // Another device's local folder is not accessible here.
        return descriptors.first(where: { $0.mode != .managedLocal })
    }

    private func apply(descriptor: LibraryDescriptor, context: ModelContext) {
        libraryName = descriptor.displayName
        activeLibraryID = descriptor.id
        defaults.set(descriptor.id.uuidString, forKey: Self.activeLibraryKey)
        let mounts = (try? context.fetch(FetchDescriptor<LibraryMount>())) ?? []
        let mount = mounts.first(where: { $0.libraryID == descriptor.id })
        let effectiveMode = mount?.modeOverrideRaw.flatMap(LibraryMode.init(rawValue:)) ?? descriptor.mode
        mode = effectiveMode
        keepAvailableOffline = defaults.bool(forKey: "library.offline.\(descriptor.id.uuidString)")
        storageOption = LibraryStorageOption.stored(in: defaults)
        isCloudBackedLocation = effectiveMode == .managedICloud
        lastSuccessfulScan = mount?.lastSuccessfulScan
        let bookmark = mount?.bookmarkData.isEmpty == false ? mount?.bookmarkData : nil
        accessNeeded = effectiveMode == .externalFolder && bookmark == nil
        Task {
            await files.setOfflineAccess(keepAvailableOffline)
            await updateCachedAvailability(libraryID: descriptor.id, context: context)
            await files.configure(LibraryConfiguration(id: descriptor.id,
                                                       mode: effectiveMode,
                                                       displayName: descriptor.displayName,
                                                       externalBookmark: bookmark))
            if effectiveMode == .externalFolder, let bookmark {
                var stale = false
                Self.activeRoot = try? URL(resolvingBookmarkData: bookmark, options: [],
                                           bookmarkDataIsStale: &stale)
                let ubiquitous = await files.rootIsUbiquitous()
                if activeLibraryID == descriptor.id { isCloudBackedLocation = ubiquitous }
            } else if effectiveMode != .externalFolder {
                do {
                    Self.activeRoot = try await files.configureManagedLibrary(
                        id: descriptor.id, mode: effectiveMode, displayName: descriptor.displayName
                    )
                    accessNeeded = false
                } catch {
                    Self.activeRoot = nil
                    accessNeeded = true
                    lastError = error.localizedDescription
                }
            }
            startBackgroundProcessing(context: context)
        }
    }

    func setBackgroundProcessingAllowed(_ allowed: Bool) {
        processingAllowed = allowed
        if !allowed { pauseBackgroundProcessing() }
    }

    func pauseBackgroundProcessing() { processingTask?.cancel() }

    func stopBackgroundProcessing() async {
        pauseBackgroundProcessing()
        await processingTask?.value
    }

    func startBackgroundProcessing(context: ModelContext, automatic: Bool = true) {
        guard pendingMutations == 0, processingAllowed, (!automatic || automaticallyProcessesLibrary), !isProcessingLibrary,
              !isRescanning, !isRemoving, !isMoving, !isConfiguring, !isMergingDuplicates, activeImports == 0,
              !accessNeeded, let libraryID = activeLibraryID,
              !CanonicalConverter.shared.isConverting else { return }
        let version = CanonicalConverterVersion.current
        let predicate = #Predicate<FileItem> {
            $0.libraryID == libraryID && $0.backgroundProcessingVersion < version &&
            ($0.storageRelativePath != nil || $0.libraryPath != nil)
        }
        let query = FetchDescriptor<FileItem>(predicate: predicate)
        guard let candidateIDs = try? context.fetchIdentifiers(query), !candidateIDs.isEmpty else { return }
        let total = candidateIDs.count
        isProcessingLibrary = true
        preparationProgress.value = .init(total: total)
        processingSummary = nil
        processingTask = Task {
            var progress = LibraryPreparationProgress.Value(total: total)
            var lastPublication = ContinuousClock.now
            defer {
                preparationProgress.value = progress
                isProcessingLibrary = false
                if progress.deferred > 0 || progress.failed > 0 {
                    processingSummary = "\(progress.prepared) prepared · \(progress.deferred) waiting for download · \(progress.failed) failed"
                }
            }
            // Keep lightweight IDs for the pass; materialize at most 100 models at once.
            var cursor = 0
            while cursor < candidateIDs.count && !Task.isCancelled && activeLibraryID == libraryID && !isRescanning && !isMoving {
                let end = min(cursor + 100, candidateIDs.count)
                let candidates = candidateIDs[cursor..<end].compactMap { context.model(for: $0) as? FileItem }
                cursor = end
                var ready: [(FileItem, EmbeddedScoreMetadata, FileItem.InferredMetadata?, CanonicalConverter.Outcome?)] = []
                for item in candidates {
                    guard !Task.isCancelled, activeLibraryID == libraryID,
                          !isRescanning, !isMoving, !CanonicalConverter.shared.isConverting else { break }
                    guard item.modelContext != nil, let path = item.effectiveRelativePath else { continue }
                    do {
                        if let input = try await files.processingInput(relativePath: path) {
                            let id = item.id
                            let title = input.metadata.title ?? item.displayTitle
                            let needsCanonical = item.canonicalVersion < version
                            let work = Task.detached(priority: .utility) {
                                guard let text = input.text else { return (nil, nil) as (FileItem.InferredMetadata?, CanonicalConverter.Outcome?) }
                                let inference = FileItem.inferredMetadata(from: text)
                                guard !Task.isCancelled else { return (inference, nil) }
                                let canonical = needsCanonical ? CanonicalConverter.prepareText(id: id, title: title, text: text) : nil
                                return (inference, canonical)
                            }
                            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                            try Task.checkCancellation()
                            ready.append((item, input.metadata, result.0, result.1))
                        } else {
                            progress.deferred += 1
                        }
                    } catch is CancellationError { break }
                    catch {
                        if Task.isCancelled { break }
                        progress.failed += 1
                        progress.lastFailure = "\((path as NSString).lastPathComponent): \(error.localizedDescription)"
                    }
                    progress.checked += 1
                    if lastPublication.duration(to: .now) >= .milliseconds(250) {
                        preparationProgress.value = progress
                        lastPublication = .now
                    }
                }
                // Apply one bounded group without suspending between model mutations.
                // The library observes a batch, rather than every individual file read.
                for (item, metadata, inference, canonical) in ready where item.modelContext != nil {
                    item.applyEmbeddedMetadata(metadata)
                    if let inference { item.applyInferredMetadata(inference) }
                    if let canonical { CanonicalConverter.shared.applyPreparedText(canonical, to: item) }
                    item.metadataReadVersion = 1
                    item.backgroundProcessingVersion = version
                }
                do { if !ready.isEmpty { try context.save() } }
                catch { lastError = "Could not save preparation progress: \(error.localizedDescription)"; break }
                progress.prepared += ready.count
                preparationProgress.value = progress
                lastPublication = .now
                if CanonicalConverter.shared.isConverting { break }
                // Leave time for touch handling and layout between catalog batches.
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
    }

    @discardableResult
    func reconcile(records: [LibraryFileRecord], descriptor: LibraryDescriptor,
                   context: ModelContext, isCompleteScan: Bool = true, readMetadata: Bool = true, provisionalPaths: Set<String> = [], reportProgress: Bool = true) async -> Bool {
        let existing = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
        let existingPresences = (try? context.fetch(FetchDescriptor<FilePresence>())) ?? []
        var updatedAvailability = availabilityByFileID
        var presenceByFileID: [UUID: FilePresence] = [:]
        for presence in existingPresences { presenceByFileID[presence.fileID] = presence }
        func setPresence(_ fileID: UUID, _ availability: FileAvailability, _ seenAt: Date?) {
            if let presence = presenceByFileID[fileID] {
                presence.availability = availability
                presence.lastSeenAt = seenAt
                presence.failureDescription = nil
            } else {
                let presence = FilePresence(fileID: fileID, availability: availability,
                                            lastSeenAt: seenAt)
                context.insert(presence)
                presenceByFileID[fileID] = presence
            }
            updatedAvailability[fileID] = availability
        }
        var byPath: [String: FileItem] = [:]
        for item in existing where item.libraryID == descriptor.id || item.libraryID == nil {
            if let path = item.effectiveRelativePath { byPath[path] = item }
        }
        let exactMatchIDs = Set(records.filter { !provisionalPaths.contains($0.relativePath) }.compactMap { byPath[$0.relativePath]?.id })
        var unmatchedExistingByHash: [String: [FileItem]] = [:]
        for item in existing where
            (item.libraryID == descriptor.id || item.libraryID == nil) &&
            !exactMatchIDs.contains(item.id) {
            if let hash = item.contentHash {
                unmatchedExistingByHash[hash, default: []].append(item)
            }
        }

        // Hash only paths that failed exact matching, and only when there is
        // metadata with a known fingerprint that could be re-linked. This
        // preserves rename/move metadata without downloading every iCloud file.
        var computedHashByPath: [String: String] = [:]
        if isCompleteScan && !unmatchedExistingByHash.isEmpty {
            for record in records where byPath[record.relativePath] == nil || provisionalPaths.contains(record.relativePath) {
                guard !Task.isCancelled else { return false }
                guard let lease = try? await files.acquireFile(relativePath: record.relativePath)
                else { continue }
                let url = lease.url
                let hash = await Task.detached(priority: .utility) {
                    FileItem.fingerprint(of: url)
                }.value
                lease.close()
                if let hash { computedHashByPath[record.relativePath] = hash }
            }
        }
        var unmatchedRecordCountByHash: [String: Int] = [:]
        for hash in computedHashByPath.values {
            unmatchedRecordCountByHash[hash, default: 0] += 1
        }
        var relinkedByPath: [String: FileItem] = [:]
        for (path, hash) in computedHashByPath {
            guard unmatchedRecordCountByHash[hash] == 1,
                  let candidates = unmatchedExistingByHash[hash],
                  candidates.count == 1,
                  let candidate = candidates.first else { continue }
            relinkedByPath[path] = candidate
        }
        let seenAt = Date.now
        var seen = Set<UUID>()

        var added = 0
        for (index, record) in records.enumerated() {
            if Task.isCancelled {
                availabilityByFileID = updatedAvailability
                try? context.save()
                TagIndexer.rebuild(in: context)
                return false
            }
            let item: FileItem
            if let provisional = byPath[record.relativePath], provisionalPaths.contains(record.relativePath),
               let original = relinkedByPath[record.relativePath], original.id != provisional.id,
               !provisional.metadataEdited, provisional.customTitle == nil, provisional.tags.isEmpty, !provisional.isFavorite,
               provisional.playCount == 0, provisional.lastOpenedAt <= provisional.importedAt {
                if let presence = presenceByFileID.removeValue(forKey: provisional.id) { context.delete(presence) }
                updatedAvailability.removeValue(forKey: provisional.id)
                context.delete(provisional)
                item = original
            } else if let match = byPath[record.relativePath] {
                item = match
            } else if let match = relinkedByPath[record.relativePath] {
                item = match
            } else {
                item = FileItem(bookmark: Data(), filename: record.filename,
                                folderName: parentName(of: record.relativePath),
                                libraryPath: record.relativePath)
                context.insert(item)
                added += 1
            }
            // Avoid dirtying unchanged rows: each mutation can invalidate library queries.
            if item.libraryID != descriptor.id { item.libraryID = descriptor.id }
            if item.storageRelativePath != record.relativePath { item.storageRelativePath = record.relativePath }
            if item.libraryPath != record.relativePath { item.libraryPath = record.relativePath }
            if item.filename != record.filename { item.filename = record.filename }
            let folderName = parentName(of: record.relativePath)
            if item.folderName != folderName { item.folderName = folderName }
            // An iCloud placeholder reports no modification date; keep the known version
            // (and its fingerprint) rather than treating eviction as a content change.
            let unknownVersion = record.modificationDate == nil && item.sourceModificationDate != nil
            if !unknownVersion && (item.byteSize != record.byteSize || item.sourceModificationDate != record.modificationDate) {
                item.byteSize = record.byteSize
                item.sourceModificationDate = record.modificationDate
                item.metadataReadVersion = 0
                item.backgroundProcessingVersion = 0
                if item.contentHash != nil { item.contentHash = nil }
            }
            if item.contentHash == nil, let hash = computedHashByPath[record.relativePath] {
                item.contentHash = hash
            }
            // Rescans skip embedded metadata. Coordinated content reads may
            // hydrate provider files or wait indefinitely for a provider.
            if readMetadata && !isCompleteScan && !item.metadataEdited && item.metadataReadVersion < 1,
               let metadata = try? await files.readEmbeddedMetadata(relativePath: record.relativePath) {
                item.applyEmbeddedMetadata(metadata)
                item.metadataReadVersion = 1
            }
            if item.needsLibraryMigration { item.needsLibraryMigration = false }
            seen.insert(item.id)
            setPresence(item.id, .available, seenAt)
            if isCompleteScan && ((index + 1).isMultiple(of: 100) || index + 1 == records.count) {
                do { try context.save() }
                catch {
                    lastError = error.localizedDescription
                    availabilityByFileID = updatedAvailability
                    return false
                }
                if reportProgress {
                    rescanAdded = added
                    rescanProcessed = index + 1
                }
                await Task.yield()
            }
        }

        guard !Task.isCancelled else {
            availabilityByFileID = updatedAvailability
            try? context.save()
            TagIndexer.rebuild(in: context)
            return false
        }
        // Missing is local state; metadata remains synced and recoverable.
        for item in existing where isCompleteScan && item.modelContext != nil && item.libraryID == descriptor.id && !seen.contains(item.id) {
            setPresence(item.id, .missing, nil)
        }
        availabilityByFileID = updatedAvailability
        try? context.save()
        TagIndexer.rebuild(in: context)
        return true
    }

    private func migrateLegacyItems(to descriptor: LibraryDescriptor, root: URL,
                                    context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
        for item in items {
            if let relative = item.libraryPath {
                item.libraryID = descriptor.id
                item.storageRelativePath = relative
                item.needsLibraryMigration = false
            } else if !item.bookmark.isEmpty {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: item.bookmark, options: [],
                                      bookmarkDataIsStale: &stale),
                   let relative = try? LibraryFileService.relativePath(of: url, under: root) {
                    item.libraryID = descriptor.id
                    item.storageRelativePath = relative
                    item.libraryPath = relative
                    item.needsLibraryMigration = false
                } else {
                    item.needsLibraryMigration = true
                }
            }
        }
    }

    private func markUnrootedLegacyItems(context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
        for item in items where item.effectiveRelativePath == nil && !item.bookmark.isEmpty {
            item.needsLibraryMigration = true
        }
        try? context.save()
    }

    private func parentName(of relativePath: String) -> String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : (parent as NSString).lastPathComponent
    }

    private func presence(for fileID: UUID, context: ModelContext) -> FilePresence? {
        ((try? context.fetch(FetchDescriptor<FilePresence>())) ?? [])
            .first(where: { $0.fileID == fileID })
    }

    private func upsertPresence(fileID: UUID, availability: FileAvailability,
                                seenAt: Date?, context: ModelContext) {
        if let presence = presence(for: fileID, context: context) {
            presence.availability = availability
            presence.lastSeenAt = seenAt
            presence.failureDescription = nil
        } else {
            context.insert(FilePresence(fileID: fileID, availability: availability,
                                        lastSeenAt: seenAt))
        }
        availabilityByFileID[fileID] = availability
    }

    private func updateMountScanDate(_ libraryID: UUID, context: ModelContext) {
        let mounts = (try? context.fetch(FetchDescriptor<LibraryMount>())) ?? []
        if let mount = mounts.first(where: { $0.libraryID == libraryID }) {
            mount.lastSuccessfulScan = .now
            try? context.save()
        }
    }
}

@MainActor
private final class LibraryMoveCheckpointWriter {
    private let job: LibraryMoveJob
    private let context: ModelContext
    private var completedPaths: [String]

    init(job: LibraryMoveJob, context: ModelContext) {
        self.job = job
        self.context = context
        completedPaths = (try? JSONDecoder().decode([String].self,
                                                    from: job.completedPathsData)) ?? []
    }

    func record(path: String, done: Int, total: Int) {
        completedPaths.append(path)
        guard done == total || done.isMultiple(of: 25) else { return }
        job.completedPathsData = (try? JSONEncoder().encode(completedPaths)) ?? Data()
        try? context.save()
    }
}

// MARK: - Backup / Restore

struct FileItemBackup: Codable {
    var filename: String
    var isFavorite: Bool
    var tags: [String]
    var importedAt: Date
    var lastOpenedAt: Date
    var scrollSpeed: Double
    var folderName: String
    var loopStartY: Double?
    var loopEndY: Double?
    var libraryPath: String?
    var playCount: Int
    var userBPM: Double?
    var referenceBPM: Double?
    var instruments: [String]? = nil
    var instrument: String? = nil
    var composer: String? = nil
    var arranger: String? = nil
    var collectionTitle: String? = nil
    var arrangement: String? = nil
    var sourceName: String? = nil
    var sourceURL: String? = nil
    var metadataEdited: Bool? = nil
    var preferredNotation: String? = nil
    var preferredTextMode: String? = nil
    var embeddedTitle: String? = nil
    var artist: String? = nil
    var sourceID: String? = nil
    var copyrightNotice: String? = nil
}

struct LibraryBackup: Codable {
    var version: Int = 2
    var exportedAt: Date
    var files: [FileItemBackup]
}

enum BackupManager {

    static func exportJSON(context: ModelContext) -> Data? {
        let items = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []

        let entries = items.map { item in
            FileItemBackup(
                filename: item.filename,
                isFavorite: item.isFavorite,
                tags: item.tags,
                importedAt: item.importedAt,
                lastOpenedAt: item.lastOpenedAt,
                scrollSpeed: item.scrollSpeed,
                folderName: item.folderName,
                loopStartY: item.loopStartY,
                loopEndY: item.loopEndY,
                libraryPath: item.libraryPath,
                playCount: item.playCount,
                userBPM: item.userBPM,
                referenceBPM: item.referenceBPM,
                instruments: item.instruments,
                instrument: item.instrument,
                composer: item.composer,
                arranger: item.arranger,
                collectionTitle: item.collectionTitle,
                arrangement: item.arrangement,
                sourceName: item.sourceName,
                sourceURL: item.sourceURL,
                metadataEdited: item.metadataEdited,
                preferredNotation: item.preferredNotation,
                preferredTextMode: item.preferredTextMode,
                embeddedTitle: item.embeddedTitle, artist: item.artist,
                sourceID: item.sourceID, copyrightNotice: item.copyrightNotice
            )
        }

        let backup = LibraryBackup(exportedAt: .now, files: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(backup)
    }

    @MainActor
    static func importJSON(data: Data, context: ModelContext, libraryID: UUID? = nil) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(LibraryBackup.self, from: data) else {
            return 0
        }

        let existing = ((try? context.fetch(FetchDescriptor<FileItem>())) ?? [])
            .filter { libraryID == nil || $0.libraryID == libraryID }
        var byPath: [String: FileItem] = [:]
        var byName: [String: FileItem] = [:]
        for item in existing {
            if let lp = item.libraryPath { byPath[lp] = item }
            if byName[item.filename] == nil { byName[item.filename] = item }
        }

        var restored = 0
        for entry in backup.files {
            let match = (entry.libraryPath.flatMap { byPath[$0] }) ?? byName[entry.filename]
            guard let match else { continue }

            match.isFavorite = entry.isFavorite
            match.tags = entry.tags
            match.scrollSpeed = entry.scrollSpeed
            match.loopStartY = entry.loopStartY
            match.loopEndY = entry.loopEndY
            match.playCount = entry.playCount
            match.userBPM = entry.userBPM
            match.referenceBPM = entry.referenceBPM
            if let value = entry.instruments { match.instruments = value }
            if backup.version >= 2 { match.instrument = entry.instrument }
            else if let value = entry.instrument { match.instrument = value }
            if backup.version >= 2 { match.composer = entry.composer }
            else if let value = entry.composer { match.composer = value }
            if backup.version >= 2 { match.arranger = entry.arranger }
            else if let value = entry.arranger { match.arranger = value }
            if backup.version >= 2 { match.collectionTitle = entry.collectionTitle }
            else if let value = entry.collectionTitle { match.collectionTitle = value }
            if backup.version >= 2 { match.arrangement = entry.arrangement }
            else if let value = entry.arrangement { match.arrangement = value }
            if backup.version >= 2 { match.sourceName = entry.sourceName }
            else if let value = entry.sourceName { match.sourceName = value }
            if backup.version >= 2 { match.sourceURL = entry.sourceURL }
            else if let value = entry.sourceURL { match.sourceURL = value }
            if let value = entry.metadataEdited { match.metadataEdited = value }
            if backup.version >= 2 { match.preferredNotation = entry.preferredNotation }
            else if let value = entry.preferredNotation { match.preferredNotation = value }
            if backup.version >= 2 { match.preferredTextMode = entry.preferredTextMode }
            else if let value = entry.preferredTextMode { match.preferredTextMode = value }
            if let value = entry.embeddedTitle { match.embeddedTitle = value }
            if let value = entry.artist { match.artist = value }
            if let value = entry.sourceID { match.sourceID = value }
            if let value = entry.copyrightNotice { match.copyrightNotice = value }
            if entry.lastOpenedAt > match.lastOpenedAt {
                match.lastOpenedAt = entry.lastOpenedAt
            }
            restored += 1
        }

        try? context.save()
        TagIndexer.rebuild(in: context)
        return restored
    }
}

/// Observed only by the status panel, never by the library's filtering/sorting view.
@MainActor
final class LibraryPreparationProgress: ObservableObject {
    struct Value {
        var total = 0
        var checked = 0
        var prepared = 0
        var deferred = 0
        var failed = 0
        var lastFailure: String?
    }
    @Published var value = Value()
}

@MainActor
final class LibraryScanProgress: ObservableObject {
    @Published var total = 0
    @Published var processed = 0
    @Published var found = 0
    @Published var added = 0
}

@MainActor
final class LibraryDiscoveryIndex {
    private var paths: Set<String>
    private var insertedPresence: [UUID: FileAvailability] = [:]
    init(paths: Set<String>) { self.paths = paths }

    /// Adds catalog entries for unknown paths. Before inserting, it checks the store
    /// for a record with the same library and path that iCloud may have imported from
    /// another device since the scan started, and reuses it instead of adding a duplicate.
    func insert(_ records: [LibraryFileRecord], libraryID: UUID, context: ModelContext) -> Int {
        let unknown = records.filter { !paths.contains($0.relativePath) }
        guard !unknown.isEmpty else { return 0 }
        // Optional-typed candidates keep the predicate a plain SQL `IN` (nil-coalescing is not translatable).
        let candidates: [String?] = unknown.map(\.relativePath)
        let optionalID: UUID? = libraryID
        let existing = FetchDescriptor<FileItem>(predicate: #Predicate { item in
            item.libraryID == optionalID &&
            (candidates.contains(item.storageRelativePath) || candidates.contains(item.libraryPath))
        })
        for item in (try? context.fetch(existing)) ?? [] {
            if let path = item.effectiveRelativePath {
                paths.insert(path)
                insertedPresence[item.id] = .available
            }
        }
        var added = 0
        for record in unknown where paths.insert(record.relativePath).inserted {
            let parent = (record.relativePath as NSString).deletingLastPathComponent
            let item = FileItem(bookmark: Data(), filename: record.filename,
                                folderName: (parent as NSString).lastPathComponent,
                                libraryPath: record.relativePath)
            item.libraryID = libraryID
            item.storageRelativePath = record.relativePath
            item.byteSize = record.byteSize
            item.sourceModificationDate = record.modificationDate
            context.insert(item)
            context.insert(FilePresence(fileID: item.id, availability: .available, lastSeenAt: .now))
            insertedPresence[item.id] = .available
            added += 1
        }
        return added
    }

    /// Presence recorded by the last inserts, for the manager's in-memory availability.
    func drainInsertedPresence() -> [UUID: FileAvailability] {
        defer { insertedPresence = [:] }
        return insertedPresence
    }
}

// MARK: - Duplicate merge

/// Merges catalog records that describe the same song. They appear when two devices
/// each catalogued the same library folder and then mirror library info through
/// iCloud. Idempotent and deterministic: every device picks the same survivor
/// (earliest `importedAt`, then smallest UUID string) and the same merged values.
@MainActor
enum LibraryDuplicateMerger {
    struct Summary: Equatable {
        var mergedGroups = 0
        var removedRecords = 0
        var removedDescriptors = 0
        var skippedGroups = 0
        /// Removed record ID → surviving record ID.
        var remapped: [UUID: UUID] = [:]
    }

    struct Candidate: Sendable {
        let index: Int
        let id: UUID
        let libraryID: UUID
        let path: String?
        let importedAt: Date
        let hash: String?
    }

    private struct Key: Hashable { let libraryID: UUID; let path: String }

    /// iCloud Drive and the default iOS volume are case-insensitive and may return
    /// either Unicode normalization, so paths compare after both are folded.
    nonisolated static func normalizedPath(_ path: String) -> String {
        let normalized = (try? LibraryFileService.normalizedRelativePath(path)) ?? path
        return normalized.precomposedStringWithCanonicalMapping.lowercased()
    }

    nonisolated static func precedes(_ lhs: (Date, UUID), _ rhs: (Date, UUID)) -> Bool {
        lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1.uuidString < rhs.1.uuidString
    }

    private nonisolated static func isPresent(_ availability: FileAvailability?) -> Bool {
        availability == .available || availability == .downloading
    }

    /// Pure grouping. Records group by (library, normalized path). A record whose file
    /// is missing here also joins the one present record with the same content
    /// fingerprint (a renamed or moved file). Returns candidate indices per group,
    /// survivor first.
    nonisolated static func plan(_ candidates: [Candidate], presence: [UUID: FileAvailability],
                                 fingerprintLibraryID: UUID?) -> [[Int]] {
        var parent = Array(0..<candidates.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var firstByKey: [Key: Int] = [:]
        for candidate in candidates {
            guard let path = candidate.path else { continue }
            let key = Key(libraryID: candidate.libraryID, path: normalizedPath(path))
            if let first = firstByKey[key] { union(first, candidate.index) } else { firstByKey[key] = candidate.index }
        }
        if let library = fingerprintLibraryID {
            var presentByHash: [String: [Int]] = [:]
            var missingByHash: [String: [Int]] = [:]
            for candidate in candidates where candidate.libraryID == library {
                guard let hash = candidate.hash else { continue }
                let availability = presence[candidate.id]
                if availability == .missing { missingByHash[hash, default: []].append(candidate.index) }
                else if isPresent(availability) { presentByHash[hash, default: []].append(candidate.index) }
            }
            for (hash, missing) in missingByHash {
                guard let present = presentByHash[hash],
                      Set(present.map(find)).count == 1 else { continue }   // Ambiguous copies stay separate.
                for index in missing { union(present[0], index) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for candidate in candidates { groups[find(candidate.index), default: []].append(candidate.index) }
        return groups.values.filter { $0.count > 1 }.map { members in
            members.sorted {
                precedes((candidates[$0].importedAt, candidates[$0].id), (candidates[$1].importedAt, candidates[$1].id))
            }
        }.sorted { $0[0] < $1[0] }
    }

    static func merge(context: ModelContext, presence: [UUID: FileAvailability], fingerprintLibraryID: UUID?,
                      protectedIDs: Set<UUID> = [], batchSize: Int = 100, fetchChunk: Int = 1_000,
                      canonicalExists: (String) -> Bool = { CanonicalStore.exists(filename: $0) }) async -> Summary {
        var summary = Summary()
        summary.removedDescriptors = mergeDescriptors(context: context)

        // Read the catalog in bounded chunks so the main actor keeps handling UI.
        var models: [FileItem] = []
        var candidates: [Candidate] = []
        var seen = Set<PersistentIdentifier>()
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<FileItem>(sortBy: [SortDescriptor(\.importedAt), SortDescriptor(\.filename)])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = fetchChunk
            descriptor.propertiesToFetch = [\.id, \.libraryID, \.storageRelativePath, \.libraryPath, \.importedAt, \.contentHash]
            guard let chunk = try? context.fetch(descriptor), !chunk.isEmpty else { break }
            for item in chunk {
                // Offset paging can repeat a row if the catalog changes meanwhile.
                guard let libraryID = item.libraryID, seen.insert(item.persistentModelID).inserted else { continue }
                candidates.append(Candidate(index: models.count, id: item.id, libraryID: libraryID,
                                            path: item.effectiveRelativePath, importedAt: item.importedAt,
                                            hash: item.contentHash))
                models.append(item)
            }
            offset += chunk.count
            if chunk.count < fetchChunk { break }
            await Task.yield()
            if Task.isCancelled { return summary }
        }
        let snapshot = candidates
        let groups = await Task.detached(priority: .utility) {
            plan(snapshot, presence: presence, fingerprintLibraryID: fingerprintLibraryID)
        }.value
        guard !groups.isEmpty else {
            if summary.removedDescriptors > 0 { try? context.save() }
            return summary
        }

        var tagDelta: [String: Int] = [:]
        var presenceByFile: [UUID: [FilePresence]] = [:]
        for record in (try? context.fetch(FetchDescriptor<FilePresence>())) ?? [] {
            presenceByFile[record.fileID, default: []].append(record)
        }
        for (batchIndex, group) in groups.enumerated() {
            let members = group.map { models[$0] }.filter { $0.modelContext != nil && !$0.isDeleted }
            if members.count < 2 { continue }
            if members.contains(where: { protectedIDs.contains($0.id) }) { summary.skippedGroups += 1; continue }
            let ordered = members.sorted { precedes(($0.importedAt, $0.id), ($1.importedAt, $1.id)) }
            guard Set(ordered.map(ObjectIdentifier.init)).count == ordered.count else { summary.skippedGroups += 1; continue }
            let survivor = ordered[0]
            let fileSource = ordered.first { isPresent(presence[$0.id]) } ?? survivor
            for member in ordered { for tag in Set(member.tags) { tagDelta[tag, default: 0] -= 1 } }
            mergeFields(into: survivor, from: ordered, fileSource: fileSource, canonicalExists: canonicalExists)
            for tag in Set(survivor.tags) { tagDelta[tag, default: 0] += 1 }
            // Keep the best local presence for the survivor.
            let records = ordered.flatMap { presenceByFile[$0.id] ?? [] }
            if let best = records.max(by: { rank($0.availability) < rank($1.availability) }) {
                if best.fileID != survivor.id { best.fileID = survivor.id }
                for record in records where record !== best { context.delete(record) }
                for member in ordered { presenceByFile[member.id] = nil }
                presenceByFile[survivor.id] = [best]
            }
            for loser in ordered.dropFirst() {
                // Two rows with one UUID cannot be ordered identically on every device; keep both.
                guard loser.id != survivor.id else { continue }
                summary.remapped[loser.id] = survivor.id
                context.delete(loser)
                summary.removedRecords += 1
            }
            summary.mergedGroups += 1
            if (batchIndex + 1).isMultiple(of: batchSize) {
                try? context.save()
                await Task.yield()
                if Task.isCancelled { break }
            }
        }
        try? context.save()
        if summary.removedRecords > 0 { applyTagDelta(tagDelta, context: context) }
        return summary
    }

    /// Adjust tag counts by the merge's change instead of re-reading the whole catalog.
    /// An index that was never built is rebuilt once.
    private static func applyTagDelta(_ delta: [String: Int], context: ModelContext) {
        let stats = (try? context.fetch(FetchDescriptor<TagStat>())) ?? []
        guard !stats.isEmpty else {
            if !delta.isEmpty { TagIndexer.rebuild(in: context) }
            return
        }
        var byName: [String: TagStat] = [:]
        for stat in stats where byName[stat.name] == nil { byName[stat.name] = stat }
        for (tag, change) in delta where change != 0 {
            if let stat = byName[tag] {
                stat.count += change
                if stat.count <= 0 { context.delete(stat) }
            } else if change > 0 {
                context.insert(TagStat(name: tag, count: change))
            }
        }
        try? context.save()
    }

    private nonisolated static func rank(_ availability: FileAvailability) -> Int {
        switch availability {
        case .available: return 5
        case .downloading: return 4
        case .accessNeeded: return 2
        case .failed: return 1
        case .missing: return 0
        }
    }

    /// Two devices that adopted the same folder can each create its descriptor.
    /// Identical duplicates cannot be ordered the same way on every device, so they stay.
    static func mergeDescriptors(context: ModelContext) -> Int {
        let descriptors = (try? context.fetch(FetchDescriptor<LibraryDescriptor>())) ?? []
        var removed = 0
        for (_, group) in Dictionary(grouping: descriptors, by: \.id) where group.count > 1 {
            func key(_ d: LibraryDescriptor) -> (Date, String, String, Int) { (d.createdAt, d.modeRaw, d.displayName, -d.rootGeneration) }
            let ordered = group.sorted { lhs, rhs in
                let a = key(lhs), b = key(rhs)
                if a.0 != b.0 { return a.0 < b.0 }
                if a.1 != b.1 { return a.1 < b.1 }
                if a.2 != b.2 { return a.2 < b.2 }
                return a.3 < b.3
            }
            let survivor = ordered[0]
            let generation = group.map(\.rootGeneration).max() ?? survivor.rootGeneration
            for other in ordered.dropFirst() {
                let a = key(survivor), b = key(other)
                guard a.0 != b.0 || a.1 != b.1 || a.2 != b.2 || a.3 != b.3 else { continue }
                context.delete(other)
                removed += 1
            }
            if survivor.rootGeneration != generation { survivor.rootGeneration = generation }
        }
        return removed
    }

    /// Merge rules (members are ordered survivor first):
    /// tags union; favorite OR; play count max; last opened max; user-edited
    /// descriptive fields from the first edited record (otherwise survivor, filling
    /// blanks); loops and practice settings from the most recently opened record;
    /// canonical tab data from the valid, newest conversion; file fields from a
    /// record whose file is present on this device.
    static func mergeFields(into survivor: FileItem, from ordered: [FileItem], fileSource: FileItem,
                            canonicalExists: (String) -> Bool) {
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<FileItem, T>, _ value: T) {
            if survivor[keyPath: keyPath] != value { survivor[keyPath: keyPath] = value }
        }
        // Choose sources before any survivor field changes.
        var practice = survivor
        for member in ordered where member.lastOpenedAt > practice.lastOpenedAt { practice = member }
        let edited = ordered.first { $0.metadataEdited }
        var tags = survivor.tags
        for member in ordered.dropFirst() { for tag in member.tags where !tags.contains(tag) { tags.append(tag) } }
        set(\.tags, tags)
        set(\.isFavorite, ordered.contains { $0.isFavorite })
        set(\.playCount, ordered.map(\.playCount).max() ?? survivor.playCount)
        set(\.lastOpenedAt, ordered.map(\.lastOpenedAt).max() ?? survivor.lastOpenedAt)
        set(\.importedAt, ordered.map(\.importedAt).min() ?? survivor.importedAt)
        set(\.confidenceNoticeDismissed, ordered.contains { $0.confidenceNoticeDismissed })
        if survivor.bookmark.isEmpty, let bookmark = ordered.first(where: { !$0.bookmark.isEmpty })?.bookmark { set(\.bookmark, bookmark) }

        // Descriptive details: an edited record wins as-is; otherwise fill blanks.
        let describing = edited ?? survivor
        let fill = edited == nil
        func pick(_ keyPath: ReferenceWritableKeyPath<FileItem, String?>) {
            var value = describing[keyPath: keyPath]
            if fill && value == nil { value = ordered.lazy.compactMap { $0[keyPath: keyPath] }.first }
            set(keyPath, value)
        }
        for keyPath in [\FileItem.embeddedTitle, \.artist, \.composer, \.arranger, \.collectionTitle, \.arrangement,
                        \.sourceName, \.sourceURL, \.sourceID, \.copyrightNotice, \.instrument, \.tuning] {
            pick(keyPath)
        }
        var instruments = describing.instruments
        if fill && instruments.isEmpty { instruments = ordered.first { !$0.instruments.isEmpty }?.instruments ?? [] }
        set(\.instruments, instruments)
        // A rename is a user choice even without the score-details edit flag.
        set(\.customTitle, describing.customTitle ?? ordered.lazy.compactMap(\.customTitle).first)
        set(\.metadataEdited, edited != nil)
        set(\.metadataReadVersion, edited?.metadataReadVersion ?? (ordered.map(\.metadataReadVersion).max() ?? 0))

        // Practice settings follow the most recently opened copy.
        set(\.loopStartY, practice.loopStartY)
        set(\.loopEndY, practice.loopEndY)
        set(\.loopStartMeasure, practice.loopStartMeasure)
        set(\.loopEndMeasure, practice.loopEndMeasure)
        set(\.scrollSpeed, practice.scrollSpeed)
        set(\.userBPM, practice.userBPM)
        set(\.referenceBPM, practice.referenceBPM ?? ordered.lazy.compactMap(\.referenceBPM).first)
        set(\.preferredTextMode, practice.preferredTextMode)
        set(\.preferredNotation, practice.preferredNotation)

        // Canonical tab data: prefer a file that exists here, then the newest converter version.
        let converted = ordered.filter { $0.canonicalFilename != nil }
        if let best = converted.max(by: { lhs, rhs in
            let l = (canonicalExists(lhs.canonicalFilename!) ? 1 : 0, lhs.canonicalVersion)
            let r = (canonicalExists(rhs.canonicalFilename!) ? 1 : 0, rhs.canonicalVersion)
            if l != r { return l < r }
            // Stable: earlier members win ties.
            return (ordered.firstIndex { $0 === lhs } ?? 0) > (ordered.firstIndex { $0 === rhs } ?? 0)
        }) {
            set(\.canonicalFilename, best.canonicalFilename)
            set(\.provenanceData, best.provenanceData)
            set(\.canonicalVersion, best.canonicalVersion)
            set(\.derivedTitle, best.derivedTitle)
            set(\.foreword, best.foreword)
        }
        set(\.backgroundProcessingVersion, ordered.map(\.backgroundProcessingVersion).max() ?? 0)

        // File identity comes from a copy whose file is present here.
        if fileSource !== survivor {
            set(\.storageRelativePath, fileSource.storageRelativePath)
            set(\.libraryPath, fileSource.libraryPath)
            set(\.filename, fileSource.filename)
            set(\.folderName, fileSource.folderName)
            set(\.byteSize, fileSource.byteSize)
            set(\.sourceModificationDate, fileSource.sourceModificationDate)
            set(\.contentHash, fileSource.contentHash ?? survivor.contentHash)
            set(\.needsLibraryMigration, fileSource.needsLibraryMigration)
        } else if survivor.contentHash == nil,
                  let hash = ordered.first(where: { $0.contentHash != nil && $0.effectiveRelativePath == survivor.effectiveRelativePath })?.contentHash {
            set(\.contentHash, hash)
        }
    }
}
