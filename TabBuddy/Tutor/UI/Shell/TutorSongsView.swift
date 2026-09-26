//
//  TutorSongsView.swift
//  TabBuddy
//
//  "Songs you know": library scores whose chord symbols match chords the
//  learner practiced in completed lessons. Tapping a song opens it in the
//  existing viewer.
//

import SwiftData
import SwiftUI

@MainActor
final class TutorSongsLoader: ObservableObject {
    @Published private(set) var songs: [TutorLibrarySong] = []
    @Published private(set) var isLoading = false
    @Published private(set) var scannedCount = 0
    private var loaded = false

    func loadIfNeeded(context: ModelContext) {
        guard !loaded, !isLoading else { return }
        isLoading = true
        let refs = TutorLibraryChordIndex.canonicalRefs(in: context)
        let textTabs = TutorLibraryChordIndex.unconvertedTextTabs(in: context)
        scannedCount = refs.count + textTabs.count
        Task {
            var result = await TutorLibraryChordIndex.songs(for: refs)
            let known = Set(result.map(\.fileID))
            result += await TutorLibraryChordIndex.textTabSongs(for: textTabs).filter { !known.contains($0.fileID) }
            songs = result
            isLoading = false
            loaded = true
        }
    }
}

struct TutorSongsCard: View {
    @ObservedObject var loader: TutorSongsLoader
    let course: Course
    let progress: PathProgress
    var onOpen: () -> Void

    var body: some View {
        let rows = TutorSongSuggestionAdapter.rows(songs: loader.songs, course: course, progress: progress)
        TutorShellCard(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Songs you know", systemImage: "music.note.list")
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(DS.fg1)
                Text(message(ready: rows.ready.count, almost: rows.almost.count))
                    .font(.subheadline)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !rows.ready.isEmpty || !rows.almost.isEmpty {
                    Button("See songs", action: onOpen)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func message(ready: Int, almost: Int) -> String {
        if loader.isLoading { return "Checking your library for chord symbols…" }
        if TutorSongSuggestionAdapter.learnedChordSymbols(course: course, progress: progress).isEmpty {
            return "After your first chord lessons, songs from your library that use those chords show up here."
        }
        if ready == 0 && almost == 0 { return "No library songs use only the chords you know yet." }
        if ready == 0 { return "\(almost) \(almost == 1 ? "song needs" : "songs need") just one more chord." }
        return "\(ready) \(ready == 1 ? "song uses" : "songs use") only chords you have practiced."
    }
}

struct TutorSongsView: View {
    @ObservedObject var loader: TutorSongsLoader
    var onOpenSong: ((FileItem) -> Void)?
    @EnvironmentObject private var state: TutorShellState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if sizeClass != .compact {
                    Text("Songs you know").font(.largeTitle.weight(.bold))
                }
                content
                Text("Checked \(loader.scannedCount) scores: converted scores and text tabs on this device that have chord symbols. Guitar Pro files and PDFs that haven't been converted aren't checked. Chords are matched by root and quality, so A♯m and B♭m count as the same chord.")
                    .font(.footnote)
                    .foregroundStyle(DS.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(sizeClass == .compact ? 16 : 32)
            .tutorReadableWidth(820)
        }
        .background(DS.paper)
        .onAppear { loader.loadIfNeeded(context: modelContext) }
    }

    @ViewBuilder
    private var content: some View {
        if let course = state.course, let progress = state.progress {
            let learned = TutorSongSuggestionAdapter.learnedChordSymbols(course: course, progress: progress)
            let rows = TutorSongSuggestionAdapter.rows(songs: loader.songs, course: course, progress: progress)
            if learned.isEmpty {
                TutorShellCard {
                    Text("Finish a lesson with chord practice and songs from your library that use those chords appear here.")
                        .foregroundStyle(DS.fg2)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chords you have practiced").font(.headline)
                    chordLine(learned, missing: [])
                }
                if loader.isLoading {
                    ProgressView("Checking your library…")
                } else if rows.ready.isEmpty && rows.almost.isEmpty {
                    TutorShellCard {
                        Text("No library scores with chord symbols use only these chords yet. Keep going: every new chord opens more songs.")
                            .foregroundStyle(DS.fg2)
                    }
                } else {
                    songList("Ready to play", rows.ready)
                    songList("One chord away", rows.almost)
                }
            }
        }
    }

    @ViewBuilder
    private func songList(_ title: String, _ rows: [TutorSongRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button { open(row) } label: {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(DS.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title).font(.body.weight(.medium)).foregroundStyle(DS.fg1)
                                        .multilineTextAlignment(.leading)
                                    chordLine(row.chords, missing: Set(row.missing))
                                }
                                Spacer()
                                if onOpenSong != nil {
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(DS.fg3)
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .disabled(onOpenSong == nil)
                        if row.id != rows.last?.id { DS.separator.frame(height: 1).padding(.leading, 50) }
                    }
                }
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator, lineWidth: 1))
            }
        }
    }

    private func chordLine(_ chords: [String], missing: Set<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chords, id: \.self) { chord in
                    let isMissing = missing.contains(chord)
                    TutorShellChip(text: chord, systemImage: isMissing ? "plus" : nil,
                              fill: isMissing ? DS.cautionSoft : DS.accentSofter,
                              foreground: isMissing ? DS.cautionText : DS.accentStrong)
                }
            }
        }
    }

    private func open(_ row: TutorSongRow) {
        guard let onOpenSong else { return }
        let id = row.fileID
        var descriptor = FetchDescriptor<FileItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let file = try? modelContext.fetch(descriptor).first { onOpenSong(file) }
    }
}
