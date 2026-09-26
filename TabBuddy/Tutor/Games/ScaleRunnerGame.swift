//
//  ScaleRunnerGame.swift
//  TabBuddy
//
//  Scale Runner: play a scale up and down in quarter notes at a target BPM,
//  following a visual count-in and beat pulse. A clean run (90% of notes on
//  time and in tune) raises the tempo by 6 BPM and the next run starts; the
//  ladder ends on the first run that is not clean. The score is the fastest
//  clean tempo. Runs the detector could not hear are repeated at the same
//  tempo. Wait mode is the untimed fallback: the cursor waits for each note
//  and no tempo best is kept.
//

import SwiftUI

@MainActor
final class ScaleRunnerModel: GameModel {
    enum NoteMark: Equatable { case hit, notSure, miss }

    enum RunState: Equatable {
        case countIn
        case running
        /// Between rungs: summary text, and whether the ladder climbs.
        case review(String, climbing: Bool)
    }

    @Published var waitMode = false
    @Published private(set) var bpm: Double = GameContent.scaleStartBPM
    @Published private(set) var runState: RunState = .countIn
    @Published private(set) var cursor = 0
    @Published private(set) var marks: [Int: NoteMark] = [:]
    @Published private(set) var currentBeat: Double = -4
    @Published private(set) var cleanRuns = 0
    @Published private(set) var highestCleanBPM: Double?
    @Published private(set) var lastAccuracy: Double?
    @Published private(set) var unsureRuns = 0

    static let cleanThreshold = 0.9
    static let countInBeats = 4
    static let reviewSeconds: TimeInterval = 2.5

    private var runIndex = 0
    private var passageStart: TimeInterval = 0
    private var reviewUntil: TimeInterval = 0
    private var waitMisses: [Int: Int] = [:]
    private var ladderEnded = false

    init(instrument: TutorInstrument, dependencies: GameDependencies) {
        super.init(gameID: TutorGameID.scaleRunner, instrument: instrument, dependencies: dependencies)
        countdownSeconds = 0
    }

    // MARK: Hooks

    override var title: String { "Scale Runner" }

    override var intro: GameIntro {
        GameIntro(
            howToPlay: [
                "Pick a scale. Its notes are shown in order, up and back down.",
                "Watch the four count-in beats, then play one note per beat with the pulse.",
                "A clean run raises the tempo by \(Int(GameContent.scaleStepBPM)) BPM and the next run starts. The ladder ends when a run is not clean.",
                "Wait mode lets you go at your own pace; it does not keep a tempo best.",
            ],
            trains: "Even, confident scale playing and gradual speed, the way teachers build technique: clean first, then faster.",
            microphone: "Listens through the microphone. Your device stays silent while you play.")
    }

    override var levelCount: Int { GameContent.scaleOptions(instrument).count }
    override func levelName(_ level: Int) -> String { option(level).scale.displayName }
    override var levelPickerIsMenu: Bool { true }
    override func levelDetail(_ level: Int) -> String { option(level).detail }
    override var listensFromStart: Bool { true }
    override var detectionSources: TutorListener.DetectionSources { .verifier }

    override var hud: [GameStat] {
        var stats = [GameStat(label: waitMode ? "Mode" : "Tempo", value: waitMode ? "Wait" : "\(Int(bpm)) BPM")]
        if !waitMode {
            stats.append(GameStat(label: "Clean runs", value: "\(cleanRuns)"))
        }
        stats.append(GameStat(label: "Note", value: "\(min(cursor + 1, notes.count)) of \(notes.count)"))
        return stats
    }

    override func formatScore(_ score: Double) -> String { "\(Int(score.rounded())) BPM" }

    func option(_ level: Int) -> GameContent.ScaleOption {
        let options = GameContent.scaleOptions(instrument)
        return options[max(0, min(options.count - 1, level - 1))]
    }

    var scaleOption: GameContent.ScaleOption { option(level) }
    var notes: [Int] { GameContent.scaleRun(scaleOption, instrument: instrument) }
    var secondsPerBeat: Double { 60 / bpm }
    var pulseBeat: Int { Int(floor(currentBeat)) }
    private var idBase: Int { runIndex * 1000 }

