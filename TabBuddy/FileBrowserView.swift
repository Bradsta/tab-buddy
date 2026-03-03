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

    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager
    @Query private var allFiles: [FileItem]

    @Query(sort: \TagStat.count, order: .reverse)
    private var stats: [TagStat]

    @State private var showTagActions = false
    @State private var tagForActions: String? = nil
    @State private var renameText: String = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(stats) { stat in
                    TagChip(
                        label: "\(stat.name) (\(stat.count))",
                        isActive: active == stat.name,
                        action: {
                            withAnimation {
                                active = (active == stat.name ? nil : stat.name)
                            }
                        }
                    )
                    .onLongPressGesture {
                        // kickoff tag actions modal for this tag
                        tagForActions = stat.name
                        renameText = stat.name
                        showTagActions = true
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        .sheet(isPresented: $showTagActions) {
            NavigationView {
                Form {
                    Section(header: Text("Rename Tag")) {
                        TextField("Tag name", text: $renameText)
                    }
                    Section {
                        Button("Save") {
                            guard let oldTag = tagForActions else { return }
                            let newTagTrimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !newTagTrimmed.isEmpty else { return }
                            // capture affected files and previous active filter
                            let affectedFiles = allFiles.filter { $0.tags.contains(oldTag) }
                            let previousActive = active
                            // apply rename
                            for file in affectedFiles {
                                if let index = file.tags.firstIndex(of: oldTag) {
                                    file.tags[index] = newTagTrimmed
                                }
                            }
                            try? context.save()
                            // register undo for rename
                            undoManager?.registerUndo(withTarget: context) { ctx in
                                for file in affectedFiles {
                                    if let idx = file.tags.firstIndex(of: newTagTrimmed) {
                                        file.tags[idx] = oldTag
                                    }
                                }
                                try? ctx.save()
                                if previousActive == oldTag {
                                    active = oldTag
                                }
                                DispatchQueue.main.async {
                                    TagIndexer.rebuild(in: ctx)
                                }
                            }
                            undoManager?.setActionName("Rename Tag")
                            // update active filter
                            if previousActive == oldTag {
                                active = newTagTrimmed
                            }
                            showTagActions = false
                            TagIndexer.rebuild(in: context)
                        }
                        Button("Cancel", role: .cancel) {
                            showTagActions = false
                        }
                    }
                    Section {
                        Button("Delete Tag", role: .destructive) {
                            guard let tag = tagForActions else { return }
                            let affectedFiles = allFiles.filter { $0.tags.contains(tag) }
                            let previousActive = active
                            // remove tag from all files
                            for file in affectedFiles {
                                file.tags.removeAll { $0 == tag }
                            }
                            try? context.save()
                            // clear active filter if it was this tag
                            if active == tag { active = nil }
                            // register undo for deletion
                            undoManager?.registerUndo(withTarget: context) { ctx in
                                for file in affectedFiles {
                                    if !file.tags.contains(tag) {
                                        file.tags.append(tag)
                                    }
                                }
                                try? ctx.save()
                                if previousActive == tag {
                                    active = tag
                                }
                                DispatchQueue.main.async {
                                    TagIndexer.rebuild(in: ctx)
                                }
                            }
                            undoManager?.setActionName("Delete Tag")
                            showTagActions = false
                            TagIndexer.rebuild(in: context)
                        }
                    }
                }
                .navigationTitle("Tag Actions")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showTagActions = false }
                    }
                }
            }
        }
    }
    
}

// File list ------------------------------------------------------------------
private struct BrowserList: View {
    let rows: [FileItem]
    let delete: (FileItem) -> Void
    let open:   (FileItem) -> Void
    @Binding var searchText: String
    @Binding var selectedFiles: Set<UUID>
    @Binding var multiSelectMode: Bool

