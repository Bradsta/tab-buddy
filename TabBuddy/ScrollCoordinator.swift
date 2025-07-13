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
    /// Accumulates fractional scroll amounts to ensure movement at low speeds
    private var scrollResidual: CGFloat = 0

    init(scrollViewProxy: UIScrollView?,
         textViewProxy: UITextView?,
         currentFile: FileItem?,
         scrollSpeed: CGFloat) {
        self.scrollViewProxy = scrollViewProxy
        self.textViewProxy = textViewProxy
        self.currentFile = currentFile
        self.scrollSpeed = scrollSpeed
    }

    @objc func handleScrollStep(_ link: CADisplayLink) {
        guard let file = currentFile else { return }
        let dt = link.targetTimestamp - link.timestamp
        scrollResidual += scrollSpeed * CGFloat(dt)
        let stepPoints = floor(scrollResidual)
        scrollResidual -= stepPoints
        guard stepPoints > 0 else { return }
        let step = stepPoints
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
