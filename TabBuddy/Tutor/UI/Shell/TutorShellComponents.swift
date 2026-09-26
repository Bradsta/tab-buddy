//
//  TutorShellComponents.swift
//  TabBuddy
//
//  Small building blocks shared by the tutor shell screens, drawn with the
//  DesignSystem tokens so the tutor reads as part of TabBuddy.
//

import SwiftUI

/// Sections of the tutor shell (sidebar on iPad, rows on iPhone).
enum TutorSection: String, Hashable, CaseIterable, Identifiable {
    case path, reviews, songs, games, glossary, calibration, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .path: return "Path"
        case .reviews: return "Reviews"
        case .songs: return "Songs you know"
        case .games: return "Games"
        case .glossary: return "Glossary"
        case .calibration: return "Calibration"
        case .settings: return "Tutor settings"
        }
    }

    var systemImage: String {
        switch self {
        case .path: return "point.topleft.down.to.point.bottomright.curvepath"
        case .reviews: return "rectangle.stack"
        case .songs: return "music.note.list"
        case .games: return "gamecontroller"
        case .glossary: return "character.book.closed"
        case .calibration: return "mic.badge.plus"
        case .settings: return "slider.horizontal.3"
        }
    }

    /// ⌘1 … ⌘7.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((TutorSection.allCases.firstIndex(of: self) ?? 0) + 1)))
    }

    init?(launchName: String) {
        self.init(rawValue: launchName.lowercased())
    }
}

/// Raised card surface.
struct TutorShellCard<Content: View>: View {
    var padding: CGFloat = 20
    var fill: Color = DS.surface
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(DS.separator, lineWidth: 1))
    }
}

/// Small rounded label ("Optional", "Coming soon", "Up next").
struct TutorShellChip: View {
    var text: String
    var systemImage: String? = nil
    var fill: Color = DS.accentSofter
    var foreground: Color = DS.accentStrong

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(foreground)
        .background(fill, in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous))
    }
}

/// Thin completion bar.
struct TutorShellProgressBar: View {
    var value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.surfaceInset)
                Capsule().fill(DS.accent)
                    .frame(width: max(value > 0 ? height : 0, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Small completion ring for sidebar stage rows.
struct TutorShellRing: View {
    var value: Double
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().stroke(DS.surfaceInset, lineWidth: 3)
            Circle().trim(from: 0, to: min(1, max(0, value)))
                .stroke(DS.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if value >= 1 {
                Image(systemName: "checkmark").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(DS.accent)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Circle marker for a lesson node.
struct TutorShellNodeMarker: View {
    var state: LessonState
    var number: Int
    var isCurrent: Bool
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            if isCurrent {
                Circle().fill(DS.accentSoft).frame(width: size + 12, height: size + 12)
            }
            switch state {
            case .completed:
                Circle().fill(DS.accent)
                Image(systemName: "checkmark").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
            case .inProgress:
                Circle().fill(DS.surface)
                Circle().strokeBorder(DS.accent, lineWidth: 3)
                Image(systemName: "play.fill").font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(DS.accent)
            case .available:
                Circle().fill(DS.surface)
                Circle().strokeBorder(DS.accent, lineWidth: 2.5)
                Text("\(number)").font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(DS.accentStrong)
            case .locked:
                Circle().fill(DS.surfaceInset)
                Image(systemName: "lock.fill").font(.system(size: size * 0.34)).foregroundStyle(DS.fg3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Microphone-permission-denied notice with a Settings link.
struct TutorShellMicDeniedNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Microphone access is off", systemImage: "mic.slash")
                .font(.headline)
                .foregroundStyle(DS.cautionText)
            Text("Listening exercises need the microphone. Quizzes and reading still work without it.")
                .foregroundStyle(DS.fg2)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.cautionSoft, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
    }
}

/// Plays curriculum playback specs through the shared synth.
enum TutorShellAudio {
    @MainActor
    @discardableResult
    static func play(_ spec: PlaybackSpec, instrument: TutorInstrument) -> Bool {
        guard let sequence = try? ExerciseGenerator.playback(for: spec, context: .standard(instrument)) else { return false }
        let synth = TutorSynth.shared
        synth.instrument = instrument
        let steps = sequence.notes.map(\.pitches)
        let beats = sequence.notes.first?.durationBeats ?? 1
        return synth.play(chords: steps, style: spec.style == .arpeggio ? .arpeggio : .block,
                          bpm: sequence.bpm, beatsPerChord: beats)
    }

    @MainActor
    @discardableResult
    static func play(pitches: [Int], instrument: TutorInstrument) -> Bool {
        let synth = TutorSynth.shared
        synth.instrument = instrument
        return synth.play(pitches: pitches, style: pitches.count > 1 ? .block : .sequence, bpm: 72)
    }
}

extension View {
    /// Readable column width for long content on wide screens.
    func tutorReadableWidth(_ width: CGFloat = 820) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}
