//
//  TabBuddyApp.swift
//  TabBuddy
//
//  Created by Brad Guerrero on 4/23/23.
//

import SwiftUI
import SwiftData

@main
struct TabBuddyApp: App {    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [FileItem.self, TagStat.self])
    }
}
