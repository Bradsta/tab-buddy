import Foundation

/// A scoped file access token. Closing or releasing the lease balances exactly
/// one successful `startAccessingSecurityScopedResource()` call.
final class FileAccessLease: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var releaseAction: (() -> Void)?

    init(url: URL, release: (() -> Void)? = nil) {
        self.url = url
        self.releaseAction = release
    }

    func close() {
        lock.lock()
        let action = releaseAction
        releaseAction = nil
        lock.unlock()
        action?()
    }

    deinit { close() }
}

actor LibraryFileService {
    static let shared = LibraryFileService()
    static let ubiquityContainerID = "iCloud.com.gamicarts.TabBuddy.library"
    static let managedFolderName = "Tab Buddy Library"

    private let localDocumentsURL: URL
    private let cloudContainer: @Sendable () -> URL?
    private let offlineDirectory: URL
    private var offlineAccess = false

    init(localDocumentsURL: URL? = nil, cloudContainer: (@Sendable () -> URL?)? = nil, offlineDirectory: URL? = nil) {
        self.localDocumentsURL = localDocumentsURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.offlineDirectory = offlineDirectory ?? (localDocumentsURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("OfflineLibrary", isDirectory: true)
        self.cloudContainer = cloudContainer ?? {
            guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
            return FileManager.default.url(forUbiquityContainerIdentifier: Self.ubiquityContainerID)
        }
    }

    func isICloudAvailable() -> Bool { cloudContainer() != nil }

    private func managedRoot(for mode: LibraryMode) throws -> URL {
        let documents: URL
        switch mode {
        case .managedLocal: documents = localDocumentsURL
        case .managedICloud:
            guard let container = cloudContainer() else { throw LibraryFileError.iCloudUnavailable }
            documents = container.appendingPathComponent("Documents", isDirectory: true)
        case .externalFolder: throw LibraryFileError.notConfigured
        }
        return documents.appendingPathComponent(Self.managedFolderName, isDirectory: true)
    }

    private var configuration: LibraryConfiguration?
    private var testingRoot: URL?

    func configure(_ configuration: LibraryConfiguration) {
        self.configuration = configuration
    }

    func configureTestingRoot(_ url: URL, libraryID: UUID = UUID()) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        testingRoot = url
        configuration = LibraryConfiguration(id: libraryID, mode: .managedICloud,
                                             displayName: "Test Library", externalBookmark: nil)
    }

    func clearTestingRoot() { testingRoot = nil }

    func validateOrCreateMarker(at root: URL, libraryID: UUID,
                                mayCreate: Bool = true) throws {
        try Self.writeOrValidateMarker(at: root, libraryID: libraryID, mayCreate: mayCreate)
    }

    func existingManagedLibraryID(mode: LibraryMode) throws -> UUID? {
        let markerURL = try managedRoot(for: mode).appendingPathComponent(LibraryMarker.filename)
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        let marker = try JSONDecoder().decode(LibraryMarker.self, from: Data(contentsOf: markerURL))
        guard marker.schemaVersion == LibraryMarker.currentVersion else { throw LibraryFileError.markerMismatch }
        return marker.libraryID
    }

    func configureManagedLibrary(id: UUID, mode: LibraryMode = .managedICloud,
                                 displayName: String = managedFolderName) throws -> URL {
        let root = try managedRoot(for: mode)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.writeOrValidateMarker(at: root, libraryID: id, mayCreate: true)
        configuration = LibraryConfiguration(id: id, mode: mode,
                                             displayName: displayName, externalBookmark: nil)
        return root
    }

    func connectExternalRoot(_ url: URL, libraryID: UUID, displayName: String,
                             mayCreateMarker: Bool = true) throws -> Data {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        _ = try url.resourceValues(forKeys: [.isDirectoryKey])

        try Self.writeOrValidateMarker(at: url, libraryID: libraryID,
                                       mayCreate: mayCreateMarker)
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        configuration = LibraryConfiguration(id: libraryID, mode: .externalFolder,
                                             displayName: displayName,
                                             externalBookmark: bookmark)
        return bookmark
    }

    /// Reuse the identity of an existing library, or adopt an unmarked folder.
    /// Never creates a child directory or overwrites another library's marker.
    static func existingLibraryID(at root: URL) throws -> UUID? {
        let markerURL = root.appendingPathComponent(LibraryMarker.filename)
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        let marker = try JSONDecoder().decode(LibraryMarker.self, from: Data(contentsOf: markerURL))
        guard marker.schemaVersion == LibraryMarker.currentVersion else { throw LibraryFileError.markerMismatch }
        return marker.libraryID
    }

    func acquireFile(relativePath: String, allowCloudPlaceholder: Bool = false) throws -> FileAccessLease {
        let normalized = try Self.normalizedRelativePath(relativePath)
        let cached = configuration.map { offlineRoot(libraryID: $0.id).appendingPathComponent(normalized) }
        let cachedExists = offlineAccess && cached.map { FileManager.default.fileExists(atPath: $0.path) } == true
        let rootLease: FileAccessLease
        do { rootLease = try acquireRoot() }
        catch {
            if cachedExists, let cached { return FileAccessLease(url: cached) }
            throw error
        }
        let url = rootLease.url.appendingPathComponent(normalized)
        guard Self.contains(url, in: rootLease.url) else {
            rootLease.close()
            throw LibraryFileError.invalidRelativePath
        }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if cachedExists, let cached,
           !FileManager.default.fileExists(atPath: url.path) ||
            (values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus != .current) {
            rootLease.close()
            return FileAccessLease(url: cached)
        }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard FileManager.default.fileExists(atPath: url.path) ||
                (allowCloudPlaceholder && values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded) ||
                (allowCloudPlaceholder && FileManager.default.fileExists(atPath: placeholder.path)) else {
            rootLease.close()
            throw LibraryFileError.fileMissing
        }
        return FileAccessLease(url: url) { rootLease.close() }
    }

    func readEmbeddedMetadata(relativePath: String) async throws -> EmbeddedScoreMetadata? {
        try await processingInput(relativePath: relativePath)?.metadata
    }

    /// Only process local content; cloud-only scores stay pending for another visit.
    func processingInput(relativePath: String) async throws -> LibraryProcessingInput? {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        guard EmbeddedScoreMetadata.canWrite(extension: ext) else { return .init(metadata: .init(), text: nil) }
        let lease = try acquireFile(relativePath: relativePath, allowCloudPlaceholder: true)
        defer { lease.close() }
        let url = lease.url
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey])
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded { return nil }
        guard (values.fileSize ?? 0) <= 20_000_000 else { return .init(metadata: .init(), text: nil) }
        let readText = ext == "txt" && (values.fileSize ?? 0) <= 2_000_000
        let coordinator = ScanCoordinator()
        let read = Task.detached(priority: .utility) {
            var error: NSError?
            var result: Result<LibraryProcessingInput?, Error> = .success(nil)
            coordinator.value.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readableURL in
                result = Result {
                    try Task.checkCancellation()
                    let handle = try FileHandle(forReadingFrom: readableURL)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: ext == "pdf" ? 20_000_000 : (readText ? 2_000_000 : 300_000)) ?? Data()
                    let metadata = try EmbeddedScoreMetadata.read(data: data, extension: ext) ?? .init()
                    let text = readText ? (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)) : nil
                    return .init(metadata: metadata, text: text)
                }
            }
            try Task.checkCancellation()
            if let error { throw error }
            return try result.get()
        }
        return try await withTaskCancellationHandler {
            try await read.value
        } onCancel: {
            coordinator.value.cancel()
            read.cancel()
        }
    }

    func writeEmbeddedMetadata(_ metadata: EmbeddedScoreMetadata, relativePath: String) throws {
        let rootLease = try acquireRoot()
        defer { rootLease.close() }
        let sourceURL = rootLease.url.appendingPathComponent(try Self.normalizedRelativePath(relativePath))
        guard Self.contains(sourceURL, in: rootLease.url) else { throw LibraryFileError.invalidRelativePath }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw LibraryFileError.fileMissing }
        let ext = sourceURL.pathExtension.lowercased()
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(MetadataError.verificationFailed)
        NSFileCoordinator().coordinate(writingItemAt: sourceURL, options: .forReplacing, error: &coordinationError) { url in
            result = Result {
                let original = try Data(contentsOf: url)
                let updated = try metadata.writing(to: original, extension: ext)
                guard try EmbeddedScoreMetadata.read(data: updated, extension: ext) == metadata else { throw MetadataError.verificationFailed }
                try updated.write(to: url, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    func setOfflineAccess(_ enabled: Bool) { offlineAccess = enabled }

    private func offlineRoot(libraryID: UUID) -> URL {
        offlineDirectory.appendingPathComponent(libraryID.uuidString, isDirectory: true)
    }

    func cachedPaths(libraryID: UUID) throws -> Set<String> {
        let root = offlineRoot(libraryID: libraryID)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return Set(try Self.scanManifest(at: root).map(\.relativePath))
    }

    func removeOfflineCopies(libraryID: UUID) throws {
        let root = offlineRoot(libraryID: libraryID)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func prepareOfflineCopies(records: [LibraryFileRecord],
                              progress: (@Sendable (Int, Int) async -> Void)? = nil) async throws {
        guard let configuration else { throw LibraryFileError.notConfigured }
        let lease = try acquireRoot()
        defer { lease.close() }
        let root = offlineRoot(libraryID: configuration.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try excluded.setResourceValues(resourceValues)
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            let relative = try Self.normalizedRelativePath(record.relativePath)
            let source = lease.url.appendingPathComponent(relative)
            let destination = root.appendingPathComponent(relative)
            let existing = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let modified = record.modificationDate, existing?.contentModificationDate == modified,
               Int64(existing?.fileSize ?? -1) == record.byteSize {
                await progress?(index + 1, records.count)
                continue
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
            do {
                try Self.coordinatedCopy(from: source, to: temporary)
                let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard record.byteSize == 0 || Int64(size ?? -1) == record.byteSize else {
                    throw LibraryFileError.copyFailed("The offline copy of \(record.filename) was incomplete.")
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            await progress?(index + 1, records.count)
        }
    }

    func acquireLegacyFile(bookmark: Data) throws -> FileAccessLease {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [],
                          bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else {
            throw LibraryFileError.accessDenied
        }
        return FileAccessLease(url: url) { url.stopAccessingSecurityScopedResource() }
    }

    func scan(onDiscovered: (@Sendable (Int) -> Void)? = nil,
              onBatch: (@Sendable ([LibraryFileRecord]) async throws -> Void)? = nil) async throws -> [LibraryFileRecord] {
        let lease = try acquireRoot()
        defer { lease.close() }
        let rootURL = lease.url
        let coordinator = ScanCoordinator()
        let (stream, continuation) = AsyncThrowingStream<[LibraryFileRecord], Error>.makeStream()
        let enumeration = Task.detached(priority: .utility) {
            do {
                var coordinationError: NSError?
                var result: Result<[LibraryFileRecord], Error> = .failure(LibraryFileError.accessDenied)
                coordinator.value.coordinate(readingItemAt: rootURL, options: .immediatelyAvailableMetadataOnly, error: &coordinationError) { root in
                    result = Result {
                        try Self.scanManifest(at: root, onDiscovered: onDiscovered, onRecords: { continuation.yield($0) })
                    }
                }
                try Task.checkCancellation()
                if let coordinationError { throw coordinationError }
                _ = try result.get()
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        defer { coordinator.value.cancel(); enumeration.cancel() }
        var records: [LibraryFileRecord] = []
        try await withTaskCancellationHandler {
            for try await batch in stream {
                try Task.checkCancellation()
                try await onBatch?(batch)
                records.append(contentsOf: batch)
            }
            try Task.checkCancellation()
        } onCancel: {
            coordinator.value.cancel()
            enumeration.cancel()
            continuation.finish(throwing: CancellationError())
        }
        let isUbiquitous = try? rootURL.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem
        if isUbiquitous == true {
            let remote = try await ICloudLibraryQuery.records(under: rootURL)
            let known = Set(records.map(\.relativePath))
            let additional = remote.filter { !known.contains($0.relativePath) }
            for start in stride(from: 0, to: additional.count, by: 100) {
                try Task.checkCancellation()
                let batch = Array(additional[start..<min(start + 100, additional.count)])
                try await onBatch?(batch)
                records.append(contentsOf: batch)
            }
            var merged = Dictionary(records.map { ($0.relativePath, $0) }, uniquingKeysWith: { _, latest in latest })
            for record in remote { merged[record.relativePath] = record }
            records = Array(merged.values)
        }
        return records.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// The logical name of an iCloud Drive placeholder (`.Song.pdf.icloud` → `Song.pdf`), if it is one.
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        let target = String(name.dropFirst().dropLast(".icloud".count))
        return target.isEmpty ? nil : target
    }

    private static func scanManifest(at rootURL: URL, onDiscovered: (@Sendable (Int) -> Void)? = nil, onRecords: (@Sendable ([LibraryFileRecord]) -> Void)? = nil) throws -> [LibraryFileRecord] {
        let root = rootURL.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey, .fileSizeKey,
                                     .contentModificationDateKey, .isUbiquitousItemKey]
        var enumerationError: Error?
        // Hidden entries are filtered here rather than by the enumerator so iCloud Drive
        // placeholders for files that are not downloaded still count as present.
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw LibraryFileError.accessDenied }

        var records: [LibraryFileRecord] = []
        var seenPaths = Set<String>()
        defer {
            let remainder = records.count % 100
            if remainder > 0 { onRecords?(Array(records.suffix(remainder))) }
        }
        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let name = fileURL.lastPathComponent
            var logicalURL = fileURL
            var isPlaceholder = false
            if name.hasPrefix(".") {
                if let target = placeholderTarget(name) {
                    logicalURL = fileURL.deletingLastPathComponent().appendingPathComponent(target)
                    isPlaceholder = true
                } else {
                    let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
                    if values?.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
            }
            let ext = logicalURL.pathExtension.lowercased()
            guard GuitarProFileType.supports(extension: ext) else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if !isPlaceholder {
                if values?.isHidden == true { continue }
                guard values?.isRegularFile != false else { continue }
            }
            let relative = try Self.relativePath(of: logicalURL, under: root)
            guard seenPaths.insert(relative).inserted else { continue }
            records.append(LibraryFileRecord(
                relativePath: relative,
                filename: logicalURL.lastPathComponent,
                byteSize: isPlaceholder ? 0 : Int64(values?.fileSize ?? 0),
                modificationDate: isPlaceholder ? nil : values?.contentModificationDate
            ))
            if records.count.isMultiple(of: 100) {
                onRecords?(Array(records.suffix(100)))
                onDiscovered?(records.count)
            }
        }
        if let enumerationError { throw enumerationError }
        onDiscovered?(records.count)
        return records.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    func importFiles(_ sourceURLs: [URL], relativeTo sourceRoot: URL? = nil,
                     progress: (@Sendable (Int, Int) async -> Void)? = nil,
                     onImported: (@Sendable ([LibraryFileRecord]) async throws -> Void)? = nil) async throws -> [LibraryFileRecord] {
        let destinationLease = try acquireRoot()
        defer { destinationLease.close() }
        let destinationRoot = destinationLease.url
        var sources: [(url: URL, relative: String)] = []
        var openedSources: [URL] = []
        defer {
            for url in openedSources { url.stopAccessingSecurityScopedResource() }
        }

        for source in sourceURLs {
            let started = source.startAccessingSecurityScopedResource()
            if started { openedSources.append(source) }
            sources.append(contentsOf: try Self.importSources(at: source, relativeTo: sourceRoot))
        }
        guard !sources.isEmpty else { throw LibraryFileError.noImportableFiles }
        await progress?(0, sources.count)

        var imported: [LibraryFileRecord] = []
        var pending: [LibraryFileRecord] = []
        do {
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                let relative = try Self.normalizedRelativePath(source.relative)
                var destination = destinationRoot.appendingPathComponent(relative)
                destination = Self.availableDestination(for: destination)
                guard Self.contains(destination, in: destinationRoot) else {
                    throw LibraryFileError.invalidRelativePath
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let temporary = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).partial")
                do {
                    try Self.coordinatedCopy(from: source.url, to: temporary)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw LibraryFileError.copyFailed(error.localizedDescription)
                }
                let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let storedRelative = try Self.relativePath(of: destination, under: destinationRoot)
                let record = LibraryFileRecord(relativePath: storedRelative,
                                               filename: destination.lastPathComponent,
                                               byteSize: Int64(values?.fileSize ?? 0),
                                               modificationDate: values?.contentModificationDate)
                imported.append(record)
                pending.append(record)
                // Publish the first file promptly, then amortize database/index work.
                if imported.count == 1 || pending.count >= 100 {
                    try await onImported?(pending)
                    pending.removeAll(keepingCapacity: true)
                }
                await progress?(index + 1, sources.count)
            }
        } catch {
            // Successfully copied files must be catalogued even when the task
            // has been cancelled or a later provider copy fails.
            if !pending.isEmpty { try await onImported?(pending) }
            throw error
        }
        if !pending.isEmpty { try await onImported?(pending) }
        return imported
    }

    /// Coordinate directory reads with file providers; never interpret a failed
    /// enumeration as a successful empty import.
    private static func importSources(at source: URL, relativeTo sourceRoot: URL?) throws -> [(url: URL, relative: String)] {
        var coordinationError: NSError?
        var result: Result<[(url: URL, relative: String)], Error> = .failure(LibraryFileError.accessDenied)
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let values = try readableURL.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    return GuitarProFileType.supports(extension: readableURL.pathExtension)
                        ? [(readableURL, readableURL.lastPathComponent)] : []
                }
                let base = sourceRoot ?? readableURL
                var enumerationError: Error?
                guard let enumerator = FileManager.default.enumerator(
                    at: readableURL, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, error in enumerationError = error; return false }
                ) else { throw LibraryFileError.accessDenied }
                var entries: [(url: URL, relative: String)] = []
                while let child = enumerator.nextObject() as? URL {
                    guard GuitarProFileType.supports(extension: child.pathExtension) else { continue }
                    let childValues = try child.resourceValues(forKeys: [.isRegularFileKey])
                    guard childValues.isRegularFile == true else { continue }
                    entries.append((child, try Self.relativePath(of: child, under: base)))
                }
                if let enumerationError { throw enumerationError }
                return entries
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Which of these library paths have a file in the current root, including iCloud
    /// placeholders that are not downloaded. Reads directory metadata only.
    func existingPaths(_ relativePaths: [String]) throws -> Set<String> {
        let lease = try acquireRoot()
        defer { lease.close() }
        var present = Set<String>()
        for path in relativePaths {
            try Task.checkCancellation()
            guard let normalized = try? Self.normalizedRelativePath(path) else { continue }
            let url = lease.url.appendingPathComponent(normalized)
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            if FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path) {
                present.insert(path)
            } else if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                      values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != nil {
                present.insert(path)
            }
        }
        return present
    }

    /// Whether the active root lives in iCloud (TabBuddy's container or iCloud Drive).
    func rootIsUbiquitous() -> Bool {
        guard let lease = try? acquireRoot() else { return false }
        defer { lease.close() }
        if configuration?.mode == .managedICloud { return true }
        return (try? lease.url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    func deleteUnderlyingFile(relativePath: String) throws {
        let normalized = try Self.normalizedRelativePath(relativePath)
        let lease = try acquireRoot()
        defer { lease.close() }
        let url = lease.url.appendingPathComponent(normalized)
        guard Self.contains(url, in: lease.url) else { throw LibraryFileError.invalidRelativePath }
        try FileManager.default.removeItem(at: url)
    }

    /// Copies a complete library to a new root. The active configuration is
    /// switched only after every destination file verifies by size (and the
    /// caller can resume because existing verified files are skipped).
    func moveLibrary(to mode: LibraryMode, externalParent: URL?,
                     records: [LibraryMoveRecord], libraryID: UUID,
                     progress: (@Sendable (String, Int, Int) async -> Void)? = nil) async throws -> LibraryMoveResult {
        guard let sourceConfiguration = configuration else {
            throw LibraryFileError.notConfigured
        }
        let sourceLease = try acquireRoot(for: sourceConfiguration)
        defer { sourceLease.close() }

        let destinationLease: FileAccessLease
        let destinationConfiguration: LibraryConfiguration
        switch mode {
        case .managedLocal, .managedICloud:
            let root = try managedRoot(for: mode)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            destinationLease = FileAccessLease(url: root)
            destinationConfiguration = LibraryConfiguration(id: libraryID, mode: mode,
                                                            displayName: Self.managedFolderName,
                                                            externalBookmark: nil)
        case .externalFolder:
            guard let parent = externalParent,
                  parent.startAccessingSecurityScopedResource() else {
                throw LibraryFileError.accessDenied
            }
            let root = parent.appendingPathComponent(Self.managedFolderName, isDirectory: true)
            let bookmark: Data
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                bookmark = try root.bookmarkData(options: [],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
            } catch {
                parent.stopAccessingSecurityScopedResource()
                throw error
            }
            destinationLease = FileAccessLease(url: root) {
                parent.stopAccessingSecurityScopedResource()
            }
            destinationConfiguration = LibraryConfiguration(id: libraryID, mode: .externalFolder,
                                                            displayName: root.lastPathComponent,
                                                            externalBookmark: bookmark)
        }
        defer { destinationLease.close() }

        guard !Self.contains(destinationLease.url, in: sourceLease.url),
              !Self.contains(sourceLease.url, in: destinationLease.url) else {
            throw LibraryFileError.invalidRelativePath
        }

        try await Self.copyLibraryContents(
            from: sourceLease.url,
            to: destinationLease.url,
            records: records,
            libraryID: libraryID,
            progress: progress
        )
        configuration = destinationConfiguration
        return LibraryMoveResult(configuration: destinationConfiguration,
                                 rootURL: destinationLease.url)
    }

    /// Copies a manifest between already-authorized roots. Kept internal so the
    /// data-integrity behavior can be exercised without iCloud or a document
    /// picker in unit tests.
    static func copyLibraryContents(
        from sourceRoot: URL,
        to destinationRoot: URL,
        records: [LibraryMoveRecord],
        libraryID: UUID,
        progress: (@Sendable (String, Int, Int) async -> Void)? = nil
    ) async throws {
        // Reject a different or malformed library before writing even one byte.
        try validateExistingMarkerIfPresent(at: destinationRoot, libraryID: libraryID)

        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            let relative = try Self.normalizedRelativePath(record.relativePath)
            let source = sourceRoot.appendingPathComponent(relative)
            let destination = destinationRoot.appendingPathComponent(relative)
            guard Self.contains(source, in: sourceRoot),
                  Self.contains(destination, in: destinationRoot) else {
                throw LibraryFileError.invalidRelativePath
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
                guard size == record.byteSize,
                      try filesHaveEqualContents(source, destination) else {
                    throw LibraryFileError.copyFailed("A conflicting file exists at \(relative).")
                }
                await progress?(relative, index + 1, records.count)
                continue
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).partial")
            do {
                try Self.coordinatedCopy(from: source, to: temporary)
                let copiedSize = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
                guard copiedSize == record.byteSize else {
                    throw LibraryFileError.copyFailed("Size verification failed for \(relative).")
                }
                if let known = record.knownFingerprint,
                   FileItem.fingerprint(of: temporary) != known {
                    throw LibraryFileError.copyFailed("Fingerprint verification failed for \(relative).")
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            await progress?(relative, index + 1, records.count)
        }
        try writeOrValidateMarker(at: destinationRoot, libraryID: libraryID, mayCreate: true)
    }

    static func normalizedRelativePath(_ path: String) throws -> String {
        let replaced = path.replacingOccurrences(of: "\\", with: "/")
        let parts = replaced.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty,
              !replaced.hasPrefix("/"),
              !parts.contains(".."), !parts.contains(".") else {
            throw LibraryFileError.invalidRelativePath
        }
        return parts.joined(separator: "/")
    }

    /// File-provider URLs and enumerated URLs can use different aliases for
    /// the same directory (for example /var and /private/var on iOS).
    /// Compare resolved components, including existing symlink ancestors of
    /// destinations that have not been created yet.
    private static func resolvedComponents(_ url: URL) -> [String] {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        // Foundation leaves a path unresolved when its final file does not yet
        // exist. Resolve its existing parent first, then append the new suffix.
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.pathComponents.count > 1 {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return ancestor.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            + missingComponents.reversed()
    }

    static func relativePath(of url: URL, under root: URL) throws -> String {
        let rootParts = resolvedComponents(root)
        let fileParts = resolvedComponents(url)
        guard fileParts.count > rootParts.count,
              fileParts.starts(with: rootParts) else { throw LibraryFileError.invalidRelativePath }
        return try normalizedRelativePath(fileParts.dropFirst(rootParts.count).joined(separator: "/"))
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        resolvedComponents(url).starts(with: resolvedComponents(root))
    }

    static func availableDestination(for requested: URL) -> URL {
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let directory = requested.deletingLastPathComponent()
        let ext = requested.pathExtension
        let stem = requested.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            var candidate = directory.appendingPathComponent("\(stem) (\(counter))")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private func acquireRoot() throws -> FileAccessLease {
        guard let configuration else { throw LibraryFileError.notConfigured }
        return try acquireRoot(for: configuration)
    }

    private func acquireRoot(for configuration: LibraryConfiguration) throws -> FileAccessLease {
        if let testingRoot { return FileAccessLease(url: testingRoot) }
        switch configuration.mode {
        case .managedLocal, .managedICloud:
            return FileAccessLease(url: try managedRoot(for: configuration.mode))
        case .externalFolder:
            guard let data = configuration.externalBookmark else {
                throw LibraryFileError.accessDenied
            }
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [],
                              bookmarkDataIsStale: &stale)
            let started = url.startAccessingSecurityScopedResource()
            return FileAccessLease(url: url) { if started { url.stopAccessingSecurityScopedResource() } }
        }
    }

    private static func validateExistingMarkerIfPresent(at root: URL,
                                                        libraryID: UUID) throws {
        let markerURL = root.appendingPathComponent(LibraryMarker.filename)
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(LibraryMarker.self, from: data),
              marker.libraryID == libraryID else {
            throw LibraryFileError.markerMismatch
        }
    }

    private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(LibraryFileError.accessDenied)
        NSFileCoordinator().coordinate(readingItemAt: source, options: [],
                                       writingItemAt: destination, options: [],
                                       error: &coordinationError) { readURL, writeURL in
            result = Result { try FileManager.default.copyItem(at: readURL, to: writeURL) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    private static func filesHaveEqualContents(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: lhs)
        let right = try FileHandle(forReadingFrom: rhs)
        defer {
            try? left.close()
            try? right.close()
        }
        let chunkSize = 256 * 1024
        while true {
            let leftChunk = try left.read(upToCount: chunkSize) ?? Data()
            let rightChunk = try right.read(upToCount: chunkSize) ?? Data()
            guard leftChunk == rightChunk else { return false }
            if leftChunk.isEmpty { return true }
        }
    }

    private static func writeOrValidateMarker(at root: URL, libraryID: UUID,
                                              mayCreate: Bool) throws {
        let markerURL = root.appendingPathComponent(LibraryMarker.filename)
        if let data = try? Data(contentsOf: markerURL),
           let marker = try? JSONDecoder().decode(LibraryMarker.self, from: data) {
            guard marker.libraryID == libraryID else { throw LibraryFileError.markerMismatch }
            return
        }
        guard mayCreate else { throw LibraryFileError.markerMismatch }
        let marker = LibraryMarker(libraryID: libraryID,
                                   schemaVersion: LibraryMarker.currentVersion)
        let data = try JSONEncoder().encode(marker)
        try data.write(to: markerURL, options: .atomic)
    }
}


/// Metadata discovery runs on the main run loop and does not download song contents.
@MainActor
private final class ICloudLibraryQuery {
    private let query = NSMetadataQuery()
    private let root: URL
    private var observer: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<[LibraryFileRecord], Error>?

    private init(root: URL) { self.root = root }

    static func records(under root: URL) async throws -> [LibraryFileRecord] {
        let discovery = ICloudLibraryQuery(root: root)
        return try await discovery.collect()
    }

    private func collect() async throws -> [LibraryFileRecord] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
                query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path + "/")
                observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                                   object: query, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.didGather() }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                    catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
                if !query.start() { finish(.failure(LibraryFileError.accessDenied)) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func didGather() {
        query.disableUpdates()
        let records = query.results.compactMap { value -> LibraryFileRecord? in
            guard let item = value as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  GuitarProFileType.supports(extension: url.pathExtension.lowercased()),
                  let relative = try? LibraryFileService.relativePath(of: url, under: root) else { return nil }
            return LibraryFileRecord(relativePath: relative, filename: url.lastPathComponent,
                byteSize: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0,
                modificationDate: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)
        }
        finish(.success(records))
    }

    private func finish(_ result: Result<[LibraryFileRecord], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}

/// The scan worker exclusively uses this coordinator; the cancellation handler
/// only calls cancel(), which may interrupt coordination from another thread.
private final class ScanCoordinator: @unchecked Sendable {
    let value = NSFileCoordinator()
}
