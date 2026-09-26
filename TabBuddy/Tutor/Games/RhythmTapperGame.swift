//
//  RhythmTapperGame.swift
//  TabBuddy
//
//  Rhythm Tapper: a one-measure rhythm is shown; after a visual count-in
//  (the beat pulse keeps going) the player taps the pad or the space bar,
//  or plays on the instrument (onsets from the listener). Each note is
//  scored by its timing offset in milliseconds. Four measures per game;
//  levels go from quarter notes to syncopation.
//

import SwiftUI

// MARK: - Scoring

enum RhythmScoring {
    enum Grade: String, Hashable {
        case onBeat, close, loose, missed

        var points: Double {
            switch self {
            case .onBeat: return 100
            case .close: return 70
            case .loose: return 40
            case .missed: return 0
            }
        }

        var label: String {
            switch self {
            case .onBeat: return "On the beat"
            case .close: return "Close"
            case .loose: return "Loose"
            case .missed: return "Missed"
            }
        }
    }

    struct NoteResult: Hashable, Identifiable {
        var index: Int
        var expected: TimeInterval
        var offsetMs: Double?
        var grade: Grade
        var id: Int { index }
    }

    static let onBeatMs = 60.0
    static let closeMs = 120.0
    /// Points removed per extra tap.
    static let extraPenalty = 50.0

    /// Matching window (seconds): at most 220 ms and under half the smallest gap.
    static func window(onsetBeats: [Double], bpm: Double) -> TimeInterval {
        let spb = 60 / max(1, bpm)
        let gaps = zip(onsetBeats.dropFirst(), onsetBeats).map { ($0 - $1) * spb }
        let smallest = gaps.min() ?? spb
        return min(0.22, max(0.08, smallest * 0.45))
    }

    static func grade(offsetMs: Double, window: TimeInterval) -> Grade {
        let a = abs(offsetMs)
        if a <= onBeatMs { return .onBeat }
        if a <= closeMs { return .close }
        if a <= window * 1000 { return .loose }
        return .missed
    }

    /// Matches each expected onset to the nearest unused tap inside the window.
    /// Taps outside every window between the first and last onset count as extras.
    static func score(expected: [TimeInterval], taps: [TimeInterval], window: TimeInterval)
        -> (notes: [NoteResult], extras: Int) {
        var used = Set<Int>()
        var notes: [NoteResult] = []
        for (i, t) in expected.enumerated() {
            var best: Int?
            for (j, tap) in taps.enumerated() where !used.contains(j) && abs(tap - t) <= window {
                if best == nil || abs(tap - t) < abs(taps[best!] - t) { best = j }
            }
            if let best {
                used.insert(best)
                let offset = (taps[best] - t) * 1000
                notes.append(NoteResult(index: i, expected: t, offsetMs: offset, grade: grade(offsetMs: offset, window: window)))
            } else {
                notes.append(NoteResult(index: i, expected: t, offsetMs: nil, grade: .missed))
            }
        }
        guard let first = expected.first, let last = expected.last else { return (notes, 0) }
        let extras = taps.enumerated().filter { j, tap in
            !used.contains(j) && tap >= first - window && tap <= last + window
        }.count
        return (notes, extras)
    }

    /// 0...100 for one measure.
    static func roundScore(_ notes: [NoteResult], extras: Int) -> Double {
        guard !notes.isEmpty else { return 0 }
        let points = notes.map(\.grade.points).reduce(0, +) - Double(extras) * extraPenalty
        return max(0, min(100, points / Double(notes.count)))
    }
}

// MARK: - Model

@MainActor
final class RhythmTapperModel: GameModel {
    enum RoundState: Equatable { case countIn, performing, review }

    @Published var playOnInstrument = false
    @Published private(set) var patterns: [RhythmPattern] = []
    @Published private(set) var roundIndex = 0
    @Published private(set) var roundState: RoundState = .countIn
    /// Beat position in the measure (negative during the count-in).
    @Published private(set) var currentBeat: Double = -4
    @Published private(set) var noteResults: [RhythmScoring.NoteResult] = []
    @Published private(set) var roundScores: [Double] = []
    @Published private(set) var extras = 0
    @Published private(set) var tapCount = 0

    static let roundCount = 4
    static let countInBeats = 4
    /// Onsets closer than this to the previous one are the same note (strum, two detectors).
    static let onsetMerge: TimeInterval = 0.09
    static let reviewSeconds: TimeInterval = 2.2

    private var taps: [TimeInterval] = []
    private var measureStart: TimeInterval = 0
    private var reviewUntil: TimeInterval = 0
    private var allOffsets: [Double] = []
    private var seed: UInt64

