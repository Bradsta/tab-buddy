//
//  ChordChangesDrill.swift
//  TabBuddy
//
//  One Minute Changes: alternate 2–4 chords for a timed run and count the
//  clean changes. With the microphone on, the Try it model's wait-mode cursor
//  does the hearing (each confidently heard chord turns green and moves the
//  cursor on); this file counts those hits from the outside, without changing
//  `TryItModel`. With the microphone off, a large +1 button counts by hand.
//  Every finished run is saved per chord set in `PracticeMemory`, so the
//  history (last, best, a sparkline of the last 20 runs) survives relaunches.
//

import Charts
import Combine
import SwiftUI

// MARK: - Spec

struct ChordChangesSpec: Hashable {
    var instrument: TutorInstrument
    /// 2...4 chords, in playing order.
    var chords: [Chord]
    var durationSec: Double = 60
    /// Tempo of the example and the passage strip (one change every two beats).
    var bpm: Double = 60

    static let chordCount: ClosedRange<Int> = 2...4
    /// JustinGuitar-style long-term aim for open-chord pairs on guitar.
    static let longTermPerMinute = 30.0

    var symbols: [String] { chords.map(\.symbol) }
    var isValid: Bool { Self.chordCount.contains(chords.count) }

    /// "C ↔ G" for a pair, "C → Am → F → G" for longer cycles.
    var title: String {
        let names = chords.map(\.displaySymbol)
        return names.count == 2 ? names.joined(separator: " ↔ ") : names.joined(separator: " → ")
    }

    var prompt: String {
        "Change between \(title) for \(Self.durationText(durationSec)). Count only changes where every note rings."
    }

    /// Beginner clean-changes-per-minute goal used by chapter drills.
    var goalPerMinute: Double { ExerciseGenerator.changesPerMinuteTarget(stage: nil, instrument: instrument) }

    var exerciseSpec: ExerciseSpec {
        ExerciseSpec(kind: .chordChanges, prompt: prompt, chords: symbols, bpm: bpm, durationSec: durationSec)
    }

    func exercise() throws -> GeneratedExercise {
        guard isValid else {
            throw ExerciseGenerationError(message: "A changes drill needs 2 to 4 chords, got \(chords.count)")
        }
        return try ExerciseGenerator.generate(exerciseSpec, context: .standard(instrument))
    }

    static func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s % 60 == 0 { return s == 60 ? "one minute" : "\(s / 60) minutes" }
        return "\(s) seconds"
    }
}

// MARK: - Counting

/// Counts clean chords from successive values of `TryItModel.heard`. In wait
/// mode each hit inserts one event id; the set is cleared when the cursor wraps
/// or marks are reset, so any growth is a new clean chord. A change is a clean
/// chord after the first one heard.
struct ChangesTally: Hashable {
    private(set) var cleanChords = 0
    private var lastCount = 0

    init(startingWith heard: Set<Int> = []) { lastCount = heard.count }

    var changes: Int { max(0, cleanChords - 1) }

    mutating func observe(heard: Set<Int>) {
        if heard.count > lastCount { cleanChords += heard.count - lastCount }
        lastCount = heard.count
    }
}

