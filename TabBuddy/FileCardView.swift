//
//  FileCardView.swift
//  TabBuddy
//
//  Card representation of a library tab, per the Card Library redesign.
//  Replaces the row layout of FileRowView in the grid. Tokens (radii, spacing,
//  tuning-pill colors, meta row) follow the design handoff.
//

import SwiftUI
import SwiftData

struct FileCardView: View, Equatable {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager

    @Bindable var file: FileItem

    /// Blue-tinted "active" treatment for the Jump back in rail.
    var isRail: Bool = false
    /// Show the uppercase folder eyebrow (flat grid only).
    var showEyebrow: Bool = true
    /// Selection mode (edit mode) overlays a checkmark and taps toggle selection.
    var isSelecting: Bool = false
    var isSelected: Bool = false

    let onOpen: () -> Void
    let onDelete: () -> Void
    var onToggleSelect: () -> Void = {}

    @State private var showTags = false
    @State private var showRename = false
    @State private var newName = ""

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.file == rhs.file && lhs.isRail == rhs.isRail
            && lhs.isSelecting == rhs.isSelecting && lhs.isSelected == rhs.isSelected
    }

    private var isPDF: Bool { file.filename.lowercased().hasSuffix(".pdf") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            Text(file.displayTitle)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Color(.label))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 38, alignment: .topLeading)
                .padding(.top, 3)

            metaRow
                .padding(.top, 9)

            if !file.tags.isEmpty {
                tagRow
                    .padding(.top, 9)
            }
        }
        .padding(.init(top: 11, leading: 13, bottom: 11, trailing: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(cardBorder)
        .overlay(alignment: .topTrailing) { selectionBadge }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { isSelecting ? onToggleSelect() : onOpen() }
        .contextMenu { contextMenu }
        .sheet(isPresented: $showTags) { TagEditorView(file: file) }
        .sheet(isPresented: $showRename) { renameSheet }
    }

    // MARK: - Pieces

    private var topRow: some View {
        HStack(alignment: .top) {
            if showEyebrow, !file.folderName.isEmpty {
                Text(file.folderName.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: toggleFavorite) {
                Image(systemName: file.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(file.isFavorite ? Color.accentColor : Color(.label).opacity(0.26))
            }
            .buttonStyle(.borderless)
        }
        .frame(minHeight: 14)
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            tuningPill
            if file.lastOpenedAt > file.importedAt {
                Text(file.lastOpenedAt, format: .relative(presentation: .named))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            if file.playCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    Text("\(file.playCount)").font(.system(size: 11))
                }
                .foregroundStyle(Color(.secondaryLabel))
            }
            if isPDF {
                Text("PDF")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .padding(.init(top: 1, leading: 3, bottom: 1, trailing: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(.separator), lineWidth: 1))
            }
            Spacer(minLength: 0)
        }
    }

    private var tuningPill: some View {
        let alt = file.isAltTuning
        return Text(file.tuning ?? "Standard")
            .font(.system(size: 10, weight: alt ? .semibold : .medium))
            .foregroundStyle(alt ? Color(.systemIndigo) : Color(.secondaryLabel))
            .padding(.init(top: 2, leading: 7, bottom: 2, trailing: 7))
            .background(
                (alt ? Color(.systemIndigo).opacity(0.12) : Color(.systemGray).opacity(0.07)),
                in: RoundedRectangle(cornerRadius: 5)
            )
    }

    private var tagRow: some View {
        let visible = Array(file.tags.prefix(2))
        let overflow = file.tags.count - visible.count
        return HStack(spacing: 5) {
            ForEach(visible, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.357, green: 0.357, blue: 0.380))
                    .padding(.init(top: 2, leading: 7, bottom: 2, trailing: 7))
                    .background(Color(.systemGray).opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(.systemGray).opacity(0.10), lineWidth: 0.5))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button { onOpen() } label: { Label("Open", systemImage: "arrow.up.right.square") }
        Button { toggleFavorite() } label: {
            Label(file.isFavorite ? "Unfavorite" : "Favorite",
                  systemImage: file.isFavorite ? "star.slash" : "star")
        }
        Button { showTags = true } label: { Label("Edit Tags", systemImage: "tag") }
        Button {
            newName = file.filename
            showRename = true
        } label: { Label("Rename", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .padding(6)
        }
    }

    private var cardBackground: some View {
        Group {
            if isRail {
                Color.accentColor.opacity(0.04)
            } else {
                Color(.secondarySystemGroupedBackground)
            }
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isRail ? Color.accentColor.opacity(0.22) : Color(.separator),
                    lineWidth: 0.5)
    }

    // MARK: - Actions

    private func toggleFavorite() {
        let wasFavorite = file.isFavorite
        file.isFavorite.toggle()
        try? context.save()
        undoManager?.registerUndo(withTarget: context) { ctx in
            file.isFavorite = wasFavorite
            try? ctx.save()
        }
        undoManager?.setActionName(wasFavorite ? "Unfavorite File" : "Favorite File")
    }

    private var renameSheet: some View {
        NavigationStack {
            Form {
                TextField("File name", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
        guard !trimmed.isEmpty, let oldURL = file.url else { return }
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            _ = oldURL.startAccessingSecurityScopedResource()
            defer { oldURL.stopAccessingSecurityScopedResource() }
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            file.bookmark = try newURL.bookmarkData()
            file.filename = trimmed
            try context.save()
            showRename = false
        } catch {
            print("Rename failed:", error)
        }
    }
}
