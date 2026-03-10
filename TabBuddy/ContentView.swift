import SwiftUI
import SwiftData

enum AppPage: Hashable {
    case viewer
    case liveTranscribe
    case tabMaker
    case tabMakerDocument(UUID)
}

enum ImportKind { case file, folder }


struct ContentView: View {
    // Inject a write-capable context
    @Environment(\.modelContext) private var context

    // Live query (auto-updates UI when data changes)
    @Query(.init(sortBy: [SortDescriptor(\FileItem.filename)]))
    private var items: [FileItem]
    
    @State private var currentFile: FileItem?
    @State private var path: [AppPage] = []
    @State private var viewerIdentity = UUID()

    var body: some View {
        NavigationStack(path: $path) {
            
            // Root: the browser
            FileBrowserView(
                currentFile: $currentFile,
                path: $path,
                onFileOpen: { file in
                      // 1) rotate the identity
                      viewerIdentity = UUID()
                      
                      // 2) set the file
                      currentFile = file
                      
                      // 3) push the destination
                      path.append(.viewer)
                }
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
                }
            }
        }
        .onAppear {
            TagIndexer.rebuild(in: context)
            backfillFolderNames()
        }
    }

    private func backfillFolderNames() {
        let needsBackfill = items.filter { $0.folderName.isEmpty }
        guard !needsBackfill.isEmpty else { return }

        for item in needsBackfill {
            guard let url = item.url else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            item.folderName = url.deletingLastPathComponent().lastPathComponent
        }
        try? context.save()
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
