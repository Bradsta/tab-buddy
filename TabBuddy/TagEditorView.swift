import SwiftUI
import SwiftData
import Observation            // for @Bindable

struct TagEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager

    @Bindable var file: FileItem
    @Query(sort: \TagStat.count, order: .reverse)
    private var stats: [TagStat]

    @State private var newTag = ""

    private func toggle(_ tag: String) {
        let previousTags = file.tags
        let isOn = file.tags.contains(tag)
        if let idx = file.tags.firstIndex(of: tag) {
            file.tags.remove(at: idx)
        } else {
            file.tags.append(tag)
        }
        try? context.save()
        undoManager?.registerUndo(withTarget: context) { ctx in
            file.tags = previousTags
            try? ctx.save()
        }
        undoManager?.setActionName(isOn ? "Remove Tag" : "Add Tag")
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("Existing Tags") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(file.tags, id: \.self) { tag in
                                TagChip(label: tag, isActive: true) {
                                    toggle(tag)
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
                            ForEach(stats.filter { !file.tags.contains($0.name) }) { stat in
                                TagChip(label: stat.name, isActive: false) {
                                    toggle(stat.name)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                }
                Section("Add Tag") {
                    HStack {
                        TextField("new tag", text: $newTag, onCommit: add)
                            .textInputAutocapitalization(.never)
                        Button("Add", action: add)
                            .disabled(trimmed.isEmpty)
                    }
                }

            }
            .navigationTitle(file.filename)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? context.save()   // persist edits
                        TagIndexer.rebuild(in: context)
                        dismiss()
                    }
                }
            }
        }
    }

    private var trimmed: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private func add() {
        guard !trimmed.isEmpty,
              !file.tags.contains(trimmed) else { return }
        file.tags.append(trimmed)
        newTag = ""
    }
}
