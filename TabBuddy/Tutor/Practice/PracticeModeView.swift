//
//  PracticeModeView.swift
//  TabBuddy
//
//  Practice mode chrome over the open score (TUTOR_IMPLEMENTATION.md §8):
//  a practice bar in the header seat, the practice range drawn natively (or
//  the original page left visible with an event strip), and a practice
//  transport with a large Start/Stop target. Space starts/stops a take,
//  → skips the current target in Wait mode, Escape leaves practice mode.
//

import SwiftUI

struct PracticeModeView: View {
    @StateObject private var controller: PracticeSessionController
    var session: PracticeSessionHandle?
    var onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showRange = false
    @State private var showTempo = false
    @State private var showCalibration = false

    /// - Parameter session: the host calls `session.close()` when it leaves the
    ///   screen; practice mode itself never closes on a transient disappear.
    init(context: PracticeScoreContext, session: PracticeSessionHandle? = nil, onClose: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: PracticeSessionController(context: context))
        self.session = session
        self.onClose = onClose
    }

    /// Tests and previews inject a controller.
    init(controller: PracticeSessionController, session: PracticeSessionHandle? = nil,
         onClose: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: controller)
        self.session = session
        self.onClose = onClose
    }

    private var isCompact: Bool { hSize == .compact }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            banners
            middle
            bottomPanel
        }
        .task { await controller.prepare() }
        // No `.onDisappear { close() }`: size-class changes and presentations can
        // make this view disappear briefly, which must not stop a take. Done and
        // the host's `session.close()` end the session.
        .onAppear { session?.register { [weak controller] in controller?.close() } }
        .onChange(of: scenePhase) { _, phase in
            // Only backgrounding stops a take; the microphone permission alert makes the scene inactive.
            if phase == .background { controller.stopTake(reason: "The take stopped when TabBuddy left the screen.") }
        }
        .sheet(isPresented: $showCalibration) {
            PracticeCalibrationSheet(instrument: controller.instrument) { controller.refreshCalibrationState() }
        }
        .modifier(PracticeReviewPresenter(controller: controller))
    }

    // MARK: Middle

    @ViewBuilder
    private var middle: some View {
        switch controller.phase {
        case .preparing:
            statusCard { ProgressView("Loading notes…") }
        case .unavailable(let reason):
            statusCard {
                VStack(spacing: 12) {
                    PracticeUnavailableCard(reason: reason)
                    Button("Close practice", action: close).buttonStyle(.bordered)
                }
            }
        default:
            if case .measureMap(_, let model) = controller.context.source {
                PracticeDrawnSurface(controller: controller, model: model)
            } else {
                // The original page stays visible and scrollable underneath.
                Color.clear.allowsHitTesting(false)
            }
        }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { content() }
            .padding(24)
            .background(DS.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.radiusCard))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.paper.opacity(0.85))
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: close) {
                    Label("Done", systemImage: "chevron.down")
                        .labelStyle(.titleAndIcon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DS.accent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Leave practice mode")

                VStack(alignment: .leading, spacing: 1) {
                    Text("Practice").font(.headline).foregroundStyle(DS.fg1)
                    Text(controller.context.title).font(.caption).foregroundStyle(DS.fg2).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !isCompact { controls }
                historyButton
            }
            if isCompact {
                ScrollView(.horizontal, showsIndicators: false) { controls }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(minHeight: DS.headerHeight)
        .background(OpaqueBar())
        .overlay(alignment: .bottom) { Hairline() }
        .disabled(controller.phase == .preparing)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: $controller.mode) {
                ForEach(PracticeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .accessibilityHint("Wait: the score waits for each note. Play-along: the score moves at the tempo.")

            Button { showRange = true } label: {
                chip(icon: "repeat", text: controller.range.map(PracticeDefaults.label) ?? "Measures")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showRange) { rangeEditor.presentationCompactAdaptation(.popover) }
            .accessibilityLabel("Practice range")
            .accessibilityValue(controller.range.map(PracticeDefaults.label) ?? "None")

            Button { showTempo = true } label: {
                chip(icon: "metronome", text: "\(Int(controller.tempoPercent))% · \(Int(controller.practiceBPM.rounded())) BPM")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTempo) { tempoEditor.presentationCompactAdaptation(.popover) }
            .accessibilityLabel("Practice speed")
            .accessibilityValue("\(Int(controller.tempoPercent)) percent")

            Menu {
                Picker("Instrument", selection: Binding(get: { controller.instrument },
                                                        set: { controller.setInstrument($0) })) {
                    ForEach(TutorInstrument.allCases) { Text($0.displayName).tag($0) }
                }
            } label: {
                chip(icon: controller.instrument == .piano ? "pianokeys" : "guitars",
                     text: controller.instrument.displayName)
            }
            .accessibilityLabel("Instrument")
            .accessibilityValue(controller.instrument.displayName)
        }
        .disabled(controller.isTakeActive || controller.phase == .analyzing)
    }

    private var historyButton: some View {
        Button {
            if let id = controller.takes.first?.id { controller.review = controller.payload(forTake: id) }
        } label: {
            TransportTileLabel(icon: "chart.bar.xaxis", label: "Takes", active: false)
        }
        .buttonStyle(.plain)
        .disabled(controller.takes.isEmpty || controller.isTakeActive)
        .opacity(controller.takes.isEmpty ? 0.45 : 1)
        .accessibilityLabel("Past takes")
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).monospacedDigit().lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(DS.surfaceInset, in: Capsule())
        .foregroundStyle(DS.fg1)
        .contentShape(Capsule())
    }

    private var rangeEditor: some View {
        let total = max(1, controller.totalMeasures)
        let range = controller.range ?? 0...0
        return Form {
            Section {
                Stepper("From measure \(range.lowerBound + 1)", value: Binding(
                    get: { range.lowerBound + 1 },
                    set: { controller.setRange(($0 - 1)...max($0 - 1, range.upperBound)) }), in: 1...total)
                Stepper("To measure \(range.upperBound + 1)", value: Binding(
                    get: { range.upperBound + 1 },
                    set: { controller.setRange(min(range.lowerBound, $0 - 1)...($0 - 1)) }), in: 1...total)
                Button("Whole piece") { controller.setRange(0...(total - 1)) }
            } footer: {
                Text("Starts from the score's loop when one is set. Short sections of 2–4 measures give the clearest feedback.")
            }
        }
        .frame(minWidth: 320, minHeight: 260)
    }

    private var tempoEditor: some View {
        Form {
            Section {
                Stepper("\(Int(controller.tempoPercent))% of the score tempo",
                        value: Binding(get: { controller.tempoPercent }, set: { controller.setTempoPercent($0) }),
                        in: PracticeTempo.range, step: 5)
                HStack {
                    ForEach(PracticeTempo.quickPercents, id: \.self) { pct in
                        Button("\(Int(pct))") { controller.setTempoPercent(pct) }
                            .buttonStyle(.bordered)
                            .tint(controller.tempoPercent == pct ? DS.accent : nil)
                    }
                }
            } footer: {
                Text("\(Int(controller.practiceBPM.rounded())) BPM. The same practice speed is used by the score's player.")
            }
        }
        .frame(minWidth: 360, minHeight: 220)
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 6) {
            if controller.permissionDenied {
                banner(icon: "mic.slash", text: "Microphone access is off, so TabBuddy can't hear you. Listening stays on this device.",
                       action: ("Open Settings", {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }), onDismiss: nil)
            }
            if controller.needsCalibration, !controller.calibrationPromptDismissed, !controller.isTakeActive {
                banner(icon: "timer", text: "Timing uses a standard 80 ms delay until this audio route is calibrated.",
                       action: ("Calibrate", { showCalibration = true }),
                       onDismiss: { controller.calibrationPromptDismissed = true })
            }
            if let notice = controller.notice, !Self.isUnreviewedNotice(notice) {
                banner(icon: "info.circle", text: notice, action: nil, onDismiss: { controller.notice = nil })
            }
            if controller.unreviewedTakeID != nil, !controller.isTakeActive {
                // A take saved when practice last closed mid-take.
                banner(icon: "tray.full",
                       text: controller.notice.flatMap { Self.isUnreviewedNotice($0) ? $0 : nil } ?? "Your last take was saved.",
                       action: ("Review", { controller.reviewUnreviewedTake() }),
                       onDismiss: { controller.dismissUnreviewedTake() })
            }
            if let message = controller.rangeMessage {
                banner(icon: "music.note", text: message, action: ("Change", { showRange = true }), onDismiss: nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .background(controller.context.source.drawsNatively ? TabPalette.light.page : Color.clear)
    }

    private static func isUnreviewedNotice(_ text: String) -> Bool { text.hasPrefix("Your last take was saved") }

    private func banner(icon: String, text: String, action: (String, () -> Void)?,
                        onDismiss: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(DS.fg2)
            Text(text).font(.subheadline).foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(action.0, action: action.1)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.accentStrong)
                    .frame(minHeight: 44)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(DS.fg3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusControl))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusControl).stroke(DS.separator))
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 8) {
            if !controller.context.source.drawsNatively, !controller.events.isEmpty {
                PracticeEventStrip(controller: controller)
            }
            HStack(spacing: 16) {
                statusArea
                Spacer(minLength: 8)
                if controller.mode == .wait, controller.phase == .listening {
                    Button { controller.skipCurrent() } label: {
                        TransportTileLabel(icon: "forward.frame", label: "Skip", active: false)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .accessibilityLabel("Skip this note")
                }
                startStopButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(OpaqueBar())
        .overlay(alignment: .top) { Hairline() }
    }

    @ViewBuilder
    private var statusArea: some View {
        switch controller.phase {
        case .countIn(let remaining):
            PracticePulseView(cursor: controller.cursor, beatsPerMeasure: controller.passage?.beatsPerMeasure ?? 4,
                              countInRemaining: remaining)
        case .listening where controller.mode == .playAlong:
            HStack(spacing: 14) {
                PracticePulseView(cursor: controller.cursor, beatsPerMeasure: controller.passage?.beatsPerMeasure ?? 4,
                                  countInRemaining: nil)
                PracticeLevelMeter(cursor: controller.cursor)
            }
        case .listening:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play").font(.caption).foregroundStyle(DS.fg2)
                    Text(controller.currentEvent.map(PracticeEventStrip.label) ?? "—")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(DS.fg1)
                        .accessibilityLabel("Next: \(controller.currentEvent.map(PracticeEventStrip.label) ?? "none")")
                }
                PracticeLevelMeter(cursor: controller.cursor)
            }
        case .starting:
            ProgressView("Starting the microphone…")
        case .analyzing:
            ProgressView("Analyzing the take…")
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text(idleTitle).font(.headline).foregroundStyle(DS.fg1)
                Text(idleDetail).font(.caption).foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var idleTitle: String {
        guard let range = controller.range else { return "Practice" }
        return "\(PracticeDefaults.label(range)) · \(controller.mode.title)"
    }

    private var idleDetail: String {
        switch controller.mode {
        case .wait: return "The score waits until it hears each note. Sound is off while listening."
        case .playAlong: return "Watch the count-in and beat pulse; sound is off while listening."
        }
    }

    private var startStopButton: some View {
        let active = controller.isTakeActive
        let diameter: CGFloat = isCompact ? 60 : 72
        return Button { controller.toggleTake() } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(active ? DS.fg1 : DS.accent)
                        .frame(width: diameter, height: diameter)
                        .shadow(color: DS.accent.opacity(0.3), radius: 8, y: 4)
                    Image(systemName: active ? "stop.fill" : "mic.fill")
                        .font(.title)
                        .foregroundStyle(active ? DS.paper : Color.white)
                }
                if !isCompact {
                    Text(active ? "Stop" : "Start take").font(.caption.weight(.semibold)).foregroundStyle(DS.fg2)
                }
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!(active || controller.canStart))
        .opacity(active || controller.canStart ? 1 : 0.45)
        .accessibilityLabel(active ? "Stop take" : "Start take")
        .accessibilityHint("Space bar")
    }

    private func close() {
        controller.close()
        onClose()
    }
}

