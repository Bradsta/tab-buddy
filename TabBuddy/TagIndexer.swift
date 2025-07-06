import SwiftData

/// Rebuilds the TagStat table from the current FileItem rows.
/// Runs on the main actor because ModelContext is main-actor-isolated.
struct TagIndexer {

    @MainActor
    static func rebuild(in context: ModelContext) {
        // 1. wipe existing TagStat rows
        if let rows = try? context.fetch(FetchDescriptor<TagStat>()) {
            rows.forEach { context.delete($0) }
        }

        // 2. tally tags
        var tally: [String: Int] = [:]
        if let files = try? context.fetch(FetchDescriptor<FileItem>()) {
            for f in files { for t in f.tags { tally[t, default: 0] += 1 } }
        }

        // 3. insert new stats
        for (tag, n) in tally {
            context.insert(TagStat(name: tag, count: n))
        }
        try? context.save()
    }
}
