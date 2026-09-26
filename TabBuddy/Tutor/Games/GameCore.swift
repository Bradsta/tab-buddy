//
//  GameCore.swift
//  TabBuddy
//
//  Shared state machine for the tutor games (TUTOR_IMPLEMENTATION.md §9):
//  intro → (microphone) → countdown → play → results, with personal bests
//  saved as `LessonProgressRecord`s. Audio and time go through seams
//  (`TutorListening`, `TutorSequencePlaying`, `GameClock`, `GameScoreStoring`)
//  so tests drive every game with fakes and call `tick()` by hand.
//
//  Rules every game follows:
//  - Output is muted while listening: stop listening before any playback.
//  - A detector result it cannot decide is shown as a neutral "not sure",
//    never as an error.
//  - Personal bests only; no streaks.
//

import Foundation
import QuartzCore
import SwiftUI

// MARK: - Seams

@MainActor
protocol GameClock: AnyObject {
    /// Monotonic seconds.
    var now: TimeInterval { get }
}

@MainActor
final class SystemGameClock: GameClock {
    var now: TimeInterval { CACurrentMediaTime() }
}

/// Where personal bests live. Higher scores are better for every game.
@MainActor
protocol GameScoreStoring: AnyObject {
    func best(for lessonID: String, instrument: TutorInstrument) -> Double?
    func record(_ score: Double, for lessonID: String, instrument: TutorInstrument)
}

/// Personal bests in the tutor store: one `LessonProgressRecord` per game,
/// instrument, and level. `bestScore` holds the game's own score (a count,
/// points, or BPM), not a 0...1 fraction; games never mark records completed.
@MainActor
final class TutorStoreGameScores: GameScoreStoring {
    let store: TutorStore

    init(store: TutorStore) { self.store = store }

    func best(for lessonID: String, instrument: TutorInstrument) -> Double? {
        guard let record = store.progress(lessonID: lessonID, instrument: instrument), record.attempts > 0 else { return nil }
        return record.bestScore
    }

    func record(_ score: Double, for lessonID: String, instrument: TutorInstrument) {
        _ = try? store.recordLessonAttempt(lessonID: lessonID, instrument: instrument, score: score, completed: false)
    }
}

/// Everything a game model needs from the outside world.
@MainActor
struct GameDependencies {
    var listener: TutorListening
    var player: TutorSequencePlaying
    var clock: GameClock
    var scores: GameScoreStoring

    /// Microphone, synth, wall clock, and the app's tutor store.
    static func live() -> GameDependencies {
        GameDependencies(listener: TutorListener(latencyStore: TutorShellLatency.store()),
                         player: TutorSequencePlayer.shared,
                         clock: SystemGameClock(),
                         scores: TutorStoreGameScores(store: .shared))
    }
}

// MARK: - Values

enum GamePhase: Equatable {
    case intro
    /// Opening the microphone.
    case starting
    /// Seconds left before play.
    case countdown(Int)
    case playing
    case results
    case micDenied
    case unavailable(String)

    var isActive: Bool {
        switch self {
        case .starting, .countdown, .playing: return true
        default: return false
        }
    }
}

struct GameFeedback: Equatable {
    var text: String
    var tone: TutorTone
    var systemImage: String

    static func good(_ text: String) -> GameFeedback { GameFeedback(text: text, tone: .good, systemImage: "checkmark.circle.fill") }
    static func neutral(_ text: String, _ image: String = "ear") -> GameFeedback { GameFeedback(text: text, tone: .neutral, systemImage: image) }
    static func notSure(_ text: String = "Not sure what I heard. Play it again and let it ring.") -> GameFeedback {
        GameFeedback(text: text, tone: .neutral, systemImage: "questionmark.circle")
    }
    static func tryAgain(_ text: String) -> GameFeedback { GameFeedback(text: text, tone: .caution, systemImage: "arrow.uturn.left") }
}

/// A heads-up-display value shown while playing.
struct GameStat: Hashable, Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

