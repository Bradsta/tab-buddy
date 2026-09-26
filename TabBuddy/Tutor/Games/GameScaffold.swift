//
//  GameScaffold.swift
//  TabBuddy
//
//  The screen every game shares: intro card (how to play, what it trains,
//  microphone use, level and mode options, personal best), visual countdown,
//  play area with a stats bar and feedback line, results card, and the
//  microphone-off state. Regular width puts options and stats in a side
//  column; compact width stacks them. Keyboard: Space or Return starts and
//  replays; games add their own keys.
//

import SwiftUI

struct GameScreen<Model: GameModel, Options: View, Play: View>: View {
    @ObservedObject var model: Model
    @ViewBuilder var options: () -> Options
    /// Play area; the flag is true for regular-width layouts.
    @ViewBuilder var play: (_ wide: Bool) -> Play

    var body: some View {
        WidthReader { width in
            let wide = TutorLayout.isWide(width)
            ScrollView {
                VStack(alignment: .leading, spacing: wide ? 24 : 18) {
                    content(wide: wide)
                }
                .padding(wide ? 32 : 16)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(DS.paper.ignoresSafeArea())
        .environment(\.tutorDiagramTapEnabled, !model.isListening && !model.phase.isActive)
        .onDisappear { model.cancel() }
        .background(startShortcuts)
    }

    @ViewBuilder
    private func content(wide: Bool) -> some View {
        switch model.phase {
        case .intro:
            introCard(wide: wide)
        case .starting:
            GameCenteredMessage(systemImage: "mic", title: "Opening the microphone…", detail: nil)
        case .countdown(let n):
            countdown(n, wide: wide)
        case .playing:
            playing(wide: wide)
        case .results:
            if let result = model.result { resultsCard(result, wide: wide) }
        case .micDenied:
            micDenied
        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 16) {
                TutorMessageRow(text: message, systemImage: "exclamationmark.triangle", tone: .caution)
                Button("Back") { model.showIntro() }
                    .buttonStyle(TutorSecondaryButtonStyle())
            }
        }
    }

    // MARK: Keyboard

    @ViewBuilder
    private var startShortcuts: some View {
        if model.phase == .intro || model.phase == .results {
            ZStack {
                KeyboardShortcutButton(key: .space) { Task { await model.start() } }
                KeyboardShortcutButton(key: .return) { Task { await model.start() } }
            }
        }
    }

    // MARK: Intro

    private func introCard(wide: Bool) -> some View {
        let intro = model.intro
        let explain = VStack(alignment: .leading, spacing: 16) {
            Text(model.title)
                .font(wide ? .largeTitle.weight(.bold) : .title.weight(.bold))
                .foregroundStyle(DS.fg1)
            VStack(alignment: .leading, spacing: 10) {
                Text("How to play").font(.headline).foregroundStyle(DS.fg2)
                ForEach(Array(intro.howToPlay.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(DS.accentStrong)
                            .frame(width: 30, height: 30)
                            .background(DS.accentSofter, in: Circle())
                        Text(step)
                            .font(wide ? .title3 : .body)
                            .foregroundStyle(DS.fg1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            TutorMessageRow(text: intro.trains, systemImage: "graduationcap", tone: .accent)
            Label(intro.microphone, systemImage: model.listensFromStart ? "mic" : "hand.tap")
                .font(.callout)
                .foregroundStyle(DS.fg2)
            if model.listensFromStart && model.listener.permissionDenied {
                micOffNotice
            }
        }
        let side = VStack(alignment: .leading, spacing: 18) {
            if model.levelCount > 1 { levelPicker }
            options()
            bestTile
            Button {
                Task { await model.start() }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(TutorPrimaryButtonStyle())
            .accessibilityHint("Space or Return also starts")
        }
        return Group {
            if wide {
                HStack(alignment: .top, spacing: 32) {
                    explain.frame(maxWidth: .infinity, alignment: .leading)
                    TutorCard(padding: 20) { side }
                        .frame(width: TutorLayout.sidePanelWidth + 40)
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    explain
                    TutorCard { side }
                }
            }
        }
    }

    private var levelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Level").font(.headline).foregroundStyle(DS.fg2)
            if model.levelPickerIsMenu {
                Picker("Level", selection: $model.level) {
                    ForEach(1...model.levelCount, id: \.self) { l in
                        Text(model.levelName(l)).tag(l)
                    }
                }
                .pickerStyle(.menu)
                .tint(DS.accentStrong)
                .frame(minHeight: 44)
            } else {
                Picker("Level", selection: $model.level) {
                    ForEach(1...model.levelCount, id: \.self) { l in
                        Text(model.levelName(l)).tag(l)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
            }
            Text(model.levelDetail(model.level))
                .font(.callout)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bestTile: some View {
        HStack(spacing: 12) {
            Image(systemName: "trophy")
                .font(.title2)
                .foregroundStyle(DS.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Personal best").font(.caption).foregroundStyle(DS.fg2)
                Text(model.best.map(model.formatScore) ?? "Not yet played")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(DS.fg1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var micOffNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Microphone access is off", systemImage: "mic.slash")
                .font(.headline)
                .foregroundStyle(DS.cautionText)
            if model.supportsTapFallback {
                Text("You can still play with taps. Turn on the microphone in Settings to play on your instrument.")
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Settings") { TutorAudioHelpers.openSettings() }
                .buttonStyle(TutorSecondaryButtonStyle())
        }
        .padding(14)
        .background(DS.cautionSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
    }

    // MARK: Countdown

    private func countdown(_ n: Int, wide: Bool) -> some View {
        VStack(spacing: 24) {
            Text("Get ready")
                .font(.title2.weight(.semibold))
                .foregroundStyle(DS.fg2)
            Text("\(n)")
                .font(.system(size: wide ? 160 : 110, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(DS.accentStrong)
                .frame(width: wide ? 260 : 180, height: wide ? 260 : 180)
                .background(DS.accentSofter, in: Circle())
                .contentTransition(.numericText())
                .animation(DS.motionSlow, value: n)
                .accessibilityLabel("Starting in \(n)")
            if model.isListening {
                InputLevelMeter(isActive: true) { model.listener.inputLevel }
                    .frame(maxWidth: 360)
                Text("Listening. Your device stays silent while you play.")
                    .font(.callout)
                    .foregroundStyle(DS.fg3)
            }
            Button("Cancel") { model.showIntro() }
                .buttonStyle(TutorSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, wide ? 40 : 16)
    }

    // MARK: Playing

    private func playing(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 20 : 14) {
            statsBar(wide: wide)
            play(wide)
            if let feedback = model.feedback {
                TutorMessageRow(text: feedback.text, systemImage: feedback.systemImage, tone: feedback.tone)
                    .font(wide ? .title3 : .body)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if model.isListening {
                InputLevelMeter(isActive: true) { model.listener.inputLevel }
                    .frame(maxWidth: 420)
            }
        }
        .animation(DS.motionFast, value: model.feedback)
    }

    private func statsBar(wide: Bool) -> some View {
        HStack(spacing: wide ? 14 : 8) {
            if let remaining = model.remaining, let duration = model.duration {
                GameTimerRing(remaining: remaining, total: duration, size: wide ? 76 : 58)
            }
            ForEach(model.hud) { stat in
                GameStatTile(stat: stat, large: wide)
            }
            Spacer(minLength: 0)
            Button {
                model.endEarly()
            } label: {
                if wide {
                    Label("End", systemImage: "stop.fill")
                } else {
                    Image(systemName: "stop.fill")
                }
            }
            .buttonStyle(TutorSecondaryButtonStyle())
            .fixedSize()
            .accessibilityLabel("End")
            .accessibilityHint("Ends the game and shows your score")
        }
    }

    // MARK: Results

    private func resultsCard(_ result: GameResult, wide: Bool) -> some View {
        let scoreBlock = VStack(alignment: .leading, spacing: 12) {
            Text(result.unsure ? "Not sure" : "Your score")
                .font(.headline)
                .foregroundStyle(DS.fg2)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(result.scoreText)
                    .font(.system(size: wide ? 88 : 64, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(result.unsure ? DS.fg2 : DS.fg1)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if result.isNewBest {
                    TutorStatusChip(text: "New personal best", systemImage: "trophy.fill", tone: .accent)
                }
            }
            Text(result.caption)
                .font(wide ? .title3 : .body)
                .foregroundStyle(DS.fg2)
            if result.recordsBest, !result.unsure {
                Text(bestLine(result))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(DS.fg3)
            }
            ForEach(result.details, id: \.self) { line in
                Text(line)
                    .font(.body)
                    .foregroundStyle(DS.fg1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TutorMessageRow(text: result.nextStep, systemImage: "arrow.forward.circle", tone: .accent)
        }
        let actions = VStack(alignment: .leading, spacing: 14) {
            Button {
                Task { await model.start() }
            } label: {
                Label("Play again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(TutorPrimaryButtonStyle())
            .accessibilityHint("Space or Return also starts")
            if model.levelCount > 1 { levelPicker }
            options()
        }
        return Group {
            if wide {
                HStack(alignment: .top, spacing: 32) {
                    TutorCard(padding: 24) { scoreBlock }
                    actions.frame(width: TutorLayout.sidePanelWidth)
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    TutorCard { scoreBlock }
                    actions
                }
            }
        }
    }

    private func bestLine(_ result: GameResult) -> String {
        if let previous = result.previousBest {
            return result.isNewBest ? "Previous best: \(model.formatScore(previous))"
                                    : "Personal best: \(model.formatScore(previous))"
        }
        return result.isNewBest ? "First score saved" : "No score saved yet"
    }

    // MARK: Microphone off

    private var micDenied: some View {
        VStack(alignment: .leading, spacing: 16) {
            MicrophoneOffPanel(onSkip: nil)
            HStack(spacing: 12) {
                if model.supportsTapFallback {
                    Button {
                        model.useTapFallback()
                        model.showIntro()
                    } label: {
                        Label("Play with taps instead", systemImage: "hand.tap")
                    }
                    .buttonStyle(TutorSecondaryButtonStyle())
                }
                Button("Back") { model.showIntro() }
                    .buttonStyle(TutorSecondaryButtonStyle())
            }
        }
    }
}

// MARK: - Components

struct GameCenteredMessage: View {
    var systemImage: String
    var title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(DS.accent)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(DS.fg1)
            if let detail { Text(detail).foregroundStyle(DS.fg2) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

struct GameStatTile: View {
    var stat: GameStat
    var large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stat.label)
                .font(.caption)
                .foregroundStyle(DS.fg2)
                .lineLimit(1)
            Text(stat.value)
                .font((large ? Font.title : Font.title3).weight(.bold).monospacedDigit())
                .foregroundStyle(DS.fg1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, large ? 16 : 10)
        .padding(.vertical, large ? 10 : 7)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(DS.separator))
        .accessibilityElement(children: .combine)
    }
}

/// Seconds left as a ring with the number inside.
struct GameTimerRing: View {
    var remaining: TimeInterval
    var total: TimeInterval
    var size: CGFloat

    var body: some View {
        let fraction = total > 0 ? max(0, min(1, remaining / total)) : 0
        ZStack {
            Circle().stroke(DS.surfaceInset, lineWidth: size * 0.1)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(remaining <= 5 ? DS.accentStrong : DS.accent,
                        style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(ceil(remaining)))")
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(DS.fg1)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(ceil(remaining))) seconds left")
    }
}

/// Large answer buttons with number-key shortcuts (1–9).
struct GameChoiceGrid: View {
    var choices: [String]
    /// Index of the right answer once answered, else nil.
    var revealedCorrect: Int?
    var chosen: Int?
    var enabled: Bool
    var wide: Bool
    var onChoose: (Int) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: wide ? 220 : 150), spacing: 12)]
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(choices.enumerated()), id: \.offset) { i, choice in
                Button {
                    onChoose(i)
                } label: {
                    HStack(spacing: 10) {
                        Text("\(i + 1)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(DS.fg3)
                            .frame(width: 22)
                        Text(choice)
                            .font(wide ? .title3.weight(.semibold) : .headline)
                            .foregroundStyle(DS.fg1)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if let icon = icon(i) {
                            Image(systemName: icon.name).foregroundStyle(icon.color)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: wide ? 72 : 60)
                    .background(fill(i), in: RoundedRectangle(cornerRadius: DS.radiusControl + 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusControl + 3, style: .continuous)
                        .strokeBorder(stroke(i), lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Answered choices stay at full strength; only unanswered waiting dims.
                .disabled(!enabled && revealedCorrect == nil)
                .allowsHitTesting(enabled)
                .keyboardShortcut(i < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: []) : nil)
                .accessibilityLabel(choice)
                .accessibilityValue(accessibilityValue(i))
            }
        }
        .opacity(enabled || revealedCorrect != nil ? 1 : 0.6)
    }

    private func icon(_ i: Int) -> (name: String, color: Color)? {
        guard let correct = revealedCorrect else { return nil }
        if i == correct { return ("checkmark.circle.fill", .green) }
        if i == chosen { return ("arrow.uturn.left.circle", DS.cautionText) }
        return nil
    }

    private func fill(_ i: Int) -> Color {
        guard let correct = revealedCorrect else { return DS.surface }
        if i == correct { return Color.green.opacity(0.14) }
        if i == chosen { return DS.cautionSoft }
        return DS.surface
    }

    private func stroke(_ i: Int) -> Color {
        guard let correct = revealedCorrect else { return DS.separator }
        if i == correct { return Color.green.opacity(0.5) }
        if i == chosen { return DS.cautionText.opacity(0.4) }
        return DS.separator
    }

    private func accessibilityValue(_ i: Int) -> String {
        guard let correct = revealedCorrect else { return "" }
        if i == correct { return "Correct answer" }
        if i == chosen { return "Your answer" }
        return ""
    }
}

/// Round progress dots (10-round games).
struct GameRoundDots: View {
    var total: Int
    var current: Int
    var outcomes: [Bool?]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                let outcome = i < outcomes.count ? outcomes[i] : nil
                Circle()
                    .fill(color(i, outcome))
                    .frame(width: i == current ? 14 : 10, height: i == current ? 14 : 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Round \(min(total, current + 1)) of \(total)")
    }

    private func color(_ i: Int, _ outcome: Bool?) -> Color {
        switch outcome {
        case .some(true): return Color.green.opacity(0.8)
        case .some(false): return DS.cautionText.opacity(0.5)
        case .none: return i == current ? DS.accent : DS.surfaceInset
        }
    }
}

/// Segmented choice between tapping and playing on the instrument.
struct GameInputModePicker: View {
    var title: String = "Answer by"
    @Binding var playOnInstrument: Bool
    var tapLabel: String = "Tapping"
    var playLabel: String = "Playing"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(DS.fg2)
            Picker(title, selection: $playOnInstrument) {
                Label(tapLabel, systemImage: "hand.tap").tag(false)
                Label(playLabel, systemImage: "mic").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
        }
    }
}
