import SwiftUI
import WebKit

/// Guitar Pro keeps its score engine, but shares the native practice interface.
struct GuitarProView: View {
    let url: URL
    @StateObject private var player: GuitarProPlayer
    @State private var notation = NotationMode.original.rawValue
    private let file: FileItem?
    @Environment(\.modelContext) private var context
    @AppStorage("player.fontScale") private var scale = 1.0
    @AppStorage("player.autoScroll") private var follow = AutoScrollMode.smooth.rawValue

    @Environment(\.scenePhase) private var scenePhase
    @State private var smoothSpeed: CGFloat = 0
    @State private var smoothLoop = false

    init(url: URL, fileID: UUID, file: FileItem? = nil) {
        self.url = url
        self.file = file
        _notation = State(initialValue: file?.preferredNotation ?? NotationMode.original.rawValue)
        _player = StateObject(wrappedValue: GuitarProPlayer(fileID: fileID))
    }

    var body: some View {
        VStack(spacing: 0) {
            GuitarProScoreView(url: url, player: player)
            PracticeNavigationPicker(mode: $follow)
            if follow == AutoScrollMode.smooth.rawValue {
                OriginalTransportBar(scrollSpeed: $smoothSpeed, loopToTop: $smoothLoop,
                    onBackToTop: { player.send(.scrollToTop) }, displayContent: { displaySettings })
            } else {
                measureTransport
            }
        }
        .onChange(of: player.ready) { if $0 { PerfTrace.endAfterCommit("open", "guitar-pro ready"); syncDisplay(); saveMetadata() } }
        .onChange(of: player.selectedTrack) { _ in player.applyOptions() }
        .onChange(of: player.solo) { _ in player.applyOptions() }
        .onChange(of: notation) { _ in file?.preferredNotation = notation; try? context.save(); syncDisplay() }
        .onChange(of: scale) { _ in syncDisplay() }
        .onChange(of: follow) { _ in player.actions.pause(); smoothSpeed = 0; syncDisplay() }
        .onChange(of: smoothSpeed) { _ in syncDisplay() }
        .onChange(of: smoothLoop) { _ in syncDisplay() }
        .onChange(of: scenePhase) { if $0 != .active { smoothSpeed = 0 } }
        .onDisappear { smoothSpeed = 0 }
    }

    private var measureTransport: some View {
        TabTransportBar(
            coordinator: player.coordinator, metronome: player.metronome,
            notePlayer: player.notePlayer, userBPM: $player.userBPM,
            originalBPM: player.originalBPM, totalMeasures: player.total,
            beatsPerMeasure: player.beats, externalPlayback: player.actions,
            isReady: player.ready, elapsedSeconds: player.elapsed,
            allowsReferenceTempoEditing: false,
            loopEnabled: $player.loopEnabled, loopStart: $player.loopStart, loopEnd: $player.loopEnd,
            onLoopChanged: { player.applyOptions() },
            displayContent: { displaySettings }
        )
    }

    @ViewBuilder private var displaySettings: some View {
        if player.tracks.count > 1 {
            Section("Tracks") {
                Picker("Track", selection: $player.selectedTrack) {
                    ForEach(player.tracks) { track in Text(track.name).tag(track.id) }
                }
                Toggle("Solo selected track", isOn: $player.solo)
            }
        }
        PlayerDisplaySections(notation: Binding(get: {
            let hasTab = player.tracks.first(where: { $0.id == player.selectedTrack })?.tuning.isEmpty == false
            return !hasTab && [NotationMode.tabOnly.rawValue, NotationMode.tabAndStaff.rawValue].contains(notation) ? NotationMode.staffOnly.rawValue : notation
        }, set: { notation = $0 }), scale: $scale, autoScroll: $follow, supportsOriginal: true,
                              supportsTab: player.tracks.first(where: { $0.id == player.selectedTrack })?.tuning.isEmpty == false)
    }

    private func saveMetadata() {
        guard let file, !file.metadataEdited else { return }
        file.instruments = Array(Set(player.tracks.map { $0.instrument.rawValue })).sorted()
        file.instrument = file.instruments.first
        if !player.composer.isEmpty { file.composer = player.composer }
        if !player.arranger.isEmpty { file.arranger = player.arranger }
        if !player.collection.isEmpty { file.collectionTitle = player.collection }
        file.applyEmbeddedMetadata(player.embedded)
        try? context.save()
    }

