//
//  NoteRushGame.swift
//  TabBuddy
//
//  Note Rush: sight-reading for 60 seconds. A note appears on the staff
//  (treble clef at written pitch for guitar, which sounds an octave lower;
//  grand staff for piano); play it and the next one appears. The verifier
//  runs in wait mode on the note shown; level 1 accepts any octave. With the
//  microphone off, the tap variant names the note from four choices.
//

import SwiftUI

@MainActor
final class NoteRushModel: GameModel {
    @Published var playOnInstrument = true
    @Published private(set) var current: GameContent.RushNote
    @Published private(set) var correct = 0
    @Published private(set) var wrong = 0
    @Published private(set) var skipped = 0

    static let gameDuration: TimeInterval = 60
    private var rng: SeededRandom
    private var armedID = 0
    private var missedNames: [String] = []

    init(instrument: TutorInstrument, dependencies: GameDependencies, seed: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        var rng = SeededRandom(seed: seed)
        current = GameContent.rushNote(level: 1, instrument: instrument, avoiding: nil, using: &rng)
        self.rng = rng
        super.init(gameID: TutorGameID.noteRush, instrument: instrument, dependencies: dependencies)
    }

    // MARK: Hooks

    override var title: String { "Note Rush" }

    override var intro: GameIntro {
        let staff = instrument == .guitar
            ? "Guitar music is written an octave above where it sounds, so play the note an octave below the page, as usual."
            : "The grand staff: treble clef for the right hand, bass clef for the left."
        return GameIntro(
            howToPlay: [
                "A note appears on the staff.",
                "Play it. When it counts, the next note appears. Return skips a note.",
                "Read as many as you can in 60 seconds. \(staff)",
                "No microphone? Switch to Tapping and name each note (keys 1 to 4).",
            ],
            trains: "Reading notes on the staff quickly, the first step to playing from sheet music.",
            microphone: "Playing listens through the microphone; tapping needs none.")
    }

    override var levelCount: Int { 3 }
    override func levelDetail(_ level: Int) -> String { GameContent.rushLevelDetail(level, instrument: instrument) }
    override var duration: TimeInterval? { Self.gameDuration }
    override var listensFromStart: Bool { playOnInstrument }
    override var supportsTapFallback: Bool { true }
    override func useTapFallback() { playOnInstrument = false }
    override var detectionSources: TutorListener.DetectionSources { .verifier }

    override var hud: [GameStat] {
        [GameStat(label: "Read", value: "\(correct)")]
            + (skipped > 0 ? [GameStat(label: "Skipped", value: "\(skipped)")] : [])
    }

    /// Level 1 accepts the note in any octave.
    var anyOctave: Bool { level <= 1 }

    override func levelDidChange() { newNote() }

    override func resetGame() {
        correct = 0
        wrong = 0
        skipped = 0
        missedNames = []
        newNote()
    }

    override func didBeginPlay() { armCurrent() }

    private func newNote() {
        current = GameContent.rushNote(level: level, instrument: instrument, avoiding: current.written, using: &rng)
    }

    private func armCurrent() {
        guard playOnInstrument, phase == .playing else { return }
        armedID += 1
        let event = ExpectedEvent(id: armedID, pitches: [current.sounding], beat: 0, durationBeats: 1, measureIndex: 0,
                                  positionInMeasure: 0, octaveTolerant: anyOctave)
        listener.arm([event], window: .wait)
    }

    private func advance() {
        newNote()
        armCurrent()
    }

    override func handle(verification r: VerificationResult) {
        guard playOnInstrument, r.expectedID == armedID else { return }
        let name = displayName
        switch r.grade {
        case .hit:
            correct += 1
            feedback = .good("\(name) ✓")
            advance()
        case .uncertain:
            feedback = .notSure("Not sure. Play \(name) again and let it ring.")
        case .partial, .wrongPitch, .missed:
            wrong += 1
            if !missedNames.contains(name) { missedNames.append(name) }
            if let heard = r.unexpected.first {
                let hint = PitchClass(heard) == PitchClass(current.sounding) ? " Right name; check the octave." : ""
                feedback = .tryAgain("Heard \(TutorAudioHelpers.name(heard)).\(hint) Try again.")
            } else {
                feedback = .tryAgain("Not quite. Try again.")
            }
        }
    }

    /// Tap variant (keys 1–4).
    func choose(_ index: Int) {
        guard phase == .playing, !playOnInstrument else { return }
        let ok = index == current.correctIndex
        if ok {
            correct += 1
            feedback = .good("\(current.choices[index]) ✓")
        } else {
            wrong += 1
            let name = current.choices[current.correctIndex]
            if !missedNames.contains(name) { missedNames.append(name) }
            feedback = .tryAgain("That was \(name).")
        }
        advance()
    }

