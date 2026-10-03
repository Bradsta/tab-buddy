//
//  TutorGamesCatalog.swift
//  TabBuddy
//
//  The games package hook for the Games shelf (see TutorGameRegistry.swift),
//  plus DEBUG launch arguments for checking game screens directly:
//
//    -TutorOpen -TutorGame rhythm-tapper       open that game
//    -TutorInstrument piano                    instrument (default: guitar,
//                                              or the only one the game supports)
//    -TutorGamePhase play|results|interrupted  sample state, fake audio, and an
//                                              in-memory score store
//    -TutorForceWidth 500                      narrow column (Split View check)
//

import SwiftUI

extension TutorGames {
    @MainActor
    static func destination(for id: String, instrument: TutorInstrument) -> AnyView? {
        view(for: id, instrument: instrument, dependencies: .live())
    }

    /// The game screen for an id, or nil for unknown ids.
    @MainActor
    static func view(for id: String, instrument: TutorInstrument,
                     dependencies: @autoclosure @escaping () -> GameDependencies) -> AnyView? {
        switch id {
        case TutorGameID.fretboardHunt, TutorGameID.keyHunt:
            return AnyView(HuntGameView(instrument: instrument, dependencies: dependencies()))
        case TutorGameID.chordChangeSprint:
            return AnyView(ChordSprintView(instrument: instrument, dependencies: dependencies()))
        case TutorGameID.intervalDuel:
            return AnyView(EarGameView(kind: .interval, instrument: instrument, dependencies: dependencies()))
        case TutorGameID.nameThatQuality:
            return AnyView(EarGameView(kind: .quality, instrument: instrument, dependencies: dependencies()))
        case TutorGameID.rhythmTapper:
            return AnyView(RhythmTapperView(instrument: instrument, dependencies: dependencies()))
        case TutorGameID.scaleRunner:
            return AnyView(ScaleRunnerView(instrument: instrument, dependencies: dependencies()))
        case TutorGameID.noteRush:
            return AnyView(NoteRushView(instrument: instrument, dependencies: dependencies()))
        default:
            return nil
        }
    }
}

// MARK: - DEBUG launch

enum TutorGameDebugLaunch {
    /// The game requested by `-TutorGame`, or nil (always nil in Release).
    @MainActor
    static func overrideView() -> AnyView? {
        #if DEBUG
        guard let id = TutorLessonDebugLaunch.value(after: "-TutorGame"),
              let entry = TutorGameRegistry.entries.first(where: { $0.id == id }) else { return nil }
        let requested = TutorLessonDebugLaunch.value(after: "-TutorInstrument").flatMap(TutorInstrument.init(rawValue:))
        let instrument = requested.flatMap { entry.instruments.contains($0) ? $0 : nil }
            ?? (entry.instruments.contains(.guitar) ? .guitar : .piano)
        let phase = TutorLessonDebugLaunch.value(after: "-TutorGamePhase")
        return AnyView(ForcedWidth(width: TutorLessonDebugLaunch.forcedWidth) {
            DebugGameHost(entry: entry, instrument: instrument, phase: phase)
        })
        #else
        return nil
        #endif
    }
}

#if DEBUG

private struct DebugGameHost: View {
    let entry: TutorGameEntry
    let instrument: TutorInstrument
    let phase: String?
    @State private var shown = false