    init(instrument: TutorInstrument, dependencies: GameDependencies, seed: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        self.seed = seed
        super.init(gameID: TutorGameID.rhythmTapper, instrument: instrument, dependencies: dependencies)
        countdownSeconds = 0
        patterns = GameContent.rhythmRounds(level: level, count: Self.roundCount, seed: seed)
    }

    // MARK: Hooks

    override var title: String { "Rhythm Tapper" }

    override var intro: GameIntro {
        GameIntro(
            howToPlay: [
                "Read the rhythm. Counts under each note show where it falls.",
                "Watch the four count-in beats, then tap each note on the big pad or the space bar. The pulse keeps the beat for you.",
                "Or switch to Playing and \(instrument == .guitar ? "strum muted strings or a chord" : "play any key") on each note.",
                "Four measures. Each note is timed in milliseconds.",
            ],
            trains: "Reading rhythms and keeping a steady pulse, so you land notes on time in real songs.",
            microphone: "Tapping needs no microphone. Playing listens through the microphone; your device stays silent.")
    }

    override var levelCount: Int { 4 }
    override func levelDetail(_ level: Int) -> String {
        GameContent.rhythmLevelDetail(level) + ", \(Int(GameContent.rhythmBPM(level: level))) BPM"
    }
    override var listensFromStart: Bool { playOnInstrument }
    override var supportsTapFallback: Bool { true }
    override func useTapFallback() { playOnInstrument = false }

    override var hud: [GameStat] {
        [GameStat(label: "Measure", value: "\(min(roundIndex + 1, Self.roundCount)) of \(Self.roundCount)"),
         GameStat(label: "Score", value: roundScores.isEmpty ? "–" : "\(Int(average.rounded()))")]
    }

    var bpm: Double { GameContent.rhythmBPM(level: level) }
    var secondsPerBeat: Double { 60 / bpm }
    var pattern: RhythmPattern? { patterns.indices.contains(roundIndex) ? patterns[roundIndex] : nil }
    var average: Double { roundScores.isEmpty ? 0 : roundScores.reduce(0, +) / Double(roundScores.count) }
    var pulseBeat: Int { Int(floor(currentBeat)) }

    override func levelDidChange() {
        patterns = GameContent.rhythmRounds(level: level, count: Self.roundCount, seed: seed)
    }

    override func resetGame() {
        seed &+= 1
        patterns = GameContent.rhythmRounds(level: level, count: Self.roundCount, seed: seed)
        roundIndex = 0
        roundScores = []
        allOffsets = []
        noteResults = []
        extras = 0
    }

    override func didBeginPlay() { startRound() }

    private func startRound() {
        taps = []
        tapCount = 0
        noteResults = []
        extras = 0
        measureStart = now + 0.3 + Double(Self.countInBeats) * secondsPerBeat
        currentBeat = -Double(Self.countInBeats)
        roundState = .countIn
        feedback = nil
    }

    override func gameTick(now t: TimeInterval) {
        guard let pattern else { return }
        switch roundState {
        case .countIn, .performing:
            let beat = (t - measureStart) / secondsPerBeat
            currentBeat = beat
            if beat >= 0, roundState == .countIn { roundState = .performing }
            // Room for late taps (and detector delay when playing).
            let grace = playOnInstrument ? 0.8 : 0.5
            if beat >= pattern.totalBeats && t - (measureStart + pattern.totalBeats * secondsPerBeat) >= grace {
                scoreRound()
            }
        case .review:
            currentBeat = (t - measureStart) / secondsPerBeat
            if t >= reviewUntil {
                if roundIndex + 1 >= patterns.count {
                    finish()
                } else {
                    roundIndex += 1
                    startRound()
                }
            }
        }
    }

    /// Screen pad or space bar.
    func tap() {
        guard phase == .playing, roundState != .review else { return }
        taps.append(now)
        tapCount += 1
    }

    override func handle(detected d: DetectedEvent) {
        guard playOnInstrument, roundState != .review else { return }
        if let last = taps.last, abs(d.time - last) < Self.onsetMerge { return }
        taps.append(d.time)
        tapCount += 1
    }

    var expectedTimes: [TimeInterval] {
        (pattern?.onsetBeats ?? []).map { measureStart + $0 * secondsPerBeat }
    }

