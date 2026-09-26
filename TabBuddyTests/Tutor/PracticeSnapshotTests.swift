//
//  PracticeSnapshotTests.swift
//  TabBuddyTests
//
//  Layout check for practice mode and the take review without a microphone.
//  Skipped unless PRACTICE_SNAPSHOT_DIR is set (pass it to xcodebuild as
//  TEST_RUNNER_PRACTICE_SNAPSHOT_DIR). Renders iPad landscape/portrait and a
//  compact width to PNG files in that directory; PRACTICE_SNAPSHOT_HOLD keeps
//  each layout on screen for that many seconds so a simulator screenshot can
//  be taken as well.
//

import SwiftUI
import XCTest
@testable import TabBuddy

@MainActor
private final class SnapshotListener: PracticeListening {
    var isListening = false
    var latency: TimeInterval = 0.08
    var takeClock: TimeInterval = 0
    var inputLevel: Float = 0.55
    var onVerification: ((VerificationResult) -> Void)?
    func start(profile: InstrumentProfile, recordTake: Bool) async throws { isListening = true }
    func stop() -> URL? { isListening = false; return nil }
    func armWait(_ event: ExpectedEvent) {}
    func armTimed(_ passage: ExpectedPassage, passageStart: TimeInterval, tempoScale: Double, tolerance: TimeInterval) {}
    func disarm() {}
    func transcribeTake(using transcriber: PolyphonicTranscriber) async throws -> [DetectedEvent] { [] }
    func hit(_ id: Int) {
        onVerification?(VerificationResult(expectedID: id, grade: .hit, heard: [], unexpected: [],
                                           onsetTime: Double(id), confidence: 0.9))
    }
}

@MainActor
final class PracticeSnapshotTests: XCTestCase {

    private struct Layout {
        var name: String
        var size: CGSize
        var sizeClass: UIUserInterfaceSizeClass
    }

    private let layouts = [
        Layout(name: "ipad-landscape", size: CGSize(width: 1376, height: 1032), sizeClass: .regular),
        Layout(name: "ipad-portrait", size: CGSize(width: 1032, height: 1376), sizeClass: .regular),
        Layout(name: "ipad-splitview-narrow", size: CGSize(width: 507, height: 1032), sizeClass: .compact),
    ]

    private var directory: URL!
    private var hold: Double = 0

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["PRACTICE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_PRACTICE_SNAPSHOT_DIR to render practice layouts.")
        }
        directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hold = Double(ProcessInfo.processInfo.environment["PRACTICE_SNAPSHOT_HOLD"] ?? "") ?? 0
    }

    private func render<V: View>(_ view: V, prefix: String) async throws {
        for layout in layouts {
            let host = UIHostingController(rootView: view)
            host.traitOverrides.horizontalSizeClass = layout.sizeClass
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(origin: .zero, size: layout.size)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(prefix)-\(layout.name).png"))
            if hold > 0 { try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) }
            window.isHidden = true
        }
    }

    func testRenderTakeReview() async throws {
        let payload = PracticeDemoData.payload()
        try await render(TakeReviewView(payload: payload, takes: PracticeDemoData.history(current: payload),
                                        totalMeasures: 32), prefix: "review")
    }

    func testRenderPracticeModeOnDrawnTab() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "classtab-aguado", withExtension: "txt",
                                                           subdirectory: "Fixtures"))
        let map = TabParser.parse(try String(contentsOf: url).replacingOccurrences(of: "\r\n", with: "\n"))
        let listener = SnapshotListener()
        let context = PracticeScoreContext(scoreKey: UUID().uuidString, title: "Aguado waltz",
                                           source: .measureMap(map, TabRenderModelBuilder.build(from: map)),
                                           totalMeasures: map.measureCount,
                                           initialRange: PracticeDefaults.systemRange(containing: 1, in: map),
                                           referenceBPM: 90, tempoPercent: 75, instrument: .guitar)
        let controller = PracticeSessionController(context: context, listener: listener, store: try TutorStore.inMemory(),
                                                   latencyStore: ClosureLatencyStore(get: { _ in nil }, set: { _, _ in }),
                                                   clockDriven: false, notificationCenter: NotificationCenter())
        controller.mode = .wait
        await controller.prepare()
        await controller.startTake()
        for id in 0..<5 { listener.hit(id) }
        try await render(PracticeModeView(controller: controller, onClose: {}).background(DS.paper),
                         prefix: "practice-drawn")
        controller.close()
    }

    func testRenderPracticeModeEventStrip() async throws {
        let listener = SnapshotListener()
        let passage = PracticeDemoData.passage()
        let context = PracticeScoreContext(scoreKey: UUID().uuidString, title: "Guitar Pro song",
                                           source: .passage(passage), totalMeasures: 16, initialRange: 8...11,
                                           referenceBPM: nil, tempoPercent: 80, instrument: .guitar)
        let controller = PracticeSessionController(context: context, listener: listener, store: try TutorStore.inMemory(),
                                                   latencyStore: ClosureLatencyStore(get: { _ in 0.07 }, set: { _, _ in }),
                                                   clockDriven: false, notificationCenter: NotificationCenter())
        controller.mode = .wait
        await controller.prepare()
        await controller.startTake()
        for id in 0..<3 { listener.hit(id) }
        let page = ZStack {
            DS.surfaceInset
            Text("Original score page").font(.largeTitle).foregroundStyle(DS.fg3)
            PracticeModeView(controller: controller, onClose: {})
        }
        try await render(page, prefix: "practice-strip")
        controller.close()
    }
}
