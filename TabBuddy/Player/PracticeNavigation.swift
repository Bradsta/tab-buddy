import SwiftUI

enum NotationMode: String { case tabOnly, tabAndStaff, original, staffOnly }
enum AutoScrollMode: String { case off, follow, line, smooth }

/// Navigation is independent of synthesized audio.
struct PracticeNavigationPicker: View {
    @Binding var mode: String
    var body: some View {
        Picker("Navigation", selection: Binding(get: {
            mode == AutoScrollMode.smooth.rawValue ? "smooth" : "follow"
        }, set: { mode = $0 })) {
            Text("Smooth scroll").tag("smooth")
            Text("Follow measures").tag("follow")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// Lives inside the score's scroll content and advances it independently of tempo.
struct SmoothScoreScroller: UIViewRepresentable {
    var speed: CGFloat
    var loop: Bool
    var restart: Int
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.speed = speed
        context.coordinator.loop = loop
        context.coordinator.probe = view
        if context.coordinator.restart != restart {
            context.coordinator.restart = restart
            if let scroll = context.coordinator.scrollView {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
            }
        }
        context.coordinator.updateClock()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.stopClock() }

    final class Coordinator: NSObject {
        weak var probe: UIView?
        var speed: CGFloat = 0
        var loop = false
        var restart = 0
        var residual: CGFloat = 0
        var link: CADisplayLink?
        var scrollView: UIScrollView? {
            var view = probe?.superview
            while let current = view {
                if let scroll = current as? UIScrollView { return scroll }
                view = current.superview
            }
            return nil
        }
        func updateClock() {
            if speed <= 0 { stopClock(); return }
            guard link == nil else { return }
            let clock = CADisplayLink(target: self, selector: #selector(tick(_:)))
            clock.add(to: .main, forMode: .common)
            link = clock
        }
        func stopClock() {
            link?.invalidate()
            link = nil
            residual = 0
        }

        @objc func tick(_ clock: CADisplayLink) {
            guard let scroll = scrollView, !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return }
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            residual += speed * CGFloat(clock.targetTimestamp - clock.timestamp)
            let step = floor(residual)
            residual -= step
            guard step > 0 else { return }
            let next = scroll.contentOffset.y + step
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: loop && next > bottom ? top : min(bottom, next)), animated: false)
        }
    }
}
