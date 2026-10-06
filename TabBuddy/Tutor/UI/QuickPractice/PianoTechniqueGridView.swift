//
//  PianoTechniqueGridView.swift
//  TabBuddy
//
//  Exam-chart style technique grid for piano Practice: exercises down the
//  left (pinned while the keys scroll sideways), keys across the top with
//  majors, a divider, then minors. Each cell shows its status for the chosen
//  hands and opens that drill. Rows the caller has not unlocked are dimmed
//  and not tappable.
//

import SwiftUI

struct PianoTechniqueGridView: View {
    @ObservedObject var memory: PracticeMemory
    var keys: [PianoTechniqueKey] = PianoTechniqueKey.order
    var unlockedRows: Set<PianoTechniqueRow> = Set(PianoTechniqueRow.allCases)
    var onSelect: (PianoTechniqueSpec) -> Void

    @State private var hands: PianoHands = .right
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var compact: Bool { sizeClass == .compact }
    private var cellSize: CGFloat { compact ? 52 : 56 }
    private let spacing: CGFloat = 6
    private var headerHeight: CGFloat { 28 }
    private var rowHeaderWidth: CGFloat { compact ? 132 : 196 }

    private var majors: [PianoTechniqueKey] { keys.filter(\.isMajor) }
    private var minors: [PianoTechniqueKey] { keys.filter { !$0.isMajor } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Hands", selection: $hands) {
                ForEach(PianoHands.allCases) { h in
                    Text(h.shortTitle).tag(h)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .accessibilityLabel("Hands")

            legend

            HStack(alignment: .top, spacing: 0) {
                rowHeaders
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: spacing) {
                        keyHeaderRow
                        ForEach(PianoTechniqueRow.allCases) { row in
                            cellRow(row)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    // MARK: Legend

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { legendItems }
            VStack(alignment: .leading, spacing: 4) { legendItems }
        }
        .font(.caption)
        .foregroundStyle(DS.fg2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var legendItems: some View {
        Label { Text("Not started") } icon: { StatusGlyph(status: .new, size: 14) }
        Label { Text("Practicing (best tempo)") } icon: { StatusGlyph(status: .practicing(bestBPM: nil), size: 14) }
        Label { Text("At goal tempo") } icon: { StatusGlyph(status: .atGoal, size: 14) }
    }

    // MARK: Row headers

    private var rowHeaders: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Color.clear.frame(width: rowHeaderWidth - 8, height: headerHeight)
            ForEach(PianoTechniqueRow.allCases) { row in
                let locked = !unlockedRows.contains(row)
                VStack(alignment: .leading, spacing: 2) {
                    Text(compact ? row.shortTitle : row.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.fg1)
                    Text(row.detail)
                        .font(.caption2)
                        .foregroundStyle(DS.fg3)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: rowHeaderWidth - 8, height: cellSize, alignment: .leading)
                .opacity(locked ? 0.4 : 1)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.trailing, 8)
        .background(DS.paper)
        .overlay(alignment: .trailing) { DS.separator.frame(width: 1) }
    }

    // MARK: Columns

    private var keyHeaderRow: some View {
        HStack(spacing: spacing) {
            ForEach(majors) { key in keyHeader(key) }
            if !majors.isEmpty, !minors.isEmpty { divider }
            ForEach(minors) { key in keyHeader(key) }
        }
        .frame(height: headerHeight)
    }

    private func keyHeader(_ key: PianoTechniqueKey) -> some View {
        Text(key.shortTitle)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(key.isMajor ? DS.fg1 : DS.fg2)
            .frame(width: cellSize)
            .accessibilityLabel(key.title)
            .accessibilityAddTraits(.isHeader)
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.separatorStrong)
            .frame(width: 1)
            .padding(.horizontal, 4)
    }

    private func cellRow(_ row: PianoTechniqueRow) -> some View {
        HStack(spacing: spacing) {
            ForEach(majors) { key in cell(key: key, row: row) }
            if !majors.isEmpty, !minors.isEmpty { divider.frame(height: cellSize) }
            ForEach(minors) { key in cell(key: key, row: row) }
        }
    }

    private func cell(key: PianoTechniqueKey, row: PianoTechniqueRow) -> some View {
        let spec = PianoTechniqueSpec(key: key, row: row, hands: hands)
        let status = spec.status(in: memory)
        let locked = !unlockedRows.contains(row)
        return Button {
            onSelect(spec)
        } label: {
            TechniqueCell(status: status, size: cellSize)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.35 : 1)
        .accessibilityLabel("\(key.title), \(row.title.lowercased()), \(status.spokenTitle)")
        .accessibilityHint(locked ? "Read the chapter first" : "Opens the drill, \(hands.title.lowercased())")
    }
}

// MARK: - Cell

private struct TechniqueCell: View {
    var status: PianoTechniqueStatus
    var size: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            StatusGlyph(status: status, size: 20)
            if case .practicing(let best?) = status {
                Text("\(Int(best.rounded()))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(DS.fg2)
            }
        }
        .frame(width: size, height: size)
        .background(status == .atGoal ? DS.accentSofter : DS.surface,
                    in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous).stroke(DS.separator, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

private struct StatusGlyph: View {
    var status: PianoTechniqueStatus
    var size: CGFloat

    var body: some View {
        Group {
            switch status {
            case .new:
                Circle().strokeBorder(DS.fg3, lineWidth: max(1.5, size / 10))
            case .practicing:
                Image(systemName: "circle.lefthalf.filled")
                    .resizable()
                    .foregroundStyle(DS.accent)
            case .atGoal:
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .foregroundStyle(DS.accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("Piano technique grid") {
    let memory = PracticeMemory(defaults: UserDefaults(suiteName: "preview")!)
    let g = PianoTechniqueKey(.G, .major)
    memory.notePracticed(PianoTechniqueSpec(key: g, row: .scaleOneOctave, hands: .right).launch, title: "G", bpm: 72)
    memory.notePracticed(PianoTechniqueSpec(key: PianoTechniqueKey(.C, .major), row: .fiveFinger, hands: .right).launch,
                         title: "C", bpm: 52)
    return ScrollView {
        PianoTechniqueGridView(memory: memory,
                               unlockedRows: [.fiveFinger, .scaleOneOctave, .brokenTriad],
                               onSelect: { _ in })
            .padding()
    }
    .background(DS.paper)
}
