import SwiftUI
import SwiftData
import Observation            // for @Bindable

struct TagEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var file: FileItem
    @Query(sort: \TagStat.count, order: .reverse)
    private var stats: [TagStat]

    @State private var newTag = ""

    private func toggle(_ tag: String) {
        if let idx = file.tags.firstIndex(of: tag) {
            file.tags.remove(at: idx)
        } else {
            file.tags.append(tag)
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("Existing Tags") {
                    ForEach(file.tags, id: \.self) { tag in
                        Text(tag)
                    }
                    .onDelete { offsets in
                        file.tags.remove(atOffsets: offsets)
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
                Section("Suggestions") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(stats) { stat in
                                let isOn = file.tags.contains(stat.name)
                                TagChip(label: stat.name, isActive: isOn) {
                                    toggle(stat.name)
                                }
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 4)
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
