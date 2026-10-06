//
//  ChapterRoutine.swift
//  TabBuddy
//
//  The routine at the end of a chapter: a short timed practice built from the
//  chapter (warm-up from the previous chapter, each Try it item, then the
//  song), meant to be repeated daily until the items feel easy — the module
//  routine pattern from JustinGuitar and Pianote. Each segment shows its Try
//  it box and a countdown; nothing is scored. Finishing records the day.
//

import SwiftUI

struct RoutineSegment: Identifiable, Hashable {
    enum Content: Hashable {
        case practice(PracticeStep)
        case song(SongStep)
    }

    var id: String
    var title: String
    var minutes: Int
    var isWarmUp: Bool
    var content: Content
}

enum ChapterRoutineBuilder {
    /// Minutes per segment kind; the routine stays near 10 minutes.
    static let warmUpMinutes = 2
    static let practiceMinutes = 3
    static let songMinutes = 4
    static let maxPracticeSegments = 3

    static func segments(for lesson: Lesson, previous: Lesson?) -> [RoutineSegment] {
        var result: [RoutineSegment] = []
        if let previous, let warm = practiceSteps(in: previous).first {
            result.append(RoutineSegment(id: "warm-\(previous.id)", title: "Warm-up: " + warm.exercise.prompt,
                                         minutes: warmUpMinutes, isWarmUp: true, content: .practice(warm)))
        }
        for (i, step) in practiceSteps(in: lesson).prefix(maxPracticeSegments).enumerated() {
            result.append(RoutineSegment(id: "\(lesson.id)-p\(i)", title: step.exercise.prompt,
                                         minutes: practiceMinutes, isWarmUp: false, content: .practice(step)))
        }
        if let song = LessonPageModel.sections(for: lesson).compactMap({ section -> SongStep? in
            if case .song(let s) = section.step { return s } else { return nil }
        }).first {
            result.append(RoutineSegment(id: "\(lesson.id)-song", title: "Song: " + song.title,
                                         minutes: songMinutes, isWarmUp: false, content: .song(song)))
        }
        return result
    }

    /// Practice steps that make sense to repeat (not free improvisation).
    static func practiceSteps(in lesson: Lesson) -> [PracticeStep] {
        LessonPageModel.sections(for: lesson).compactMap { section in
            if case .practice(let p) = section.step, p.exercise.kind != .improvise { return p }
            return nil
        }
    }

    /// The chapter before `lessonID` on the main path (or in its branch).
    @MainActor
    static func previousLesson(of lessonID: String, instrument: TutorInstrument) -> Lesson? {
        guard let location = CurriculumLibrary.shared.location(ofLesson: lessonID, instrument: instrument) else { return nil }
        let siblings = location.branch?.lessons ?? location.stage.lessons
        if let i = siblings.firstIndex(where: { $0.id == lessonID }), i > 0 { return siblings[i - 1] }
        guard location.branch == nil, let course = CurriculumLibrary.shared.course(for: instrument),
              let stageIndex = course.stages.firstIndex(where: { $0.id == location.stage.id }), stageIndex > 0 else { return nil }
        return course.stages[stageIndex - 1].lessons.last
    }
}

struct ChapterRoutineView: View {
    let lesson: Lesson
    let instrument: TutorInstrument
    var intervals: [Interval]?
    var stage: Int?
    @ObservedObject var memory: PracticeMemory = .shared

    @State private var running = false
    @State private var index = 0
    @State private var remaining: Int = 0
    @State private var paused = false
    @State private var finished = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var segments: [RoutineSegment] {
        ChapterRoutineBuilder.segments(for: lesson,
                                       previous: ChapterRoutineBuilder.previousLesson(of: lesson.id, instrument: instrument))
    }