    var body: some View {
        // Presented like the Games shelf does (full screen, own NavigationStack);
        // a NavigationStack nested inside the pushed Tutor page would not push.
        Button("Open \(entry.title)") { shown = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.paper)
            .onAppear { shown = true }
            .fullScreenCover(isPresented: $shown) {
                NavigationStack {
                    content
                        .navigationTitle(entry.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Done") { shown = false } }
                        }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let phase {
            let deps = DebugGameDependencies.make()
            DebugPhaseView(id: entry.id, instrument: instrument, phase: phase, dependencies: deps)
        } else {
            TutorGames.destination(for: entry.id, instrument: instrument) ?? AnyView(Text("Unavailable"))
        }
    }
}

/// Builds the model directly so it can be put into a sample phase.
private struct DebugPhaseView: View {
    let id: String
    let instrument: TutorInstrument
    let phase: String
    let dependencies: GameDependencies

    var body: some View {
        switch id {
        case TutorGameID.fretboardHunt, TutorGameID.keyHunt:
            HuntGameView(model: prepared(HuntGameModel(instrument: instrument, dependencies: dependencies, seed: 7)))
        case TutorGameID.chordChangeSprint:
            ChordSprintView(model: prepared(ChordSprintModel(instrument: instrument, dependencies: dependencies)))
        case TutorGameID.intervalDuel:
            EarGameView(model: prepared(EarGameModel(kind: .interval, instrument: instrument, dependencies: dependencies, seed: 7)))
        case TutorGameID.nameThatQuality:
            EarGameView(model: prepared(EarGameModel(kind: .quality, instrument: instrument, dependencies: dependencies, seed: 7)))
        case TutorGameID.rhythmTapper:
            RhythmTapperView(model: prepared(RhythmTapperModel(instrument: instrument, dependencies: dependencies, seed: 7)))
        case TutorGameID.scaleRunner:
            ScaleRunnerView(model: prepared(ScaleRunnerModel(instrument: instrument, dependencies: dependencies)))
        case TutorGameID.noteRush:
            NoteRushView(model: prepared(NoteRushModel(instrument: instrument, dependencies: dependencies, seed: 7)))
        default:
            Text("Unknown game")
        }
    }

    private func prepared<M: GameModel>(_ model: M) -> M {
        model.autoTick = false
        switch phase {
        case "play": model.debugShow(.playing)
        case "results": model.debugShow(.results)
        case "countdown": model.debugShow(.countdown(2))
        case "mic-off": model.debugShow(.micDenied)
        case "interrupted": model.debugShow(.interrupted)
        default: break
        }
        return model
    }
}

enum DebugGameDependencies {
    @MainActor
    static func make() -> GameDependencies {
        GameDependencies(listener: DebugSilentListener(), player: DebugSilentPlayer(),
                         clock: SystemGameClock(), scores: MemoryGameScores())
    }
}

/// Pretends to listen; hears nothing.
@MainActor
final class DebugSilentListener: TutorListening {
    var isListening = false
    var permissionDenied = false
    var inputLevel: Float { Float(0.35 + 0.2 * sin(Date().timeIntervalSince1970 * 3)) }
    var takeClock: TimeInterval { CACurrentMediaTime() }
    var onVerification: ((VerificationResult) -> Void)?
    var onDetected: ((DetectedEvent) -> Void)?
    var detectionSources: TutorListener.DetectionSources = .all
    func start(profile: InstrumentProfile, recordTake: Bool) async throws { isListening = true }
    @discardableResult func stop() -> URL? { isListening = false; return nil }
    func arm(_ events: [ExpectedEvent], window: ExpectedNoteVerifier.Window) {}
    func armTimed(_ passage: ExpectedPassage, passageStart: TimeInterval, tempoScale: Double, tolerance: TimeInterval) {}
    func disarm() {}
}

@MainActor
final class DebugSilentPlayer: TutorSequencePlaying {
    var isPlaying = false
    @discardableResult
    func play(_ sequence: PlaybackSequence, instrument: TutorInstrument, onStep: ((Int) -> Void)?,
              completion: (() -> Void)?) -> Bool {
        completion?()
        return false
    }
    func stop() {}
}
#endif

/// Personal bests kept in memory (tests, previews).
@MainActor
final class MemoryGameScores: GameScoreStoring {
    private(set) var records: [String: (best: Double, attempts: Int)] = [:]

    func best(for lessonID: String, instrument: TutorInstrument) -> Double? {
        records["\(lessonID)|\(instrument.rawValue)"]?.best
    }

    func record(_ score: Double, for lessonID: String, instrument: TutorInstrument) {
        let key = "\(lessonID)|\(instrument.rawValue)"
        let old = records[key]
        records[key] = (max(old?.best ?? score, score), (old?.attempts ?? 0) + 1)
    }
}
