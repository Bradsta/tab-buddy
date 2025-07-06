//
//  TagStat.swift
//  TabBuddy
//


import SwiftData

@Model
final class TagStat {
    @Attribute(.unique) var name:  String     // lowercase tag text
    var count: Int                            // # of files that have it

    init(name: String, count: Int = 0) {
        self.name  = name
        self.count = count
    }
}
