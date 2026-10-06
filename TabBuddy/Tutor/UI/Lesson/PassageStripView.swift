//
//  PassageStripView.swift
//  TabBuddy
//
//  The notes or chords of a passage as chips grouped into measures. Heard
//  events are green with a check; the listening target has an accent ring;
//  the chip sounding in the example is filled. Nothing is ever red. Guitar
//  single notes read as tab (fret over string name), as guitarists read them;
//  a long measure wraps inside its box instead of overflowing.
//

import SwiftUI

struct PassageStripView: View {
    let events: [ExpectedEvent]
    /// Event ids heard while listening.
    var heard: Set<Int> = []
    /// Index into `events` of the current listening target.
    var cursor: Int?
    /// Index into `events` sounding in the example.
    var playing: Int?
    var showMeasures = true
    var large = false

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 10) {
            ForEach(measures, id: \.measure) { group in
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(group.items, id: \.offset) { item in
                        chip(item.offset, item.element)
                    }
                }
                .padding(showMeasures ? 6 : 0)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                        .strokeBorder(showMeasures ? DS.separator : .clear, lineWidth: 1)
                )
                .overlay(alignment: .trailing) {
                    if showMeasures {
                        Rectangle().fill(DS.fg3).frame(width: 1.5).padding(.vertical, 4)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var measures: [(measure: Int, items: [(offset: Int, element: ExpectedEvent)])] {
        var groups: [(measure: Int, items: [(offset: Int, element: ExpectedEvent)])] = []
        for (i, e) in events.enumerated() {
            let key = showMeasures ? e.measureIndex : i
            if let last = groups.last, last.measure == key {
                groups[groups.count - 1].items.append((i, e))
            } else {
                groups.append((key, [(i, e)]))
            }
        }
        return groups
    }

    static func label(_ e: ExpectedEvent) -> String {
        e.chordName ?? e.pitches.map { NoteNaming.displayName(midi: $0) }.joined(separator: " ")
    }

    /// Standard-tuning string names by guitarist number (1 = high e).
    static let stringNames = ["e", "B", "G", "D", "A", "E"]

    /// Tab reading for a single fretted note: (fret, string name).
    static func tab(_ e: ExpectedEvent) -> (fret: String, string: String)? {
        guard e.chordName == nil, e.pitches.count == 1, let f = e.fretting, f.count == 1 else { return nil }
        let n = f[0].guitarString
        guard (1...stringNames.count).contains(n) else { return nil }
        return (String(f[0].fret), stringNames[n - 1])
    }

    static func spokenLabel(_ e: ExpectedEvent) -> String {
        guard let tab = tab(e) else { return label(e) }
        return "\(label(e)), \(tab.string) string fret \(tab.fret)"
    }

    private func chip(_ index: Int, _ event: ExpectedEvent) -> some View {
        let isHeard = heard.contains(event.id)
        let isCursor = cursor == index
        let isPlaying = playing == index
        return HStack(spacing: 4) {
            if isHeard {
                Image(systemName: "checkmark").font(.caption.weight(.bold))
            }
            if let tab = Self.tab(event) {
                VStack(spacing: 0) {
                    Text(tab.fret)
                        .font((large ? Font.title3 : .headline).weight(.bold).monospacedDigit())
                    Text(tab.string)
                        .font(.caption2.weight(.semibold))
                        .opacity(0.7)
                }
                .frame(minWidth: large ? 24 : 18)
            } else {
                Text(Self.label(event))
                    .font(large ? .title3.weight(.semibold) : .headline)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isPlaying ? .white : (isHeard ? Color.green : DS.fg1))
        .padding(.horizontal, large ? 14 : 10)
        .padding(.vertical, large ? 10 : 7)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
                .fill(isPlaying ? DS.accent : (isHeard ? Color.green.opacity(0.14) : DS.surfaceInset))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
                .strokeBorder(isCursor ? DS.accent : .clear, lineWidth: 3)
        )
        .scaleEffect(isCursor ? 1.06 : 1)
        .animation(DS.motionFast, value: isCursor)
    }

    private var accessibilityText: String {
        let parts = events.enumerated().map { i, e -> String in
            if heard.contains(e.id) { return "\(Self.spokenLabel(e)) heard" }
            if cursor == i { return "\(Self.spokenLabel(e)) current" }
            return Self.spokenLabel(e)
        }
        return "Passage: " + parts.joined(separator: ", ")
    }
}

/// Visual metronome: one dot per beat of the measure, the current one lit.
struct BeatPulseView: View {
    var beat: Int
    var beatsPerMeasure: Int
    var active: Bool

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<max(1, beatsPerMeasure), id: \.self) { i in
                let lit = active && ((beat % max(1, beatsPerMeasure)) + max(1, beatsPerMeasure)) % max(1, beatsPerMeasure) == i
                Circle()
                    .fill(lit ? (i == 0 ? DS.accentStrong : DS.accent) : DS.surfaceInset)
                    .frame(width: lit ? 26 : 18, height: lit ? 26 : 18)
                    .frame(width: 28, height: 28)
                    .animation(.easeOut(duration: 0.08), value: lit)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(active ? "Beat \(((beat % max(1, beatsPerMeasure)) + max(1, beatsPerMeasure)) % max(1, beatsPerMeasure) + 1)" : "Beat indicator")
    }
}
