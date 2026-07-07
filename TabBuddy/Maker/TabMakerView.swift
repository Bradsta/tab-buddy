//
//  TabMakerView.swift
//  TabBuddy
//
//  Root view for the tab maker editor: shared header (editable title,
//  Edit/Preview switch), document canvas, and the bottom maker transport.
//

import SwiftUI

struct TabMakerView: View {
    @StateObject private var viewModel: TabMakerViewModel
    @Environment(\.dismiss) private var dismiss

    /// 0 = Edit, 1 = Preview (read-only drawn render).
    @State private var viewMode = 0

    init(composedTab: ComposedTab) {
        _viewModel = StateObject(wrappedValue: TabMakerViewModel(composedTab: composedTab))
    }

    var body: some View {
        Group {
            if viewMode == 1 {
                makerPreview
            } else {
                TabMakerDocumentView(viewModel: viewModel)
                    .frame(maxHeight: .infinity)
                    .overlay {
                        NoteInputOverlay {
                            viewModel.toggleTool()
                        }
                        .allowsHitTesting(true)
                    }
            }
        }
        .background(DS.paper.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if viewMode == 0, let id = viewModel.lastPlacedNoteID,
               let note = viewModel.notes.first(where: { $0.id == id }) {
                FretSuggestionCard(viewModel: viewModel, note: note)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { makerHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MakerTransportBar(viewModel: viewModel,
                              coordinator: viewModel.playbackCoordinator)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear {
            viewModel.stopPlayback()
            viewModel.stopTranscription()
        }
    }

    // MARK: - Header

    private var makerHeader: some View {
        ViewerHeader(
            title: viewModel.composedTab.title,
            subtitle: makerSubtitle,
            editableTitle: Binding(
                get: { viewModel.composedTab.title },
                set: { viewModel.composedTab.title = $0 }
            ),
            switchSegments: [
                ViewSwitchSegment(id: 0, icon: "pencil", label: "Edit"),
                ViewSwitchSegment(id: 1, icon: "eye", label: "Preview"),
            ],
            switchSelection: $viewMode,
            backLabel: "Compositions",
            onBack: { dismiss() }
        )
    }

    /// `Tuning · TimeSig · N bars`
    private var makerSubtitle: String {
        let tab = viewModel.composedTab
        return [
            tab.tuningName,
            "\(tab.beatsPerMeasure)/\(tab.noteValue)",
            "\(tab.measureCount) bars",
        ].joined(separator: " · ")
    }

    // MARK: - Preview (read-only drawn render)

    private var makerPreview: some View {
        let model = TabRenderModelBuilder.build(from: viewModel.buildMeasureMap())
        return ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.systems, id: \.index) { sys in
                    DrawnTabSystemView(
                        system: sys,
                        model: model,
                        palette: .light,
                        scale: 1.0,
                        showRhythm: true,
                        showStaff: false,
                        isCurrentSystem: false,
                        currentMeasure: -1,
                        beatFraction: 0,
                        isPlaying: false,
                        loopStart: nil,
                        loopEnd: nil,
                        onSeek: { _ in }
                    )
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
    }
}
