//
//  LibrarySongSuggester.swift
//  TabBuddy
//
//  Suggests library songs whose chords the learner already knows. Chords are
//  compared by root pitch class and quality, so "A#m" matches "Bbm" and a
//  slash chord ("C/G") counts as its main chord. The caller supplies the song
//  list (title + chord names), keeping this independent of `FileItem`.
//

import Foundation

struct LibrarySongSuggestion: Hashable, Sendable {
    /// Index into the caller's song list.
    var index: Int
    var title: String
    /// Distinct chord symbols in the song, in first-appearance order.
    var chords: [String]
    /// Chords not yet learned (empty for a full match).
    var missing: [String]
}

enum LibrarySongSuggester {
    /// Enharmonic-insensitive identity of a chord (slash bass ignored).
    struct ChordKey: Hashable, Sendable {
        var root: PitchClass
        var quality: ChordQuality

        init(_ chord: Chord) {
            root = chord.root.pitchClass
            quality = chord.quality
        }

        init?(_ symbol: String) {
            guard let chord = Chord(symbol) else { return nil }
            self.init(chord)
        }
    }

    /// Chords from chord exercises (playChord, chordChanges, strumRhythm) in completed lessons.
    static func learnedChords(in course: Course, completedLessonIDs: Set<String>) -> Set<ChordKey> {
        var keys = Set<ChordKey>()
        for location in course.allLessonLocations where completedLessonIDs.contains(location.lesson.id) {
            for step in location.lesson.steps {
                guard case .practice(let practice) = step,
                      [.playChord, .chordChanges, .strumRhythm].contains(practice.exercise.kind) else { continue }
                keys.formUnion((practice.exercise.chords ?? []).compactMap(ChordKey.init))
            }
        }
        return keys
    }

    /// Songs whose chords are all known, or at most `maxMissing` unknown.
    /// Songs with no recognizable chords are skipped; unrecognized symbols count as missing.
    /// Sorted by fewest missing, then most distinct chords, then title.
    static func suggest(songs: [(title: String, chords: [String])], known: Set<ChordKey>,
                        maxMissing: Int = 0) -> [LibrarySongSuggestion] {
        var result: [LibrarySongSuggestion] = []
        for (index, song) in songs.enumerated() {
            var seen = Set<String>()
            let distinct = song.chords.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            guard distinct.contains(where: { ChordKey($0) != nil }) else { continue }
            var missingKeys = Set<ChordKey>()
            var missing: [String] = []
            for symbol in distinct {
                if let key = ChordKey(symbol) {
                    if !known.contains(key), missingKeys.insert(key).inserted { missing.append(symbol) }
                } else {
                    missing.append(symbol)
                }
            }
            guard missing.count <= maxMissing else { continue }
            result.append(LibrarySongSuggestion(index: index, title: song.title, chords: distinct, missing: missing))
        }
        return result.sorted {
            ($0.missing.count, -$0.chords.count, $0.title.lowercased()) < ($1.missing.count, -$1.chords.count, $1.title.lowercased())
        }
    }

    /// Convenience: learned chords from progress, then suggestions.
    static func suggest(songs: [(title: String, chords: [String])], course: Course, progress: PathProgress,
                        maxMissing: Int = 0) -> [LibrarySongSuggestion] {
        suggest(songs: songs, known: learnedChords(in: course, completedLessonIDs: progress.completedLessonIDs),
                maxMissing: maxMissing)
    }
}
