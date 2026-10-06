//
//  PracticeSuggestions.swift
//  TabBuddy
//
//  Turns course content into ready-to-play Practice items: a lesson's Try it
//  step becomes a `PracticeLaunch` ("Practice this"), the next chapter's items
//  feed the "For you" row, and the chapters read so far decide which scale
//  types and chord qualities the pickers show first (the rest sit under More).
//

import SwiftUI

struct PracticeForYouItem: Identifiable, Hashable {
    enum Source: Hashable { case chapter(String), recent }
    var title: String
    var detail: String
    var launch: PracticeLaunch
    var source: Source
    var id: String { launch.key }
}

enum PracticeSuggestions {
    /// The Practice item a lesson exercise maps to, if Practice can host it.
    static func launch(from spec: ExerciseSpec, instrument: TutorInstrument) -> PracticeLaunch? {
        switch spec.kind {
        case .scale:
            guard let text = spec.scale, let scale = Scale(text) else { return nil }
            return PracticeLaunch(instrument: instrument, kind: .scale, root: scale.root.name, type: scale.type.rawValue,
                                  octaves: max(1, spec.octaves ?? 1))
        case .playChord:
            let chords = (spec.chords ?? []).compactMap { Chord($0) }
            guard let first = chords.first else { return nil }
            if chords.count >= 2 {
                return PracticeLaunch(instrument: instrument, kind: .changes, root: first.root.name,
                                      chords: Array(chords.prefix(4)).map(\.symbol))
            }
            return PracticeLaunch(instrument: instrument, kind: .chord, root: first.root.name, type: first.quality.rawValue)
        case .chordChanges:
            let chords = (spec.chords ?? []).compactMap { Chord($0) }
            guard chords.count >= 2, let first = chords.first else { return nil }
            return PracticeLaunch(instrument: instrument, kind: .changes, root: first.root.name,
                                  chords: Array(chords.prefix(4)).map(\.symbol))
        default:
            return nil
        }
    }

    /// The Practice item for a generated exercise (used by a chapter's Try it box).
    static func launch(from exercise: GeneratedExercise, instrument: TutorInstrument) -> PracticeLaunch? {
        switch exercise.kind {
        case .scale:
            guard let scale = exercise.scale else { return nil }
            return PracticeLaunch(instrument: instrument, kind: .scale, root: scale.root.name, type: scale.type.rawValue)
        case .playChord, .chordChanges:
            var names: [String] = []
            for event in exercise.passage.events {
                if let name = event.chordName, !names.contains(name) { names.append(name) }
            }
            let chords = names.compactMap { Chord($0) }
            guard let first = chords.first else { return nil }
            if chords.count >= 2 {
                return PracticeLaunch(instrument: instrument, kind: .changes, root: first.root.name,
                                      chords: Array(chords.prefix(4)).map(\.symbol))
            }
            return PracticeLaunch(instrument: instrument, kind: .chord, root: first.root.name, type: first.quality.rawValue)
        default:
            return nil
        }
    }

    /// Practice items from a chapter, in page order, without duplicates.
    static func launches(in lesson: Lesson, instrument: TutorInstrument) -> [(title: String, launch: PracticeLaunch)] {
        var seen = Set<String>()
        var result: [(String, PracticeLaunch)] = []
        for section in LessonPageModel.sections(for: lesson) {
            guard case .practice(let p) = section.step, let launch = launch(from: p.exercise, instrument: instrument),
                  seen.insert(launch.key).inserted else { continue }
            result.append((title(for: launch), launch))
        }
        return result
    }

    /// "For you": the next chapter's practice items, then recent items.
    static func suggestions(nextLesson: Lesson?, chapterLabel: String?, recents: [PracticeRecent],
                            instrument: TutorInstrument, limit: Int = 6) -> [PracticeForYouItem] {
        var result: [PracticeForYouItem] = []
        if let nextLesson {
            for item in launches(in: nextLesson, instrument: instrument).prefix(3) {
                result.append(PracticeForYouItem(title: item.title, detail: chapterLabel ?? nextLesson.title,
                                                 launch: item.launch, source: .chapter(nextLesson.id)))
            }
        }
        for recent in recents where !result.contains(where: { $0.launch.key == recent.launch.key }) {
            result.append(PracticeForYouItem(title: recent.title, detail: "Recent", launch: recent.launch, source: .recent))
        }
        return Array(result.prefix(limit))
    }

    /// Scale types used by chapters up to and including `lesson` (major always).
    static func introducedScaleTypes(course: Course, through lessonID: String?) -> Set<ScaleType> {
        var types: Set<ScaleType> = [.major]
        for location in course.allLessonLocations {
            for section in LessonPageModel.sections(for: location.lesson) {
                if case .practice(let p) = section.step, let text = p.exercise.scale ?? p.exercise.key, let scale = Scale(text) {
                    types.insert(scale.type)
                }
            }
            if location.lesson.id == lessonID { break }
        }
        return types
    }

    /// Short title for a launch: "G major", "Am", "C ↔ G".
    static func title(for launch: PracticeLaunch) -> String {
        switch launch.kind {
        case .scale:
            let type = launch.type.flatMap(ScaleType.init(rawValue:))
            let root = SpelledNote(launch.root)?.displayName ?? launch.root
            var text = "\(root) \(type?.name ?? "scale")"
            if let position = launch.position { text += " · position \(position)" }
            return text
        case .chord:
            let quality = launch.type.flatMap(ChordQuality.init(rawValue:)) ?? .major
            return SpelledNote(launch.root).map { Chord(root: $0, quality: quality).displaySymbol } ?? launch.root
        case .changes:
            let names = launch.chords.compactMap { Chord($0)?.displaySymbol }
            return names.count == 2 ? names.joined(separator: " ↔ ") : names.joined(separator: " → ")
        case .technique:
            return PianoTechniqueSpec(launch: launch)?.title ?? "Technique"
        }
    }
}

// MARK: - Opening Practice from a chapter

private struct TutorOpenPracticeKey: EnvironmentKey {
    static let defaultValue: ((PracticeLaunch) -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by the Tutor shell around a chapter: opens Practice with an item filled in.
    var tutorOpenPractice: ((PracticeLaunch) -> Void)? {
        get { self[TutorOpenPracticeKey.self] }
        set { self[TutorOpenPracticeKey.self] = newValue }
    }
}
