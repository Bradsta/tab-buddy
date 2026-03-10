//
//  TabText.swift
//  TabBuddy
//
//  Created by Brad Guerrero on 5/26/24.
//

import SwiftUI
import UIKit

struct TabText: UIViewRepresentable {
    @Binding var fontSize: CGFloat
    var content: String
    @Binding var textViewProxy: UITextView?

    /// Playback highlight overlay (managed externally by PlaybackCoordinator)
    var highlightOverlay: PlaybackHighlightOverlay?

    /// Callback when user taps at a character index (for seek-to-measure)
    var onTapAtCharacter: ((Int) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.text = content
        textView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Add highlight overlay as subview (frame managed by overlay itself)
        if let overlay = highlightOverlay {
            overlay.frame = textView.bounds
            textView.addSubview(overlay)
        }

        // Add tap gesture for seek-to-measure
        if onTapAtCharacter != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleTap(_:)))
            textView.addGestureRecognizer(tap)
        }

        DispatchQueue.main.async {
            self.textViewProxy = textView
        }

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        if uiView.text != content {
            uiView.text = content

            // Adjust font size after updating content
            DispatchQueue.main.async {
                self.adjustFontSizeToFit(textView: uiView)
            }
        }

        // Overlay manages its own frame positioning in syncFrameAndRedraw()

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapAtCharacter: onTapAtCharacter)
    }

    final class Coordinator: NSObject {
        var onTapAtCharacter: ((Int) -> Void)?

        init(onTapAtCharacter: ((Int) -> Void)?) {
            self.onTapAtCharacter = onTapAtCharacter
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            let point = gesture.location(in: textView)
            let charIndex = textView.layoutManager.characterIndex(
                for: point,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            onTapAtCharacter?(charIndex)
        }
    }

    private func adjustFontSizeToFit(textView: UITextView) {
        let currentFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let textAttributes: [NSAttributedString.Key: Any] = [.font: currentFont]
        let textWidth = (content as NSString).size(withAttributes: textAttributes).width

        let bufferWidth = 50.0
        let availableWidth = textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right - bufferWidth

        if availableWidth > 0 && textWidth > 0 {
            let scaleFactor = availableWidth / textWidth
            let newFontSize = max(min(fontSize * scaleFactor, 18), 4) // clamp between 4 and 18

            if abs(newFontSize - fontSize) > 1 {
                DispatchQueue.main.async {
                    self.fontSize = newFontSize
                }
            }
        }
    }
}
