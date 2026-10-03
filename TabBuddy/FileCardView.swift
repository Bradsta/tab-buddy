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

/// The library facts a card needs for its menu and delete confirmation. Passed by
/// value so 200 visible cards do not each observe every `LibraryManager` publish.
struct LibraryCardContext: Equatable {
    var mode: LibraryMode?
    var storageOption: LibraryStorageOption?
    var libraryName: String?

    @MainActor static var current: LibraryCardContext {
        let manager = LibraryManager.shared
        return LibraryCardContext(mode: manager.mode, storageOption: manager.storageOption, libraryName: manager.libraryName)
    }
}

struct FileCardView: View, Equatable {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager

    @Bindable var file: FileItem
    var library: LibraryCardContext = .current

    /// Blue-tinted "active" treatment for the Jump back in rail.
    var isRail: Bool = false
    /// Show the uppercase folder eyebrow (flat grid only).
    var showEyebrow: Bool = true
    /// Selection mode (edit mode) overlays a checkmark and taps toggle selection.
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var availability: FileAvailability = .available

    let onOpen: () -> Void
    let onDelete: () -> Void
    var onToggleSelect: () -> Void = {}

    @State private var showTags = false
    @State private var showDetails = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var showFileDeleteConfirmation = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.file == rhs.file && lhs.isRail == rhs.isRail
            && lhs.isSelecting == rhs.isSelecting && lhs.isSelected == rhs.isSelected
            && lhs.availability == rhs.availability && lhs.library == rhs.library
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
        .sheet(isPresented: $showDetails) { ScoreDetailsView(file: file) }
        .sheet(isPresented: $showTags) { TagEditorView(file: file) }
        .sheet(isPresented: $showRename) { renameSheet }
        .alert("Delete this file?", isPresented: $showFileDeleteConfirmation) {
            Button("Delete File", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteMessage)
        }
    }

    /// Names the exact file. Only the app-managed library folder offers deletion;
    /// a folder you chose only offers Remove from Library.
    private var deleteMessage: String {
        let path = file.effectiveRelativePath ?? file.filename
        return "Deletes “\(path)” from the library folder. This can’t be undone."
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
            if !knownInstruments.isEmpty {
                Button { showDetails = true } label: { instrumentPill }
                    .buttonStyle(.borderless).disabled(isSelecting)
                    .accessibilityLabel("Edit instrument")
            }
            if file.displayTuning != "Unknown" {
                Button { showDetails = true } label: { tuningPill }
                    .buttonStyle(.borderless).disabled(isSelecting)
                    .accessibilityLabel("Edit tuning")
            }
            if file.lastOpenedAt > file.importedAt {
                Text(minimalAgo(file.lastOpenedAt))
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
            if availability != .available {
                Label(availabilityLabel, systemImage: availabilityIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(availability == .missing ? Color.red : Color.orange)
                    .lineLimit(1)
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

    private var availabilityLabel: String {
        switch availability {
        case .available: return "Available"
        case .downloading: return "Downloading"
        case .accessNeeded: return "Access Needed"
        case .missing: return "Missing"
        case .failed: return "Unavailable"
        }
    }

    private var availabilityIcon: String {
        switch availability {
        case .available: return "checkmark.circle"
        case .downloading: return "icloud.and.arrow.down"
        case .accessNeeded: return "folder.badge.questionmark"
        case .missing: return "questionmark.folder"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var knownInstruments: [Instrument] { file.instrumentKinds.filter { $0 != .unknown } }

    private var instrumentPill: some View {
        let inst = knownInstruments.first ?? .unknown
        return HStack(spacing: 3) {
            Image(systemName: inst.symbol)
                .font(.system(size: 9, weight: .medium))
            Text(inst.label + (knownInstruments.count > 1 ? " +\(knownInstruments.count - 1)" : ""))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color(.secondaryLabel))
        .padding(.init(top: 2, leading: 7, bottom: 2, trailing: 7))
        .background(Color(.systemGray).opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }

    private var tuningPill: some View {
        Text(file.displayTuning)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(Color(.secondaryLabel))
            .padding(.init(top: 2, leading: 7, bottom: 2, trailing: 7))
            .background(Color(.systemGray).opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
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
            newName = file.displayTitle
            showRename = true
        } label: { Label("Rename", systemImage: "pencil") }
        Divider()
        if library.mode == .externalFolder {
            Button { onDelete() } label: {
                Label("Remove from Library", systemImage: "minus.circle")
            }
        } else {
            Button(role: .destructive) { showFileDeleteConfirmation = true } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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
                Section {
                    TextField("Song name", text: $newName)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Sets the display name in your library. The original file (\(file.filename)) is untouched.")
                }
            }
            .navigationTitle("Rename")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: commitRename)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRename = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Sets a non-destructive display title (never moves/renames the file).
    /// An empty value clears the custom title, reverting to the filename.
    @MainActor
    private func commitRename() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        file.customTitle = trimmed.isEmpty ? nil : trimmed
        try? context.save()
        showRename = false
    }
}
