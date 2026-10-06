//
//  QuickPracticeView.swift
//  TabBuddy
//
//  The Practice section. A "For you" row opens the next chapter's items and
//  recent items with their settings filled in. Scales and chords are chosen on
//  the instrument: a circle of fifths (guitar) or a keyboard strip (piano) for
//  the key, chips for the scale type, boxes on a full-neck fretboard for the
//  guitar position, and the key's chords (I–vii°) for chords and One Minute
//  Changes. Piano adds a technique grid (keys × exercises). Each item
//  remembers its tempo (`PracticeMemory`); Intervals, Rhythms, and the
//  Exercises index are unchanged.
//

import SwiftUI

struct TutorPracticeView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case technique, scales, chords, intervals, rhythms, exercises
        var id: String { rawValue }
        var title: String {
            switch self {
            case .technique: return "Technique"
            case .scales: return "Scales"
            case .chords: return "Chords"
            case .intervals: return "Intervals"
            case .rhythms: return "Rhythms"
            case .exercises: return "Exercises"
            }
        }

        static func tabs(for instrument: TutorInstrument) -> [Tab] {
            instrument == .piano ? allCases : allCases.filter { $0 != .technique }
        }

        static func tab(for launch: PracticeLaunch) -> Tab {
            switch launch.kind {
            case .scale: return .scales
            case .chord, .changes: return .chords
            case .technique: return .technique
            }
        }
    }

    let instrument: TutorInstrument
    let course: Course?
    var initialTab: Tab? = nil
    /// The next chapter (feeds "For you" and which scale types show first).
    var nextLesson: Lesson? = nil
    var chapterLabel: String? = nil
    /// An item to open directly ("Practice this" from a chapter).
    var initialLaunch: PracticeLaunch? = nil
    var onOpenLesson: (LessonLaunch) -> Void

    @State private var tab: Tab = .scales
    @State private var launch: PracticeLaunch?
    @ObservedObject private var memory = PracticeMemory.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var compact: Bool { sizeClass == .compact }

    private var introducedScales: Set<ScaleType> {
        guard let course else { return [.major] }
        return PracticeSuggestions.introducedScaleTypes(course: course, through: nextLesson?.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                header
                forYou
                content
            }
            .padding(.horizontal, compact ? 16 : 28)
            .padding(.vertical, compact ? 12 : 20)
            .tutorReadableWidth(1200)
        }
        .background(DS.paper)
        .onAppear {
            if let initialLaunch { open(initialLaunch) }
            else if let initialTab { tab = Tab.tabs(for: instrument).contains(initialTab) ? initialTab : .scales }
            else { tab = instrument == .piano ? .technique : .scales }
        }
        .onChange(of: initialLaunch) { _, new in if let new { open(new) } }
    }

    private func open(_ item: PracticeLaunch) {
        launch = item
        tab = Tab.tab(for: item)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                Text("Practice").font(.title.weight(.bold)).foregroundStyle(DS.fg1)
                Spacer(minLength: 12)
                tabPicker.frame(maxWidth: 640)
            }
            VStack(alignment: .leading, spacing: 10) {
                if !compact { Text("Practice").font(.title.weight(.bold)).foregroundStyle(DS.fg1) }
                ScrollView(.horizontal, showsIndicators: false) { tabPicker.frame(minWidth: 480) }
            }
        }
    }

    private var tabPicker: some View {
        Picker("Practice", selection: $tab) {
            ForEach(Tab.tabs(for: instrument)) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var forYou: some View {
        let items = PracticeSuggestions.suggestions(nextLesson: nextLesson, chapterLabel: chapterLabel,
                                                    recents: memory.recents(for: instrument), instrument: instrument)
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Text("For you")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(DS.fg3)
                    ForEach(items) { item in
                        Button { open(item.launch) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.source == .recent ? "clock.arrow.circlepath" : "book")
                                    .font(.subheadline)
                                    .foregroundStyle(DS.accentStrong)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(DS.fg1)
                                    Text(item.detail).font(.caption).foregroundStyle(DS.fg3).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(minHeight: 48)
                            .background(launch?.key == item.launch.key ? DS.accentSoft : DS.surface,
                                        in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(DS.separator))
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .technique:
            if instrument == .piano {
                TechniquePracticeCard(memory: memory, initial: launch?.kind == .technique ? launch : nil)
                    .id(launch?.kind == .technique ? launch?.key : "technique")
            } else {
                scales
            }
        case .scales: scales
        case .chords:
            ChordPracticeCard(instrument: instrument, memory: memory,
                              initial: (launch?.kind == .chord || launch?.kind == .changes) ? launch : nil)
                .id("\(instrument.rawValue)-\((launch?.kind == .chord || launch?.kind == .changes) ? launch?.key ?? "" : "")")
        case .intervals: IntervalPracticeCard(instrument: instrument).id(instrument)
        case .rhythms: RhythmPracticeCard(instrument: instrument).id(instrument)
        case .exercises:
            if let course {
                ExerciseIndexView(course: course, onOpenLesson: onOpenLesson)
            } else {
                ContentUnavailableView("No lessons loaded", systemImage: "music.quarternote.3")
            }
        }
    }

    private var scales: some View {
        ScalePracticeCard(instrument: instrument, memory: memory, introduced: introducedScales,
                          initial: launch?.kind == .scale ? launch : nil)
            .id("\(instrument.rawValue)-\(launch?.kind == .scale ? launch?.key ?? "" : "")")
    }
}

// MARK: - Shared card host

/// A Try it card for a quick-practice spec. Recreate it (`.id(spec)`) when the spec changes.
/// With a `launch`, playing or listening records the item in `PracticeMemory`
/// and tempo changes are remembered for it.
struct QuickPracticeTryIt: View {
    @StateObject private var model: TryItModel
    private let launch: PracticeLaunch?
    private let title: String
    private let showsDiagram: Bool

    init(exercise: GeneratedExercise?, error: String? = nil, prompt: String, diagram: Diagram?, instrument: TutorInstrument,
         bpm: Double, example: PlaybackSequence? = nil, supportsListening: Bool = true,
         launch: PracticeLaunch? = nil, title: String = "", showsDiagram: Bool = true) {
        _model = StateObject(wrappedValue: TryItModel(exercise: exercise, generationError: error, prompt: prompt, diagram: diagram,
                                                      instrument: instrument, bpm: bpm, supportsListening: supportsListening,
                                                      example: example, listener: TutorListener(), player: TutorSequencePlayer.shared))
        self.launch = launch
        self.title = title
        self.showsDiagram = showsDiagram
    }

    var body: some View {
        TryItBox { TryItCardView(model: model, showsPrompt: true, showsDiagram: showsDiagram) }
            .onChange(of: model.isPlaying) { _, playing in if playing { record() } }
            .onChange(of: model.isListening) { _, listening in if listening { record() } }
            .onChange(of: model.bpm) { _, bpm in
                if let launch { PracticeMemory.shared.setTempo(bpm, for: launch) }
            }
    }

    private func record() {
        guard let launch else { return }
        PracticeMemory.shared.notePracticed(launch, title: title, bpm: model.bpm)
    }
}

/// Tempo ladder offered as chips: the usual steps plus the item's last tempo.
/// Starting tempo for Intervals and Rhythms.
private enum TempoMemory {
    static let defaultBPM = 72.0
}

enum PracticeTempoLadder {
    static let steps: [Double] = [60, 72, 84, 96, 108, 120]
    static let defaultBPM = 72.0

    /// At most five chips around the item's last tempo (or 72), so they fit the side panel.
    static func steps(including last: Double?) -> [Double] {
        let anchor = (last ?? defaultBPM).rounded()
        var all = Set(steps)
        all.insert(anchor)
        let sorted = all.sorted()
        let i = sorted.firstIndex(of: anchor) ?? 0
        let lo = max(0, min(i - 2, sorted.count - 5))
        return Array(sorted[lo..<min(sorted.count, lo + 5)])
    }
}

/// Labeled group used by the practice cards.
private struct PickerRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(DS.fg3)
            content
        }
    }
}

