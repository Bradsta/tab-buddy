//
//  TabPlayerView.swift
//  TabBuddy
//
//  The drawn Tab Player: a scrollable stack of `DrawnTabSystemView`s driven by
//  the shared `PlaybackCoordinator`, plus the shared `TabTransportBar` and a
//  Display popover (notation, rhythm, size, auto-scroll, tuning/capo).
//
//  Embedded by `TabViewerView` for text MeasureMap-backed tabs. PDFs keep their
//  PDFKit fallback; the raw "Original" text view reuses `TabTransportBar` too.
//

import SwiftUI

enum NotationMode: String { case tabOnly, tabAndStaff }
enum AutoScrollMode: String { case off, follow, line }

struct TabPlayerView: View {
    let map: MeasureMap
    let file: FileItem?
    let subtitle: String

    @ObservedObject var coordinator: PlaybackCoordinator
    @ObservedObject var metronome: MetronomeEngine
    @ObservedObject var notePlayer: NotePlaybackEngine
    @Binding var userBPM: Double

    @Environment(\.modelContext) private var context

    // –– Persisted view preferences ––
    @AppStorage("player.notation") private var notationRaw = NotationMode.tabOnly.rawValue
    @AppStorage("player.showRhythm") private var showRhythm = true
    @AppStorage("player.fontScale") private var fontScale = 1.0
    @AppStorage("player.autoScroll") private var autoScrollRaw = AutoScrollMode.follow.rawValue

    // –– Session state ––
    @State private var model: TabRenderModel = .empty
    @State private var originalBPM: Double = 120

    // Loop (global measure indices, inclusive)
    @State private var loopEnabled = false
    @State private var loopStart: Int?
    @State private var loopEnd: Int?

    // Auto-scroll bookkeeping
    @State private var viewportHeight: CGFloat = 0
    @State private var lastAutoScrollTarget = -1

    private var notation: NotationMode { NotationMode(rawValue: notationRaw) ?? .tabOnly }
    private var autoScroll: AutoScrollMode { AutoScrollMode(rawValue: autoScrollRaw) ?? .follow }
    private var showStaff: Bool { notation == .tabAndStaff }
    private var beatsPerMeasure: Int {
        map.timeSignature?.beats ?? model.systems.first?.measures.first?.beatCount ?? 4
    }

    var body: some View {
        VStack(spacing: 0) {
            systemsScroll(palette: .light, scale: fontScale)
            Divider()
            TabTransportBar(
                coordinator: coordinator,
                metronome: metronome,
                notePlayer: notePlayer,
                userBPM: $userBPM,
                originalBPM: originalBPM,
                totalMeasures: model.totalMeasures,
                beatsPerMeasure: beatsPerMeasure,
                loopEnabled: $loopEnabled,
                loopStart: $loopStart,
                loopEnd: $loopEnd,
                onLoopChanged: { applyLoop(); persistLoop() },
                onSeek: { lastAutoScrollTarget = -1; notePlayer.stopNotes() },
                displayContent: { displayPopover }
            )
        }
        .onAppear { configure() }
        .onChange(of: map.measureCount) { _ in
            model = TabRenderModelBuilder.build(from: map)
        }
        .onChange(of: userBPM) { coordinator.bpm = $0 }
    }

    // MARK: - Setup

    private func configure() {
        model = TabRenderModelBuilder.build(from: map)
        originalBPM = map.bpm ?? userBPM
        if originalBPM <= 0 { originalBPM = 120 }
        if let s = file?.loopStartMeasure, let e = file?.loopEndMeasure {
            loopStart = s; loopEnd = e; loopEnabled = true
            applyLoop()
        }
    }

    // MARK: - Systems scroll

