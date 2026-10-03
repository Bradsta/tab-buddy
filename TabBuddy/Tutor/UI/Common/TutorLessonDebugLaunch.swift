//
//  TutorLessonDebugLaunch.swift
//  TabBuddy
//
//  DEBUG-only launch arguments for checking lesson screens directly:
//
//    -TutorLessonDemo guitar.s3.l1     open that chapter in LessonPageView
//    -TutorLessonStep 4                scroll to section 4 (0-based page order)
//    -TutorDiagramGallery              every diagram kind for both instruments
//    -TutorForceWidth 500              lay the screen out in a 500 pt column
//                                      (Split View / compact check)
//
//  The tutor shell calls `TutorLessonDebugLaunch.overrideView()` from its root
//  view; it returns nil when no argument is present (and always in Release).
//

import SwiftUI

enum TutorLessonDebugLaunch {
    #if DEBUG
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }

    static var lessonID: String? { value(after: "-TutorLessonDemo") }
    static var startSection: Int? { value(after: "-TutorLessonStep").flatMap(Int.init) }
    static var showsGallery: Bool { arguments.contains("-TutorDiagramGallery") }
    static var forcedWidth: CGFloat? { value(after: "-TutorForceWidth").flatMap(Double.init).map { CGFloat($0) } }

    static var isRequested: Bool { lessonID != nil || showsGallery }
    #else
    static var isRequested: Bool { false }
    #endif

    /// The debug screen requested by launch arguments, or nil.
    @MainActor
    static func overrideView() -> AnyView? {
        #if DEBUG
        if showsGallery {
            return AnyView(ForcedWidth(width: forcedWidth) { DiagramGalleryView() })
        }
        if let id = lessonID {
            return AnyView(ForcedWidth(width: forcedWidth) { DebugLessonHost(lessonID: id, startSection: startSection) })
        }
        #endif
        return nil
    }
}

#if DEBUG

/// Lays content out in a fixed-width column with the matching size class.
struct ForcedWidth<Content: View>: View {
    var width: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if let width {
            content
                .frame(width: width)
                .environment(\.horizontalSizeClass, width < TutorLayout.wideBreakpoint ? .compact : .regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.25).ignoresSafeArea())
        } else {
            content
        }
    }
}

/// Loads the bundled curriculum and presents one chapter.
struct DebugLessonHost: View {
    let lessonID: String
    var startSection: Int?
    @ObservedObject private var library = CurriculumLibrary.shared
    @State private var closed = false

    var body: some View {
        Group {
            if closed {
                VStack(spacing: 12) {
                    Text("Chapter closed").font(.title2)
                    Button("Open again") { closed = false }
                }
            } else if let found {
                LessonPageView(lesson: found.0, instrument: found.1, initialSection: startSection) { closed = true }
            } else if library.isLoaded {
                Text("No lesson \"\(lessonID)\" in the bundled curriculum.").padding()
            } else {
                ProgressView("Loading lessons…")
            }
        }
        .task { await library.loadIfNeeded() }
    }

    private var found: (Lesson, TutorInstrument)? {
        for instrument in TutorInstrument.allCases {
            if let lesson = library.course(for: instrument)?.lesson(id: lessonID) { return (lesson, instrument) }
        }
        return nil
    }
}

// MARK: - Diagram gallery

struct DiagramGalleryView: View {
    @State private var instrument: TutorInstrument = .guitar

