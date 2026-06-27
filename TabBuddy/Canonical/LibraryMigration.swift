//
//  LibraryMigration.swift
//  TabBuddy
//
//  One-time, defensive metadata migration steps run at launch.
//
//  The SwiftData schema change in Phase 2 (canonical reference + provenance on
//  FileItem) is additive-optional, so SwiftData migrates the on-disk store in
//  place without touching existing metadata. As an extra safety net for users
//  with large existing libraries, the first launch after the upgrade exports a
//  full JSON snapshot of all metadata (tags, favorites, BPM, loops, play counts)
//  to Documents/Backups, so nothing is unrecoverable even in a worst case.
//

import Foundation
import SwiftData

enum LibraryMigration {

    /// Bump when a launch-time migration step is added.
    static let currentSchemaVersion = 2   // 1 = pre-canonical
    private static let schemaVersionKey = "tabbuddy.schemaVersion"

    /// Run any pending one-time migration steps. Safe to call on every launch;
    /// each step runs at most once. Must run after the container has opened
    /// successfully (so the store has already migrated in place).
    @MainActor
    static func runIfNeeded(context: ModelContext) {
        let previous = UserDefaults.standard.integer(forKey: schemaVersionKey) // 0 if unset
        guard previous < currentSchemaVersion else { return }

        // Snapshot existing metadata before recording the new version, so a
        // crash mid-step re-runs the snapshot next launch rather than skipping it.
        snapshotMetadata(context: context, reason: "pre-canonical-v\(currentSchemaVersion)")

        UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
    }

    /// Directory where defensive snapshots are written (visible in Files).
    static var backupsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Backups", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Export a full metadata snapshot to Documents/Backups. No-op (other than a
    /// log) if there is nothing to back up.
    @MainActor
    @discardableResult
    static func snapshotMetadata(context: ModelContext, reason: String) -> URL? {
        // Skip the write entirely for empty libraries (e.g. fresh installs).
        let count = (try? context.fetchCount(FetchDescriptor<FileItem>())) ?? 0
        guard count > 0 else { return nil }

        guard let data = BackupManager.exportJSON(context: context) else {
            print("[LibraryMigration] metadata snapshot failed to encode")
            return nil
        }

        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let url = backupsDirectory.appendingPathComponent("\(reason)-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            print("[LibraryMigration] snapshotted \(count) items -> \(url.lastPathComponent)")
            return url
        } catch {
            print("[LibraryMigration] could not write snapshot: \(error)")
            return nil
        }
    }
}
