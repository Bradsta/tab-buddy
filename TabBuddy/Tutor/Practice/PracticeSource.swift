//
//  PracticeSource.swift
//  TabBuddy
//
//  What practice mode knows about the open score: where expected notes come
//  from, the measure count, the starting range and speed, and how to push a
//  loop/tempo back into the viewer. Built by `TabViewerView`.
//

import Foundation

/// Where expected notes come from.
enum PracticeSource {
    /// Text tab or PDF canonical, drawn natively (`DrawnTabSystemView`).
    case measureMap(MeasureMap, TabRenderModel)
    /// Guitar Pro: note groups exported by the alphaTab page for `track`.
    case alphaTab(track: Int, export: @MainActor () async -> [[String: Any]])
    /// A sibling MIDI file; the loader returns a readable copy (nil if gone).
    case midi(load: @MainActor () async -> URL?)
    /// Already-built note groups (tests, demo).
    case passage(ExpectedPassage)

    var drawsNatively: Bool {
        if case .measureMap = self { return true }
        return false
    }
}

/// Everything `PracticeSessionController` needs from the viewer.
struct PracticeScoreContext {
    /// `FileItem.id` UUID string.
    var scoreKey: String
    var title: String
    var source: PracticeSource
    /// Measures in the score (0 when unknown until notes load).
    var totalMeasures: Int
    /// The viewer's loop, else the current system (0-based, inclusive).
    var initialRange: ClosedRange<Int>?
    /// Score tempo in the passage's beat unit; nil = use the source's own tempo.
    var referenceBPM: Double?
    /// The viewer's practice speed (100 = score tempo).
    var tempoPercent: Double
    var instrument: TutorInstrument
    /// The part is a bass (bass track, or a tuning whose lowest string is below
    /// D2): listening uses `InstrumentProfile.bassGuitar` instead of the
    /// acoustic guitar profile. Only meaningful for `.guitar`.
    var isBass: Bool = false
    /// Pushes a loop (nil = leave) and a practice speed (nil = leave) into the viewer.
    var applyToViewer: @MainActor (ClosedRange<Int>?, Double?) -> Void = { _, _ in }
}

extension PracticeScoreContext {
    /// Listening profile for a take: the bass profile for bass parts, or when
    /// the passage reaches below the guitar range (MIDI 38, drop D).
    func listeningProfile(for instrument: TutorInstrument, passage: ExpectedPassage? = nil) -> InstrumentProfile {
        if isBass { return InstrumentProfile.preset(for: instrument, isBass: true) }
        guard let passage else { return InstrumentProfile.preset(for: instrument) }
        return InstrumentProfile.preset(for: instrument, pitches: passage.events.lazy.flatMap(\.pitches))
    }
}

// MARK: - Passage building

/// Builds passages for a range from any practice source. Notes that need I/O
/// (alphaTab export, MIDI copy) are loaded once by `load()`.
@MainActor
final class PracticePassageFactory {
    private(set) var source: PracticeSource
    private var alphaTabNotes: [PassageBuilder.AlphaTabNote]?
    private var alphaTabTrack = 0
    private var midiURL: URL?
    private var fixed: ExpectedPassage?
    private(set) var loaded = false

    init(source: PracticeSource) {
        self.source = source
        if case .passage(let p) = source { fixed = p; loaded = true }
        if case .measureMap = source { loaded = true }
    }

    /// Loads exported/copied notes. Returns false when the source yields nothing.
    func load() async -> Bool {
        if loaded { return true }
        switch source {
        case .alphaTab(let track, let export):
            let raw = await export()
            alphaTabNotes = raw.compactMap(PassageBuilder.AlphaTabNote.init(dictionary:))
            alphaTabTrack = track
            loaded = !(alphaTabNotes ?? []).isEmpty
        case .midi(let load):
            midiURL = await load()
            loaded = midiURL != nil
        case .measureMap, .passage:
            loaded = true
        }
        return loaded
    }

    /// Measures known to the source (for range clamping).
    var measureCount: Int {
        switch source {
        case .measureMap(let map, _): return map.measureCount
        case .alphaTab: return (alphaTabNotes?.map(\.bar).max()).map { $0 + 1 } ?? 0
        case .midi, .passage: return (whole()?.measureRange?.upperBound).map { $0 + 1 } ?? 0
        }
    }

    /// A passage for `range` (nil = whole piece). `bpm` overrides the source tempo.
    func passage(range: ClosedRange<Int>?, bpm: Double?, instrument: TutorInstrument) -> ExpectedPassage? {
        switch source {
        case .measureMap(let map, _):
            return PassageBuilder.from(measureMap: map, measureRange: range, bpm: bpm, instrument: instrument)
        case .alphaTab:
            guard let notes = alphaTabNotes else { return nil }
            return PassageBuilder.from(alphaTabNotes: notes, track: alphaTabTrack, measureRange: range,
                                       bpm: bpm, instrument: instrument)
        case .midi:
            guard let url = midiURL else { return nil }
            return PassageBuilder.from(midiFileURL: url, measureRange: range, bpm: bpm, instrument: instrument)
        case .passage:
            guard var p = fixed else { return nil }
            if let range { p.events = p.events.filter { range.contains($0.measureIndex) } }
            guard !p.events.isEmpty else { return nil }
            let origin = p.events.first?.beat ?? 0
            for i in p.events.indices { p.events[i].beat -= origin; p.events[i].id = i }
            if let bpm { p.bpm = bpm }
            p.instrument = instrument
            return p
        }
    }

