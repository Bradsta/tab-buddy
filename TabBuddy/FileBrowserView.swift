//
//  FileBrowserView.swift
//  TabBuddy
//

import SwiftUI
import SwiftData

struct RowKey: Identifiable { let id: Int }
enum ImportMode { case files, folder }


// Tag header ----------------------------------------------------------------
private struct TagHeader: View {
    @Binding var active: String?

    @Query(sort: \TagStat.count, order: .reverse)
    private var stats: [TagStat]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(stats) { stat in
                    TagChip(label: "\(stat.name) (\(stat.count))",
                            isActive: active == stat.name) {
                        withAnimation {
                            active =
                                (active == stat.name ? nil : stat.name)
                        }
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
    }
    
}

// File list ------------------------------------------------------------------
private struct BrowserList: View {
    let rows: [FileItem]
    let delete: (FileItem) -> Void
    let open:   (FileItem) -> Void
    @Binding var searchText: String

    var body: some View {
        List {
            ForEach(rows) { file in
                FileRowView(file: file,
                            removeFile: { delete(file) },
                            openFile:   { open(file) }).equatable()
            }
        }
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search tags or names")
        .transaction { $0.animation = nil }
        .listStyle(.plain)
    }
}


struct FileBrowserView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager

    
    // Live list, auto-refreshes when you insert / delete / edit
    @Query private var items: [FileItem]
    
    @Binding var currentFile: FileItem?
    @Binding var path: [AppPage]
    let onFileOpen: (FileItem) -> Void

    // Picker / importer state
    @State private var importMode: ImportMode = .files
    @State private var showPicker = false
    @StateObject private var folderImporter = FolderImporter()
    
    // UI state
    @State private var searchText = ""
    @State private var showClearConfirmation = false
    @State private var activeTagFilter: String? = nil   // nil → no filter
    @State private var sortByRecent   = false       // false → by name
    @State private var filterFavorite = false       // false → all files
    
    private var visibleFiles: [FileItem] {
        var list = items

        // –– 1) text search ––
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()
        if !needle.isEmpty {
            list = list.filter { file in
                file.filename.localizedCaseInsensitiveContains(needle) ||
                file.tags.contains { $0.localizedCaseInsensitiveContains(needle) }
            }
        }

        // –– 2) tag chip filter ––
        if let tag = activeTagFilter {
            list = list.filter { $0.tags.contains(tag) }
        }

        // –– 3) favourite toggle ––
        if filterFavorite {
            list = list.filter(\.isFavorite)
        }

        // –– 4) sort ––
        if sortByRecent {
            list.sort { ($0.lastOpenedAt) >
                        ($1.lastOpenedAt) }
        } else {
            list.sort { ($0.isFavorite ? 0 : 1, $0.filename.lowercased())
                     < ($1.isFavorite ? 0 : 1, $1.filename.lowercased()) }
        }
        return list
    }
    
    private func delete(_ file: FileItem) {
        // 1. Remove now
        context.delete(file)
        try? context.save()

        // 2. Register undo
        undoManager?.registerUndo(withTarget: context) { ctx in
            ctx.insert(file)           // resurrect the same object
            try? ctx.save()
        }
        undoManager?.setActionName("Delete File")
    }

    private func clearAll() {
        let snapshot = items           // capture before deletion

        for item in snapshot { context.delete(item) }
        try? context.save()

        undoManager?.registerUndo(withTarget: context) { ctx in
            for item in snapshot { ctx.insert(item) }
            try? ctx.save()
        }
        undoManager?.setActionName("Remove All Files")
    }

    
    private func open(_ file: FileItem) {
        guard let url = file.url else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        file.lastOpenedAt = Date()
        try? context.save()
        onFileOpen(file)
    }
    
    var body: some View {
        let visible  = visibleFiles

        VStack(spacing: 0) {
            TagHeader(active: $activeTagFilter)
            Divider()
            
            BrowserList(rows: visible,
                        delete: delete,
                        open:   open,
                        searchText: $searchText)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                            Picker("Sort", selection: $sortByRecent) {
                                Image(systemName: "textformat").tag(false)  // Name
                                Image(systemName: "clock").tag(true)        // Recent
                            }
                            .pickerStyle(.segmented)

                            Toggle(isOn: $filterFavorite) {
                                Image(systemName: "star.fill")
                            }
                            .toggleStyle(.button)
                        }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if (undoManager?.canUndo ?? false) {
                    Button("Undo") {
                        undoManager?.undo()
                    }
                }

                // Import button (files or folder)
                Menu {
                    Button {
                        importMode = .files
                        showPicker = true
                    } label: { Label("Import Files", systemImage: "doc.on.doc") }
                    
                    Button {
                        importMode = .folder
                        showPicker = true
                    } label: { Label("Import Folder", systemImage: "folder") }
                } label: { Label("Add", systemImage: "plus") }
                
                // Ellipsis menu
                Menu {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: { Label("Remove All Files", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Remove all imported files?",
                            isPresented: $showClearConfirmation,
                            titleVisibility: .visible) {
            Button("Remove All Files", role: .destructive, action: clearAll)
            Button("Cancel", role: .cancel) { }
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: importMode == .files ? [.pdf, .plainText] : [.folder],
            allowsMultipleSelection: importMode == .files,
            onCompletion: { result in
                if case .success(let urls) = result {
                    folderImporter.start(urls: urls, context: context)
                }
            }
        )
        .overlay {
            if folderImporter.isRunning {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        Text("Importing \(folderImporter.processed) of \(folderImporter.total) files…")
                            .font(.headline)
                        
                        ProgressView(value: Double(folderImporter.processed),
                                     total: Double(max(folderImporter.total, 1)))
                            .progressViewStyle(.linear)
                            .frame(width: 240)
                        
                        Button("Cancel", role: .cancel) {
                            folderImporter.cancel()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}