/// Presents the review as a large sheet on every size class. The presentation
/// is attached unconditionally so the practice chrome keeps its identity when
/// the size class changes (iPad Split View, Stage Manager). A sheet, unlike a
/// full-screen cover, leaves the viewer underneath on screen, so the viewer's
/// `onDisappear` teardown doesn't run while the review is up.
struct PracticeReviewPresenter: ViewModifier {
    @ObservedObject var controller: PracticeSessionController

    func body(content: Content) -> some View {
        // A Bool binding keeps the page up while switching between takes.
        let presented = Binding(get: { controller.review != nil }, set: { if !$0 { controller.review = nil } })
        content.sheet(isPresented: presented) {
            current.modifier(PracticeReviewSizing())
        }
    }

    @ViewBuilder
    private var current: some View {
        if let payload = controller.review { review(payload) }
    }

    private func review(_ payload: PracticeReviewPayload) -> some View {
        TakeReviewView(payload: payload, takes: controller.takes, totalMeasures: controller.totalMeasures,
                       onApply: { action in
                           controller.apply(action)
                           controller.review = nil
                       },
                       onSelectTake: { id in controller.review = controller.payload(forTake: id) },
                       onDeleteTake: { id in controller.deleteTake(id) },
                       onDone: { controller.review = nil })
    }
}

/// Page-sized sheet on iOS 18 and later (two columns fit on iPad); a
/// large-detent sheet on iOS 17.
struct PracticeReviewSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.page).presentationDetents([.large])
        } else {
            content.presentationDetents([.large])
        }
    }
}

/// Bar material over paper, so the viewer chrome underneath doesn't show through.
private struct OpaqueBar: View {
    var body: some View {
        ZStack {
            DS.paper
            BarMaterial()
        }
        .ignoresSafeArea()
    }
}
