//
//  TutorGamesView.swift
//  TabBuddy
//
//  Games shelf driven by `TutorGameRegistry`. Games without a destination in
//  `TutorGames` show as "Coming soon".
//

import SwiftUI

struct TutorGamesView: View {
    @EnvironmentObject private var state: TutorShellState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var activeGame: TutorGameEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if sizeClass != .compact {
                    Text("Games").font(.largeTitle.weight(.bold))
                }
                Text("Short drills for the skills in your lessons. They are extra practice and never required.")
                    .font(sizeClass == .compact ? .body : .title3)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    ForEach(TutorGameRegistry.entries(for: state.instrument)) { entry in
                        card(entry)
                    }
                }
            }
            .padding(sizeClass == .compact ? 16 : 32)
            .tutorReadableWidth(1000)
        }
        .background(DS.paper)
        .fullScreenCover(item: $activeGame) { entry in
            NavigationStack {
                (TutorGameRegistry.destination(for: entry, instrument: state.instrument) ?? AnyView(EmptyView()))
                    .navigationTitle(entry.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { activeGame = nil } }
                    }
            }
        }
    }

    private func card(_ entry: TutorGameEntry) -> some View {
        let available = TutorGameRegistry.isAvailable(entry, instrument: state.instrument)
        return TutorShellCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: entry.systemImage)
                        .font(.title2)
                        .foregroundStyle(available ? DS.accent : DS.fg3)
                        .frame(width: 44, height: 44)
                        .background(available ? DS.accentSofter : DS.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                    Spacer()
                    if !available {
                        TutorShellChip(text: "Coming soon", fill: DS.surfaceInset, foreground: DS.fg2)
                    }
                }
                Text(entry.title).font(.headline).foregroundStyle(DS.fg1)
                Text(entry.summary)
                    .font(.subheadline)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label(entry.usesMicrophone ? "Listens" : "Tap to answer",
                          systemImage: entry.usesMicrophone ? "mic" : "hand.tap")
                    Spacer()
                    if available {
                        Button("Play") { activeGame = entry }
                            .buttonStyle(.borderedProminent)
                            // The row's tertiary text style would otherwise tint the label.
                            .foregroundStyle(.white)
                    }
                }
                .font(.caption)
                .foregroundStyle(DS.fg3)
            }
            .frame(minHeight: 150, alignment: .top)
        }
        .opacity(available ? 1 : 0.85)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(available ? entry.title : "\(entry.title), coming soon")
    }
}
