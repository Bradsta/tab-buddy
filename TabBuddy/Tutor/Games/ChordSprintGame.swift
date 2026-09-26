//
//  ChordSprintGame.swift
//  TabBuddy
//
//  Chord Change Sprint: alternate two chords for 60 seconds. The verifier
//  runs in wait mode on the chord that is due; a clean strum of it counts
//  and arms the other chord. The first clean chord starts the count, so the
//  score is the number of clean changes. Piano is graded by pitch class, so
//  any voicing or inversion counts.
//

import SwiftUI

@MainActor
final class ChordSprintModel: GameModel {
    @Published var chords: [String] {
        didSet { if chords != oldValue { loadBest() } }
    }
    /// Index into `chords` of the chord that is due.
    @Published private(set) var currentIndex = 0
    @Published private(set) var cleanHits = 0
    @Published private(set) var changes = 0
    @Published private(set) var retries = 0

    static let gameDuration: TimeInterval = 60
    private var armedID = 0

    init(instrument: TutorInstrument, dependencies: GameDependencies) {
        chords = GameContent.defaultChordPair(instrument)
        super.init(gameID: TutorGameID.chordChangeSprint, instrument: instrument, dependencies: dependencies)
    }

    // MARK: Hooks

    override var title: String { "Chord Change Sprint" }

    override var intro: GameIntro {
        let bench = GameContent.chordBenchmark(instrument)
        let verb = instrument == .guitar ? "Strum" : "Play"
        return GameIntro(
            howToPlay: [
                "Pick two chords you know.",
                "\(verb) the highlighted chord once and let it ring. When it counts, the other chord lights up.",
                "Keep switching for 60 seconds. Every clean change scores a point.",
            ],
            trains: "Moving between chord fingerings without stopping, the skill that keeps songs flowing. "
                + "Many beginners start around \(bench.start) clean changes a minute; \(bench.goal) is a solid goal. Beat your own best, not the benchmark.",
            microphone: "Listens through the microphone. Your device stays silent while you play.")
    }

    override var duration: TimeInterval? { Self.gameDuration }
    override var listensFromStart: Bool { true }
    override var detectionSources: TutorListener.DetectionSources { .verifier }

    /// Bests are kept per chord pair (order does not matter).
    override var scoreKey: String {
        let pair = chords.sorted().joined(separator: "-").lowercased()
        return "game.\(gameID).\(instrument.rawValue)" + (pair == GameContent.defaultChordPair(instrument).sorted().joined(separator: "-").lowercased() ? "" : ".\(pair)")
    }

    override var hud: [GameStat] {
        [GameStat(label: "Changes", value: "\(changes)"),
         GameStat(label: "Per minute", value: perMinute.map { "\($0)" } ?? "–")]
    }

    var currentChord: String { chords[currentIndex] }
    var nextChord: String { chords[1 - currentIndex] }

    /// Changes per minute so far (after 10 seconds).
    var perMinute: Int? {
        guard phase == .playing, elapsed >= 10 else { return nil }
        return Int((Double(changes) / elapsed * 60).rounded())
    }

    override func resetGame() {
        currentIndex = 0
        cleanHits = 0
        changes = 0
        retries = 0
    }

    override func didBeginPlay() {
        arm()
        feedback = .neutral("\(instrument == .guitar ? "Strum" : "Play") \(currentChord).", "music.note")
    }

    override func handle(verification r: VerificationResult) {
        guard r.expectedID == armedID else { return }
        let name = currentChord
        switch r.grade {
        case .hit:
            cleanHits += 1
            if cleanHits > 1 { changes += 1 }
            currentIndex = 1 - currentIndex
            feedback = .good("\(name) ✓  Now \(currentChord)")
            arm()
        case .uncertain:
            feedback = .notSure("Not sure. \(instrument == .guitar ? "Strum" : "Play") \(name) again.")
        case .partial:
            retries += 1
            feedback = .tryAgain("Part of \(name) came through. Check that every note rings.")
        case .wrongPitch, .missed:
            retries += 1
            if !r.unexpected.isEmpty {
                let heard = r.unexpected.prefix(3).map { TutorAudioHelpers.name($0) }.joined(separator: " ")
                feedback = .tryAgain("Heard \(heard). Try \(name) again.")
            } else {
                feedback = .tryAgain("Not quite. Try \(name) again.")
            }
        }
    }

