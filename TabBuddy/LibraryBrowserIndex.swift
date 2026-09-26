import Foundation
import SwiftData

/// Value snapshots keep filtering/sorting independent of SwiftData and the UI actor.
@MainActor
final class LibraryBrowserIndex: ObservableObject {
    struct Row: Equatable, Sendable {
        let id: UUID
        let name: String
        let search: String
        let tags: Set<String>
        let instruments: Set<String>
        let favorite: Bool
        let opened: Date
        let imported: Date
        let playCount: Int
        let path: String
    }
    struct Request: Equatable, Sendable {
        var search = ""
        var instrument = ""
        var tag: String?
        var favorites = false
        var sort = "name"
        var folderPrefix: String?
        var revision = 0
    }
    struct Results: Sendable {
        var ids: [UUID] = []
        var folders: [String: [UUID]] = [:]
        var recent: [UUID] = []
    }

    @Published private(set) var revision = 0
    @Published private(set) var visible: [FileItem] = []
    @Published private(set) var folders: [String] = []
    @Published private(set) var folderMembers: [String: [FileItem]] = [:]
    @Published private(set) var recent: [FileItem] = []
    @Published private(set) var instruments: [Instrument] = []
    private(set) var libraryFiles: [FileItem] = []
    private var rows: [Row] = []
    private var completedRequest: Request?
    private var queryGeneration = UUID()
    @Published private(set) var hasSnapshot = false
    private var models: [UUID: FileItem] = [:]
    private var rowOffsets: [PersistentIdentifier: Int] = [:]
    private var isRebuilding = false
    private var rebuildTask: Task<Void, Never>?
    private var pendingRebuild: ([FileItem], UUID?)?
    private var isShown: (FileItem) -> Bool = { _ in true }
    private var generation = UUID()

    /// A practice preference save should not re-read tens of thousands of songs.
    /// Membership changes and unknown notification payloads use the full rebuild.
    func applySavedChanges(_ notification: Notification, context: ModelContext, libraryID: UUID?,
                           isShown: (FileItem) -> Bool = { _ in true }) -> Bool {
        guard hasSnapshot, !isRebuilding, rebuildTask == nil, pendingRebuild == nil else { return false }
        func value(_ key: ModelContext.NotificationKey) -> Any? {
            notification.userInfo?[key] ?? notification.userInfo?[key.rawValue]
        }
        if let invalidated = value(.invalidatedAllIdentifiers), (invalidated as? Bool) != false { return false }
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        guard keys.contains(where: { value($0) != nil }) else { return false }
        func identifiers(_ key: ModelContext.NotificationKey) -> Set<PersistentIdentifier>? {
            guard let raw = value(key) else { return [] }
            if let ids = raw as? Set<PersistentIdentifier> { return ids }
            if let ids = raw as? [PersistentIdentifier] { return Set(ids) }
            return nil
        }
        guard let inserted = identifiers(.insertedIdentifiers), inserted.isEmpty,
              let deleted = identifiers(.deletedIdentifiers), deleted.isEmpty,
              let updated = identifiers(.updatedIdentifiers) else { return false }
        var replacements: [(Int, Row)] = []
        for id in updated {
            guard let item = context.model(for: id) as? FileItem else { continue }
            let included = (item.libraryID == nil || item.libraryID == libraryID) && isShown(item)
            guard let offset = rowOffsets[id] else {
                if included { return false }
                continue
            }
            guard included, !item.isDeleted else { return false }
            let row = Self.snapshot(item)
            // Instrument membership is built during the full catalog pass.
            guard row.instruments == rows[offset].instruments else { return false }
            if row != rows[offset] { replacements.append((offset, row)) }
        }
        if !replacements.isEmpty {
            for (offset, row) in replacements { rows[offset] = row }
            revision += 1
        }
        return true
    }

    private static func snapshot(_ item: FileItem) -> Row {
        let text = [item.filename, item.folderName, item.customTitle ?? "", item.foreword ?? "",
                    item.searchableMetadata, item.tuning ?? "", item.displayTuning, item.tags.joined(separator: "\n")].joined(separator: "\n")
        return Row(id: item.id, name: item.displayTitle.lowercased(), search: text,
                   tags: Set(item.tags), instruments: Set(item.instrumentKinds.map(\.rawValue)), favorite: item.isFavorite,
                   opened: item.lastOpenedAt, imported: item.importedAt, playCount: item.playCount,
                   path: item.effectiveRelativePath ?? "")
    }

