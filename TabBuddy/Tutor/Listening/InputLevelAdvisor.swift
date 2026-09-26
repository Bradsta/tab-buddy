//
//  InputLevelAdvisor.swift
//  TabBuddy
//
//  Mic-check guidance for the calibration / input-level screen. iPad is the
//  primary device: its microphones sit on the top edge or near the cameras
//  depending on model, and it usually rests on a music stand 0.5–1.5 m from
//  the instrument, so levels run lower and room reverb higher than on a
//  phone held close. Pure logic; the UI supplies measured levels from
//  `TutorAudioSession` (peakDBFS, noiseFloorDBFS).
//

import Foundation

enum InputLevelAdvisor {
    enum Status: String, Sendable {
        case noSignal, tooQuiet, good, tooLoud, noisyRoom
    }

    struct Advice: Hashable, Sendable {
        var status: Status
        var message: String
    }

    /// Assesses a mic check where the player sounded a test note ("open low E"
    /// or "middle C"). `peakDBFS` is the note's peak, `noiseFloorDBFS` the room.
    static func assess(peakDBFS: Float, noiseFloorDBFS: Float, instrument: TutorInstrument,
                       isPad: Bool) -> Advice {
        let snr = peakDBFS - noiseFloorDBFS
        if peakDBFS > -1.5 {
            return Advice(status: .tooLoud, message: isPad
                ? "The sound is clipping. Move the iPad a little farther from the \(noun(instrument)), or play softer."
                : "The sound is clipping. Hold the device a little farther away, or play softer.")
        }
        if snr < 6 {
            return Advice(status: .noSignal, message: "No note was heard. \(placementTip(instrument: instrument, isPad: isPad))")
        }
        if noiseFloorDBFS > -42 {
            return Advice(status: .noisyRoom, message: "The room is noisy. Turn off fans, music, or the TV if you can; listening works best with quiet between notes.")
        }
        if peakDBFS < -42 || snr < 18 {
            return Advice(status: .tooQuiet, message: "The note is quiet. \(placementTip(instrument: instrument, isPad: isPad))")
        }
        return Advice(status: .good, message: "Level looks good.")
    }

    /// Placement guidance for the microphone.
    static func placementTip(instrument: TutorInstrument, isPad: Bool) -> String {
        switch (instrument, isPad) {
        case (.guitar, true):
            return "Put the iPad on a stand within about 1 m of the guitar, with its top edge (where the microphones are) toward the sound hole, and keep the case and your hands off that edge."
        case (.piano, true):
            return "Stand the iPad on the music desk with its top edge toward the strings or open lid. Keep the case off the top edge, where the microphones are."
        case (.guitar, false):
            return "Hold or place the device about 30–60 cm from the sound hole, with the bottom microphone facing the guitar."
        case (.piano, false):
            return "Place the device on the music desk, microphone toward the strings."
        }
    }

    private static func noun(_ i: TutorInstrument) -> String { i == .guitar ? "guitar" : "piano" }
}