    private func whole() -> ExpectedPassage? {
        passage(range: nil, bpm: nil, instrument: .guitar)
    }

    /// Removes the temporary MIDI copy. The factory reports unloaded afterwards,
    /// so a later `load()` copies the MIDI file again instead of building from nothing.
    func cleanUp() {
        if let midiURL, midiURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: midiURL)
        }
        midiURL = nil
        if case .midi = source { loaded = false }
    }
}

/// Lets the viewer end a practice session it hosts. `PracticeModeView`
/// registers its controller's `close()`; the viewer calls `close()` when it
/// really leaves the screen (not when a presentation covers it).
@MainActor
final class PracticeSessionHandle {
    private var closeAction: (() -> Void)?

    func register(_ action: @escaping () -> Void) { closeAction = action }

    /// Runs the registered close once.
    func close() {
        let action = closeAction
        closeAction = nil
        action?()
    }
}

// MARK: - Instrument and range helpers

enum PracticeDefaults {
    /// Guitar-family instruments practice as `.guitar` (bass included; its
    /// listening profile comes from `isBass`); piano gets its own.
    static func instrument(trackInstrument: Instrument?, fileInstruments: [Instrument],
                           isTablature: Bool) -> TutorInstrument {
        if let trackInstrument {
            switch trackInstrument {
            case .piano: return .piano
            case .guitar, .bass, .ukulele, .mandolin, .banjo: return .guitar
            default: break
            }
        }
        if isTablature { return .guitar }
        let guitarFamily: Set<Instrument> = [.guitar, .bass, .ukulele, .mandolin, .banjo]
        if fileInstruments.contains(.piano) && !fileInstruments.contains(where: guitarFamily.contains) { return .piano }
        if fileInstruments.contains(where: guitarFamily.contains) { return .guitar }
        return .piano
    }

    /// Lowest open string below this (D2, MIDI 38) means a bass tuning:
    /// 4/5-string bass, or a baritone/low tuning the guitar profile can't hear.
    static let bassStringThresholdMIDI = 38

    /// Whether a part should be heard with the bass profile.
    /// - Parameters:
    ///   - trackInstrument: the selected track's instrument (Guitar Pro), if known.
    ///   - fileInstruments: the score's instruments, used when there is no track.
    ///   - openStringMIDI: the tab's open strings with octaves, if known.
    static func isBass(trackInstrument: Instrument?, fileInstruments: [Instrument],
                       openStringMIDI: [Int]?) -> Bool {
        if let lowest = openStringMIDI?.min(), lowest < bassStringThresholdMIDI { return true }
        if let trackInstrument { return trackInstrument == .bass }
        if openStringMIDI != nil { return false }
        let otherGuitars: Set<Instrument> = [.guitar, .ukulele, .mandolin, .banjo]
        return fileInstruments.contains(.bass) && !fileInstruments.contains(where: otherGuitars.contains)
    }

    /// Clamps a range into `0..<count`; nil when nothing remains.
    static func clamp(_ range: ClosedRange<Int>, count: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return range.lowerBound >= 0 ? range : nil }
        let lo = max(0, min(count - 1, range.lowerBound))
        let hi = max(lo, min(count - 1, range.upperBound))
        return lo...hi
    }

    /// The measures of the system containing `measure` (drawn tabs).
    static func systemRange(containing measure: Int, in map: MeasureMap) -> ClosedRange<Int>? {
        var start = 0
        for system in map.systems {
            let count = system.measures.count
            if count > 0, measure < start + count { return start...(start + count - 1) }
            start += count
        }
        return map.measureCount > 0 ? 0...min(3, map.measureCount - 1) : nil
    }

    /// Default span without a system layout: four measures from `measure`.
    static func span(from measure: Int, count: Int, length: Int = 4) -> ClosedRange<Int> {
        let lo = max(0, count > 0 ? min(measure, count - 1) : measure)
        let hi = count > 0 ? min(count - 1, lo + length - 1) : lo + length - 1
        return lo...max(lo, hi)
    }

    /// 1-based display label.
    static func label(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound ? "Measure \(range.lowerBound + 1)"
            : "Measures \(range.lowerBound + 1)–\(range.upperBound + 1)"
    }
}

/// How a practice suggestion changes the next take.
struct PracticeSuggestionAction: Equatable {
    var loop: ClosedRange<Int>?
    var tempoPercent: Double?

    /// Clamps the suggestion into the score and a playable speed range.
    init(_ suggestion: PracticeSuggestion, totalMeasures: Int) {
        loop = suggestion.loopMeasures.flatMap { PracticeDefaults.clamp($0, count: totalMeasures) }
        tempoPercent = suggestion.tempoPercent.map { PracticeTempo.clamp($0) }
    }

    init(loop: ClosedRange<Int>?, tempoPercent: Double?) {
        self.loop = loop
        self.tempoPercent = tempoPercent
    }
}

enum PracticeTempo {
    static let range: ClosedRange<Double> = 25...150
    static let quickPercents: [Double] = [50, 60, 70, 80, 90, 100]

    static func clamp(_ percent: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, percent.rounded()))
    }
}
