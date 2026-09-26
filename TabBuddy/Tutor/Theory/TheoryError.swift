//
//  TheoryError.swift
//  TabBuddy
//
//  Parse errors for the theory core. Messages are written for content authors:
//  they name the rejected text and say what was expected.
//

import Foundation

struct TheoryParseError: Error, LocalizedError, Hashable, Sendable, CustomStringConvertible {
    enum Kind: String, Codable, Hashable, Sendable {
        case note, pitch, pitchClass, interval, scale, chord, key, romanNumeral, rhythm, fretPosition, fingering
    }

    var kind: Kind
    /// The text that failed to parse.
    var input: String
    /// Why it failed and what was expected.
    var reason: String

    var errorDescription: String? { description }
    var description: String { "Invalid \(kind.rawValue) \"\(input)\": \(reason)" }
}

/// Shared helper for types that encode as their string form.
extension SingleValueDecodingContainer {
    func decodeTheoryString<T>(_ parse: (String) throws -> T) throws -> T {
        let raw = try decode(String.self)
        do {
            return try parse(raw)
        } catch let error as TheoryParseError {
            throw DecodingError.dataCorruptedError(in: self, debugDescription: error.description)
        }
    }
}
