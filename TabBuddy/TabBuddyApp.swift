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
    let container = TabBuddyApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }

    // MARK: - Model container

    private static let schema = Schema([FileItem.self, TagStat.self, ComposedTab.self])

    /// Loads the SwiftData store, recovering from an incompatible on-disk store
    /// rather than coming up with a broken container (which silently breaks every
    /// query and save). This happens when an older-schema store can't migrate in
    /// place — e.g. a store created before a mandatory attribute was added.
    private static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("[TabBuddyApp] store failed to load (\(error)). Archiving and recreating.")
            archiveIncompatibleStore(at: config.url)
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Unrecoverable ModelContainer error after reset: \(error)")
            }
        }
    }

    /// Moves the store (and its `-shm` / `-wal` sidecars) aside with a timestamped
    /// suffix so a fresh store can be created. Non-destructive: the old files are
    /// renamed, not deleted, so they can be recovered if needed.
    private static func archiveIncompatibleStore(at storeURL: URL) {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        for sidecar in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: storeURL.path + sidecar)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: src.path + ".corrupt-\(stamp)")
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                print("[TabBuddyApp] could not archive \(src.lastPathComponent): \(error)")
            }
        }
    }
}
