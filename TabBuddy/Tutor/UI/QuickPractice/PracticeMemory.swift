//
//  PracticeMemory.swift
//  TabBuddy
//
//  Device-local memory for the Practice section: each item's last tempo and
//  tempo goal, how often it was practiced, a short recents list, and One
//  Minute Changes counts per chord pair. Stored as JSON in UserDefaults (small,
//  never synced). Items are identified by `PracticeLaunch.key`.
//

import Foundation

/// Everything needed to reopen one practice item with its settings filled in.
struct PracticeLaunch: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case scale, chord, changes, technique
    }

    var instrument: TutorInstrument
    var kind: Kind
    /// Root or key, spelled ("G", "Bb", "F#").
    var root: String
    /// `ScaleType.rawValue` for scales, `ChordQuality.rawValue` for chords.
    var type: String? = nil
    /// Guitar scale position 1...5 (nil = full neck / course default).
    var position: Int? = nil
    var octaves: Int = 1
    /// Chord symbols for a changes drill, in order (2...4).
    var chords: [String] = []
    /// `PianoTechniqueRow.rawValue` for a technique cell.
    var technique: String? = nil
    /// Piano hands for technique: "rh", "lh", "together".
    var hands: String? = nil

    /// Stable identity for tempo memory and recents (settings that change the
    /// music are part of it; display options such as labels are not).
    var key: String {
        var parts: [String] = [instrument.rawValue, kind.rawValue, root]
        parts.append(type ?? "")
        parts.append(position.map { String($0) } ?? "")
        parts.append(String(octaves))
        parts.append(chords.joined(separator: ","))
        parts.append(technique ?? "")
        parts.append(hands ?? "")
        return parts.joined(separator: "|")
    }

    var id: String { key }
}

struct PracticeRecent: Codable, Hashable, Identifiable {
    var launch: PracticeLaunch
    var title: String
    var lastPracticed: Date
    var id: String { launch.key }
}

struct ChangesEntry: Codable, Hashable {
    var date: Date
    /// Clean changes in the run.
    var count: Int
    var durationSec: Double
    var perMinute: Double { durationSec > 0 ? Double(count) * 60 / durationSec : 0 }
}

struct PracticeItemStats: Codable, Hashable {
    var lastBPM: Double?
    var goalBPM: Double?
    var bestBPM: Double?
    var sessions: Int = 0
    var lastPracticed: Date?
}

@MainActor
final class PracticeMemory: ObservableObject {
    static let shared = PracticeMemory()

    private struct Stored: Codable {
        var items: [String: PracticeItemStats] = [:]
        var recents: [PracticeRecent] = []
        var changes: [String: [ChangesEntry]] = [:]
        /// Chapter routine completions: lesson ID → "yyyy-MM-dd" days (one per day).
        var routineDays: [String: [String]]? = nil
    }

    static let storageKey = "tutor.practiceMemory.v1"
    static let maxRecents = 8
    static let maxChangesPerPair = 60

    private let defaults: UserDefaults
    @Published private var stored: Stored

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.storageKey) }
    }

    // MARK: Items

    func stats(for launch: PracticeLaunch) -> PracticeItemStats {
        stored.items[launch.key] ?? PracticeItemStats()
    }

    /// The tempo to open an item at: its last tempo, else `fallback`.
    func tempo(for launch: PracticeLaunch, fallback: Double) -> Double {
        stored.items[launch.key]?.lastBPM ?? fallback
    }

    func setTempo(_ bpm: Double, for launch: PracticeLaunch) {
        var s = stats(for: launch)
        s.lastBPM = bpm
        stored.items[launch.key] = s
        save()
    }

    func setGoal(_ bpm: Double?, for launch: PracticeLaunch) {
        var s = stats(for: launch)
        s.goalBPM = bpm
        stored.items[launch.key] = s
        save()
    }

    /// Records that an item was practiced (played, listened to, or looped) at `bpm`.
    func notePracticed(_ launch: PracticeLaunch, title: String, bpm: Double?, at date: Date = .now) {
        var s = stats(for: launch)
        s.sessions += 1
        s.lastPracticed = date
        if let bpm {
            s.lastBPM = bpm
            s.bestBPM = max(s.bestBPM ?? 0, bpm)
        }
        stored.items[launch.key] = s
        stored.recents.removeAll { $0.launch.key == launch.key }
        stored.recents.insert(PracticeRecent(launch: launch, title: title, lastPracticed: date), at: 0)
        if stored.recents.count > Self.maxRecents * 2 { stored.recents.removeLast(stored.recents.count - Self.maxRecents * 2) }
        save()
    }

    func recents(for instrument: TutorInstrument) -> [PracticeRecent] {
        Array(stored.recents.filter { $0.launch.instrument == instrument }.prefix(Self.maxRecents))
    }

    // MARK: One Minute Changes

    /// Order-independent identity for a set of chords ("C|G" == "G|C").
    static func changesKey(instrument: TutorInstrument, chords: [String]) -> String {
        instrument.rawValue + ":" + chords.sorted().joined(separator: "|")
    }

    func recordChanges(instrument: TutorInstrument, chords: [String], count: Int, durationSec: Double, at date: Date = .now) {
        let key = Self.changesKey(instrument: instrument, chords: chords)
        var list = stored.changes[key] ?? []
        list.append(ChangesEntry(date: date, count: count, durationSec: durationSec))
        if list.count > Self.maxChangesPerPair { list.removeFirst(list.count - Self.maxChangesPerPair) }
        stored.changes[key] = list
        save()
    }

    func changesHistory(instrument: TutorInstrument, chords: [String]) -> [ChangesEntry] {
        stored.changes[Self.changesKey(instrument: instrument, chords: chords)] ?? []
    }

    // MARK: Chapter routines

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Records a finished chapter routine (at most once per day).
    func recordRoutine(lessonID: String, at date: Date = .now) {
        let day = Self.dayFormatter.string(from: date)
        var all = stored.routineDays ?? [:]
        var days = all[lessonID] ?? []
        guard !days.contains(day) else { return }
        days.append(day)
        all[lessonID] = days
        stored.routineDays = all
        save()
    }

    /// Days the chapter's routine was finished.
    func routineDayCount(lessonID: String) -> Int { stored.routineDays?[lessonID]?.count ?? 0 }

    func didRoutineToday(lessonID: String, now: Date = .now) -> Bool {
        stored.routineDays?[lessonID]?.contains(Self.dayFormatter.string(from: now)) ?? false
    }

    /// Clears everything (Tutor settings reset).
    func reset() {
        stored = Stored()
        defaults.removeObject(forKey: Self.storageKey)
    }
}
