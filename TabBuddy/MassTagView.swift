import SwiftUI
import SwiftData

/// A standalone view for mass-tagging files.
struct MassTagView: View {
    let files: [FileItem]
    var onFinish: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager
    @State private var newTag: String = ""
    @Query(sort: \TagStat.count, order: .reverse)
    private var stats: [TagStat]

    private func applySuggestion(_ tag: String) {
        let previousTags = files.map { ($0, $0.tags) }
        for file in files where !file.tags.contains(tag) {
            file.tags.append(tag)
        }
        try? context.save()
        undoManager?.registerUndo(withTarget: context) { ctx in
            for (file, tags) in previousTags {
                file.tags = tags
            }
            try? ctx.save()
        }
        undoManager?.setActionName("Apply Tag to Selection")
    }

    private func removeCommonTag(_ tag: String) {
        let previousTags = files.map { ($0, $0.tags) }
        for file in files {
            file.tags.removeAll { $0 == tag }
        }
        try? context.save()
        undoManager?.registerUndo(withTarget: context) { ctx in
            for (file, tags) in previousTags {
                file.tags = tags
            }
            try? ctx.save()
        }
        undoManager?.setActionName("Remove Tag from Selection")
    }

    var body: some View {
        Form {
            Section("Common Tags") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(stats.filter { stat in
                            // tags on every file
                            files.allSatisfy { $0.tags.contains(stat.name) }
                        }) { stat in
                            TagChip(label: stat.name, isActive: true) {
                                removeCommonTag(stat.name)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
            Section("Tags to Add") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(stats.filter { stat in
                            // include any tag not on every file
                            !files.allSatisfy { $0.tags.contains(stat.name) }
                        }) { stat in
                            TagChip(label: stat.name, isActive: false) {
                                applySuggestion(stat.name)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
            Section(header: Text("Add Tag")) {
                TextField("Tag name", text: $newTag)
            }
            Section {
                Button("Apply to \(files.count) files") {
                    let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !tag.isEmpty else { return }
                    for file in files {
                        if !file.tags.contains(tag) {
                            file.tags.append(tag)
                        }
                    }
                    try? context.save()
                    onFinish?()
                }
                .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Close", role: .cancel) {
                    onFinish?()
                }
            }
        }
    }
}
