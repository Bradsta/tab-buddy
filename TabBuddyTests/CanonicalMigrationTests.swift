//
//  CanonicalMigrationTests.swift
//  TabBuddyTests
//
//  Verifies the Phase 2 schema additions are non-destructive and that the new
//  canonical/provenance fields behave correctly.
//

import XCTest
import SwiftData
@testable import TabBuddy

final class CanonicalMigrationTests: XCTestCase {

    /// Build an in-memory container over the real schema.
    private func makeContext() throws -> ModelContext {
        let schema = Schema([FileItem.self, TagStat.self, ComposedTab.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    /// A FileItem created the "old" way (no canonical fields set) keeps all its
    /// metadata and gets safe defaults for the new fields.
    func testExistingMetadataPreservedWithNewSchema() throws {
        let context = try makeContext()

        let item = FileItem(bookmark: Data([1, 2, 3]),
                            filename: "song.txt",
                            isFavorite: true,
                            tags: ["jazz", "practice"],
                            folderName: "Standards")
        item.playCount = 7
        item.userBPM = 132
        context.insert(item)
        try context.save()

        // Re-fetch and confirm metadata is intact and new fields defaulted.
        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<FileItem>()).first)
        XCTAssertEqual(fetched.filename, "song.txt")
        XCTAssertTrue(fetched.isFavorite)
        XCTAssertEqual(fetched.tags, ["jazz", "practice"])
        XCTAssertEqual(fetched.folderName, "Standards")
        XCTAssertEqual(fetched.playCount, 7)
        XCTAssertEqual(fetched.userBPM, 132)

        // New canonical fields: safe defaults.
        XCTAssertNil(fetched.canonicalFilename)
        XCTAssertNil(fetched.provenanceData)
        XCTAssertEqual(fetched.canonicalVersion, 0)
        XCTAssertFalse(fetched.hasCanonical)
        XCTAssertNil(fetched.provenance)
    }

    /// The provenance computed accessor round-trips through provenanceData.
    func testProvenanceAccessorRoundTrips() throws {
        let context = try makeContext()
        let item = FileItem(bookmark: Data(), filename: "x.txt")
        context.insert(item)

        let prov = Provenance(sourceType: .pdfText,
                              confidence: 0.6,
                              converterVersion: CanonicalConverterVersion.current,
                              rhythmSource: .synthesized,
                              clipped: true)
        item.provenance = prov
        item.canonicalFilename = CanonicalStore.filename(for: item.id)
        item.canonicalVersion = prov.converterVersion
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<FileItem>()).first)
        XCTAssertTrue(fetched.hasCanonical)
        XCTAssertEqual(fetched.provenance, prov)
        XCTAssertEqual(fetched.canonicalVersion, CanonicalConverterVersion.current)
        XCTAssertTrue(fetched.canonicalFilename?.hasSuffix(".musicxml") ?? false)
    }

    /// CanonicalStore writes/reads/deletes a canonical file by stable name.
    func testCanonicalStoreRoundTrip() throws {
        let id = UUID()
        let name = CanonicalStore.filename(for: id)
        let payload = Data("<score-partwise/>".utf8)

        try CanonicalStore.write(payload, filename: name)
        XCTAssertTrue(CanonicalStore.exists(filename: name))
        XCTAssertEqual(CanonicalStore.read(filename: name), payload)

        CanonicalStore.delete(filename: name)
        XCTAssertFalse(CanonicalStore.exists(filename: name))
    }
}