    private func syncDisplay() {
        player.send(.configure(["notation": notation, "zoom": scale, "follow": follow,
                                "smoothSpeed": smoothSpeed, "smoothLoop": smoothLoop]))
    }
}

@MainActor
final class GuitarProPlayer: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Track: Identifiable {
        let id: Int
        let name: String
        let tuning: String
        let capo: Int
        var instrument: Instrument = .unknown
    }
    private(set) var embedded = EmbeddedScoreMetadata()
    private(set) var composer = ""
    private(set) var arranger = ""
    private(set) var collection = ""
    // This coordinator mirrors engine state for the shared controls; its clock is never started.
    let coordinator = PlaybackCoordinator()
    let metronome = MetronomeEngine()
    let notePlayer = NotePlaybackEngine()
    @Published var userBPM = 120.0
    @Published var originalBPM = 120.0
    @Published var ready = false
    @Published var total = 0
    @Published var beats = 4
    @Published var elapsed = 0.0
    @Published var tracks: [Track] = []
    @Published var selectedTrack = 0
    @Published var solo = false
    @Published var loopEnabled = false
    @Published var loopStart: Int?
    @Published var loopEnd: Int?
    private var loopPass = 0
    private var loaded = false
    private var savedSpeed = 1.0
    private let settingsKey: String
    weak var webView: WKWebView?

    init(fileID: UUID) {
        settingsKey = "guitarPro.practice.\(fileID.uuidString)"
        super.init()
        let saved = UserDefaults.standard.dictionary(forKey: settingsKey) ?? [:]
        savedSpeed = min(1.5, max(0.25, saved["speed"] as? Double ?? 1))
        selectedTrack = saved["track"] as? Int ?? 0
        solo = saved["solo"] as? Bool ?? false
        loopEnabled = saved["loop"] as? Bool ?? false
        // Earlier web controls stored one-based bar numbers.
        loopStart = (saved["start"] as? Int).map { max(0, $0 - 1) }
        loopEnd = (saved["end"] as? Int).map { max(0, $0 - 1) }
        metronome.isEnabled = saved["metronome"] as? Bool ?? false
        notePlayer.isEnabled = saved["sound"] as? Bool ?? false
        PracticeSourceRegistry.register(self, for: fileID)
        // Tutor listening mutes app audio.
        NotificationCenter.default.addObserver(self, selector: #selector(tutorListeningWillStart),
                                               name: .tutorListeningWillStart, object: nil)
    }

    @objc private func tutorListeningWillStart() { send(.pause) }

    /// Tutor practice: the selected track's notes (`PassageBuilder.AlphaTabNote` dictionaries).
    func exportNotes() async -> [[String: Any]] {
        guard loaded, let webView, let script = Command.exportNotes(selectedTrack).javaScript else { return [] }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? [[String: Any]] ?? [])
            }
        }
    }

    var actions: PlayerPlaybackActions {
        PlayerPlaybackActions(
            play: { [weak self] in self?.send(.play) },
            pause: { [weak self] in self?.send(.pause) },
            seek: { [weak self] in self?.send(.seek($0)) },
            sound: { [weak self] _ in self?.applyOptions() },
            tempo: { [weak self] _ in self?.applyOptions() },
            metronome: { [weak self] _ in self?.applyOptions() })
    }

    /// Only supported operations can cross the native/web boundary, with their required arguments.
    enum Command {
        case play, pause, scrollToTop, loadScore
        case seek(Int)
        case configure([String: Any])
        case exportNotes(Int)

        var javaScript: String? {
            let method: String
            let argument: Any?
            switch self {
            case .play: (method, argument) = ("play", nil)
            case .pause: (method, argument) = ("pause", nil)
            case .scrollToTop: (method, argument) = ("scrollToTop", nil)
            case .loadScore: (method, argument) = ("loadScore", nil)
            case .seek(let bar): (method, argument) = ("seek", bar)
            case .configure(let options): (method, argument) = ("configure", options)
            case .exportNotes(let track): (method, argument) = ("exportNotes", track)
            }
            var json = ""
            if let argument {
                guard let data = try? JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed]),
                      let encoded = String(data: data, encoding: .utf8) else { return nil }
                json = encoded
            }
            return "window.tabBuddyPlayer?.\(method)(\(json))"
        }
    }

    func send(_ command: Command) {
        guard let script = command.javaScript else { return }
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    func applyOptions() {
        guard loaded else { return }
        let a = max(0, min(total - 1, loopStart ?? 0))
        let b = max(0, min(total - 1, loopEnd ?? a))
        let start = min(a, b), end = max(a, b)
        if loopEnabled { loopStart = start; loopEnd = end }
        let speed = min(1.5, max(0.25, coordinator.bpm / max(1, originalBPM)))
        let options: [String: Any] = ["speed": speed, "track": selectedTrack, "solo": solo,
            "sound": notePlayer.isEnabled, "metronome": metronome.isEnabled,
            "loop": loopEnabled, "start": start, "end": end]
        send(.configure(options))
        var saved = options
        // Preserve an explicitly cleared range when reopening the file.
        saved["start"] = loopStart.map { _ in start + 1 }
        saved["end"] = loopEnd.map { _ in end + 1 }
        UserDefaults.standard.set(saved, forKey: settingsKey)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == "tabbuddy-gp",
              let state = message.body as? [String: Any] else { return }
        receive(state)
    }

    func receive(_ state: [String: Any]) {
        if !loaded, let count = state["total"] as? Int, count > 0 {
            loaded = true
            total = count
            originalBPM = max(1, state["tempo"] as? Double ?? 120)
            userBPM = originalBPM * savedSpeed
            coordinator.bpm = userBPM
            embedded = EmbeddedScoreMetadata.parseHeader(state["notices"] as? String ?? "")
                ?? EmbeddedScoreMetadata(title: state["title"] as? String, artist: state["artist"] as? String, copyright: state["copyright"] as? String)
            composer = state["composer"] as? String ?? ""
            arranger = state["arranger"] as? String ?? ""
            collection = state["collection"] as? String ?? ""
            tracks = (state["tracks"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? Int, let name = $0["name"] as? String else { return nil }
                return Track(id: id, name: name, tuning: $0["tuning"] as? String ?? "", capo: $0["capo"] as? Int ?? 0,
                             instrument: Instrument.fromMIDI(program: $0["program"] as? Int, percussion: $0["percussion"] as? Bool ?? false))
            }
            selectedTrack = tracks.contains(where: { $0.id == selectedTrack }) ? selectedTrack : (tracks.first?.id ?? 0)
            applyOptions()
        }
        let nextReady = state["ready"] as? Bool ?? false
        if ready != nextReady { ready = nextReady }
        let playing = state["playing"] as? Bool ?? false
        if coordinator.isPlaying != playing { coordinator.isPlaying = playing }
        let bar = state["bar"] as? Int ?? 0
        if coordinator.currentMeasureIndex != bar { coordinator.currentMeasureIndex = bar }
        let time = state["time"] as? Double ?? 0
        if elapsed != time { elapsed = time }
        let nextBeats = max(1, state["beats"] as? Int ?? 4)
        if beats != nextBeats { beats = nextBeats }
        let pass = state["loopPass"] as? Int ?? 0
        if pass > loopPass { loopPass = pass; coordinator.onLoopCompleted?() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == "tabbuddy-gp" ? .allow : .cancel)
    }
}

struct GuitarProScoreView: UIViewRepresentable {
    let url: URL
    let player: GuitarProPlayer

    final class Coordinator {
        var relay: GuitarProMessageRelay?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let pool = GuitarProWebViewPool.shared
        let shell = pool.take() ?? GuitarProWebViewPool.makeShell(warm: false)
        shell.handler.scoreURL = url
        shell.relay.target = player
        context.coordinator.relay = shell.relay
        player.webView = shell.webView
        shell.webView.navigationDelegate = player
        if shell.isWarm {
            // Runtime, font, and soundfont are already loaded: only the score.
            player.send(.loadScore)
        } else {
            shell.webView.load(URLRequest(url: URL(string: "tabbuddy-gp://player/index.html")!))
        }
        // Prepare the next open after this score has had time to render.
        pool.scheduleWarm()
        return shell.webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.disposePlayer?.()", completionHandler: nil)
        coordinator.relay?.target = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        view.stopLoading()
        view.navigationDelegate = nil
    }
}

/// Forwards the page's messages to the current player, so one web view can be
/// prepared before a score is chosen and handed to a player later.
final class GuitarProMessageRelay: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    /// The page has created its alphaTab runtime (fonts and soundfont may still be loading).
    private(set) var shellReady = false

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], body["shell"] as? Bool == true { shellReady = true }
        target?.userContentController(controller, didReceive: message)
    }
}

