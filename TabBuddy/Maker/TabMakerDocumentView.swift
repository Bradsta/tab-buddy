//
//  TabMakerDocumentView.swift
//  TabBuddy
//
//  Scrollable canvas hosting the music staff and tab staff side by side.
//  Handles gesture input for note placement and editing.
//

import SwiftUI

struct TabMakerDocumentView: View {
    @ObservedObject var viewModel: TabMakerViewModel

    /// Points per beat at zoom 1.0
    private let beatWidth: CGFloat = 80

    /// Computed measure width based on time signature
    private var measureWidth: CGFloat {
        CGFloat(viewModel.composedTab.beatsPerMeasure) * beatWidth
    }

    /// Total canvas width
    private var totalWidth: CGFloat {
        StaffView.headerWidth + CGFloat(viewModel.composedTab.measureCount) * measureWidth + 40
    }

    /// Tracking which note is being dragged (for edit mode)
    @State private var draggingNoteID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                Spacer().frame(height: 8)

                StaffView(
                    notes: viewModel.notes,
                    draftNote: viewModel.draftNote,
                    beatsPerMeasure: viewModel.composedTab.beatsPerMeasure,
                    noteValue: viewModel.composedTab.noteValue,
                    measureCount: viewModel.composedTab.measureCount,
                    measureWidth: measureWidth,
                    playbackMeasureIndex: viewModel.playbackMeasureIndex,
                    playbackBeatFraction: viewModel.playbackBeatFraction,
                    isPlaying: viewModel.isPlaying
                )
                .gesture(staffDragGesture)

                TabStaffView(
                    notes: viewModel.notes,
                    draftNote: viewModel.draftNote,
                    tuningMIDI: viewModel.cachedTuningMIDI,
                    measureCount: viewModel.composedTab.measureCount,
                    measureWidth: measureWidth,
                    playbackMeasureIndex: viewModel.playbackMeasureIndex,
                    playbackBeatFraction: viewModel.playbackBeatFraction,
                    isPlaying: viewModel.isPlaying
                )

                Spacer()
            }
            .frame(width: totalWidth)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Staff Drag Gesture

    private var staffDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDrag(location: value.location, isStart: value.translation == .zero)
            }
            .onEnded { _ in
                handleDragEnd()
            }
    }

    private func handleDrag(location: CGPoint, isStart: Bool) {
        guard !viewModel.isPlaying else { return }

        guard let hit = StaffView.hitTest(
            location: location,
            measureWidth: measureWidth,
            measureCount: viewModel.composedTab.measureCount
        ) else { return }

        switch viewModel.activeTool {
        case .pencil:
            if isStart {
                if let existingNote = viewModel.noteAt(
                    measureIndex: hit.measureIndex,
                    positionInMeasure: hit.positionInMeasure,
                    staffStep: hit.staffStep
                ) {
                    draggingNoteID = existingNote.id
                } else {
                    draggingNoteID = nil
                }
            }

            if let noteID = draggingNoteID {
                viewModel.moveNote(id: noteID, toStaffStep: hit.staffStep)
            } else {
                if isStart {
                    viewModel.updateDraftNote(
                        measureIndex: hit.measureIndex,
                        positionInMeasure: hit.positionInMeasure,
                        staffStep: hit.staffStep
                    )
                } else if let draft = viewModel.draftNote {
                    viewModel.updateDraftNote(
                        measureIndex: draft.measureIndex,
                        positionInMeasure: draft.positionInMeasure,
                        staffStep: hit.staffStep
                    )
                }
            }

        case .eraser:
            viewModel.eraseAt(
                measureIndex: hit.measureIndex,
                positionInMeasure: hit.positionInMeasure,
                staffStep: hit.staffStep
            )
        }
    }

    private func handleDragEnd() {
        if draggingNoteID != nil {
            draggingNoteID = nil
        } else {
            viewModel.commitDraftNote()
        }
    }
}
