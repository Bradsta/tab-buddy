//
//  TabMakerView.swift
//  TabBuddy
//
//  Root view for the tab maker editor. Combines toolbar,
//  document view, and Apple Pencil interaction overlay.
//

import SwiftUI

struct TabMakerView: View {
    @StateObject private var viewModel: TabMakerViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    init(composedTab: ComposedTab) {
        _viewModel = StateObject(wrappedValue: TabMakerViewModel(composedTab: composedTab))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            TabMakerToolbar(viewModel: viewModel)

            Divider()

            // Document canvas — fills remaining space
            TabMakerDocumentView(viewModel: viewModel)
                .frame(maxHeight: .infinity)
                .overlay {
                    NoteInputOverlay {
                        viewModel.toggleTool()
                    }
                    .allowsHitTesting(true)
                }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Title", text: Binding(
                    get: { viewModel.composedTab.title },
                    set: { viewModel.composedTab.title = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .focused($titleFocused)
            }
        }
        .onDisappear {
            viewModel.stopPlayback()
            viewModel.stopTranscription()
        }
    }
}
