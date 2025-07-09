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
    /// How many points to scroll each frame
    var scrollSpeed: CGFloat

    init(scrollViewProxy: UIScrollView?,
         textViewProxy: UITextView?,
         currentFile: FileItem?,
         scrollSpeed: CGFloat) {
        self.scrollViewProxy = scrollViewProxy
        self.textViewProxy = textViewProxy
        self.currentFile = currentFile
        self.scrollSpeed = scrollSpeed
    }

    @objc func handleScrollStep() {
        guard let file = currentFile else { return }
        let step = scrollSpeed / 20.0
        if file.url?.pathExtension.lowercased() == "pdf" {
            guard let sv = scrollViewProxy else { return }
            let y = min(sv.contentOffset.y + step,
                        sv.contentSize.height - sv.bounds.height)
            sv.setContentOffset(.init(x: sv.contentOffset.x, y: y), animated: false)
        } else {
            guard let tv = textViewProxy else { return }
            let y = min(tv.contentOffset.y + step,
                        tv.contentSize.height - tv.bounds.height)
            tv.setContentOffset(.init(x: tv.contentOffset.x, y: y), animated: false)
        }
    }
}
