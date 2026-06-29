//
//  ScrollTransportBar.swift
//  TabBuddy
//
//  The bottom transport for the Original (raw text) file view. It shares the
//  visual style of `TabTransportBar` but its controls are reading-oriented:
//  back-to-top, an inline auto-scroll speed slider (using the space freed by
//  dropping play/scrubber), a loop-to-top toggle, and the Display popover.
//

import SwiftUI

struct ScrollTransportBar<Display: View>: View {
    @Binding var scrollSpeed: CGFloat
    @Binding var loopToTop: Bool
    var onBackToTop: () -> Void
    /// Hidden for PDFs, which have no text-size control to offer.
    var showDisplayButton: Bool = true
    @ViewBuilder var displayContent: () -> Display

    @State private var showDisplay = false

    private var scrolling: Bool { scrollSpeed > 0 }

    var body: some View {
        HStack(spacing: 18) {
            control(icon: "arrow.up.to.line", label: "Top", active: false) { onBackToTop() }

            // Inline auto-scroll speed — no popover.
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Button {
                        scrollSpeed = scrolling ? 0 : 8
                    } label: {
                        Image(systemName: scrolling ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(scrolling ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Slider(value: $scrollSpeed, in: 0...40, step: 1)
                        .frame(minWidth: 160)

                    Text(scrolling ? "\(Int(scrollSpeed))" : "Off")
                        .font(.callout).fontWeight(.semibold).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                }
                Text("Auto-scroll speed")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 380)

            Spacer(minLength: 8)

            control(icon: "repeat", label: "Loop to top", active: loopToTop) {
                loopToTop.toggle()
            }
            if showDisplayButton {
                control(icon: "slider.horizontal.3", label: "Display", active: false) {
                    showDisplay = true
                }
                .popover(isPresented: $showDisplay) {
                    displayContent().presentationCompactAdaptation(.popover)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
    }

    private func control(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .frame(width: 42, height: 42)
                    .background(active ? Color.accentColor : Color(uiColor: .systemFill).opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 11))
                    .foregroundStyle(active ? Color.white : Color.primary)
                Text(label).font(.system(size: 10))
                    .foregroundStyle(active ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
