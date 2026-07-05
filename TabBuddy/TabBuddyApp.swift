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

    /// CloudKit container for the personal-metadata sync (FileItem). Dev builds
    /// and the store build are signed by different teams, so each build's data
    /// lives in its own container; the backup export/import bridges them.
    /// Deliberately in the dev namespace — container IDs are global and
    /// permanent, so the com.gamicarts.* name stays free for the store team.
    private static let cloudKitContainerID = "iCloud.net.hweeks.tabbuddy"

    /// Whether CloudKit mirroring can be enabled. Entitlement-less builds
    /// (unit tests, `CODE_SIGNING_ALLOWED=NO` simulator builds) crash with an
    /// uncatchable ObjC exception deep in CloudKit setup, so this must be
    /// decided up front. `ubiquityIdentityToken` is nil when the process lacks
    /// the iCloud entitlement or no iCloud account is signed in — in both
    /// cases mirroring must stay off (the app then runs local-only).
    private static var cloudKitAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Store layout:
    ///   • "cloud" — FileItem, mirrored to the user's private CloudKit database
    ///     (tags, favorites, recents, play counts follow the user across devices).
    ///   • "local" — TagStat (derived index, rebuilt on demand) and ComposedTab
    ///     (Maker documents), device-local.
    private static func makeConfigurations() -> [ModelConfiguration] {
        let cloud = ModelConfiguration(
            "cloud",
            schema: Schema([FileItem.self]),
            cloudKitDatabase: cloudKitAvailable ? .private(cloudKitContainerID) : .none
        )
        let local = ModelConfiguration(
            "local",
            schema: Schema([TagStat.self, ComposedTab.self]),
            cloudKitDatabase: .none
        )
        return [cloud, local]
    }

    /// Loads the SwiftData store, recovering from an incompatible on-disk store
    /// rather than coming up with a broken container (which silently breaks every
    /// query and save). This happens when an older-schema store can't migrate in
    /// place — e.g. a store created before a mandatory attribute was added.
    /// If CloudKit mirroring can't come up at all (e.g. unprovisioned container),
    /// falls back to an equivalent local-only store so the app still works.
    private static func makeContainer() -> ModelContainer {
        let configs = makeConfigurations()
        do {
            return try ModelContainer(for: schema, configurations: configs)
        } catch {
            print("[TabBuddyApp] store failed to load (\(error)). Archiving and recreating.")
            for config in configs { archiveIncompatibleStore(at: config.url) }
            do {
                return try ModelContainer(for: schema, configurations: configs)
            } catch {
                print("[TabBuddyApp] retry failed (\(error)). Falling back to local-only store.")
                let localOnly = [
                    ModelConfiguration("cloud", schema: Schema([FileItem.self]), cloudKitDatabase: .none),
                    ModelConfiguration("local", schema: Schema([TagStat.self, ComposedTab.self]), cloudKitDatabase: .none)
                ]
                do {
                    return try ModelContainer(for: schema, configurations: localOnly)
                } catch {
                    fatalError("Unrecoverable ModelContainer error after reset: \(error)")
                }
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