struct GameResult: Equatable {
    var score: Double
    /// Big number on the results card ("12", "84 BPM").
    var scoreText: String
    /// What the number counts ("clean changes in 60 seconds").
    var caption: String
    var details: [String] = []
    /// What to practice next.
    var nextStep: String
    /// The detector could not hear enough; shown neutrally and not saved.
    var unsure = false
    /// False for practice variants that do not keep a best (e.g. wait mode).
    var recordsBest = true
    var previousBest: Double? = nil
    var isNewBest = false
}

struct GameIntro: Equatable {
    var howToPlay: [String]
    var trains: String
    /// "Listens through the microphone" / "Tap to answer; no microphone needed".
    var microphone: String
}

// MARK: - Base model

/// Base class for every game. Subclasses override the hooks in "Game hooks".
@MainActor
class GameModel: ObservableObject {
    let gameID: String
    let instrument: TutorInstrument
    let listener: TutorListening
    let player: TutorSequencePlaying
    let clock: GameClock
    let scores: GameScoreStoring
    /// Runs a 30 Hz timer while a game is active. Tests turn it off and call `tick()`.
    var autoTick = true
    /// Seconds of visual countdown before play (0 skips it, e.g. games with a beat count-in).
    var countdownSeconds: Double = 3

    @Published private(set) var phase: GamePhase = .intro
    @Published var level: Int = 1 {
        didSet {
            guard level != oldValue else { return }
            levelDidChange()
            loadBest()
        }
    }
    @Published private(set) var best: Double?
    @Published private(set) var result: GameResult?
    @Published var feedback: GameFeedback?
    /// Seconds left for timed games.
    @Published private(set) var remaining: TimeInterval?

    private var countdownStart: TimeInterval = 0
    private(set) var playStart: TimeInterval = 0
    private var ticker: Task<Void, Never>?

    init(gameID: String, instrument: TutorInstrument, dependencies: GameDependencies) {
        self.gameID = gameID
        self.instrument = instrument
        listener = dependencies.listener
        player = dependencies.player
        clock = dependencies.clock
        scores = dependencies.scores
        loadBest()
    }

    // MARK: Game hooks (override)

    var title: String { gameID }
    var intro: GameIntro { GameIntro(howToPlay: [], trains: "", microphone: "") }
    var levelCount: Int { 1 }
    func levelName(_ level: Int) -> String { "Level \(level)" }
    func levelDetail(_ level: Int) -> String { "" }
    /// Long level names use a menu instead of a segmented control.
    var levelPickerIsMenu: Bool { false }
    /// Seconds per game, or nil for round-based games.
    var duration: TimeInterval? { nil }
    /// Open the microphone before the countdown.
    var listensFromStart: Bool { false }
    /// A tap alternative exists when the microphone is off.
    var supportsTapFallback: Bool { false }
    var detectionSources: TutorListener.DetectionSources { .all }
    var hud: [GameStat] { [] }
    func resetGame() {}
    func didBeginPlay() {}
    func gameTick(now: TimeInterval) {}
    func handle(detected: DetectedEvent) {}
    func handle(verification: VerificationResult) {}
    func makeResult() -> GameResult { GameResult(score: 0, scoreText: "0", caption: "", nextStep: "") }
    func formatScore(_ score: Double) -> String { String(Int(score.rounded())) }
    func levelDidChange() {}
    /// Switch to the tap alternative (mic off).
    func useTapFallback() {}

    // MARK: Derived

    /// Personal-best record id: `game.<id>.<instrument>`, plus `.level<n>`
    /// above level 1 so each level keeps a fair best.
    var scoreKey: String {
        let base = "game.\(gameID).\(instrument.rawValue)"
        return level > 1 ? base + ".level\(level)" : base
    }

    /// Time base: the listener's take clock while listening (detections use
    /// it), the wall clock otherwise.
    var now: TimeInterval { listener.isListening ? listener.takeClock : clock.now }

    var isListening: Bool { listener.isListening }
    var elapsed: TimeInterval { now - playStart }

    // MARK: Controls

    /// Starts a game from the intro, results, or an error state.
    func start() async {
        guard !phase.isActive else { return }
        stopTicker()
        player.stop()
        result = nil
        feedback = nil
        remaining = duration
        resetGame()
        if listensFromStart {
            phase = .starting
            guard await openMicrophone() else { return }
        }
        beginCountdown()
    }