    override func resetGame() {
        bpm = GameContent.scaleStartBPM
        cleanRuns = 0
        highestCleanBPM = nil
        lastAccuracy = nil
        unsureRuns = 0
        runIndex = 0
        ladderEnded = false
    }

    override func didBeginPlay() { startRun() }

    private func startRun() {
        runIndex += 1
        marks = [:]
        waitMisses = [:]
        cursor = 0
        feedback = nil
        let passage = GameContent.scalePassage(notes, bpm: bpm, instrument: instrument, idBase: idBase)
        if waitMode {
            runState = .running
            currentBeat = 0
            listener.arm(passage.events, window: .wait)
            feedback = .neutral("Play \(TutorAudioHelpers.name(notes[0])). I'll wait for each note.", "music.note")
        } else {
            passageStart = now + 0.4 + Double(Self.countInBeats) * secondsPerBeat
            currentBeat = -Double(Self.countInBeats)
            runState = .countIn
            listener.armTimed(passage, passageStart: passageStart, tempoScale: 1, tolerance: tolerance)
        }
    }

    var tolerance: TimeInterval { min(0.3, max(0.12, 0.3 * secondsPerBeat)) }

    override func gameTick(now t: TimeInterval) {
        switch runState {
        case .countIn, .running:
            guard !waitMode else { return }
            let beat = (t - passageStart) / secondsPerBeat
            currentBeat = beat
            if beat >= 0, runState == .countIn { runState = .running }
            if beat >= 0 { cursor = min(notes.count - 1, Int(floor(beat + 0.5))) }
            // After the last window closes (plus time for the verifier to report).
            if beat > Double(notes.count - 1) + tolerance / secondsPerBeat + 0.6 / secondsPerBeat {
                endTimedRun()
            }
        case .review:
            if t >= reviewUntil {
                if ladderEnded { finish() } else { startRun() }
            }
        }
    }

    override func handle(verification r: VerificationResult) {
        let index = r.expectedID - idBase
        guard notes.indices.contains(index) else { return }
        if waitMode {
            handleWait(r, index: index)
            return
        }
        switch r.grade {
        case .hit: marks[index] = .hit
        case .uncertain: if marks[index] != .hit { marks[index] = .notSure }
        case .partial, .wrongPitch, .missed: if marks[index] != .hit { marks[index] = .miss }
        }
    }

    private func handleWait(_ r: VerificationResult, index: Int) {
        guard runState == .running, index == cursor else { return }
        let name = TutorAudioHelpers.name(notes[index])
        switch r.grade {
        case .hit:
            marks[index] = (waitMisses[index] ?? 0) <= 1 ? .hit : .miss
            cursor += 1
            if cursor >= notes.count {
                endWaitRun()
            } else {
                feedback = .good("\(name) ✓  Next \(TutorAudioHelpers.name(notes[cursor]))")
            }
        case .uncertain:
            feedback = .notSure("Not sure. Play \(name) again and let it ring.")
        case .partial, .wrongPitch, .missed:
            waitMisses[index, default: 0] += 1
            if let heard = r.unexpected.first {
                feedback = .tryAgain("Heard \(TutorAudioHelpers.name(heard)). Try \(name).")
            } else {
                feedback = .tryAgain("Not quite. Try \(name).")
            }
        }
    }