    private var totalMinutes: Int { segments.map(\.minutes).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if segments.isEmpty {
                TutorMessageRow(text: "This chapter has nothing to play yet. Its ideas come back in the next chapter's routine.",
                                systemImage: "book", tone: .neutral)
            } else if finished {
                finishedCard
            } else if running {
                runner
            } else {
                overview
            }
        }
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About \(totalMinutes) minutes. Repeat it on a few days until every item feels easy, then move on.")
                .font(.body)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { i, segment in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(segment.minutes) min")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(DS.accentStrong)
                            .frame(width: 56, alignment: .leading)
                        Text(segment.title)
                            .font(.body)
                            .foregroundStyle(DS.fg1)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    if i < segments.count - 1 { Hairline().padding(.leading, 14) }
                }
            }
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.separator))
            HStack(spacing: 14) {
                Button { start(at: 0) } label: {
                    Label(memory.didRoutineToday(lessonID: lesson.id) ? "Run it again" : "Start routine", systemImage: "timer")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(TutorPrimaryButtonStyle())
                .frame(maxWidth: 320)
                daysLabel
            }
        }
    }

    @ViewBuilder
    private var daysLabel: some View {
        let days = memory.routineDayCount(lessonID: lesson.id)
        if days > 0 {
            Label("Done on \(days) \(days == 1 ? "day" : "days")", systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(DS.fg2)
        }
    }

    // MARK: Runner

    private var runner: some View {
        let segment = segments[min(index, segments.count - 1)]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Part \(index + 1) of \(segments.count)\(segment.isWarmUp ? " · warm-up" : "")")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(DS.fg3)
                    Text(segment.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(DS.fg1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(Self.clock(remaining))
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(remaining == 0 ? DS.accentStrong : DS.fg1)
                    .accessibilityLabel("\(remaining / 60) minutes \(remaining % 60) seconds left")
                Button { paused.toggle() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(paused ? "Resume timer" : "Pause timer")
            }
            ProgressView(value: Double(index) + progressInSegment(segment), total: Double(segments.count))
                .tint(DS.accent)
            TryItBox {
                switch segment.content {
                case .practice(let step):
                    TryItLessonCard(step: step, instrument: instrument, intervals: intervals, seed: 1, stage: stage)
                case .song(let song):
                    SongStepView(step: song, instrument: instrument)
                }
            }
            .id(segment.id)
            HStack(spacing: 12) {
                Button("Stop") { running = false }
                    .buttonStyle(TutorSecondaryButtonStyle())
                    .frame(maxWidth: 160)
                Spacer(minLength: 0)
                Button {
                    next()
                } label: {
                    Label(index + 1 < segments.count ? (remaining == 0 ? "Time's up · next" : "Next") : "Finish routine",
                          systemImage: index + 1 < segments.count ? "forward.end.fill" : "checkmark.circle")
                }
                .buttonStyle(TutorPrimaryButtonStyle(tint: remaining == 0 ? DS.accent : DS.fg2))
                .frame(maxWidth: 260)
            }
        }
        .task(id: "\(index)-\(running)") {
            // One-second countdown; pausing holds it. It never moves on by itself while you play.
            while running && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !paused, remaining > 0 { remaining -= 1 }
            }
        }
    }

    private var finishedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Routine done", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(DS.accentStrong)
            let days = memory.routineDayCount(lessonID: lesson.id)
            Text(days >= 3
                 ? "Done on \(days) days. If every item feels easy, mark the chapter as read and move on; it comes back as a warm-up."
                 : "Done on \(days) \(days == 1 ? "day" : "days"). Come back tomorrow; a few short days beat one long one.")
                .font(.subheadline)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Back to the routine") { finished = false }
                .buttonStyle(TutorSecondaryButtonStyle())
                .frame(maxWidth: 260)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.accentSofter, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
    }

    private func progressInSegment(_ segment: RoutineSegment) -> Double {
        let total = Double(segment.minutes * 60)
        return total > 0 ? min(1, max(0, 1 - Double(remaining) / total)) : 0
    }

    private func start(at i: Int) {
        index = i
        remaining = segments[i].minutes * 60
        paused = false
        running = true
    }

    private func next() {
        TutorSynth.shared.stop()
        if index + 1 < segments.count {
            start(at: index + 1)
        } else {
            running = false
            finished = true
            memory.recordRoutine(lessonID: lesson.id)
        }
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