    var body: some View {
        List {
            ForEach(rows) { file in
                HStack(spacing: 8) {
                    // show selection indicator in multi-select mode
                    if multiSelectMode {
                        Image(systemName: selectedFiles.contains(file.id) ? "checkmark.circle.fill" : "circle")
                    }
                    // file row content, disable taps when in multi-select mode
                    FileRowView(file: file,
                                removeFile: { delete(file) },
                                openFile:   { if !multiSelectMode { open(file) } })
                        .allowsHitTesting(!multiSelectMode)
                }
                .contentShape(Rectangle())
                .background(multiSelectMode && selectedFiles.contains(file.id)
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear)
                .onTapGesture {
                    if multiSelectMode {
                        if selectedFiles.contains(file.id) {
                            selectedFiles.remove(file.id)
                        } else {
                            selectedFiles.insert(file.id)
                        }
                    } else {
                        open(file)
                    }
                }
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
    @Environment(\.editMode) private var editMode

    /// Multi-select support
    @State private var selectedFiles: Set<UUID> = []
    @State private var showMassTagModal = false
    
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
    @State private var isSearchPresented = false
    @State private var showClearConfirmation = false
    @State private var showDeleteSelectedConfirmation = false
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

            List(selection: $selectedFiles) {
                ForEach(visible) { file in
                    FileRowView(file: file,
                                removeFile: { delete(file) },
                                openFile:   { open(file) })
                        .tag(file.id)
                }
            }
            .listStyle(.plain)
        }
        .searchable(text: $searchText,
                    isPresented: $isSearchPresented,
                    placement: .toolbar,
                    prompt: "Search tags or names")
        .onChange(of: path) { newPath in
            if newPath.isEmpty && !searchText.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchPresented = true
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                Menu {
                    Picker("Sort", selection: $sortByRecent) {
                        Label("Name", systemImage: "textformat").tag(false)
                        Label("Recent", systemImage: "clock").tag(true)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }

                Toggle(isOn: $filterFavorite) {
                    Image(systemName: "star.fill")
                }
                .toggleStyle(.button)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // button to exit selection mode
                if editMode?.wrappedValue == .active {
                    Button("Done Selecting") {
                        withAnimation {
                            editMode?.wrappedValue = .inactive
                            selectedFiles.removeAll()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if (undoManager?.canUndo ?? false) {
                    Button("Undo") {
                        undoManager?.undo()
                    }
                }
                if editMode?.wrappedValue == .active {
                    Button(selectedFiles.count == visible.count ? "Deselect All" : "Select All") {
                        if selectedFiles.count == visible.count {
                            // all selected: deselect all
                            selectedFiles.removeAll()
                        } else {
                            // select all currently visible rows
                            let allIds = Set(visible.map { $0.id })
                            selectedFiles = allIds
                        }
                    }
                }
                // mass-tag selected files
                if !selectedFiles.isEmpty {
                    Button("Tag Selected (\(selectedFiles.count))") {
                        showMassTagModal = true
                    }
                }
                if !selectedFiles.isEmpty {
                    Button("Delete Selected (\(selectedFiles.count))", role: .destructive) {
                        showDeleteSelectedConfirmation = true
                    }
                }

                // Import button (files or folder)
                if editMode?.wrappedValue != .active {
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
                }

                // Ellipsis menu
                if editMode?.wrappedValue != .active {
                    Menu {
                        // toggle multi-select mode
                        Button {
                            withAnimation {
                                editMode?.wrappedValue = (editMode?.wrappedValue == .active ? .inactive : .active)
                                if editMode?.wrappedValue == .inactive {
                                    selectedFiles.removeAll()
                                }
                            }
                        } label: {
                            Label(editMode?.wrappedValue == .active ? "Done" : "Select", systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: { Label("Remove All Files", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .confirmationDialog("Remove all imported files?",
                            isPresented: $showClearConfirmation,
                            titleVisibility: .visible) {
            Button("Remove All Files", role: .destructive, action: clearAll)
            Button("Cancel", role: .cancel) { }
        }
        .alert(
            "Delete \(selectedFiles.count) selected files?",
            isPresented: $showDeleteSelectedConfirmation
        ) {
            Button("Delete", role: .destructive) {
                let filesToDelete = items.filter { selectedFiles.contains($0.id) }
                // 1. Remove selected files
                for file in filesToDelete {
                    context.delete(file)
                }
                try? context.save()
                // 2. Register undo for group deletion
                undoManager?.registerUndo(withTarget: context) { ctx in
                    for file in filesToDelete {
                        ctx.insert(file)
                    }
                    try? ctx.save()
                }
                undoManager?.setActionName("Delete Selected Files")
                // 3. Clear selection
                selectedFiles.removeAll()
            }
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
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    
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
        .overlay {
            if showMassTagModal {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    // direct card without NavigationView
                    MassTagView(
                        files: visibleFiles.filter { selectedFiles.contains($0.id) }
                    ) {
                        showMassTagModal = false
                    }
                    .frame(maxWidth: 600)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(32)
                }
            }
        }
    }
}