/// Timer and counter for one drill run. The microphone path listens through
/// the shared `TryItModel`; the manual path counts taps.
@MainActor
final class ChordChangesRun: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        /// Mic runs save on their own; manual runs wait for Save.
        case finished(count: Int, saved: Bool)
    }

    enum Counting: String, CaseIterable, Identifiable {
        case microphone, taps
        var id: String { rawValue }
        var title: String { self == .microphone ? "Listen" : "Tap to count" }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining: Double
    @Published private(set) var tally = ChangesTally()
    @Published private(set) var manualCount = 0
    @Published var counting: Counting
    @Published private(set) var notice: String?

    let durationSec: Double
    private var endDate: Date?
    private var ticker: Task<Void, Never>?
    private var heardSubscription: AnyCancellable?

    init(durationSec: Double, counting: Counting) {
        self.durationSec = durationSec
        self.remaining = durationSec
        self.counting = counting
    }

    var isRunning: Bool { phase == .running }

    /// Changes so far in this run.
    var count: Int { counting == .microphone ? tally.changes : manualCount }

    func start(model: TryItModel) async {
        guard phase != .running else { return }
        notice = nil
        tally = ChangesTally()
        manualCount = 0
        if counting == .microphone {
            model.stopPlayback()
            model.setListenMode(.wait)
            model.resetMarks()
            await model.startListening()
            guard model.listenState == .listening else {
                counting = .taps
                notice = model.listenState == .permissionDenied
                    ? "Microphone access is off, so this run counts taps. Tap +1 after each clean change."
                    : "The microphone did not start, so this run counts taps. Tap +1 after each clean change."
                startTimer(model: model)
                return
            }
            tally = ChangesTally(startingWith: model.heard)
            heardSubscription = model.$heard.sink { [weak self] heard in
                MainActor.assumeIsolated { self?.tally.observe(heard: heard) }
            }
        }
        startTimer(model: model)
    }

    private func startTimer(model: TryItModel) {
        phase = .running
        remaining = durationSec
        endDate = Date().addingTimeInterval(durationSec)
        ticker?.cancel()
        ticker = Task { @MainActor [weak self, weak model] in
            while !Task.isCancelled {
                guard let self else { return }
                let left = max(0, (self.endDate ?? .now).timeIntervalSinceNow)
                self.remaining = left
                if left <= 0 {
                    self.finish(model: model)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func tap() {
        guard phase == .running, counting == .taps else { return }
        manualCount += 1
    }

    func undoTap() {
        guard counting == .taps, manualCount > 0 else { return }
        switch phase {
        case .running: manualCount -= 1
        case .finished(_, let saved) where !saved:
            manualCount -= 1
            phase = .finished(count: manualCount, saved: false)
        default: break
        }
    }

    /// Time ran out (also called by tests).
    func finish(model: TryItModel?) {
        guard phase == .running else { return }
        ticker?.cancel()
        ticker = nil
        heardSubscription = nil
        remaining = 0
        let micRun = counting == .microphone
        if micRun, let model, model.isListening { model.stopListening() }
        phase = .finished(count: count, saved: false)
    }

    /// Stops early without saving (a partial run is not a fair score).
    func cancel(model: TryItModel?) {
        ticker?.cancel()
        ticker = nil
        heardSubscription = nil
        if counting == .microphone, let model, model.isListening { model.stopListening() }
        phase = .idle
        remaining = durationSec
    }

    func markSaved() {
        if case .finished(let count, _) = phase { phase = .finished(count: count, saved: true) }
    }

    func reset() {
        phase = .idle
        remaining = durationSec
        tally = ChangesTally()
        manualCount = 0
    }
}

// MARK: - View

struct ChordChangesDrillView: View {
    let spec: ChordChangesSpec
    @ObservedObject var memory: PracticeMemory

    var body: some View {
        if spec.isValid {
            ChordChangesDrillContent(spec: spec, memory: memory).id(spec)
        } else {
            TutorMessageRow(text: "Pick 2 to 4 chords to practice changing between them.",
                            systemImage: "hand.tap", tone: .neutral)
        }
    }
}

private struct ChordChangesDrillContent: View {
    let spec: ChordChangesSpec
    @ObservedObject var memory: PracticeMemory
    @StateObject private var model: TryItModel
    @StateObject private var run: ChordChangesRun
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(spec: ChordChangesSpec, memory: PracticeMemory) {
        self.spec = spec
        self.memory = memory
        var exercise: GeneratedExercise?
        var failure: String?
        do { exercise = try spec.exercise() } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        _model = StateObject(wrappedValue: TryItModel(exercise: exercise, generationError: failure, prompt: spec.prompt,
                                                      instrument: spec.instrument, bpm: spec.bpm,
                                                      listener: TutorListener(), player: TutorSequencePlayer.shared))
        _run = StateObject(wrappedValue: ChordChangesRun(durationSec: exercise?.durationSec ?? spec.durationSec,
                                                         counting: exercise == nil ? .taps : .microphone))
    }

    private var compact: Bool { sizeClass == .compact }
    private var history: [ChangesEntry] { memory.changesHistory(instrument: spec.instrument, chords: spec.symbols) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(spec.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(DS.fg1)
            Text(spec.prompt)
                .font(.body)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
            diagrams
            WidthReader { width in
                if TutorLayout.isWide(width) {
                    HStack(alignment: .top, spacing: 24) {
                        runPanel.frame(maxWidth: .infinity, alignment: .leading)
                        historyPanel.frame(width: TutorLayout.sidePanelWidth)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        runPanel
                        historyPanel
                    }
                }
            }
            TryItBox {
                TryItCardView(model: model, showsPrompt: false)
            }
            .disabled(run.isRunning)
            .opacity(run.isRunning ? 0.6 : 1)
        }
        .onDisappear { run.cancel(model: model) }
        .onChange(of: run.phase) { _, phase in
            // Mic runs save as soon as time is up.
            if case .finished(let count, false) = phase, run.counting == .microphone {
                save(count)
            }
        }
    }

    // MARK: Diagrams

    private var diagrams: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 140 : 180), spacing: 14)], alignment: .leading, spacing: 14) {
            ForEach(Array(spec.chords.enumerated()), id: \.offset) { _, chord in
                VStack(alignment: .leading, spacing: 6) {
                    Text(chord.displaySymbol)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(DS.fg1)
                    DiagramView(diagram: diagram(for: chord), instrument: spec.instrument,
                                highlightedMIDI: currentChord == chord.symbol ? model.highlightedMIDI : [])
                }
                .padding(12)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .strokeBorder(currentChord == chord.symbol && model.isListening ? DS.accent : DS.separator,
                                  lineWidth: currentChord == chord.symbol && model.isListening ? 2 : 1))
            }
        }
    }

    private var currentChord: String? { model.currentEvent?.chordName }

    private func diagram(for chord: Chord) -> Diagram {
        var d = ChordPracticeSpec(root: chord.root, quality: chord.quality).diagram(instrument: spec.instrument)
        d.caption = nil
        return d
    }

    // MARK: Run

    private var runPanel: some View {
        TutorCard {
            VStack(alignment: .leading, spacing: 14) {
                if model.supportsListening, !run.isRunning {
                    Picker("Counting", selection: $run.counting) {
                        ForEach(ChordChangesRun.Counting.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timeText)
                            .font(.system(size: compact ? 44 : 56, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(run.isRunning ? DS.accent : DS.fg1)
                            .contentTransition(.numericText())
                        Text("left").font(.caption).foregroundStyle(DS.fg3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(displayCount)")
                            .font(.system(size: compact ? 44 : 56, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DS.fg1)
                            .contentTransition(.numericText())
                        Text("clean changes").font(.caption).foregroundStyle(DS.fg3)
                    }
                }
                .accessibilityElement(children: .combine)

                if let notice = run.notice {
                    TutorMessageRow(text: notice, systemImage: "mic.slash", tone: .neutral)
                }

                switch run.phase {
                case .idle:
                    Button {
                        Task { await run.start(model: model) }
                    } label: {
                        Label("Start \(ChordChangesSpec.durationText(run.durationSec)) run", systemImage: "timer")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(TutorPrimaryButtonStyle())
                    .disabled(model.listenState == .starting)
                    Text(run.counting == .microphone
                         ? "The app listens and counts each chord it hears clearly after the first. It is silent while it listens."
                         : "Tap +1 after each change where every note rings.")
                        .font(.caption)
                        .foregroundStyle(DS.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                case .running:
                    if run.counting == .taps {
                        Button { run.tap() } label: {
                            Text("+1")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                        .buttonStyle(TutorPrimaryButtonStyle())
                        .keyboardShortcut(.space, modifiers: [])
                        .accessibilityLabel("Add one clean change")
                    } else {
                        InputLevelMeter(isActive: true) { model.listener.inputLevel }
                    }
                    HStack(spacing: 10) {
                        if run.counting == .taps {
                            Button { run.undoTap() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                                .buttonStyle(TutorSecondaryButtonStyle())
                                .disabled(run.manualCount == 0)
                        }
                        Button { run.cancel(model: model) } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(TutorSecondaryButtonStyle())
                    }
                    Text("Stopping early does not save the run.")
                        .font(.caption)
                        .foregroundStyle(DS.fg3)
                case .finished(let count, let saved):
                    Text(resultLine(count))
                        .font(.headline)
                        .foregroundStyle(DS.fg1)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if !saved {
                            Button { save(count) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                                .buttonStyle(TutorPrimaryButtonStyle())
                            Button { run.undoTap() } label: { Label("−1", systemImage: "minus") }
                                .buttonStyle(TutorSecondaryButtonStyle())
                                .disabled(run.manualCount == 0)
                                .accessibilityLabel("Remove one change")
                            Button("Discard") { run.reset() }
                                .buttonStyle(TutorSecondaryButtonStyle())
                        } else {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                                .font(.headline)
                            Spacer(minLength: 0)
                            Button { run.reset() } label: { Label("Go again", systemImage: "arrow.counterclockwise") }
                                .buttonStyle(TutorSecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var displayCount: Int {
        if case .finished(let count, _) = run.phase { return count }
        return run.count
    }

    private var timeText: String {
        let s = Int(run.remaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func resultLine(_ count: Int) -> String {
        let perMinute = run.durationSec > 0 ? Double(count) * 60 / run.durationSec : 0
        var line = "\(count) clean change\(count == 1 ? "" : "s")"
        if run.durationSec != 60 { line += " (\(Int(perMinute.rounded())) a minute)" }
        if let best = previousBest, perMinute > best { line += ". A new best." }
        return line
    }

    private var previousBest: Double? {
        // The history may already hold this run once saved; compare against earlier ones.
        let earlier = run.phase == .finished(count: displayCount, saved: true) ? history.dropLast() : history[...]
        return earlier.map(\.perMinute).max()
    }

    private func save(_ count: Int) {
        memory.recordChanges(instrument: spec.instrument, chords: spec.symbols, count: count, durationSec: run.durationSec)
        run.markSaved()
    }

    // MARK: History

    private var historyPanel: some View {
        let entries = history
        let recent = Array(entries.suffix(20))
        let goal = spec.goalPerMinute
        return TutorCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your changes").font(.headline).foregroundStyle(DS.fg1)
                if entries.isEmpty {
                    Text("No runs yet for these chords. Runs are saved on this device.")
                        .font(.subheadline)
                        .foregroundStyle(DS.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 18) {
                        stat("Last", entries.last.map { perMinuteText($0.perMinute) } ?? "–")
                        stat("Best", entries.map(\.perMinute).max().map(perMinuteText) ?? "–")
                        stat("Runs", "\(entries.count)")
                    }
                    if recent.count > 1 {
                        Chart {
                            ForEach(Array(recent.enumerated()), id: \.offset) { i, entry in
                                LineMark(x: .value("Run", i + 1), y: .value("Per minute", entry.perMinute))
                                    .foregroundStyle(DS.accent)
                                    .interpolationMethod(.monotone)
                                PointMark(x: .value("Run", i + 1), y: .value("Per minute", entry.perMinute))
                                    .foregroundStyle(DS.accent)
                                    .symbolSize(18)
                            }
                            RuleMark(y: .value("Goal", goal))
                                .foregroundStyle(DS.fg3)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                        .frame(height: 90)
                        .accessibilityLabel("Clean changes a minute over the last \(recent.count) runs")
                    }
                }
                Text(goalText(goal))
                    .font(.caption)
                    .foregroundStyle(DS.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(DS.fg1)
            Text(label).font(.caption).foregroundStyle(DS.fg3)
        }
        .accessibilityElement(children: .combine)
    }

    private func perMinuteText(_ value: Double) -> String {
        "\(Int(value.rounded()))/min"
    }

    private func goalText(_ goal: Double) -> String {
        var text = "A guide, not a test: about \(Int(goal)) clean changes a minute on a new pair"
        if spec.instrument == .guitar {
            text += ", working toward \(Int(ChordChangesSpec.longTermPerMinute)) over weeks of short daily runs."
        } else {
            text += "."
        }
        return text
    }
}
