//
//  PracticeDemoData.swift
//  TabBuddy
//
//  Synthetic take data for previews and layout checks (no microphone).
//  The analysis comes from the real TakeAnalyzer run over a scripted
//  performance with deliberate mistakes and a rushed section.
//

#if DEBUG
import SwiftUI

enum PracticeDemoData {
    /// An 8-measure guitar passage (measures 9–16) with chords and single notes.
    static func passage() -> ExpectedPassage {
        let eMinor = [40, 47, 52, 55, 59, 64], aMinor = [45, 52, 57, 60, 64], g = [43, 47, 50, 55, 59, 67]
        var groups: [[Int]] = []
        var durations: [Double] = []
        for bar in 0..<8 {
            switch bar % 4 {
            case 0: groups += [eMinor, [52], [55], [59]]; durations += [1, 1, 1, 1]
            case 1: groups += [[57], [59], [60], [59], [57], [55]]; durations += [1, 0.5, 0.5, 1, 0.5, 0.5]
            case 2: groups += [aMinor, [60], g, [62]]; durations += [1, 1, 1, 1]
            default: groups += [[64], [62], [60], [59], eMinor]; durations += [0.5, 0.5, 0.5, 0.5, 2]
            }
        }
        var p = PassageBuilder.from(pitchEvents: groups, durations: durations, bpm: 96, beatsPerMeasure: 4,
                                    instrument: .guitar)
        for i in p.events.indices { p.events[i].measureIndex += 8 }
        return p
    }

    /// A scripted performance: wrong notes, a missed note, a partial chord,
    /// an unsure onset, an extra, and rushing in measures 13–14.
    static func archive() -> PracticeTakeArchive {
        let passage = passage()
        let scale = 0.8
        let spb = 60 / (passage.bpm * scale)
        var detected: [DetectedEvent] = []
        var time = 1.0
        var lastBeat = 0.0
        for e in passage.events {
            let rushing = (12...13).contains(e.measureIndex)
            time += (e.beat - lastBeat) * spb * (rushing ? 0.86 : 1)
            lastBeat = e.beat
            let jitter = Double((e.id * 37) % 11 - 5) * 0.006
            var pitches = e.pitches
            var confidence = 0.9
            switch e.id {
            case 5: pitches = [pitches[0] + 1]                  // wrong note
            case 11: continue                                   // missed
            case 18: pitches = Array(pitches.dropLast(2))       // partial chord
            case 22: confidence = 0.3                           // unsure
            case 30: pitches = [pitches[0] - 2]                 // wrong note
            default: break
            }
            detected.append(DetectedEvent(time: time + jitter, pitches: pitches,
                                          confidences: pitches.map { _ in confidence }, source: .polyphonic))
            if e.id == 26 {
                detected.append(DetectedEvent(time: time + 0.18, pitches: [66], confidences: [0.8], source: .polyphonic))
            }
        }
        let analysis = TakeAnalyzer().analyze(passage: passage, live: [], detected: detected, tempoScale: scale)
        return PracticeTakeArchive(analysis: analysis, passage: passage, mode: .playAlong, tempoPercent: 80,
                                   latency: 0.08, passageStart: 1)
    }

    static func payload() -> PracticeReviewPayload {
        PracticeReviewPayload(id: UUID(), archive: archive(), audioURL: nil, date: date(daysAgo: 0),
                              measures: 8...15, bpm: 76.8)
    }

    /// Six takes over two weeks, improving.
    static func history(current: PracticeReviewPayload) -> [PracticeTakeSummary] {
        var takes: [PracticeTakeSummary] = [
            PracticeTakeSummary(id: current.id, date: current.date, measures: current.measures, bpm: current.bpm,
                                accuracy: current.archive.analysis.accuracy,
                                timingMADms: current.archive.analysis.timingMADms,
                                measureAccuracy: current.archive.analysis.measureAccuracy, hasAudio: false)
        ]
        for k in 1...5 {
            var cells: [Int: Double] = [:]
            for m in 8...15 { cells[m] = max(0.2, min(1, 0.45 + 0.08 * Double(5 - k) + Double((m * 7 + k * 3) % 5) * 0.06)) }
            if k > 3 { cells[13] = nil; cells[14] = nil }
            let accuracy = cells.values.reduce(0, +) / Double(cells.count)
            takes.append(PracticeTakeSummary(id: UUID(), date: date(daysAgo: k * 3), measures: 8...(k > 3 ? 12 : 15),
                                             bpm: 72, accuracy: accuracy, timingMADms: 40 + Double(k) * 6,
                                             measureAccuracy: cells, hasAudio: k < 3))
        }
        return takes
    }

    private static func date(daysAgo: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 25 - daysAgo; c.hour = 18; c.minute = 30
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }
}

#Preview("Take review") {
    let payload = PracticeDemoData.payload()
    return TakeReviewView(payload: payload, takes: PracticeDemoData.history(current: payload), totalMeasures: 32)
}
#endif