    static func samples(for instrument: TutorInstrument) -> [(String, Diagram)] {
        switch instrument {
        case .guitar:
            return [
                ("Fretboard · chord with fingers", Diagram(kind: .fretboard, chord: "C", notes: ["5:3", "4:2", "3:0", "2:1", "1:0"],
                                                          labels: .fingers, fretRange: [0, 4], caption: "C major: x32010")),
                ("Fretboard · intervals", Diagram(kind: .fretboard, chord: "Em", notes: ["6:0", "5:2", "4:2", "3:0", "2:0", "1:0"],
                                                  labels: .intervals, fretRange: [0, 4])),
                ("Fretboard · scale degrees, moved up", Diagram(kind: .fretboard, scale: "A minor pentatonic",
                                                                notes: ["6:5", "6:8", "5:5", "5:7", "4:5", "4:7", "3:5", "3:7", "2:5", "2:8", "1:5", "1:8"],
                                                                labels: .degrees, fretRange: [4, 9])),
                ("Fretboard · barre fingers", Diagram(kind: .fretboard, chord: "G", notes: ["6:3", "5:5", "4:5", "3:4", "2:3", "1:3"],
                                                      labels: .fingers, fretRange: [1, 6])),
                ("Staff · written pitch", Diagram(kind: .staff, notes: ["E4", "G4", "B4", "G4", "C5", "B4", "A4", "G4"], labels: .noteNames,
                                                  pitchRange: ["C4", "A5"], caption: "Written pitch. Guitar sounds one octave lower.")),
                ("Staff · key signature", Diagram(kind: .staff, notes: ["D4", "F#4", "A4", "C#5", "D5"], key: "D major", labels: .noteNames,
                                                  caption: "D major key signature: F♯ and C♯.")),
                ("Circle of fifths", Diagram(kind: .circleOfFifths, key: "G major", caption: "G major with its neighbors C (IV) and D (V).")),
                ("Rhythm", Diagram(kind: .rhythm, rhythm: "q q e e q | h. qr | te te te q h", caption: "Quarter, eighth, dotted half, rest, triplets")),
                ("Interval ladder", Diagram(kind: .intervalLadder, scale: "C major", labels: .intervals, caption: "Intervals above C")),
            ]
        case .piano:
            return [
                ("Keyboard · right-hand fingers", Diagram(kind: .keyboard, notes: ["C4", "D4", "E4", "F4", "G4"], labels: .fingers,
                                                          pitchRange: ["C4", "C5"], caption: "Right hand C position: 1 on C4 … 5 on G4.")),
                ("Keyboard · left-hand fingers", Diagram(kind: .keyboard, notes: ["C3", "D3", "E3", "F3", "G3"], labels: .fingers,
                                                         pitchRange: ["C3", "C4"], caption: "Left hand C position: 5 on C3 … 1 on G3.")),
                ("Keyboard · scale degrees", Diagram(kind: .keyboard, scale: "D major", notes: ["D4", "E4", "F#4", "G4", "A4", "B4", "C#5", "D5"],
                                                     labels: .degrees, pitchRange: ["D4", "D5"])),
                ("Keyboard · chord", Diagram(kind: .keyboard, chord: "Cm", notes: ["C4", "Eb4", "G4"], pitchRange: ["C4", "C5"],
                                             caption: "C minor: lower the 3rd by a half step.")),
                ("Grand staff", Diagram(kind: .staff, notes: ["C3", "F3", "C4", "G4", "C5"], pitchRange: ["F2", "G5"],
                                        caption: "Middle C sits between the two staves.")),
                ("Bass clef", Diagram(kind: .staff, notes: ["G2", "A2", "B2", "C3", "D3", "E3", "F3", "G3", "A3"], pitchRange: ["F2", "C4"],
                                      caption: "Bass clef: the dots surround F3.")),
                ("Staff · flats", Diagram(kind: .staff, notes: ["F4", "Bb4", "Eb5", "B4"], key: "F major", labels: .noteNames,
                                          pitchRange: ["C4", "G5"])),
                ("Circle of fifths · minor", Diagram(kind: .circleOfFifths, key: "E minor")),
                ("Rhythm · 3/4", Diagram(kind: .rhythm, rhythm: "h q q q q h.", caption: "Two measures of 3/4.")),
                ("Interval ladder · notes", Diagram(kind: .intervalLadder, notes: ["C4", "E4", "G4", "B4", "D5"], labels: .intervals)),
            ]
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Instrument", selection: $instrument) {
                    ForEach(TutorInstrument.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: 20, alignment: .top)], spacing: 20) {
                    ForEach(Array(Self.samples(for: instrument).enumerated()), id: \.offset) { _, sample in
                        TutorCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(sample.0).font(.headline).foregroundStyle(DS.fg1)
                                DiagramView(diagram: sample.1, instrument: instrument)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(DS.paper.ignoresSafeArea())
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-TutorGalleryPiano") { instrument = .piano }
        }
    }
}

#endif
