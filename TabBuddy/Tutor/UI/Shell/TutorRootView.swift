//
//  TutorRootView.swift
//  TabBuddy
//
//  Tutor entry (AppPage.tutor). Regular width (iPad full screen, large Split
//  View / Stage Manager windows): a sidebar with the instrument switch, the
//  book's parts (stages), and the practice/help sections, next to a detail
//  pane. Compact width (iPhone, narrow iPad windows): one scrolling contents
//  page whose sections push onto the app's navigation stack. The two columns
//  are drawn here rather than with NavigationSplitView because this view is
//  itself pushed inside ContentView's NavigationStack, where a split view
//  cannot nest.
//
//  Chapters open full screen in `LessonPageView`; progress refreshes when
//  the page closes.
//

import SwiftData
import SwiftUI

struct TutorRootView: View {
    /// Opens a library score in the existing viewer (ContentView's navigation).
    var onOpenSong: ((FileItem) -> Void)? = nil

    @StateObject private var state = TutorShellState()
    @StateObject private var songs = TutorSongsLoader()
    @ObservedObject private var library = CurriculumLibrary.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext

    @State private var section: TutorSection = .path
    @State private var compactRoute: TutorSection?
    @State private var scrollTarget: String?
    @State private var activeLesson: LessonLaunch?
    @State private var practiceTab: TutorPracticeView.Tab?
    @State private var didApplyLaunchOptions = false

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        #if DEBUG
        if let debugView = TutorLessonDebugLaunch.overrideView() ?? TutorGameDebugLaunch.overrideView() {
            debugView
        } else {
            shell
        }
        #else
        shell
        #endif
    }

    private var shell: some View {
        Group {
            if library.content == nil {
                ProgressView("Loading lessons…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.paper)
            } else if isCompact {
                compactHome
            } else {
                splitLayout
            }
        }
        .navigationTitle("Tutor")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await library.loadIfNeeded()
            applyLaunchOptionsIfNeeded()
            state.refresh()
            songs.loadIfNeeded(context: modelContext)
        }
        .fullScreenCover(item: $activeLesson) { launch in
            LessonPageView(lesson: launch.lesson, instrument: state.instrument, initialSection: launch.sectionIndex,
                           store: state.store) {
                activeLesson = nil
                state.lessonDidClose()
            }
        }
        .navigationDestination(item: $compactRoute) { route in
            sectionContent(route)
                .navigationTitle(route.title)
                .navigationBarTitleDisplayMode(.inline)
        }
        .environmentObject(state)
    }

    // MARK: Regular width

    private var splitLayout: some View {
        HStack(spacing: 0) {
            TutorSidebar(section: $section, scrollTarget: $scrollTarget)
                .frame(width: 300)
            DS.separator.frame(width: 1).ignoresSafeArea(edges: .bottom)
            sectionContent(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.paper)
        }
        .background(DS.paper)
    }

    // MARK: Compact width

    private var compactHome: some View {
        Group {
            if let model = state.pathModel {
                TutorPathView(model: model, instrument: state.instrument, isCompact: true,
                              scrollTarget: $scrollTarget, onStart: open,
                              onSetDone: { state.setLessonDone($0, done: $1) }) {
                    VStack(alignment: .leading, spacing: 16) {
                        TutorInstrumentPicker()
                        pathHeader(model)
                        compactLinks
                    }
                }
            } else {
                missingCourse
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(TutorSection.allCases.filter { $0 != .path }) { s in
                        Button { compactRoute = s } label: { Label(s.title, systemImage: s.systemImage) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Tutor sections")
            }
        }
    }

    private var compactLinks: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach([TutorSection.practice, .flashcards, .games, .glossary, .calibration, .settings]) { s in
                Button { compactRoute = s } label: {
                    Label(s.title, systemImage: s.systemImage)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                            .strokeBorder(DS.separator, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.fg1)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionContent(_ s: TutorSection) -> some View {
        switch s {
        case .path:
            if let model = state.pathModel {
                TutorPathView(model: model, instrument: state.instrument, isCompact: isCompact,
                              scrollTarget: $scrollTarget, onStart: open,
                              onSetDone: { state.setLessonDone($0, done: $1) }) {
                    pathHeader(model)
                }
            } else {
                missingCourse
            }
        case .practice:
            TutorPracticeView(instrument: state.instrument, course: state.course, initialTab: practiceTab, onOpenLesson: open)
                .id(state.instrument)
        case .flashcards:
            if let course = state.course, let progress = state.progress {
                TutorFlashcardsView(course: course, progress: progress, instrument: state.instrument)
                    .id("\(state.instrument.rawValue)-\(progress.completedLessonIDs.count)")
            } else {
                missingCourse
            }
        case .songs:
            TutorSongsView(loader: songs, onOpenSong: onOpenSong)
        case .games:
            TutorGamesView()
        case .glossary:
            TutorGlossaryView()
        case .calibration:
            TutorCalibrationView(instrument: state.instrument)
                .id(state.instrument)
        case .settings:
            TutorSettingsView()
        }
    }

    private func pathHeader(_ model: TutorPathModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TutorContinueHero(card: model.continueCard, overallCompletion: model.progress.overallCompletion,
                              practiceDays: state.practiceDays, isCompact: isCompact, onStart: { open(LessonLaunch(lesson: $0)) },
                              onReviewPath: { scrollTarget = model.sections.first?.id })
            summaryCards(model)
        }
    }

    @ViewBuilder
    private func summaryCards(_ model: TutorPathModel) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 240 : 210), spacing: 14, alignment: .top)],
                  alignment: .leading, spacing: 14) {
            TutorPracticeCard(onOpen: { tab in
                practiceTab = tab
                if isCompact { compactRoute = .practice } else { section = .practice }
            }, onFlashcards: {
                if isCompact { compactRoute = .flashcards } else { section = .flashcards }
            })
            TutorSongsCard(loader: songs, course: model.course, progress: model.progress) {
                if isCompact { compactRoute = .songs } else { section = .songs }
            }
            TutorTodayCard(minutes: state.todayMinutes, goal: state.dailyGoalMinutes)
        }
    }

    private var missingCourse: some View {
        ContentUnavailableView("No lessons for \(state.instrument.displayName)",
                               systemImage: "graduationcap",
                               description: Text("The bundled lesson files could not be read."))
    }

    private func open(_ launch: LessonLaunch) {
        TutorSynth.shared.stop()
        activeLesson = launch
    }

    // MARK: Launch options (DEBUG)

    private func applyLaunchOptionsIfNeeded() {
        guard !didApplyLaunchOptions else { return }
        didApplyLaunchOptions = true
        if let instrument = TutorLaunchOptions.instrument { state.setInstrument(instrument) }
        if let n = TutorLaunchOptions.seedProgress { state.seedProgress(firstLessons: n) }
        var target: TutorSection?
        if TutorLaunchOptions.calibration { target = .calibration }
        if let name = TutorLaunchOptions.section, let s = TutorSection(launchName: name) { target = s }
        if let tab = TutorLaunchOptions.practiceTab.flatMap(TutorPracticeView.Tab.init(rawValue:)) { practiceTab = tab }
        if let target {
            if isCompact { compactRoute = target } else { section = target }
        }
    }
}

