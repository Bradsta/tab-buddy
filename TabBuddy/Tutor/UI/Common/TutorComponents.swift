//
//  TutorComponents.swift
//  TabBuddy
//
//  Shared building blocks for tutor screens: cards, large buttons readable
//  from a music stand, the live input meter, status chips, the microphone-off
//  panel, a small Markdown block renderer, and the regular-width breakpoint.
//

import SwiftUI

// MARK: - Layout

enum TutorLayout {
    /// Width at which lesson screens switch to side-by-side layouts.
    static let wideBreakpoint: CGFloat = 700
    /// Readable column for text-only content on wide screens.
    static let readableWidth: CGFloat = 760
    /// Side panel width in practice views on wide screens.
    static let sidePanelWidth: CGFloat = 340
    static let largeTarget: CGFloat = 56

    static func isWide(_ width: CGFloat) -> Bool { width >= wideBreakpoint }
}

/// Measures the available width and hands it to the content (0 until known).
struct WidthReader<Content: View>: View {
    @ViewBuilder var content: (CGFloat) -> Content
    @State private var width: CGFloat = 0

    var body: some View {
        content(width)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in width = new }
                }
            )
    }
}

// MARK: - Surfaces

struct TutorCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .strokeBorder(DS.separator, lineWidth: 1)
            )
    }
}

// MARK: - Buttons

struct TutorPrimaryButtonStyle: ButtonStyle {
    var tint: Color = DS.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(minHeight: TutorLayout.largeTarget)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusControl + 3, style: .continuous)
                    .fill(configuration.isPressed ? DS.accentStrong : tint)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .animation(DS.motionFast, value: configuration.isPressed)
    }
}

struct TutorSecondaryButtonStyle: ButtonStyle {
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(DS.accentStrong)
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                    .fill(configuration.isPressed ? DS.accentSoft : DS.accentSofter)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Round play/stop control for demos and references.
struct TutorPlayButton: View {
    var isPlaying: Bool
    var title: String = "Play"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isPlaying ? "Stop" : title, systemImage: isPlaying ? "stop.fill" : "play.fill")
        }
        .buttonStyle(TutorSecondaryButtonStyle())
        .accessibilityLabel(isPlaying ? "Stop playback" : title)
    }
}

/// A button that exists only for its keyboard shortcut.
struct KeyboardShortcutButton: View {
    var key: KeyEquivalent
    var modifiers: EventModifiers = []
    var action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

// MARK: - Status

enum TutorTone {
    case good, neutral, caution, accent

    var foreground: Color {
        switch self {
        case .good: return Color.green
        case .neutral: return DS.fg2
        case .caution: return DS.cautionText
        case .accent: return DS.accentStrong
        }
    }

    var background: Color {
        switch self {
        case .good: return Color.green.opacity(0.14)
        case .neutral: return DS.surfaceInset
        case .caution: return DS.cautionSoft
        case .accent: return DS.accentSofter
        }
    }
}

struct TutorStatusChip: View {
    var text: String
    var systemImage: String? = nil
    var tone: TutorTone = .neutral

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tone.background, in: Capsule())
    }
}

/// Message row for coach tips and feedback.
struct TutorMessageRow: View {
    var text: String
    var systemImage: String = "lightbulb"
    var tone: TutorTone = .accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tone.foreground)
            Text(text)
                .foregroundStyle(DS.fg1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
    }
}

/// Live microphone level. Reads the level through `level` on a short timer so
/// the owning view does not redraw on every audio chunk.
struct InputLevelMeter: View {
    var isActive: Bool
    var level: () -> Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isActive)) { _ in
            let value = isActive ? CGFloat(min(1, max(0, level()))) : 0
            HStack(spacing: 8) {
                Image(systemName: isActive ? "mic.fill" : "mic")
                    .foregroundStyle(isActive ? DS.accent : DS.fg3)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.surfaceInset)
                        Capsule().fill(isActive ? DS.accent : DS.separatorStrong)
                            .frame(width: max(4, proxy.size.width * value))
                    }
                }
                .frame(height: 8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isActive ? "Microphone level" : "Microphone off")
            .accessibilityValue("\(Int(value * 100)) percent")
        }
    }
}

/// Microphone access is off: explain and link to Settings.
struct MicrophoneOffPanel: View {
    var onSkip: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Microphone access is off", systemImage: "mic.slash")
                .font(.headline)
                .foregroundStyle(DS.fg1)
            Text("TabBuddy can listen to your instrument and turn heard notes green. Turn on Microphone for TabBuddy in Settings, then come back. Reading, examples, and Check yourself work without it.")
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    TutorAudioHelpers.openSettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .buttonStyle(TutorSecondaryButtonStyle())
                if let onSkip {
                    Button("Skip for now", action: onSkip)
                        .buttonStyle(TutorSecondaryButtonStyle())
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.cautionSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
    }
}

// MARK: - Markdown

/// Block-level Markdown for lesson text: paragraphs, "-"/"*" bullets,
/// numbered lists, "#" headings, and pipe tables. Inline styles go through
/// `AttributedString(markdown:)`.
enum MarkdownBlock: Hashable {
    case heading(String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case table(header: [String], rows: [[String]])

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var table: [[String]] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !table.isEmpty {
                let rows = table.filter { row in !row.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }
                if let header = rows.first { blocks.append(.table(header: header, rows: Array(rows.dropFirst()))) }
                table = []
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                table.append(cells)
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if bullets.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2)))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                if numbered.isEmpty { flush() }
                numbered.append(String(line[line.index(dot, offsetBy: 2)...]))
            } else {
                if !bullets.isEmpty || !numbered.isEmpty || !table.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct MarkdownText: View {
    var text: String
    var font: Font = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .font(font)
        .foregroundStyle(DS.fg1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(MarkdownBlock.inline(text)).font(.headline)
        case .paragraph(let text):
            Text(MarkdownBlock.inline(text)).fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(DS.accent).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(MarkdownBlock.inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(DS.accentStrong)
                        Text(MarkdownBlock.inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownBlock.inline(cell)).font(.subheadline.weight(.semibold)).foregroundStyle(DS.fg2)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownBlock.inline(cell)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12)
            .background(DS.surfaceInset, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        }
    }
}

// MARK: - Environment

private struct DiagramTapEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Tap-to-hear on diagrams. Off while the microphone is listening (output is muted then).
    var tutorDiagramTapEnabled: Bool {
        get { self[DiagramTapEnabledKey.self] }
        set { self[DiagramTapEnabledKey.self] = newValue }
    }
}
