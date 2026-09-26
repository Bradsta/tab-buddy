//
//  PracticeTests.swift
//  TabBuddyTests
//
//  WP-F library practice mode: controller state machine (fake listener, no
//  audio), passage sources, suggestion mapping, review computations, and the
//  Guitar Pro note export.
//

import XCTest
import WebKit
@testable import TabBuddy

@MainActor
private final class FakePracticeListener: PracticeListening {
    var isListening = false
    var latency: TimeInterval = 0.05
    var takeClock: TimeInterval = 0
    var inputLevel: Float = 0.3
    var onVerification: ((VerificationResult) -> Void)?

    var startError: Error?
    var startCount = 0
    var stopCount = 0
    var armedWait: [ExpectedEvent] = []
    var armedTimed: (start: TimeInterval, scale: Double, tolerance: TimeInterval)?
    var disarmCount = 0
    var takeURL: URL?
    var transcription: [DetectedEvent] = []

    func start(profile: InstrumentProfile, recordTake: Bool) async throws {
        startCount += 1
        if let startError { throw startError }
        isListening = true
    }

    func stop() -> URL? {
        stopCount += 1
        isListening = false
        return takeURL
    }

    func armWait(_ event: ExpectedEvent) { armedWait.append(event) }

    func armTimed(_ passage: ExpectedPassage, passageStart: TimeInterval, tempoScale: Double,
                  tolerance: TimeInterval) {
        armedTimed = (passageStart, tempoScale, tolerance)
    }

    func disarm() { disarmCount += 1 }

    func transcribeTake(using transcriber: PolyphonicTranscriber) async throws -> [DetectedEvent] { transcription }

    func emit(_ id: Int, _ grade: EventGrade, heard: [Int] = [], unexpected: [Int] = [], at time: Double = 1) {
        onVerification?(VerificationResult(expectedID: id, grade: grade, heard: heard, unexpected: unexpected,
                                           onsetTime: time, confidence: grade == .uncertain ? 0.3 : 0.9))
    }
}

@MainActor
final class PracticeTests: XCTestCase {

    private var webView: WKWebView?
    private var window: UIWindow?

