import SwiftUI
import SwiftData
import CoreData
import OSLog

/// DEBUG-only reader navigation timings. Read them with
/// `log stream --predicate 'subsystem == "com.gamicarts.TabBuddy" AND category == "Perf"'`.
/// No-ops in release builds.
@MainActor
enum PerfTrace {
    #if DEBUG
    private static let log = Logger(subsystem: "com.gamicarts.TabBuddy", category: "Perf")
    private static var starts: [String: CFAbsoluteTime] = [:]
    #endif

    static func begin(_ name: String) {
        #if DEBUG
        starts[name] = CFAbsoluteTimeGetCurrent()
        #endif
    }

    /// Logs the elapsed time once per `begin`; later `end` calls are ignored.
    static func end(_ name: String, _ detail: String = "") {
        #if DEBUG
        guard let start = starts.removeValue(forKey: name) else { return }
        let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        log.notice("\(name, privacy: .public) \(detail, privacy: .public) \(ms) ms")
        #endif
    }

    /// Logs elapsed time without ending the measurement.
    static func lap(_ name: String, _ detail: String) {
        #if DEBUG
        guard let start = starts[name] else { return }
        let ms = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        log.notice("\(name, privacy: .public) · \(detail, privacy: .public) \(ms) ms")
        #endif
    }

    /// Ends the measurement after the next run-loop turn, i.e. once the frame that
    /// shows the new state has been committed.
    static func endAfterCommit(_ name: String, _ detail: String = "") {
        #if DEBUG
        DispatchQueue.main.async { end(name, detail) }
        #endif
    }
}

enum AppPage: Hashable {
    case viewer
    case liveTranscribe
    case tabMaker
    case tabMakerDocument(UUID)
    case tuner
    case tutor
}

enum ImportKind { case file, folder }


struct ContentView: View {
    // Inject a write-capable context
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var didBootstrap = false

    @State private var currentFile: FileItem?
    @State private var path: [AppPage] = []
    @State private var viewerIdentity = UUID()
    /// Identity of the open score, captured at open so a record deleted by an iCloud
    /// import (another device's duplicate merge) can be followed without reading the
    /// deleted model.
    @State private var openedScore: ReaderRecordGuard.Opened?
    @State private var readerNotice: String?

