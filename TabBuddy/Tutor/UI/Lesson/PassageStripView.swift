//
//  PassageStripView.swift
//  TabBuddy
//
//  The notes or chords of a passage as chips grouped into measures, marked as
//  they are played: green check for a hit, neutral "?" when the detector was
//  unsure, a caution tint for "try again". The cursor chip has an accent ring.
//

import SwiftUI

struct PassageStripView: View {
    let events: [ExpectedEvent]
    var marks: [Int: PracticeRunModel.Mark] = [:]
    /// Index into `events` of the current target.
    var cursor: Int?
    /// Index into `events` sounding in a demo.
    var playing: Int?
    var showMeasures = true
    var large = false

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 10) {
            ForEach(measures, id: \.measure) { group in
                HStack(spacing: 6) {
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

    private func chip(_ index: Int, _ event: ExpectedEvent) -> some View {
        let mark = marks[event.id] ?? .pending
        let isCursor = cursor == index
        let isPlaying = playing == index
        let style = Self.style(for: mark)
        return HStack(spacing: 4) {
            if let icon = style.icon {
                Image(systemName: icon).font(.caption.weight(.bold))
            }
            Text(Self.label(event))
                .font(large ? .title3.weight(.semibold) : .headline)
                .lineLimit(1)
        }
        .foregroundStyle(isPlaying ? .white : style.foreground)
        .padding(.horizontal, large ? 14 : 10)
        .padding(.vertical, large ? 10 : 7)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
                .fill(isPlaying ? DS.accent : style.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
                .strokeBorder(isCursor ? DS.accent : .clear, lineWidth: 3)
        )
        .scaleEffect(isCursor ? 1.06 : 1)
        .animation(DS.motionFast, value: isCursor)
    }

    struct ChipStyle {
        var foreground: Color
        var background: Color
        var icon: String?
    }

    static func style(for mark: PracticeRunModel.Mark) -> ChipStyle {
        switch mark {
        case .pending: return ChipStyle(foreground: DS.fg1, background: DS.surfaceInset, icon: nil)
        case .hit: return ChipStyle(foreground: Color.green, background: Color.green.opacity(0.14), icon: "checkmark")
        case .notSure: return ChipStyle(foreground: DS.fg2, background: DS.surfaceInset, icon: "questionmark")
        case .retry, .partial: return ChipStyle(foreground: DS.cautionText, background: DS.cautionSoft, icon: "arrow.uturn.left")
        case .skipped, .missed: return ChipStyle(foreground: DS.fg3, background: DS.surfaceInset, icon: "minus")
        }
    }

    private var accessibilityText: String {
        let parts = events.enumerated().map { i, e -> String in
            let mark = marks[e.id] ?? .pending
            let status: String
            switch mark {
            case .pending: status = cursor == i ? "current" : ""
            case .hit: status = "played"
            case .notSure: status = "not sure"
            case .retry, .partial: status = "try again"
            case .skipped: status = "skipped"
            case .missed: status = "missed"
            }
            return status.isEmpty ? Self.label(e) : "\(Self.label(e)) \(status)"
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
        .accessibilityLabel(active ? "Beat \((beat % max(1, beatsPerMeasure)) + 1)" : "Beat indicator")
    }
}
