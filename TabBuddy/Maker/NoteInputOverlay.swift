//
//  NoteInputOverlay.swift
//  TabBuddy
//
//  UIViewRepresentable that captures Apple Pencil double-tap events
//  and routes them to the TabMakerViewModel for tool toggling.
//

import SwiftUI
import UIKit

struct NoteInputOverlay: UIViewRepresentable {
    let onPencilDoubleTap: () -> Void

    func makeUIView(context: Context) -> PencilInteractionView {
        let view = PencilInteractionView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)

        return view
    }

    func updateUIView(_ uiView: PencilInteractionView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPencilDoubleTap: onPencilDoubleTap)
    }

    class Coordinator: NSObject, UIPencilInteractionDelegate {
        let onPencilDoubleTap: () -> Void

        init(onPencilDoubleTap: @escaping () -> Void) {
            self.onPencilDoubleTap = onPencilDoubleTap
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            onPencilDoubleTap()
        }
    }
}

/// Simple UIView subclass to host the pencil interaction.
class PencilInteractionView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Only intercept pencil events, let touch events pass through
        // to the SwiftUI gesture recognizers underneath
        return false
    }
}
