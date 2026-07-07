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
            let maxY = sv.contentSize.height - sv.bounds.height
            var y = sv.contentOffset.y + step
            if loopToTop, y >= maxY {
                y = loopWrapY(bottom: maxY, viewport: sv.bounds.height, now: link.timestamp)
            } else if let start = loopStartY, let end = loopEndY, y >= end {
                y = start
            } else {
                y = min(y, maxY)
                loopDwellUntil = nil
            }
            sv.setContentOffset(.init(x: sv.contentOffset.x, y: y), animated: false)
        } else {
            guard let tv = textViewProxy else { return }
            let maxY = tv.contentSize.height - tv.bounds.height
            var y = tv.contentOffset.y + step
            if loopToTop, y >= maxY {
                y = loopWrapY(bottom: maxY, viewport: tv.bounds.height, now: link.timestamp)
            } else if let start = loopStartY, let end = loopEndY, y >= end {
                y = start
            } else {
                y = min(y, maxY)
                loopDwellUntil = nil
            }
            tv.setContentOffset(.init(x: tv.contentOffset.x, y: y), animated: false)
        }
    }

    /// Loop-to-top runway: the moment the bottom arrives, the final screen of
    /// tab has only just scrolled into view — so hold there for as long as one
    /// viewport takes to scroll past (speed-adaptive) before wrapping. Without
    /// this the last measures are unplayable.
    private var loopDwellUntil: CFTimeInterval?

    private func loopWrapY(bottom maxY: CGFloat, viewport: CGFloat, now: CFTimeInterval) -> CGFloat {
        if let until = loopDwellUntil {
            if now >= until {
                loopDwellUntil = nil
                return 0
            }
            return max(0, maxY)
        }
        loopDwellUntil = now + Double(viewport / max(1, scrollSpeed))
        return max(0, maxY)
    }
}
