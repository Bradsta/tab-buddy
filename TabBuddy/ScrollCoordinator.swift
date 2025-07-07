//
//  ScrollCoordinator.swift
//  TabBuddy
//

import ObjectiveC
import UIKit

class ScrollCoordinator: NSObject {
    weak var scrollViewProxy: UIScrollView?
    weak var textViewProxy: UITextView?
    var currentFile: FileItem?

    init(scrollViewProxy: UIScrollView?,
         textViewProxy: UITextView?,
         currentFile: FileItem?) {
        self.scrollViewProxy = scrollViewProxy
        self.textViewProxy = textViewProxy
        self.currentFile = currentFile
    }

    @objc func handleScrollStep() {
        guard let file = currentFile else { return }

        let step: CGFloat = 1

        if file.url?.pathExtension.lowercased() == "pdf" {
            guard let scrollView = scrollViewProxy else { return }
            let newOffset = min(scrollView.contentOffset.y + step,
                                scrollView.contentSize.height - scrollView.bounds.size.height)
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newOffset), animated: false)
        } else {
            guard let textView = textViewProxy else { return }
            let newOffset = min(textView.contentOffset.y + step,
                                textView.contentSize.height - textView.bounds.size.height)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: newOffset), animated: false)
        }
    }
}
