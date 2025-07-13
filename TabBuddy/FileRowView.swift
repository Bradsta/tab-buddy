import SwiftUI
import SwiftData
import Observation
import UIKit
import UniformTypeIdentifiers

struct FileRowView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager

    @Bindable var file: FileItem                     // SwiftData row

    // callbacks supplied by the list
    let removeFile: () -> Void
    let openFile:   () -> Void

    // local UI state
    @State private var showTags    = false
    @State private var confirmDel  = false
    @State private var showRename = false
    @State private var newName    = ""

    /// retain controller to prevent deallocation
    @State private var docController: UIDocumentInteractionController?

    var body: some View {
        HStack(spacing: 12) {

            // ── Left-side controls ─────────────────────────────────────
            Button {
                let wasFavorite = file.isFavorite
                file.isFavorite.toggle()
                try? context.save()

                undoManager?.registerUndo(withTarget: context) { ctx in
                    file.isFavorite = wasFavorite
                    try? ctx.save()
                }
                undoManager?.setActionName(wasFavorite
                                          ? "Unfavorite File"
                                          : "Favorite File")
            } label: {
                 Image(systemName: file.isFavorite ? "star.fill" : "star")
             }
            .buttonStyle(.borderless)

            Menu {
                Button { showTags = true } label: {
                    Label("Edit Tags", systemImage: "tag")
                }
                Button(role: .destructive) { confirmDel = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)

            // ── Centre: filename + tags ────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Button(action: openFile) {
                    Text(file.filename)
                        .font(.headline)
                        // you can also add a highlight effect if you like:
                        // .foregroundColor(.primary)
                }
                .buttonStyle(.plain)

                if !file.tags.isEmpty {
                    Text("Tags: \(file.tags.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if file.lastOpenedAt > file.importedAt {
                    TimelineView(.periodic(from: file.lastOpenedAt, by: 60)) { _ in
                            Text(file.lastOpenedAt,
                                 format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                }
                Button(action: openFile) {
                    Image(systemName: "arrow.up.right.square")
                        .frame(minWidth: 24)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)

        // Swipe-to-delete  (leading edge) ------------------------------
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(role: .destructive, action: removeFile) {
                Label("Delete", systemImage: "trash")
            }
        }

        // Swipe-to-tags (trailing edge) -------------------------------
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { showTags = true } label: {
                Label("Tags", systemImage: "tag")
            }
        }

        // Tag-editor sheet & delete confirmation ----------------------
        .sheet(isPresented: $showTags) {
            TagEditorView(file: file)
        }
        .sheet(isPresented: $showRename) { renameSheet }
        .confirmationDialog("Delete “\(file.filename)”?",
                            isPresented: $confirmDel,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: removeFile)
            Button("Cancel", role: .cancel) { }
        }
    }
    
    private func revealInFinder() {
        guard let fileURL = file.url else { return }
        let folderURL = fileURL.deletingLastPathComponent()

        UIApplication.shared.open(folderURL)
    }
    
    private var renameSheet: some View {
        NavigationStack {
            Form {
                TextField("File name", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onAppear { DispatchQueue.main.async {                   // select all
                        UITextField.appearance().selectAll(nil)
                    }}
            }
            .navigationTitle("Rename")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: commitRename)
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRename = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    @MainActor
        private func commitRename() {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let oldURL = file.url else { return }

            let newURL = oldURL.deletingLastPathComponent()
                               .appendingPathComponent(trimmed)

            do {
                // security-scoped access
                _ = oldURL.startAccessingSecurityScopedResource()
                defer { oldURL.stopAccessingSecurityScopedResource() }

                try FileManager.default.moveItem(at: oldURL, to: newURL)

                // new bookmark & model update
                let bookmark = try newURL.bookmarkData()
                file.bookmark = bookmark
                file.filename = trimmed
                try context.save()
                // optional: re-index tags etc. (not needed for rename)
                showRename = false
            } catch {
                print("Rename failed:", error)
                // You could show an alert here
            }
        }
}
