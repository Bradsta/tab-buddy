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

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.text = content
        textView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        DispatchQueue.main.async {
            self.textViewProxy = textView
        }

        // Delay font adjustment very slightly after layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.adjustFontSizeToFit(textView: textView)
        }

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        uiView.text = content
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
