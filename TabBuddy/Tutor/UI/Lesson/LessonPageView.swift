//
//  LessonPageView.swift
//  TabBuddy
//
//  One lesson as a textbook chapter on a single scrolling page: chapter
//  header, a table of contents with jump links (a card at the top in regular
//  width, a Contents menu in the top bar everywhere), then every section in
//  order with a heading: reading with inline diagrams and "Hear it", worked
//  examples as figure cards, "Try it" boxes, songs, and "Check yourself"
//  questions at the end. A "Mark as done" toggle closes the chapter. There is
//  no gating, grading, or score.
//
//  Hardware keyboard: Escape closes, ⌘D toggles done, Space plays the example
//  in a Try it box, L toggles its Listen switch.
//

import SwiftUI

/// What the shell opens: a lesson, optionally scrolled to one section.
struct LessonLaunch: Identifiable, Hashable {
    var lesson: Lesson
    /// Index into `LessonPageModel.sections`.
    var sectionIndex: Int? = nil
    var id: String { lesson.id }
}

struct LessonPageView: View {
    let lesson: Lesson
    let instrument: TutorInstrument
    var initialSection: Int? = nil
    var onExit: () -> Void

    @StateObject private var model: LessonPageModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(lesson: Lesson, instrument: TutorInstrument, initialSection: Int? = nil, store: TutorStore? = nil,
         onExit: @escaping () -> Void) {
        self.lesson = lesson
        self.instrument = instrument
        self.initialSection = initialSection
        self.onExit = onExit
        _model = StateObject(wrappedValue: LessonPageModel(lesson: lesson, instrument: instrument, store: store ?? TutorStore.shared))
    }

    private var compact: Bool { sizeClass == .compact }
    private var gutter: CGFloat { compact ? 16 : 32 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                topBar(proxy)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 28 : 40) {
                        chapterHeader
                        if !compact, model.sections.count > 1 { contentsCard(proxy) }
                        ForEach(model.sections) { section in
                            sectionView(section)
                                .id(section.id)
                        }
                        doneCard
                    }
                    .frame(maxWidth: 1180, alignment: .leading)
                    .padding(.horizontal, gutter)
                    .padding(.vertical, compact ? 20 : 32)
                    .frame(maxWidth: .infinity)
                    .id("chapter-top")
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    guard let initialSection, model.sections.indices.contains(initialSection) else { return }
                    let target = model.sections[initialSection].id
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
        .background(DS.paper.ignoresSafeArea())
        .background(KeyboardShortcutButton(key: "d", modifiers: .command) { model.toggleDone() })
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Chrome

    private func topBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            Button {
                TutorSynth.shared.stop()
                onExit()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(DS.fg2)
                    .frame(width: DS.tile, height: DS.tile)
                    .background(Circle().fill(DS.surfaceInset))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close lesson")

            VStack(alignment: .leading, spacing: 2) {
                Text(lesson.title)
                    .font(.headline)
                    .foregroundStyle(DS.fg1)
                    .lineLimit(1)
                Text(chapterLine)
                    .font(.caption)
                    .foregroundStyle(DS.fg2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.sections.count > 1 {
                Menu {
                    Button { withAnimation(DS.motionSlow) { proxy.scrollTo("chapter-top", anchor: .top) } } label: {
                        Label("Top of chapter", systemImage: "arrow.up.to.line")
                    }
                    Divider()
                    ForEach(model.sections) { section in
                        Button { withAnimation(DS.motionSlow) { proxy.scrollTo(section.id, anchor: .top) } } label: {
                            Label("\(section.number). \(section.title)", systemImage: section.kind.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                        if !compact { Text("Contents") }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, compact ? 0 : 12)
                    .frame(minWidth: DS.tile, minHeight: DS.tile)
                    .background(Capsule().fill(DS.surfaceInset))
                    .foregroundStyle(DS.fg1)
                }
                .accessibilityLabel("Contents")
            }
            Toggle(isOn: Binding(get: { model.isDone }, set: { model.setDone($0) })) {
                Text("Done")
            }
            .toggleStyle(.button)
            .tint(DS.accent)
            .accessibilityHint("Marks this chapter as read")
        }
        .padding(.horizontal, gutter)
        .padding(.vertical, 10)
        .background(BarMaterial())
    }

    private var location: LessonLocation? { CurriculumLibrary.shared.location(ofLesson: lesson.id, instrument: instrument) }

    /// "Part 3 · Chapter 2" from the course position, else the lesson length.
    private var chapterLine: String {
        guard let location else { return "\(lesson.minutes) min" }
        if let branch = location.branch {
            let n = (branch.lessons.firstIndex { $0.id == lesson.id } ?? 0) + 1
            return "\(branch.title) · Chapter \(n) · \(lesson.minutes) min"
        }
        let n = (location.stage.lessons.firstIndex { $0.id == lesson.id } ?? 0) + 1
        return "Part \(location.stage.order) · Chapter \(n) · \(lesson.minutes) min"
    }

    // MARK: Header and contents

    private var chapterHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chapterLine.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(DS.accentStrong)
            Text(lesson.title)
                .font(compact ? .largeTitle.weight(.bold) : .system(size: 40, weight: .bold))
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            Text(lesson.summary)
                .font(compact ? .body : .title3)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: TutorLayout.readableWidth, alignment: .leading)
            HStack(spacing: 14) {
                Label("\(lesson.minutes) min", systemImage: "clock")
                Label("\(model.sections.count) sections", systemImage: "list.bullet")
                if model.usesMicrophone { Label("Try it boxes can listen", systemImage: "mic") }
                if model.isDone { Label("Read", systemImage: "checkmark.circle.fill").foregroundStyle(DS.accentStrong) }
            }
            .font(.subheadline)
            .foregroundStyle(DS.fg2)
        }
    }