    // Coalesce changes without repeatedly cancelling a large snapshot halfway through.
    func scheduleRebuild(_ files: [FileItem], libraryID: UUID?, isShown: @escaping (FileItem) -> Bool = { _ in true }) {
        pendingRebuild = (files, libraryID)
        self.isShown = isShown
        guard rebuildTask == nil else { return }
        let token = generation
        rebuildTask = Task {
            defer { if generation == token { rebuildTask = nil } }
            while let next = pendingRebuild, !Task.isCancelled {
                pendingRebuild = nil
                await rebuild(next.0, libraryID: next.1, isShown: isShown)
            }
        }
    }

    func clear() {
        generation = UUID()
        queryGeneration = UUID()
        hasSnapshot = false
        rebuildTask?.cancel()
        rebuildTask = nil
        pendingRebuild = nil
        completedRequest = nil
        rows = []; models = [:]; rowOffsets = [:]; libraryFiles = []
        visible = []; folders = []; folderMembers = [:]; recent = []; instruments = []
        revision += 1
    }

    /// `isShown` hides songs whose file is not in this device's folder (their records are kept).
    func rebuild(_ files: [FileItem], libraryID: UUID?, isShown: (FileItem) -> Bool = { _ in true }) async {
        isRebuilding = true
        defer { isRebuilding = false }
        // Coalesce saves during batch imports. Model access remains on its owning actor.
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        var snapshots: [Row] = []
        var byID: [UUID: FileItem] = [:]
        var offsets: [PersistentIdentifier: Int] = [:]
        var library: [FileItem] = []
        var kinds = Set<String>()
        for (index, item) in files.enumerated() {
            guard !Task.isCancelled else { return }
            if item.modelContext != nil && !item.isDeleted && (item.libraryID == nil || item.libraryID == libraryID) && isShown(item) {
                let row = Self.snapshot(item)
                kinds.formUnion(row.instruments)
                offsets[item.persistentModelID] = snapshots.count
                snapshots.append(row)
                byID[item.id] = item
                library.append(item)
            }
            if index.isMultiple(of: 100) {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
            }
        }
        guard !Task.isCancelled else { return }
        rows = snapshots; models = byID; rowOffsets = offsets; libraryFiles = library
        instruments = Instrument.allCases.filter { kinds.contains($0.rawValue) }
        hasSnapshot = true
        revision += 1
    }

    func filter(_ request: Request) async {
        let token = UUID()
        queryGeneration = token
        guard request != completedRequest else { return }
        // Typing cancels previous work; picker changes don't need a debounce.
        if !request.search.isEmpty {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        }
        let snapshot = rows
        let work = Task.detached(priority: .userInitiated) { Self.evaluate(snapshot, request: request) }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, queryGeneration == token, request.revision == revision, let result else { return }
        completedRequest = request
        visible = result.ids.compactMap { models[$0] }
        folders = result.folders.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        folderMembers = result.folders.mapValues { $0.compactMap { models[$0] } }
        recent = result.recent.compactMap { models[$0] }
    }

    nonisolated static func evaluate(_ rows: [Row], request: Request, now: Date = .now) -> Results? {
        let needle = request.search.trimmingCharacters(in: .whitespacesAndNewlines)
        var matching: [Row] = []
        var result = Results()
        var recentRows: [Row] = []
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 100) && Task.isCancelled { return nil }
            if row.opened > row.imported && row.opened >= cutoff { recentRows.append(row) }
            if let prefix = request.folderPrefix, row.path.hasPrefix(prefix) {
                let remainder = row.path.dropFirst(prefix.count)
                if let slash = remainder.firstIndex(of: "/") {
                    result.folders[String(remainder[..<slash]), default: []].append(row.id)
                }
            }
            if !request.instrument.isEmpty && !row.instruments.contains(request.instrument) { continue }
            if let tag = request.tag, !row.tags.contains(tag) { continue }
            if request.favorites && !row.favorite { continue }
            if let prefix = request.folderPrefix {
                if row.path.isEmpty { if !prefix.isEmpty { continue } }
                else if !row.path.hasPrefix(prefix) || row.path.dropFirst(prefix.count).contains("/") { continue }
            }
            if !needle.isEmpty && !row.search.localizedCaseInsensitiveContains(needle) { continue }
            matching.append(row)
        }
        matching.sort { lhs, rhs in
            switch request.sort {
            case "recent": if lhs.opened != rhs.opened { return lhs.opened > rhs.opened }
            case "imported": if lhs.imported != rhs.imported { return lhs.imported > rhs.imported }
            case "mostPlayed": if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
            default: if lhs.favorite != rhs.favorite { return lhs.favorite }
            }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard !Task.isCancelled else { return nil }
        result.ids = matching.map(\.id)
        result.recent = recentRows.sorted { $0.opened > $1.opened }.prefix(10).map(\.id)
        return result
    }
}