/// Keeps one Guitar Pro web view warm: alphaTab runtime parsed, Bravura font and
/// the soundfont loaded, no score. Opening a score then costs only the score load
/// instead of a cold web process start. Dropped on memory warnings and when its
/// web process ends; the next open falls back to a cold start.
@MainActor
final class GuitarProWebViewPool: NSObject, WKNavigationDelegate {
    static let shared = GuitarProWebViewPool()

    struct Shell {
        let webView: WKWebView
        let handler: GuitarProResourceHandler
        let relay: GuitarProMessageRelay
        let isWarm: Bool
    }

    private var warm: Shell?
    private var warmTask: Task<Void, Never>?
    private var memoryObserver: NSObjectProtocol?

    override init() {
        super.init()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.drop() }
            }
    }

    /// The warm shell when its runtime is ready; otherwise nil (a cold shell is cheaper
    /// than waiting on a half-started one).
    func take() -> Shell? {
        warmTask?.cancel(); warmTask = nil
        guard let shell = warm else { return nil }
        warm = nil
        guard shell.relay.shellReady else { discard(shell); return nil }
        shell.webView.navigationDelegate = nil
        return shell
    }

    func scheduleWarm(after seconds: Double = 2.0) {
        guard warm == nil, warmTask == nil else { return }
        warmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.warm == nil else { self?.warmTask = nil; return }
            let shell = Self.makeShell(warm: true)
            shell.webView.navigationDelegate = self
            shell.webView.load(URLRequest(url: URL(string: "tabbuddy-gp://player/index.html?warm=1")!))
            self.warm = shell
            self.warmTask = nil
        }
    }

    func drop() {
        warmTask?.cancel(); warmTask = nil
        if let shell = warm { warm = nil; discard(shell) }
    }

    private func discard(_ shell: Shell) {
        shell.webView.evaluateJavaScript("window.disposePlayer?.()", completionHandler: nil)
        shell.webView.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        shell.webView.stopLoading()
        shell.webView.navigationDelegate = nil
    }

    static func makeShell(warm: Bool) -> Shell {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let handler = GuitarProResourceHandler(scoreURL: nil)
        configuration.setURLSchemeHandler(handler, forURLScheme: "tabbuddy-gp")
        let relay = GuitarProMessageRelay()
        configuration.userContentController.add(relay, name: "player")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        return Shell(webView: view, handler: handler, relay: relay, isWarm: warm)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if warm?.webView === webView { drop() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == "tabbuddy-gp" ? .allow : .cancel)
    }
}