/// A selectable chip.
private struct PracticeChip: View {
    var title: String
    var selected: Bool
    var dashed = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? DS.accentStrong : DS.fg2)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(selected ? DS.accentSoft : DS.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? DS.accentStrong.opacity(0.5) : DS.separator,
                                                style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Key picker for the instrument: a circle of fifths on guitar, a keyboard strip on piano.
private struct InstrumentKeyPicker: View {
    let instrument: TutorInstrument
    @Binding var root: SpelledNote
    var minor: Binding<Bool>? = nil

    var body: some View {
        PickerRow(label: "Key") {
            if instrument == .guitar {
                KeyWheelPicker(root: $root, minor: minor, size: minor == nil ? 236 : 290)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    KeyStripPicker(root: $root, height: 104)
                    if let minor {
                        Picker("Mode", selection: minor) {
                            Text("Major").tag(false)
                            Text("Minor").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
    }
}

/// Two columns on wide layouts (pickers left, practice right), stacked otherwise.
private struct PracticeColumns<Rail: View, Stage: View>: View {
    @ViewBuilder var rail: Rail
    @ViewBuilder var stage: Stage

    var body: some View {
        WidthReader { width in
            if width >= 1000 {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) { rail }
                        .frame(width: 280)
                    VStack(alignment: .leading, spacing: 16) { stage }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if width >= 560 {
                // iPad portrait / Split View: pickers side by side above the stage.
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 20) { rail }
                    stage
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    rail
                    stage
                }
            }
        }
    }
}

// MARK: - Scales

struct ScalePracticeCard: View {
    let instrument: TutorInstrument
    @ObservedObject var memory: PracticeMemory
    var introduced: Set<ScaleType> = [.major]
    @State private var spec: ScalePracticeSpec
    @State private var showsAllTypes = false

    /// Types offered before More, in teaching order.
    private static let primary: [ScaleType] = [.major, .naturalMinor, .majorPentatonic, .minorPentatonic, .blues,
                                               .harmonicMinor, .melodicMinor, .dorian, .mixolydian]

    init(instrument: TutorInstrument, memory: PracticeMemory, introduced: Set<ScaleType> = [.major], initial: PracticeLaunch? = nil) {
        self.instrument = instrument
        self.memory = memory
        self.introduced = introduced
        var start = initial.flatMap(ScalePracticeSpec.init(launch:)) ?? ScalePracticeSpec()
        if instrument == .piano { start.position = nil }
        _spec = State(initialValue: start)
    }

    private var shownTypes: [ScaleType] {
        if showsAllTypes { return ScaleType.allCases.filter { $0 != .ionian && $0 != .aeolian } }
        let first = Self.primary.filter { introduced.contains($0) }
        return first.isEmpty ? [.major] : first
    }

    var body: some View {
        let launch = spec.launch(instrument: instrument)
        let bpm = memory.tempo(for: launch, fallback: PracticeTempoLadder.defaultBPM)
        PracticeColumns {
            InstrumentKeyPicker(instrument: instrument, root: $spec.root)
            PickerRow(label: "Scale") {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(shownTypes, id: \.self) { type in
                        PracticeChip(title: type.displayName, selected: spec.type == type) { spec.type = type }
                    }
                    if !showsAllTypes {
                        PracticeChip(title: "More", selected: false, dashed: true) { showsAllTypes = true }
                    }
                }
            }
            PickerRow(label: "Options") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Octaves", selection: $spec.octaves) {
                        Text("1 octave").tag(1)
                        Text("2 octaves").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Picker("Labels", selection: $spec.labels) {
                        Text("Names").tag(Diagram.Labels.noteNames)
                        Text("Degrees").tag(Diagram.Labels.degrees)
                    }
                    .pickerStyle(.segmented)
                }
            }
        } stage: {
            if instrument == .guitar {
                VStack(alignment: .leading, spacing: 8) {
                    Text(positionTitle)
                        .font(.headline)
                        .foregroundStyle(DS.fg1)
                    FullNeckPositionPicker(scale: spec.scale, selection: $spec.position, labels: spec.labels)
                }
                .padding(16)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
            }
            QuickPracticeTryIt(exercise: exercise(bpm: bpm, launch: launch),
                               prompt: "\(spec.title), \(spec.octaves == 1 ? "one octave" : "two octaves"), up and down.",
                               diagram: spec.diagram(instrument: instrument),
                               instrument: instrument, bpm: bpm, launch: launch, title: PracticeSuggestions.title(for: launch),
                               showsDiagram: instrument != .guitar)
                .id(spec)
        }
    }

    private var positionTitle: String {
        guard let box = spec.guitarPosition() else { return "\(spec.title) · whole neck. Tap a box to practice one position." }
        return "\(spec.title) · \(box.title)"
    }

    private func exercise(bpm: Double, launch: PracticeLaunch) -> GeneratedExercise {
        var e = spec.exercise(instrument: instrument, bpm: bpm)
        e.tempoSteps = PracticeTempoLadder.steps(including: memory.stats(for: launch).lastBPM)
        return e
    }
}

