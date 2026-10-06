//
//  DiatonicChordRow.swift
//  TabBuddy
//
//  Picks chords from a key's diatonic set (I ii iii IV V vi vii° in major,
//  i ii° III iv v VI VII in natural minor) instead of a quality menu. Large
//  chips show the Roman numeral and the letter symbol, tinted by quality
//  family. In `.single` mode a tap replaces the selection; in `.changes` mode
//  taps build an ordered tray of up to `maxSelection` chords for a changes
//  drill. Optional "More" chips add other qualities on the key's root.
//

import SwiftUI

// MARK: - Model

enum DiatonicChords {
    /// Triads on each scale degree with their Roman numerals.
    /// C major: I C, ii Dm, iii Em, IV F, V G, vi Am, vii° Bdim.
    /// A minor (natural): i Am, ii° Bdim, III C, iv Dm, v Em, VI F, VII G.
    static func triads(in key: Key) -> [(roman: String, chord: Chord)] {
        Array(zip(key.triadNumerals, key.diatonicTriads)).map { (roman: $0.0, chord: $0.1) }
    }

    /// Seventh chords on each scale degree (C major: Imaj7 ii7 iii7 IVmaj7 V7 vi7 viiø7).
    static func sevenths(in key: Key) -> [(roman: String, chord: Chord)] {
        Array(zip(key.seventhNumerals, key.diatonicSevenths)).map { (roman: $0.0, chord: $0.1) }
    }

    /// Common colour chords on the key's root for the "More" chips: 7, maj7, sus2, sus4
    /// (m7 instead of 7/maj7 in a minor key).
    static func extras(in key: Key) -> [Chord] {
        let qualities: [ChordQuality] = key.mode == .major
            ? [.dominantSeventh, .majorSeventh, .sus2, .sus4]
            : [.minorSeventh, .sus2, .sus4]
        return qualities.map { Chord(root: key.tonic, quality: $0) }
    }

    /// Roman numeral for any chord in the key ("I7", "Isus4"), falling back to the symbol.
    static func roman(for chord: Chord, in key: Key) -> String {
        key.romanNumeral(for: chord) ?? chord.displaySymbol
    }

    enum Family: Hashable {
        case major, minor, diminished, other
    }

    static func family(of quality: ChordQuality) -> Family {
        let intervals = quality.intervals
        if intervals.contains(.m3) { return intervals.contains(.d5) ? .diminished : .minor }
        if intervals.contains(.M3) { return quality == .augmented ? .other : .major }
        return .other
    }
}

// MARK: - View

struct DiatonicChordRow: View {
    enum Mode: Hashable {
        /// A tap replaces the selection with that chord.
        case single
        /// A tap adds the chord to the end of an ordered tray (up to `maxSelection`) or removes it.
        case changes
    }

    let key: Key
    @Binding var selection: [Chord]
    var maxSelection: Int
    @Binding var showsRoman: Bool
    var mode: Mode
    /// "More" chips: other qualities on the key root (see `DiatonicChords.extras(in:)`).
    var extraChords: [Chord]

    init(key: Key, selection: Binding<[Chord]>, maxSelection: Int = 4, showsRoman: Binding<Bool>,
         mode: Mode = .single, extraChords: [Chord] = []) {
        self.key = key
        _selection = selection
        self.maxSelection = maxSelection
        _showsRoman = showsRoman
        self.mode = mode
        self.extraChords = extraChords
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }

    /// New selection after tapping `chord`.
    static func applyingTap(_ chord: Chord, to selection: [Chord], mode: Mode, maxSelection: Int) -> [Chord] {
        switch mode {
        case .single:
            return [chord]
        case .changes:
            var result = selection
            if let i = result.firstIndex(of: chord) {
                result.remove(at: i)
            } else if result.count < maxSelection {
                result.append(chord)
            }
            return result
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(DS.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Picker("Chord labels", selection: $showsRoman) {
                    Text("Roman").tag(true)
                    Text("Letters").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            FlowLayout(spacing: compact ? 8 : 10, lineSpacing: compact ? 8 : 10) {
                ForEach(DiatonicChords.triads(in: key), id: \.chord) { item in
                    chip(item.chord, roman: item.roman)
                }
            }
            if !extraChords.isEmpty {
                Text("MORE")
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(DS.fg3)
                    .padding(.top, 4)
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(extraChords, id: \.self) { chord in
                        chip(chord, roman: DiatonicChords.roman(for: chord, in: key), small: true)
                    }
                }
            }
        }
    }

    private var caption: String {
        switch mode {
        case .single:
            return "Chords in \(key.displayName)"
        case .changes:
            let n = selection.count
            if n < 2 { return "Tap 2 to \(maxSelection) chords in \(key.displayName), in the order you'll play them." }
            return "\(n) of \(maxSelection) chords. Tap a chord again to remove it."
        }
    }

    private func chip(_ chord: Chord, roman: String, small: Bool = false) -> some View {
        let order = selection.firstIndex(of: chord)
        let selected = order != nil
        let colors = Self.colors(for: DiatonicChords.family(of: chord.quality))
        let primary = showsRoman ? roman : chord.displaySymbol
        let secondary = showsRoman ? chord.displaySymbol : roman
        let full = mode == .changes && !selected && selection.count >= maxSelection
        return Button {
            withAnimation(DS.motionFast) {
                selection = Self.applyingTap(chord, to: selection, mode: mode, maxSelection: maxSelection)
            }
        } label: {
            VStack(spacing: 2) {
                Text(primary)
                    .font(small ? .headline : (compact ? .title3.weight(.bold) : .title2.weight(.bold)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(secondary)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.8)
            }
            .foregroundStyle(selected ? Color.white : colors.text)
            .padding(.horizontal, 10)
            .frame(minWidth: small ? 56 : (compact ? 58 : 72), minHeight: small ? 48 : (compact ? 52 : 60))
            .background(
                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                    .fill(selected ? DS.accent : colors.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                    .strokeBorder(selected ? DS.accentStrong : DS.separator, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if mode == .changes, let order {
                    Text("\(order + 1)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(DS.accentStrong)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(DS.surfaceRaised))
                        .overlay(Circle().strokeBorder(DS.accentStrong, lineWidth: 1))
                        .offset(x: 6, y: -6)
                }
            }
            .opacity(full ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(chord.name), \(roman)")
        .accessibilityValue(order.map { mode == .changes ? "Selected, number \($0 + 1)" : "Selected" } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func colors(for family: DiatonicChords.Family) -> (fill: Color, text: Color) {
        switch family {
        case .major: return (DS.accentSofter, DS.accentStrong)
        case .minor: return (DS.surfaceInset, DS.fg1)
        case .diminished: return (DS.cautionSoft, DS.cautionText)
        case .other: return (DS.surface, DS.fg2)
        }
    }
}
