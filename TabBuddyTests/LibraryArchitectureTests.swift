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
    func testSwitchingOptionsNeverCopiesSongsAndReturnsToEachLocation() async throws {
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
        func settle() async throws {
            for _ in 0..<200 {
                if !manager.isConfiguring && !manager.isRescanning { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        manager.configureManaged(context: context)
        try await settle()
        XCTAssertEqual(manager.storageOption, .iCloudOnly)
        XCTAssertTrue(LibrarySyncPreference.isEnabled(in: defaults))
        let source = temporaryRoot.appendingPathComponent("practice.txt")
        try Data("practice".utf8).write(to: source)
        _ = try await manager.importFiles([source], context: context)
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<FileItem>()).first)
        item.tags = ["Practicing"]
        let id = item.id
        let cloudLibraryID = try XCTUnwrap(manager.activeLibraryID)
        let cloudRoot = cloud.appendingPathComponent("Documents/Tab Buddy Library")
        func listing(_ url: URL) -> [String] {
            ((try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? []).sorted()
        }
        let cloudBefore = listing(cloudRoot)

        XCTAssertEqual(manager.switchStorageOption(to: .localOnly, context: context), .started)
        try await settle()
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.storageOption, .localOnly)
        XCTAssertFalse(LibrarySyncPreference.isEnabled(in: defaults))
        XCTAssertEqual(manager.mode, .managedLocal)
        XCTAssertNotEqual(manager.activeLibraryID, cloudLibraryID)
        XCTAssertEqual(listing(cloudRoot), cloudBefore, "Switching must not touch the previous location")
        XCTAssertFalse(listing(local.appendingPathComponent("Tab Buddy Library")).contains("practice.txt"),
                       "Switching options must not copy songs")
        XCTAssertTrue(try context.fetch(FetchDescriptor<LibraryMoveJob>()).isEmpty, "No copy job is created")
        let retained = try XCTUnwrap(context.fetch(FetchDescriptor<FileItem>()).first { $0.id == id })
        XCTAssertEqual(retained.tags, ["Practicing"], "Library info for the other location is kept")

        XCTAssertEqual(manager.switchStorageOption(to: .iCloudOnly, context: context), .started)
        try await settle()
        XCTAssertEqual(manager.activeLibraryID, cloudLibraryID, "Switching back shows the same songs again")
        XCTAssertEqual(manager.mode, .managedICloud)
        XCTAssertTrue(manager.isShownOnThisDevice(retained))
        XCTAssertEqual(listing(cloudRoot), cloudBefore)
        let descriptor = try XCTUnwrap(context.fetch(FetchDescriptor<LibraryDescriptor>()).first { $0.id == cloudLibraryID })
        XCTAssertEqual(descriptor.mode, .managedICloud, "A device-local switch must not redirect other devices")
        XCTAssertTrue(try context.fetch(FetchDescriptor<LibraryMoveJob>()).isEmpty)
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
        let provisionalIDs = Set(try context.fetch(FetchDescriptor<FileItem>()).map(\.id)).subtracting([item.id])
        await LibraryManager.shared.reconcile(records: [record], descriptor: descriptor, context: context,
                                             provisionalPaths: ["renamed.txt"], locallyCreatedIDs: provisionalIDs,
                                             reportProgress: false)


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
        let markerID = try await LibraryFileService.existingLibraryID(at: selected)
        XCTAssertEqual(markerID, activeID)
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

/// Library options (Local only / iCloud only / Hybrid), duplicate merging, and
/// hidden-not-deleted behavior. Unsigned simulator tests run without CloudKit:
/// "two devices" are simulated by separate stores holding the records each device
/// would have after mirroring. These are not live iCloud sync tests.
final class LibraryStorageOptionTests: XCTestCase {
    private var temporaryRoot: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabBuddyOptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "library-options-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private static let schema = Schema([FileItem.self, LibraryDescriptor.self, LibraryMount.self, FilePresence.self,
                                        LibraryMoveJob.self, TagStat.self])

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Self.schema, configurations: [ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: true)])
    }

    @MainActor
    private func settle(_ manager: LibraryManager) async throws {
        for _ in 0..<300 {
            if !manager.isConfiguring && !manager.isRescanning && !manager.isMergingDuplicates { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func record(_ path: String, library: UUID, importedAt: Date, id: UUID = UUID()) -> FileItem {
        let item = FileItem(id: id, bookmark: Data(), filename: (path as NSString).lastPathComponent,
                            folderName: "", libraryPath: path, importedAt: importedAt)
        item.libraryID = library
        item.storageRelativePath = path
        return item
    }

    // MARK: Option model

    func testOptionMigratesFromLegacySyncFlagWithoutChoosingHybrid() throws {
        let synced = try makeDefaults()
        synced.set(true, forKey: LibrarySyncPreference.key)
        XCTAssertEqual(LibraryStorageOption.migrateIfNeeded(in: synced, activeMode: .managedICloud), .iCloudOnly)
        XCTAssertEqual(synced.string(forKey: LibraryStorageOption.key), "iCloudOnly")

        let external = try makeDefaults()
        external.set(false, forKey: LibrarySyncPreference.key)
        XCTAssertEqual(LibraryStorageOption.migrateIfNeeded(in: external, activeMode: .externalFolder), .localOnly,
                       "A chosen folder without sync must become Local only, never Hybrid")
        XCTAssertFalse(LibrarySyncPreference.isEnabled(in: external))

        let managedLocal = try makeDefaults()
        managedLocal.set(false, forKey: LibrarySyncPreference.key)
        XCTAssertEqual(LibraryStorageOption.migrateIfNeeded(in: managedLocal, activeMode: .managedLocal), .localOnly)

        let fresh = try makeDefaults()
        XCTAssertNil(LibraryStorageOption.migrateIfNeeded(in: fresh, activeMode: nil), "First run stays unset")
        XCTAssertNil(LibraryStorageOption.stored(in: fresh))

        let chosen = try makeDefaults()
        LibraryStorageOption.set(.hybrid, in: chosen)
        chosen.set(false, forKey: LibrarySyncPreference.key) // A stale legacy flag must not override the option.
        XCTAssertEqual(LibraryStorageOption.migrateIfNeeded(in: chosen, activeMode: .externalFolder), .hybrid)
        XCTAssertTrue(LibrarySyncPreference.isEnabled(in: chosen))
    }

    func testSettingOptionPostsReloadOnlyWhenMirroringChanges() throws {
        let defaults = try makeDefaults()
        var reloads = 0
        let observer = NotificationCenter.default.addObserver(forName: LibrarySyncPreference.didChange, object: defaults, queue: nil) { _ in reloads += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        LibraryStorageOption.set(.localOnly, in: defaults)
        XCTAssertEqual(reloads, 1, "The first choice replaces the unset connection")
        LibraryStorageOption.set(.hybrid, in: defaults)
        XCTAssertEqual(reloads, 2)
        LibraryStorageOption.set(.iCloudOnly, in: defaults)
        XCTAssertEqual(reloads, 2, "iCloud only and Hybrid both mirror; no reload")
        LibraryStorageOption.set(.localOnly, in: defaults)
        XCTAssertEqual(reloads, 3)
    }

    @MainActor
    func testConfigurationsMirrorOnlyForICloudOnlyAndHybrid() {
        for option in LibraryStorageOption.allCases {
            let configs = TabBuddyApp.makeConfigurations(option: option, cloudAvailable: true)
            let mirrored = configs.first?.cloudKitContainerIdentifier != nil
            XCTAssertEqual(mirrored, option != .localOnly, "\(option)")
            XCTAssertNil(configs.last?.cloudKitContainerIdentifier, "Device-local data never mirrors")
            XCTAssertTrue(TabBuddyApp.makeConfigurations(option: option, cloudAvailable: false).allSatisfy { $0.cloudKitContainerIdentifier == nil })
            XCTAssertEqual(TabBuddyApp.mirrorsMetadata(option: option, cloudAvailable: true), option != .localOnly)
            XCTAssertFalse(TabBuddyApp.mirrorsMetadata(option: option, cloudAvailable: false))
        }
        XCTAssertTrue(TabBuddyApp.makeConfigurations(option: nil, cloudAvailable: true).allSatisfy { $0.cloudKitContainerIdentifier == nil })
        XCTAssertEqual(TabBuddyApp.makeConfigurations(option: .localOnly, cloudAvailable: true).map(\.url),
                       TabBuddyApp.makeConfigurations(option: .hybrid, cloudAvailable: true).map(\.url),
                       "Every option opens the same store files")
    }

    // MARK: Switching

    @MainActor
    func testHybridReadsFolderInPlaceAndLocalOnlyKeepsTheSameFolder() async throws {
        let defaults = try makeDefaults()
        let folder = temporaryRoot.appendingPathComponent("My iCloud Drive Songs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: folder.appendingPathComponent("Album/one.txt"))
        try Data("two".utf8).write(to: folder.appendingPathComponent("two.gp"))
        let appDocuments = temporaryRoot.appendingPathComponent("App")
        let service = LibraryFileService(localDocumentsURL: appDocuments, cloudContainer: { nil })
        let container = try makeContainer()
        let context = container.mainContext
        let manager = LibraryManager(files: service, defaults: defaults)
        func listing() -> [String] { ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted() }

        manager.useExistingFolder(url: folder, context: context, option: .hybrid)
        try await settle(manager)
        XCTAssertEqual(manager.storageOption, .hybrid)
        XCTAssertTrue(LibrarySyncPreference.isEnabled(in: defaults))
        XCTAssertEqual(manager.mode, .externalFolder)
        let hybridID = try XCTUnwrap(manager.activeLibraryID)
        // Without a database reload in this test, the scan resumes from the pending flag.
        manager.rescan(context: context)
        try await settle(manager)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<FileItem>()).compactMap(\.effectiveRelativePath)), ["Album/one.txt", "two.gp"])
        let before = listing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: appDocuments.appendingPathComponent(LibraryFileService.managedFolderName).path))

        XCTAssertEqual(manager.plannedLocation(for: .localOnly), LibraryOptionLocation(libraryID: hybridID, mode: .externalFolder))
        let sameFolder = manager.switchConfirmation(to: .localOnly, context: context)
        XCTAssertTrue(sameFolder.hasPrefix("Songs aren’t copied or moved."), sameFolder)
        XCTAssertTrue(sameFolder.contains("stays on this device"), sameFolder)
        XCTAssertEqual(manager.switchStorageOption(to: .localOnly, context: context), .started)
        try await settle(manager)
        XCTAssertEqual(manager.storageOption, .localOnly)
        XCTAssertEqual(manager.activeLibraryID, hybridID, "Turning sync off keeps showing the same folder")
        XCTAssertEqual(listing(), before)
        XCTAssertEqual(manager.switchStorageOption(to: .hybrid, context: context), .started)
        try await settle(manager)
        XCTAssertEqual(manager.activeLibraryID, hybridID)
        XCTAssertEqual(listing(), before, "No option change adds, moves, or deletes files")
        XCTAssertTrue(try context.fetch(FetchDescriptor<LibraryMoveJob>()).isEmpty)

        manager.useAppFolder(context: context) // Only valid in Local only.
        XCTAssertEqual(manager.activeLibraryID, hybridID)
        await manager.finishDatabaseWork()
    }

    @MainActor
    func testHybridNeedsFolderWhenNoFolderIsKnown() async throws {
        let defaults = try makeDefaults()
        let cloud = temporaryRoot.appendingPathComponent("Cloud")
        let service = LibraryFileService(localDocumentsURL: temporaryRoot.appendingPathComponent("App"), cloudContainer: { cloud })
        let container = try makeContainer()
        let manager = LibraryManager(files: service, defaults: defaults)
        manager.configureManaged(context: container.mainContext, useICloud: true)
        try await settle(manager)
        XCTAssertEqual(manager.storageOption, .iCloudOnly)
        XCTAssertNil(manager.plannedLocation(for: .hybrid))
        XCTAssertTrue(manager.switchConfirmation(to: .hybrid, context: container.mainContext).contains("Choose the folder"))
        XCTAssertEqual(manager.switchStorageOption(to: .hybrid, context: container.mainContext), .needsFolder)
        XCTAssertEqual(manager.storageOption, .iCloudOnly, "Nothing changes until a folder is chosen")
    }

    // MARK: Hidden, never deleted

    @MainActor
    func testHybridHidesSongsMissingHereAndNeverDeletesThem() async throws {
        let defaults = try makeDefaults()
        let folder = temporaryRoot.appendingPathComponent("Shared Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("here".utf8).write(to: folder.appendingPathComponent("here.txt"))
        let container = try makeContainer()
        let context = container.mainContext
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        manager.useExistingFolder(url: folder, context: context, option: .hybrid)
        try await settle(manager)
        let libraryID = try XCTUnwrap(manager.activeLibraryID)
        // A record synced from the other device, whose file is only in that device's folder.
        let elsewhere = record("elsewhere.txt", library: libraryID, importedAt: .distantPast)
        elsewhere.tags = ["From iPad"]
        elsewhere.isFavorite = true
        elsewhere.playCount = 7
        context.insert(elsewhere)
        // A synced record whose file is also here but not yet confirmed on this device.
        try Data("later".utf8).write(to: folder.appendingPathComponent("later.txt"))
        let later = record("later.txt", library: libraryID, importedAt: .distantPast)
        context.insert(later)
        try context.save()
        XCTAssertFalse(manager.isShownOnThisDevice(elsewhere), "Unconfirmed records stay hidden in Hybrid")
        await manager.verifyUnknownPresence(context: context)
        XCTAssertTrue(manager.isShownOnThisDevice(later))
        XCTAssertFalse(manager.isShownOnThisDevice(elsewhere))

        manager.rescan(context: context)
        try await settle(manager)
        XCTAssertNil(manager.lastError)
        let all = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(all.count, 3, "A completed full scan never deletes records for missing files")
        XCTAssertEqual(manager.availabilityByFileID[elsewhere.id], .missing)
        XCTAssertFalse(manager.isShownOnThisDevice(elsewhere))
        XCTAssertEqual(elsewhere.tags, ["From iPad"])
        XCTAssertTrue(elsewhere.isFavorite)
        XCTAssertEqual(elsewhere.playCount, 7)

        let index = LibraryBrowserIndex()
        await index.rebuild(all, libraryID: libraryID, isShown: { manager.isShownOnThisDevice($0) })
        await index.filter(.init(revision: index.revision))
        XCTAssertEqual(Set(index.visible.map(\.filename)), ["here.txt", "later.txt"])

        // Remove All in Hybrid: catalog only, and never a song hidden on this device.
        await manager.removeItems(all, context: context)
        let remaining = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(remaining.map(\.id), [elsewhere.id])
        XCTAssertEqual(remaining.first?.tags, ["From iPad"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("here.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("later.txt").path))
        await manager.finishDatabaseWork()
    }

    func testMissingSongsHideInEveryOptionButUnknownOnlyInHybrid() {
        for option in LibraryStorageOption.allCases {
            XCTAssertFalse(LibraryManager.isShown(presence: .missing, inActiveLibrary: true, option: option))
            XCTAssertTrue(LibraryManager.isShown(presence: .available, inActiveLibrary: true, option: option))
            XCTAssertTrue(LibraryManager.isShown(presence: .downloading, inActiveLibrary: true, option: option))
        }
        XCTAssertFalse(LibraryManager.isShown(presence: nil, inActiveLibrary: true, option: .hybrid))
        XCTAssertTrue(LibraryManager.isShown(presence: nil, inActiveLibrary: true, option: .iCloudOnly))
        XCTAssertTrue(LibraryManager.isShown(presence: nil, inActiveLibrary: false, option: .hybrid), "Legacy records are not hidden")
    }

    func testRemovalConfirmationSaysWhatHappens() {
        let hybrid = LibraryManager.removalConfirmation(count: 3, all: false, option: .hybrid, mode: .externalFolder, folderName: "Tabs")
        XCTAssertEqual(hybrid.button, "Remove from Library")
        XCTAssertTrue(hybrid.message.contains("all your devices"))
        XCTAssertTrue(hybrid.message.contains("Files stay in “Tabs”"))
        let chosen = LibraryManager.removalConfirmation(count: 1, all: false, option: .localOnly, mode: .externalFolder, folderName: "Tabs")
        XCTAssertEqual(chosen.title, "Remove 1 song from the library?")
        XCTAssertFalse(chosen.message.contains("all your devices"))
        let cloud = LibraryManager.removalConfirmation(count: 10, all: true, option: .iCloudOnly, mode: .managedICloud, folderName: nil)
        XCTAssertEqual(cloud.title, "Delete all songs?")
        XCTAssertTrue(cloud.message.contains("all your devices"))
        let local = LibraryManager.removalConfirmation(count: 2, all: false, option: .localOnly, mode: .managedLocal, folderName: nil)
        XCTAssertEqual(local.button, "Delete")
        XCTAssertTrue(local.message.contains("on this device"))
        XCTAssertFalse(local.message.contains("all your devices"))
    }

    // MARK: Unauthorized folder on this device

    @MainActor
    func testSyncedHybridFolderNotYetChosenHereAsksForAccess() async throws {
        let defaults = try makeDefaults()
        LibraryStorageOption.set(.hybrid, in: defaults)
        let container = try makeContainer()
        let context = container.mainContext
        let libraryID = UUID()
        context.insert(LibraryDescriptor(id: libraryID, mode: .externalFolder, displayName: "iPad Songs"))
        let synced = record("song.pdf", library: libraryID, importedAt: .distantPast)
        context.insert(synced)
        try context.save()
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        manager.bootstrap(context: context)
        XCTAssertTrue(manager.isConfigured)
        XCTAssertEqual(manager.activeLibraryID, libraryID)
        XCTAssertEqual(manager.mode, .externalFolder)
        XCTAssertTrue(manager.accessNeeded, "This device must choose the folder before showing it")
        XCTAssertEqual(manager.libraryName, "iPad Songs")
        XCTAssertFalse(manager.isShownOnThisDevice(synced))
        XCTAssertEqual(try context.fetch(FetchDescriptor<FileItem>()).count, 1, "Nothing is deleted while access is missing")
        // Choosing a different library's folder is rejected rather than merged.
        let other = temporaryRoot.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await LibraryFileService().validateOrCreateMarker(at: other, libraryID: UUID())
        manager.configureExternal(url: other, context: context)
        try await settle(manager)
        XCTAssertEqual(manager.lastError, LibraryFileError.markerMismatch.localizedDescription)
        XCTAssertTrue(manager.accessNeeded)
    }

    // MARK: Discovery

    @MainActor
    func testDiscoveryReusesSyncedRecordInsteadOfInsertingDuplicate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let libraryID = UUID()
        let synced = record("Album/song.txt", library: libraryID, importedAt: .distantPast)
        synced.tags = ["Synced"]
        context.insert(synced)
        try context.save()
        // The scan's path index was built before iCloud imported the record.
        let discovery = LibraryDiscoveryIndex(paths: [])
        let batch = [LibraryFileRecord(relativePath: "Album/song.txt", filename: "song.txt", byteSize: 4, modificationDate: nil),
                     LibraryFileRecord(relativePath: "new.txt", filename: "new.txt", byteSize: 3, modificationDate: nil)]
        XCTAssertEqual(discovery.insert(batch, libraryID: libraryID, context: context), 1)
        XCTAssertEqual(discovery.insert(batch, libraryID: libraryID, context: context), 0)
        try context.save()
        let items = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.filter { $0.effectiveRelativePath == "Album/song.txt" }.map(\.id), [synced.id])
        XCTAssertEqual(discovery.drainInsertedPresence()[synced.id], .available)
        // Another library's record with the same path does not count.
        let otherLibrary = LibraryDiscoveryIndex(paths: [])
        XCTAssertEqual(otherLibrary.insert([batch[0]], libraryID: UUID(), context: context), 1)
    }

    func testScanCountsICloudPlaceholdersAsPresent() async throws {
        let root = temporaryRoot.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: root.appendingPathComponent("local.txt"))
        try Data().write(to: root.appendingPathComponent("Album/.evicted song.pdf.icloud"))
        try Data().write(to: root.appendingPathComponent(".hidden/secret.txt"))
        try Data().write(to: root.appendingPathComponent(".notes.txt"))
        try Data().write(to: root.appendingPathComponent("Album/.image.png.icloud"))
        let service = LibraryFileService()
        try await service.configureTestingRoot(root)
        let records = try await service.scan()
        XCTAssertEqual(records.map(\.relativePath), ["Album/evicted song.pdf", "local.txt"])
        XCTAssertEqual(records.first?.filename, "evicted song.pdf")
        let present = try await service.existingPaths(["Album/evicted song.pdf", "local.txt", "gone.txt"])
        XCTAssertEqual(present, ["Album/evicted song.pdf", "local.txt"])
        let lease = try await service.acquireFile(relativePath: "Album/evicted song.pdf", allowCloudPlaceholder: true)
        lease.close()
        await service.clearTestingRoot()
    }

    // MARK: Duplicate merge

    /// The same two catalogs as each device holds them after mirroring (inserted in a
    /// different order). Each device must pick the same survivor and merged values.
    @MainActor
    private func mergedSnapshot(insertInReverse: Bool, presence: FileAvailability?) async throws -> [String] {
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let ipadID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let iphoneID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let ipad = record("Games/Zelda.gp", library: library, importedAt: Date(timeIntervalSince1970: 1_000), id: ipadID)
        ipad.tags = ["Practice", "Zelda"]
        ipad.playCount = 12
        ipad.lastOpenedAt = Date(timeIntervalSince1970: 5_000)
        ipad.loopStartMeasure = 4
        ipad.loopEndMeasure = 8
        ipad.referenceBPM = 96
        ipad.canonicalFilename = "missing-canonical.musicxml"
        ipad.canonicalVersion = 40
        let iphone = record("games/zelda.gp", library: library, importedAt: Date(timeIntervalSince1970: 2_000), id: iphoneID)
        iphone.tags = ["Zelda", "Favorites"]
        iphone.isFavorite = true
        iphone.playCount = 3
        iphone.lastOpenedAt = Date(timeIntervalSince1970: 9_000)
        iphone.loopStartMeasure = 1
        iphone.loopEndMeasure = 2
        iphone.metadataEdited = true
        iphone.composer = "Koji Kondo"
        iphone.customTitle = "Zelda Theme"
        iphone.canonicalFilename = "present-canonical.musicxml"
        iphone.canonicalVersion = 30
        let items = insertInReverse ? [iphone, ipad] : [ipad, iphone]
        for item in items { context.insert(item) }
        try context.save()
        var availability: [UUID: FileAvailability] = [:]
        if let presence { for item in items { availability[item.id] = presence; context.insert(FilePresence(fileID: item.id, availability: presence)) } }
        try context.save()
        // iCloud Drive compares names case-insensitively.
        let summary = await LibraryDuplicateMerger.merge(context: context, presence: availability, fingerprintLibraryID: library,
                                                         caseInsensitivePaths: true,
                                                         canonicalExists: { $0 == (insertInReverse ? "present-canonical.musicxml" : "missing-canonical.musicxml") },
                                                         copyCanonical: { _, _ in })
        XCTAssertEqual(summary.remapped, [iphoneID: ipadID])
        let again = await LibraryDuplicateMerger.merge(context: context, presence: availability, fingerprintLibraryID: library,
                                                       caseInsensitivePaths: true)
        XCTAssertEqual(again.mergedGroups, 0, "Merging is idempotent")
        let survivors = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(survivors.count, 1)
        let s = try XCTUnwrap(survivors.first)
        if presence != nil {
            XCTAssertEqual(try context.fetch(FetchDescriptor<FilePresence>()).map(\.fileID), [ipadID], "Presence follows the survivor")
        }
        return [s.id.uuidString, s.tags.joined(separator: ","), "\(s.isFavorite)", "\(s.playCount)", "\(s.lastOpenedAt.timeIntervalSince1970)",
                "\(s.loopStartMeasure ?? -1)-\(s.loopEndMeasure ?? -1)", "\(s.referenceBPM ?? -1)", s.composer ?? "-",
                s.customTitle ?? "-", "\(s.metadataEdited)", s.canonicalFilename ?? "-", "\(s.canonicalVersion)", s.effectiveRelativePath ?? "-"]
    }

    @MainActor
    func testDuplicateMergeIsDeterministicAcrossDevicesAndMergesMetadata() async throws {
        let ipadView = try await mergedSnapshot(insertInReverse: false, presence: .available)
        let iphoneView = try await mergedSnapshot(insertInReverse: true, presence: nil)
        XCTAssertEqual(ipadView, iphoneView, "Both devices must reach the same survivor and values")
        XCTAssertEqual(ipadView, [
            "AAAAAAAA-0000-0000-0000-000000000001",   // earliest import survives
            "Practice,Zelda,Favorites",               // tags union
            "true", "12", "9000.0",                   // favorite OR, play count max, last opened max
            "1-2", "96.0",                            // loop from most recently opened; tempo filled
            "Koji Kondo", "Zelda Theme", "true",      // user-edited details win
            "missing-canonical.musicxml", "40",       // the survivor's canonical, whichever files exist on each device
            "Games/Zelda.gp"
        ])
    }

    @MainActor
    func testRenamedFileMergesByFingerprintOntoPresentCopy() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID()
        let old = record("Old Name.pdf", library: library, importedAt: Date(timeIntervalSince1970: 10))
        old.contentHash = "hash-1"
        old.tags = ["Keep"]
        let renamed = record("New Folder/New Name.pdf", library: library, importedAt: Date(timeIntervalSince1970: 20))
        renamed.contentHash = "hash-1"
        let unrelatedMissing = record("Gone.pdf", library: library, importedAt: Date(timeIntervalSince1970: 5))
        unrelatedMissing.contentHash = "hash-2"
        // Two present copies share a fingerprint: ambiguous, so their missing twin is left alone.
        let twinMissing = record("Twin.pdf", library: library, importedAt: Date(timeIntervalSince1970: 1))
        twinMissing.contentHash = "hash-3"
        let twinA = record("A/Twin.pdf", library: library, importedAt: Date(timeIntervalSince1970: 2))
        twinA.contentHash = "hash-3"
        let twinB = record("B/Twin.pdf", library: library, importedAt: Date(timeIntervalSince1970: 3))
        twinB.contentHash = "hash-3"
        for item in [old, renamed, unrelatedMissing, twinMissing, twinA, twinB] { context.insert(item) }
        let presence: [UUID: FileAvailability] = [old.id: .missing, renamed.id: .available, unrelatedMissing.id: .missing,
                                                   twinMissing.id: .missing, twinA.id: .available, twinB.id: .available]
        for (id, availability) in presence { context.insert(FilePresence(fileID: id, availability: availability)) }
        try context.save()
        let scanMissing: Set<UUID> = [old.id, unrelatedMissing.id, twinMissing.id]
        let summary = await LibraryDuplicateMerger.merge(context: context, presence: presence, fingerprintLibraryID: library,
                                                         scanConfirmedMissing: scanMissing)
        XCTAssertEqual(summary.remapped, [renamed.id: old.id])
        let items = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(old.effectiveRelativePath, "New Folder/New Name.pdf", "The survivor points at the present file")
        XCTAssertEqual(old.filename, "New Name.pdf")
        XCTAssertEqual(old.tags, ["Keep"])
        let presences = try context.fetch(FetchDescriptor<FilePresence>())
        XCTAssertEqual(presences.first { $0.fileID == old.id }?.availability, .available)
        XCTAssertNil(presences.first { $0.fileID == renamed.id })
    }

    @MainActor
    func testMergeRemapsTutorTakesDefaultsPresenceAndTags() async throws {
        let defaults = try makeDefaults()
        LibraryStorageOption.set(.hybrid, in: defaults)
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID()
        context.insert(LibraryDescriptor(id: library, mode: .externalFolder, displayName: "Songs"))
        let first = record("song.txt", library: library, importedAt: Date(timeIntervalSince1970: 1))
        let second = record("song.txt", library: library, importedAt: Date(timeIntervalSince1970: 2))
        second.tags = ["From iPhone"]
        context.insert(first)
        context.insert(second)
        context.insert(FilePresence(fileID: second.id, availability: .available))
        try context.save()
        let tutor = try TutorStore.inMemory()
        tutor.compressesTakeAudio = false
        let analysis = TakeAnalysis(graded: [], extras: [], tempoCurve: [], targetBPM: 90, accuracy: 0.8, timingMADms: 10,
                                    measureAccuracy: [:], measureTendency: [:], suggestions: [])
        try tutor.saveTake(scoreKey: second.id.uuidString, scoreTitle: "Song", measures: 0...1, bpm: 90, analysis: analysis)
        defaults.set(Data("gp".utf8), forKey: "guitarPro.practice.\(second.id.uuidString)")
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        manager.rekeyPracticeTakes = { map in _ = try? tutor.rekeyTakes(map) }
        manager.bootstrap(context: context)
        let summary = try await XCTUnwrapAsync(await manager.mergeDuplicates(context: context))
        XCTAssertEqual(summary.remapped, [second.id: first.id])
        XCTAssertEqual(tutor.takes(forScore: first.id.uuidString).count, 1, "Practice history follows the survivor")
        XCTAssertTrue(tutor.takes(forScore: second.id.uuidString).isEmpty)
        XCTAssertEqual(defaults.data(forKey: "guitarPro.practice.\(first.id.uuidString)"), Data("gp".utf8))
        XCTAssertNil(defaults.object(forKey: "guitarPro.practice.\(second.id.uuidString)"))
        XCTAssertEqual(manager.availabilityByFileID[first.id], .available)
        XCTAssertNil(manager.availabilityByFileID[second.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<TagStat>()).map(\.name), ["From iPhone"])
        XCTAssertEqual(first.tags, ["From iPhone"])
    }

    @MainActor
    func testMergeLeavesOpenScoreAndDescriptorDuplicatesAreDeterministic() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID()
        let early = LibraryDescriptor(id: library, mode: .externalFolder, displayName: "Songs")
        early.createdAt = Date(timeIntervalSince1970: 1)
        let late = LibraryDescriptor(id: library, mode: .externalFolder, displayName: "Songs")
        late.createdAt = Date(timeIntervalSince1970: 2)
        late.rootGeneration = 3
        context.insert(late)
        context.insert(early)
        let a = record("a.txt", library: library, importedAt: Date(timeIntervalSince1970: 1))
        let b = record("a.txt", library: library, importedAt: Date(timeIntervalSince1970: 2))
        context.insert(a)
        context.insert(b)
        try context.save()
        let skipped = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: nil, protectedIDs: [b.id])
        XCTAssertEqual(skipped.skippedGroups, 1)
        XCTAssertEqual(skipped.removedDescriptors, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FileItem>()).count, 2, "The open score is merged later")
        let descriptors = try context.fetch(FetchDescriptor<LibraryDescriptor>())
        XCTAssertEqual(descriptors.map(\.createdAt), [Date(timeIntervalSince1970: 1)])
        XCTAssertEqual(descriptors.first?.rootGeneration, 3)
        let later = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: nil)
        XCTAssertEqual(later.remapped, [b.id: a.id])
    }

    @MainActor
    func testTenThousandDuplicatePairsMergeInBatchesWithoutLongStalls() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let library = UUID()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<10_000 {
            let path = "Folder \(index % 100)/Song \(index).pdf"
            let ipad = record(path, library: library, importedAt: base.addingTimeInterval(Double(index)))
            ipad.tags = ["Set \(index % 20)"]
            let iphone = record(path, library: library, importedAt: base.addingTimeInterval(Double(index) + 0.5))
            iphone.playCount = index % 7
            context.insert(ipad)
            context.insert(iphone)
            if index % 1_000 == 999 { try context.save() }
        }
        try context.save()
        TagIndexer.rebuild(in: context) // Built at launch in the app.
        // A main-actor ticker records the longest gap the merge leaves between turns.
        var longestStall: Duration = .zero
        var ticking = true
        let ticker = Task { @MainActor in
            var last = ContinuousClock.now
            while ticking {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                longestStall = max(longestStall, now - last)
                last = now
            }
        }
        let start = ContinuousClock.now
        let summary = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: library)
        let elapsed = start.duration(to: .now)
        ticking = false
        await ticker.value
        print("10k duplicate pairs merged in \(elapsed); longest main-actor stall \(longestStall)")
        XCTAssertEqual(summary.mergedGroups, 10_000)
        XCTAssertEqual(summary.removedRecords, 10_000)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FileItem>()), 10_000)
        XCTAssertLessThan(elapsed, .seconds(60))
        XCTAssertLessThan(longestStall, .milliseconds(500), "Merging must yield to the UI between bounded batches")
        let incremental = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TagStat>()).map { ($0.name, $0.count) })
        TagIndexer.rebuild(in: context)
        let rebuilt = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TagStat>()).map { ($0.name, $0.count) })
        XCTAssertEqual(incremental, rebuilt, "Incremental tag counts match a full rebuild")
        XCTAssertEqual(rebuilt["Set 0"], 500)
        let again = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: library)
        XCTAssertEqual(again.mergedGroups, 0)
    }

    @MainActor
    func testTutorTakesRekeyAndReapplyAudioCap() throws {
        let tutor = try TutorStore.inMemory()
        tutor.compressesTakeAudio = false
        let analysis = TakeAnalysis(graded: [], extras: [], tempoCurve: [], targetBPM: 90, accuracy: 0.5, timingMADms: 10,
                                    measureAccuracy: [:], measureTendency: [:], suggestions: [])
        try tutor.saveTake(scoreKey: "old", scoreTitle: "Song", measures: 0...1, bpm: 90, analysis: analysis)
        try tutor.saveTake(scoreKey: "new", scoreTitle: "Song", measures: 0...1, bpm: 90, analysis: analysis)
        XCTAssertEqual(try tutor.rekeyTakes(from: "old", to: "new"), 1)
        XCTAssertEqual(tutor.takes(forScore: "new").count, 2)
        XCTAssertEqual(try tutor.rekeyTakes(from: "old", to: "new"), 0)
        XCTAssertEqual(try tutor.rekeyTakes(from: "new", to: "new"), 0)
    }
    // MARK: - Data-safety fixes (2026-09-25 review)

    /// #1: `FileItem.init` sets lastOpenedAt = importedAt, so a later-catalogued,
    /// never-opened record must not win practice fields.
    @MainActor
    func testPracticeFieldsSurviveNeverOpenedLaterRecord() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID()
        let practiced = record("song.gp", library: library, importedAt: Date(timeIntervalSince1970: 1_000))
        practiced.lastOpenedAt = Date(timeIntervalSince1970: 2_000)
        practiced.playCount = 4
        practiced.loopStartMeasure = 3; practiced.loopEndMeasure = 9
        practiced.loopStartY = 10; practiced.loopEndY = 400
        practiced.scrollSpeed = 42
        practiced.userBPM = 88
        practiced.referenceBPM = 120
        practiced.preferredTextMode = "player"
        practiced.preferredNotation = "tab"
        // Catalogued later on the other device and never opened: lastOpenedAt == importedAt (5000 > 2000).
        let fresh = record("song.gp", library: library, importedAt: Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(fresh.lastOpenedAt, fresh.importedAt)
        context.insert(fresh); context.insert(practiced)
        try context.save()
        let summary = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: nil)
        XCTAssertEqual(summary.remapped, [fresh.id: practiced.id])
        XCTAssertEqual(practiced.loopStartMeasure, 3); XCTAssertEqual(practiced.loopEndMeasure, 9)
        XCTAssertEqual(practiced.loopStartY, 10); XCTAssertEqual(practiced.loopEndY, 400)
        XCTAssertEqual(practiced.scrollSpeed, 42)
        XCTAssertEqual(practiced.userBPM, 88)
        XCTAssertEqual(practiced.referenceBPM, 120)
        XCTAssertEqual(practiced.preferredTextMode, "player")
        XCTAssertEqual(practiced.preferredNotation, "tab")
        XCTAssertEqual(practiced.playCount, 4)
    }

    /// #1 reversed: the survivor was never opened; the later record holds the settings.
    @MainActor
    func testPracticeFieldsComeFromOpenedLoserAndFieldByField() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID()
        let survivor = record("a.txt", library: library, importedAt: Date(timeIntervalSince1970: 1_000))
        survivor.scrollSpeed = 0
        // Opened most recently: only a loop.
        let recent = record("a.txt", library: library, importedAt: Date(timeIntervalSince1970: 2_000))
        recent.lastOpenedAt = Date(timeIntervalSince1970: 9_000)
        recent.loopStartMeasure = 1; recent.loopEndMeasure = 2
        // Opened earlier: tempo and speed but no loop.
        let older = record("a.txt", library: library, importedAt: Date(timeIntervalSince1970: 3_000))
        older.playCount = 1
        older.lastOpenedAt = Date(timeIntervalSince1970: 3_000)   // == importedAt, but it has a play count
        older.userBPM = 70
        older.scrollSpeed = 25
        older.loopStartMeasure = 5; older.loopEndMeasure = 6
        // Never opened but has a notation preference: used as the last fallback.
        let unopened = record("a.txt", library: library, importedAt: Date(timeIntervalSince1970: 4_000))
        unopened.preferredNotation = "staff"
        for item in [unopened, older, recent, survivor] { context.insert(item) }
        try context.save()
        _ = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: nil)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FileItem>()), 1)
        XCTAssertEqual(survivor.loopStartMeasure, 1, "Most recently opened record with a loop")
        XCTAssertEqual(survivor.loopEndMeasure, 2)
        XCTAssertEqual(survivor.userBPM, 70, "A set value is never replaced by an unset one")
        XCTAssertEqual(survivor.scrollSpeed, 25)
        XCTAssertEqual(survivor.preferredNotation, "staff")
        XCTAssertEqual(survivor.lastOpenedAt, Date(timeIntervalSince1970: 9_000))
        XCTAssertEqual(survivor.playCount, 1)
    }

    /// #2: several user-edited records merge field by field.
    @MainActor
    func testEditedDetailsMergeFieldByField() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID()
        let first = record("s.pdf", library: library, importedAt: Date(timeIntervalSince1970: 1))
        first.metadataEdited = true
        first.composer = "Composer A"
        first.tags = ["one"]
        let second = record("s.pdf", library: library, importedAt: Date(timeIntervalSince1970: 2))
        second.metadataEdited = true
        second.composer = "Composer B"      // Conflict: survivor order wins.
        second.artist = "Artist B"          // Blank on the first edited record: filled.
        second.instruments = ["piano"]
        second.tuning = "Drop D"
        second.tags = ["two"]
        let unedited = record("s.pdf", library: library, importedAt: Date(timeIntervalSince1970: 3))
        unedited.arranger = "Inferred arranger"   // Not a user edit: edited records decide.
        unedited.customTitle = "My Title"
        for item in [unedited, second, first] { context.insert(item) }
        try context.save()
        _ = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: nil)
        XCTAssertEqual(first.composer, "Composer A")
        XCTAssertEqual(first.artist, "Artist B")
        XCTAssertEqual(first.instruments, ["piano"])
        XCTAssertEqual(first.tuning, "Drop D")
        XCTAssertNil(first.arranger)
        XCTAssertEqual(first.customTitle, "My Title", "A rename is kept from any record")
        XCTAssertTrue(first.metadataEdited)
        XCTAssertEqual(first.tags, ["one", "two"])
    }

    /// #3: an undownloaded marker is never treated as "no marker".
    func testPlaceholderMarkerIsNeverReplaced() async throws {
        for placeholderName in ["..tabbuddy-library.json.icloud", ".tabbuddy-library.json.icloud"] {
            let folder = temporaryRoot.appendingPathComponent("Synced-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("bplist placeholder".utf8).write(to: folder.appendingPathComponent(placeholderName))
            XCTAssertEqual(LibraryFileService.inspectMarker(at: folder), .notDownloaded, placeholderName)
            do {
                _ = try await LibraryFileService.existingLibraryID(at: folder, timeout: .milliseconds(300))
                XCTFail("A placeholder marker must not read as an unmarked folder")
            } catch {
                XCTAssertEqual(error as? LibraryFileError, .markerNotDownloaded)
            }
            do {
                try await LibraryFileService().validateOrCreateMarker(at: folder, libraryID: UUID(), mayCreate: true)
                XCTFail("A second marker must never be written next to a placeholder")
            } catch {
                XCTAssertEqual(error as? LibraryFileError, .markerNotDownloaded)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(LibraryMarker.filename).path))
        }
    }

    @MainActor
    func testChoosingFolderWithUndownloadedMarkerWaitsInsteadOfMintingID() async throws {
        let saved = LibraryFileService.markerDownloadTimeout
        LibraryFileService.markerDownloadTimeout = .milliseconds(300)
        defer { LibraryFileService.markerDownloadTimeout = saved }
        let defaults = try makeDefaults()
        let folder = temporaryRoot.appendingPathComponent("iCloud Songs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("..tabbuddy-library.json.icloud"))
        try Data("tab".utf8).write(to: folder.appendingPathComponent("song.txt"))
        let container = try makeContainer()
        let context = container.mainContext
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        manager.useExistingFolder(url: folder, context: context, option: .hybrid)
        try await settle(manager)
        XCTAssertEqual(manager.lastError, LibraryFileError.markerNotDownloaded.localizedDescription)
        XCTAssertTrue(manager.lastError?.contains("Waiting for the library marker to download from iCloud Drive") == true)
        XCTAssertNil(manager.activeLibraryID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LibraryDescriptor>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(LibraryMarker.filename).path))
    }

    func testMarkerConflictCopiesAreSurfaced() async throws {
        let id = UUID()
        let encoder = JSONEncoder()
        func folder(_ name: String) throws -> URL {
            let url = temporaryRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try encoder.encode(LibraryMarker(libraryID: id, schemaVersion: 1)).write(to: url.appendingPathComponent(LibraryMarker.filename))
            return url
        }
        // A conflict copy with the same identity is harmless.
        let same = try folder("Same")
        try encoder.encode(LibraryMarker(libraryID: id, schemaVersion: 1)).write(to: same.appendingPathComponent(".tabbuddy-library 2.json"))
        let sameID = try await LibraryFileService.existingLibraryID(at: same)
        XCTAssertEqual(sameID, id)
        // A conflict copy naming another library must be resolved by the user.
        let different = try folder("Different")
        try encoder.encode(LibraryMarker(libraryID: UUID(), schemaVersion: 1)).write(to: different.appendingPathComponent(".tabbuddy-library 2.json"))
        do {
            _ = try await LibraryFileService.existingLibraryID(at: different)
            XCTFail("Conflicting markers must be surfaced")
        } catch {
            XCTAssertEqual(error as? LibraryFileError, .markerConflict([".tabbuddy-library 2.json"]))
        }
        // Only a conflict copy and no primary marker: surfaced, and nothing is written.
        let onlyCopy = temporaryRoot.appendingPathComponent("OnlyCopy", isDirectory: true)
        try FileManager.default.createDirectory(at: onlyCopy, withIntermediateDirectories: true)
        try encoder.encode(LibraryMarker(libraryID: id, schemaVersion: 1)).write(to: onlyCopy.appendingPathComponent(".tabbuddy-library 2.json"))
        XCTAssertEqual(LibraryFileService.inspectMarker(at: onlyCopy), .conflict([".tabbuddy-library 2.json"]))
        do {
            try await LibraryFileService().validateOrCreateMarker(at: onlyCopy, libraryID: id)
            XCTFail("Expected a conflict")
        } catch {
            XCTAssertEqual(error as? LibraryFileError, .markerConflict([".tabbuddy-library 2.json"]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: onlyCopy.appendingPathComponent(LibraryMarker.filename).path))
    }

    /// #3 legacy bootstrap: the folder's marker decides the identity; an unreadable
    /// marker is shown instead of silently creating a diverging descriptor.
    @MainActor
    func testLegacyBookmarkAdoptsFolderMarkerIdentity() async throws {
        let saved = LibraryFileService.markerDownloadTimeout
        LibraryFileService.markerDownloadTimeout = .milliseconds(300)
        defer { LibraryFileService.markerDownloadTimeout = saved }
        let markerID = UUID()
        let marked = temporaryRoot.appendingPathComponent("Marked", isDirectory: true)
        try FileManager.default.createDirectory(at: marked, withIntermediateDirectories: true)
        try JSONEncoder().encode(LibraryMarker(libraryID: markerID, schemaVersion: 1)).write(to: marked.appendingPathComponent(LibraryMarker.filename))
        let defaults = try makeDefaults()
        defaults.set(try marked.bookmarkData(), forKey: LibraryManager.legacyBookmarkKey)
        let container = try makeContainer()
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        manager.bootstrap(context: container.mainContext)
        try await settle(manager)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.activeLibraryID, markerID)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<LibraryDescriptor>()).map(\.id), [markerID])

        let evicted = temporaryRoot.appendingPathComponent("Evicted", isDirectory: true)
        try FileManager.default.createDirectory(at: evicted, withIntermediateDirectories: true)
        try Data().write(to: evicted.appendingPathComponent("..tabbuddy-library.json.icloud"))
        let otherDefaults = try makeDefaults()
        otherDefaults.set(try evicted.bookmarkData(), forKey: LibraryManager.legacyBookmarkKey)
        let other = try makeContainer()
        let second = LibraryManager(files: LibraryFileService(), defaults: otherDefaults)
        second.bootstrap(context: other.mainContext)
        try await settle(second)
        XCTAssertEqual(second.lastError, LibraryFileError.markerNotDownloaded.localizedDescription)
        XCTAssertTrue(try other.mainContext.fetch(FetchDescriptor<LibraryDescriptor>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evicted.appendingPathComponent(LibraryMarker.filename).path))
    }

    /// #4: fingerprint joins need a completed-scan miss, a unique fingerprint among
    /// all records, and equal sizes.
    func testFingerprintJoinRequiresScanConfirmedUniqueSameSize() {
        let library = UUID()
        func candidate(_ index: Int, _ path: String, hash: String?, size: Int64 = 100) -> LibraryDuplicateMerger.Candidate {
            .init(index: index, id: UUID(), libraryID: library, path: path, importedAt: Date(timeIntervalSince1970: Double(index)),
                  hash: hash, byteSize: size)
        }
        let old = candidate(0, "Old.pdf", hash: "h")
        let new = candidate(1, "New/New.pdf", hash: "h")
        let presence: [UUID: FileAvailability] = [old.id: .missing, new.id: .available]
        XCTAssertEqual(LibraryDuplicateMerger.plan([old, new], presence: presence, scanConfirmedMissing: [old.id],
                                                   fingerprintLibraryID: library), [[0, 1]])
        XCTAssertTrue(LibraryDuplicateMerger.plan([old, new], presence: presence, scanConfirmedMissing: [],
                                                  fingerprintLibraryID: library).isEmpty,
                      "A miss from a quick path check (iCloud listing lag) never joins")
        // A third record with the same fingerprint, even one not present here, makes it ambiguous.
        let third = candidate(2, "Elsewhere.pdf", hash: "h")
        XCTAssertTrue(LibraryDuplicateMerger.plan([old, new, third], presence: presence, scanConfirmedMissing: [old.id],
                                                  fingerprintLibraryID: library).isEmpty)
        // Different byte sizes never join.
        let bigger = candidate(1, "New/New.pdf", hash: "h", size: 200)
        XCTAssertTrue(LibraryDuplicateMerger.plan([old, bigger], presence: [old.id: .missing, bigger.id: .available],
                                                  scanConfirmedMissing: [old.id], fingerprintLibraryID: library).isEmpty)
    }

    /// #4 + #5 through the manager: a path-check miss neither joins by fingerprint nor
    /// stays hidden once the file appears; only a completed scan enables the join.
    @MainActor
    func testPathCheckMissNeverJoinsAndIsRecheckedAfterMerges() async throws {
        let defaults = try makeDefaults()
        let folder = temporaryRoot.appendingPathComponent("Hybrid Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("New"), withIntermediateDirectories: true)
        let payload = Data("renamed tab".utf8)
        let newURL = folder.appendingPathComponent("New/Name.txt")
        try payload.write(to: newURL)
        let container = try makeContainer()
        let context = container.mainContext
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        manager.useExistingFolder(url: folder, context: context, option: .hybrid)
        try await settle(manager)
        manager.rescan(context: context)
        try await settle(manager)
        let library = try XCTUnwrap(manager.activeLibraryID)
        let present = try XCTUnwrap(try context.fetch(FetchDescriptor<FileItem>()).first { $0.effectiveRelativePath == "New/Name.txt" })
        let hash = try XCTUnwrap(FileItem.fingerprint(of: newURL))
        present.contentHash = hash
        // Synced from the other device, at a path this device's listing does not show (yet).
        let synced = record("Old Name.txt", library: library, importedAt: .distantPast)
        synced.contentHash = hash
        synced.byteSize = present.byteSize
        synced.tags = ["Synced"]
        context.insert(synced)
        // Another synced record whose file arrives later.
        let arriving = record("Arriving.txt", library: library, importedAt: .distantPast)
        context.insert(arriving)
        try context.save()

        await manager.verifyUnknownPresence(context: context, force: true)
        XCTAssertEqual(manager.availabilityByFileID[synced.id], .missing)
        XCTAssertFalse(manager.isShownOnThisDevice(arriving))
        var quickSummary: LibraryDuplicateMerger.Summary?
        for _ in 0..<100 where quickSummary == nil {
            quickSummary = await manager.mergeDuplicates(context: context)   // nil while a scheduled pass runs
            if quickSummary == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let quick = try XCTUnwrap(quickSummary)
        XCTAssertTrue(quick.remapped.isEmpty, "A path-check miss must not join by fingerprint")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FileItem>()), 3)

        // The file arrives; the next merge pass re-checks path-check misses.
        try Data("arrived".utf8).write(to: folder.appendingPathComponent("Arriving.txt"))
        _ = await manager.mergeDuplicates(context: context)
        XCTAssertEqual(manager.availabilityByFileID[arriving.id], .available)
        XCTAssertTrue(manager.isShownOnThisDevice(arriving))

        // This device had the old file before it was renamed (seen here). A completed
        // full scan then confirms the old path is gone, and the rename joins.
        try context.fetch(FetchDescriptor<FilePresence>()).first { $0.fileID == synced.id }?.seenHere = true
        try context.save()
        manager.rescan(context: context)
        try await settle(manager)
        let reasons = try context.fetch(FetchDescriptor<FilePresence>()).first { $0.fileID == synced.id }?.reason
        XCTAssertEqual(reasons, .completedScan)
        var joined = false
        for _ in 0..<50 where !joined {
            _ = await manager.mergeDuplicates(context: context)
            joined = (try context.fetchCount(FetchDescriptor<FileItem>())) == 2
            if !joined { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(joined)
        let survivor = try XCTUnwrap(try context.fetch(FetchDescriptor<FileItem>()).first { $0.id == synced.id })
        XCTAssertEqual(survivor.effectiveRelativePath, "New/Name.txt")
        XCTAssertEqual(survivor.tags, ["Synced"])
        await manager.finishDatabaseWork()
    }

    /// #6: Local only on a store that mirrored before keeps hidden songs out of Remove All.
    @MainActor
    func testLocalOnlyAfterMirroringSkipsHiddenSongsAndSaysSo() async throws {
        let defaults = try makeDefaults()
        let folder = temporaryRoot.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("here".utf8).write(to: folder.appendingPathComponent("here.txt"))
        let container = try makeContainer()
        let context = container.mainContext
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        XCTAssertFalse(manager.hasEverMirrored)
        XCTAssertTrue(manager.offersBackupBeforeSwitching(to: .hybrid))
        manager.useExistingFolder(url: folder, context: context, option: .hybrid)
        try await settle(manager)
        XCTAssertTrue(manager.hasEverMirrored)
        XCTAssertFalse(manager.offersBackupBeforeSwitching(to: .iCloudOnly))
        XCTAssertEqual(manager.switchStorageOption(to: .localOnly, context: context), .started)
        try await settle(manager)
        XCTAssertEqual(manager.storageOption, .localOnly)
        manager.rescan(context: context)
        try await settle(manager)
        let library = try XCTUnwrap(manager.activeLibraryID)
        let hidden = record("elsewhere.txt", library: library, importedAt: .distantPast)
        context.insert(hidden)
        try context.save()
        manager.rescan(context: context)
        try await settle(manager)
        XCTAssertFalse(manager.isShownOnThisDevice(hidden))
        XCTAssertTrue(manager.removalSkipsHiddenSongs)
        XCTAssertTrue(manager.removalConfirmation(count: 1, all: true).message.contains("also apply on your other devices"))
        await manager.removeItems(try context.fetch(FetchDescriptor<FileItem>()), context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FileItem>()).map(\.id), [hidden.id])
        // A store that never mirrored keeps the earlier Local only behavior.
        let never = LibraryManager.removalConfirmation(count: 1, all: true, option: .localOnly, mode: .externalFolder,
                                                       folderName: "F", hasMirrored: false)
        XCTAssertFalse(never.message.contains("other devices"))
        await manager.finishDatabaseWork()
    }

    /// #7: the reader follows a record deleted under it, or closes cleanly.
    @MainActor
    func testReaderGuardFollowsMergedRecordOrCloses() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID()
        let open = record("Album/song.txt", library: library, importedAt: Date(timeIntervalSince1970: 2))
        let other = record("Album/song.txt", library: library, importedAt: Date(timeIntervalSince1970: 1))
        context.insert(open); context.insert(other)
        try context.save()
        let opened = ReaderRecordGuard.Opened(open)
        XCTAssertEqual(ReaderRecordGuard.resolve(opened, current: open, context: context, survivor: { _ in nil }), .unchanged)
        // Another device's merge deleted the open record: follow the same library + path.
        context.delete(open)
        try context.save()
        XCTAssertEqual(ReaderRecordGuard.resolve(opened, current: nil, context: context, survivor: { _ in nil }), .redirect(other))
        // With a known survivor from this device's merge map.
        let moved = record("Elsewhere/renamed.txt", library: library, importedAt: Date(timeIntervalSince1970: 3))
        context.insert(moved)
        context.delete(other)
        try context.save()
        let movedID = moved.id
        XCTAssertEqual(ReaderRecordGuard.resolve(opened, current: nil, context: context, survivor: { _ in movedID }), .redirect(moved))
        XCTAssertEqual(ReaderRecordGuard.resolve(opened, current: nil, context: context, survivor: { _ in nil }), .gone)
    }

    /// #8: the whole manager path (merge + follow-up re-keying) at 10k pairs, with the
    /// longest main-actor pause measured.
    @MainActor
    func testManagerMergeTenThousandPairsIncludingRekeyWithoutLongStalls() async throws {
        let defaults = try makeDefaults()
        LibraryStorageOption.set(.iCloudOnly, in: defaults)
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let library = UUID()
        context.insert(LibraryDescriptor(id: library, mode: .managedICloud, displayName: "Songs"))
        let base = Date(timeIntervalSince1970: 1_000_000)
        var losers: [UUID] = []
        for index in 0..<10_000 {
            let path = "Folder \(index % 100)/Song \(index).pdf"
            let ipad = record(path, library: library, importedAt: base.addingTimeInterval(Double(index)))
            ipad.tags = ["Set \(index % 20)"]
            let iphone = record(path, library: library, importedAt: base.addingTimeInterval(Double(index) + 0.5))
            iphone.playCount = index % 7
            context.insert(ipad); context.insert(iphone)
            context.insert(FilePresence(fileID: iphone.id, availability: .available))
            losers.append(iphone.id)
            if index % 1_000 == 999 { try context.save() }
        }
        try context.save()
        TagIndexer.rebuild(in: context)
        let tutor = try TutorStore.inMemory()
        tutor.compressesTakeAudio = false
        let analysis = TakeAnalysis(graded: [], extras: [], tempoCurve: [], targetBPM: 90, accuracy: 0.8, timingMADms: 10,
                                    measureAccuracy: [:], measureTendency: [:], suggestions: [])
        for id in losers.prefix(200) {
            try tutor.saveTake(scoreKey: id.uuidString, scoreTitle: "Song", measures: 0...1, bpm: 90, analysis: analysis)
            defaults.set(Data("gp".utf8), forKey: "guitarPro.practice.\(id.uuidString)")
        }
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        var rekeyCalls = 0
        manager.rekeyPracticeTakes = { map in rekeyCalls += 1; _ = try? tutor.rekeyTakes(map) }
        var longestStall: Duration = .zero
        var ticking = true
        let ticker = Task { @MainActor in
            var last = ContinuousClock.now
            while ticking {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                longestStall = max(longestStall, now - last)
                last = now
            }
        }
        let start = ContinuousClock.now
        let summary = try XCTUnwrapAsync(await manager.mergeDuplicates(context: context))
        let elapsed = start.duration(to: .now)
        ticking = false
        await ticker.value
        print("Manager path: 10k pairs merged and re-keyed in \(elapsed); longest main-actor stall \(longestStall)")
        XCTAssertEqual(summary.removedRecords, 10_000)
        XCTAssertEqual(rekeyCalls, 1, "Practice takes re-key in one batch")
        XCTAssertEqual(manager.mergeProgress.done, 10_000)
        XCTAssertEqual(tutor.takes(forScore: summary.remapped[losers[0]]!.uuidString).count, 1)
        XCTAssertTrue(tutor.takes(forScore: losers[0].uuidString).isEmpty)
        XCTAssertEqual(defaults.data(forKey: "guitarPro.practice.\(summary.remapped[losers[199]]!.uuidString)"), Data("gp".utf8))
        XCTAssertNil(defaults.object(forKey: "guitarPro.practice.\(losers[199].uuidString)"))
        XCTAssertEqual(manager.availabilityByFileID.count, 10_000)
        XCTAssertLessThan(elapsed, .seconds(90))
        XCTAssertLessThan(longestStall, .milliseconds(500), "The manager path must yield to the UI")
    }

    /// #9: the synced canonical name never depends on which files this device has.
    @MainActor
    func testCanonicalChoiceIsDeterministicAndNeverDeletes() async throws {
        let library = UUID()
        func run(existing: Set<String>) async throws -> (String?, [String]) {
            let container = try makeContainer()
            let context = container.mainContext
            let survivor = record("x.txt", library: library, importedAt: Date(timeIntervalSince1970: 1),
                                  id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
            let b = record("x.txt", library: library, importedAt: Date(timeIntervalSince1970: 2))
            b.canonicalFilename = "b.musicxml"; b.canonicalVersion = 7
            let a = record("x.txt", library: library, importedAt: Date(timeIntervalSince1970: 3))
            a.canonicalFilename = "a.musicxml"; a.canonicalVersion = 7
            for item in [a, b, survivor] { context.insert(item) }
            try context.save()
            var copies: [String] = []
            _ = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: nil,
                                                   canonicalExists: { existing.contains($0) },
                                                   copyCanonical: { from, to in copies.append("\(from)->\(to)") })
            return (survivor.canonicalFilename, copies)
        }
        let deviceA = try await run(existing: ["a.musicxml"])
        let deviceB = try await run(existing: ["b.musicxml"])
        XCTAssertEqual(deviceA.0, "a.musicxml", "Lowest name when the survivor has none")
        XCTAssertEqual(deviceB.0, "a.musicxml", "Same choice on every device")
        XCTAssertEqual(deviceA.1, [])
        XCTAssertEqual(deviceB.1, ["b.musicxml->a.musicxml"], "Missing local file is copied, never moved or deleted")
    }

    /// #10: case folding only for case-insensitive locations; Unicode forms always match.
    func testPathGroupingCaseSensitivity() {
        let library = UUID()
        let upper = LibraryDuplicateMerger.Candidate(index: 0, id: UUID(), libraryID: library, path: "Song.txt", importedAt: .distantPast, hash: nil)
        let lower = LibraryDuplicateMerger.Candidate(index: 1, id: UUID(), libraryID: library, path: "song.txt", importedAt: .now, hash: nil)
        XCTAssertTrue(LibraryDuplicateMerger.plan([upper, lower], presence: [:], fingerprintLibraryID: nil, caseInsensitivePaths: false).isEmpty)
        XCTAssertEqual(LibraryDuplicateMerger.plan([upper, lower], presence: [:], fingerprintLibraryID: nil, caseInsensitivePaths: true), [[0, 1]])
        let composed = LibraryDuplicateMerger.Candidate(index: 0, id: UUID(), libraryID: library, path: "Caf\u{E9}.txt", importedAt: .distantPast, hash: nil)
        let decomposed = LibraryDuplicateMerger.Candidate(index: 1, id: UUID(), libraryID: library, path: "Cafe\u{301}.txt", importedAt: .now, hash: nil)
        XCTAssertEqual(LibraryDuplicateMerger.plan([composed, decomposed], presence: [:], fingerprintLibraryID: nil, caseInsensitivePaths: false), [[0, 1]])
    }

    /// #11: a merge requested while one runs is not dropped.
    @MainActor
    func testMergeRequestedDuringPassRunsAfterward() async throws {
        let defaults = try makeDefaults()
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID()
        for index in 0..<300 {
            context.insert(record("s\(index).txt", library: library, importedAt: Date(timeIntervalSince1970: Double(index))))
            context.insert(record("s\(index).txt", library: library, importedAt: Date(timeIntervalSince1970: Double(index) + 0.5)))
        }
        try context.save()
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        let first = Task { await manager.mergeDuplicates(context: context) }
        while !manager.isMergingDuplicates { await Task.yield() }
        let second = await manager.mergeDuplicates(context: context)
        XCTAssertNil(second, "Only one pass at a time")
        _ = await first.value
        // Arrives after the first pass read the catalog: merged by the follow-up pass.
        context.insert(record("late.txt", library: library, importedAt: Date(timeIntervalSince1970: 1)))
        context.insert(record("late.txt", library: library, importedAt: Date(timeIntervalSince1970: 2)))
        try context.save()
        var remaining = try context.fetchCount(FetchDescriptor<FileItem>())
        for _ in 0..<100 where remaining != 301 {
            try await Task.sleep(nanoseconds: 50_000_000)
            remaining = try context.fetchCount(FetchDescriptor<FileItem>())
        }
        XCTAssertEqual(remaining, 301)
    }

    /// #12: a record synced from another device is never deleted by rename relinking.
    @MainActor
    func testRelinkNeverDeletesRecordSyncedFromAnotherDevice() async throws {
        let root = temporaryRoot.appendingPathComponent("Relink", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let renamedURL = root.appendingPathComponent("renamed.txt")
        try Data("favorite tab".utf8).write(to: renamedURL)
        let libraryID = UUID()
        let service = LibraryFileService()
        try await service.configureTestingRoot(root, libraryID: libraryID)
        let container = try makeContainer()
        let context = container.mainContext
        let descriptor = LibraryDescriptor(id: libraryID, mode: .externalFolder, displayName: "Relink")
        context.insert(descriptor)
        let original = record("original.txt", library: libraryID, importedAt: Date(timeIntervalSince1970: 1))
        original.tags = ["practice"]
        original.contentHash = FileItem.fingerprint(of: renamedURL)
        let values = try renamedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        original.byteSize = Int64(values.fileSize ?? 0)
        // The other device already catalogued the renamed file; it arrived through iCloud.
        let synced = record("renamed.txt", library: libraryID, importedAt: Date(timeIntervalSince1970: 2))
        synced.isFavorite = false
        context.insert(original); context.insert(synced)
        // This device had the original file before it was renamed.
        context.insert(FilePresence(fileID: original.id, availability: .available, lastSeenAt: .now))
        try context.save()
        let manager = LibraryManager(files: service, defaults: try makeDefaults())
        let file = LibraryFileRecord(relativePath: "renamed.txt", filename: "renamed.txt",
                                     byteSize: Int64(values.fileSize ?? 0), modificationDate: values.contentModificationDate)
        await manager.reconcile(records: [file], descriptor: descriptor, context: context,
                                provisionalPaths: ["renamed.txt"], locallyCreatedIDs: [], reportProgress: false)
        let ids = Set(try context.fetch(FetchDescriptor<FileItem>()).map(\.id))
        XCTAssertEqual(ids, [original.id, synced.id], "The synced record is kept")
        let presences = try context.fetch(FetchDescriptor<FilePresence>())
        XCTAssertEqual(presences.first { $0.fileID == original.id }?.reason, .completedScan)
        // The merger then combines them under its rules.
        synced.contentHash = original.contentHash
        synced.byteSize = original.byteSize
        try context.save()
        let summary = await LibraryDuplicateMerger.merge(context: context, presence: manager.availabilityByFileID,
                                                         fingerprintLibraryID: libraryID, scanConfirmedMissing: [original.id])
        XCTAssertEqual(summary.remapped, [synced.id: original.id])
        XCTAssertEqual(original.effectiveRelativePath, "renamed.txt")
        XCTAssertEqual(original.tags, ["practice"])
        await service.clearTestingRoot()
    }

    /// #13: rows sharing one UUID are never deleted and do not reprocess forever.
    @MainActor
    func testSameIDRowsAreSkippedPermanently() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let library = UUID()
        let shared = UUID()
        let a = record("x.txt", library: library, importedAt: Date(timeIntervalSince1970: 1), id: shared)
        let b = record("x.txt", library: library, importedAt: Date(timeIntervalSince1970: 1), id: shared)
        let other = record("x.txt", library: library, importedAt: Date(timeIntervalSince1970: 2))
        for item in [a, b, other] { context.insert(item) }
        try context.save()
        let first = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: nil)
        XCTAssertEqual(first.sameIDRowsSkipped, 1)
        XCTAssertEqual(first.remapped, [other.id: shared])
        XCTAssertEqual(try context.fetch(FetchDescriptor<FileItem>()).map(\.id), [shared, shared])
        let second = await LibraryDuplicateMerger.merge(context: context, presence: [:], fingerprintLibraryID: nil)
        XCTAssertEqual(second.mergedGroups, 0)
        XCTAssertEqual(second.removedRecords, 0)
    }

    /// #14: every user-set field round-trips; matching is by library + path, then
    /// fingerprint, then a unique filename.
    @MainActor
    func testBackupRoundTripsEveryUserFieldAndMatchesSafely() throws {
        let library = UUID()
        let source = try makeContainer()
        let item = record("Album/Song.txt", library: library, importedAt: Date(timeIntervalSince1970: 100))
        item.isFavorite = true
        item.tags = ["A", "B"]
        item.lastOpenedAt = Date(timeIntervalSince1970: 500)
        item.scrollSpeed = 33
        item.loopStartY = 1; item.loopEndY = 2
        item.loopStartMeasure = 3; item.loopEndMeasure = 4
        item.playCount = 9
        item.userBPM = 90; item.referenceBPM = 100
        item.instruments = ["guitar", "bass"]; item.instrument = "guitar"
        item.composer = "C"; item.arranger = "Ar"; item.collectionTitle = "Col"; item.arrangement = "Arr"
        item.sourceName = "SN"; item.sourceURL = "https://example.com"; item.sourceID = "SID"; item.copyrightNotice = "©"
        item.embeddedTitle = "ET"; item.artist = "Art"
        item.metadataEdited = true
        item.preferredNotation = "staff"; item.preferredTextMode = "player"
        item.customTitle = "Custom"
        item.tuning = "Drop D"
        item.confidenceNoticeDismissed = true
        item.contentHash = "hash-song"
        source.mainContext.insert(item)
        try source.mainContext.save()
        let data = try XCTUnwrap(BackupManager.exportJSON(context: source.mainContext))
        let decoded = try { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return try d.decode(LibraryBackup.self, from: data) }()
        XCTAssertEqual(decoded.version, 3)

        let target = try makeContainer()
        let context = target.mainContext
        let blank = record("Album/Song.txt", library: library, importedAt: Date(timeIntervalSince1970: 100))
        // Same filename elsewhere: must not receive the entry.
        let sameName = record("Other/Song.txt", library: library, importedAt: Date(timeIntervalSince1970: 100))
        context.insert(blank); context.insert(sameName)
        try context.save()
        XCTAssertEqual(BackupManager.importJSON(data: data, context: context, libraryID: library), 1)
        func fields(_ f: FileItem) -> [String] {
            ["\(f.isFavorite)", f.tags.joined(separator: ","), "\(f.lastOpenedAt.timeIntervalSince1970)", "\(f.scrollSpeed)",
             "\(f.loopStartY ?? -1)", "\(f.loopEndY ?? -1)", "\(f.loopStartMeasure ?? -1)", "\(f.loopEndMeasure ?? -1)",
             "\(f.playCount)", "\(f.userBPM ?? -1)", "\(f.referenceBPM ?? -1)", f.instruments.joined(separator: ","),
             f.instrument ?? "-", f.composer ?? "-", f.arranger ?? "-", f.collectionTitle ?? "-", f.arrangement ?? "-",
             f.sourceName ?? "-", f.sourceURL ?? "-", f.sourceID ?? "-", f.copyrightNotice ?? "-", f.embeddedTitle ?? "-",
             f.artist ?? "-", "\(f.metadataEdited)", f.preferredNotation ?? "-", f.preferredTextMode ?? "-",
             f.customTitle ?? "-", f.tuning ?? "-", "\(f.confidenceNoticeDismissed)"]
        }
        XCTAssertEqual(fields(blank), fields(item))
        XCTAssertTrue(sameName.tags.isEmpty)
        XCTAssertNil(sameName.customTitle)

        // Renamed since the backup: the unique fingerprint finds it.
        let moved = try makeContainer()
        let renamed = record("New Place/Renamed.txt", library: library, importedAt: .now)
        renamed.contentHash = "hash-song"
        moved.mainContext.insert(renamed)
        try moved.mainContext.save()
        XCTAssertEqual(BackupManager.importJSON(data: data, context: moved.mainContext, libraryID: library), 1)
        XCTAssertEqual(renamed.customTitle, "Custom")

        // Only an ambiguous filename: nothing is restored.
        let ambiguous = try makeContainer()
        ambiguous.mainContext.insert(record("X/Song.txt", library: library, importedAt: .now))
        ambiguous.mainContext.insert(record("Y/Song.txt", library: library, importedAt: .now))
        try ambiguous.mainContext.save()
        XCTAssertEqual(BackupManager.importJSON(data: data, context: ambiguous.mainContext, libraryID: library), 0)

        // A version 2 backup (no new fields) stays readable and keeps unknown fields.
        let v2 = """
        {"version":2,"exportedAt":"2026-01-01T00:00:00Z","files":[{"filename":"Song.txt","isFavorite":true,"tags":["Old"],
        "importedAt":"2026-01-01T00:00:00Z","lastOpenedAt":"2026-01-01T00:00:00Z","scrollSpeed":5,"folderName":"Album",
        "libraryPath":"Album/Song.txt","playCount":2}]}
        """
        let old = try makeContainer()
        let keep = record("Album/Song.txt", library: library, importedAt: .now)
        keep.customTitle = "Keep me"
        keep.loopStartMeasure = 7
        old.mainContext.insert(keep)
        try old.mainContext.save()
        XCTAssertEqual(BackupManager.importJSON(data: Data(v2.utf8), context: old.mainContext, libraryID: library), 1)
        XCTAssertEqual(keep.tags, ["Old"])
        XCTAssertEqual(keep.customTitle, "Keep me")
        XCTAssertEqual(keep.loopStartMeasure, 7)
    }

    /// #15: a chosen folder's file only moves to the Trash; it is kept when the Trash is unavailable.
    func testDeleteFilePrefersTrashAndNeverRemovesChosenFolderFiles() throws {
        let file = temporaryRoot.appendingPathComponent("keep.txt")
        try Data("song".utf8).write(to: file)
        struct NoTrash: Error {}
        XCTAssertThrowsError(try LibraryFileService.deleteFile(at: file, displayPath: "keep.txt", allowPermanentRemoval: false,
                                                               trash: { _ in throw NoTrash() })) { error in
            XCTAssertEqual(error as? LibraryFileError, .trashUnavailable("keep.txt"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "A chosen folder's file is never removed permanently")
        var trashed: [URL] = []
        try LibraryFileService.deleteFile(at: file, displayPath: "keep.txt", allowPermanentRemoval: false,
                                          trash: { trashed.append($0) })
        XCTAssertEqual(trashed, [file])
        try LibraryFileService.deleteFile(at: file, displayPath: "keep.txt", allowPermanentRemoval: true,
                                          trash: { _ in throw NoTrash() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Only the app-managed folder falls back to removal")
    }


    // MARK: - Re-review fixes (2026-09-25)

    /// R1: a rescan started during a merge waits for the whole pass; survivors are
    /// never marked missing and no deleted record is written.
    @MainActor
    func testRescanDuringMergeWaitsForThePass() async throws {
        let defaults = try makeDefaults()
        let folder = temporaryRoot.appendingPathComponent("Busy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<300 { try Data("song \(index)".utf8).write(to: folder.appendingPathComponent("s\(index).txt")) }
        let container = try makeContainer()
        let context = container.mainContext
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        manager.useExistingFolder(url: folder, context: context, option: .localOnly)
        try await settle(manager)
        manager.rescan(context: context)
        try await settle(manager)
        let library = try XCTUnwrap(manager.activeLibraryID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FileItem>()), 300)
        // The other device's copies of the same songs.
        for index in 0..<300 {
            context.insert(record("s\(index).txt", library: library, importedAt: Date(timeIntervalSinceNow: Double(index))))
        }
        try context.save()
        let merge = Task { await manager.mergeDuplicates(context: context) }
        while !manager.isMergingDuplicates { await Task.yield() }
        manager.rescan(context: context)
        XCTAssertTrue(manager.isRescanning)
        _ = await merge.value
        try await settle(manager)
        for _ in 0..<100 where manager.isRescanning || manager.isMergingDuplicates { try await Task.sleep(nanoseconds: 50_000_000) }
        var count = try context.fetchCount(FetchDescriptor<FileItem>())
        for _ in 0..<20 where count != 300 {
            _ = await manager.mergeDuplicates(context: context)
            try await Task.sleep(nanoseconds: 50_000_000)
            count = try context.fetchCount(FetchDescriptor<FileItem>())
        }
        XCTAssertEqual(count, 300)
        let items = try context.fetch(FetchDescriptor<FileItem>())
        XCTAssertTrue(items.allSatisfy { manager.availabilityByFileID[$0.id] == .available }, "No survivor is marked missing")
        XCTAssertTrue(items.allSatisfy { manager.isShownOnThisDevice($0) })
        await manager.finishDatabaseWork()
    }

    /// R2: a missing record whose path changed (another device's merge) is re-checked,
    /// and a rescan marks every record at a seen path present.
    @MainActor
    func testMovedMissingRecordIsRecheckedAndSamePathRecordsAreSeen() async throws {
        let defaults = try makeDefaults()
        let folder = temporaryRoot.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: folder.appendingPathComponent("new.txt"))
        try Data("dup".utf8).write(to: folder.appendingPathComponent("dup.txt"))
        let container = try makeContainer()
        let context = container.mainContext
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        manager.useExistingFolder(url: folder, context: context, option: .hybrid)
        try await settle(manager)
        manager.rescan(context: context)
        try await settle(manager)
        let library = try XCTUnwrap(manager.activeLibraryID)
        let moved = record("old.txt", library: library, importedAt: .distantPast)
        context.insert(moved)
        let twin = record("dup.txt", library: library, importedAt: .distantPast)
        context.insert(twin)
        try context.save()
        manager.rescan(context: context)
        try await settle(manager)
        XCTAssertEqual(manager.availabilityByFileID[moved.id], .missing)
        XCTAssertEqual(manager.availabilityByFileID[twin.id], .available, "Every record at a path the scan saw is present")
        let presence = try XCTUnwrap(try context.fetch(FetchDescriptor<FilePresence>()).first { $0.fileID == moved.id })
        XCTAssertEqual(presence.missingPath, "old.txt")
        // Another device's merge moved the record to the file that exists here.
        moved.storageRelativePath = "new.txt"; moved.libraryPath = "new.txt"
        try context.save()
        await manager.verifyUnknownPresence(context: context)
        XCTAssertEqual(manager.availabilityByFileID[moved.id], .available)
        XCTAssertTrue(manager.isShownOnThisDevice(moved))
        await manager.finishDatabaseWork()
    }

    /// R3: a copy the other device just added, whose file has not reached this
    /// device, is `notSeenHere` after a completed scan and never fingerprint-joined.
    @MainActor
    func testNeverSeenCopyIsNotJoinedByFingerprint() async throws {
        let defaults = try makeDefaults()
        let folder = temporaryRoot.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("c.txt")
        try Data("same bytes".utf8).write(to: fileURL)
        let container = try makeContainer()
        let context = container.mainContext
        let manager = LibraryManager(files: LibraryFileService(), defaults: defaults)
        manager.useExistingFolder(url: folder, context: context, option: .hybrid)
        try await settle(manager)
        manager.rescan(context: context)
        try await settle(manager)
        let library = try XCTUnwrap(manager.activeLibraryID)
        let original = try XCTUnwrap(try context.fetch(FetchDescriptor<FileItem>()).first)
        original.contentHash = FileItem.fingerprint(of: fileURL)
        let copy = record("copy/c.txt", library: library, importedAt: Date.now.addingTimeInterval(60))
        copy.contentHash = original.contentHash
        copy.byteSize = original.byteSize
        copy.tags = ["Added on iPad"]
        context.insert(copy)
        try context.save()
        manager.rescan(context: context)
        try await settle(manager)
        let reason = try context.fetch(FetchDescriptor<FilePresence>()).first { $0.fileID == copy.id }?.reason
        XCTAssertEqual(reason, .notSeenHere)
        for _ in 0..<3 { _ = await manager.mergeDuplicates(context: context); try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<FileItem>()).map(\.id)), [original.id, copy.id],
                       "A copy never seen here is not merged away")
        await manager.finishDatabaseWork()
    }

    /// R4: a known iCloud library launches without waiting for an evicted marker.
    func testKnownManagedLibraryLaunchDoesNotBlockOnEvictedMarker() async throws {
        let cloud = temporaryRoot.appendingPathComponent("Cloud", isDirectory: true)
        let root = cloud.appendingPathComponent("Documents/\(LibraryFileService.managedFolderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("..tabbuddy-library.json.icloud"))
        let service = LibraryFileService(localDocumentsURL: temporaryRoot.appendingPathComponent("App"), cloudContainer: { cloud })
        let start = ContinuousClock.now
        _ = try await service.configureManagedLibrary(id: UUID(), mode: .managedICloud)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LibraryMarker.filename).path))
        let offline = await LibraryFileService.markerProblem(at: root, expected: UUID(), timeout: .milliseconds(200))
        XCTAssertNil(offline, "An undownloaded marker is not an error")
        let expected = UUID(), other = UUID()
        let readable = temporaryRoot.appendingPathComponent("Readable", isDirectory: true)
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        try JSONEncoder().encode(LibraryMarker(libraryID: other, schemaVersion: 1)).write(to: readable.appendingPathComponent(LibraryMarker.filename))
        let mismatch = await LibraryFileService.markerProblem(at: readable, expected: expected)
        XCTAssertEqual(mismatch, .markerIdentityMismatch(expected: expected, found: other))
    }

    /// R5: evicted conflict copies don't block; Resolve keeps this library's marker and trashes the other.
    func testMarkerConflictResolveKeepsActiveLibraryAndTrashes() async throws {
        let keep = UUID(), other = UUID()
        let encoder = JSONEncoder()
        let evicted = temporaryRoot.appendingPathComponent("EvictedCopy", isDirectory: true)
        try FileManager.default.createDirectory(at: evicted, withIntermediateDirectories: true)
        try encoder.encode(LibraryMarker(libraryID: keep, schemaVersion: 1)).write(to: evicted.appendingPathComponent(LibraryMarker.filename))
        try Data().write(to: evicted.appendingPathComponent("..tabbuddy-library 2.json.icloud"))
        let id = try await LibraryFileService.existingLibraryID(at: evicted, timeout: .milliseconds(300))
        XCTAssertEqual(id, keep, "An unreadable conflict copy does not block; the primary decides")

        let folder = temporaryRoot.appendingPathComponent("Conflict", isDirectory: true)
        let trashDir = temporaryRoot.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try encoder.encode(LibraryMarker(libraryID: other, schemaVersion: 1)).write(to: folder.appendingPathComponent(LibraryMarker.filename))
        try encoder.encode(LibraryMarker(libraryID: keep, schemaVersion: 1)).write(to: folder.appendingPathComponent(".tabbuddy-library 2.json"))
        let trashed = try await LibraryFileService.resolveMarkerConflict(at: folder, keep: keep, trash: { url in
            try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(UUID().uuidString))
        })
        XCTAssertEqual(trashed, [LibraryMarker.filename])
        XCTAssertEqual(LibraryFileService.inspectMarker(at: folder), .present(LibraryMarker(libraryID: keep, schemaVersion: 1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".tabbuddy-library 2.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashDir.path).count, 1, "The other marker is in the Trash, not deleted")
        // Trash unavailable: nothing is removed.
        let stuck = temporaryRoot.appendingPathComponent("Stuck", isDirectory: true)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try encoder.encode(LibraryMarker(libraryID: keep, schemaVersion: 1)).write(to: stuck.appendingPathComponent(LibraryMarker.filename))
        try encoder.encode(LibraryMarker(libraryID: other, schemaVersion: 1)).write(to: stuck.appendingPathComponent(".tabbuddy-library 2.json"))
        struct NoTrash: Error {}
        do {
            _ = try await LibraryFileService.resolveMarkerConflict(at: stuck, keep: keep, trash: { _ in throw NoTrash() })
            XCTFail("Expected trashUnavailable")
        } catch {
            XCTAssertEqual(error as? LibraryFileError, .trashUnavailable(".tabbuddy-library 2.json"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.appendingPathComponent(".tabbuddy-library 2.json").path))
    }

    /// R6: an exact library + path match wins over an earlier entry's fallback.
    @MainActor
    func testRestoreExactMatchesClaimRecordsBeforeFallbacks() throws {
        let library = UUID()
        let source = try makeContainer()
        let renamedAway = record("Old/Song.txt", library: library, importedAt: .now)
        renamedAway.contentHash = "h"
        renamedAway.customTitle = "Fallback"
        let exact = record("A/Song.txt", library: library, importedAt: .now)
        exact.customTitle = "Exact"
        source.mainContext.insert(renamedAway); source.mainContext.insert(exact)
        try source.mainContext.save()
        var backup = LibraryBackup(exportedAt: .now, files: [FileItemBackup(renamedAway), FileItemBackup(exact)])
        backup.files[1].contentHash = nil
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        let target = try makeContainer()
        let current = record("A/Song.txt", library: library, importedAt: .now)
        current.contentHash = "h"
        target.mainContext.insert(current)
        try target.mainContext.save()
        XCTAssertEqual(BackupManager.importJSON(data: data, context: target.mainContext, libraryID: library), 1)
        XCTAssertEqual(current.customTitle, "Exact")
    }

    /// R8: markers are written whole and never over an existing file.
    func testExclusiveMarkerWriteNeverOverwrites() throws {
        let folder = temporaryRoot.appendingPathComponent("Exclusive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(LibraryMarker.filename)
        try LibraryFileService.writeExclusively(Data("first".utf8), to: url)
        XCTAssertThrowsError(try LibraryFileService.writeExclusively(Data("second".utf8), to: url))
        XCTAssertEqual(try Data(contentsOf: url), Data("first".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [LibraryMarker.filename], "No temporary file is left")
    }

}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