// MARK: - Chords

struct ChordPracticeCard: View {
    enum Mode: String, CaseIterable, Identifiable {
        case single, changes
        var id: String { rawValue }
        var title: String { self == .single ? "One chord" : "Changes" }
    }

    let instrument: TutorInstrument
    @ObservedObject var memory: PracticeMemory
    @State private var root: SpelledNote
    @State private var minor = false
    @State private var mode: Mode
    @State private var selection: [Chord]
    @State private var showsRoman = true
    @State private var style: ChordPracticeSpec.Style = .block

    init(instrument: TutorInstrument, memory: PracticeMemory, initial: PracticeLaunch? = nil) {
        self.instrument = instrument
        self.memory = memory
        let chords = initial?.chords.compactMap { Chord($0) } ?? []
        if let initial, initial.kind == .changes, chords.count >= 2 {
            _root = State(initialValue: chords[0].root)
            _minor = State(initialValue: chords[0].quality == .minor)
            _mode = State(initialValue: .changes)
            _selection = State(initialValue: chords)
        } else if let initial, initial.kind == .chord, let r = SpelledNote(initial.root) {
            let quality = initial.type.flatMap(ChordQuality.init(rawValue:)) ?? .major
            _root = State(initialValue: r)
            _minor = State(initialValue: quality == .minor)
            _mode = State(initialValue: .single)
            _selection = State(initialValue: [Chord(root: r, quality: quality)])
        } else {
            _root = State(initialValue: .C)
            _mode = State(initialValue: .single)
            _selection = State(initialValue: [Chord(root: .C, quality: .major)])
        }
    }

