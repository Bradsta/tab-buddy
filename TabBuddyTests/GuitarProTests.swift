import XCTest
import WebKit
import SwiftUI
@testable import TabBuddy

@MainActor
final class GuitarProTests: XCTestCase {
    private var webView: WKWebView!
    private var window: UIWindow!

    override func tearDown() {
        webView?.evaluateJavaScript("window.disposePlayer?.()", completionHandler: nil)
        window?.isHidden = true
        window = nil
        webView = nil
        super.tearDown()
    }

    func testTuningLabelsPreserveCustomPitches() {
        for spelling in ["EADGBE", "E A D G B E", "e-B-G-D-A-E", "Standard"] {
            XCTAssertEqual(GuitarTuning.displayName(for: spelling), "Standard")
        }
        XCTAssertEqual(GuitarTuning.displayName(for: "C-C-C-C-C-C"), "C C C C C C")
        XCTAssertEqual(GuitarTuning.displayName(for: "C standard"), "C standard")
        XCTAssertEqual(GuitarTuning.displayName(for: nil), "Unknown")
        XCTAssertEqual(GuitarTuning.noteSpelling("Eb Ab Db Gb"), ["Eb", "Ab", "Db", "Gb"])
        let strings = Array(repeating: "C|--0--2--|", count: 6).joined(separator: "\n")
        XCTAssertEqual(TabParser.parse(strings).tuning, "C C C C C C")
        XCTAssertEqual(TabRenderModelBuilder.build(from: TabParser.parse(strings)).stringLabels, Array(repeating: "C", count: 6))
        XCTAssertEqual(TabParser.parse("Tuning: C-C-C-C-C-C\n" + strings).tuning, "C C C C C C")
        XCTAssertEqual(TabParser.parse("Tuning: E A D G B E\n" + strings).tuning, "Standard")
    }

