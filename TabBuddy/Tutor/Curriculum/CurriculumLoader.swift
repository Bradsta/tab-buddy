//
//  CurriculumLoader.swift
//  TabBuddy
//
//  Loads bundled tutor content (`tutor-<instrument>-stage-NN.json` and
//  `tutor-glossary.json`) into one `Course` per instrument. The app bundle is
//  flat, so files are found by name prefix. Loading is a pure function that
//  can run off the main thread; `CurriculumLibrary` publishes the result to UI.
//

import Foundation

/// A problem found while loading or validating content.
struct CurriculumIssue: Hashable, Sendable, CustomStringConvertible {
    enum Severity: String, Hashable, Sendable { case error, warning }

    var severity: Severity
    /// Content file name ("tutor-guitar-stage-03.json").
    var file: String
    var lessonID: String? = nil
    /// Index into the lesson's `steps`, when the issue is inside a step.
    var stepIndex: Int? = nil
    /// Field path within the file, lesson, or step ("exercise.notes[2]").
    var path: String = ""
    var message: String

    var description: String {
        var location = file
        if let lessonID { location += " " + lessonID }
        if let stepIndex { location += " step \(stepIndex)" }
        if !path.isEmpty { location += " " + path }
        return "[\(severity.rawValue)] \(location): \(message)"
    }
}

/// Everything loaded from the content files.
struct CurriculumContent: Sendable {
    var courses: [TutorInstrument: Course]
    var glossary: [GlossaryEntry]
    /// Stage id → file name it was read from.
    var stageFiles: [String: String]
    /// Files that failed to decode, or were misnamed.
    var loadIssues: [CurriculumIssue]

    static let empty = CurriculumContent(courses: [:], glossary: [], stageFiles: [:], loadIssues: [])

    func course(_ instrument: TutorInstrument) -> Course? { courses[instrument] }

    /// Case-insensitive glossary lookup; tolerates a trailing plural "s".
    func glossaryEntry(for term: String) -> GlossaryEntry? {
        let key = term.lowercased().trimmingCharacters(in: .whitespaces)
        if let hit = glossaryIndex[key] { return hit }
        if key.hasSuffix("s"), let hit = glossaryIndex[String(key.dropLast())] { return hit }
        if let hit = glossaryIndex[key + "s"] { return hit }
        return nil
    }

