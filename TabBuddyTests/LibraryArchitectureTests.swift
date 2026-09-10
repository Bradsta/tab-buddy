import XCTest
import SwiftData
import SwiftUI
import PDFKit
import AVFoundation
@testable import TabBuddy

final class LibraryArchitectureTests: XCTestCase {
    private var temporaryRoot: URL!

    @MainActor
    func testReaderLifecycleDoesNotAllocateAudio() {
        var allocations = 0
        let notes = NotePlaybackEngine(makeEngine: { allocations += 1; return AVAudioEngine() })
        let metronome = MetronomeEngine(makeEngine: { allocations += 1; return AVAudioEngine() })
        for _ in 0..<20 {
            notes.stop()
            notes.stopNotes()
            notes.playMIDI(60)
            notes.isEnabled = true
            notes.playNotes([0, nil, nil, nil, nil, nil])
            metronome.stop()
            metronome.playClick(beatInMeasure: 0, beatsPerMeasure: 4, force: true)
        }
        XCTAssertEqual(allocations, 0, "Opening, switching, and closing a reader must not initialize audio")
    }

    @MainActor
    func testReaderSavesCoalesceAndFlushOnInactivity() async throws {
        let schema = Schema([FileItem.self])
        let config = ModelConfiguration(schema: schema, url: temporaryRoot.appendingPathComponent("Reader.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        context.autosaveEnabled = false
        let item = FileItem(bookmark: Data(), filename: "song.txt")
        context.insert(item)
        try context.save()
        defer { ReaderPersistence.flush(context) }
        var saves = 0
        let subscription = NotificationCenter.default.publisher(for: ModelContext.didSave).sink { notification in
            if notification.object as? ModelContext === context { saves += 1 }
        }
        defer { subscription.cancel() }
        for _ in 0..<10 {
            item.preferredTextMode = TextViewMode.player.rawValue
            ReaderPersistence.scheduleSave(context)
        }
        item.scrollSpeed = 8
        ReaderPersistence.scheduleSave(context)
        XCTAssertEqual(saves, 0, "The gesture must return without synchronously saving")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(saves, 1)
        let reloaded = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<FileItem>()).first)
        XCTAssertEqual(reloaded.preferredTextMode, TextViewMode.player.rawValue)
        XCTAssertEqual(reloaded.scrollSpeed, 8)

        item.preferredTextMode = TextViewMode.original.rawValue
        ReaderPersistence.scheduleSave(context)
        ReaderPersistence.flush(context)
        XCTAssertEqual(saves, 2, "Inactivity must save immediately even during the delay")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(saves, 2, "The cancelled delayed save must not run again")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FileItem>()).first?.preferredTextMode,
                       TextViewMode.original.rawValue)
    }

    @MainActor
    func testBrowserIndexAppliesRealSaveNotificationsWithoutFullRebuild() async throws {
        let schema = Schema([FileItem.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.autosaveEnabled = false
        let files = (0..<1_000).map { FileItem(bookmark: Data(), filename: "\($0).txt") }
        for file in files { context.insert(file) }
        try context.save()
        let index = LibraryBrowserIndex()
        await index.rebuild(files, libraryID: nil)
        let revision = index.revision
        var notification: Notification?
        let subscription = NotificationCenter.default.publisher(for: ModelContext.didSave).sink { saved in
            if saved.object as? ModelContext === context { notification = saved }
        }
        defer { subscription.cancel() }
        let item = files[500]
        item.preferredTextMode = TextViewMode.player.rawValue
        item.scrollSpeed = 8
        try context.save()
        XCTAssertTrue(index.applySavedChanges(try XCTUnwrap(notification), context: context, libraryID: nil))
        XCTAssertEqual(index.revision, revision, "Reader-only settings must not invalidate the library query")

        item.lastOpenedAt = .now
        item.playCount = 2
        try context.save()
        XCTAssertTrue(index.applySavedChanges(try XCTUnwrap(notification), context: context, libraryID: nil))
        await index.filter(.init(sort: "mostPlayed", revision: index.revision))
        XCTAssertEqual(index.visible.first?.id, item.id)
        XCTAssertEqual(index.recent.first?.id, item.id)

        item.composer = "Bach"
        item.customTitle = "Updated title"
        item.tags = ["practice"]
        item.isFavorite = true
        try context.save()
        XCTAssertTrue(index.applySavedChanges(try XCTUnwrap(notification), context: context, libraryID: nil))
        await index.filter(.init(search: "Bach", tag: "practice", favorites: true, revision: index.revision))
        XCTAssertEqual(index.visible.map(\.id), [item.id])

        context.delete(item)
        try context.save()
        XCTAssertFalse(index.applySavedChanges(try XCTUnwrap(notification), context: context, libraryID: nil),
                       "Membership changes must still schedule full reconciliation")
        XCTAssertFalse(index.applySavedChanges(Notification(name: ModelContext.didSave), context: context, libraryID: nil),
                       "Unknown payloads must not leave stale catalog rows")
    }

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    @MainActor
    func testSyncPreferenceControlsMetadataConfiguration() {
        let off = TabBuddyApp.makeConfigurations(syncEnabled: false, cloudAvailable: true)
        let on = TabBuddyApp.makeConfigurations(syncEnabled: true, cloudAvailable: true)
        let unavailable = TabBuddyApp.makeConfigurations(syncEnabled: true, cloudAvailable: false)
        XCTAssertTrue(off.allSatisfy { $0.cloudKitContainerIdentifier == nil })
        XCTAssertEqual(on.first?.cloudKitContainerIdentifier, LibraryFileService.ubiquityContainerID)
        XCTAssertNil(on.last?.cloudKitContainerIdentifier, "Device authorization must never sync")
        XCTAssertTrue(unavailable.allSatisfy { $0.cloudKitContainerIdentifier == nil })
        XCTAssertEqual(off.map(\.url), on.map(\.url), "Switching sync must reopen the same stores")
    }

    @MainActor
    func testMetadataSurvivesSyncConnectionReload() async throws {
        let suite = "sync-reload-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self,
                             LibraryMoveJob.self, TagStat.self, ComposedTab.self])
        let root = try XCTUnwrap(temporaryRoot)
        var requested: [Bool] = []
        let persistence = LibraryPersistence(defaults: defaults, buildContainer: { enabled in
            requested.append(enabled)
            let configs = TabBuddyApp.makeConfigurations(syncEnabled: enabled, cloudAvailable: false).map {
                ModelConfiguration($0.name, schema: $0.schema, url: root.appendingPathComponent($0.name + ".store"), cloudKitDatabase: .none)
            }
            return try! ModelContainer(for: schema, configurations: configs)
        }, finishWork: {})
        let id = UUID()
        do {
            let context = try XCTUnwrap(persistence.container?.mainContext)
            let file = FileItem(bookmark: Data(), filename: "practice.gp")
            file.id = id
            file.tags = ["Practicing"]
            file.isFavorite = true
            context.insert(file)
            try context.save()
        }
        for enabled in [true, false] {
            LibrarySyncPreference.set(enabled, in: defaults)
            await persistence.reloadIfNeeded()
            XCTAssertNil(persistence.container)
            persistence.reopen()
            let files = try XCTUnwrap(persistence.container).mainContext.fetch(FetchDescriptor<FileItem>())
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(files.first?.id, id)
            XCTAssertEqual(files.first?.tags, ["Practicing"])
            XCTAssertEqual(files.first?.isFavorite, true)
        }
        XCTAssertEqual(requested, [false, true, false])
    }

    @MainActor
    func testSwitchingOffSyncRetainsLibraryAndPersistsUnifiedPreference() async throws {
        let suite = "sync-toggle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = temporaryRoot.appendingPathComponent("Cloud")
        let local = temporaryRoot.appendingPathComponent("Local")
        let service = LibraryFileService(localDocumentsURL: local, cloudContainer: { cloud })
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let manager = LibraryManager(files: service, defaults: defaults)
        manager.configureManaged(context: context)
        for _ in 0..<100 {
            if manager.isConfigured && !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(LibrarySyncPreference.isEnabled(in: defaults))
        let source = temporaryRoot.appendingPathComponent("practice.txt")
        try Data("practice".utf8).write(to: source)
        _ = try await manager.importFiles([source], context: context)
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<FileItem>()).first)
        item.tags = ["Practicing"]
        let id = item.id
        manager.moveLibrary(to: .managedLocal, context: context)
        for _ in 0..<100 {
            if !manager.isMoving { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(LibrarySyncPreference.isEnabled(in: defaults))
        XCTAssertEqual(manager.mode, .managedLocal)
        XCTAssertNil(manager.lastError)
        let retained = try XCTUnwrap(context.fetch(FetchDescriptor<FileItem>()).first)
        XCTAssertEqual(retained.id, id)
        XCTAssertEqual(retained.tags, ["Practicing"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Documents/Tab Buddy Library/practice.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("Tab Buddy Library/practice.txt").path))
        let descriptor = try XCTUnwrap(context.fetch(FetchDescriptor<LibraryDescriptor>()).first)
        XCTAssertEqual(descriptor.mode, .managedICloud, "Turning sync off here must not redirect other devices")
        await manager.finishDatabaseWork()
    }

    func testOfflineCopiesRemainReadableWithoutChangingCloudStorage() async throws {
        let cloud = temporaryRoot.appendingPathComponent("Cloud")
        let service = LibraryFileService(localDocumentsURL: temporaryRoot.appendingPathComponent("Local"), cloudContainer: { cloud })
        let id = UUID()
        let root = try await service.configureManagedLibrary(id: id)
        let source = root.appendingPathComponent("practice.gp")
        let original = Data("original".utf8)
        try original.write(to: source)
        try await service.prepareOfflineCopies(records: service.scan())
        await service.setOfflineAccess(true)
        // A local copy must still open when the iCloud file is not materialized.
        try FileManager.default.removeItem(at: source)
        let lease = try await service.acquireFile(relativePath: "practice.gp")
        XCTAssertEqual(try Data(contentsOf: lease.url), original)
        XCTAssertFalse(lease.url.path.hasPrefix(cloud.path))
        lease.close()
        let updated = Data("updated copy".utf8)
        try updated.write(to: source)
        try await service.prepareOfflineCopies(records: service.scan())
        let paths = try await service.cachedPaths(libraryID: id)
        XCTAssertEqual(paths, ["practice.gp"])
        // Removing the cache leaves the actual synced library untouched.
        try await service.removeOfflineCopies(libraryID: id)
        XCTAssertEqual(try Data(contentsOf: source), updated)
        let remaining = try await service.cachedPaths(libraryID: id)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testEmbeddedMetadataWritesSourceAndNeverOfflineFallback() async throws {
        let cloud = temporaryRoot.appendingPathComponent("MetadataCloud")
        let service = LibraryFileService(localDocumentsURL: temporaryRoot.appendingPathComponent("Local"), cloudContainer: { cloud })
        let root = try await service.configureManagedLibrary(id: UUID())
        let source = root.appendingPathComponent("score.txt")
        let original = Data("e|--0--|\nB|--1--|\n".utf8)
        try original.write(to: source)
        try await service.prepareOfflineCopies(records: service.scan())
        await service.setOfflineAccess(true)
        try FileManager.default.removeItem(at: source)
        do {
            try await service.writeEmbeddedMetadata(.init(title: "Changed"), relativePath: "score.txt")
            XCTFail("Must not edit the fallback cache when the source is missing")
        } catch { XCTAssertEqual(error as? LibraryFileError, .fileMissing) }
        let cached = try await service.acquireFile(relativePath: "score.txt")
        XCTAssertEqual(try Data(contentsOf: cached.url), original)
        cached.close()
        try original.write(to: source)
        let metadata = EmbeddedScoreMetadata(title: "Portable title", instruments: ["guitar"], sourceID: "123")
        try await service.writeEmbeddedMetadata(metadata, relativePath: "score.txt")
        let read = try await service.readEmbeddedMetadata(relativePath: "score.txt")
        XCTAssertEqual(read, metadata)
        XCTAssertEqual(try EmbeddedScoreMetadata.textBody(Data(contentsOf: source)), original)
    }

    func testLocalLibraryCopiesImportsWithoutICloud() async throws {
        let documents = temporaryRoot.appendingPathComponent("Local")
        let service = LibraryFileService(localDocumentsURL: documents, cloudContainer: { nil })
        let id = UUID()
        let root = try await service.configureManagedLibrary(id: id, mode: .managedLocal)
        let source = temporaryRoot.appendingPathComponent("song.gp")
        let data = Data("guitar-pro-fixture".utf8)
        try data.write(to: source)
        let imported = try await service.importFiles([source])
        XCTAssertEqual(imported.map(\.relativePath), ["song.gp"])
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("song.gp")), data)
        let storedID = try await service.existingManagedLibraryID(mode: .managedLocal)
        XCTAssertEqual(storedID, id)
        do {
            _ = try await service.configureManagedLibrary(id: id, mode: .managedICloud)
            XCTFail("An unavailable cloud container must not replace the local library")
        } catch { XCTAssertEqual(error as? LibraryFileError, .iCloudUnavailable) }
        let lease = try await service.acquireFile(relativePath: "song.gp")
        defer { lease.close() }
        XCTAssertEqual(lease.url, root.appendingPathComponent("song.gp"))
    }

    func testManagedStorageMigrationKeepsSourcesAndCanReturnLocal() async throws {
        let cloud = temporaryRoot.appendingPathComponent("Cloud")
        let service = LibraryFileService(localDocumentsURL: temporaryRoot.appendingPathComponent("Local"), cloudContainer: { cloud })
        let id = UUID()
        let local = try await service.configureManagedLibrary(id: id, mode: .managedLocal)
        try Data("practice".utf8).write(to: local.appendingPathComponent("song.txt"))
        let records = [LibraryMoveRecord(relativePath: "song.txt", byteSize: 8, knownFingerprint: nil)]
        let synced = try await service.moveLibrary(to: .managedICloud, externalParent: nil, records: records, libraryID: id)
        XCTAssertEqual(synced.configuration.mode, .managedICloud)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("song.txt").path))
        XCTAssertEqual(try Data(contentsOf: synced.rootURL.appendingPathComponent("song.txt")), Data("practice".utf8))
        let returned = try await service.moveLibrary(to: .managedLocal, externalParent: nil, records: records, libraryID: id)
        XCTAssertEqual(returned.rootURL, local)
        XCTAssertTrue(FileManager.default.fileExists(atPath: synced.rootURL.appendingPathComponent("song.txt").path))
    }

    @MainActor
    func testSetupFallsBackToLocalAndRestoresDeviceChoice() async throws {
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let suite = "storage-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = LibraryFileService(localDocumentsURL: temporaryRoot.appendingPathComponent("Local"), cloudContainer: { nil })
        let manager = LibraryManager(files: service, defaults: defaults)
        manager.configureManaged(context: context, useICloud: true)
        for _ in 0..<100 {
            if manager.isConfigured && !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(manager.mode, .managedLocal)
        XCTAssertFalse(LibrarySyncPreference.isEnabled(in: defaults))
        XCTAssertNil(manager.lastError)
        let first = temporaryRoot.appendingPathComponent("first.txt")
        let second = temporaryRoot.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("first".utf8).write(to: second)
        _ = try await manager.importFiles([first], context: context)
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<FileItem>()).first)
        original.contentHash = FileItem.fingerprint(of: first)
        _ = try await manager.importFiles([second], context: context)
        let catalog = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(catalog.count, 2)
        for item in catalog {
            XCTAssertEqual(manager.availability(of: item, context: context), .available,
                           "Importing another song must not mark existing songs missing")
        }
        let reopened = LibraryManager(files: service, defaults: defaults)
        reopened.bootstrap(context: context)
        XCTAssertEqual(reopened.activeLibraryID, manager.activeLibraryID)
        XCTAssertEqual(reopened.mode, .managedLocal)

        let host = UIHostingController(rootView: LibraryStorageSettings(libraryManager: reopened, chooseFolder: { _ in })
            .modelContainer(container))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Local library storage settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRelativePathRejectsTraversalAndPrefixCollisions() throws {
        XCTAssertThrowsError(try LibraryFileService.normalizedRelativePath("../outside.pdf"))
        XCTAssertThrowsError(try LibraryFileService.normalizedRelativePath("/absolute.pdf"))
        XCTAssertEqual(try LibraryFileService.normalizedRelativePath("Jazz/Standards/song.pdf"),
                       "Jazz/Standards/song.pdf")

        let sibling = temporaryRoot.deletingLastPathComponent()
            .appendingPathComponent(temporaryRoot.lastPathComponent + "-other/file.pdf")
        XCTAssertFalse(LibraryFileService.contains(sibling, in: temporaryRoot))
    }

    func testRelativePathsAcceptAliasesButRejectLinksOutsideRoot() throws {
        let realRoot = temporaryRoot.appendingPathComponent("Actual Library", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let alias = temporaryRoot.appendingPathComponent("Picker Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realRoot)
        let realFile = realRoot.appendingPathComponent("song.txt")
        try Data("tab".utf8).write(to: realFile)
        XCTAssertEqual(try LibraryFileService.relativePath(of: realFile, under: alias), "song.txt")
        XCTAssertTrue(LibraryFileService.contains(realFile, in: alias))
        XCTAssertEqual(try LibraryFileService.relativePath(of: alias.appendingPathComponent("song.txt"), under: realRoot), "song.txt")

        let outside = temporaryRoot.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = realRoot.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escapedFile = link.appendingPathComponent("new.txt")
        XCTAssertFalse(LibraryFileService.contains(escapedFile, in: realRoot))
        XCTAssertThrowsError(try LibraryFileService.relativePath(of: escapedFile, under: realRoot))
    }

    func testCollisionNamingNeverOverwrites() throws {
        let requested = temporaryRoot.appendingPathComponent("song.pdf")
        try Data("first".utf8).write(to: requested)
        let second = LibraryFileService.availableDestination(for: requested)
        XCTAssertEqual(second.lastPathComponent, "song (2).pdf")
        try Data("second".utf8).write(to: second)
        XCTAssertEqual(LibraryFileService.availableDestination(for: requested).lastPathComponent,
                       "song (3).pdf")
    }

    func testMarkerRejectsDifferentLibrary() async throws {
        let service = LibraryFileService()
        let expected = UUID()
        try await service.validateOrCreateMarker(at: temporaryRoot, libraryID: expected)
        try await service.validateOrCreateMarker(at: temporaryRoot, libraryID: expected,
                                                  mayCreate: false)
        do {
            try await service.validateOrCreateMarker(at: temporaryRoot, libraryID: UUID(),
                                                      mayCreate: false)
            XCTFail("Expected marker mismatch")
        } catch {
            XCTAssertEqual(error as? LibraryFileError, .markerMismatch)
        }
    }

    func testMoveRejectsDifferentLibraryBeforeCopying() async throws {
        let source = temporaryRoot.appendingPathComponent("Source", isDirectory: true)
        let destination = temporaryRoot.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let payload = Data("tab".utf8)
        try payload.write(to: source.appendingPathComponent("song.txt"))

        let service = LibraryFileService()
        try await service.validateOrCreateMarker(at: destination, libraryID: UUID())

        do {
            try await LibraryFileService.copyLibraryContents(
                from: source,
                to: destination,
                records: [LibraryMoveRecord(relativePath: "song.txt",
                                            byteSize: Int64(payload.count),
                                            knownFingerprint: nil)],
                libraryID: UUID()
            )
            XCTFail("Expected marker mismatch")
        } catch {
            XCTAssertEqual(error as? LibraryFileError, .markerMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("song.txt").path
        ))
    }

    func testMoveRejectsSameSizeConflictingDestination() async throws {
        let source = temporaryRoot.appendingPathComponent("Source", isDirectory: true)
        let destination = temporaryRoot.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("AAAA".utf8).write(to: source.appendingPathComponent("song.txt"))
        try Data("BBBB".utf8).write(to: destination.appendingPathComponent("song.txt"))

        do {
            try await LibraryFileService.copyLibraryContents(
                from: source,
                to: destination,
                records: [LibraryMoveRecord(relativePath: "song.txt", byteSize: 4,
                                            knownFingerprint: nil)],
                libraryID: UUID()
            )
            XCTFail("Expected conflicting destination failure")
        } catch {
            guard case .copyFailed = error as? LibraryFileError else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("song.txt")),
                       Data("BBBB".utf8))
    }

    @MainActor
    func testReconcileRelinksRenamedFileWithoutLosingMetadata() async throws {
        let renamedURL = temporaryRoot.appendingPathComponent("renamed.txt")
        let payload = Data("favorite tab".utf8)
        try payload.write(to: renamedURL)
        let libraryID = UUID()
        try await LibraryFileService.shared.configureTestingRoot(temporaryRoot,
                                                                  libraryID: libraryID)
        addTeardownBlock {
            await LibraryFileService.shared.clearTestingRoot()
        }

        let schema = Schema([
            FileItem.self, LibraryDescriptor.self, TagStat.self, ComposedTab.self,
            LibraryMount.self, FilePresence.self, LibraryMoveJob.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let descriptor = LibraryDescriptor(id: libraryID, mode: .externalFolder,
                                           displayName: "Test Library")
        let item = FileItem(bookmark: Data(), filename: "original.txt", isFavorite: true,
                            tags: ["practice"], libraryPath: "original.txt")
        item.libraryID = libraryID
        item.storageRelativePath = "original.txt"
        item.contentHash = FileItem.fingerprint(of: renamedURL)
        context.insert(descriptor)
        context.insert(item)
        try context.save()

        let values = try renamedURL.resourceValues(forKeys: [.fileSizeKey,
                                                              .contentModificationDateKey])
        let record = LibraryFileRecord(relativePath: "renamed.txt", filename: "renamed.txt",
                                       byteSize: Int64(values.fileSize ?? 0), modificationDate: values.contentModificationDate)
        await LibraryManager.shared.reconcile(records: [record], descriptor: descriptor, context: context,
                                             isCompleteScan: false, readMetadata: false)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FileItem>()).count, 2, "Discovery can persist a provisional path before rename matching")
        await LibraryManager.shared.reconcile(records: [record], descriptor: descriptor, context: context,
                                             provisionalPaths: ["renamed.txt"], reportProgress: false)


        let files = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.id, item.id)
        XCTAssertEqual(files.first?.storageRelativePath, "renamed.txt")
        XCTAssertEqual(files.first?.tags, ["practice"])
        XCTAssertEqual(files.first?.isFavorite, true)
    }

    func testLeaseReleasesExactlyOnce() {
        var releaseCount = 0
        let lease = FileAccessLease(url: temporaryRoot) { releaseCount += 1 }
        lease.close()
        lease.close()
        XCTAssertEqual(releaseCount, 1)
    }

    func testFiveThousandFileMetadataScanKeepsDuplicateNames() async throws {
        for folderIndex in 0..<50 {
            let folder = temporaryRoot.appendingPathComponent("Folder \(folderIndex)",
                                                               isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for fileIndex in 0..<100 {
                let name = fileIndex == 0 ? "duplicate.txt" : "tab-\(fileIndex).txt"
                try Data().write(to: folder.appendingPathComponent(name))
            }
        }
        let service = LibraryFileService()
        try await service.configureTestingRoot(temporaryRoot)
        let records = try await service.scan()
        await service.clearTestingRoot()

        XCTAssertEqual(records.count, 5_000)
        XCTAssertEqual(records.filter { $0.filename == "duplicate.txt" }.count, 50)
        XCTAssertTrue(records.allSatisfy { $0.byteSize == 0 })
    }

    func testImportPreservesFoldersAndResolvesCollisions() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabBuddyImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let nested = source.appendingPathComponent("Artist", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("tab".utf8).write(to: nested.appendingPathComponent("song.txt"))

        let service = LibraryFileService()
        try await service.configureTestingRoot(temporaryRoot)
        let first = try await service.importFiles([source])
        let second = try await service.importFiles([source])
        await service.clearTestingRoot()

        XCTAssertEqual(first.first?.relativePath, "Artist/song.txt")
        XCTAssertEqual(second.first?.relativePath, "Artist/song (2).txt")
    }
    func testEmptyAndMissingFoldersDoNotReportSuccessfulImports() async throws {
        let source = temporaryRoot.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let service = LibraryFileService()
        try await service.configureTestingRoot(temporaryRoot.appendingPathComponent("Destination"))
        do {
            _ = try await service.importFiles([source])
            XCTFail("An empty folder must explain why nothing was imported")
        } catch {
            XCTAssertEqual(error as? LibraryFileError, .noImportableFiles)
        }
        do {
            _ = try await service.importFiles([source.appendingPathComponent("Missing")])
            XCTFail("An inaccessible source must fail rather than appear empty")
        } catch {
            XCTAssertNotEqual(error as? LibraryFileError, .noImportableFiles)
        }
    }

    @MainActor
    func testUsingExistingFolderScansExactRootAndRetainsPreviousLibrary() async throws {
        let suite = "existing-folder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let service = LibraryFileService(localDocumentsURL: temporaryRoot.appendingPathComponent("App"), cloudContainer: { nil })
        let manager = LibraryManager(files: service, defaults: defaults)
        manager.configureManaged(context: context, useICloud: false)
        for _ in 0..<100 {
            if !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let previousID = try XCTUnwrap(manager.activeLibraryID)
        let source = temporaryRoot.appendingPathComponent("song.txt")
        try Data("old tab".utf8).write(to: source)
        _ = try await manager.importFiles([source], context: context)
        let oldItem = try XCTUnwrap(context.fetch(FetchDescriptor<FileItem>()).first)
        oldItem.tags = ["Practice"]
        let backup = try XCTUnwrap(BackupManager.exportJSON(context: context))
        let selected = temporaryRoot.appendingPathComponent("Existing Collection", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try Data("existing tab".utf8).write(to: selected.appendingPathComponent("song.txt"))
        manager.useExistingFolder(url: selected, context: context)
        for _ in 0..<150 {
            if !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.mode, .externalFolder)
        let activeID = try XCTUnwrap(manager.activeLibraryID)
        XCTAssertNotEqual(activeID, previousID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.appendingPathComponent(LibraryFileService.managedFolderName).path))
        XCTAssertEqual(try LibraryFileService.existingLibraryID(at: selected), activeID)
        let all = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(all.filter { $0.libraryID == activeID }.map(\.filename), ["song.txt"])
        XCTAssertEqual(all.filter { $0.libraryID == previousID }.count, 1)
        oldItem.tags = ["Keep old metadata"]
        XCTAssertEqual(BackupManager.importJSON(data: backup, context: context, libraryID: activeID), 1)
        XCTAssertEqual(oldItem.tags, ["Keep old metadata"])
        XCTAssertEqual(all.first { $0.libraryID == activeID }?.tags, ["Practice"])
        manager.useExistingFolder(url: selected, context: context)
        for _ in 0..<150 {
            if !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(manager.activeLibraryID, activeID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FileItem>()).count, 2)
    }

    @MainActor
    func testIncrementalImportCommitsRemainderAfterCancellation() async throws {
        try await verifyPartialImport(cancel: true)
    }

    @MainActor
    func testIncrementalImportCommitsRemainderAfterCopyFailure() async throws {
        try await verifyPartialImport(cancel: false)
    }

    @MainActor
    private func verifyPartialImport(cancel: Bool) async throws {
        let service = LibraryFileService(localDocumentsURL: temporaryRoot.appendingPathComponent("Library"), cloudContainer: { nil })
        let suite = "incremental-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LibraryManager(files: service, defaults: defaults)
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        manager.configureManaged(context: context, useICloud: false)
        for _ in 0..<100 {
            if manager.isConfigured && !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(manager.isConfigured)
        let sources = try (0..<8).map { index -> URL in
            let url = temporaryRoot.appendingPathComponent("source-\(index).txt")
            let data = try EmbeddedScoreMetadata(title: "Score \(index)").writing(to: Data("e|--0-1-3--|\nB|---------|\nG|---------|\nD|---------|\nA|---------|\nE|---------|\n".utf8), extension: "txt")
            try data.write(to: url)
            return url
        }
        let verifyFirst: @MainActor @Sendable () -> Void = {
            XCTAssertEqual(try? context.fetch(FetchDescriptor<FileItem>()).count, 1)
        }
        // Cancelling a child task leaves the test itself able to inspect results.
        let job = Task { @MainActor in
            try await manager.importFiles(sources, context: context) { done, _ in
                if done == 1 {
                    await verifyFirst()
                }
                if done == 3 {
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    else { try? FileManager.default.removeItem(at: sources[3]) }
                }
            }
        }
        do {
            _ = try await job.value
            XCTFail("The import should stop after three copies")
        } catch {
            if cancel { XCTAssertTrue(error is CancellationError) }
            else { XCTAssertFalse(error is CancellationError) }
        }
        let retained = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(retained.count, 3, "Flush the partial batch even after failure/cancellation")
        XCTAssertTrue(retained.allSatisfy { $0.embeddedTitle == nil && $0.backgroundProcessingVersion == 0 }, "Fast imports must defer parsing")
        manager.startBackgroundProcessing(context: context, automatic: false)
        let handoff = manager.scanProgress.$total.sink { total in
            if total > 0 { XCTAssertFalse(manager.isProcessingLibrary, "Preparation must finish before a rescan enumerates/reconciles") }
        }
        manager.rescan(context: context)
        for _ in 0..<200 {
            if !manager.isRescanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(manager.isRescanning)
        XCTAssertFalse(manager.isProcessingLibrary)
        handoff.cancel()
        manager.startBackgroundProcessing(context: context, automatic: false)
        for _ in 0..<200 {
            if !manager.isProcessingLibrary { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(manager.isProcessingLibrary)
        XCTAssertEqual(Set(retained.compactMap(\.embeddedTitle)), ["Score 0", "Score 1", "Score 2"])
        XCTAssertTrue(retained.allSatisfy { $0.backgroundProcessingVersion == CanonicalConverterVersion.current })
        XCTAssertTrue(retained.allSatisfy { $0.canonicalVersion == CanonicalConverterVersion.current }, "Background text preparation should generate usable tab data")
        manager.startBackgroundProcessing(context: context, automatic: false)
        XCTAssertFalse(manager.isProcessingLibrary, "Completed files should not be processed again")
        XCTAssertEqual(manager.processingPrepared, 3)
        XCTAssertEqual(manager.processingFailed, 0)
        XCTAssertEqual(manager.processingDeferred, 0)
        let missing = FileItem(bookmark: Data(), filename: "missing.txt")
        missing.libraryID = manager.activeLibraryID
        missing.storageRelativePath = "missing.txt"
        context.insert(missing)
        manager.startBackgroundProcessing(context: context, automatic: false)
        for _ in 0..<200 {
            if !manager.isProcessingLibrary { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(manager.isProcessingLibrary)
        XCTAssertEqual(manager.processingChecked, 1)
        XCTAssertEqual(manager.processingPrepared, 0)
        XCTAssertEqual(manager.processingFailed, 1)
        XCTAssertEqual(manager.processingDeferred, 0, "Missing files are failures, not known cloud placeholders")
        XCTAssertTrue(manager.processingLastFailure?.contains("missing.txt") == true)
        XCTAssertNotNil(manager.processingSummary)
        XCTAssertEqual(missing.backgroundProcessingVersion, 0, "Failed files remain retryable")
        let stored = try await service.scan()
        XCTAssertEqual(stored.count, 3)
    }

    @MainActor
    func testDeferredCanonicalWritePreservesEditedTuning() async throws {
        let schema = Schema([FileItem.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let item = FileItem(bookmark: Data(), filename: "practice.txt")
        item.metadataEdited = true
        item.tuning = "My custom tuning"
        context.insert(item)
        try context.save()
        let map = TabParser.parse("e|--0-1-3--|\nB|---------|\nG|---------|\nD|---------|\nA|---------|\nE|---------|\n")
        CanonicalConverter.shared.convertOnOpen(item, context: context, prebuilt: (map, .txtDirect))
        for _ in 0..<200 {
            if item.canonicalVersion == CanonicalConverterVersion.current { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(item.canonicalVersion, CanonicalConverterVersion.current)
        XCTAssertEqual(item.tuning, "My custom tuning")
    }

    @MainActor
    func testPDFOpensFromExternalFolderAndMissingSourceReportsError() async throws {
        let root = temporaryRoot.appendingPathComponent("External PDFs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Practice score.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        let data = renderer.pdfData { context in
            context.beginPage()
            "Practice score".draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
        try data.write(to: source)
        let suite = "pdf-opening-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        manager.useExistingFolder(url: root, context: container.mainContext)
        for _ in 0..<200 {
            if !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<FileItem>()).first)
        let lease = try await manager.acquireFile(item)
        let url = lease.url
        let pages = try await Task.detached {
            var error: NSError?
            var pages: Int?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readableURL in
                pages = PDFDocument(url: readableURL)?.pageCount
            }
            if let error { throw error }
            return pages
        }.value
        lease.close()
        XCTAssertEqual(pages, 1)
        try FileManager.default.removeItem(at: source)
        do {
            let unexpected = try await manager.acquireFile(item)
            unexpected.close()
            XCTFail("A missing PDF must report a file-access error")
        } catch { XCTAssertEqual(error as? LibraryFileError, .fileMissing) }
    }

    func testBrowserIndexFiltersFoldersAndAllSortModes() throws {
        let now = Date()
        func row(_ name: String, favorite: Bool, count: Int, folder: String, instrument: String, days: Double) -> LibraryBrowserIndex.Row {
            .init(id: UUID(), name: name, search: name + " Composer Bach", tags: ["practice"], instruments: [instrument],
                  favorite: favorite, opened: now.addingTimeInterval(-days * 86400), imported: now.addingTimeInterval(-30 * 86400), playCount: count, path: folder + name)
        }
        let a = row("alpha", favorite: false, count: 8, folder: "Album/", instrument: "guitar", days: 1)
        let b = row("beta", favorite: true, count: 2, folder: "Album/Nested/", instrument: "piano", days: 2)
        let c = row("charlie", favorite: false, count: 4, folder: "", instrument: "guitar", days: 3)
        let rows = [c, b, a]
        XCTAssertEqual(LibraryBrowserIndex.evaluate(rows, request: .init(), now: now)?.ids, [b.id, a.id, c.id])
        XCTAssertEqual(LibraryBrowserIndex.evaluate(rows, request: .init(sort: "recent"), now: now)?.ids, [a.id, b.id, c.id])
        XCTAssertEqual(LibraryBrowserIndex.evaluate(rows, request: .init(sort: "mostPlayed"), now: now)?.ids, [a.id, c.id, b.id])
        XCTAssertEqual(LibraryBrowserIndex.evaluate(rows, request: .init(search: "BACH", instrument: "guitar", tag: "practice"), now: now)?.ids, [a.id, c.id])
        XCTAssertEqual(LibraryBrowserIndex.evaluate(rows, request: .init(favorites: true), now: now)?.ids, [b.id])
        let folder = try XCTUnwrap(LibraryBrowserIndex.evaluate(rows, request: .init(folderPrefix: "Album/"), now: now))
        XCTAssertEqual(folder.ids, [a.id])
        XCTAssertEqual(folder.folders["Nested"], [b.id])
        XCTAssertEqual(folder.recent, [a.id, b.id, c.id])
        XCTAssertEqual(LibraryBrowserIndex.evaluate(rows, request: .init(folderPrefix: ""), now: now)?.ids, [c.id])
    }

    func testBrowserIndexTwentyEightThousandRows() async throws {
        let rows = (0..<28_000).map { index in
            LibraryBrowserIndex.Row(id: UUID(), name: String(format: "%05d", 28_000 - index), search: "Score \(index) Bach", tags: [], instruments: ["guitar"], favorite: false, opened: .distantPast, imported: .distantPast, playCount: index, path: "Album/\(index).txt")
        }
        let result = await Task.detached {
            let start = ContinuousClock.now
            let result = LibraryBrowserIndex.evaluate(rows, request: .init(search: "Bach", sort: "mostPlayed"))
            print("28k cached search/sort: \(start.duration(to: .now))")
            return result
        }.value
        XCTAssertEqual(result?.ids.count, 28_000)
        XCTAssertEqual(result?.ids.first, rows.last?.id)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return LibraryBrowserIndex.evaluate(rows, request: .init())
        }
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
    }

    @MainActor
    func testBrowserIndexRefreshesEditsAndDeletion() async throws {
        let schema = Schema([FileItem.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let item = FileItem(bookmark: Data(), filename: "song.txt")
        context.insert(item)
        try context.save()
        let index = LibraryBrowserIndex()
        await index.rebuild([item], libraryID: nil)
        await index.filter(.init(search: "Bach", revision: index.revision))
        XCTAssertTrue(index.visible.isEmpty)
        item.composer = "Bach"
        try context.save()
        await index.rebuild([item], libraryID: nil)
        await index.filter(.init(search: "Bach", revision: index.revision))
        XCTAssertEqual(index.visible.map(\.id), [item.id])
        item.customTitle = "Renamed score"
        item.tuning = "EADGBE"
        await index.rebuild([item], libraryID: nil)
        await index.filter(.init(search: "Standard", revision: index.revision))
        XCTAssertEqual(index.visible.map(\.id), [item.id], "Normalized tuning names remain searchable")
        let all = LibraryBrowserIndex.Request(revision: index.revision)
        await index.filter(all)
        let delayed = Task { await index.filter(.init(search: "does not exist", revision: index.revision)) }
        try await Task.sleep(for: .milliseconds(20))
        await index.filter(all)
        await delayed.value
        XCTAssertEqual(index.visible.map(\.id), [item.id], "Returning to the cached query must invalidate an older in-flight search")
        let stale = LibraryBrowserIndex.Request(revision: index.revision)
        context.delete(item)
        try context.save()
        await index.rebuild([], libraryID: nil)
        await index.filter(.init(revision: index.revision))
        await index.filter(stale)
        XCTAssertTrue(index.visible.isEmpty, "An older query must not restore deleted results")
    }

    @MainActor
    func testPreparationOptInAndProgressDoNotInvalidateLibrary() throws {
        let suite = "preparation-preference-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LibraryManager(defaults: defaults)
        XCTAssertFalse(manager.automaticallyProcessesLibrary)
        manager.automaticallyProcessesLibrary = true
        XCTAssertTrue(LibraryManager(defaults: defaults).automaticallyProcessesLibrary)
        manager.automaticallyProcessesLibrary = false
        XCTAssertFalse(LibraryManager(defaults: defaults).automaticallyProcessesLibrary)
        var libraryUpdates = 0
        let subscription = manager.objectWillChange.sink { libraryUpdates += 1 }
        for count in 1...10_000 {
            manager.scanProgress.found = count
            manager.preparationProgress.value = .init(total: 10_000, checked: count)
        }
        XCTAssertEqual(libraryUpdates, 0, "Progress must update only the status views, not invalidate the library")
        subscription.cancel()
    }

    @MainActor
    func testPreparationBatchesResumeAfterPause() async throws {
        let root = temporaryRoot.appendingPathComponent("BatchPreparation")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<250 {
            try Data("Composer: Test Composer\nplain text".utf8).write(to: root.appendingPathComponent("\(index).txt"))
        }
        let suite = "preparation-batches-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        manager.useExistingFolder(url: root, context: context)
        for _ in 0..<300 {
            if !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(manager.isProcessingLibrary, "Adopting or scanning a library must not start preparation by default")
        let subscription = manager.preparationProgress.$value.sink { value in
            if value.prepared == 100 { manager.pauseBackgroundProcessing() }
        }
        manager.startBackgroundProcessing(context: context, automatic: false)
        for _ in 0..<500 {
            if !manager.isProcessingLibrary { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        subscription.cancel()
        XCTAssertEqual(manager.processingPrepared, 100)
        let stored = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(stored.filter { $0.backgroundProcessingVersion == CanonicalConverterVersion.current }.count, 100)
        manager.startBackgroundProcessing(context: context, automatic: false)
        for _ in 0..<500 {
            if !manager.isProcessingLibrary { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(manager.isProcessingLibrary)
        XCTAssertEqual(manager.processingTotal, 150)
        XCTAssertEqual(manager.processingPrepared, 150)
        XCTAssertTrue(stored.allSatisfy { $0.composer == "Test Composer" })
    }

    @MainActor
    func testExternalDiscoveryCheckpointSurvivesReopeningStore() async throws {
        let root = temporaryRoot.appendingPathComponent("External/New Folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<250 { try Data("tab".utf8).write(to: root.appendingPathComponent("\(index).txt")) }
        let suite = "discovery-checkpoint-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let store = temporaryRoot.appendingPathComponent("checkpoint.store")
        let configuration = ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        var sawDiscoveryCheckpoint = false
        let subscription = manager.scanProgress.$processed.sink { count in
            if count >= 100 {
                XCTAssertEqual(manager.rescanTotal, 0, "Must persist while discovery is still underway")
                sawDiscoveryCheckpoint = true
                manager.cancelScan()
            }
        }
        manager.useExistingFolder(url: root.deletingLastPathComponent(), context: container.mainContext)
        for _ in 0..<300 {
            if !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        subscription.cancel()
        XCTAssertTrue(sawDiscoveryCheckpoint)
        let reopened = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)])
        let retained = try reopened.mainContext.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(retained.count, 100)
        XCTAssertTrue(retained.allSatisfy { $0.libraryPath?.hasPrefix("New Folder/") == true })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 250)
    }

    @MainActor
    func testFolderReferenceRemovalIncludesDescendantsAndStopsPreparation() async throws {
        let root = temporaryRoot.appendingPathComponent("External")
        for path in ["Album/one.txt", "Album/Nested/two.txt", "Album Extras/keep.txt"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("tab".utf8).write(to: url)
        }
        let suite = "folder-removal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        manager.useExistingFolder(url: root, context: context)
        for _ in 0..<200 {
            if !manager.isConfiguring && !manager.isRescanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let all = try context.fetch(FetchDescriptor<FileItem>())
        let selected = LibraryManager.folderItems(in: all, relativeFolder: "Album")
        XCTAssertEqual(selected.count, 2)
        manager.startBackgroundProcessing(context: context, automatic: false)
        await manager.removeItems(selected, context: context)
        XCTAssertFalse(manager.isProcessingLibrary)
        XCTAssertNil(manager.lastError)
        let remaining = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(remaining.map(\.libraryPath), ["Album Extras/keep.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Album/one.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Album/Nested/two.txt").path))
    }

    @MainActor
    func testCatalogCancellationKeepsUnprocessedFilesAvailable() async throws {
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let manager = LibraryManager(files: LibraryFileService())
        let descriptor = LibraryDescriptor(mode: .externalFolder, displayName: "Cancellation")
        context.insert(descriptor)
        await manager.reconcile(records: [.init(relativePath: "retained.txt", filename: "retained.txt", byteSize: 0, modificationDate: nil)], descriptor: descriptor, context: context)
        let retained = try XCTUnwrap(context.fetch(FetchDescriptor<FileItem>()).first)
        let records = (0..<4800).map { LibraryFileRecord(relativePath: "Songs/\($0).txt", filename: "\($0).txt", byteSize: 0, modificationDate: nil) }
        var work: Task<Bool, Never>?
        let subscription = manager.scanProgress.$processed.sink { count in
            if count >= 100 {
                let verification = ModelContext(container)
                XCTAssertEqual(try? verification.fetch(FetchDescriptor<FileItem>()).count, 101,
                               "A separate context must see the checkpoint before cancellation")
                work?.cancel()
            }
        }
        work = Task { await manager.reconcile(records: records, descriptor: descriptor, context: context) }
        let completed = await work!.value
        XCTAssertFalse(completed)
        XCTAssertEqual(manager.rescanProcessed, 100)
        XCTAssertEqual(manager.rescanAdded, 100)
        XCTAssertEqual(manager.availabilityByFileID[retained.id], .available)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FileItem>()).count, 101)
        subscription.cancel()
    }

    @MainActor
    func testRescanDoesNotReadEmbeddedFileContents() async throws {
        let service = LibraryFileService(localDocumentsURL: temporaryRoot, cloudContainer: { nil })
        let id = UUID()
        let root = try await service.configureManagedLibrary(id: id, mode: .managedLocal)
        let data = try EmbeddedScoreMetadata(title: "Embedded title").writing(to: Data("score".utf8), extension: "txt")
        try data.write(to: root.appendingPathComponent("score.txt"))
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let descriptor = LibraryDescriptor(mode: .managedLocal, displayName: "Metadata")
        descriptor.id = id
        context.insert(descriptor)
        let manager = LibraryManager(files: service)
        let records = try await service.scan()
        await manager.reconcile(records: records, descriptor: descriptor, context: context)
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<FileItem>()).first)
        XCTAssertNil(item.embeddedTitle, "Catalog rescans must not open file contents")
        XCTAssertEqual(item.metadataReadVersion, 0)
        await manager.reconcile(records: records, descriptor: descriptor, context: context, isCompleteScan: false)
        XCTAssertEqual(item.embeddedTitle, "Embedded title", "Explicit imports still index available embedded metadata")
        await manager.reconcile(records: records, descriptor: descriptor, context: context)
        XCTAssertEqual(manager.rescanAdded, 0, "Existing files must not be counted as new")
        XCTAssertEqual(manager.rescanProcessed, 1)
    }

    @MainActor
    func testLargeCatalogScanPublishesOnceAndBulkRemovalPreservesExternalFiles() async throws {
        let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self, LibraryMoveJob.self, TagStat.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let manager = LibraryManager(files: LibraryFileService())
        manager.mode = .externalFolder
        let descriptor = LibraryDescriptor(mode: .externalFolder, displayName: "Large collection")
        context.insert(descriptor)
        let retained = FileItem(bookmark: Data(), filename: "retained.txt")
        retained.libraryID = UUID()
        retained.tags = ["Keep"]
        context.insert(retained)
        let sentinel = temporaryRoot.appendingPathComponent("song.txt")
        try Data("source".utf8).write(to: sentinel)
        let records = (0..<5000).map { LibraryFileRecord(relativePath: "Songs/\($0).txt", filename: "\($0).txt", byteSize: 0, modificationDate: nil) }
        var publications = 0
        let subscription = manager.$availabilityByFileID.dropFirst().sink { _ in publications += 1 }
        let scanStart = Date()
        await manager.reconcile(records: records, descriptor: descriptor, context: context)
        let scanTime = Date().timeIntervalSince(scanStart)
        XCTAssertEqual(publications, 1, "Do not invalidate the library UI for each scanned score")
        let selected = try context.fetch(FetchDescriptor<FileItem>()).filter { $0.libraryID == descriptor.id }
        XCTAssertEqual(selected.count, 5000)
        XCTAssertEqual(manager.rescanAdded, 5000)
        let removalStart = Date()
        await manager.removeItems(selected, context: context)
        print("5000-score catalog: scan \(scanTime)s, removal \(Date().timeIntervalSince(removalStart))s")
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FileItem>()).map(\.id), [retained.id])
        XCTAssertTrue(try context.fetch(FetchDescriptor<FilePresence>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TagStat>()).map(\.name), ["Keep"])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("source".utf8))
        XCTAssertEqual(publications, 2)
        subscription.cancel()
    }

}
