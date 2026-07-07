//
//  DesignSystem.swift
//  TabBuddy
//
//  Gamic Arts design tokens (DESIGN.md §3). Colors resolve from the asset
//  catalog (light/dark variants live there); radii and motion are constants.
//  `Color.accentColor` is the same rose as `DS.accent` via the global
//  AccentColor asset — prefer the semantic names below in new chrome.
//

import SwiftUI

enum DS {
    // MARK: Surfaces
    /// App canvas.
    static let paper = Color("Paper")
    /// Cards, bars.
    static let surface = Color("Surface")
    /// Wells, inactive tiles, grouped-list canvas.
    static let surfaceInset = Color("SurfaceInset")
    /// Sheets, popovers, scrubber thumb.
    static let surfaceRaised = Color("SurfaceRaised")
    /// Header/transport material tint — layer over a blur.
    static let barTint = Color("BarTint")

    // MARK: Text
    static let fg1 = Color("Fg1")
    static let fg2 = Color("Fg2")
    static let fg3 = Color("Fg3")

    // MARK: Lines
    static let separator = Color("Separator")
    static let separatorStrong = Color("SeparatorStrong")

    // MARK: Accent (TabBuddy rose)
    static let accent = Color("AccentColor")
    /// Pressed states, text on soft fills.
    static let accentStrong = Color("AccentStrong")
    /// Tinted fills: tempo pill, active-measure highlight.
    static let accentSoft = Color("AccentSoft")
    /// Badges, tinted rows.
    static let accentSofter = Color("AccentSofter")

    // MARK: Caution (low-confidence)
    static let cautionSoft = Color("CautionSoft")
    static let cautionText = Color("CautionText")

    // MARK: Radii
    /// Standard control corner radius.
    static let radiusControl: CGFloat = 11
    /// Small chips.
    static let radiusChip: CGFloat = 8
    /// Raised cards (fret suggestions etc.).
    static let radiusCard: CGFloat = 15

    // MARK: Motion — ease-out, no bounces.
    static let motionFast: Animation = .easeOut(duration: 0.14)
    static let motionSlow: Animation = .easeOut(duration: 0.24)

    // MARK: Metrics
    static let headerHeight: CGFloat = 52
    static let playDiameter: CGFloat = 52
    static let playDiameterCompact: CGFloat = 48
    static let tile: CGFloat = 44
    static let tileCompact: CGFloat = 38
}

// MARK: - Shared chrome bits

/// Header/transport background: bar tint over system blur, per DESIGN.md.
struct BarMaterial: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            DS.barTint
        }
        .ignoresSafeArea()
    }
}

/// 1px hairline for bar edges.
struct Hairline: View {
    var body: some View {
        DS.separator.frame(height: 1.0 / UIScreen.main.scale)
    }
}

/// Minimal elapsed-time display: "2m12s", "42s".
func minimalTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let m = total / 60
    let s = total % 60
    return m > 0 ? "\(m)m\(String(format: "%02d", s))s" : "\(s)s"
}

/// Minimal relative timestamp: "now", "5m", "3h", "2d", "3w", "4mo", "2y".
func minimalAgo(_ date: Date) -> String {
    let s = max(0, Date().timeIntervalSince(date))
    let day = 86_400.0
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(Int(s / 60))m"
    case ..<day: return "\(Int(s / 3600))h"
    case ..<(day * 7): return "\(Int(s / day))d"
    case ..<(day * 30): return "\(Int(s / (day * 7)))w"
    case ..<(day * 365): return "\(Int(s / (day * 30)))mo"
    default: return "\(Int(s / (day * 365)))y"
    }
}
