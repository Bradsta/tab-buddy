//
//  TutorPathView.swift
//  TabBuddy
//
//  The learning path: a "Continue" hero card, summary cards (reviews, songs,
//  today), then each stage as a header followed by its lesson nodes on a
//  vertical rail. The order is a recommendation; every lesson opens, and the
//  lesson detail can mark a lesson done to skip it. Optional side branches
//  hang off the rail after the lesson they suggest following. Tapping a node
//  opens the lesson detail (popover on iPad, sheet on iPhone).
//

import SwiftUI

struct TutorPathView<Header: View>: View {
    let model: TutorPathModel
    let instrument: TutorInstrument
    let isCompact: Bool
    /// Stage id to scroll to (sidebar selection); cleared after scrolling.
    @Binding var scrollTarget: String?
    var onStart: (Lesson) -> Void
    /// Marks a lesson done (skip ahead) or not done.
    var onSetDone: (Lesson, Bool) -> Void = { _, _ in }
    @ViewBuilder var header: Header

    @State private var selectedLessonID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 28)
                    ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                        stageBlock(section, isFirst: index == 0, isLast: index == model.sections.count - 1)
                            .id(section.id)
                    }
                    Text("Side branches are optional. The main path never waits for them.")
                        .font(.footnote)
                        .foregroundStyle(DS.fg3)
                        .padding(.top, 24)
                }
                .padding(.horizontal, isCompact ? 16 : 32)
                .padding(.vertical, isCompact ? 16 : 28)
                .tutorReadableWidth(860)
            }
            .background(DS.paper)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(DS.motionSlow) { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
            .onAppear {
                if let target = scrollTarget {
                    proxy.scrollTo(target, anchor: .top)
                    scrollTarget = nil
                }
            }
        }
    }

    // MARK: Stage

    @ViewBuilder
    private func stageBlock(_ section: TutorStageSection, isFirst: Bool, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stageHeader(section)
                .padding(.top, isFirst ? 0 : 28)
                .padding(.bottom, 14)
            ForEach(Array(section.nodes.enumerated()), id: \.element.id) { i, node in
                let lastNode = i == section.nodes.count - 1
                nodeRow(node, stage: section.stage, railTop: true, railBottom: !(isLast && lastNode))
                ForEach(section.branches(after: node.id)) { branch in
                    branchBlock(branch, stage: section.stage, railBottom: !(isLast && lastNode))
                }
            }
        }
    }

    private func stageHeader(_ section: TutorStageSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Stage \(section.stage.order)".uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(section.isCurrent ? DS.accentStrong : DS.fg3)
                if section.isCurrent { TutorShellChip(text: "You are here") }
                Spacer()
                Text("\(section.completedCount) of \(section.nodes.count) · \(Int((section.completion * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(DS.fg2)
            }
            Text(section.stage.title)
                .font(isCompact ? .title2.weight(.bold) : .title.weight(.bold))
                .foregroundStyle(DS.fg1)
            Text(section.stage.summary)
                .font(.body)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
            TutorShellProgressBar(value: section.completion)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Nodes

    private var markerSize: CGFloat { isCompact ? 40 : 48 }
    private var railWidth: CGFloat { markerSize + 12 }

    private func rail(top: Bool, bottom: Bool, completedAbove: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(top ? (completedAbove ? DS.accent : DS.separatorStrong) : .clear).frame(width: 3)
            Rectangle().fill(bottom ? DS.separatorStrong : .clear).frame(width: 3)
        }
        .frame(width: railWidth)
    }

    private func nodeRow(_ node: TutorPathNode, stage: Stage, railTop: Bool, railBottom: Bool) -> some View {
        Button {
            selectedLessonID = node.id
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    rail(top: railTop, bottom: railBottom, completedAbove: node.state == .completed)
                    TutorShellNodeMarker(state: node.state, number: node.number, isCurrent: node.isCurrent, size: markerSize)
                }
                .frame(width: railWidth)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.lesson.title)
                        .font(isCompact ? .headline : .title3.weight(.semibold))
                        .foregroundStyle(node.state == .locked ? DS.fg2 : DS.fg1)
                        .multilineTextAlignment(.leading)
                    Text(meta(node))
                        .font(.subheadline)
                        .foregroundStyle(DS.fg3)
                }
                Spacer(minLength: 8)
                if node.isCurrent {
                    TutorShellChip(text: "Up next")
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.fg3)
            }
            .padding(.vertical, 8)
            .padding(.trailing, 12)
            .frame(minHeight: isCompact ? 64 : 76)
            .background(node.isCurrent ? DS.accentSofter : .clear,
                        in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(node.lesson.title), \(stateLabel(node.state))")
        .popover(isPresented: Binding(get: { selectedLessonID == node.id },
                                      set: { if !$0, selectedLessonID == node.id { selectedLessonID = nil } })) {
            TutorLessonDetailView(node: node, stage: stage, instrument: instrument,
                                  onStart: { lesson in
                                      selectedLessonID = nil
                                      onStart(lesson)
                                  },
                                  onSetDone: { lesson, done in
                                      selectedLessonID = nil
                                      onSetDone(lesson, done)
                                  },
                                  onClose: { selectedLessonID = nil })
                .frame(idealWidth: 440, idealHeight: 560)
                .presentationDetents([.medium, .large])
        }
    }

    private func meta(_ node: TutorPathNode) -> String {
        var parts = ["\(node.lesson.minutes) min"]
        switch node.state {
        case .completed: parts.append("Done")
        case .inProgress: parts.append("In progress")
        case .locked: parts.append("Locked")
        case .available: break
        }
        if node.lesson.steps.contains(where: { if case .practice = $0 { return true }; return false }) {
            parts.append("Mic")
        }
        return parts.joined(separator: " · ")
    }

    private func stateLabel(_ state: LessonState) -> String {
        switch state {
        case .locked: return "locked"
        case .available: return "available"
        case .inProgress: return "in progress"
        case .completed: return "completed"
        }
    }

    // MARK: Branch

    private func branchBlock(_ branch: TutorBranchSection, stage: Stage, railBottom: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                rail(top: true, bottom: railBottom, completedAbove: false)
                // Dashed connector from the rail to the detour card.
                Path { p in
                    p.move(to: CGPoint(x: railWidth / 2, y: 30))
                    p.addLine(to: CGPoint(x: railWidth + (isCompact ? 8 : 24), y: 30))
                }
                .stroke(DS.separatorStrong, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                .frame(width: railWidth + (isCompact ? 8 : 24), height: 40, alignment: .topLeading)
                .offset(x: (isCompact ? 4 : 12))
            }
            .frame(width: railWidth)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TutorShellChip(text: "Optional detour", systemImage: "arrow.triangle.branch",
                              fill: DS.surfaceInset, foreground: DS.fg2)
                    Spacer()
                    Text("\(Int((branch.completion * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(DS.fg2)
                }
                Text(branch.branch.title)
                    .font(.headline)
                    .foregroundStyle(DS.fg1)
                Text(branch.branch.summary)
                    .font(.subheadline)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                if !branch.isUnlocked {
                    Label(branch.unlockHint, systemImage: "signpost.right")
                        .font(.subheadline)
                        .foregroundStyle(DS.fg3)
                }
                VStack(spacing: 0) {
                    ForEach(branch.nodes) { node in
                        branchNodeRow(node, stage: stage)
                    }
                }
            }
            .padding(16)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(DS.separatorStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .padding(.leading, isCompact ? 14 : 36)
            .padding(.vertical, 10)
        }
    }

    private func branchNodeRow(_ node: TutorPathNode, stage: Stage) -> some View {
        Button {
            selectedLessonID = node.id
        } label: {
            HStack(spacing: 12) {
                TutorShellNodeMarker(state: node.state, number: node.number, isCurrent: false, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.lesson.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(node.state == .locked ? DS.fg2 : DS.fg1)
                        .multilineTextAlignment(.leading)
                    Text("\(node.lesson.minutes) min")
                        .font(.caption)
                        .foregroundStyle(DS.fg3)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(DS.fg3)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .popover(isPresented: Binding(get: { selectedLessonID == node.id },
                                      set: { if !$0, selectedLessonID == node.id { selectedLessonID = nil } })) {
            TutorLessonDetailView(node: node, stage: stage, instrument: instrument,
                                  onStart: { lesson in
                                      selectedLessonID = nil
                                      onStart(lesson)
                                  },
                                  onSetDone: { lesson, done in
                                      selectedLessonID = nil
                                      onSetDone(lesson, done)
                                  },
                                  onClose: { selectedLessonID = nil })
                .frame(idealWidth: 440, idealHeight: 560)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Continue hero

struct TutorContinueHero: View {
    let card: TutorContinueCard
    let overallCompletion: Double
    let practiceDays: Int
    let isCompact: Bool
    var onStart: (Lesson) -> Void
    var onReviewPath: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.accentStrong)
            Text(card.lesson?.title ?? "You finished the path")
                .font(isCompact ? .title.weight(.bold) : .largeTitle.weight(.bold))
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
            if let lesson = card.lesson {
                Text(lesson.summary)
                    .font(isCompact ? .body : .title3)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Label("\(card.minutes) min", systemImage: "clock")
                    Label("\(lesson.steps.count) steps", systemImage: "list.bullet")
                    if lesson.steps.contains(where: { if case .practice = $0 { return true }; return false }) {
                        Label("Uses the mic", systemImage: "mic")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(DS.fg2)
            } else {
                Text("Every main-path lesson is done. Replay any lesson, keep up your reviews, or try a side branch.")
                    .foregroundStyle(DS.fg2)
            }
            HStack(spacing: 12) {
                if let lesson = card.lesson {
                    Button {
                        onStart(lesson)
                    } label: {
                        Label(card.buttonTitle, systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .hoverEffect(.lift)
                } else {
                    Button("Show the path", action: onReviewPath)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                TutorShellProgressBar(value: overallCompletion)
                Text(progressLine)
                    .font(.footnote)
                    .foregroundStyle(DS.fg2)
            }
            .padding(.top, 6)
        }
        .padding(isCompact ? 20 : 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.accentSofter, in: RoundedRectangle(cornerRadius: DS.radiusCard + 5, style: .continuous))
    }

    private var eyebrow: String {
        switch card.kind {
        case .finished: return "Path complete"
        case .resume: return "Pick up where you left off · Stage \(card.stageNumber): \(card.stageTitle)"
        case .start: return "Up next · Stage \(card.stageNumber): \(card.stageTitle)"
        }
    }

    private var progressLine: String {
        let pct = "\(Int((overallCompletion * 100).rounded()))% of the main path"
        guard practiceDays > 0 else { return pct }
        return pct + " · practiced on \(practiceDays) \(practiceDays == 1 ? "day" : "days")"
    }
}

// MARK: - Lesson detail

struct TutorLessonDetailView: View {
    let node: TutorPathNode
    let stage: Stage
    let instrument: TutorInstrument
    var onStart: (Lesson) -> Void
    var onSetDone: (Lesson, Bool) -> Void = { _, _ in }
    var onClose: () -> Void

    var body: some View {
        let lesson = node.lesson
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.isBranch ? "Optional · Stage \(stage.order)" : "Stage \(stage.order) · Lesson \(node.number)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DS.accentStrong)
                        Text(lesson.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(DS.fg1)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(DS.fg3)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
                }
                Text(lesson.summary)
                    .font(.body)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Label("\(lesson.minutes) min", systemImage: "clock")
                    Label("\(lesson.steps.count) steps", systemImage: "list.bullet")
                    if node.state == .completed { Label("Done", systemImage: "checkmark.circle") }
                }
                .font(.subheadline)
                .foregroundStyle(DS.fg2)

                if let reason = node.lockedReason {
                    Label(reason, systemImage: "lock")
                        .font(.subheadline)
                        .foregroundStyle(DS.cautionText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.cautionSoft, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("Steps")
                        .font(.headline)
                        .padding(.bottom, 6)
                    ForEach(TutorStepSummary.summaries(for: lesson)) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: step.systemImage)
                                .frame(width: 22)
                                .foregroundStyle(DS.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.kindLabel).font(.caption.weight(.semibold)).foregroundStyle(DS.fg3)
                                Text(step.title).font(.subheadline).foregroundStyle(DS.fg1)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                if !lesson.glossaryTerms.isEmpty {
                    Text("Terms: " + lesson.glossaryTerms.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(DS.fg3)
                }

            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            if let title = TutorPathModel.actionTitle(for: node.state) {
                VStack(spacing: 10) {
                    Button {
                        onStart(lesson)
                    } label: {
                        Text(title)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    let done = node.state == .completed
                    Button {
                        onSetDone(lesson, !done)
                    } label: {
                        Label(done ? "Mark as not done" : "Mark as done (skip)",
                              systemImage: done ? "arrow.uturn.backward" : "forward.end")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityHint(done ? "Returns this lesson to your path."
                                            : "Skips this lesson. You can still open it any time.")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(DS.surfaceRaised)
            }
        }
        .background(DS.surfaceRaised)
    }
}