    /// Ends the game now and shows the results for what was played.
    func endEarly() {
        guard phase.isActive else { return }
        if phase == .playing {
            finish()
        } else {
            cancel()
        }
    }

    /// Stops everything (view disappeared, Done).
    func cancel() {
        stopTicker()
        player.stop()
        closeMicrophone()
        if phase.isActive { phase = .intro }
        feedback = nil
    }

    /// Back to the intro card (change level or mode).
    func showIntro() {
        cancel()
        phase = .intro
        result = nil
    }

    // MARK: Microphone

    /// Opens the microphone; on failure moves to `.micDenied` / `.unavailable`.
    @discardableResult
    func openMicrophone() async -> Bool {
        if listener.isListening { return true }
        listener.onDetected = { [weak self] d in self?.receive(d) }
        listener.onVerification = { [weak self] r in self?.receive(r) }
        listener.detectionSources = detectionSources
        do {
            try await listener.start(profile: TutorAudioHelpers.profile(for: instrument), recordTake: false)
        } catch {
            stopTicker()
            phase = listener.isPermissionError(error) ? .micDenied : .unavailable(error.localizedDescription)
            return false
        }
        guard phase.isActive else {
            // Cancelled while the input was starting.
            listener.stop()
            return false
        }
        return true
    }

    func closeMicrophone() {
        guard listener.isListening else { return }
        listener.disarm()
        listener.stop()
    }

    private func receive(_ d: DetectedEvent) {
        guard phase == .playing else { return }
        handle(detected: d)
    }

    private func receive(_ r: VerificationResult) {
        guard phase == .playing else { return }
        handle(verification: r)
    }

    // MARK: Clock

    private func beginCountdown() {
        countdownStart = now
        if countdownSeconds > 0 {
            phase = .countdown(Int(ceil(countdownSeconds)))
        } else {
            beginPlay()
        }
        startTicker()
    }

    private func beginPlay() {
        phase = .playing
        playStart = now
        remaining = duration
        didBeginPlay()
    }

    /// Advances the countdown, the game timer, and the game's own clock.
    func tick() {
        let t = now
        switch phase {
        case .countdown:
            let left = countdownSeconds - (t - countdownStart)
            if left <= 0 {
                beginPlay()
            } else {
                let shown = Int(ceil(left))
                if phase != .countdown(shown) { phase = .countdown(shown) }
            }
        case .playing:
            if let duration {
                let left = max(0, duration - (t - playStart))
                remaining = left
                if left <= 0 { finish(); return }
            }
            gameTick(now: t)
        default:
            break
        }
    }

    private func startTicker() {
        guard autoTick else { return }
        stopTicker()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Results

    /// Scores the game, saves a personal best, and shows the results.
    func finish() {
        guard phase.isActive else { return }
        stopTicker()
        player.stop()
        closeMicrophone()
        var r = makeResult()
        let previous = best
        r.previousBest = previous
        if r.recordsBest && !r.unsure {
            r.isNewBest = r.score > 0 && r.score > (previous ?? 0)
            scores.record(r.score, for: scoreKey, instrument: instrument)
            if r.isNewBest { best = r.score }
        }
        result = r
        feedback = nil
        remaining = nil
        phase = .results
    }

    func loadBest() {
        best = scores.best(for: scoreKey, instrument: instrument)
    }

    /// Next-level hint used in results.
    func nextLevelHint(threshold: Bool) -> String? {
        guard threshold, level < levelCount else { return nil }
        return "Ready for more: try \(levelName(level + 1)) (\(levelDetail(level + 1).lowercased()))."
    }

    // MARK: DEBUG

    #if DEBUG
    /// Screenshot support: jump straight into a phase with sample state.
    func debugShow(_ phase: GamePhase) {
        self.phase = phase
        if phase == .playing { debugFillPlay() }
        if phase == .results {
            debugFillPlay()
            self.phase = .playing
            finish()
        }
    }

    func debugFillPlay() {}
    func debugSetRemaining(_ value: TimeInterval?) { remaining = value }
    #endif
}
