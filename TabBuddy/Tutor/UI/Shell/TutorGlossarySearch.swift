//
//  TutorGlossarySearch.swift
//  TabBuddy
//
//  Glossary filtering for GlossaryView: term prefix matches first, then term
//  substring matches, then definition matches. Case- and diacritic-insensitive.
//

import Foundation

enum TutorGlossarySearch {
    static func filter(_ entries: [GlossaryEntry], query: String) -> [GlossaryEntry] {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return entries }
        var prefix: [GlossaryEntry] = [], inTerm: [GlossaryEntry] = [], inDefinition: [GlossaryEntry] = []
        for entry in entries {
            let term = fold(entry.term)
            if term.hasPrefix(q) || term.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
                prefix.append(entry)
            } else if term.contains(q) {
                inTerm.append(entry)
            } else if fold(entry.definition).contains(q) {
                inDefinition.append(entry)
            }
        }
        return prefix + inTerm + inDefinition
    }

    /// Groups entries by first letter ("#" for digits and symbols).
    static func sections(_ entries: [GlossaryEntry]) -> [(letter: String, entries: [GlossaryEntry])] {
        var order: [String] = []
        var groups: [String: [GlossaryEntry]] = [:]
        for entry in entries {
            let first = entry.term.first.map { String($0).uppercased() } ?? "#"
            let key = first.rangeOfCharacter(from: .letters) != nil ? first : "#"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
