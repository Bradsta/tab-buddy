//
//  LessonUISnapshotTests.swift
//  TabBuddyTests
//
//  Renders lesson screens into PNGs for visual review at iPad portrait,
//  iPad landscape, Split View, and iPhone widths. Skipped unless the
//  TUTOR_SNAPSHOT_DIR environment variable names an output folder (pass it as
//  TEST_RUNNER_TUTOR_SNAPSHOT_DIR to xcodebuild). Not an assertion suite.
//

import SwiftUI
import XCTest
@testable import TabBuddy

@MainActor
final class LessonUISnapshotTests: XCTestCase {

    private var outputDirectory: URL?

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["TUTOR_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TUTOR_SNAPSHOT_DIR to render lesson snapshots.")
        }
        outputDirectory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: outputDirectory!, withIntermediateDirectories: true)
        await CurriculumLibrary.shared.loadIfNeeded()
    }

    enum Size {
        case portrait, landscape, split, phone
        var size: CGSize {
            switch self {
            case .portrait: return CGSize(width: 834, height: 1210)
            case .landscape: return CGSize(width: 1210, height: 834)
            case .split: return CGSize(width: 507, height: 834)
            case .phone: return CGSize(width: 390, height: 844)
            }
        }
        var sizeClass: UserInterfaceSizeClass { self == .portrait || self == .landscape ? .regular : .compact }
        var name: String { "\(self)" }
    }

    private func render<V: View>(_ view: V, size: Size, name: String, height: CGFloat? = nil,
                                 settle: UInt64 = 1_200_000_000) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let frame = CGSize(width: size.size.width, height: height ?? size.size.height)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: frame)
        let host = UIHostingController(rootView: view
            .environment(\.horizontalSizeClass, size.sizeClass)
            .frame(width: frame.width, height: frame.height))
        window.rootViewController = host
        window.isHidden = false
        try await Task.sleep(nanoseconds: settle)
        let image = UIGraphicsImageRenderer(size: frame).image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: frame), afterScreenUpdates: true)
        }
        window.isHidden = true
        let url = outputDirectory!.appendingPathComponent("eb-\(name)-\(size.name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
    }

    private func lessonHost(_ id: String, step: Int) -> some View {
        DebugLessonHost(lessonID: id, startStep: step)
    }

    /// Index of the first step matching `match` in a lesson.
    private func stepIndex(_ id: String, _ match: (LessonStep) -> Bool) -> Int? {
        for instrument in TutorInstrument.allCases {
            if let lesson = CurriculumLibrary.shared.course(for: instrument)?.lesson(id: id) {
                return lesson.steps.firstIndex(where: match)
            }
        }
        return nil
    }

    private func firstLesson(_ instrument: TutorInstrument, _ match: (LessonStep) -> Bool) -> (String, Int)? {
        guard let course = CurriculumLibrary.shared.course(for: instrument) else { return nil }
        for location in course.allLessonLocations {
            if let i = location.lesson.steps.firstIndex(where: match) { return (location.lesson.id, i) }
        }
        return nil
    }

    func testGallery() async throws {
        try await render(DiagramGalleryView(), size: .portrait, name: "gallery-guitar", height: 2700)
        try await render(PianoGallery(), size: .portrait, name: "gallery-piano", height: 2700)
        try await render(DiagramGalleryView(), size: .phone, name: "gallery-guitar", height: 3600)
    }

    func testExplainAndDemo() async throws {
        for size in [Size.portrait, .landscape, .phone] {
            try await render(lessonHost("guitar.s3.l1", step: 1), size: size, name: "explain-guitar")
        }
        try await render(lessonHost("piano.s1.l1", step: 0), size: .portrait, name: "explain-piano")
        try await render(lessonHost("piano.s1.l1", step: 1), size: .landscape, name: "demo-piano")
        try await render(lessonHost("guitar.s3.l1", step: 4), size: .portrait, name: "demo-guitar")
    }

    func testPracticeSteps() async throws {
        let isPractice: (LessonStep) -> Bool = { if case .practice = $0 { return true }; return false }
        let practiceIndex = try XCTUnwrap(stepIndex("guitar.s3.l1", isPractice))
        for size in [Size.portrait, .landscape, .split, .phone] {
            try await render(lessonHost("guitar.s3.l1", step: practiceIndex), size: size, name: "practice-chord")
        }
        func kind(_ k: ExerciseKind) -> (LessonStep) -> Bool {
            { if case .practice(let p) = $0 { return p.exercise.kind == k }; return false }
        }
        for (instrument, k) in [(TutorInstrument.guitar, ExerciseKind.chordChanges), (.guitar, .findAllNotes), (.guitar, .improvise),
                                (.guitar, .intervalPlayback), (.guitar, .scale), (.piano, .playSequence), (.guitar, .strumRhythm)] {
            if let (id, i) = firstLesson(instrument, kind(k)) {
                try await render(lessonHost(id, step: i), size: .landscape, name: "practice-\(k.rawValue)-\(instrument.rawValue)")
            }
        }
    }

    func testQuizAndSong() async throws {
        let isQuiz: (LessonStep) -> Bool = { if case .quiz = $0 { return true }; return false }
        if let i = stepIndex("guitar.s3.l1", isQuiz) {
            try await render(lessonHost("guitar.s3.l1", step: i), size: .portrait, name: "quiz-fixed")
        }
        if let i = stepIndex("piano.s1.l1", isQuiz) {
            try await render(lessonHost("piano.s1.l1", step: i), size: .landscape, name: "quiz-keyboard")
            try await render(lessonHost("piano.s1.l1", step: i), size: .phone, name: "quiz-keyboard")
        }
        let isSong: (LessonStep) -> Bool = { if case .song = $0 { return true }; return false }
        if let (id, i) = firstLesson(.guitar, isSong) {
            try await render(lessonHost(id, step: i), size: .portrait, name: "song-guitar")
            try await render(lessonHost(id, step: i), size: .phone, name: "song-guitar")
        }
        if let (id, i) = firstLesson(.piano, isSong) {
            try await render(lessonHost(id, step: i), size: .landscape, name: "song-piano")
        }
    }

    func testCompletion() async throws {
        let lesson = try XCTUnwrap(CurriculumLibrary.shared.course(for: .guitar)?.lesson(id: "guitar.s3.l1"))
        let model = LessonPlayerModel(lesson: lesson, instrument: .guitar)
        model.record(StepOutcome(score: 0.7, passed: false, weakest: .weakest(item: "E", accuracy: 0.5), label: "Practice"),
                     forStep: 5)
        model.record(.skipped(label: "Other"), forStep: 6)
        let store = try TutorStore.inMemory()
        let view = ScrollView {
            LessonCompletionView(model: model, store: store, onDone: {}, onReview: {}).padding(32)
        }.background(DS.paper)
        try await render(view, size: .portrait, name: "completion")
        try await render(view, size: .phone, name: "completion")
    }
}

/// Gallery preset to the piano tab.
private struct PianoGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(DiagramGalleryView.samples(for: .piano).enumerated()), id: \.offset) { _, sample in
                    TutorCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(sample.0).font(.headline)
                            DiagramView(diagram: sample.1, instrument: .piano)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(DS.paper)
    }
}