    private func scoreRound() {
        guard let pattern else { return }
        let window = RhythmScoring.window(onsetBeats: pattern.onsetBeats, bpm: bpm)
        let scored = RhythmScoring.score(expected: expectedTimes, taps: taps, window: window)
        noteResults = scored.notes
        extras = scored.extras
        let score = RhythmScoring.roundScore(scored.notes, extras: scored.extras)
        roundScores.append(score)
        allOffsets += scored.notes.compactMap(\.offsetMs)
        roundState = .review
        reviewUntil = now + Self.reviewSeconds
        let onBeat = scored.notes.filter { $0.grade == .onBeat }.count
        if playOnInstrument && taps.isEmpty {
            feedback = .notSure("Nothing came through. Play a little louder or move closer to the device.")
        } else if score >= 85 {
            feedback = .good("\(onBeat) of \(scored.notes.count) on the beat")
        } else {
            let lean = Self.lean(scored.notes)
            feedback = .neutral("\(onBeat) of \(scored.notes.count) on the beat" + (lean.map { ". \($0)" } ?? ""), "metronome")
        }
    }

    /// "You tend to rush" / "…drag" from the median offset.
    static func lean(_ notes: [RhythmScoring.NoteResult]) -> String? {
        let offsets = notes.compactMap(\.offsetMs).sorted()
        guard offsets.count >= 2 else { return nil }
        let median = offsets[offsets.count / 2]
        if median < -35 { return "You tend to come in early" }
        if median > 35 { return "You tend to come in late" }
        return nil
    }

    override func makeResult() -> GameResult {
        let score = average.rounded()
        let heard = !playOnInstrument || !allOffsets.isEmpty
        var details: [String] = []
        if !allOffsets.isEmpty {
            let sorted = allOffsets.map(abs).sorted()
            details.append("Typical timing: within \(Int(sorted[sorted.count / 2].rounded())) ms of the beat.")
        }
        if let lean = Self.lean(allOffsets.enumerated().map {
            RhythmScoring.NoteResult(index: $0.offset, expected: 0, offsetMs: $0.element, grade: .close)
        }) {
            details.append(lean + ".")
        }
        let next: String
        if let hint = nextLevelHint(threshold: score >= 85) {
            next = hint
        } else if score < 60 {
            next = "Count out loud with the pulse (\"1 and 2 and\") before you tap, and clap the rhythm once slowly."
        } else {
            next = "Tap along with the count-in to lock in the pulse, then keep your hand moving on every beat."
        }
        return GameResult(score: score, scoreText: "\(Int(score))",
                          caption: "timing points out of 100 (\(playOnInstrument ? "played" : "tapped"))",
                          details: details, nextStep: next, unsure: !heard)
    }

    #if DEBUG
    override func debugFillPlay() {
        roundIndex = 1
        roundScores = [82]
        roundState = .performing
        currentBeat = 1.3
        tapCount = 2
    }
    #endif
}

// MARK: - View

struct RhythmTapperView: View {
    @StateObject private var model: RhythmTapperModel

    init(instrument: TutorInstrument, dependencies: @autoclosure @escaping () -> GameDependencies) {
        _model = StateObject(wrappedValue: RhythmTapperModel(instrument: instrument, dependencies: dependencies()))
    }

