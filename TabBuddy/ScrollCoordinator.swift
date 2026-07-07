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
    /// Whether the current document is a PDF. Cached so the per-frame scroll
    /// step never re-resolves the file's bookmark (which opens a security-scoped
    /// resource on every access and would leak one ~30×/sec during auto-scroll).
    var isPDF: Bool = false
    /// How many points to scroll each frame
    var scrollSpeed: CGFloat
    /// Accumulates fractional scroll amounts to ensure movement at low speeds
    private var scrollResidual: CGFloat = 0

    /// Loop marker positions (scroll Y offsets)
    var loopStartY: CGFloat? = nil
    var loopEndY: CGFloat? = nil

    /// When true, auto-scroll wraps back to the top once it reaches the bottom
    /// (the "loop" control in the Original file view).
    var loopToTop: Bool = false

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
        guard currentFile != nil else { return }
        let dt = link.targetTimestamp - link.timestamp
        scrollResidual += scrollSpeed * CGFloat(dt)
        let stepPoints = floor(scrollResidual)
        scrollResidual -= stepPoints
        guard stepPoints > 0 else { return }
        let step = stepPoints
        if isPDF {
            guard let sv = scrollViewProxy else { return }
            sv.setContentOffset(.init(x: sv.contentOffset.x,
                                      y: nextY(for: sv, step: step)), animated: false)
        } else {
            guard let tv = textViewProxy else { return }
            tv.setContentOffset(.init(x: tv.contentOffset.x,
                                      y: nextY(for: tv, step: step)), animated: false)
        }
    }

    /// Next scroll offset. Loop-to-top gets a RUNWAY: instead of wrapping the
    /// moment the last line reaches the bottom edge (which leaves it zero
    /// play time), the content keeps scrolling up past the end — credits
    /// style — and wraps only once the final line has cleared the top of the
    /// screen. Motion never pauses, and the ending stays playable.
    private func nextY(for scrollView: UIScrollView, step: CGFloat) -> CGFloat {
        let inset = scrollView.adjustedContentInset
        let contentBottom = scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        let y = scrollView.contentOffset.y + step

        if loopToTop {
            let runwayEnd = contentBottom + (scrollView.bounds.height - inset.top - inset.bottom) * 0.95
            return y >= runwayEnd ? -inset.top : y
        }
        if let start = loopStartY, let end = loopEndY, y >= end {
            return start
        }
        return min(y, max(-inset.top, contentBottom))
    }
}
