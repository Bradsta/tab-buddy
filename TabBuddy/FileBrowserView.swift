//
//  FileBrowserView.swift
//  TabBuddy
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RowKey: Identifiable { let id: Int }
enum ImportMode { case files, folder }

struct JSONBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}


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

    // Library state
    @StateObject private var libraryManager = LibraryManager.shared
    @State private var showLibraryPicker = false
    @State private var showCopyToLibraryPrompt = false
    @State private var pendingImportURLs: [URL] = []

    // UI state
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var showClearConfirmation = false
    @State private var showDeleteSelectedConfirmation = false
    @State private var showBackupExporter = false
    @State private var showBackupImporter = false
    @State private var backupData = Data()
    @State private var showRestoreResult = false
    @State private var restoreCount = 0
    @State private var activeTagFilter: String? = nil   // nil → no filter
    private enum SortMode: String { case name, recent, imported, mostPlayed }
    @State private var sortMode: SortMode = .name
    @State private var filterFavorite = false       // false → all files
    private enum BrowseMode { case flat, folders }
    @State private var browseMode: BrowseMode = .flat
    @State private var folderPath: [String] = []    // breadcrumb for folder navigation
    
    /// Current folder prefix built from breadcrumb, e.g. "Jazz/Standards/"
    private var currentFolderPrefix: String {
        folderPath.isEmpty ? "" : folderPath.joined(separator: "/") + "/"
    }

    private var visibleFiles: [FileItem] {
        var list = items

        // –– 1) text search ––
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()
        if !needle.isEmpty {
            list = list.filter { file in
                file.filename.localizedCaseInsensitiveContains(needle) ||
                file.tags.contains { $0.localizedCaseInsensitiveContains(needle) } ||
                file.folderName.localizedCaseInsensitiveContains(needle)
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

        // –– 4) folder filter (only show files directly in current folder) ––
        if browseMode == .folders {
            let prefix = currentFolderPrefix
            list = list.filter { file in
                guard let lp = file.libraryPath else {
                    return prefix.isEmpty  // non-library files only at root
                }
                if prefix.isEmpty {
                    // Root: show files with no subfolder
                    return !lp.contains("/")
                }
                guard lp.hasPrefix(prefix) else { return false }
                let remainder = String(lp.dropFirst(prefix.count))
                return !remainder.contains("/")  // direct children only
            }
        }

        // –– 5) sort ––
        switch sortMode {
        case .name:
            list.sort { ($0.isFavorite ? 0 : 1, $0.filename.lowercased())
                     < ($1.isFavorite ? 0 : 1, $1.filename.lowercased()) }
        case .recent:
            list.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        case .imported:
            list.sort { $0.importedAt > $1.importedAt }
        case .mostPlayed:
            list.sort { $0.playCount > $1.playCount }
        }
        return list
    }

    /// Subfolders visible at the current folder level
    private var visibleSubfolders: [String] {
        guard browseMode == .folders else { return [] }
        let prefix = currentFolderPrefix
        var folders = Set<String>()
        for file in items {
            guard let lp = file.libraryPath else { continue }
            if prefix.isEmpty {
                // Root: collect first path component if it's a directory
                if let slash = lp.firstIndex(of: "/") {
                    folders.insert(String(lp[lp.startIndex..<slash]))
                }
            } else {
                guard lp.hasPrefix(prefix) else { continue }
                let remainder = String(lp.dropFirst(prefix.count))
                if let slash = remainder.firstIndex(of: "/") {
                    folders.insert(String(remainder[remainder.startIndex..<slash]))
                }
            }
        }
        return folders.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        // file.url already starts the security scope; the viewer manages its own scope lifecycle
        guard file.url != nil else { return }

        file.lastOpenedAt = Date()
        file.playCount += 1
        try? context.save()
        onFileOpen(file)
    }
    
    // MARK: - Extracted subviews

    @ViewBuilder
    private var breadcrumbBar: some View {
        if browseMode == .folders {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button {
                        withAnimation { folderPath = [] }
                    } label: {
                        Label("Library", systemImage: "folder")
                            .font(.subheadline.weight(folderPath.isEmpty ? .semibold : .regular))
                    }
                    ForEach(Array(folderPath.enumerated()), id: \.offset) { i, name in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            withAnimation { folderPath = Array(folderPath.prefix(i + 1)) }
                        } label: {
                            Text(name)
                                .font(.subheadline.weight(i == folderPath.count - 1 ? .semibold : .regular))
                        }
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            .background(Color(.secondarySystemBackground))
            Divider()
        }
    }

    @ViewBuilder
    private func fileList(visible: [FileItem]) -> some View {
        List(selection: $selectedFiles) {
            if browseMode == .folders {
                ForEach(visibleSubfolders, id: \.self) { folder in
                    Button {
                        withAnimation { folderPath.append(folder) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            Text(folder)
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(visible) { file in
                FileRowView(file: file,
                            removeFile: { delete(file) },
                            openFile:   { open(file) })
                    .tag(file.id)
            }
        }
        .listStyle(.plain)
    }

    @ToolbarContentBuilder
    private func leadingToolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Menu {
                Picker("Sort", selection: $sortMode) {
                    Label("Name", systemImage: "textformat").tag(SortMode.name)
                    Label("Recent", systemImage: "clock").tag(SortMode.recent)
                    Label("Imported", systemImage: "arrow.down.circle").tag(SortMode.imported)
                    Label("Most Played", systemImage: "flame").tag(SortMode.mostPlayed)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }

            if libraryManager.isConfigured {
                Button {
                    withAnimation {
                        browseMode = browseMode == .flat ? .folders : .flat
                        folderPath = []
                    }
                } label: {
                    Image(systemName: browseMode == .folders ? "list.bullet" : "folder")
                }
            }

            Toggle(isOn: $filterFavorite) {
                Image(systemName: "star.fill")
            }
            .toggleStyle(.button)
        }
    }

    @ToolbarContentBuilder
    private func trailingToolbar(visible: [FileItem]) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
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
                Button("Undo") { undoManager?.undo() }
            }
            if editMode?.wrappedValue == .active {
                Button(selectedFiles.count == visible.count ? "Deselect All" : "Select All") {
                    if selectedFiles.count == visible.count {
                        selectedFiles.removeAll()
                    } else {
                        selectedFiles = Set(visible.map(\.id))
                    }
                }
            }
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
            if editMode?.wrappedValue != .active {
                importMenu
            }
            if editMode?.wrappedValue != .active {
                ellipsisMenu
            }
        }
    }

    private var importMenu: some View {
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

    private var ellipsisMenu: some View {
        Menu {
            Button {
                withAnimation {
                    editMode?.wrappedValue = .active
                }
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }

            Divider()

            Button { showLibraryPicker = true } label: {
                if let name = libraryManager.libraryName {
                    Label("Change Library (\(name))", systemImage: "folder.badge.gearshape")
                } else {
                    Label("Set Library Folder", systemImage: "folder.badge.plus")
                }
            }

            if libraryManager.isConfigured {
                Button {
                    libraryManager.rescan(context: context)
                } label: {
                    Label("Rescan Library", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    libraryManager.removeLibraryFolder()
                } label: {
                    Label("Remove Library", systemImage: "folder.badge.minus")
                }
            }

            Divider()

            Button {
                if let data = BackupManager.exportJSON(context: context) {
                    backupData = data
                    showBackupExporter = true
                }
            } label: {
                Label("Export Backup", systemImage: "square.and.arrow.up")
            }
            Button { showBackupImporter = true } label: {
                Label("Restore Backup", systemImage: "square.and.arrow.down")
            }

            Divider()

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: { Label("Remove All Files", systemImage: "trash") }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    // MARK: - Body

    var body: some View {
        let visible = visibleFiles
        mainContent(visible: visible)
            .modifier(BrowserDialogs(
                showClearConfirmation: $showClearConfirmation,
                showDeleteSelectedConfirmation: $showDeleteSelectedConfirmation,
                showCopyToLibraryPrompt: $showCopyToLibraryPrompt,
                showBackupExporter: $showBackupExporter,
                showBackupImporter: $showBackupImporter,
                showRestoreResult: $showRestoreResult,
                showPicker: $showPicker,
                showLibraryPicker: $showLibraryPicker,
                importMode: importMode,
                backupData: backupData,
                restoreCount: $restoreCount,
                pendingImportURLs: $pendingImportURLs,
                selectedFiles: $selectedFiles,
                clearAll: clearAll,
                items: items,
                context: context,
                undoManager: undoManager,
                folderImporter: folderImporter,
                libraryManager: libraryManager
            ))
            .overlay { rescanOverlay }
            .overlay { importOverlay }
            .overlay { massTagOverlay }
    }

    @ViewBuilder
    private func mainContent(visible: [FileItem]) -> some View {
        VStack(spacing: 0) {
            TagHeader(active: $activeTagFilter)
            Divider()
            breadcrumbBar
            fileList(visible: visible)
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
            leadingToolbar()
            trailingToolbar(visible: visible)
        }
    }

    @ViewBuilder
    private var rescanOverlay: some View {
        if libraryManager.isRescanning {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Rescanning Library…").font(.headline)
                    if libraryManager.rescanTotal > 0 {
                        Text("\(libraryManager.rescanProcessed) of \(libraryManager.rescanTotal) files")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ProgressView(value: Double(libraryManager.rescanProcessed),
                                     total: Double(max(libraryManager.rescanTotal, 1)))
                            .progressViewStyle(.linear).frame(width: 240)
                    } else {
                        ProgressView()
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var importOverlay: some View {
        if folderImporter.isRunning {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Importing \(folderImporter.processed) of \(folderImporter.total) files…")
                        .font(.headline)
                    ProgressView(value: Double(folderImporter.processed),
                                 total: Double(max(folderImporter.total, 1)))
                        .progressViewStyle(.linear).frame(width: 240)
                    Button("Cancel", role: .cancel) { folderImporter.cancel() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var massTagOverlay: some View {
        if showMassTagModal {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
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

// MARK: - Extracted modifier for dialogs/sheets to reduce body complexity

private struct BrowserDialogs: ViewModifier {
    @Binding var showClearConfirmation: Bool
    @Binding var showDeleteSelectedConfirmation: Bool
    @Binding var showCopyToLibraryPrompt: Bool
    @Binding var showBackupExporter: Bool
    @Binding var showBackupImporter: Bool
    @Binding var showRestoreResult: Bool
    @Binding var showPicker: Bool
    @Binding var showLibraryPicker: Bool
    let importMode: ImportMode
    let backupData: Data
    @Binding var restoreCount: Int
    @Binding var pendingImportURLs: [URL]
    @Binding var selectedFiles: Set<UUID>
    let clearAll: () -> Void
    let items: [FileItem]
    let context: ModelContext
    let undoManager: UndoManager?
    let folderImporter: FolderImporter
    let libraryManager: LibraryManager

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Remove all imported files?",
                                isPresented: $showClearConfirmation,
                                titleVisibility: .visible) {
                Button("Remove All Files", role: .destructive, action: clearAll)
                Button("Cancel", role: .cancel) { }
            }
            .alert("Delete \(selectedFiles.count) selected files?",
                   isPresented: $showDeleteSelectedConfirmation) {
                Button("Delete", role: .destructive) {
                    let filesToDelete = items.filter { selectedFiles.contains($0.id) }
                    for file in filesToDelete { context.delete(file) }
                    try? context.save()
                    undoManager?.registerUndo(withTarget: context) { ctx in
                        for file in filesToDelete { ctx.insert(file) }
                        try? ctx.save()
                    }
                    undoManager?.setActionName("Delete Selected Files")
                    selectedFiles.removeAll()
                }
                Button("Cancel", role: .cancel) { }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: importMode == .files ? [.pdf, .plainText] : [.folder],
                          allowsMultipleSelection: importMode == .files) { result in
                if case .success(let urls) = result {
                    if libraryManager.isConfigured {
                        pendingImportURLs = urls
                        showCopyToLibraryPrompt = true
                    } else {
                        folderImporter.start(urls: urls, context: context)
                    }
                }
            }
            .fileImporter(isPresented: $showLibraryPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    libraryManager.setLibraryFolder(url: url)
                }
            }
            .modifier(BrowserDialogs2(
                showCopyToLibraryPrompt: $showCopyToLibraryPrompt,
                showBackupExporter: $showBackupExporter,
                showBackupImporter: $showBackupImporter,
                showRestoreResult: $showRestoreResult,
                backupData: backupData,
                restoreCount: $restoreCount,
                pendingImportURLs: $pendingImportURLs,
                context: context,
                folderImporter: folderImporter,
                libraryManager: libraryManager
            ))
    }
}

private struct BrowserDialogs2: ViewModifier {
    @Binding var showCopyToLibraryPrompt: Bool
    @Binding var showBackupExporter: Bool
    @Binding var showBackupImporter: Bool
    @Binding var showRestoreResult: Bool
    let backupData: Data
    @Binding var restoreCount: Int
    @Binding var pendingImportURLs: [URL]
    let context: ModelContext
    let folderImporter: FolderImporter
    let libraryManager: LibraryManager

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Copy files to your library?",
                                isPresented: $showCopyToLibraryPrompt,
                                titleVisibility: .visible) {
                Button("Copy to Library (\(libraryManager.libraryName ?? "Library"))") {
                    folderImporter.startWithLibraryCopy(urls: pendingImportURLs, context: context, libraryManager: libraryManager)
                    pendingImportURLs = []
                }
                Button("Import in Place") {
                    folderImporter.start(urls: pendingImportURLs, context: context)
                    pendingImportURLs = []
                }
                Button("Cancel", role: .cancel) { pendingImportURLs = [] }
            }
            .fileExporter(isPresented: $showBackupExporter,
                          document: JSONBackupDocument(data: backupData),
                          contentType: .json,
                          defaultFilename: "TabBuddy-Backup") { _ in }
            .fileImporter(isPresented: $showBackupImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        restoreCount = BackupManager.importJSON(data: data, context: context)
                        showRestoreResult = true
                    }
                }
            }
            .alert("Restore Complete", isPresented: $showRestoreResult) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Restored metadata for \(restoreCount) files.")
            }
    }
}