    func testSmoothScrollingDoesNotStartSynthPlayback() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "practice", withExtension: "gp", subdirectory: "Fixtures/GuitarPro"))
        open(url)
        try await waitFor("window.tabBuddyPlayer?.state.ready === true")
        try await waitFor("document.querySelectorAll('#score svg').length > 0")
        _ = try await webView.evaluateJavaScript("""
        document.getElementById('score-scroll').style.height = '150px';
        document.getElementById('score-scroll').style.flex = 'none';
        window.tabBuddyPlayer.configure({follow:'smooth',smoothSpeed:8});
        """)
        try await waitFor("document.getElementById('score-scroll').scrollTop > 10")
        let playing = try await webView.evaluateJavaScript("window.tabBuddyPlayer.state.playing") as? Bool
        XCTAssertEqual(playing, false)
        _ = try await webView.evaluateJavaScript("window.tabBuddyPlayer.configure({smoothSpeed:0}); window.tabBuddyPlayer.scrollToTop()")
        let top = try await webView.evaluateJavaScript("document.getElementById('score-scroll').scrollTop") as? Double
        XCTAssertEqual(top, 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        let pausedTop = try await webView.evaluateJavaScript("document.getElementById('score-scroll').scrollTop") as? Double
        XCTAssertEqual(pausedTop, 0, "A stopped scrolling clock must leave the score stationary")
        _ = try await webView.evaluateJavaScript("window.tabBuddyPlayer.configure({smoothSpeed:8})")
        try await waitFor("document.getElementById('score-scroll').scrollTop > 5")
    }

    func testNativeSmoothScrollingAdvancesAndPauses() async throws {
        func content(speed: CGFloat) -> some View {
            ScrollView {
                LazyVStack { ForEach(0..<40) { Text("Bar \($0 + 1)").frame(height: 80) } }
                    .background(SmoothScoreScroller(speed: speed, loop: false, restart: 0))
            }
        }
        let host = UIHostingController(rootView: content(speed: 8))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        func findScroll(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        let scroll = try XCTUnwrap(findScroll(host.view))
        let initial = scroll.contentOffset.y
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertGreaterThan(scroll.contentOffset.y, initial + 2)
        host.rootView = content(speed: 0)
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let paused = scroll.contentOffset.y
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(scroll.contentOffset.y, paused, accuracy: 0.5)
    }

    func testFileTypes() {
        for ext in ["gp3", "gp4", "GP5", "gpx", "gp"] {
            XCTAssertTrue(GuitarProFileType.contains("song.\(ext)"))
            XCTAssertTrue(GuitarProFileType.supports(extension: ext))
        }
        XCTAssertFalse(GuitarProFileType.contains("song.gp5.txt"))
        XCTAssertFalse(GuitarProFileType.supports(extension: "exe"))
    }

    func testLibraryImportsAndRescansGuitarProAlongsideExistingFormats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Artist")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let extensions = GuitarProFileType.extensions + ["txt", "pdf"]
        for ext in extensions + ["exe"] {
            try Data("fixture".utf8).write(to: source.appendingPathComponent("song.\(ext)"))
        }
        let service = LibraryFileService()
        try await service.configureTestingRoot(root.appendingPathComponent("library"))
        let imported = try await service.importFiles([source.deletingLastPathComponent()])
        let scanned = try await service.scan()
        XCTAssertEqual(Set(imported.map(\.relativePath)), Set(extensions.map { "Artist/song.\($0)" }))
        XCTAssertEqual(Set(scanned.map(\.relativePath)), Set(imported.map(\.relativePath)))
        await service.clearTestingRoot()
    }

    /// Optional downloaded fixtures stay out of version control and the app bundle.
    func testGProTabSamplesWhenAvailable() async throws {
        for (name, ext, tracks) in [("let-it-be", "gp3", 1), ("canon-rock", "gpx", 7)] {
            guard let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext,
                                                      subdirectory: "Fixtures/GuitarPro/LocalSamples") else {
                throw XCTSkip("Download GProTab samples into Fixtures/GuitarPro/LocalSamples to run this check.")
            }
            open(url)
            try await waitFor("window.tabBuddyPlayer?.state.ready === true")
            try await waitFor("document.querySelectorAll('#score svg').length > 0")
            let count = try await webView.evaluateJavaScript("window.tabBuddyPlayer.state.tracks.length") as? Int
            XCTAssertEqual(count, tracks)
            if tracks > 1 {
                _ = try await webView.evaluateJavaScript("window.tabBuddyPlayer.configure({track:1,solo:true})")
            }
            _ = try await webView.evaluateJavaScript("window.tabBuddyPlayer.play()")
            try await waitFor("window.tabBuddyPlayer.state.playing === true")
            try await waitFor("window.tabBuddyPlayer.state.time > 0.1")
            _ = try await webView.evaluateJavaScript("window.disposePlayer()")
            window.isHidden = true
            window = nil
            webView = nil
        }
    }

    private func open(_ url: URL, player: GuitarProPlayer? = nil) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        if let player { config.userContentController.add(player, name: "player") }
        config.setURLSchemeHandler(GuitarProResourceHandler(scoreURL: url), forURLScheme: "tabbuddy-gp")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        player?.webView = webView
        let controller = UIViewController()
        controller.view = webView
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = webView.frame
        } else { window = UIWindow(frame: webView.frame) }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        webView.load(URLRequest(url: URL(string: "tabbuddy-gp://player/index.html")!))
    }

    private func waitFor(_ expression: String, timeout: TimeInterval = 25) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await webView.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let status = try? await webView.evaluateJavaScript("document.body.innerText")
        XCTFail("Timed out: \(expression). Page: \(status ?? "unavailable")")
        throw URLError(.timedOut)
    }

    func testOfflineRenderingPlaybackAndLoopControls() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "practice", withExtension: "gp", subdirectory: "Fixtures/GuitarPro"))
        open(url)
        try await waitFor("window.tabBuddyPlayer?.state.ready === true")
        try await waitFor("document.querySelectorAll('#score svg').length > 0")
        _ = try await webView.evaluateJavaScript("""
        window.tabBuddyPlayer.configure({start:2,end:1,loop:true});
        """)
        let start = try await webView.evaluateJavaScript("window.tabBuddyPlayer.state.options.start") as? Int
        let end = try await webView.evaluateJavaScript("window.tabBuddyPlayer.state.options.end") as? Int
        XCTAssertEqual(start, 1)
        XCTAssertEqual(end, 2)
        _ = try await webView.evaluateJavaScript("window.tabBuddyPlayer.play()")
        try await waitFor("window.tabBuddyPlayer.state.playing === true")
        try await waitFor("window.tabBuddyPlayer.state.time > 0.1")
        try await waitFor("window.tabBuddyPlayer.state.time >= 5")
        try await waitFor("window.tabBuddyPlayer.state.loopPass >= 1")
        _ = try await webView.evaluateJavaScript("window.pausePlayback()")
        try await waitFor("window.tabBuddyPlayer.state.playing === false")
        _ = try await webView.evaluateJavaScript("window.tabBuddyPlayer.configure({loop:false})")
        let loop = try await webView.evaluateJavaScript("window.tabBuddyPlayer.state.options.loop") as? Bool
        XCTAssertEqual(loop, false)
    }

    func testNativeBridgeRestoresPracticeAndControlsEngine() async throws {
        let id = UUID()
        let key = "guitarPro.practice.\(id.uuidString)"
        UserDefaults.standard.set(["speed": 0.75, "track": 99, "loop": true, "start": 3, "end": 2], forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let player = GuitarProPlayer(fileID: id)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "practice", withExtension: "gp", subdirectory: "Fixtures/GuitarPro"))
        open(url, player: player)
        try await waitFor("window.tabBuddyPlayer?.state.ready === true")
        try await waitFor("window.tabBuddyPlayer.state.options.speed === 0.75")
        XCTAssertTrue(player.ready)
        XCTAssertEqual(player.selectedTrack, 0)
        XCTAssertEqual(player.coordinator.bpm, 90)
        XCTAssertEqual(player.loopStart, 1)
        XCTAssertEqual(player.loopEnd, 2)
        player.actions.seek(2)
        try await waitFor("window.tabBuddyPlayer.state.bar === 2")
        player.coordinator.bpm = 150
        player.actions.tempo(150)
        try await waitFor("window.tabBuddyPlayer.state.options.speed === 1.25")
        player.notePlayer.isEnabled = false
        player.actions.sound(false)
        try await waitFor("window.tabBuddyPlayer.state.options.sound === false")
        player.send(.configure(["notation": "tabAndStaff", "zoom": 1.3, "follow": "off"]))
        try await waitFor("window.tabBuddyPlayer.state.options.notation === 'tabAndStaff' && window.tabBuddyPlayer.state.options.follow === 'off'")
        player.actions.play()
        try await waitFor("window.tabBuddyPlayer.state.playing === true")
        player.actions.pause()
        try await waitFor("window.tabBuddyPlayer.state.playing === false")

        player.loopEnabled = false
        player.loopStart = nil
        player.loopEnd = nil
        player.applyOptions()
        let reopened = GuitarProPlayer(fileID: id)
        XCTAssertFalse(reopened.loopEnabled)
        XCTAssertNil(reopened.loopStart, "Clearing a loop must survive reopening the file")
        XCTAssertNil(reopened.loopEnd)
    }

    func testSharedNativePlayerLayout() async throws {
        let previousMode = UserDefaults.standard.string(forKey: "player.autoScroll")
        UserDefaults.standard.set("follow", forKey: "player.autoScroll")
        defer { UserDefaults.standard.set(previousMode, forKey: "player.autoScroll") }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "practice", withExtension: "gp", subdirectory: "Fixtures/GuitarPro"))
        let id = UUID()
        defer { UserDefaults.standard.removeObject(forKey: "guitarPro.practice.\(id.uuidString)") }
        let host = UIHostingController(rootView: GuitarProView(url: url, fileID: id)
            .environment(\.horizontalSizeClass, .compact))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        func findWebView(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { findWebView($0) }.first
        }
        for _ in 0..<30 {
            webView = findWebView(host.view)
            if webView != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(webView)
        try await waitFor("window.tabBuddyPlayer?.state.ready === true")
        try await waitFor("document.querySelectorAll('#score svg').length > 0")
        XCTAssertLessThan(webView.frame.height, host.view.bounds.height - 80)
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("Shared Guitar Pro controls — iPhone")
        UserDefaults.standard.set("smooth", forKey: "player.autoScroll")
        try await waitFor("window.tabBuddyPlayer.state.options.follow === 'smooth'")
        try await Task.sleep(nanoseconds: 300_000_000)
        capture("Smooth scroll controls — iPhone")
        window.overrideUserInterfaceStyle = .dark
        try await waitFor("window.matchMedia('(prefers-color-scheme: dark)').matches")
        capture("Shared Guitar Pro controls — dark")
        window.overrideUserInterfaceStyle = .light
        host.rootView = GuitarProView(url: url, fileID: id).environment(\.horizontalSizeClass, .regular)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 900)
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        capture("Shared Guitar Pro controls — iPad width")
    }

    func testPianoRetainsOriginalNotationAndInstrumentMetadata() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "piano-practice", withExtension: "gp", subdirectory: "Fixtures/GuitarPro"))
        let player = GuitarProPlayer(fileID: UUID())
        open(url, player: player)
        try await waitFor("window.tabBuddyPlayer?.state.ready === true")
        try await waitFor("document.querySelectorAll('#score svg').length > 0")
        XCTAssertEqual(player.tracks.first?.instrument, .piano)
        XCTAssertTrue(player.tracks.first?.tuning.isEmpty == true)
        XCTAssertEqual(player.composer, "TabBuddy")
        let notation = try await webView.evaluateJavaScript("window.tabBuddyPlayer.state.options.notation") as? String
        XCTAssertEqual(notation, "original")
        _ = try await webView.evaluateJavaScript("window.tabBuddyPlayer.configure({notation:'tabOnly'})")
        try await waitFor("document.querySelectorAll('#score svg').length > 0")
        let snapshot = try await webView.takeSnapshot(configuration: nil)
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "Piano original staff notation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMalformedFileShowsError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gp")
        try Data("not a Guitar Pro file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        open(url)
        try await waitFor("document.querySelector('#status')?.textContent.includes('Could not open') === true")
    }
}