    private func contentsCard(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In this chapter")
                .font(.headline)
                .foregroundStyle(DS.fg1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 8, alignment: .topLeading)],
                      alignment: .leading, spacing: 4) {
                ForEach(model.sections) { section in
                    Button {
                        withAnimation(DS.motionSlow) { proxy.scrollTo(section.id, anchor: .top) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(section.number)")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(DS.accentStrong)
                                .frame(width: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.title)
                                    .font(.body)
                                    .foregroundStyle(DS.fg1)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                Text(section.kind.label)
                                    .font(.caption)
                                    .foregroundStyle(DS.fg3)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table of contents")
    }

    // MARK: Sections

    private func sectionView(_ section: LessonSection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading(section)
            sectionBody(section)
        }
    }

    private func sectionHeading(_ section: LessonSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: section.kind.systemImage)
                Text(section.kind.label.uppercased())
                    .tracking(0.8)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(section.kind == .practice || section.kind == .song ? DS.accentStrong : DS.fg3)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(section.number)")
                    .font((compact ? Font.title2 : .title).weight(.bold).monospacedDigit())
                    .foregroundStyle(DS.accentStrong)
                Text(section.title)
                    .font((compact ? Font.title2 : .title).weight(.bold))
                    .foregroundStyle(DS.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func sectionBody(_ section: LessonSection) -> some View {
        switch section.step {
        case .explain(let s):
            ExplainStepView(step: s, instrument: instrument)
        case .demo(let s):
            DemoStepView(step: s, instrument: instrument, figureNumber: exampleNumber(of: section))
        case .practice(let s):
            TryItBox {
                TryItLessonCard(step: s, instrument: instrument, intervals: model.intervals,
                                seed: model.seed(for: section), stage: model.stage)
            }
        case .quiz(let s):
            CheckYourselfView(step: s, instrument: instrument, seed: model.seed(for: section))
        case .song(let s):
            TryItBox {
                SongStepView(step: s, instrument: instrument)
            }
        }
    }

    /// 1-based count among the chapter's examples.
    private func exampleNumber(of section: LessonSection) -> Int {
        model.sections.filter { $0.kind == .demo && $0.index <= section.index }.count
    }

    // MARK: Done

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isDone ? "You marked this chapter as read." : "Finished reading?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(DS.fg1)
            Text("Done only means read. Nothing here is scored, and you can come back any time.")
                .font(.subheadline)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    model.toggleDone()
                } label: {
                    Label(model.isDone ? "Mark as not done" : "Mark as done",
                          systemImage: model.isDone ? "arrow.uturn.backward" : "checkmark.circle")
                }
                .buttonStyle(TutorPrimaryButtonStyle(tint: model.isDone ? DS.fg2 : DS.accent))
                .frame(maxWidth: 300)
                Button("Close") {
                    TutorSynth.shared.stop()
                    onExit()
                }
                .buttonStyle(TutorSecondaryButtonStyle())
            }
            if let error = model.saveError {
                TutorMessageRow(text: error, systemImage: "exclamationmark.triangle", tone: .caution)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.accentSofter, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
    }
}

/// Tinted box around an exercise or song.
struct TryItBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.accentSoft, lineWidth: 1.5))
    }
}

/// A lesson practice step as a Try it card.
struct TryItLessonCard: View {
    @StateObject private var model: TryItModel

    init(step: PracticeStep, instrument: TutorInstrument, intervals: [Interval]?, seed: UInt64, stage: Int?) {
        _model = StateObject(wrappedValue: TryItModel(step: step, instrument: instrument, intervals: intervals, seed: seed,
                                                      stage: stage, listener: TutorListener(), player: TutorSequencePlayer.shared))
    }

    var body: some View {
        TryItCardView(model: model, showsPrompt: false)
    }
}
