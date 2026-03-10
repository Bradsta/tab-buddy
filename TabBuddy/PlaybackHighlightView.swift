//
//  PlaybackHighlightView.swift
//  TabBuddy
//
//  Transparent overlay drawn on top of UITextView to show
//  the current playback position as a highlight column.
//

import UIKit

final class PlaybackHighlightOverlay: UIView {

    /// The rectangle to highlight (in the text view's content coordinate space).
    var highlightRect: CGRect = .zero {
        didSet {
            if highlightRect != oldValue {
                syncFrameAndRedraw()
            }
        }
    }

    /// Whether the highlight is visible.
    var isHighlightVisible: Bool = false {
        didSet { syncFrameAndRedraw() }
    }

    /// Highlight fill color (semi-transparent)
    var highlightColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.12)

    /// Cursor line color (the leading edge)
    var cursorColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    /// Reposition the overlay to match the text view's visible area and redraw.
    /// By sizing to the viewport (not the full content), the backing store stays
    /// small and iOS won't silently clip draws for tall documents.
    private func syncFrameAndRedraw() {
        if let textView = superview as? UITextView {
            let visible = CGRect(origin: textView.contentOffset, size: textView.bounds.size)
            if frame != visible {
                frame = visible
            }
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard isHighlightVisible, highlightRect.width > 0, highlightRect.height > 0 else { return }

        // Transform content-space highlight rect to overlay-local coordinates.
        // The overlay's origin is at the text view's contentOffset (top of visible area).
        let localRect = highlightRect.offsetBy(dx: -frame.origin.x, dy: -frame.origin.y)

        // Skip drawing if the highlight is entirely outside the visible area
        guard localRect.intersects(bounds) else { return }

        // Draw the translucent highlight rectangle
        highlightColor.setFill()
        let highlightPath = UIBezierPath(roundedRect: localRect, cornerRadius: 2)
        highlightPath.fill()

        // Draw the cursor line at the leading edge
        cursorColor.setFill()
        let cursorWidth: CGFloat = 2
        let cursorRect = CGRect(
            x: localRect.minX - cursorWidth / 2,
            y: localRect.minY,
            width: cursorWidth,
            height: localRect.height
        )
        UIBezierPath(rect: cursorRect).fill()
    }

    // MARK: - Coordinate Calculation

    /// Calculate the highlight rect for a given measure in a text view.
    /// - Parameters:
    ///   - measure: The measure to highlight
    ///   - beatFraction: 0.0–1.0 position within the measure
    ///   - system: The system containing the measure
    ///   - textView: The text view displaying the tab
    ///   - charWidth: Width of one monospaced character in points
    /// - Returns: The rect in the text view's content coordinate space
    static func calculateRect(
        measure: Measure,
        beatFraction: Double,
        system: MeasureSystem,
        textView: UITextView,
        charWidth: CGFloat
    ) -> CGRect {
        guard let columnRange = measure.columnRange,
              let lineRange = system.lineRange
        else { return .zero }

        let inset = textView.textContainerInset

        // X position: based on column range and beat fraction
        let measureStartX = inset.left + CGFloat(columnRange.lowerBound) * charWidth
        let measureWidth = CGFloat(columnRange.count) * charWidth
        let cursorX = measureStartX + CGFloat(beatFraction) * measureWidth

        // Highlight width: from cursor to a small region ahead
        let highlightWidth = max(charWidth * 2, measureWidth * 0.05)

        // Y position: use layoutManager for precise positioning.
        // The simple lineRange * lineHeight estimate drifts due to line wrapping
        // and spacing, causing the highlight to disappear on longer tabs.
        let systemStartY: CGFloat
        let systemEndY: CGFloat
        let text = textView.text ?? ""
        let lines = text.components(separatedBy: "\n")

        // Get Y for the first line of the system
        var charIndexStart = 0
        for i in 0..<min(lineRange.lowerBound, lines.count) {
            charIndexStart += lines[i].count + 1
        }
        let safeStart = min(charIndexStart, max(0, text.count - 1))
        let nsRangeStart = NSRange(location: safeStart, length: 1)
        let glyphRangeStart = textView.layoutManager.glyphRange(
            forCharacterRange: nsRangeStart, actualCharacterRange: nil
        )
        let rectStart = textView.layoutManager.boundingRect(
            forGlyphRange: glyphRangeStart, in: textView.textContainer
        )
        systemStartY = inset.top + rectStart.origin.y

        // Get Y for the last line of the system
        let lastLine = lineRange.lowerBound + lineRange.count - 1
        var charIndexEnd = 0
        for i in 0..<min(lastLine + 1, lines.count) {
            charIndexEnd += lines[i].count + 1
        }
        let safeEnd = min(max(0, charIndexEnd - 1), max(0, text.count - 1))
        let nsRangeEnd = NSRange(location: safeEnd, length: 1)
        let glyphRangeEnd = textView.layoutManager.glyphRange(
            forCharacterRange: nsRangeEnd, actualCharacterRange: nil
        )
        let rectEnd = textView.layoutManager.boundingRect(
            forGlyphRange: glyphRangeEnd, in: textView.textContainer
        )
        systemEndY = inset.top + rectEnd.origin.y + rectEnd.height

        let systemHeight = systemEndY - systemStartY

        return CGRect(
            x: cursorX,
            y: systemStartY,
            width: highlightWidth,
            height: systemHeight
        )
    }

    /// Calculate the width of one monospaced character for the given font.
    static func monoCharWidth(for font: UIFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = ("M" as NSString).size(withAttributes: attributes)
        return size.width
    }
}
