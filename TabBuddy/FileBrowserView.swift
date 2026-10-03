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
    /// localFolder / hybridFolder adopt a folder in place for that option; externalLibrary
    /// reconnects the current folder; moveDestination is the explicit copy.
    case files, folder, localFolder, hybridFolder, externalLibrary, moveDestination, backup

    var contentTypes: [UTType] {
        switch self {
        case .files: return [.pdf, .plainText] + GuitarProFileType.contentTypes
        case .folder, .localFolder, .hybridFolder, .externalLibrary, .moveDestination: return [.folder]
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
    @Environment(\.scenePhase) private var scenePhase

    /// Multi-select support
    @State private var selectedFiles: Set<UUID> = []
    @State private var showMassTagModal = false
    @State private var showStorageSettings = false
    @State private var pendingSettingsAction: LibrarySettingsAction?
    @State private var showDiscovery = false
    @State private var importAfterDiscovery = false
    @AppStorage("browser.instrumentFilter") private var instrumentFilter = ""
    @State private var storagePickerTarget: ImportTarget?
    @State private var firstRunOption: LibraryStorageOption?
    
    /// The catalog, fetched once per `catalogRevision`. A live `@Query` re-materialized
    /// every model on most redraws (2.4 s of main-thread time per 20 s with 5,000 songs);
    /// saves, CloudKit imports, and record changes bump the revision instead.
    @State private var items: [FileItem] = []
    @StateObject private var browserIndex = LibraryBrowserIndex()
    @State private var catalogRevision = 0
    @State private var scheduledCatalogRevision: Int?
    @State private var displayedFileLimit = 200
    
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

    private var libraryItems: [FileItem] { browserIndex.libraryFiles }
    private var libraryInstruments: [Instrument] { browserIndex.instruments }
    private var visibleFiles: [FileItem] { browserIndex.visible }
    private var visibleSubfolders: [String] { browserIndex.folders }

    private var browserRequest: LibraryBrowserIndex.Request {
        .init(search: searchText, instrument: instrumentFilter, tag: activeTagFilter,
              favorites: filterFavorite, sort: sortMode.rawValue,
              folderPrefix: browseMode == .folders ? currentFolderPrefix : nil,
              revision: browserIndex.revision)
    }

    private var libraryInstrumentSelection: Binding<String> {
        Binding(get: { instrumentFilter }, set: { instrumentFilter = $0 })
    }

    private func delete(_ file: FileItem) {
        Task { await libraryManager.removeItems([file], context: context) }
    }

    /// Every catalog entry of the active library, including songs hidden because their
    /// file is missing. In Hybrid, removal itself skips songs not in this device's folder.
    private var removableLibraryItems: [FileItem] {
        let active = libraryManager.activeLibraryID
        return items.filter { $0.libraryID == nil || $0.libraryID == active }
    }

    private func clearAll() {
        let snapshot = removableLibraryItems
        Task { await libraryManager.removeItems(snapshot, context: context) }
    }

    
    private func open(_ file: FileItem) {
        guard libraryManager.availability(of: file, context: context) == .available else { return }

        // Recency updates on open; playCount is incremented by the viewer only
        // after the tab has stayed open a few seconds (see TabViewerView).
        file.lastOpenedAt = Date()
        ReaderPersistence.scheduleSave(context)

        // Backfill the content fingerprint lazily — scanning no longer hashes
        // (it would force-download every iCloud file); the file is about to be
        // read for display anyway. Used to re-link moved/renamed files.
        if file.contentHash == nil {
            Task(priority: .utility) {
                // Let the reader acquire and display the score before optional indexing.
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard file.modelContext != nil, !file.isDeleted, file.contentHash == nil else { return }
                guard let lease = try? await libraryManager.acquireFile(file) else { return }
                let url = lease.url
                let hash = await Task.detached(priority: .utility) {
                    let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                    guard values?.isUbiquitousItem != true || values?.ubiquitousItemDownloadingStatus != .notDownloaded else { return nil as String? }
                    var result: String?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: nil) { readableURL in
                        result = FileItem.fingerprint(of: readableURL)
                    }
                    return result
                }.value
                lease.close()
                await MainActor.run {
                    guard file.modelContext != nil else { return }
                    if let hash, file.contentHash == nil {
                        file.contentHash = hash
                        try? context.save()
                    }
                }
            }
        }

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
    private var jumpBackInFiles: [FileItem] { browserIndex.recent }

    /// Show the rail only at the unfiltered root, outside edit mode.
    private var showJumpBackIn: Bool {
        browseMode == .flat
            && folderPath.isEmpty
            && activeTagFilter == nil
            && !filterFavorite
            && instrumentFilter.isEmpty
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
        .onAppear { PerfTrace.endAfterCommit("back", "library visible") }
    }

    private var jumpBackInSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Jump back in").font(.system(size: 20, weight: .bold))
                Text("Last 7 days").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 11) {
                    ForEach(jumpBackInFiles, id: \.persistentModelID) { file in
                        if file.modelContext != nil && !file.isDeleted {
                        FileCardView(file: file, library: cardContext, isRail: true, showEyebrow: true,
                                     availability: libraryManager.availability(of: file, context: context),
                                     onOpen: { open(file) }, onDelete: { delete(file) })
                            .frame(width: 216)
                        }
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private func allTabsSection(visible: [FileItem]) -> some View {
        let folders = browseMode == .folders ? folderMemberships : [:]
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(browseMode == .folders ? (folderPath.last ?? "Library") : "All scores")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Text("\(visible.count) score\(visible.count == 1 ? "" : "s")")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }

            if visible.isEmpty && visibleSubfolders.isEmpty {
                Text(!browserIndex.hasSnapshot ? "Loading library…" : (searchText.isEmpty ? "No scores here yet" : "No matching scores"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 11) {
                    if browseMode == .folders {
                        ForEach(visibleSubfolders, id: \.self) { folder in
                            folderCard(folder, members: folders[folder] ?? [])
                        }
                    }
                    ForEach(Array(visible.prefix(displayedFileLimit)), id: \.persistentModelID) { file in
                        if file.modelContext != nil && !file.isDeleted {
                        FileCardView(file: file,
                                     library: cardContext,
                                     isRail: false,
                                     showEyebrow: browseMode == .flat,
                                     isSelecting: isSelecting,
                                     isSelected: selectedFiles.contains(file.id),
                                     availability: libraryManager.availability(of: file, context: context),
                                     onOpen: { open(file) },
                                     onDelete: { delete(file) },
                                     onToggleSelect: { toggleSelect(file) })
                        }
                    }
                    if visible.count > displayedFileLimit {
                        ProgressView().onAppear { displayedFileLimit += 200 }
                    }
                }
            }
        }
    }

    /// Build membership once per rendered folder section, not once per folder card.
    private var folderMemberships: [String: [FileItem]] { browserIndex.folderMembers }

    private var cardContext: LibraryCardContext {
        LibraryCardContext(mode: libraryManager.mode, storageOption: libraryManager.storageOption,
                           libraryName: libraryManager.libraryName)
    }

    private func folderCard(_ folder: String, members: [FileItem]) -> some View {
        let ids = Set(members.filter { $0.modelContext != nil && !$0.isDeleted }.map(\.id))
        let allSelected = !ids.isEmpty && ids.isSubset(of: selectedFiles)
        return Button {
            if isSelecting {
                if allSelected { selectedFiles.subtract(ids) }
                else { selectedFiles.formUnion(ids) }
            } else {
                withAnimation { folderPath.append(folder) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(members.count) scores").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelecting ? (allSelected ? "checkmark.circle.fill" : (ids.isDisjoint(with: selectedFiles) ? "circle" : "minus.circle")) : "chevron.right")
                    .foregroundStyle(allSelected ? Color.accentColor : Color.secondary)
            }
            .padding(.init(top: 11, leading: 13, bottom: 11, trailing: 13))
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(allSelected ? Color.accentColor : Color(.separator), lineWidth: allSelected ? 2 : 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Select Folder", systemImage: "checkmark.circle") {
                editMode?.wrappedValue = .active
                selectedFiles.formUnion(ids)
            }
            Button(libraryManager.mode == .externalFolder ? "Remove Folder References" : "Delete Folder Scores", role: .destructive) {
                selectedFiles = Set(LibraryManager.folderItems(in: libraryItems, relativeFolder: currentFolderPrefix + folder).map(\.id))
                showDeleteSelectedConfirmation = true
            }
        }
    }

    private func selectableIDs(visible: [FileItem]) -> Set<UUID> {
        var ids = Set(visible.map(\.id))
        if browseMode == .folders {
            for members in folderMemberships.values { ids.formUnion(members.map(\.id)) }
        }
        return ids
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
                Button(selectableIDs(visible: visible).isSubset(of: selectedFiles) ? "Deselect All" : "Select All") {
                    if selectableIDs(visible: visible).isSubset(of: selectedFiles) {
                        selectedFiles.removeAll()
                    } else {
                        selectedFiles = selectableIDs(visible: visible)
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
                Button {
                    path.append(.tuner)
                } label: { Label("Tuner", systemImage: "tuningfork") }
            }
            if editMode?.wrappedValue != .active {
                Button {
                    path.append(.tutor)
                } label: { Label("Tutor", systemImage: "graduationcap") }
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
            Button { showDiscovery = true } label: { Label("Find music online", systemImage: "globe") }
            Divider()
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

            Button { showStorageSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    /// DEBUG launch arguments for simulator checks: `-LibraryAutoSetupLocal` creates the
    /// app-local library on a fresh install; `-LibrarySettingsOpen` presents Settings.
    private func runDebugLaunchArguments() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-LibraryAutoSetupLocal") && !libraryManager.isConfigured && LibraryStorageOption.stored() == nil {
            // Wait for the storage availability check that gates setup.
            for _ in 0..<50 where libraryManager.iCloudAvailable == nil { try? await Task.sleep(for: .milliseconds(100)) }
            libraryManager.configureManaged(context: context, useICloud: false)
        }
        if arguments.contains("-LibrarySettingsOpen") { showStorageSettings = true }
        await seedLibraryIfRequested(arguments)
        if arguments.contains("-LibraryRescan") {
            for _ in 0..<100 where !libraryManager.isConfigured || libraryManager.isRescanning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            libraryManager.rescan(context: context)
        }
        // Detached: this view task is cancelled and restarted on navigation, which
        // would cut every sleep short.
        Task { @MainActor in await runPerfCycleIfRequested(arguments) }
        #endif
    }

    #if DEBUG
    /// `-LibrarySeedSynthetic <n>` writes n generated text tabs and
    /// `-LibrarySeedFolder <path>` copies the supported files under a host folder into
    /// the app-local library, then rescans. Runs once per install (a `Seed` folder
    /// marks it). For navigation timing on the simulator only.
    private func seedLibraryIfRequested(_ arguments: [String]) async {
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let synthetic = value(after: "-LibrarySeedSynthetic").flatMap(Int.init) ?? 0
        let folder = value(after: "-LibrarySeedFolder")
        guard synthetic > 0 || folder != nil else { return }
        for _ in 0..<100 where !libraryManager.isConfigured || LibraryManager.activeRoot == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let root = LibraryManager.activeRoot else { return }
        let seedRoot = root.appendingPathComponent("Seed", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: seedRoot.path) else { return }
        let count = synthetic
        let source = folder.map { URL(fileURLWithPath: $0) }
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.createDirectory(at: seedRoot, withIntermediateDirectories: true)
            let strings = ["e", "B", "G", "D", "A", "E"]
            for n in 0..<count {
                var text = "Seed Song \(n)\nArtist \(n % 97)\n\n"
                for system in 0..<(6 + n % 7) {
                    for line in strings {
                        var row = "\(line)|"
                        for _ in 0..<4 {
                            for beat in 0..<16 {
                                let fret = (system * 7 + beat * 3 + n) % 17
                                row += beat % 3 == 0 && fret < 10 ? "-\(fret)" : (beat % 5 == 0 && fret >= 10 ? "\(fret)" : "--")
                            }
                            row += "|"
                        }
                        text += row + "\n"
                    }
                    text += "\n"
                }
                let dir = seedRoot.appendingPathComponent("Folder \(n % 12)", isDirectory: true)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? text.write(to: dir.appendingPathComponent("Seed Song \(n).txt"), atomically: true, encoding: .utf8)
            }
            if let source, let items = fm.enumerator(at: source, includingPropertiesForKeys: nil) {
                let supported = Set(["txt", "pdf"] + GuitarProFileType.extensions)
                let dest = seedRoot.appendingPathComponent("Fixtures", isDirectory: true)
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for case let url as URL in items where supported.contains(url.pathExtension.lowercased()) {
                    try? fm.copyItem(at: url, to: dest.appendingPathComponent(url.lastPathComponent))
                }
            }
        }.value
        // Auto-setup may already be scanning; a second scan request would be dropped.
        for _ in 0..<600 where libraryManager.isRescanning { try? await Task.sleep(for: .milliseconds(200)) }
        libraryManager.rescan(context: context)
    }

    /// `-LibraryPerfCycle <rounds>` opens a fixed set of scores (the first seed text tab,
    /// `comet-observatory.txt`, `corridors-of-time.pdf`, `practice.gp`) `rounds` times each,
    /// waiting after each open and after each return, so PerfTrace logs open/back timings
    /// without touching the screen. Runs after seeding and the scan finish.
    nonisolated(unsafe) private static var perfCycleStarted = false
    private func runPerfCycleIfRequested(_ arguments: [String]) async {
        guard let i = arguments.firstIndex(of: "-LibraryPerfCycle"), i + 1 < arguments.count,
              let rounds = Int(arguments[i + 1]), rounds > 0, !Self.perfCycleStarted else { return }
        Self.perfCycleStarted = true
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<1200 where libraryManager.isRescanning || !browserIndex.hasSnapshot || libraryItems.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(3))
        let names = ["seed song 0.txt", "comet-observatory.txt", "corridors-of-time.pdf", "practice.gp"]
        let targets = names.compactMap { name in libraryItems.first { $0.filename.lowercased().hasSuffix(name) } }
        PerfTrace.begin("targets"); PerfTrace.end("targets", targets.map(\.filename).joined(separator: ","))
        for file in targets {
            for _ in 0..<rounds {
                open(file)
                try? await Task.sleep(for: .seconds(6))
                PerfTrace.begin("back")
                if !path.isEmpty { path.removeLast() }
                try? await Task.sleep(for: .seconds(4))
            }
        }
        PerfTrace.begin("cycle-done"); PerfTrace.end("cycle-done")
    }
    #endif

    private func performSettingsAction(_ action: LibrarySettingsAction) {
        // Start new presentations only after Settings has fully dismissed.
        switch action {
        case .exportBackup:
            if let data = BackupManager.exportJSON(context: context) {
                backupData = data
                showBackupExporter = true
            }
        case .restoreBackup: activeImport = .backup
        case .removeAll: showClearConfirmation = true
        case .generateTabData:
            Task {
                await libraryManager.stopBackgroundProcessing()
                canonicalConverter.convertLibrary(context: context)
            }
        case .prepare: libraryManager.startBackgroundProcessing(context: context, automatic: false)
        case .rescan: libraryManager.rescan(context: context)
        }
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
            .sheet(isPresented: $showDiscovery, onDismiss: {
                if importAfterDiscovery { importAfterDiscovery = false; activeImport = .files }
            }) {
                ScoreDiscoveryView(query: searchText, instrumentRaw: instrumentFilter) {
                    importAfterDiscovery = true
                    showDiscovery = false
                }
            }
            .sheet(isPresented: $showStorageSettings, onDismiss: {
                if let target = storagePickerTarget {
                    storagePickerTarget = nil
                    activeImport = target
                }
                if let action = pendingSettingsAction {
                    pendingSettingsAction = nil
                    performSettingsAction(action)
                }
            }) {
                LibraryStorageSettings(libraryManager: libraryManager,
                                       performLibraryAction: { pendingSettingsAction = $0 },
                                       isGeneratingTabData: canonicalConverter.isConverting) {
                    storagePickerTarget = $0
                }
            }
            .task { libraryManager.refreshStorageAvailability() }
            .task(id: catalogRevision) {
                // A duplicate merge saves in many batches; refresh once when it finishes.
                guard !libraryManager.isMergingDuplicates else { return }
                guard scheduledCatalogRevision != catalogRevision else { return }
                if scheduledCatalogRevision != nil {
                    // Coalesce bursts (import batches, CloudKit imports) into one fetch.
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                }
                scheduledCatalogRevision = catalogRevision
                items = (try? context.fetch(FetchDescriptor<FileItem>())) ?? []
                let manager = libraryManager
                browserIndex.scheduleRebuild(items, libraryID: libraryManager.activeLibraryID,
                                             isShown: { manager.isShownOnThisDevice($0) })
                // The first Guitar Pro open otherwise pays the whole web runtime start.
                if items.contains(where: { GuitarProFileType.extensions.contains(($0.filename as NSString).pathExtension.lowercased()) }) {
                    GuitarProWebViewPool.shared.scheduleWarm(after: 6)
                }
            }
            .task(id: browserRequest) {
                await browserIndex.filter(browserRequest)
            }
            .onChange(of: searchText) { _, _ in displayedFileLimit = 200 }
            .onChange(of: sortMode) { _, _ in displayedFileLimit = 200 }
            .onChange(of: activeTagFilter) { _, _ in displayedFileLimit = 200 }
            .onChange(of: instrumentFilter) { _, _ in displayedFileLimit = 200 }
            .onChange(of: filterFavorite) { _, _ in displayedFileLimit = 200 }
            .onChange(of: folderPath) { _, _ in displayedFileLimit = 200 }
            .onChange(of: browseMode) { _, _ in displayedFileLimit = 200 }
            // Records changed by CloudKit imports or by library operations that do not
            // save through this context's notification path.
            .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in catalogRevision += 1 }
            .onReceive(NotificationCenter.default.publisher(for: LibraryManager.recordsChangedNotification)) { _ in catalogRevision += 1 }
            .onChange(of: libraryManager.activeLibraryID) { _, _ in
                browserIndex.clear()
                catalogRevision += 1
            }
            // Songs appear or hide as this device learns which files are in its folder.
            .onReceive(libraryManager.$availabilityByFileID.dropFirst()) { _ in catalogRevision += 1 }
            .onChange(of: libraryManager.storageOption) { _, _ in catalogRevision += 1 }
            .onChange(of: libraryManager.isMergingDuplicates) { _, merging in
                if !merging { catalogRevision += 1 }
            }
            .task { await runDebugLaunchArguments() }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
                guard let savedContext = notification.object as? ModelContext, savedContext === context else { return }
                guard !libraryManager.isMergingDuplicates else { return }   // One refresh after the merge.
                if !browserIndex.applySavedChanges(notification, context: context, libraryID: libraryManager.activeLibraryID,
                                                   isShown: { libraryManager.isShownOnThisDevice($0) }) {
                    catalogRevision += 1
                }
            }

            .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
                libraryManager.refreshStorageAvailability(force: true)
                libraryManager.bootstrap(context: context)
            }
            .overlay {
                if libraryManager.isRemoving {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                        ProgressView("Removing \(libraryManager.removalProcessed) of \(libraryManager.removalTotal)…",
                                     value: Double(libraryManager.removalProcessed),
                                     total: Double(max(1, libraryManager.removalTotal)))
                            .frame(width: 260).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .overlay(alignment: .bottom) { backgroundWorkStatus }
            .overlay { moveOverlay }
            .overlay { massTagOverlay(visible: visible) }
            .onChange(of: scenePhase) { phase in
                libraryManager.setBackgroundProcessingAllowed(phase == .active)
                guard phase == .active else { return }
                libraryManager.refreshStorageAvailability()
                guard libraryManager.isConfigured else { return }
                // Opening the app uses the saved catalog. Both rescan and
                // offline refresh enumerate the entire folder, so reserve them
                // for setup, explicit changes, and user-requested refreshes.
                libraryManager.importPendingSharedFiles(context: context)
                libraryManager.startBackgroundProcessing(context: context)
            }
            // Note: no automatic whole-library canonical conversion after
            // import — reading and parsing thousands of (possibly undownloaded
            // iCloud) files made first-run setup take forever. Canonicals are
            // generated on open (convertOnOpen) or via the explicit
            // "Generate Tab Data" menu action.
    }

    @ViewBuilder
    private func mainContent(visible: [FileItem]) -> some View {
        VStack(spacing: 0) {
            libraryStatusBanner
            HStack {
                Picker("Instrument", selection: libraryInstrumentSelection) {
                    Text("All instruments").tag("")
                    ForEach(libraryInstruments, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }.pickerStyle(.menu)
                    .onChange(of: libraryInstruments, initial: true) { _, instruments in
                        if browserIndex.revision > 0 && !instrumentFilter.isEmpty && !instruments.contains(where: { $0.rawValue == instrumentFilter }) {
                            instrumentFilter = ""
                        }
                    }
                Spacer()
            }.padding(.horizontal)
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
    private var libraryStatusBanner: some View {
        if !libraryManager.isConfigured {
            let available = libraryManager.iCloudAvailable == true
            let choice = firstRunOption ?? (available ? .iCloudOnly : .localOnly)
            VStack(alignment: .leading, spacing: 10) {
                Text("Your Tab Buddy Library").font(.headline)
                Text("Choose where your songs live. You can change this later in Settings; changing never copies songs.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LibraryStorageOptionList(selected: choice, iCloudAvailable: available,
                                         isDisabled: libraryManager.isConfiguring) { firstRunOption = $0 }
                if let error = libraryManager.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                Button(libraryManager.isConfiguring ? "Setting Up Library…" : (choice == .hybrid ? "Choose Folder…" : "Get Started")) {
                    switch choice {
                    case .hybrid: activeImport = .hybridFolder
                    case .iCloudOnly: libraryManager.configureManaged(context: context, useICloud: true)
                    case .localOnly: libraryManager.configureManaged(context: context, useICloud: false)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(libraryManager.isConfiguring || libraryManager.iCloudAvailable == nil)
            }
            .padding()
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
        } else if libraryManager.accessNeeded {
            HStack {
                Image(systemName: "folder.badge.questionmark")
                VStack(alignment: .leading) {
                    Text(libraryManager.mode == .managedICloud ? "iCloud Unavailable" : "Choose This Folder on This Device").font(.headline)
                    Text(libraryManager.mode == .managedICloud
                         ? "Your library stays in iCloud. Check iCloud Drive in device Settings, then retry."
                         : "“\(libraryManager.libraryName ?? "Library")” holds this library’s songs. Choose the same folder in Files to show them here. Library info is kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if libraryManager.mode == .externalFolder {
                    Button("Choose Folder…") { activeImport = .externalLibrary }
                } else {
                    Button("Retry") { libraryManager.bootstrap(context: context); libraryManager.rescan(context: context) }
                }
            }
            .padding()
            .background(Color.orange.opacity(0.12))
        } else if browserIndex.hasLegacyImports {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                VStack(alignment: .leading) {
                    Text("Legacy Imports").font(.headline)
                    Text("Copy older bookmarked files into the active library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Move Files") { libraryManager.migrateLegacyImports(context: context) }
            }
            .padding()
            .background(Color.blue.opacity(0.1))
        } else if let error = libraryManager.lastError {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                Text(error).font(.caption)
                Spacer()
                Button("Retry") { libraryManager.rescan(context: context) }
            }.padding().background(Color.red.opacity(0.1))
        }
    }

    @ViewBuilder
    private var rescanStatus: some View {
        if libraryManager.isRescanning {
            LibraryScanStatus(progress: libraryManager.scanProgress, isPausing: libraryManager.isProcessingLibrary) {
                libraryManager.cancelScan()
            }
        } else if let summary = libraryManager.rescanSummary {
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { libraryManager.rescanSummary = nil } label: {
                    Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Dismiss scan summary")
            }.padding(.horizontal)
        }
    }

    @ViewBuilder
    private var importOverlay: some View {
        if folderImporter.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                Text(folderImporter.total == 0 ? "Finding import files…" : "Imported \(folderImporter.processed) of \(folderImporter.total) files")
                    .font(.subheadline)
                if folderImporter.total == 0 { IndeterminateScanProgress() }
                else { ProgressView(value: Double(folderImporter.processed), total: Double(max(1, folderImporter.total))) }
                Button("Cancel", role: .cancel) { folderImporter.cancel() }.frame(minHeight: 44)
            }.padding(.horizontal)
        }
    }

    @ViewBuilder
    private var moveOverlay: some View {
        if libraryManager.isMoving {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Moving Library…").font(.headline)
                    Text("\(libraryManager.moveProcessed) of \(libraryManager.moveTotal) files")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ProgressView(value: Double(libraryManager.moveProcessed),
                                 total: Double(max(libraryManager.moveTotal, 1)))
                        .frame(width: 240)
                    Text("The original library remains active until verification completes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel) {
                        libraryManager.cancelMove()
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var conversionOverlay: some View {
        if canonicalConverter.isConverting {
            VStack(alignment: .leading, spacing: 6) {
                Text("Generating Tab Data…").font(.subheadline)
                ProgressView(value: Double(canonicalConverter.processed), total: Double(max(1, canonicalConverter.total)))
                Text("\(canonicalConverter.processed) of \(canonicalConverter.total) files").font(.caption)
            }.padding(.horizontal)
        }
    }

    @ViewBuilder
    private var backgroundWorkStatus: some View {
        if libraryManager.isRescanning || libraryManager.rescanSummary != nil || libraryManager.processingSummary != nil || libraryManager.isProcessingLibrary || folderImporter.isRunning || canonicalConverter.isConverting || libraryManager.isMergingDuplicates {
            VStack(spacing: 8) {
                if libraryManager.isMergingDuplicates {
                    LibraryMergeStatus(progress: libraryManager.mergeProgress).padding(.horizontal)
                } else if libraryManager.isRescanning {
                    rescanStatus
                } else if folderImporter.isRunning {
                    importOverlay
                } else if canonicalConverter.isConverting {
                    conversionOverlay
                } else if libraryManager.isProcessingLibrary {
                    LibraryPreparationStatus(progress: libraryManager.preparationProgress) {
                        libraryManager.pauseBackgroundProcessing()
                    }.padding(.horizontal)
                } else if let summary = libraryManager.processingSummary {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Library preparation").font(.subheadline)
                            Spacer()
                            Button("Dismiss") { libraryManager.processingSummary = nil }.frame(minHeight: 44)
                        }
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                        if libraryManager.processingDeferred > 0 {
                            Text(libraryManager.mode == .managedICloud
                                 ? "Cloud-only files can be prepared once downloaded. Open a score or use Keep available offline in Settings."
                                 : "Cloud-only files can be prepared once downloaded. Open a score or download the folder in the Files app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let failure = libraryManager.processingLastFailure {
                            Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }.padding(.horizontal)
                } else {
                    rescanStatus
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 4, y: 2)
            .padding()
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

    private var removeAllConfirmation: LibraryManager.RemovalConfirmation {
        // Alert titles are evaluated on every redraw; count the catalog only while the
        // confirmation is up instead of faulting every model each time.
        guard showClearConfirmation else { return libraryManager.removalConfirmation(count: 0, all: true) }
        let active = libraryManager.activeLibraryID
        let count = items.filter { ($0.libraryID == nil || $0.libraryID == active) && libraryManager.isShownOnThisDevice($0) }.count
        return libraryManager.removalConfirmation(count: count, all: true)
    }

    private var removeSelectedConfirmation: LibraryManager.RemovalConfirmation {
        libraryManager.removalConfirmation(count: selectedFiles.count, all: false)
    }

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
            .alert(removeAllConfirmation.title, isPresented: $showClearConfirmation) {
                Button(removeAllConfirmation.button, role: .destructive, action: clearAll)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(removeAllConfirmation.message)
            }
            .alert(removeSelectedConfirmation.title, isPresented: $showDeleteSelectedConfirmation) {
                Button(removeSelectedConfirmation.button, role: .destructive) {
                    let filesToDelete = items.filter { selectedFiles.contains($0.id) }
                    Task { await libraryManager.removeItems(filesToDelete, context: context) }
                    selectedFiles.removeAll()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(removeSelectedConfirmation.message)
            }
            .confirmationDialog("Copy files to your library?",
                                isPresented: $showCopyToLibraryPrompt,
                                titleVisibility: .visible) {
                Button("Copy to Library (\(libraryManager.libraryName ?? "Library"))") {
                    folderImporter.startWithLibraryCopy(urls: pendingImportURLs, context: context, libraryManager: libraryManager)
                    pendingImportURLs = []
                }
                Button("Cancel", role: .cancel) { pendingImportURLs = [] }
            }
            .alert("Import failed", isPresented: Binding(
                get: { folderImporter.lastError != nil },
                set: { if !$0 { folderImporter.lastError = nil } }
            )) {
                Button("OK") { folderImporter.lastError = nil }
            } message: {
                Text(folderImporter.lastError ?? "The files could not be imported.")
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
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { folderImporter.lastError = error.localizedDescription }
            return
        }
        switch target {
        case .files, .folder:
            guard libraryManager.isConfigured else {
                folderImporter.lastError = LibraryFileError.notConfigured.localizedDescription
                return
            }
            folderImporter.start(urls: urls, context: context)
        case .localFolder:
            if let url = urls.first { libraryManager.useExistingFolder(url: url, context: context, option: .localOnly) }
        case .hybridFolder:
            if let url = urls.first { libraryManager.useExistingFolder(url: url, context: context, option: .hybrid) }
        case .externalLibrary:
            if let url = urls.first {
                libraryManager.configureExternal(url: url, context: context)
            }
        case .moveDestination:
            if let url = urls.first {
                libraryManager.moveLibrary(to: .externalFolder,
                                           externalParent: url,
                                           context: context)
            }
        case .backup:
            guard let url = urls.first,
                  url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) {
                restoreCount = BackupManager.importJSON(data: data, context: context, libraryID: libraryManager.activeLibraryID)
                showRestoreResult = true
            }
        case .none:
            break
        }
    }
}

/// Finding files has no denominator. Animate activity without inventing a percentage.
private struct IndeterminateScanProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            GeometryReader { geometry in
                let phase = reduceMotion ? 0.5 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                Capsule().fill(Color.accentColor.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor)
                            .frame(width: geometry.size.width / 3)
                            .offset(x: geometry.size.width * (phase * 4 / 3 - 1 / 3))
                    }.clipShape(Capsule())
            }
        }.frame(height: 4)
    }
}

private struct LibraryPreparationStatus: View {
    @ObservedObject var progress: LibraryPreparationProgress
    let pause: () -> Void

    var body: some View {
        let value = progress.value
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preparing library…").font(.subheadline)
                Spacer()
                Button("Pause", action: pause).frame(minHeight: 44)
            }
            ProgressView(value: Double(value.checked), total: Double(max(1, value.total)))
            Text("\(value.checked) of \(value.total) checked · \(value.prepared) prepared · \(value.deferred) waiting for download · \(value.failed) failed")
                .font(.caption).foregroundStyle(.secondary)
            if let failure = value.lastFailure {
                Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

private struct LibraryScanStatus: View {
    @ObservedObject var progress: LibraryScanProgress
    let isPausing: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isPausing ? "Pausing preparation…" : "Rescanning Library…").font(.subheadline)
                if isPausing {
                    Text("Rescan will start when the current file finishes.").font(.caption).foregroundStyle(.secondary)
                    IndeterminateScanProgress()
                } else if progress.total > 0 {
                    Text("\(progress.processed) of \(progress.total) checked · \(progress.added) added · \(progress.processed - progress.added) existing")
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(progress.processed), total: Double(max(progress.total, 1)))
                } else {
                    Text("Finding files… \(progress.found) found · \(progress.processed) saved to catalog · \(progress.added) new")
                        .font(.caption).foregroundStyle(.secondary)
                    IndeterminateScanProgress().accessibilityLabel("Finding files; total not yet known")
                }
            }
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel, action: cancel).frame(minHeight: 44)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

/// "Merging library info from your other devices… (n)" while a duplicate merge runs.
/// Only this view observes merge progress.
private struct LibraryMergeStatus: View {
    @ObservedObject var progress: LibraryMergeProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                Text(progress.total > 0
                     ? "Merging library info from your other devices… (\(progress.done) of \(progress.total))"
                     : "Merging library info from your other devices…")
                    .font(.subheadline)
            }
            Text("Please don’t edit songs until this finishes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
