//
//  EarGames.swift
//  TabBuddy
//
//  Interval Duel and Name That Quality: ten rounds each. The synth plays the
//  sound with listening stopped; the player answers by tapping (keys 1–4)
//  or, in Interval Duel, by playing the upper note from the given root.
//  Space replays the sound, Return moves on.
//

import SwiftUI

@MainActor
final class EarGameModel: GameModel {
    enum Kind { case interval, quality }

    enum RoundState: Equatable {
        /// The synth is playing the sound.
        case hearing
        case answering
        case answered(correct: Bool, chosen: Int?, played: Int?)
    }

    let kind: Kind
    @Published var answerByPlaying = false
    @Published private(set) var rounds: [GameContent.EarRound] = []
    @Published private(set) var roundIndex = 0
    @Published private(set) var roundState: RoundState = .hearing
    @Published private(set) var outcomes: [Bool] = []
    @Published private(set) var playbackStep: Int?

    static let roundCount = 10
    private var seed: UInt64
    private var hearToken = 0

    init(kind: Kind, instrument: TutorInstrument, dependencies: GameDependencies,
         seed: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        self.kind = kind
        self.seed = seed
        super.init(gameID: kind == .interval ? TutorGameID.intervalDuel : TutorGameID.nameThatQuality,
                   instrument: instrument, dependencies: dependencies)
        countdownSeconds = 2
    }

    // MARK: Hooks

    override var title: String { kind == .interval ? "Interval Duel" : "Name That Quality" }

    override var intro: GameIntro {
        switch kind {
        case .interval:
            return GameIntro(
                howToPlay: [
                    "Listen to two notes. They play one after the other, and at level 3 sometimes together.",
                    "Name the distance between them: tap an answer or press 1 to 4.",
                    "Or switch to Playing: you see the lower note's name; play the upper note on your instrument.",
                    "Ten rounds. Press Space to hear it again.",
                ],
                trains: "Hearing intervals, the building blocks of melodies and chords. It helps you play by ear and tune your singing.",
                microphone: "Tap to answer: no microphone needed. Playing answers use the microphone after each sound.")
        case .quality:
            return GameIntro(
                howToPlay: [
                    "Listen to a chord, then its notes one at a time.",
                    "Decide its quality: major, minor, or at higher levels diminished, augmented, or dominant seventh.",
                    "Tap an answer or press its number. Ten rounds; Space replays the sound.",
                ],
                trains: "Recognizing chord colors by ear, so you can hear what a song is doing and pick chords for melodies.",
                microphone: "Tap to answer: no microphone needed.")
        }
    }

    override var levelCount: Int { 3 }
    override func levelDetail(_ level: Int) -> String {
        kind == .interval ? GameContent.intervalLevelDetail(level) : GameContent.qualityLevelDetail(level)
    }

    override var detectionSources: TutorListener.DetectionSources { .monophonic }
    override var supportsTapFallback: Bool { kind == .interval }
    override func useTapFallback() { answerByPlaying = false }

    override var hud: [GameStat] {
        [GameStat(label: "Round", value: "\(min(roundIndex + 1, Self.roundCount)) of \(Self.roundCount)"),
         GameStat(label: "Correct", value: "\(correctCount)")]
    }

    var correctCount: Int { outcomes.filter { $0 }.count }
    var round: GameContent.EarRound? { rounds.indices.contains(roundIndex) ? rounds[roundIndex] : nil }
    /// Playing answers apply to Interval Duel only.
    var playsAnswers: Bool { kind == .interval && answerByPlaying }

    override func resetGame() {
        seed &+= 1
        rounds = kind == .interval
            ? GameContent.intervalRounds(level: level, instrument: instrument, count: Self.roundCount, seed: seed)
            : GameContent.qualityRounds(level: level, instrument: instrument, count: Self.roundCount, seed: seed)
        roundIndex = 0
        outcomes = []
        roundState = .hearing
    }

    override func didBeginPlay() { hear() }

    // MARK: Actions