final class GuitarProResourceHandler: NSObject, WKURLSchemeHandler {
    /// The score served at `/score`; set before the page asks for it. Main thread only.
    var scoreURL: URL?
    /// Tasks still waiting for a response, so a stopped task is never answered.
    private var active = Set<ObjectIdentifier>()
    private static let readQueue = DispatchQueue(label: "GuitarProResourceHandler.read", qos: .userInitiated, attributes: .concurrent)

    init(scoreURL: URL?) { self.scoreURL = scoreURL }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "player" else {
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        let id = ObjectIdentifier(task)
        active.insert(id)
        let score = scoreURL
        // Reading the 1 MB runtime, the font, and the soundfont on the main thread
        // stalled the push animation; deliver on main, read elsewhere.
        Self.readQueue.async {
            let result = Result { try Self.read(path: url.path, scoreURL: score) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active.remove(id) != nil else { return }
                switch result {
                case .success(let (data, mime)):
                    task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                    task.didReceive(data)
                    task.didFinish()
                case .failure(let error):
                    task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    private static func read(path: String, scoreURL: URL?) throws -> (Data, String) {
        // Explicit allowlist prevents score content from accessing other local files.
        let types = ["/index.html": "text/html", "/player.js": "text/javascript",
                     "/player.css": "text/css", "/alphaTab.min.js": "text/javascript",
                     "/font/Bravura.woff2": "font/woff2", "/soundfont/sonivox.sf2": "application/octet-stream"]
        if path == "/score" {
            guard let scoreURL else { throw URLError(.fileDoesNotExist) }
            var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: scoreURL, options: [], error: nil) { readURL in
                result = Result { try Data(contentsOf: readURL) }
            }
            return (try result.get(), "application/octet-stream")
        }
        guard let type = types[path],
              let root = Bundle.main.url(forResource: "GuitarProAssets", withExtension: nil) else {
            throw URLError(.fileDoesNotExist)
        }
        return (try Data(contentsOf: root.appendingPathComponent(String(path.dropFirst()))), type)
    }
}