    private var glossaryIndex: [String: GlossaryEntry] {
        Dictionary(glossary.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

enum CurriculumLoader {
    static let stagePrefix = "tutor-"
    static let glossaryFileName = "tutor-glossary.json"

    /// Parses "tutor-guitar-stage-03.json" → (.guitar, 3).
    static func stageFileInfo(_ fileName: String) -> (instrument: TutorInstrument, number: Int)? {
        guard fileName.hasPrefix(stagePrefix), fileName.hasSuffix(".json") else { return nil }
        let core = fileName.dropFirst(stagePrefix.count).dropLast(5)
        let parts = core.split(separator: "-")
        guard parts.count == 3, parts[1] == "stage",
              let instrument = TutorInstrument(rawValue: String(parts[0])),
              let number = Int(parts[2]) else { return nil }
        return (instrument, number)
    }

    /// Bundled content files (flat bundle, matched by name prefix).
    static func contentFiles(in bundle: Bundle) -> [URL] {
        (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(stagePrefix) }
    }

    static func contentFiles(inDirectory directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(stagePrefix) && $0.hasSuffix(".json") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    // MARK: Loading

    private static let cacheLock = NSLock()
    private static var bundleCache: CurriculumContent?

    /// Loads the app bundle's content once and caches it. Safe to call from any thread.
    static func loadBundled(_ bundle: Bundle = .main) -> CurriculumContent {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if bundle == .main, let cached = bundleCache { return cached }
        let content = load(files: contentFiles(in: bundle))
        if bundle == .main { bundleCache = content }
        return content
    }

    /// Loads every content file in a directory (tests read the source tree).
    static func load(directory: URL) -> CurriculumContent {
        load(files: contentFiles(inDirectory: directory))
    }

    /// Decodes stage and glossary files. Undecodable files become `loadIssues`.
    static func load(files: [URL]) -> CurriculumContent {
        var stages: [TutorInstrument: [(number: Int, stage: Stage)]] = [:]
        var glossary: [GlossaryEntry] = []
        var stageFiles: [String: String] = [:]
        var issues: [CurriculumIssue] = []
        let decoder = JSONDecoder()

        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            do {
                let data = try Data(contentsOf: url)
                if name == glossaryFileName {
                    glossary = try decoder.decode([GlossaryEntry].self, from: data)
                } else if let info = stageFileInfo(name) {
                    let stage = try decoder.decode(Stage.self, from: data)
                    if stage.instrument != info.instrument {
                        issues.append(CurriculumIssue(severity: .error, file: name, path: "instrument",
                                                      message: "stage instrument \(stage.instrument.rawValue) does not match the file name"))
                    }
                    if stage.order != info.number {
                        issues.append(CurriculumIssue(severity: .warning, file: name, path: "order",
                                                      message: "stage order \(stage.order) differs from file number \(info.number)"))
                    }
                    stages[stage.instrument, default: []].append((info.number, stage))
                    stageFiles[stage.id] = name
                } else if name.hasPrefix(stagePrefix) {
                    issues.append(CurriculumIssue(severity: .warning, file: name,
                                                  message: "unrecognized tutor file name; expected tutor-<instrument>-stage-NN.json"))
                }
            } catch {
                issues.append(CurriculumIssue(severity: .error, file: name,
                                              message: "failed to decode: \(describe(error))"))
            }
        }

        var courses: [TutorInstrument: Course] = [:]
        for (instrument, list) in stages {
            let sorted = list.sorted { ($0.stage.order, $0.number) < ($1.stage.order, $1.number) }.map(\.stage)
            courses[instrument] = Course(instrument: instrument, title: instrument.displayName, stages: sorted)
        }
        return CurriculumContent(courses: courses, glossary: glossary.sorted { $0.term.lowercased() < $1.term.lowercased() },
                                 stageFiles: stageFiles, loadIssues: issues)
    }

    /// Readable decoding error with its coding path.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map { "[\($0)]" } ?? "." + $0.stringValue }.joined()
        }
        switch error {
        case .dataCorrupted(let c): return "\(path(c.codingPath)): \(c.debugDescription)"
        case .keyNotFound(let key, let c): return "\(path(c.codingPath)): missing key \"\(key.stringValue)\""
        case .typeMismatch(_, let c): return "\(path(c.codingPath)): \(c.debugDescription)"
        case .valueNotFound(_, let c): return "\(path(c.codingPath)): \(c.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }
}

// MARK: - Course queries

/// Where a lesson sits in its course.
struct LessonLocation: Hashable, Sendable {
    var lesson: Lesson
    var stage: Stage
    /// Nil for main-path lessons.
    var branch: Branch?

    var isOnMainPath: Bool { branch == nil }
}

extension Course {
    /// Main-path lessons in order, across stages.
    var mainPathLessons: [Lesson] { stages.flatMap(\.lessons) }

    var allBranches: [Branch] { stages.flatMap(\.branches) }

    /// Every lesson with its stage and branch.
    var allLessonLocations: [LessonLocation] {
        stages.flatMap { stage in
            stage.lessons.map { LessonLocation(lesson: $0, stage: stage, branch: nil) }
                + stage.branches.flatMap { b in b.lessons.map { LessonLocation(lesson: $0, stage: stage, branch: b) } }
        }
    }

    func location(ofLesson id: String) -> LessonLocation? {
        allLessonLocations.first { $0.lesson.id == id }
    }

    func lesson(id: String) -> Lesson? { location(ofLesson: id)?.lesson }

    /// Review item seed by id, for card playback/diagram lookup.
    func reviewItem(id: String) -> ReviewItemSeed? {
        for location in allLessonLocations {
            if let item = location.lesson.reviewItems.first(where: { $0.id == id }) { return item }
        }
        return nil
    }
}

// MARK: - Library (UI)

/// Main-actor holder of loaded content for SwiftUI views.
@MainActor
final class CurriculumLibrary: ObservableObject {
    static let shared = CurriculumLibrary()

    @Published private(set) var content: CurriculumContent?
    @Published private(set) var isLoading = false

    private let loader: @Sendable () -> CurriculumContent

    /// Defaults to the app bundle.
    init(loader: @escaping @Sendable () -> CurriculumContent = { CurriculumLoader.loadBundled() }) {
        self.loader = loader
    }

    /// Wraps already-loaded content (previews, tests).
    init(content: CurriculumContent) {
        self.loader = { content }
        self.content = content
    }

    var isLoaded: Bool { content != nil }

    /// Loads off the main thread the first time; later calls return immediately.
    func loadIfNeeded() async {
        guard content == nil, !isLoading else { return }
        isLoading = true
        let loader = self.loader
        let loaded = await Task.detached(priority: .userInitiated) { loader() }.value
        content = loaded
        isLoading = false
    }

    func course(for instrument: TutorInstrument) -> Course? { content?.courses[instrument] }

    var glossary: [GlossaryEntry] { content?.glossary ?? [] }

    func glossaryEntry(for term: String) -> GlossaryEntry? { content?.glossaryEntry(for: term) }

    func location(ofLesson id: String, instrument: TutorInstrument) -> LessonLocation? {
        course(for: instrument)?.location(ofLesson: id)
    }

    func reviewItem(id: String, instrument: TutorInstrument) -> ReviewItemSeed? {
        course(for: instrument)?.reviewItem(id: id)
    }
}
