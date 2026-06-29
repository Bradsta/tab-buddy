//
//  FileBrowserView.swift
//  TabBuddy
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// All file-picking destinations, presented through a single `.fileImporter`.
/// SwiftUI only reliably presents one sheet-style modifier (fileImporter /
/// fileExporter) per view, so the picker is funneled through one importer
/// keyed on this enum rather than several stacked importers.
enum ImportTarget: Equatable {
    case files, folder, library, backup

    var contentTypes: [UTType] {
        switch self {
        case .files: return [.pdf, .plainText]
        case .folder, .library: return [.folder]
        case .backup: return [.json]
        }
    }

    var allowsMultiple: Bool { self == .files }
}

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

    // Picker / importer state — a single importer keyed on the active target
    @State private var activeImport: ImportTarget?
    @StateObject private var folderImporter = FolderImporter()

    // Library state
    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var canonicalConverter = CanonicalConverter.shared
    @State private var showCopyToLibraryPrompt = false
    @State private var pendingImportURLs: [URL] = []

    // UI state
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var showClearConfirmation = false
    @State private var showDeleteSelectedConfirmation = false
    @State private var showBackupExporter = false
    @State private var backupData = Data()
    @State private var showRestoreResult = false
    @State private var restoreCount = 0
    @AppStorage("browser.activeTagFilter") private var activeTagFilter: String?   // nil → no filter
    private enum SortMode: String { case name, recent, imported, mostPlayed }
    @AppStorage("browser.sortMode") private var sortMode: SortMode = .name
    @AppStorage("browser.filterFavorite") private var filterFavorite = false       // false → all files
    private enum BrowseMode: String { case flat, folders }
    @AppStorage("browser.browseMode") private var browseMode: BrowseMode = .flat
    @State private var folderPath: [String] = []    // breadcrumb for folder navigation (not persisted)
    
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
                file.folderName.localizedCaseInsensitiveContains(needle) ||
                (file.derivedTitle?.localizedCaseInsensitiveContains(needle) ?? false) ||
                (file.foreword?.localizedCaseInsensitiveContains(needle) ?? false)
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
        guard file.isBookmarkValid else { return }

        // Recency updates on open; playCount is incremented by the viewer only
        // after the tab has stayed open a few seconds (see TabViewerView).
        file.lastOpenedAt = Date()
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

    // MARK: - Card library content

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 206), spacing: 11, alignment: .top)]
    }

    /// Tabs opened in the last 7 days, most-recent first (for the rail).
    private var jumpBackInFiles: [FileItem] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return items
            .filter { $0.lastOpenedAt > $0.importedAt && $0.lastOpenedAt >= cutoff }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
            .prefix(10)
            .map { $0 }
    }

    /// Show the rail only at the unfiltered root, outside edit mode.
    private var showJumpBackIn: Bool {
        browseMode == .flat
            && folderPath.isEmpty
            && activeTagFilter == nil
            && !filterFavorite
            && searchText.trimmingCharacters(in: .whitespaces).isEmpty
            && editMode?.wrappedValue != .active
            && !jumpBackInFiles.isEmpty
    }

    private var isSelecting: Bool { editMode?.wrappedValue == .active }

    @ViewBuilder
    private func fileList(visible: [FileItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if showJumpBackIn { jumpBackInSection }
                allTabsSection(visible: visible)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var jumpBackInSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Jump back in").font(.system(size: 20, weight: .bold))
                Text("Last 7 days").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 11) {
                    ForEach(jumpBackInFiles) { file in
                        FileCardView(file: file, isRail: true, showEyebrow: true,
                                     onOpen: { open(file) }, onDelete: { delete(file) })
                            .frame(width: 216)
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private func allTabsSection(visible: [FileItem]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(browseMode == .folders ? (folderPath.last ?? "Library") : "All tabs")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Text("\(visible.count) tab\(visible.count == 1 ? "" : "s")")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }

            if visible.isEmpty && visibleSubfolders.isEmpty {
                Text("No tabs here yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 11) {
                    if browseMode == .folders {
                        ForEach(visibleSubfolders, id: \.self) { folder in
                            folderCard(folder)
                        }
                    }
                    ForEach(visible) { file in
                        FileCardView(file: file,
                                     isRail: false,
                                     showEyebrow: browseMode == .flat,
                                     isSelecting: isSelecting,
                                     isSelected: selectedFiles.contains(file.id),
                                     onOpen: { open(file) },
                                     onDelete: { delete(file) },
                                     onToggleSelect: { toggleSelect(file) })
                    }
                }
            }
        }
    }

    private func folderCard(_ folder: String) -> some View {
        Button {
            withAnimation { folderPath.append(folder) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Text(folder).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.init(top: 11, leading: 13, bottom: 11, trailing: 13))
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggleSelect(_ file: FileItem) {
        if selectedFiles.contains(file.id) {
            selectedFiles.remove(file.id)
        } else {
            selectedFiles.insert(file.id)
        }
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
                path.append(.tabMaker)
            } label: { Label("Compose Tab", systemImage: "music.note.list") }

            Button {
                path.append(.liveTranscribe)
            } label: { Label("Live Transcribe", systemImage: "mic.and.signal.meter") }

            Divider()

            Button {
                activeImport = .files
            } label: { Label("Import Files", systemImage: "doc.on.doc") }
            Button {
                activeImport = .folder
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

            Button { activeImport = .library } label: {
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
                canonicalConverter.convertLibrary(context: context)
            } label: {
                Label("Generate Tab Data", systemImage: "wand.and.stars")
            }
            .disabled(canonicalConverter.isConverting)

            Divider()

            Button {
                if let data = BackupManager.exportJSON(context: context) {
                    backupData = data
                    showBackupExporter = true
                }
            } label: {
                Label("Export Backup", systemImage: "square.and.arrow.up")
            }
            Button { activeImport = .backup } label: {
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
                showRestoreResult: $showRestoreResult,
                activeImport: $activeImport,
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
            .overlay { conversionOverlay }
            .overlay { massTagOverlay(visible: visible) }
            .onChange(of: folderImporter.isRunning) { running in
                // After an import finishes, backfill canonical tab data for any
                // newly added files (idempotent — skips already-converted ones).
                if !running {
                    canonicalConverter.convertLibrary(context: context)
                }
            }
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
    private var conversionOverlay: some View {
        if canonicalConverter.isConverting {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Generating Tab Data…").font(.headline)
                    if canonicalConverter.total > 0 {
                        Text("\(canonicalConverter.processed) of \(canonicalConverter.total) files")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ProgressView(value: Double(canonicalConverter.processed),
                                     total: Double(max(canonicalConverter.total, 1)))
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
    private func massTagOverlay(visible: [FileItem]) -> some View {
        if showMassTagModal {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                MassTagView(
                    files: visible.filter { selectedFiles.contains($0.id) }
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
    @Binding var showRestoreResult: Bool
    @Binding var activeImport: ImportTarget?
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

    // Bridges the optional `activeImport` to the Bool the importer expects.
    private var isImporting: Binding<Bool> {
        Binding(get: { activeImport != nil },
                set: { if !$0 { activeImport = nil } })
    }

    func body(content: Content) -> some View {
        // Snapshot the target for this render so the completion handler and the
        // content-type parameters agree even after SwiftUI resets the binding
        // (dismissal fires `isImporting`'s setter, which clears `activeImport`).
        let currentImport = activeImport
        return content
            // Alert-style presentations stack safely on a single view.
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
            .alert("Restore Complete", isPresented: $showRestoreResult) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Restored metadata for \(restoreCount) files.")
            }
            // Sheet-style presentations collide if stacked on one view, so each
            // gets its own host view.
            .background(
                Color.clear.fileImporter(
                    isPresented: isImporting,
                    allowedContentTypes: currentImport?.contentTypes ?? [],
                    allowsMultipleSelection: currentImport?.allowsMultiple ?? false
                ) { result in
                    handleImport(result, target: currentImport)
                }
            )
            .background(
                Color.clear.fileExporter(
                    isPresented: $showBackupExporter,
                    document: JSONBackupDocument(data: backupData),
                    contentType: .json,
                    defaultFilename: "TabBuddy-Backup") { _ in }
            )
    }

    private func handleImport(_ result: Result<[URL], Error>, target: ImportTarget?) {
        activeImport = nil
        guard case .success(let urls) = result else { return }
        switch target {
        case .files, .folder:
            if libraryManager.isConfigured {
                pendingImportURLs = urls
                showCopyToLibraryPrompt = true
            } else {
                folderImporter.start(urls: urls, context: context)
            }
        case .library:
            if let url = urls.first { libraryManager.setLibraryFolder(url: url) }
        case .backup:
            guard let url = urls.first,
                  url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) {
                restoreCount = BackupManager.importJSON(data: data, context: context)
                showRestoreResult = true
            }
        case .none:
            break
        }
    }
}