    private func arm() {
        armedID += 1
        guard let event = GameContent.chordEvent(currentChord, id: armedID, instrument: instrument) else { return }
        listener.arm([event], window: .wait)
    }

    override func makeResult() -> GameResult {
        let bench = GameContent.chordBenchmark(instrument)
        let pair = "\(chords[0]) and \(chords[1])"
        var details = ["Switching between \(pair)."]
        if retries > 0 { details.append("\(retries) strum\(retries == 1 ? "" : "s") needed a second try.") }
        let next: String
        switch changes {
        case ..<bench.start:
            next = instrument == .guitar
                ? "Practice the switch slowly: lift the fingers together and land them as a group. Find a finger that can stay on or slide."
                : "Practice the switch slowly and look for the notes both chords share; keep those fingers still."
        case ..<bench.goal:
            next = "Good pace. Aim for \(changes + 3) next time, and keep every note ringing."
        default:
            next = "That is fluent. Try a harder pair, such as \(instrument == .guitar ? "C and G" : "F and G")."
        }
        return GameResult(score: Double(changes), scoreText: "\(changes)",
                          caption: "clean changes in \(Int(Self.gameDuration)) seconds",
                          details: details, nextStep: next)
    }

    #if DEBUG
    override func debugFillPlay() {
        changes = 14
        cleanHits = 15
        currentIndex = 1
        feedback = .good("\(chords[0]) ✓  Now \(chords[1])")
        debugSetRemaining(27)
    }
    #endif
}

struct ChordSprintView: View {
    @StateObject private var model: ChordSprintModel

    init(instrument: TutorInstrument, dependencies: @autoclosure @escaping () -> GameDependencies) {
        _model = StateObject(wrappedValue: ChordSprintModel(instrument: instrument, dependencies: dependencies()))
    }

    init(model: @autoclosure @escaping () -> ChordSprintModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        GameScreen(model: model, options: { chordPicker }, play: { wide in playArea(wide: wide) })
    }

    private var chordPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chords").font(.headline).foregroundStyle(DS.fg2)
            HStack(spacing: 10) {
                chordMenu(0)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(DS.fg3)
                chordMenu(1)
            }
        }
    }

    private func chordMenu(_ slot: Int) -> some View {
        Menu {
            ForEach(GameContent.chordOptions(model.instrument).filter { $0 != model.chords[1 - slot] }, id: \.self) { symbol in
                Button(symbol) { model.chords[slot] = symbol }
            }
        } label: {
            Text(model.chords[slot])
                .font(.title3.weight(.semibold))
                .frame(minWidth: 64, minHeight: 48)
                .padding(.horizontal, 8)
                .background(DS.accentSofter, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                .foregroundStyle(DS.accentStrong)
        }
        .accessibilityLabel("Chord \(slot + 1): \(model.chords[slot])")
    }

    @ViewBuilder
    private func playArea(wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 12))
        layout {
            ForEach(0..<2, id: \.self) { i in
                chordCard(i, wide: wide)
            }
        }
    }

    private func chordCard(_ i: Int, wide: Bool) -> some View {
        let symbol = model.chords[i]
        let active = model.currentIndex == i
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(symbol)
                    .font(.system(size: wide ? 56 : 40, weight: .bold, design: .rounded))
                    .foregroundStyle(active ? DS.accentStrong : DS.fg3)
                Spacer()
                if active {
                    TutorStatusChip(text: model.instrument == .guitar ? "Strum now" : "Play now",
                                    systemImage: "hand.point.down", tone: .accent)
                }
            }
            if let diagram = chordDiagram(symbol) {
                DiagramView(diagram: diagram, instrument: model.instrument)
                    .frame(height: model.instrument == .guitar ? (wide ? 200 : 150) : (wide ? 150 : 110))
            }
        }
        .padding(wide ? 20 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? DS.accentSofter : DS.surface,
                    in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
            .strokeBorder(active ? DS.accent : DS.separator, lineWidth: active ? 2.5 : 1))
        .opacity(active ? 1 : 0.7)
        .animation(DS.motionFast, value: active)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(active ? "\(symbol), play now" : "\(symbol), next")
    }

    private func chordDiagram(_ symbol: String) -> Diagram? {
        guard let event = GameContent.chordEvent(symbol, id: 0, instrument: model.instrument) else { return nil }
        return Diagram.forEvent(pitches: event.pitches, fretting: event.fretting, chordName: symbol,
                                instrument: model.instrument)
    }
}