    init(model: @autoclosure @escaping () -> RhythmTapperModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        GameScreen(model: model, options: { options }, play: { wide in playArea(wide: wide) })
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            GameInputModePicker(title: "Answer by", playOnInstrument: $model.playOnInstrument)
            if model.phase == .intro, let pattern = model.patterns.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sample rhythm").font(.headline).foregroundStyle(DS.fg2)
                    RhythmStripView(model: RhythmStripModel(rhythm: pattern.tokens, beatsPerMeasure: 4),
                                    bpm: model.bpm)
                }
            }
        }
    }

    @ViewBuilder
    private func playArea(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 20 : 14) {
            HStack(spacing: 16) {
                BeatPulseView(beat: model.pulseBeat, beatsPerMeasure: 4, active: true)
                Text(stateLabel)
                    .font(wide ? .title2.weight(.semibold) : .headline)
                    .foregroundStyle(model.roundState == .countIn ? DS.accentStrong : DS.fg1)
                    .monospacedDigit()
            }
            if let pattern = model.pattern {
                TutorCard(padding: wide ? 18 : 12) {
                    GameRhythmStrip(pattern: pattern, currentBeat: model.currentBeat,
                                    results: model.roundState == .review ? model.noteResults : [])
                        .frame(height: wide ? 150 : 128)
                }
            }
            if model.roundState == .review {
                offsetsRow(wide: wide)
            }
            if model.playOnInstrument {
                TutorMessageRow(text: "Play on each note. Taps on the pad still count.", systemImage: "mic", tone: .neutral)
            }
            TapPad(wide: wide, enabled: model.roundState != .review) { model.tap() }
        }
    }

    private var stateLabel: String {
        switch model.roundState {
        case .countIn:
            let n = Int(floor(model.currentBeat)) + RhythmTapperModel.countInBeats + 1
            return n >= 1 ? "Count-in \(n)…" : "Get ready"
        case .performing: return model.playOnInstrument ? "Play!" : "Tap!"
        case .review: return model.extras > 0 ? "\(model.extras) extra tap\(model.extras == 1 ? "" : "s")" : "Measure done"
        }
    }

    private func offsetsRow(wide: Bool) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(model.noteResults) { note in
                VStack(spacing: 2) {
                    Text(note.offsetMs.map { String(format: "%+.0f ms", $0) } ?? "–")
                        .font((wide ? Font.headline : Font.subheadline).monospacedDigit())
                    Text(note.grade.label).font(.caption)
                }
                .foregroundStyle(color(note.grade))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(background(note.grade), in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func color(_ g: RhythmScoring.Grade) -> Color {
        switch g {
        case .onBeat: return .green
        case .close: return DS.accentStrong
        case .loose, .missed: return DS.fg2
        }
    }

    private func background(_ g: RhythmScoring.Grade) -> Color {
        switch g {
        case .onBeat: return Color.green.opacity(0.14)
        case .close: return DS.accentSofter
        case .loose, .missed: return DS.surfaceInset
        }
    }
}

/// Big touch-down pad (fires on finger down, not lift) plus the space bar.
struct TapPad: View {
    var wide: Bool
    var enabled: Bool
    var onTap: () -> Void
    @State private var pressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.radiusCard + 6, style: .continuous)
                .fill(pressed ? DS.accentSoft : DS.surface)
            RoundedRectangle(cornerRadius: DS.radiusCard + 6, style: .continuous)
                .strokeBorder(pressed ? DS.accent : DS.separatorStrong, lineWidth: 2)
            VStack(spacing: 8) {
                Image(systemName: "hand.tap.fill").font(.system(size: wide ? 44 : 34))
                Text("Tap here or press Space").font(wide ? .title3.weight(.semibold) : .headline)
            }
            .foregroundStyle(enabled ? DS.accentStrong : DS.fg3)
        }
        .frame(height: wide ? 220 : 160)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    if enabled { onTap() }
                }
                .onEnded { _ in pressed = false }
        )
        .background(KeyboardShortcutButton(key: .space) { if enabled { onTap() } })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tap pad")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { onTap() } }
    }
}

/// Rhythm symbols spaced by length with a moving playhead and, after a
/// measure, each note tinted by its timing grade.
struct GameRhythmStrip: View {
    var pattern: RhythmPattern
    var currentBeat: Double
    var results: [RhythmScoring.NoteResult]

    var body: some View {
        let model = RhythmStripModel(rhythm: pattern.tokens, beatsPerMeasure: 4)
        GeometryReader { proxy in
            let width = proxy.size.width - 40
            let x: (Double) -> CGFloat = { 20 + width * CGFloat(model.fraction(ofBeat: $0)) }
            ZStack(alignment: .topLeading) {
                ForEach(0..<4, id: \.self) { b in
                    Rectangle().fill(DS.separator).frame(width: 1, height: proxy.size.height - 20)
                        .position(x: x(Double(b)), y: proxy.size.height / 2)
                }
                let onsetIndex = sounded(model)
                ForEach(model.items) { item in
                    let grade = onsetIndex[item.index].flatMap { i in results.first { $0.index == i }?.grade }
                    VStack(spacing: 6) {
                        RhythmGlyph(event: item.event)
                            .foregroundStyle(tint(grade, active: isActive(item)))
                            .frame(width: 30, height: 60)
                        Text(item.count)
                            .font(.title3.monospacedDigit().weight(item.count.first?.isNumber == true ? .bold : .regular))
                            .foregroundStyle(item.event.isRest ? DS.fg3 : DS.fg2)
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: DS.radiusChip)
                        .fill(isActive(item) ? DS.accentSoft : .clear))
                    .position(x: x(item.startBeat) + 18, y: proxy.size.height / 2)
                }
                if currentBeat >= 0 && currentBeat <= model.totalBeats {
                    Capsule().fill(DS.accent)
                        .frame(width: 3, height: proxy.size.height - 10)
                        .position(x: x(currentBeat), y: proxy.size.height / 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
    }

    /// Item index → onset index (rests map to nil).
    private func sounded(_ model: RhythmStripModel) -> [Int?] {
        var n = 0
        return model.items.map { item in
            guard !item.event.isRest else { return nil }
            defer { n += 1 }
            return n
        }
    }

    private func isActive(_ item: RhythmStripModel.Item) -> Bool {
        results.isEmpty && currentBeat >= item.startBeat && currentBeat < item.startBeat + item.event.beats
    }

    private func tint(_ grade: RhythmScoring.Grade?, active: Bool) -> Color {
        switch grade {
        case .onBeat: return .green
        case .close: return DS.accentStrong
        case .loose, .missed: return DS.fg3
        case nil: return active ? DS.accentStrong : DS.fg1
        }
    }
}
