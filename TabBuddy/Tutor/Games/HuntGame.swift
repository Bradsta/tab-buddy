//
//  HuntGame.swift
//  TabBuddy
//
//  Fretboard Hunt (guitar) and Key Hunt (piano): play every octave of the
//  target note within 30 seconds. The microphone cannot tell strings apart,
//  so the game counts distinct pitches in range (guitar frets 0–12, piano
//  C2–C7) and lights every fret position of each pitch found. Finding them
//  all moves on to a new note; the score is the total found.
//

import SwiftUI

@MainActor
final class HuntGameModel: GameModel {
    @Published private(set) var target: PitchClass = PitchClass(0)
    @Published private(set) var targets: [Int] = []
    @Published private(set) var found: Set<Int> = []
    @Published private(set) var totalFound = 0
    @Published private(set) var clearedSets = 0

    /// Detections below this confidence are "not sure".
    static let minConfidence = 0.35
    static let gameDuration: TimeInterval = 30

    private var rng: SeededRandom
    private var seed: UInt64

    init(instrument: TutorInstrument, dependencies: GameDependencies, seed: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        self.seed = seed
        rng = SeededRandom(seed: seed)
        super.init(gameID: instrument == .guitar ? TutorGameID.fretboardHunt : TutorGameID.keyHunt,
                   instrument: instrument, dependencies: dependencies)
        pickTarget(first: true)
    }

    // MARK: Hooks

    override var title: String { instrument == .guitar ? "Fretboard Hunt" : "Key Hunt" }

    override var intro: GameIntro {
        let range = instrument == .guitar ? "on frets 0 to 12" : "from C2 to C7"
        return GameIntro(
            howToPlay: [
                "A note name appears, for example C.",
                "Play that note in as many different octaves as you can find \(range). Single notes, one at a time.",
                "Found them all? A new note appears. You have 30 seconds.",
            ],
            trains: instrument == .guitar
                ? "Knowing where each note lives on the neck, which makes reading, soloing, and finding chord roots faster."
                : "Finding a note by name anywhere on the keyboard, the base for reading music in both clefs.",
            microphone: "Listens through the microphone. Your device stays silent while you play.")
    }

    override var levelCount: Int { 2 }
    override func levelDetail(_ level: Int) -> String {
        level <= 1 ? "Natural notes (A to G)" : "All twelve notes, including sharps and flats"
    }
    override var duration: TimeInterval? { Self.gameDuration }
    override var listensFromStart: Bool { true }
    override var detectionSources: TutorListener.DetectionSources { .monophonic }

    override var hud: [GameStat] {
        [GameStat(label: "Find", value: GameContent.pitchClassName(target)),
         GameStat(label: "This note", value: "\(found.count) of \(targets.count)"),
         GameStat(label: "Score", value: "\(totalFound)")]
    }

    override func resetGame() {
        seed &+= 1   // "Play again" gets a new target order, as in the other games.
        rng = SeededRandom(seed: seed &+ UInt64(level))
        found = []
        totalFound = 0
        clearedSets = 0
        pickTarget(first: true)
    }

    override func levelDidChange() { pickTarget(first: true) }

    override func didBeginPlay() {
        feedback = .neutral("Find every \(GameContent.pitchClassName(target)).", "scope")
    }

    override func handle(detected d: DetectedEvent) {
        guard let (pitch, confidence) = zip(d.pitches, d.confidences).max(by: { $0.1 < $1.1 }) else { return }
        guard confidence >= Self.minConfidence else {
            feedback = .notSure()
            return
        }
        let name = TutorAudioHelpers.name(pitch)
        if targets.contains(pitch) {
            if found.insert(pitch).inserted {
                totalFound += 1
                if found.count == targets.count {
                    clearedSets += 1
                    let done = GameContent.pitchClassName(target)
                    pickTarget(first: false)
                    feedback = .good("All \(done)s found. Next: \(GameContent.pitchClassName(target))")
                } else {
                    feedback = .good("Found \(name)")
                }
            } else {
                feedback = .neutral("\(name) is already found. Try another octave.", "arrow.up.arrow.down")
            }
        } else if PitchClass(pitch) == target {
            let limit = instrument == .guitar ? "above fret 12" : "outside C2 to C7"
            feedback = .neutral("\(name) is \(limit). Try a lower octave.", "arrow.down")
        } else {
            feedback = .neutral("Heard \(name). Looking for \(GameContent.pitchClassName(target)).")
        }
    }

