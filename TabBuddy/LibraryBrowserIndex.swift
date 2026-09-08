import Foundation
import SwiftData

/// Value snapshots keep filtering/sorting independent of SwiftData and the UI actor.
@MainActor
final class LibraryBrowserIndex: ObservableObject {
    struct Row: Sendable {
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
    private var rebuildTask: Task<Void, Never>?
    private var pendingRebuild: ([FileItem], UUID?)?
    private var generation = UUID()

    // Coalesce changes without repeatedly cancelling a large snapshot halfway through.
    func scheduleRebuild(_ files: [FileItem], libraryID: UUID?) {
        pendingRebuild = (files, libraryID)
        guard rebuildTask == nil else { return }
        let token = generation
        rebuildTask = Task {
            defer { if generation == token { rebuildTask = nil } }
            while let next = pendingRebuild, !Task.isCancelled {
                pendingRebuild = nil
                await rebuild(next.0, libraryID: next.1)
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
        rows = []; models = [:]; libraryFiles = []
        visible = []; folders = []; folderMembers = [:]; recent = []; instruments = []
        revision += 1
    }

    func rebuild(_ files: [FileItem], libraryID: UUID?) async {
        // Coalesce saves during batch imports. Model access remains on its owning actor.
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        var snapshots: [Row] = []
        var byID: [UUID: FileItem] = [:]
        var library: [FileItem] = []
        var kinds = Set<String>()
        for (index, item) in files.enumerated() {
            guard !Task.isCancelled else { return }
            if item.modelContext != nil && !item.isDeleted && (item.libraryID == nil || item.libraryID == libraryID) {
                let instruments = Set(item.instrumentKinds.map(\.rawValue))
                kinds.formUnion(instruments)
                let text = [item.filename, item.folderName, item.customTitle ?? "", item.foreword ?? "",
                            item.searchableMetadata, item.tuning ?? "", item.displayTuning, item.tags.joined(separator: "\n")].joined(separator: "\n")
                snapshots.append(Row(id: item.id, name: item.displayTitle.lowercased(), search: text,
                                     tags: Set(item.tags), instruments: instruments, favorite: item.isFavorite,
                                     opened: item.lastOpenedAt, imported: item.importedAt, playCount: item.playCount,
                                     path: item.effectiveRelativePath ?? ""))
                byID[item.id] = item
                library.append(item)
            }
            if index.isMultiple(of: 100) {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
            }
        }
        guard !Task.isCancelled else { return }
        rows = snapshots; models = byID; libraryFiles = library
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
