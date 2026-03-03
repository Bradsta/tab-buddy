import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum AppPage: Hashable {
    case viewer
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

                }
            }
        }
        .onAppear {
            TagIndexer.rebuild(in: context)
            backfillFolderNames()
            LibraryManager.shared.processPendingImports(context: context)
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