    var body: some View {
        NavigationStack(path: $path) {
            
            // Root: the browser
            FileBrowserView(
                currentFile: $currentFile,
                path: $path,
                onFileOpen: openFile
            )
            .navigationDestination(for: AppPage.self) { page in
                switch page {
                case .viewer:
                    TabViewerView(file: $currentFile, path: $path)
                        .id(viewerIdentity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .liveTranscribe:
                    LiveTranscriptionView()
                case .tabMaker:
                    MakerCompositionListView(path: $path)
                case .tabMakerDocument(let tabID):
                    TabMakerDocumentDestination(tabID: tabID)
                case .tuner:
                    TunerView()
                case .tutor:
                    TutorRootView(onOpenSong: openFile)
                }
            }
        }
        .onAppear {
            guard !didBootstrap else { return }
            didBootstrap = true
            LibraryMigration.runIfNeeded(context: context)
            LibraryManager.shared.bootstrap(context: context)
            LibraryManager.shared.importPendingSharedFiles(context: context)
            TagIndexer.rebuild(in: context)
            backfillFolderNames()
            if TutorLaunchOptions.openOnLaunch { path.append(.tutor) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { ReaderPersistence.flush(context) }
        }
        .onChange(of: path) { _, newPath in
            // Duplicate merging leaves the open score's record alone until the reader closes.
            LibraryManager.shared.readerFileID = newPath.contains(.viewer) ? currentFile?.id : nil
        }
        .onChange(of: currentFile?.id) { _, id in
            if path.contains(.viewer) { LibraryManager.shared.readerFileID = id }
        }
        // The open score's record can disappear when iCloud imports another device's
        // duplicate merge, or after a merge/removal here. Follow it or close cleanly.
        .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event, event.type == .import, event.endDate != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                validateOpenScore()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryManager.recordsChangedNotification)) { _ in
            validateOpenScore()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
            guard openedScore != nil, (notification.object as? ModelContext) === context else { return }
            validateOpenScore()
        }
        .alert("Song moved", isPresented: Binding(get: { readerNotice != nil }, set: { if !$0 { readerNotice = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(readerNotice ?? "")
        }
    }

    private func openFile(_ file: FileItem) {
        PerfTrace.begin("open")
        // 1) rotate the identity
        viewerIdentity = UUID()
        // 2) set the file
        currentFile = file
        openedScore = ReaderRecordGuard.Opened(file)
        // 3) push the destination
        path.append(.viewer)
    }

    private func validateOpenScore() {
        guard path.contains(.viewer), let opened = openedScore else { return }
        switch ReaderRecordGuard.resolve(opened, current: currentFile, context: context,
                                         survivor: LibraryManager.shared.survivor(for:)) {
        case .unchanged:
            return
        case .redirect(let survivor):
            // Reopen the viewer on the merged record; practice settings were merged into it.
            ReaderPersistence.flush(context)
            openedScore = ReaderRecordGuard.Opened(survivor)
            viewerIdentity = UUID()
            currentFile = survivor
            LibraryManager.shared.readerFileID = survivor.id
        case .gone:
            openedScore = nil
            path.removeAll { $0 == .viewer }
            currentFile = nil
            LibraryManager.shared.readerFileID = nil
            readerNotice = "This song’s library entry was removed or merged on another device. Open it again from the library."
        }
    }

    private func backfillFolderNames() {
        // Root-level files intentionally have no folder label. Derive nested
        // labels from stored paths; opening every source file is unnecessary.
        Task {
            let query = FetchDescriptor<FileItem>(predicate: #Predicate { $0.folderName == "" })
            guard let items = try? context.fetch(query) else { return }
            for (index, item) in items.enumerated() {
                if let path = item.effectiveRelativePath {
                    let parent = (path as NSString).deletingLastPathComponent
                    if !parent.isEmpty { item.folderName = (parent as NSString).lastPathComponent }
                }
                if index.isMultiple(of: 100) {
                    do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
                }
            }
            if context.hasChanges { try? context.save() }
        }
    }

}

/// Keeps the reader pointed at a live catalog record without reading a deleted model.
@MainActor
enum ReaderRecordGuard {
    struct Opened: Equatable {
        let id: UUID
        let modelID: PersistentIdentifier
        let libraryID: UUID?
        let path: String?

        init(_ item: FileItem) {
            id = item.id
            modelID = item.persistentModelID
            libraryID = item.libraryID
            path = item.effectiveRelativePath
        }
    }

    enum Resolution: Equatable {
        case unchanged
        case redirect(FileItem)
        case gone
    }

    /// The open record still exists → unchanged. Otherwise follow this device's merge
    /// map, then a record with the same library and path (the survivor another device
    /// chose); with neither, the reader closes.
    static func resolve(_ opened: Opened, current: FileItem?, context: ModelContext,
                        survivor: (UUID) -> UUID?) -> Resolution {
        let id = opened.id
        let live = (try? context.fetch(FetchDescriptor<FileItem>(predicate: #Predicate { $0.id == id }))) ?? []
        if let current, live.contains(where: { $0.persistentModelID == current.persistentModelID }) { return .unchanged }
        if current == nil, !live.isEmpty { return .unchanged }
        if let first = live.first { return .redirect(first) }
        if let next = survivor(id),
           let found = try? context.fetch(FetchDescriptor<FileItem>(predicate: #Predicate { $0.id == next })).first {
            return .redirect(found)
        }
        if let library = opened.libraryID, let path = opened.path {
            let optionalLibrary: UUID? = library
            let optionalPath: String? = path
            let samePath = (try? context.fetch(FetchDescriptor<FileItem>(predicate: #Predicate {
                $0.libraryID == optionalLibrary && ($0.storageRelativePath == optionalPath || $0.libraryPath == optionalPath)
            }))) ?? []
            if let found = samePath.sorted(by: { LibraryDuplicateMerger.precedes(($0.importedAt, $0.id), ($1.importedAt, $1.id)) }).first {
                return .redirect(found)
            }
        }
        return .gone
    }
}

/// Resolves a ComposedTab by UUID from SwiftData and presents TabMakerView.
private struct TabMakerDocumentDestination: View {
    let tabID: UUID
    @Query private var allTabs: [ComposedTab]

    var body: some View {
        if let tab = allTabs.first(where: { $0.id == tabID }) {
            TabMakerView(composedTab: tab)
        } else {
            Text("Composition not found")
                .foregroundColor(.secondary)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