    /// Plays the round's sound (listening stops first; output is muted while listening).
    func hear() {
        guard phase == .playing, let round else { return }
        if case .answered = roundState { return }
        closeMicrophone()
        roundState = .hearing
        feedback = .neutral("Listen…")
        hearToken += 1
        let token = hearToken
        player.play(round.sequence, instrument: instrument, onStep: { [weak self] i in
            self?.playbackStep = i
        }, completion: { [weak self] in
            guard let self, token == self.hearToken, self.phase == .playing, self.roundState == .hearing else { return }
            self.playbackStep = nil
            self.roundState = .answering
            if self.playsAnswers {
                self.feedback = .neutral("Your turn: play the upper note.", "music.note")
                Task { await self.openMicrophone() }
            } else {
                self.feedback = nil
            }
        })
    }

    /// Space: replay while answering.
    func replay() {
        guard phase == .playing, roundState == .answering || roundState == .hearing else { return }
        player.stop()
        hear()
    }

    func choose(_ index: Int) {
        guard phase == .playing, roundState == .answering, let round else { return }
        resolve(correct: index == round.correctIndex, chosen: index, played: nil)
    }

    override func handle(detected d: DetectedEvent) {
        guard playsAnswers, roundState == .answering, let round, let root = round.root, let target = round.target else { return }
        guard let (pitch, confidence) = zip(d.pitches, d.confidences).max(by: { $0.1 < $1.1 }) else { return }
        guard confidence >= HuntGameModel.minConfidence else {
            feedback = .notSure("Not sure what I heard. Play the upper note again and let it ring.")
            return
        }
        if pitch == target {
            resolve(correct: true, chosen: nil, played: pitch)
        } else if pitch == root {
            feedback = .neutral("That is the lower note, \(TutorAudioHelpers.name(root)). Play the upper one.", "arrow.up")
        } else if PitchClass(pitch) == PitchClass(target) {
            // Right note name in another octave: the interval class is right.
            resolve(correct: true, chosen: nil, played: pitch)
        } else {
            resolve(correct: false, chosen: nil, played: pitch)
        }
    }

    private func resolve(correct: Bool, chosen: Int?, played: Int?) {
        guard let round else { return }
        player.stop()
        closeMicrophone()
        outcomes.append(correct)
        roundState = .answered(correct: correct, chosen: chosen, played: played)
        if correct {
            var text = "Yes: \(round.correctAnswer)."
            if let played, let target = round.target, played != target {
                text += " \(TutorAudioHelpers.name(played)) is the right note in another octave."
            }
            feedback = .good(text)
        } else if let played {
            feedback = .tryAgain("You played \(TutorAudioHelpers.name(played)). It was a \(round.correctAnswer.lowercased()).")
        } else {
            feedback = .tryAgain("It was \(round.correctAnswer.lowercased()).")
        }
    }

    /// Return: next round (or results after the last).
    func next() {
        guard phase == .playing, case .answered = roundState else { return }
        if roundIndex + 1 >= rounds.count {
            finish()
        } else {
            roundIndex += 1
            roundState = .hearing
            hear()
        }
    }

    /// Give up on a played answer (detector trouble): counts as not answered.
    func skipPlayedAnswer() {
        guard phase == .playing, roundState == .answering else { return }
        resolve(correct: false, chosen: nil, played: nil)
    }

    override func makeResult() -> GameResult {
        let correct = correctCount
        var missed: [String] = []
        for (i, ok) in outcomes.enumerated() where !ok && rounds.indices.contains(i) {
            let answer = rounds[i].correctAnswer
            if !missed.contains(answer) { missed.append(answer) }
        }
        var details: [String] = []
        if !missed.isEmpty { details.append("Missed: " + missed.joined(separator: ", ")) }
        let next: String
        if let hint = nextLevelHint(threshold: correct >= 9) {
            next = hint
        } else if let first = missed.first {
            next = kind == .interval
                ? "Link \(first.lowercased()) to a song you know, then play it on your instrument and sing it back."
                : "Play a \(first.lowercased()) chord and its major version back to back and listen for what changes."
        } else {
            next = "Every answer right. Try again with Playing answers to connect your ear to your hands."
        }
        return GameResult(score: Double(correct), scoreText: "\(correct)/\(Self.roundCount)",
                          caption: kind == .interval ? "intervals named" : "chord qualities named",
                          details: details, nextStep: next)
    }

