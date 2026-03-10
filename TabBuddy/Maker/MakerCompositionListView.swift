//
//  MakerCompositionListView.swift
//  TabBuddy
//
//  List of user-composed tabs with create and delete functionality.
//

import SwiftUI
import SwiftData

struct MakerCompositionListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ComposedTab.modifiedAt, order: .reverse)
    private var compositions: [ComposedTab]

    @Binding var path: [AppPage]

    var body: some View {
        Group {
            if compositions.isEmpty {
                emptyState
            } else {
                compositionList
            }
        }
        .navigationTitle("Compositions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createNewComposition()
                } label: {
                    Label("New", systemImage: "plus")
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Compositions")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Tap + to create your first tab")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
            Button {
                createNewComposition()
            } label: {
                Label("New Composition", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - List

    private var compositionList: some View {
        List {
            ForEach(compositions) { tab in
                Button {
                    path.append(.tabMakerDocument(tab.id))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tab.title)
                            .font(.headline)
                            .foregroundColor(.primary)
                        HStack(spacing: 12) {
                            Label("\(tab.beatsPerMeasure)/\(tab.noteValue)",
                                  systemImage: "metronome")
                            Label(tab.tuningName, systemImage: "guitars")
                            Label("\(Int(tab.bpm)) BPM", systemImage: "speedometer")
                            Label("\(tab.measureCount) measures",
                                  systemImage: "rectangle.split.3x1")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)

                        Text(tab.modifiedAt, style: .relative)
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    context.delete(compositions[index])
                }
                try? context.save()
            }
        }
    }

    // MARK: - Actions

    private func createNewComposition() {
        let tab = ComposedTab()
        context.insert(tab)
        try? context.save()
        path.append(.tabMakerDocument(tab.id))
    }
}