    override func tearDown() {
        webView?.evaluateJavaScript("window.disposePlayer?.()", completionHandler: nil)
        window?.isHidden = true
        window = nil
        webView = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private let scoreKey = UUID().uuidString

    private func makeController(passage: ExpectedPassage, tempoPercent: Double = 100,
                                listener: FakePracticeListener, store: TutorStore,
                                center: NotificationCenter = NotificationCenter(),
                                calibrated: Bool = false,
                                apply: @escaping @MainActor (ClosedRange<Int>?, Double?) -> Void = { _, _ in })
        -> PracticeSessionController {
        let context = PracticeScoreContext(scoreKey: scoreKey, title: "Test song", source: .passage(passage),
                                           totalMeasures: 8, initialRange: 0...0, referenceBPM: nil,
                                           tempoPercent: tempoPercent, instrument: .guitar, applyToViewer: apply)
        let latency = ClosureLatencyStore(get: { _ in calibrated ? 0.07 : nil }, set: { _, _ in })
        return PracticeSessionController(context: context, listener: listener, store: store, latencyStore: latency,
                                         clockDriven: false, notificationCenter: center)
    }

    private func waitForReview(_ c: PracticeSessionController, file: StaticString = #filePath,
                               line: UInt = #line) async throws -> PracticeReviewPayload {
        for _ in 0..<200 {
            if c.phase == .ready, let review = c.review { return review }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("No review; phase \(c.phase)", file: file, line: line)
        throw URLError(.timedOut)
    }

    private var fourNotes: ExpectedPassage {
        PassageBuilder.sequence([60, 62, 64, 65], bpm: 120, instrument: .guitar)
    }

    // MARK: - State machine

    func testWaitModeAdvancesOnHitsOnlyAndSavesTake() async throws {
        let listener = FakePracticeListener()
        let store = try TutorStore.inMemory()
        let c = makeController(passage: fourNotes, tempoPercent: 80, listener: listener, store: store)
        c.mode = .wait
        await c.prepare()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.events.count, 4)
        XCTAssertTrue(c.needsCalibration, "No stored latency for the route → non-blocking prompt")
        XCTAssertTrue(c.canStart)

        await c.startTake()
        XCTAssertEqual(c.phase, .listening)
        XCTAssertEqual(listener.startCount, 1)
        XCTAssertEqual(listener.armedWait.map(\.id), [0])

        listener.emit(0, .uncertain)
        listener.emit(0, .wrongPitch, unexpected: [61])
        XCTAssertEqual(c.currentIndex, 0, "Only a hit advances Wait mode")
        XCTAssertTrue(c.satisfied.isEmpty)

        listener.emit(0, .hit, heard: [60], at: 1.0)
        XCTAssertEqual(c.currentIndex, 1)
        XCTAssertEqual(c.satisfied, [0])
        XCTAssertEqual(listener.armedWait.map(\.id), [0, 1])

        c.skipCurrent()
        XCTAssertEqual(c.currentIndex, 2)
        XCTAssertEqual(listener.armedWait.last?.id, 2)

        listener.emit(2, .hit, heard: [64], at: 2.4)
        listener.emit(3, .partial, heard: [], at: 3.0)
        XCTAssertEqual(c.partiallyHeard, [3])
        listener.emit(3, .hit, heard: [65], at: 3.3)
        XCTAssertEqual(c.phase, .analyzing, "The last hit finishes the take")
        XCTAssertEqual(listener.stopCount, 1)

        let review = try await waitForReview(c)
        let grades = review.archive.analysis.graded.sorted { $0.expectedID < $1.expectedID }.map(\.grade)
        XCTAssertEqual(grades, [.hit, .missed, .hit, .hit])
        XCTAssertEqual(review.archive.analysis.accuracy, 0.75, accuracy: 1e-9)
        XCTAssertEqual(review.archive.mode, .wait)
        XCTAssertEqual(review.archive.tempoPercent, 80)
        XCTAssertEqual(review.bpm, 96, accuracy: 1e-9)

        let records = store.takes(forScore: scoreKey)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, review.id)
        XCTAssertNotNil(records.first?.analysis, "Plain TakeAnalysis decoding still works")
        XCTAssertEqual(PracticeTakeArchive.decode(records[0].analysisJSON)?.passage?.events.count, 4)
        XCTAssertEqual(c.takes.map(\.id), [review.id])
        XCTAssertEqual(c.payload(forTake: review.id)?.archive.passage?.events.count, 4)

        c.deleteTake(review.id)
        XCTAssertTrue(store.takes(forScore: scoreKey).isEmpty)
        XCTAssertNil(c.review)
    }