    @ViewBuilder
    private func systemsScroll(palette: TabPalette, scale: CGFloat) -> some View {
        let curSys = currentSystemIndex   // resolve once per render, not per system
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let fw = forewordText {
                        proseBlock("Foreword", fw)
                    }
                    ForEach(model.systems) { sys in
                        DrawnTabSystemView(
                            system: sys,
                            model: model,
                            palette: palette,
                            scale: scale,
                            showRhythm: showRhythm,
                            showStaff: showStaff,
                            isCurrentSystem: sys.index == curSys,
                            currentMeasure: coordinator.currentMeasureIndex,
                            beatFraction: coordinator.beatFraction,
                            isPlaying: coordinator.isPlaying,
                            loopStart: loopEnabled ? loopStart : nil,
                            loopEnd: loopEnabled ? loopEnd : nil,
                            onSeek: { handleTap(measure: $0) }
                        )
                        .id(sys.index)
                    }
                    if let aw = afterwordText {
                        proseBlock("Afterword", aw)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
            }
            .background(palette.page)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { viewportHeight = $0 }
            })
            .onChange(of: currentSystemIndex) { sys in
                guard autoScroll != .off, coordinator.isPlaying else { return }
                let (target, anchor) = autoScrollTarget(currentSystem: sys, scale: scale)
                // Don't re-issue the same scroll — this is what keeps a loop that
                // fits on screen from shifting back and forth every pass.
                guard target != lastAutoScrollTarget else { return }
                lastAutoScrollTarget = target
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(target, anchor: anchor)
                }
            }
        }
    }

    /// Where to scroll for the current playback position. When a loop is active
    /// and its systems all fit in the viewport, lock onto the loop's middle
    /// system (a fixed target) so the view holds still across passes; otherwise
    /// follow the current system.
    private func autoScrollTarget(currentSystem: Int, scale: CGFloat) -> (Int, UnitPoint) {
        if loopEnabled, let ls = loopStart, let le = loopEnd, loopFitsOnScreen(scale: scale) {
            let firstSys = systemIndex(forMeasure: min(ls, le))
            let lastSys = systemIndex(forMeasure: max(ls, le))
            return ((firstSys + lastSys) / 2, .center)
        }
        return (currentSystem, autoScroll == .follow ? .center : .top)
    }

    private func loopFitsOnScreen(scale: CGFloat) -> Bool {
        guard loopEnabled, let ls = loopStart, let le = loopEnd, viewportHeight > 0 else { return false }
        let span = systemIndex(forMeasure: max(ls, le)) - systemIndex(forMeasure: min(ls, le)) + 1
        let perSystem = TabMetrics(scale: scale, showRhythm: showRhythm, showStaff: showStaff).total + 8
        return CGFloat(span) * perSystem <= viewportHeight
    }

    private func systemIndex(forMeasure measure: Int) -> Int {
        for sys in model.systems where sys.measures.contains(where: { $0.globalIndex == measure }) {
            return sys.index
        }
        return 0
    }

    // MARK: - Foreword / afterword

    private var forewordText: String? {
        nonEmpty(map.comments)
    }
    private var afterwordText: String? {
        nonEmpty(map.afterword)
    }
    private func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private func proseBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2).fontWeight(.bold).textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
    }

    private var currentSystemIndex: Int {
        for sys in model.systems where sys.measures.contains(where: { $0.globalIndex == coordinator.currentMeasureIndex }) {
            return sys.index
        }
        return 0
    }

    // MARK: - Loop

    /// While looping, a tap re-anchors the nearer A/B bound; otherwise it seeks.
    private func handleTap(measure g: Int) {
        if loopEnabled {
            guard let s = loopStart else { loopStart = g; applyLoop(); persistLoop(); return }
            if g < s { loopStart = g } else { loopEnd = g }
            applyLoop(); persistLoop()
        } else {
            notePlayer.stopNotes()
            lastAutoScrollTarget = -1
            coordinator.seekToMeasure(g)
        }
    }

    private func applyLoop() {
        lastAutoScrollTarget = -1   // re-evaluate the scroll lock for the new loop
        if loopEnabled, let s = loopStart, let e = loopEnd {
            coordinator.loopStartMeasure = min(s, e)
            coordinator.loopEndMeasure = max(s, e)
        } else {
            coordinator.loopStartMeasure = nil
            coordinator.loopEndMeasure = nil
        }
    }

    private func persistLoop() {
        file?.loopStartMeasure = loopEnabled ? loopStart : nil
        file?.loopEndMeasure = loopEnabled ? loopEnd : nil
        try? context.save()
    }

    // MARK: - Display popover

    private var displayPopover: some View {
        let mode = Binding(get: { notation }, set: { notationRaw = $0.rawValue })
        return Form {
            Section("Notation") {
                Picker("Notation", selection: mode) {
                    Text("Tab only").tag(NotationMode.tabOnly)
                    Text("Tab + staff").tag(NotationMode.tabAndStaff)
                }.pickerStyle(.segmented)
                Toggle("Rhythm letters", isOn: $showRhythm)
                HStack {
                    Text("Size")
                    Spacer()
                    Button { fontScale = max(0.8, fontScale - 0.1) } label: { Image(systemName: "textformat.size.smaller") }
                    Text("\(Int(fontScale * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button { fontScale = min(1.8, fontScale + 0.1) } label: { Image(systemName: "textformat.size.larger") }
                }.buttonStyle(.borderless)
            }
            Section("Auto-scroll") {
                Picker("Auto-scroll", selection: Binding(
                    get: { autoScroll }, set: { autoScrollRaw = $0.rawValue })) {
                    Text("Off").tag(AutoScrollMode.off)
                    Text("Follow playback").tag(AutoScrollMode.follow)
                    Text("Line by line").tag(AutoScrollMode.line)
                }.pickerStyle(.inline)
            }
            Section("Tuning & capo") {
                LabeledContent("Tuning", value: map.tuning ?? "Standard")
                LabeledContent("Capo", value: map.capoSemitones.map { $0 == 0 ? "None" : "\($0)" } ?? "None")
            }
        }
        .frame(minWidth: 320, minHeight: 440)
    }
}
