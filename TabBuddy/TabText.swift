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

    class Coordinator: NSObject {
        var parent: TabText

        init(parent: TabText) {
            self.parent = parent
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.text = content
        textView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        
        DispatchQueue.main.async {
            self.textViewProxy = textView
        }
        
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        uiView.text = content
    }
}