    /// Scores a timed run; climbs, repeats (not sure), or ends the ladder.
    func endTimedRun() {
        guard !waitMode else { return }
        if case .review = runState { return }
        listener.disarm()
        let n = notes.count
        let hits = (0..<n).filter { marks[$0] == .hit }.count
        let unsure = (0..<n).filter { marks[$0] == .notSure }.count
        let decided = n - unsure
        let accuracy = decided > 0 ? Double(hits) / Double(decided) : 0
        let tempo = Int(bpm)
        if decided * 2 < n {
            unsureRuns += 1
            if unsureRuns >= 3 {
                ladderEnded = true
                runState = .review("I could not hear enough to grade. Move closer to the device and try again.", climbing: false)
            } else {
                runState = .review("Not sure what I heard. Same tempo again.", climbing: false)
            }
            feedback = .notSure("Not sure what I heard. Let each note ring a little.")
        } else if accuracy + 1e-9 >= Self.cleanThreshold {
            lastAccuracy = accuracy
            cleanRuns += 1
            highestCleanBPM = bpm
            if bpm + GameContent.scaleStepBPM > GameContent.scaleMaxBPM {
                ladderEnded = true
                runState = .review("Clean at \(tempo) BPM, the top of the ladder.", climbing: false)
            } else {
                bpm += GameContent.scaleStepBPM
                runState = .review("Clean run at \(tempo) BPM. Next: \(Int(bpm)) BPM", climbing: true)
            }
            feedback = .good("\(hits) of \(n) notes clean at \(tempo) BPM")
        } else {
            lastAccuracy = accuracy
            ladderEnded = true
            runState = .review("\(hits) of \(n) clean at \(tempo) BPM. The ladder stops here.", climbing: false)
            feedback = .neutral("\(hits) of \(n) notes clean at \(tempo) BPM", "metronome")
        }
        reviewUntil = now + Self.reviewSeconds
    }

    private func endWaitRun() {
        listener.disarm()
        let clean = marks.values.filter { $0 == .hit }.count
        lastAccuracy = Double(clean) / Double(max(1, notes.count))
        ladderEnded = true
        finish()
    }

    override func makeResult() -> GameResult {
        let scale = scaleOption.scale.displayName
        if waitMode {
            let clean = marks.values.filter { $0 == .hit }.count
            let done = cursor >= notes.count
            return GameResult(score: Double(clean), scoreText: "\(clean)/\(notes.count)",
                              caption: "notes clean in \(scale)\(done ? "" : " (stopped early)")",
                              details: ["Clean means found with at most one retry."],
                              nextStep: clean >= notes.count - 1
                                ? "Turn off wait mode and start the tempo ladder at \(Int(GameContent.scaleStartBPM)) BPM."
                                : "Say each note name before you play it, then run the scale again in wait mode.",
                              recordsBest: false)
        }
        var details = ["\(cleanRuns) clean run\(cleanRuns == 1 ? "" : "s") in \(scale)."]
        if let acc = lastAccuracy { details.append("Last run: \(Int((acc * 100).rounded()))% of notes clean.") }
        let score = highestCleanBPM ?? 0
        let next: String
        if let top = highestCleanBPM {
            next = "Practice at \(Int(top)) BPM until it feels easy, then climb again. Speed follows clean playing."
        } else {
            next = "Try wait mode to learn the notes, then come back to the ladder at \(Int(GameContent.scaleStartBPM)) BPM."
        }
        let unsure = highestCleanBPM == nil && unsureRuns > 0 && lastAccuracy == nil
        return GameResult(score: score, scoreText: highestCleanBPM.map { "\(Int($0)) BPM" } ?? "–",
                          caption: "fastest clean run", details: details, nextStep: next, unsure: unsure)
    }

    #if DEBUG
    override func debugFillPlay() {
        bpm = 72
        cleanRuns = 2
        highestCleanBPM = 66
        runState = .running
        currentBeat = 5.2
        cursor = 5
        marks = [0: .hit, 1: .hit, 2: .hit, 3: .hit, 4: .notSure]
    }
    #endif
}

struct ScaleRunnerView: View {
    @StateObject private var model: ScaleRunnerModel

    init(instrument: TutorInstrument, dependencies: @autoclosure @escaping () -> GameDependencies) {
        _model = StateObject(wrappedValue: ScaleRunnerModel(instrument: instrument, dependencies: dependencies()))
    }

    init(model: @autoclosure @escaping () -> ScaleRunnerModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        GameScreen(model: model, options: { options }, play: { wide in playArea(wide: wide) })
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.waitMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wait for me").font(.headline).foregroundStyle(DS.fg1)
                    Text("No tempo: the next note waits until you play this one.")
                        .font(.callout).foregroundStyle(DS.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(DS.accent)
        }
    }