    override func makeResult() -> GameResult {
        var details: [String] = []
        if clearedSets > 0 { details.append("Found every octave of \(clearedSets) note\(clearedSets == 1 ? "" : "s").") }
        let missing = targets.filter { !found.contains($0) }.map { TutorAudioHelpers.name($0) }
        if !missing.isEmpty && totalFound > 0 {
            details.append("Still to find for \(GameContent.pitchClassName(target)): " + missing.joined(separator: ", "))
        }
        let next: String
        if let hint = nextLevelHint(threshold: totalFound >= 10) {
            next = hint
        } else if instrument == .guitar {
            next = "Learn the notes on the low E and A strings first; octave patterns (two strings up, two frets over) find the rest."
        } else {
            next = "Find every C first, then use C as a landmark: D is the next white key up, B the next one down."
        }
        return GameResult(score: Double(totalFound), scoreText: "\(totalFound)",
                          caption: "notes found in \(Int(Self.gameDuration)) seconds",
                          details: details, nextStep: next)
    }

    // MARK: Targets

    private func pickTarget(first: Bool) {
        let pool = GameContent.huntPitchClasses(level: level)
        if first, level <= 1 {
            target = PitchClass(0)   // Start with C, the landmark note.
        } else {
            let others = pool.filter { $0 != target }
            target = others.randomElement(using: &rng) ?? pool[0]
        }
        targets = GameContent.huntTargets(target, instrument: instrument)
        found = []
    }

    /// Guitar positions of every found pitch.
    var foundPositions: [FretPosition] {
        found.sorted().flatMap { GameContent.guitarPositions($0) }
    }

    #if DEBUG
    override func debugFillPlay() {
        found = Set(targets.prefix(2))
        totalFound = 7
        clearedSets = 2
        feedback = .good("Found \(TutorAudioHelpers.name(targets[1]))")
        debugSetRemaining(18)
    }
    #endif
}

struct HuntGameView: View {
    @StateObject private var model: HuntGameModel

    init(instrument: TutorInstrument, dependencies: @autoclosure @escaping () -> GameDependencies) {
        _model = StateObject(wrappedValue: HuntGameModel(instrument: instrument, dependencies: dependencies()))
    }

    init(model: @autoclosure @escaping () -> HuntGameModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        GameScreen(model: model, options: { EmptyView() }, play: { wide in playArea(wide: wide) })
    }

    @ViewBuilder
    private func playArea(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Find every")
                    .font(wide ? .title2 : .title3)
                    .foregroundStyle(DS.fg2)
                Text(GameContent.pitchClassName(model.target))
                    .font(.system(size: wide ? 64 : 44, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.accentStrong)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            octaveChips(wide: wide)
            TutorCard(padding: wide ? 16 : 10) {
                if model.instrument == .guitar {
                    FretboardView(model: FretboardDiagramModel(diagram: fretDiagram), instrument: .guitar)
                        .frame(height: wide ? 260 : 190)
                } else {
                    KeyboardView(model: KeyboardDiagramModel(diagram: keyDiagram))
                        .frame(height: wide ? 180 : 120)
                }
            }
        }
    }

    /// One chip per octave to find; filled when found.
    private func octaveChips(wide: Bool) -> some View {
        FlowLayout(spacing: 10) {
            ForEach(model.targets, id: \.self) { midi in
                let done = model.found.contains(midi)
                HStack(spacing: 6) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                    Text(done ? TutorAudioHelpers.name(midi) : "?")
                        .monospacedDigit()
                }
                .font(wide ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(done ? Color.green : DS.fg3)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(done ? Color.green.opacity(0.14) : DS.surfaceInset, in: Capsule())
                .accessibilityLabel(done ? "Found \(TutorAudioHelpers.name(midi))" : "Not found yet")
            }
        }
    }

    private var fretDiagram: Diagram {
        Diagram(kind: .fretboard, notes: model.foundPositions.map(\.notation), labels: .noteNames, fretRange: [0, 12])
    }

    private var keyDiagram: Diagram {
        let range = GameContent.huntRange(.piano)
        return Diagram(kind: .keyboard, notes: model.found.sorted().map { Pitch(midi: $0).name }, labels: .noteNames,
                       pitchRange: [Pitch(midi: range.lowerBound).name, Pitch(midi: range.upperBound).name])
    }
}