// MARK: - Sidebar

private struct TutorSidebar: View {
    @Binding var section: TutorSection
    @Binding var scrollTarget: String?
    @EnvironmentObject private var state: TutorShellState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TutorInstrumentPicker()
                    .padding(.horizontal, 4)

                group("Book") {
                    row(.path)
                    if let model = state.pathModel {
                        ForEach(model.sections) { s in
                            Button {
                                section = .path
                                scrollTarget = s.id
                            } label: {
                                HStack(spacing: 10) {
                                    TutorShellRing(value: s.completion, size: 20)
                                    Text("Part \(s.stage.order). \(s.stage.title)")
                                        .font(.subheadline)
                                        .foregroundStyle(s.isCurrent ? DS.fg1 : DS.fg2)
                                        .fontWeight(s.isCurrent ? .semibold : .regular)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, 30)
                                .padding(.trailing, 8)
                                .frame(minHeight: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                        }
                    }
                }

                group("Practice") {
                    row(.practice)
                    row(.flashcards)
                    row(.songs)
                    row(.games)
                }

                group("Help") {
                    row(.glossary)
                    row(.calibration)
                    row(.settings)
                }
            }
            .padding(16)
        }
        .background(DS.surface)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(DS.fg3)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            content()
        }
    }

    private func row(_ s: TutorSection) -> some View {
        Button {
            section = s
        } label: {
            HStack(spacing: 10) {
                Image(systemName: s.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(section == s ? DS.accentStrong : DS.accent)
                Text(s.title)
                    .font(.body.weight(section == s ? .semibold : .regular))
                    .foregroundStyle(DS.fg1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(section == s ? DS.accentSofter : .clear,
                        in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .keyboardShortcut(s.shortcut, modifiers: .command)
        .accessibilityLabel(s.title)
        .accessibilityAddTraits(section == s ? .isSelected : [])
    }
}

// MARK: - Instrument picker

struct TutorInstrumentPicker: View {
    @EnvironmentObject private var state: TutorShellState

    var body: some View {
        Picker("Instrument", selection: Binding(get: { state.instrument }, set: { state.setInstrument($0) })) {
            ForEach(TutorInstrument.allCases) { i in
                Label(i.displayName, systemImage: i == .guitar ? "guitars" : "pianokeys").tag(i)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
    }
}

// MARK: - Summary cards

/// Quick links into the Practice section and Flashcards.
struct TutorPracticeCard: View {
    var onOpen: (TutorPracticeView.Tab) -> Void
    var onFlashcards: () -> Void

    var body: some View {
        TutorShellCard(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Practice", systemImage: "music.quarternote.3")
                    .font(.headline)
                    .foregroundStyle(DS.fg1)
                Text("Scales, chords, intervals, and rhythms at your own tempo, without opening a chapter.")
                    .font(.subheadline)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    Button("Scales") { onOpen(.scales) }
                    Button("Chords") { onOpen(.chords) }
                    Button("Intervals") { onOpen(.intervals) }
                    Button("Rhythms") { onOpen(.rhythms) }
                    Button("Flashcards", action: onFlashcards)
                }
                .buttonStyle(.bordered)
                .font(.subheadline.weight(.medium))
            }
        }
    }
}

struct TutorTodayCard: View {
    let minutes: Int
    let goal: Int

    var body: some View {
        TutorShellCard(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Today", systemImage: "sun.max")
                    .font(.headline)
                    .foregroundStyle(DS.fg1)
                Text(minutes >= goal
                     ? "About \(minutes) min of chapters marked read today. Goal of \(goal) min met."
                     : minutes > 0
                     ? "About \(minutes) of \(goal) min, counted from chapters marked read."
                     : "Goal: \(goal) min, counted from chapters you mark as read. A short read still counts.")
                    .font(.subheadline)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                TutorShellProgressBar(value: goal > 0 ? Double(minutes) / Double(goal) : 0)
                Spacer(minLength: 0)
            }
        }
    }
}
