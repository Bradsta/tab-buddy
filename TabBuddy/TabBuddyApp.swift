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
    @StateObject private var persistence = LibraryPersistence()

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = persistence.container {
                    ContentView().modelContainer(container)
                } else {
                    ProgressView("Updating library sync…")
                        .task { persistence.reopen() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
                Task { @MainActor in await persistence.reloadIfNeeded() }
            }
            .onReceive(NotificationCenter.default.publisher(for: LibrarySyncPreference.didChange)) { notification in
                guard let defaults = notification.object as? UserDefaults, defaults === UserDefaults.standard else { return }
                Task { @MainActor in
                    // Let the storage operation finish releasing its model context first.
                    await Task.yield()
                    await persistence.reloadIfNeeded()
                }
            }
        }
    }

    // MARK: - Model container

    private static let schema = Schema([
        FileItem.self, LibraryDescriptor.self,
        TagStat.self, ComposedTab.self, LibraryMount.self,
        FilePresence.self, LibraryMoveJob.self
    ])

    /// CloudKit container for personal-metadata sync. This identifier must stay
    /// aligned with the app's entitlements and provisioning; changing it would
    /// create a separate metadata store.
    private static let cloudKitContainerID = "iCloud.com.gamicarts.TabBuddy.library"

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
    /// Library info mirrors through CloudKit only for iCloud only and Hybrid, and
    /// only while an iCloud account is available. Local only never mirrors.
    static func mirrorsMetadata(option: LibraryStorageOption?, cloudAvailable: Bool) -> Bool {
        (option?.syncsMetadata ?? false) && cloudAvailable
    }

    static func makeConfigurations(option: LibraryStorageOption?, cloudAvailable: Bool? = nil) -> [ModelConfiguration] {
        makeConfigurations(syncEnabled: option?.syncsMetadata ?? false, cloudAvailable: cloudAvailable)
    }

    static func makeConfigurations(syncEnabled: Bool, cloudAvailable: Bool? = nil) -> [ModelConfiguration] {
        let cloud = ModelConfiguration(
            "cloud",
            schema: Schema([FileItem.self, LibraryDescriptor.self]),
            cloudKitDatabase: syncEnabled && (cloudAvailable ?? cloudKitAvailable) ? .private(cloudKitContainerID) : .none
        )
        let local = ModelConfiguration(
            "local",
            schema: Schema([TagStat.self, ComposedTab.self, LibraryMount.self,
                            FilePresence.self, LibraryMoveJob.self]),
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
    static func makeContainer(syncEnabled: Bool) -> ModelContainer {
        let configs = makeConfigurations(syncEnabled: syncEnabled)
        do {
            return try ModelContainer(for: schema, configurations: configs)
        } catch {
            // A CloudKit/account/configuration failure is not proof of an
            // incompatible store. Never move user data aside on a generic
            // initialization error; first try the same schemas locally.
            print("[TabBuddyApp] cloud-backed store failed (\(error)). Trying local-only stores.")
            do {
                let localOnly = [
                    ModelConfiguration("cloud", schema: Schema([FileItem.self, LibraryDescriptor.self]), cloudKitDatabase: .none),
                    ModelConfiguration("local", schema: Schema([TagStat.self, ComposedTab.self,
                                                                  LibraryMount.self, FilePresence.self,
                                                                  LibraryMoveJob.self]), cloudKitDatabase: .none)
                ]
                return try ModelContainer(for: schema, configurations: localOnly)
            } catch {
                fatalError("Unrecoverable ModelContainer error without modifying stores: \(error)")
            }
        }
    }
}


/// Rebuild the same stores with the requested CloudKit configuration. The temporary
/// loading view removes old queries/navigation before another container is opened.
@MainActor
final class LibraryPersistence: ObservableObject {
    @Published private(set) var container: ModelContainer?
    private var syncEnabled: Bool
    private var reloading = false
    private var cloudAccountAvailable = FileManager.default.ubiquityIdentityToken != nil
    private let defaults: UserDefaults
    private let buildContainer: @MainActor (Bool) -> ModelContainer
    private let finishWork: () async -> Void

    init(defaults: UserDefaults = .standard,
         buildContainer: @escaping @MainActor (Bool) -> ModelContainer = { TabBuddyApp.makeContainer(syncEnabled: $0) },
         finishWork: @escaping () async -> Void = { await LibraryManager.shared.finishDatabaseWork() }) {
        self.defaults = defaults
        self.buildContainer = buildContainer
        self.finishWork = finishWork
        syncEnabled = LibrarySyncPreference.isEnabled(in: defaults)
        container = buildContainer(syncEnabled)
    }

    func reloadIfNeeded() async {
        let accountAvailable = FileManager.default.ubiquityIdentityToken != nil
        guard syncEnabled != LibrarySyncPreference.isEnabled(in: defaults) || cloudAccountAvailable != accountAvailable else { return }
        guard container != nil, !reloading else { return }
        reloading = true
        defer { reloading = false }
        await finishWork()
        do { try container?.mainContext.save() }
        catch {
            LibraryManager.shared.lastError = "Could not save the library before updating sync: \(error.localizedDescription)"
            return
        }
        container = nil
    }

    func reopen() {
        guard container == nil else { return }
        syncEnabled = LibrarySyncPreference.isEnabled(in: defaults)
        cloudAccountAvailable = FileManager.default.ubiquityIdentityToken != nil
        container = buildContainer(syncEnabled)
    }
}