    private var key: Key { Key(tonic: root, mode: minor ? .minor : .major) }

    /// Other qualities on the key's root, under More.
    private var extraChords: [Chord] {
        DiatonicChords.extras(in: key)
    }

    var body: some View {
        PracticeColumns {
            InstrumentKeyPicker(instrument: instrument, root: $root, minor: $minor)
            PickerRow(label: "Practice") {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if mode == .single {
                PickerRow(label: "Play as") {
                    Picker("Play as", selection: $style) {
                        ForEach(ChordPracticeSpec.Style.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        } stage: {
            DiatonicChordRow(key: key, selection: $selection, showsRoman: $showsRoman,
                             mode: mode == .single ? .single : .changes, extraChords: extraChords)
            stage
        }
        .onChange(of: root) { _, _ in resetSelection() }
        .onChange(of: minor) { _, _ in resetSelection() }
        .onChange(of: mode) { _, new in
            if new == .single { selection = Array(selection.prefix(1)) }
            if selection.isEmpty { resetSelection() }
        }
    }

    private func resetSelection() {
        let triads = DiatonicChords.triads(in: key).map(\.chord)
        selection = mode == .single ? Array(triads.prefix(1)) : Array(triads.prefix(1)) + triads.dropFirst(4).prefix(1)
    }

    @ViewBuilder
    private var stage: some View {
        if mode == .single, let chord = selection.first {
            let spec = ChordPracticeSpec(root: chord.root, quality: chord.quality, style: style)
            let launch = spec.launch(instrument: instrument)
            let bpm = memory.tempo(for: launch, fallback: PracticeTempoLadder.defaultBPM)
            QuickPracticeTryIt(exercise: spec.exercise(instrument: instrument, bpm: bpm),
                               prompt: "\(spec.title): " + spec.chord.tones.map(\.displayName).joined(separator: " ") + ".",
                               diagram: spec.diagram(instrument: instrument), instrument: instrument, bpm: bpm,
                               example: spec.example(instrument: instrument, bpm: bpm),
                               launch: launch, title: spec.title)
                .id(spec)
        } else if selection.count >= 2 {
            let launch = PracticeLaunch(instrument: instrument, kind: .changes, root: root.name, chords: selection.map(\.symbol))
            ChordChangesDrillView(spec: ChordChangesSpec(instrument: instrument, chords: selection,
                                                         bpm: memory.tempo(for: launch, fallback: 60)),
                                  memory: memory)
                .id(selection.map(\.symbol).joined(separator: "-"))
                // A saved run puts the chord set in recents.
                .onChange(of: memory.changesHistory(instrument: instrument, chords: launch.chords).count) { _, _ in
                    memory.notePracticed(launch, title: PracticeSuggestions.title(for: launch), bpm: nil)
                }
        } else {
            TutorMessageRow(text: "Tap at least two chords to practice changing between them.",
                            systemImage: "arrow.left.arrow.right", tone: .neutral)
        }
    }
}

// MARK: - Technique (piano)

struct TechniquePracticeCard: View {
    @ObservedObject var memory: PracticeMemory
    @State private var selected: PianoTechniqueSpec?

    init(memory: PracticeMemory, initial: PracticeLaunch? = nil) {
        self.memory = memory
        // Open on a drill so the page is never an empty grid; the first cell is where every method starts.
        _selected = State(initialValue: initial.flatMap(PianoTechniqueSpec.init(launch:))
                          ?? PianoTechniqueKey.order.first.map { PianoTechniqueSpec(key: $0, row: .fiveFinger) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keys across, exercises down. Start with hands separate at the suggested tempo; a cell fills in as you reach its goal tempo.")
                .font(.subheadline)
                .foregroundStyle(DS.fg3)
                .fixedSize(horizontal: false, vertical: true)
            PianoTechniqueGridView(memory: memory) { spec in selected = spec }
            if let spec = selected {
                let launch = spec.launch
                let bpm = memory.tempo(for: launch, fallback: spec.row.targetBPM)
                QuickPracticeTryIt(exercise: technique(spec, bpm: bpm, launch: launch), prompt: spec.title + ".",
                                   diagram: spec.diagram(), instrument: .piano, bpm: bpm,
                                   example: spec.example(bpm: bpm), launch: launch, title: spec.title)
                    .id(launch.key)
            }
        }
    }

    private func technique(_ spec: PianoTechniqueSpec, bpm: Double, launch: PracticeLaunch) -> GeneratedExercise {
        var e = spec.exercise(bpm: bpm)
        e.tempoSteps = PracticeTempoLadder.steps(including: memory.stats(for: launch).lastBPM ?? spec.row.targetBPM)
        return e
    }
}

// MARK: - Intervals

struct IntervalPracticeCard: View {
    let instrument: TutorInstrument
    @State private var spec: IntervalPracticeSpec
    @State private var bpm = TempoMemory.defaultBPM

    init(instrument: TutorInstrument) {
        self.instrument = instrument
        _spec = State(initialValue: IntervalPracticeSpec(root: IntervalPracticeSpec.defaultRoot(instrument)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PickerRow(label: "Interval") {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(IntervalPracticeSpec.intervals, id: \.self) { interval in
                        Button(interval.shortName) { spec.interval = interval }
                            .font(.subheadline.weight(.semibold).monospaced())
                            .buttonStyle(.bordered)
                            .tint(spec.interval == interval ? DS.accent : DS.fg2)
                            .accessibilityLabel(interval.name)
                    }
                }
            }
            HStack(alignment: .top, spacing: 20) {
                PickerRow(label: "Root") {
                    HStack(spacing: 8) {
                        Button { move(-1) } label: { Image(systemName: "minus") }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Lower root")
                        Text(spec.root.displayName)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .frame(minWidth: 56)
                        Button { move(1) } label: { Image(systemName: "plus") }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Higher root")
                    }
                }
                PickerRow(label: "Direction") {
                    Picker("Direction", selection: $spec.direction) {
                        ForEach(IntervalPracticeSpec.Direction.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
            }
            if spec.fits(instrument) {
                QuickPracticeTryIt(exercise: spec.exercise(instrument: instrument, bpm: bpm), prompt: spec.caption,
                                   diagram: spec.diagram(instrument: instrument), instrument: instrument, bpm: bpm,
                                   example: spec.example(instrument: instrument, bpm: bpm))
                    .id(spec)
            } else {
                TutorMessageRow(text: "That interval from \(spec.root.displayName) leaves the \(instrument.displayName.lowercased()). Move the root.",
                                systemImage: "arrow.up.and.down", tone: .neutral)
            }
        }
    }

    private func move(_ semitones: Int) {
        let range = IntervalPracticeSpec.rootRange(instrument)
        let midi = min(range.upperBound, max(range.lowerBound, spec.root.midi + semitones))
        spec.root = Pitch(midi: midi)
    }
}

// MARK: - Rhythms

struct RhythmPracticeCard: View {
    let instrument: TutorInstrument
    @State private var spec = RhythmPracticeSpec()
    @State private var field = "q q e e q"
    @State private var bpm = 80.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PickerRow(label: "Presets") {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(RhythmPracticeSpec.presets) { preset in
                        Button(preset.name) {
                            field = preset.tokens
                            spec.tokens = preset.tokens
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(spec.tokens == preset.tokens ? DS.accent : DS.fg2)
                    }
                }
            }
            PickerRow(label: "Your rhythm") {
                HStack(spacing: 8) {
                    TextField("q q e e q", text: $field)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { spec.tokens = field }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                    Button("Use") { spec.tokens = field }
                        .buttonStyle(.borderedProminent)
                }
                Text("w h q e s = whole to sixteenth · \".\" dotted · \"t\" triplet · \"r\" rest (qr) · \"|\" bar line")
                    .font(.caption)
                    .foregroundStyle(DS.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = spec.error {
                TutorMessageRow(text: error, systemImage: "exclamationmark.circle", tone: .neutral)
            } else {
                QuickPracticeTryIt(exercise: spec.exercise(instrument: instrument, bpm: bpm), prompt: spec.title + ". Count out loud, then clap or strum along.",
                                   diagram: spec.diagram(), instrument: instrument, bpm: bpm, supportsListening: false)
                    .id(spec)
            }
        }
    }
}

// MARK: - Exercise index

struct ExerciseIndexView: View {
    let course: Course
    var onOpenLesson: (LessonLaunch) -> Void

    var body: some View {
        let groups = TutorExerciseIndex.grouped(course: course)
        VStack(alignment: .leading, spacing: 22) {
            Text("Every Try it box and song in the \(course.title.lowercased()) course. Tap one to open its chapter at that section.")
                .font(.subheadline)
                .foregroundStyle(DS.fg3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(groups, id: \.group) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(group.group.title) (\(group.entries.count))", systemImage: group.group.systemImage)
                        .font(.headline)
                        .foregroundStyle(DS.fg1)
                    VStack(spacing: 0) {
                        ForEach(group.entries) { entry in
                            Button {
                                guard let lesson = course.lesson(id: entry.lessonID) else { return }
                                onOpenLesson(LessonLaunch(lesson: lesson, sectionIndex: entry.sectionIndex))
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title)
                                            .font(.body)
                                            .foregroundStyle(DS.fg1)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(entry.location)
                                            .font(.caption)
                                            .foregroundStyle(DS.fg3)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(DS.fg3)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            if entry.id != group.entries.last?.id { Hairline().padding(.leading, 14) }
                        }
                    }
                    .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
                }
            }
        }
    }
}
