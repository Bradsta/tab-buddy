//
//  ViewerHeader.swift
//  TabBuddy
//
//  The one header (DESIGN.md §4) shared by every viewer surface and the
//  Tab Maker: 52pt translucent bar, [back | title cluster | view switch].
//  The title cluster is a single tappable menu holding rename / tags /
//  favorite / file details — there is no ellipsis menu anymore.
//

import SwiftUI

/// Two-state view switch (extensible to three for the future diff view).
struct ViewSwitchSegment: Identifiable {
    var id: Int
    var icon: String
    var label: String
}

struct ViewerHeader: View {
    @Environment(\.horizontalSizeClass) private var hSize

    // Center cluster
    let title: String
    var subtitle: String = ""
    /// Maker: editable title (dashed-underline affordance) instead of the menu.
    var editableTitle: Binding<String>? = nil
    /// nil = no badge (no canonical yet / not a viewer surface).
    var confidence: Double? = nil

    // Title menu
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onEditTags: (() -> Void)? = nil
    /// Short detail rows for the menu footer (source, converter, confidence).
    var detailRows: [String] = []

    // Trailing view switch (nil = hidden, e.g. no canonical yet)
    var switchSegments: [ViewSwitchSegment] = []
    var switchSelection: Binding<Int>? = nil

    // Leading
    var backLabel: String = "Library"
    var onBack: () -> Void = {}

    /// Canonical display threshold: at/above shows the accent badge,
    /// below shows the caution badge (and gates the PDF fallback notice).
    static let confidenceThreshold: Double = 0.8

    private var isCompact: Bool { hSize == .compact }

    var body: some View {
        HStack(spacing: 8) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            titleCluster
                .layoutPriority(1)
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: DS.headerHeight)
        .background(BarMaterial())
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: Leading — back

    private var leading: some View {
        Button(action: onBack) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                if !isCompact {
                    Text(backLabel)
                }
            }
            .foregroundStyle(DS.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Center — title cluster (one hit target)

    @ViewBuilder
    private var titleCluster: some View {
        if let editableTitle {
            VStack(spacing: 1) {
                TextField("Title", text: editableTitle)
                    .font(.headline)
                    .foregroundStyle(DS.fg1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(DS.fg3)
                            .frame(height: 1)
                            .mask(
                                HStack(spacing: 3) {
                                    ForEach(0..<24, id: \.self) { _ in
                                        Rectangle().frame(width: 4)
                                    }
                                }
                            )
                            .offset(y: 3)
                    }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.fg2)
                        .lineLimit(1)
                }
            }
        } else {
            titleMenuCluster
        }
    }

    private var titleMenuCluster: some View {
        Menu {
            if let onRename { Button("Rename…", action: onRename) }
            if let onEditTags { Button("Edit tags…", action: onEditTags) }
            if let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Label(isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: isFavorite ? "star.slash" : "star")
                }
            }
            if !detailRows.isEmpty {
                Divider()
                ForEach(detailRows, id: \.self) { row in
                    Button(row) {}.disabled(true)
                }
            }
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(DS.fg1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.fg3)
                    if !isCompact, let confidence {
                        confidenceBadge(confidence)
                    }
                }
                if !subtitle.isEmpty || (isCompact && confidence != nil) {
                    HStack(spacing: 5) {
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(DS.fg2)
                                .lineLimit(1)
                        }
                        if isCompact, let confidence {
                            confidenceBadge(confidence)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func confidenceBadge(_ value: Double) -> some View {
        let good = value >= Self.confidenceThreshold
        return HStack(spacing: 3) {
            Circle()
                .fill(good ? DS.accentStrong : DS.cautionText)
                .frame(width: 5, height: 5)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(good ? DS.accentSofter : DS.cautionSoft, in: Capsule())
        .foregroundStyle(good ? DS.accentStrong : DS.cautionText)
    }

    // MARK: Trailing — favorite (iPad) + view switch

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 10) {
            if !isCompact, let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? DS.accent : DS.fg3)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")
            }
            if let switchSelection, !switchSegments.isEmpty {
                viewSwitch(selection: switchSelection)
            }
        }
    }

    private func viewSwitch(selection: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            ForEach(switchSegments) { seg in
                let active = selection.wrappedValue == seg.id
                Button {
                    withAnimation(DS.motionFast) { selection.wrappedValue = seg.id }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: seg.icon)
                            .font(.system(size: 12, weight: .medium))
                        if !isCompact {
                            Text(seg.label)
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .padding(.horizontal, isCompact ? 0 : 10)
                    .frame(minWidth: isCompact ? 38 : 0, minHeight: 30)
                    .background(
                        active
                            ? AnyShapeStyle(DS.surfaceRaised)
                            : AnyShapeStyle(Color.clear),
                        in: Capsule()
                    )
                    .shadow(color: active ? .black.opacity(0.10) : .clear, radius: 2, y: 1)
                    .foregroundStyle(active ? DS.fg1 : DS.fg2)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(seg.label)
            }
        }
        .padding(2)
        .background(DS.surfaceInset, in: Capsule())
    }
}