    func testPlayAlongCountInCursorAndTimedArming() async throws {
        let listener = FakePracticeListener()
        listener.takeClock = 1.0
        let store = try TutorStore.inMemory()
        let c = makeController(passage: fourNotes, listener: listener, store: store, calibrated: true)
        c.mode = .playAlong
        await c.prepare()
        XCTAssertFalse(c.needsCalibration)
        await c.startTake()

        // One 4/4 bar at 120 BPM lasts 2 s, so the count-in is a single bar.
        XCTAssertEqual(c.phase, .countIn(remaining: 4))
        let armed = try XCTUnwrap(listener.armedTimed)
        XCTAssertEqual(armed.start, 3.0, accuracy: 1e-9)
        XCTAssertEqual(armed.scale, 1)
        XCTAssertEqual(armed.tolerance, 0.15, accuracy: 1e-9)

        listener.takeClock = 1.6
        c.tick()
        XCTAssertEqual(c.phase, .countIn(remaining: 3))
        XCTAssertEqual(c.cursor.beat ?? 0, -2.8, accuracy: 1e-9)
        XCTAssertEqual(c.cursor.pulseBeatInMeasure, 1)

        listener.takeClock = 3.0
        c.tick()
        XCTAssertEqual(c.phase, .listening)
        XCTAssertEqual(c.currentIndex, 0)
        XCTAssertEqual(c.cursor.pulseBeatInMeasure, 0)

        listener.emit(0, .hit, heard: [60], at: 3.0)
        listener.takeClock = 4.1
        c.tick()
        XCTAssertEqual(c.currentIndex, 2, "The cursor follows the tempo, not the notes")
        XCTAssertEqual(c.satisfied, [0])

        listener.emit(2, .hit, heard: [64], at: 4.0)
        listener.takeClock = 3.0 + 5.2 * 0.5
        c.tick()
        XCTAssertEqual(c.phase, .analyzing, "One beat after the last note the take ends")

        let review = try await waitForReview(c)
        XCTAssertEqual(review.archive.mode, .playAlong)
        XCTAssertEqual(review.archive.passageStart ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(review.archive.latency, 0.05)
    }

    func testTwoBarCountInForShortBars() async throws {
        let listener = FakePracticeListener()
        let store = try TutorStore.inMemory()
        let fast = PassageBuilder.sequence([60, 62, 64], bpm: 180, beatsPerMeasure: 3, instrument: .guitar)
        let c = makeController(passage: fast, listener: listener, store: store)
        c.mode = .playAlong
        await c.prepare()
        await c.startTake()
        XCTAssertEqual(c.phase, .countIn(remaining: 6), "A 1 s bar gets a two-bar visual count-in")
    }

    func testCountInIsOneBarInPassageBeats() async throws {
        // Quarter-note passages carry 3 beats per 6/8 bar; 3/4 has 3 as well.
        let sixEight = PassageBuilder.quarterBeats(numerator: 6, noteValue: 8)
        XCTAssertEqual(sixEight, 3)
        for (bar, bpm, expected) in [(sixEight, 60.0, 3), (3, 60.0, 3), (sixEight, 120.0, 6)] {
            let listener = FakePracticeListener()
            let passage = PassageBuilder.sequence([60, 62, 64, 65, 67, 69], bpm: bpm, beatsPerMeasure: bar,
                                                  instrument: .guitar)
            let c = makeController(passage: passage, listener: listener, store: try TutorStore.inMemory())
            c.mode = .playAlong
            await c.prepare()
            await c.startTake()
            XCTAssertEqual(c.phase, .countIn(remaining: expected), "bar \(bar) at \(bpm) BPM")
            // Beat 0 of the passage is the accented first pulse of a bar.
            listener.takeClock = try XCTUnwrap(listener.armedTimed?.start)
            c.tick()
            XCTAssertEqual(c.cursor.pulseBeatInMeasure, 0)
            listener.takeClock += 60 / bpm
            c.tick()
            XCTAssertEqual(c.cursor.pulseBeatInMeasure, 1)
            c.stopTake()
            _ = try await waitForReview(c)
        }
    }

    func testPermissionDeniedKeepsReadyAndFlags() async throws {
        let listener = FakePracticeListener()
        listener.startError = TutorAudioError.permissionDenied
        let c = makeController(passage: fourNotes, listener: listener, store: try TutorStore.inMemory())
        await c.prepare()
        await c.startTake()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertTrue(c.permissionDenied)
        XCTAssertNil(c.review)
    }

    func testStopDuringCountInDiscardsTake() async throws {
        let listener = FakePracticeListener()
        let store = try TutorStore.inMemory()
        let c = makeController(passage: fourNotes, listener: listener, store: store)
        c.mode = .playAlong
        await c.prepare()
        c.toggleTake()
        for _ in 0..<50 where !c.isTakeActive || c.phase == .starting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(c.phase, .countIn(remaining: 4))
        c.toggleTake()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertTrue(store.takes(forScore: scoreKey).isEmpty)
        XCTAssertNil(c.review)
    }

    func testInterruptionStopsAndAnalyzesWithNotice() async throws {
        let listener = FakePracticeListener()
        let center = NotificationCenter()
        let c = makeController(passage: fourNotes, listener: listener, store: try TutorStore.inMemory(), center: center)
        c.mode = .wait
        await c.prepare()
        await c.startTake()
        listener.emit(0, .hit, heard: [60])
        center.post(name: .tutorListeningDidStop, object: nil)
        let review = try await waitForReview(c)
        XCTAssertNotNil(c.notice)
        XCTAssertEqual(review.archive.analysis.graded.first { $0.expectedID == 0 }?.grade, .hit)
    }

    func testClosingMidTakeKeepsTakeForNextVisit() async throws {
        let listener = FakePracticeListener()
        let store = try TutorStore.inMemory()
        let c = makeController(passage: fourNotes, listener: listener, store: store)
        c.mode = .wait
        await c.prepare()
        listener.takeClock = 2
        await c.startTake()
        listener.emit(0, .hit, heard: [60], at: 2.5)
        listener.takeClock = 8
        c.close()
        for _ in 0..<200 where store.takes(forScore: scoreKey).isEmpty || c.phase != .ready {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let saved = try XCTUnwrap(store.takes(forScore: scoreKey).first)
        XCTAssertNil(c.review, "No review is presented after closing")

        let next = makeController(passage: fourNotes, listener: FakePracticeListener(), store: store)
        await next.prepare()
        XCTAssertEqual(next.unreviewedTakeID, saved.id)
        XCTAssertNotNil(next.notice)
        next.reviewUnreviewedTake()
        XCTAssertEqual(next.review?.id, saved.id)
        XCTAssertNil(next.unreviewedTakeID)

        let third = makeController(passage: fourNotes, listener: FakePracticeListener(), store: store)
        await third.prepare()
        XCTAssertNil(third.unreviewedTakeID, "Offered once")
    }

    func testClosingShortTakeDiscardsIt() async throws {
        let listener = FakePracticeListener()
        let store = try TutorStore.inMemory()
        let c = makeController(passage: fourNotes, listener: listener, store: store)
        c.mode = .wait
        await c.prepare()
        await c.startTake()
        listener.emit(0, .hit, heard: [60], at: 0.5)
        listener.takeClock = 1.5
        c.close()
        XCTAssertEqual(c.phase, .ready)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(store.takes(forScore: scoreKey).isEmpty)
    }

    func testRouteChangeStopsOnlyForDeviceChanges() async throws {
        let listener = FakePracticeListener()
        let c = makeController(passage: fourNotes, listener: listener, store: try TutorStore.inMemory())
        c.mode = .wait
        await c.prepare()
        await c.startTake()
        c.routeChanged(.categoryChange)
        XCTAssertEqual(c.phase, .listening, "Session activation changes are not interruptions")
        c.routeChanged(.oldDeviceUnavailable)
        XCTAssertEqual(c.phase, .analyzing)
        _ = try await waitForReview(c)
    }

    // MARK: - Suggestions

    func testSuggestionMappingClampsAndUpdatesViewer() async throws {
        let action = PracticeSuggestionAction(PracticeSuggestion(message: "", loopMeasures: 6...12, tempoPercent: 200),
                                              totalMeasures: 8)
        XCTAssertEqual(action.loop, 6...7)
        XCTAssertEqual(action.tempoPercent, 150)
        let none = PracticeSuggestionAction(PracticeSuggestion(message: "", loopMeasures: nil, tempoPercent: 20),
                                            totalMeasures: 8)
        XCTAssertNil(none.loop)
        XCTAssertEqual(none.tempoPercent, 25)

        var applied: [(ClosedRange<Int>?, Double?)] = []
        let passage = PassageBuilder.sequence(Array(60..<76), bpm: 100, instrument: .guitar)   // 4 measures
        let c = makeController(passage: passage, listener: FakePracticeListener(), store: try TutorStore.inMemory(),
                               apply: { applied.append(($0, $1)) })
        await c.prepare()
        XCTAssertEqual(c.range, 0...0)
        c.apply(PracticeSuggestionAction(PracticeSuggestion(message: "Loop measures 2–3 at 80%",
                                                            loopMeasures: 1...2, tempoPercent: 80), totalMeasures: 8))
        XCTAssertEqual(c.range, 1...2)
        XCTAssertEqual(c.tempoPercent, 80)
        XCTAssertEqual(c.passage?.events.first?.measureIndex, 1)
        XCTAssertEqual(c.passage?.events.first?.beat, 0, "Beat 0 is the start of the new range")
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.0, 1...2)
        XCTAssertEqual(applied.first?.1, 80)

        c.setTempoPercent(90)
        XCTAssertEqual(applied.last?.1, 90, "The practice speed follows into the viewer")
    }

    // MARK: - Passage sources

    func testPassageFromTextTabFixture() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "classtab-aguado", withExtension: "txt",
                                                           subdirectory: "Fixtures"))
        let map = TabParser.parse(try String(contentsOf: url).replacingOccurrences(of: "\r\n", with: "\n"))
        let model = TabRenderModelBuilder.build(from: map)
        let factory = PracticePassageFactory(source: .measureMap(map, model))
        let loaded = await factory.load()
        XCTAssertTrue(loaded)
        XCTAssertEqual(factory.measureCount, map.measureCount)

        let system = try XCTUnwrap(PracticeDefaults.systemRange(containing: 2, in: map))
        XCTAssertTrue(system.contains(2))
        let passage = try XCTUnwrap(factory.passage(range: system, bpm: 100, instrument: .guitar))
        XCTAssertTrue(passage.events.allSatisfy { system.contains($0.measureIndex) })
        XCTAssertEqual(passage.bpm, 100)
        XCTAssertEqual(passage.instrument, .guitar)
        XCTAssertTrue(passage.events.allSatisfy { !($0.fretting ?? []).isEmpty }, "Drawn overlay needs fingering")

        // Instrument inference.
        XCTAssertEqual(PracticeDefaults.instrument(trackInstrument: nil, fileInstruments: [.piano], isTablature: true), .guitar)
        XCTAssertEqual(PracticeDefaults.instrument(trackInstrument: .bass, fileInstruments: [], isTablature: false), .guitar)
        XCTAssertEqual(PracticeDefaults.instrument(trackInstrument: .piano, fileInstruments: [.guitar], isTablature: false), .piano)
        XCTAssertEqual(PracticeDefaults.instrument(trackInstrument: nil, fileInstruments: [.piano], isTablature: false), .piano)
        XCTAssertEqual(PracticeDefaults.instrument(trackInstrument: nil, fileInstruments: [.ukulele], isTablature: false), .guitar)
    }

    /// The array `player.js exportNotes` posts (NSNumber values, chords as arrays).
    private var exportedNotes: [[String: Any]] {
        func n(_ bar: Int, _ start: Double, _ midi: [Int], dur: Double = 960) -> [String: Any] {
            ["track": NSNumber(value: 0), "bar": NSNumber(value: bar), "start": NSNumber(value: start),
             "duration": NSNumber(value: dur), "midi": midi.map { NSNumber(value: $0) }, "tempo": NSNumber(value: 90.0),
             "ticksPerQuarter": 960, "barStartTick": NSNumber(value: Double(bar) * 3840), "beatsPerBar": 4, "beatValue": 4]
        }
        return [n(0, 0, [40, 47, 52]), n(0, 1920, [55]), n(1, 3840, [57]), n(1, 4800, [59]),
                n(2, 7680, [60, 64]), n(2, 9600, [62], dur: 1920)]
    }

    func testPassageFromAlphaTabExport() async throws {
        let notes = exportedNotes
        let factory = PracticePassageFactory(source: .alphaTab(track: 0, export: { notes }))
        let loaded = await factory.load()
        XCTAssertTrue(loaded)
        XCTAssertEqual(factory.measureCount, 3)
        let whole = try XCTUnwrap(factory.passage(range: nil, bpm: nil, instrument: .guitar))
        XCTAssertEqual(whole.bpm, 90)
        XCTAssertEqual(whole.events.map(\.pitches), [[40, 47, 52], [55], [57], [59], [60, 64], [62]])
        let tail = try XCTUnwrap(factory.passage(range: 1...2, bpm: nil, instrument: .piano))
        XCTAssertEqual(tail.events.map(\.beat), [0, 1, 4, 6])
        XCTAssertEqual(tail.events.map(\.measureIndex), [1, 1, 2, 2])
        XCTAssertEqual(tail.instrument, .piano)

        let empty = PracticePassageFactory(source: .alphaTab(track: 0, export: { [] }))
        let emptyLoaded = await empty.load()
        XCTAssertFalse(emptyLoaded)

        // An unavailable source puts the controller in .unavailable with a reason.
        let context = PracticeScoreContext(scoreKey: scoreKey, title: "t", source: .alphaTab(track: 0, export: { [] }),
                                           totalMeasures: 3, initialRange: nil, referenceBPM: nil, tempoPercent: 100,
                                           instrument: .guitar)
        let c = PracticeSessionController(context: context, listener: FakePracticeListener(),
                                          store: try TutorStore.inMemory(),
                                          latencyStore: ClosureLatencyStore(get: { _ in nil }, set: { _, _ in }),
                                          clockDriven: false, notificationCenter: NotificationCenter())
        await c.prepare()
        guard case .unavailable(let reason) = c.phase else { return XCTFail("\(c.phase)") }
        XCTAssertFalse(reason.isEmpty)
    }

    func testGuitarProPlayerExportsNotes() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "practice", withExtension: "gp",
                                                           subdirectory: "Fixtures/GuitarPro"))
        let fileID = UUID()
        let player = GuitarProPlayer(fileID: fileID)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(player, name: "player")
        config.setURLSchemeHandler(GuitarProResourceHandler(scoreURL: url), forURLScheme: "tabbuddy-gp")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        webView = view
        player.webView = view
        let controller = UIViewController()
        controller.view = view
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map { UIWindow(windowScene: $0) } ?? UIWindow(frame: view.frame)
        window.frame = view.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        view.load(URLRequest(url: URL(string: "tabbuddy-gp://player/index.html")!))
        for _ in 0..<150 where !player.ready { try await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertTrue(player.ready)
        XCTAssertTrue(PracticeSourceRegistry.guitarPro(for: fileID) === player)

        let raw = await player.exportNotes()
        XCTAssertFalse(raw.isEmpty)
        let keys: Set<String> = ["track", "bar", "start", "duration", "midi", "tempo", "ticksPerQuarter",
                                 "barStartTick", "beatsPerBar", "beatValue"]
        XCTAssertEqual(Set(raw[0].keys), keys, "Exactly the AlphaTabNote keys")
        let typed = raw.compactMap(PassageBuilder.AlphaTabNote.init(dictionary:))
        XCTAssertEqual(typed.count, raw.count)
        XCTAssertEqual(typed.map(\.start), typed.map(\.start).sorted(), "Score-order ticks")
        XCTAssertTrue(typed.allSatisfy { $0.track == player.selectedTrack && $0.start >= $0.barStartTick })
        XCTAssertTrue(typed.allSatisfy { $0.midi.allSatisfy { (0...127).contains($0) } && $0.tempo > 0 })
        let passage = try XCTUnwrap(PassageBuilder.from(alphaTabNotes: raw))
        XCTAssertFalse(passage.events.isEmpty)
        XCTAssertEqual(passage.bpm, player.originalBPM, accuracy: 0.5)
    }

    // MARK: - Review computations

    private func reviewFixture() -> (ExpectedPassage, TakeAnalysis) {
        // Measures 4–6: two events each.
        var passage = PassageBuilder.from(pitchEvents: [[60], [64, 67], [62], [65], [60, 64, 67], [59]],
                                          durations: [2], bpm: 100, beatsPerMeasure: 4, instrument: .piano)
        for i in passage.events.indices { passage.events[i].measureIndex += 4 }
        func g(_ id: Int, _ grade: EventGrade, matched: [Int] = [], missing: [Int] = [], wrong: [Int] = [],
               t: Double? = nil, ms: Double? = nil) -> GradedEvent {
            GradedEvent(expectedID: id, grade: grade, matchedPitches: matched, missingPitches: missing,
                        wrongPitches: wrong, playedTime: t, timingOffsetMs: ms, confidence: 0.9)
        }
        let graded = [g(0, .hit, matched: [60], t: 1.0, ms: -20), g(1, .partial, matched: [64], missing: [67], t: 2.2, ms: 30),
                      g(2, .wrongPitch, missing: [62], wrong: [63], t: 3.4), g(3, .missed, missing: [65]),
                      g(4, .uncertain, missing: [60, 64, 67]), g(5, .hit, matched: [59], t: 7.0, ms: 80)]
        let analysis = TakeAnalysis(graded: graded, extras: [ExtraNote(time: 2.5, pitch: 70, afterExpectedID: 1),
                                                             ExtraNote(time: 0.2, pitch: 50, afterExpectedID: nil)],
                                    tempoCurve: [TempoSample(beat: 0, bpm: 98), TempoSample(beat: 8, bpm: 110)],
                                    targetBPM: 100, accuracy: 0.6, timingMADms: 30,
                                    measureAccuracy: [4: 0.75, 5: 0, 6: 1], measureTendency: [4: .steady, 5: .rushing, 6: .rushing],
                                    suggestions: [])
        return (passage, analysis)
    }

    func testReviewModelLegendRowsAndWeakest() {
        let (passage, analysis) = reviewFixture()
        let model = TakeReviewModel(analysis: analysis, passage: passage, latency: 0.1)
        XCTAssertEqual(model.measures, [4, 5, 6])
        XCTAssertEqual(model.rows(measuresPerRow: 2), [[4, 5], [6]])
        let counts = model.legendCounts
        XCTAssertEqual(counts[.hit], 2)
        XCTAssertEqual(counts[.partial], 1)
        XCTAssertEqual(counts[.wrongPitch], 1)
        XCTAssertEqual(counts[.missed], 1)
        XCTAssertEqual(counts[.uncertain], 1)
        XCTAssertEqual(counts[nil], 2, "Extras")
        XCTAssertEqual(model.weakestMeasures().map(\.measure), [5, 4])
        XCTAssertEqual(model.extras.first?.measureIndex, 4, "An extra sits after the event it followed")
        XCTAssertEqual(model.extras.first?.pitch, 70)

        let partial = model.marks.first { $0.id == 1 }!
        XCTAssertEqual(TakeReviewModel.describe(partial), "E4 G4: missing G4")
        let wrong = model.marks.first { $0.id == 2 }!
        XCTAssertEqual(TakeReviewModel.describe(wrong), "D4: heard D♯4 instead")
        XCTAssertEqual(TakeReviewModel.describe(model.marks.first { $0.id == 4 }!), "C4 E4 G4: not sure")

        XCTAssertEqual(model.measurePosition(ofBeat: 0), 4, accuracy: 1e-9)
        XCTAssertEqual(model.measurePosition(ofBeat: 6), 5.5, accuracy: 1e-9)
        XCTAssertEqual(model.tempoPoints.map(\.measurePosition), [4, 6])
        XCTAssertEqual(model.loopRegion(around: 6), 5...6, "Tap-to-loop spans the rushing run")
        XCTAssertEqual(model.loopRegion(around: 4), 4...5, "Steady measures loop with their neighbor")

        // Playback cursor: anchors at hits/partials (played + latency).
        XCTAssertEqual(model.beat(atAudioTime: 1.1) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(model.beat(atAudioTime: 1.7) ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(model.beat(atAudioTime: 7.1) ?? -1, 10, accuracy: 1e-9)
    }

    func testHeatmapAggregatesAcrossTakes() {
        func take(_ day: Int, _ cells: [Int: Double]) -> PracticeTakeSummary {
            PracticeTakeSummary(id: UUID(), date: Date(timeIntervalSince1970: Double(day) * 86_400),
                                measures: (cells.keys.min() ?? 0)...(cells.keys.max() ?? 0), bpm: 80,
                                accuracy: cells.values.reduce(0, +) / Double(max(1, cells.count)),
                                timingMADms: nil, measureAccuracy: cells, hasAudio: false)
        }
        let takes = [take(3, [2: 0.9, 3: 1.0]), take(1, [1: 0.2, 2: 0.4]), take(2, [2: 0.6, 3: 0.5])]
        let heatmap = PracticeHeatmap(takes: takes)
        XCTAssertEqual(heatmap.measures, [1, 2, 3])
        XCTAssertEqual(heatmap.rows.map(\.date), takes.map(\.date).sorted(), "Oldest first")
        XCTAssertEqual(heatmap.meanByMeasure[2] ?? 0, (0.4 + 0.6 + 0.9) / 3, accuracy: 1e-9)
        XCTAssertEqual(heatmap.meanByMeasure[1] ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(heatmap.trend(forMeasure: 2) ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertNil(heatmap.trend(forMeasure: 1), "One take is not a trend")
        XCTAssertNil(heatmap.rows.first?.cells[3], "Absent measures stay empty")

        let limited = PracticeHeatmap(takes: takes, limit: 2)
        XCTAssertEqual(limited.rows.count, 2)
        XCTAssertEqual(limited.measures, [2, 3], "Only the newest takes are kept")
        XCTAssertTrue(PracticeHeatmap(takes: []).isEmpty)
    }

    func testArchiveKeepsTakeAnalysisCompatible() throws {
        let (passage, analysis) = reviewFixture()
        let archive = PracticeTakeArchive(analysis: analysis, passage: passage, mode: .playAlong, tempoPercent: 70,
                                          latency: 0.09, passageStart: 2)
        let data = try JSONEncoder().encode(archive)
        let plain = try JSONDecoder().decode(TakeAnalysis.self, from: data)
        XCTAssertEqual(plain, analysis)
        let back = try XCTUnwrap(PracticeTakeArchive.decode(data))
        XCTAssertEqual(back.passage, passage)
        XCTAssertEqual(back.mode, .playAlong)
        XCTAssertEqual(back.tempoPercent, 70)
        XCTAssertEqual(back.latency, 0.09)
        XCTAssertEqual(back.passageStart, 2)
        // A plain analysis (another writer) decodes as an archive without extras.
        let bare = try XCTUnwrap(PracticeTakeArchive.decode(try JSONEncoder().encode(analysis)))
        XCTAssertNil(bare.passage)
        XCTAssertEqual(bare.analysis, analysis)
    }

    func testDatesUseYearMonthDay() {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 7; c.hour = 9; c.minute = 5
        let date = Calendar.current.date(from: c)!
        XCTAssertEqual(PracticeDateFormat.day(date), "2026-03-07")
        XCTAssertEqual(PracticeDateFormat.dayTime(date), "2026-03-07 09:05")
    }

    func testDemoAnalysisExercisesEveryGrade() {
        #if DEBUG
        let model = TakeReviewModel(archive: PracticeDemoData.archive())
        let counts = model.legendCounts
        XCTAssertGreaterThan(counts[.hit] ?? 0, 20)
        XCTAssertGreaterThan(counts[.wrongPitch] ?? 0, 0)
        XCTAssertGreaterThan(counts[.missed] ?? 0, 0)
        XCTAssertGreaterThan(model.tempoPoints.count, 2)
        #endif
    }
}