    override func formatScore(_ score: Double) -> String { "\(Int(score.rounded()))/\(Self.roundCount)" }

    #if DEBUG
    override func debugFillPlay() {
        resetGame()
        outcomes = [true, true, false, true]
        roundIndex = 4
        roundState = .answered(correct: true, chosen: rounds[4].correctIndex, played: nil)
        feedback = .good("Yes: \(rounds[4].correctAnswer).")
    }
    #endif
}

struct EarGameView: View {
    @StateObject private var model: EarGameModel

    init(kind: EarGameModel.Kind, instrument: TutorInstrument,
         dependencies: @autoclosure @escaping () -> GameDependencies) {
        _model = StateObject(wrappedValue: EarGameModel(kind: kind, instrument: instrument, dependencies: dependencies()))
    }

    init(model: @autoclosure @escaping () -> EarGameModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        GameScreen(model: model, options: { options }, play: { wide in playArea(wide: wide) })
    }

    @ViewBuilder
    private var options: some View {
        if model.kind == .interval {
            GameInputModePicker(playOnInstrument: $model.answerByPlaying)
        }
    }

    @ViewBuilder
    private func playArea(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 20 : 14) {
            GameRoundDots(total: EarGameModel.roundCount, current: model.roundIndex,
                          outcomes: model.outcomes.map { Optional($0) })
            HStack(spacing: 14) {
                Button {
                    model.replay()
                } label: {
                    Label(model.roundState == .hearing ? "Playing…" : "Hear it again",
                          systemImage: model.roundState == .hearing ? "speaker.wave.2.fill" : "speaker.wave.2")
                }
                .buttonStyle(TutorSecondaryButtonStyle())
                .disabled(isAnswered)
                .keyboardShortcut(.space, modifiers: [])
                Spacer()
                if isAnswered {
                    Button {
                        model.next()
                    } label: {
                        Label(model.roundIndex + 1 >= EarGameModel.roundCount ? "See results" : "Next",
                              systemImage: "arrow.right")
                    }
                    .buttonStyle(TutorSecondaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            if let round = model.round {
                if model.playsAnswers, let root = round.root {
                    playedAnswerPanel(round: round, root: root, wide: wide)
                } else {
                    GameChoiceGrid(choices: round.choices, revealedCorrect: revealed(round), chosen: chosen,
                                   enabled: model.roundState == .answering, wide: wide) { model.choose($0) }
                }
                if isAnswered {
                    Text(round.explanation)
                        .font(wide ? .title3 : .body)
                        .foregroundStyle(DS.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func playedAnswerPanel(round: GameContent.EarRound, root: Int, wide: Bool) -> some View {
        TutorCard(padding: wide ? 24 : 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Lower note").font(.headline).foregroundStyle(DS.fg2)
                Text(TutorAudioHelpers.name(root))
                    .font(.system(size: wide ? 64 : 48, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.fg1)
                Text(isAnswered ? "Answer: \(round.correctAnswer), up to \(TutorAudioHelpers.name(round.target ?? root))."
                     : "Play the upper note you heard.")
                    .font(wide ? .title3 : .body)
                    .foregroundStyle(DS.fg2)
                if model.roundState == .answering {
                    Button("I can't find it") { model.skipPlayedAnswer() }
                        .buttonStyle(TutorSecondaryButtonStyle())
                }
            }
        }
    }

    private var isAnswered: Bool {
        if case .answered = model.roundState { return true }
        return false
    }

    private var chosen: Int? {
        if case .answered(_, let chosen, _) = model.roundState { return chosen }
        return nil
    }

    private func revealed(_ round: GameContent.EarRound) -> Int? {
        isAnswered ? round.correctIndex : nil
    }
}