    @ViewBuilder
    private func playArea(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 20 : 14) {
            if !model.waitMode {
                HStack(spacing: 16) {
                    BeatPulseView(beat: model.pulseBeat, beatsPerMeasure: 4, active: true)
                    Text(stateLabel)
                        .font(wide ? .title2.weight(.semibold) : .headline)
                        .foregroundStyle(DS.fg1)
                }
            }
            noteStrip(wide: wide)
            TutorCard(padding: wide ? 16 : 10) {
                DiagramView(diagram: diagram, instrument: model.instrument,
                            highlightedMIDI: model.notes.indices.contains(model.cursor) ? [model.notes[model.cursor]] : [])
                    .frame(height: model.instrument == .guitar ? (wide ? 220 : 170) : (wide ? 150 : 110))
            }
        }
    }

    private var stateLabel: String {
        switch model.runState {
        case .countIn:
            let n = Int(floor(model.currentBeat)) + ScaleRunnerModel.countInBeats + 1
            return n >= 1 ? "Count-in \(n)… \(Int(model.bpm)) BPM" : "Get ready"
        case .running: return "Play with the pulse"
        case .review(let text, _): return text
        }
    }

    private func noteStrip(wide: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.notes.enumerated()), id: \.offset) { i, midi in
                        let mark = model.marks[i]
                        let current = i == model.cursor && model.runState == .running
                        Text(noteName(midi))
                            .font((wide ? Font.title3 : Font.headline).weight(.semibold).monospacedDigit())
                            .foregroundStyle(foreground(mark, current: current))
                            .frame(minWidth: wide ? 64 : 52, minHeight: wide ? 56 : 46)
                            .background(background(mark, current: current),
                                        in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                                .strokeBorder(current ? DS.accent : .clear, lineWidth: 2))
                            .id(i)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: model.cursor) { _, new in
                withAnimation(DS.motionFast) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// Spelled as in the scale ("F♯4" in G major).
    private func noteName(_ midi: Int) -> String {
        let spelled = model.scaleOption.scale.notes.first { $0.pitchClass == PitchClass(midi) } ?? PitchClass(midi).spelled()
        return Pitch(midi: midi, spelled: spelled)?.displayName ?? TutorAudioHelpers.name(midi)
    }

    private func foreground(_ mark: ScaleRunnerModel.NoteMark?, current: Bool) -> Color {
        switch mark {
        case .hit: return .green
        case .notSure, .miss: return DS.fg2
        case nil: return current ? DS.accentStrong : DS.fg1
        }
    }

    private func background(_ mark: ScaleRunnerModel.NoteMark?, current: Bool) -> Color {
        switch mark {
        case .hit: return Color.green.opacity(0.14)
        case .notSure, .miss: return DS.surfaceInset
        case nil: return current ? DS.accentSofter : DS.surface
        }
    }

    private var diagram: Diagram {
        let option = model.scaleOption
        switch model.instrument {
        case .guitar:
            let positions = GameContent.scalePassage(model.notes, bpm: model.bpm, instrument: .guitar)
                .events.compactMap { $0.fretting?.first }
            let frets = positions.map(\.fret)
            let hi = max(4, frets.max() ?? 4)
            let lo = hi > 5 ? max(0, (frets.filter { $0 > 0 }.min() ?? 1) - 1) : 0
            return Diagram(kind: .fretboard, scale: option.scale.name, notes: Array(Set(positions.map(\.notation))).sorted(),
                           labels: .noteNames, fretRange: [lo, max(lo + 4, hi)])
        case .piano:
            let range = KeyboardLayout.fitting(model.notes)
            return Diagram(kind: .keyboard, scale: option.scale.name,
                           notes: Array(Set(model.notes)).sorted().map { Pitch(midi: $0).name }, labels: .noteNames,
                           pitchRange: [Pitch(midi: range.lowestMIDI).name, Pitch(midi: range.highestMIDI).name])
        }
    }
}
