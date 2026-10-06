//
//  PracticeKeyPicker.swift
//  TabBuddy
//
//  One-tap key pickers for Practice. Guitar uses a circle of fifths (majors
//  outside, relative minors inside, the key's neighbours tinted), which also
//  teaches key relationships. Piano uses a one-octave keyboard strip, so the
//  key is chosen on the instrument itself.
//

import SwiftUI

enum PracticeKeys {
    /// Major roots clockwise from C, spelled as keys are usually written.
    static let circle: [SpelledNote] = ["C", "G", "D", "A", "E", "B", "F#", "Db", "Ab", "Eb", "Bb", "F"].compactMap { SpelledNote($0) }
    /// Relative minors in the same order.
    static let relativeMinors: [SpelledNote] = ["A", "E", "B", "F#", "C#", "G#", "Eb", "Bb", "F", "C", "G", "D"].compactMap { SpelledNote($0) }

    static func circleIndex(of note: SpelledNote) -> Int? {
        circle.firstIndex { $0.pitchClass == note.pitchClass }
    }

    /// Key signature text for a major key ("2♯", "3♭", "no ♯ or ♭").
    static func signature(major index: Int) -> String {
        let fifths = index <= 6 ? index : index - 12
        if fifths == 0 { return "no ♯ or ♭" }
        return fifths > 0 ? "\(fifths)♯" : "\(-fifths)♭"
    }
}

/// Circle-of-fifths root picker. Tapping an outer segment picks that major
/// root; tapping an inner one picks the minor root (and sets `minor`).
struct KeyWheelPicker: View {
    @Binding var root: SpelledNote
    /// When non-nil the inner ring is tappable and reports major/minor.
    var minor: Binding<Bool>? = nil
    var size: CGFloat = 220

    private var selectedIndex: Int? {
        if minor?.wrappedValue == true {
            return PracticeKeys.relativeMinors.firstIndex { $0.pitchClass == root.pitchClass }
        }
        return PracticeKeys.circleIndex(of: root)
    }

    var body: some View {
        let isMinor = minor?.wrappedValue == true
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                segment(i, minorRing: false, selected: !isMinor && selectedIndex == i, near: !isMinor && isNeighbour(i))
                if minor != nil {
                    segment(i, minorRing: true, selected: isMinor && selectedIndex == i, near: isMinor && isNeighbour(i))
                }
            }
            VStack(spacing: 2) {
                Text(centerTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(DS.fg1)
                Text(centerDetail)
                    .font(.caption)
                    .foregroundStyle(DS.fg3)
                    .multilineTextAlignment(.center)
            }
            .frame(width: size * 0.36)
            .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
    }

    private var centerTitle: String {
        if minor?.wrappedValue == true { return root.displayName + "m" }
        return root.displayName
    }

    private var centerDetail: String {
        guard let index = PracticeKeys.circleIndex(of: root) ?? selectedIndex else { return "" }
        if minor?.wrappedValue == true {
            let major = (index + 12) % 12
            return "rel. \(PracticeKeys.circle[major].displayName) · \(PracticeKeys.signature(major: major))"
        }
        return "rel. \(PracticeKeys.relativeMinors[index].displayName)m · \(PracticeKeys.signature(major: index))"
    }

    private func isNeighbour(_ i: Int) -> Bool {
        guard let s = selectedIndex else { return false }
        return i == (s + 1) % 12 || i == (s + 11) % 12
    }

    @ViewBuilder
    private func segment(_ i: Int, minorRing: Bool, selected: Bool, near: Bool) -> some View {
        // Outer majors and inner minors need room: 12 inner dots of 30 pt fit at 0.53 × radius from 280 pt up.
        let radius = size / 2 * (minorRing ? 0.53 : 0.84)
        let dot: CGFloat = minorRing ? 30 : 42
        let angle = Double(i) / 12 * 2 * .pi
        let note = minorRing ? PracticeKeys.relativeMinors[i] : PracticeKeys.circle[i]
        let label = note.displayName + (minorRing ? "m" : "")
        Button {
            root = note
            minor?.wrappedValue = minorRing
        } label: {
            Text(label)
                .font((minorRing ? Font.caption : Font.subheadline).weight(.semibold))
                .foregroundStyle(selected ? Color.white : (near ? DS.accentStrong : DS.fg2))
                .frame(width: dot, height: dot)
                .background(Circle().fill(selected ? DS.accentStrong : (near ? DS.accentSoft : DS.surfaceInset)))
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .offset(x: radius * sin(angle), y: -radius * cos(angle))
        .accessibilityLabel(minorRing ? "\(note.displayName) minor" : "\(note.displayName) major")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One-octave piano strip: tap a key to choose the root.
struct KeyStripPicker: View {
    @Binding var root: SpelledNote
    var height: CGFloat = 120

    private static let whites: [SpelledNote] = ["C", "D", "E", "F", "G", "A", "B"].compactMap { SpelledNote($0) }
    /// Black keys with the white-key index they sit after, spelled as common keys.
    private static let blackSpellings: [(Int, String)] = [(0, "Db"), (1, "Eb"), (3, "F#"), (4, "Ab"), (5, "Bb")]
    private static let blacks: [(after: Int, note: SpelledNote)] = blackSpellings.compactMap { pair in
        SpelledNote(pair.1).map { (after: pair.0, note: $0) }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 2) {
                    ForEach(Self.whites, id: \.self) { note in
                        key(note, white: true)
                            .frame(width: w - 2, height: height)
                    }
                }
                ForEach(Self.blacks, id: \.note) { item in
                    key(item.note, white: false)
                        .frame(width: w * 0.62, height: height * 0.6)
                        .offset(x: w * CGFloat(item.after + 1) - w * 0.31 - 1)
                }
            }
        }
        .frame(height: height)
    }

    private func key(_ note: SpelledNote, white: Bool) -> some View {
        let selected = note.pitchClass == root.pitchClass
        return Button { root = note } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: white ? 8 : 5, style: .continuous)
                    .fill(selected ? DS.accentStrong : (white ? DS.surface : DS.fg1))
                    .overlay(RoundedRectangle(cornerRadius: white ? 8 : 5, style: .continuous)
                        .strokeBorder(DS.separator))
                Text(note.displayName)
                    .font((white ? Font.subheadline : Font.caption).weight(.semibold))
                    .foregroundStyle(selected ? Color.white : (white ? DS.fg2 : DS.surface))
                    .padding(.bottom, white ? 10 : 6)
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(note.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    struct Host: View {
        @State var root = SpelledNote.G
        @State var minor = false
        var body: some View {
            VStack(spacing: 30) {
                KeyWheelPicker(root: $root, minor: $minor)
                KeyStripPicker(root: $root).frame(width: 420)
            }
            .padding()
        }
    }
    return Host()
}
