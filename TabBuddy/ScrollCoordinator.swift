//
//  ScrollCoordinator.swift
//  TabBuddy
//

import ObjectiveC
import UIKit

class ScrollCoordinator: NSObject, ObservableObject {
    var scrollViewProxy: UIScrollView?
    var textViewProxy: UITextView?
    var currentFile: FileItem?
    /// How many points to scroll each frame
    var scrollSpeed: CGFloat
    /// Accumulates fractional scroll amounts to ensure movement at low speeds
    private var scrollResidual: CGFloat = 0

    /// Loop marker positions (scroll Y offsets)
    var loopStartY: CGFloat? = nil
    var loopEndY: CGFloat? = nil

    init(scrollViewProxy: UIScrollView?,
         textViewProxy: UITextView?,
         currentFile: FileItem?,
         scrollSpeed: CGFloat) {
        self.scrollViewProxy = scrollViewProxy
        self.textViewProxy = textViewProxy
        self.currentFile = currentFile
        self.scrollSpeed = scrollSpeed
    }

    /// Scroll to a specific Y offset (used by PlaybackCoordinator).
    func scrollToY(_ y: CGFloat, animated: Bool = true) {
        if let sv = scrollViewProxy {
            let clampedY = min(y, sv.contentSize.height - sv.bounds.height)
            sv.setContentOffset(.init(x: sv.contentOffset.x, y: max(0, clampedY)), animated: animated)
        } else if let tv = textViewProxy {
            let clampedY = min(y, tv.contentSize.height - tv.bounds.height)
            tv.setContentOffset(.init(x: tv.contentOffset.x, y: max(0, clampedY)), animated: animated)
        }
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
            var y = min(sv.contentOffset.y + step,
                        sv.contentSize.height - sv.bounds.height)
            if let start = loopStartY, let end = loopEndY, y >= end {
                y = start
            }
            sv.setContentOffset(.init(x: sv.contentOffset.x, y: y), animated: false)
        } else {
            guard let tv = textViewProxy else { return }
            var y = min(tv.contentOffset.y + step,
                        tv.contentSize.height - tv.bounds.height)
            if let start = loopStartY, let end = loopEndY, y >= end {
                y = start
            }
            tv.setContentOffset(.init(x: tv.contentOffset.x, y: y), animated: false)
        }
    }
}
