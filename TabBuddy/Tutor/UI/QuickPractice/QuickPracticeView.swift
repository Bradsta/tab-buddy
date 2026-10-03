//
//  QuickPracticeView.swift
//  TabBuddy
//
//  The Practice section: direct practice without opening a chapter. Tabs for
//  Scales, Chords, Intervals, and Rhythms each show pickers above a Try it
//  card (diagram, Play example with loop and tempo, optional Listen), and the
//  Exercises tab lists every Try it box and song in the course by kind with a
//  jump link into its chapter.
//

import SwiftUI

struct TutorPracticeView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case scales, chords, intervals, rhythms, exercises
        var id: String { rawValue }
        var title: String {
            switch self {
            case .scales: return "Scales"
            case .chords: return "Chords"
            case .intervals: return "Intervals"
            case .rhythms: return "Rhythms"
            case .exercises: return "Exercises"
            }
        }
    }

    let instrument: TutorInstrument
    let course: Course?
    var initialTab: Tab? = nil
    var onOpenLesson: (LessonLaunch) -> Void

    @State private var tab: Tab = .scales
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !compact {
                    Text("Practice").font(.largeTitle.weight(.bold))
                }
                Text("Pick something and play it at your own pace. The app plays an example at any tempo and can turn heard notes green. Nothing is scored.")
                    .font(compact ? .body : .title3)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Practice", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 640)

                switch tab {
                case .scales: ScalePracticeCard(instrument: instrument).id(instrument)
                case .chords: ChordPracticeCard(instrument: instrument).id(instrument)
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
            .padding(compact ? 16 : 32)
            .tutorReadableWidth(1100)
        }
        .background(DS.paper)
        .onAppear { if let initialTab { tab = initialTab } }
    }
}

// MARK: - Shared card host

/// A Try it card for a quick-practice spec. Recreate it (`.id(spec)`) when the spec changes.
struct QuickPracticeTryIt: View {
    @StateObject private var model: TryItModel

    init(exercise: GeneratedExercise?, error: String? = nil, prompt: String, diagram: Diagram?, instrument: TutorInstrument,
         bpm: Double, example: PlaybackSequence? = nil, supportsListening: Bool = true) {
        _model = StateObject(wrappedValue: TryItModel(exercise: exercise, generationError: error, prompt: prompt, diagram: diagram,
                                                      instrument: instrument, bpm: bpm, supportsListening: supportsListening,
                                                      example: example, listener: TutorListener(), player: TutorSequencePlayer.shared))
    }

    var body: some View {
        TryItBox { TryItCardView(model: model, showsPrompt: true) }
    }
}

/// Labeled picker row used by the practice cards.
private struct PickerRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(DS.fg3)
            content
        }
    }
}

private struct RootPicker: View {
    @Binding var root: SpelledNote

    var body: some View {
        PickerRow(label: "Root") {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(QuickPracticeRoots.all, id: \.self) { note in
                    let selected = note.pitchClass == root.pitchClass
                    Button(QuickPracticeRoots.label(note)) { root = note }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(selected ? DS.accent : DS.fg2)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

/// Remembers the tempo across spec changes within a card.
private struct TempoMemory {
    static let defaultBPM = 72.0
}

// MARK: - Scales

struct ScalePracticeCard: View {
    let instrument: TutorInstrument
    @State private var spec = ScalePracticeSpec()
    @State private var bpm = TempoMemory.defaultBPM

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RootPicker(root: $spec.root)
            HStack(alignment: .top, spacing: 20) {
                PickerRow(label: "Scale") {
                    Picker("Scale", selection: $spec.type) {
                        ForEach(ScaleType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                PickerRow(label: "Octaves") {
                    Picker("Octaves", selection: $spec.octaves) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                PickerRow(label: "Labels") {
                    Picker("Labels", selection: $spec.labels) {
                        Text("Names").tag(Diagram.Labels.noteNames)
                        Text("Degrees").tag(Diagram.Labels.degrees)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
            if instrument == .guitar {
                PickerRow(label: "Position") {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        Button("Course default") { spec.fretWindow = nil }
                            .buttonStyle(.bordered)
                            .tint(spec.fretWindow == nil ? DS.accent : DS.fg2)
                        ForEach(ScalePracticeSpec.fretWindows, id: \.self) { start in
                            let title = start == 0 ? "Open (0–4)" : "Frets \(start)–\(start + ScalePracticeSpec.windowSpan)"
                            Button(title) { spec.fretWindow = start }
                                .buttonStyle(.bordered)
                                .tint(spec.fretWindow == start ? DS.accent : DS.fg2)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            QuickPracticeTryIt(exercise: spec.exercise(instrument: instrument, bpm: bpm),
                               prompt: "\(spec.title), \(spec.octaves == 1 ? "one octave" : "two octaves"), up and down.",
                               diagram: spec.diagram(instrument: instrument), instrument: instrument, bpm: bpm)
                .id(spec)
        }
    }
}

// MARK: - Chords

struct ChordPracticeCard: View {
    let instrument: TutorInstrument
    @State private var spec = ChordPracticeSpec()
    @State private var bpm = TempoMemory.defaultBPM

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RootPicker(root: $spec.root)
            HStack(alignment: .top, spacing: 20) {
                PickerRow(label: "Quality") {
                    Picker("Quality", selection: $spec.quality) {
                        ForEach(ChordQuality.allCases, id: \.self) { Text("\($0.name) (\(Chord(root: spec.root, quality: $0).displaySymbol))").tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                PickerRow(label: "Play as") {
                    Picker("Play as", selection: $spec.style) {
                        ForEach(ChordPracticeSpec.Style.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
            }
            QuickPracticeTryIt(exercise: spec.exercise(instrument: instrument, bpm: bpm),
                               prompt: "\(spec.title): " + spec.chord.tones.map(\.displayName).joined(separator: " ") + ".",
                               diagram: spec.diagram(instrument: instrument), instrument: instrument, bpm: bpm,
                               example: spec.example(instrument: instrument, bpm: bpm))
                .id(spec)
        }
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