    /// Return: skip the note shown.
    func skip() {
        guard phase == .playing else { return }
        skipped += 1
        let name = displayName
        if !missedNames.contains(name) { missedNames.append(name) }
        feedback = .neutral("Skipped \(name).", "forward")
        advance()
    }

    /// Name shown after answering: with octave unless any octave counts.
    var displayName: String {
        let written = current.written
        guard !anyOctave else { return written.note.displayName }
        // Written spelling at the sounding octave (guitar sounds an octave below the page).
        return written.note.displayName + String(instrument == .guitar ? written.octave - 1 : written.octave)
    }

    override func makeResult() -> GameResult {
        let minutes = Self.gameDuration / 60
        var details: [String] = []
        if playOnInstrument {
            details.append("That is \(Int((Double(correct) / minutes).rounded())) notes a minute.")
        } else if correct + wrong > 0 {
            details.append("\(correct) of \(correct + wrong) named correctly.")
        }
        if !missedNames.isEmpty { details.append("Worth another look: " + missedNames.prefix(6).joined(separator: ", ")) }
        let next: String
        if let hint = nextLevelHint(threshold: correct >= 20) {
            next = hint
        } else if instrument == .guitar {
            next = "Learn the lines (E G B D F) and spaces (F A C E) of the treble clef, then find each note on the first four frets."
        } else {
            next = "Use landmarks: middle C, treble G (second line), and bass F (fourth line). Read other notes as steps from them."
        }
        return GameResult(score: Double(correct), scoreText: "\(correct)",
                          caption: "notes read in \(Int(Self.gameDuration)) seconds (\(playOnInstrument ? "played" : "named"))",
                          details: details, nextStep: next)
    }

    /// Tapping and playing keep separate bests.
    override var scoreKey: String { super.scoreKey + (playOnInstrument ? "" : ".tap") }

    #if DEBUG
    override func debugFillPlay() {
        correct = 11
        feedback = .good("E ✓")
        debugSetRemaining(34)
    }
    #endif
}

struct NoteRushView: View {
    @StateObject private var model: NoteRushModel

    init(instrument: TutorInstrument, dependencies: @autoclosure @escaping () -> GameDependencies) {
        _model = StateObject(wrappedValue: NoteRushModel(instrument: instrument, dependencies: dependencies()))
    }

    init(model: @autoclosure @escaping () -> NoteRushModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        GameScreen(model: model, options: { options }, play: { wide in playArea(wide: wide) })
            .onChange(of: model.playOnInstrument) { _, _ in model.loadBest() }
    }

    private var options: some View {
        GameInputModePicker(playOnInstrument: $model.playOnInstrument, tapLabel: "Tapping names", playLabel: "Playing")
    }

    @ViewBuilder
    private func playArea(wide: Bool) -> some View {
        let staff = TutorCard(padding: wide ? 20 : 12) {
            MiniStaffView(model: StaffDiagramModel(diagram: diagram, instrument: model.instrument))
                .frame(height: model.instrument == .piano ? (wide ? 300 : 230) : (wide ? 220 : 170))
                .id(model.current)
                .transition(.opacity)
        }
        let controls = VStack(alignment: .leading, spacing: 14) {
            if model.playOnInstrument {
                Text(model.anyOctave ? "Play this note (any octave)" : "Play this note")
                    .font(wide ? .title2.weight(.semibold) : .headline)
                    .foregroundStyle(DS.fg1)
            } else {
                GameChoiceGrid(choices: model.current.choices, revealedCorrect: nil, chosen: nil,
                               enabled: true, wide: false) { model.choose($0) }
            }
            Button {
                model.skip()
            } label: {
                Label("Skip", systemImage: "forward")
            }
            .buttonStyle(TutorSecondaryButtonStyle())
            .keyboardShortcut(.return, modifiers: [])
        }
        if wide {
            HStack(alignment: .top, spacing: 20) {
                staff.frame(maxWidth: .infinity)
                controls.frame(width: TutorLayout.sidePanelWidth)
            }
            .animation(DS.motionFast, value: model.current)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                staff
                controls
            }
            .animation(DS.motionFast, value: model.current)
        }
    }

    private var diagram: Diagram {
        Diagram(kind: .staff, notes: [model.current.written.name], labels: .none,
                caption: model.instrument == .piano ? "Grand staff" : "Treble clef")
    }
}
