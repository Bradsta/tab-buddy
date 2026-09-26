import SwiftUI
import SwiftData

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
    }

    private func openFile(_ file: FileItem) {
        // 1) rotate the identity
        viewerIdentity = UUID()
        // 2) set the file
        currentFile = file
        // 3) push the destination
        path.append(.viewer)
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
