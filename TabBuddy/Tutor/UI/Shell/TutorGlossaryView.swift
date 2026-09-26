//
//  TutorGlossaryView.swift
//  TabBuddy
//
//  Searchable glossary. Regular width: list and entry side by side. Compact:
//  list, with the entry in a sheet. "See also" links move between entries.
//

import SwiftUI

struct TutorGlossaryView: View {
    /// Entry to show first (e.g. from a lesson's term).
    var initialTerm: String? = nil

    @ObservedObject private var library = CurriculumLibrary.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var query = ""
    @State private var selected: GlossaryEntry?
    @State private var history: [GlossaryEntry] = []
    @State private var sheetEntry: GlossaryEntry?
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if sizeClass == .compact {
                list
                    .sheet(item: $sheetEntry) { entry in
                        NavigationStack {
                            TutorGlossaryEntryView(entry: entry, onSelect: { sheetEntry = $0 })
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) { Button("Done") { sheetEntry = nil } }
                                }
                        }
                        .presentationDetents([.medium, .large])
                    }
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 340)
                    DS.separator.frame(width: 1)
                    Group {
                        if let selected {
                            TutorGlossaryEntryView(entry: selected, canGoBack: !history.isEmpty,
                                                   onBack: goBack, onSelect: select(linked:))
                        } else {
                            ContentUnavailableView("Pick a term", systemImage: "character.book.closed",
                                                   description: Text("\(library.glossary.count) terms from the lessons."))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.paper)
                }
            }
        }
        .onAppear {
            if selected == nil, let initialTerm, let entry = library.glossaryEntry(for: initialTerm) {
                selected = entry
            }
        }
    }

    private var results: [GlossaryEntry] { TutorGlossarySearch.filter(library.glossary, query: query) }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.fg3)
                TextField("Search terms and definitions", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.fg3) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .padding(12)
            .background(
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            )

            let entries = results
            if entries.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    if query.isEmpty {
                        ForEach(TutorGlossarySearch.sections(entries), id: \.letter) { group in
                            Section(group.letter) {
                                ForEach(group.entries) { row($0) }
                            }
                        }
                    } else {
                        ForEach(entries) { row($0) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(DS.surface)
    }

    private func row(_ entry: GlossaryEntry) -> some View {
        Button {
            if sizeClass == .compact {
                sheetEntry = entry
            } else {
                history = []
                selected = entry
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term).font(.body.weight(.medium)).foregroundStyle(DS.fg1)
                Text(entry.definition).font(.caption).foregroundStyle(DS.fg2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected?.id == entry.id && sizeClass != .compact ? DS.accentSofter : DS.surface)
    }

    private func select(linked entry: GlossaryEntry) {
        if let selected { history.append(selected) }
        selected = entry
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        selected = previous
    }
}

struct TutorGlossaryEntryView: View {
    let entry: GlossaryEntry
    var canGoBack = false
    var onBack: () -> Void = {}
    var onSelect: (GlossaryEntry) -> Void

    @ObservedObject private var library = CurriculumLibrary.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if canGoBack {
                    Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("[", modifiers: .command)
                }
                Text(entry.term)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(DS.fg1)
                Text(entry.definition)
                    .font(.title3)
                    .foregroundStyle(DS.fg1)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !entry.seeAlso.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("See also").font(.headline).foregroundStyle(DS.fg2)
                        TutorShellFlowLayout(spacing: 8) {
                            ForEach(entry.seeAlso, id: \.self) { term in
                                if let linked = library.glossaryEntry(for: term) {
                                    Button { onSelect(linked) } label: {
                                        Text(term)
                                            .font(.body.weight(.medium))
                                            .padding(.horizontal, 12)
                                            .frame(minHeight: 36)
                                            .background(DS.accentSofter, in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous))
                                            .foregroundStyle(DS.accentStrong)
                                    }
                                    .buttonStyle(.plain)
                                    .hoverEffect(.highlight)
                                } else {
                                    Text(term)
                                        .font(.body)
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 36)
                                        .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous))
                                        .foregroundStyle(DS.fg2)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.paper)
    }
}

/// Wrapping row layout for chips.
struct TutorShellFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, maxX), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
