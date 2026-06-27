//
//  CanonicalStore.swift
//  TabBuddy
//
//  Local on-disk storage for generated canonical MusicXML files.
//
//  Phase 2 stores these in Application Support; Phase 3 will relocate the
//  directory into the iCloud app container (the canonical becomes the portable
//  source of truth). Callers address files by a stable name derived from the
//  owning FileItem's id, so the reference survives renames/moves of the original.
//

import Foundation

enum CanonicalStore {

    /// Directory holding `<id>.musicxml` files. Created on first access.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Canonical", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
        }
        return dir
    }

    /// Stable filename for a given FileItem id.
    static func filename(for id: UUID) -> String {
        "\(id.uuidString).musicxml"
    }

    static func url(forFilename filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    static func write(_ data: Data, filename: String) throws {
        try data.write(to: url(forFilename: filename), options: .atomic)
    }

    static func read(filename: String) -> Data? {
        try? Data(contentsOf: url(forFilename: filename))
    }

    static func delete(filename: String) {
        try? FileManager.default.removeItem(at: url(forFilename: filename))
    }

    static func exists(filename: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forFilename: filename).path)
    }
}
