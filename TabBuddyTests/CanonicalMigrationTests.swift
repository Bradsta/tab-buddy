//
//  CanonicalMigrationTests.swift
//  TabBuddyTests
//
//  Verifies the Phase 2 schema additions are non-destructive and that the new
//  canonical/provenance fields behave correctly.
//

import XCTest
import SwiftData
import SwiftUI
import PDFKit
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
    @MainActor
    func testScoreMetadataSurvivesBackupAndUserEditsWin() throws {
        let context = try makeContext()
        let file = FileItem(bookmark: Data(), filename: "sonata.pdf")
        context.insert(file)
        XCTAssertEqual(file.instrumentKinds, [.unknown])
        file.inferMetadata(from: "Piano and voice\nComposer: Example Composer\nArranger: Example Arranger\nAlbum: Exercises")
        XCTAssertEqual(Set(file.instrumentKinds), [.piano, .voice])
        XCTAssertEqual(file.composer, "Example Composer")
        file.metadataEdited = true
        file.arrangement = "Duet"
        file.sourceURL = "https://example.com/score"
        file.inferMetadata(from: "Guitar\nComposer: Wrong")
        XCTAssertEqual(file.composer, "Example Composer")
        XCTAssertEqual(Set(file.instrumentKinds), [.piano, .voice])
        let backup = try XCTUnwrap(BackupManager.exportJSON(context: context))
        file.instruments = [Instrument.guitar.rawValue]
        file.composer = "Changed"
        file.sourceURL = nil
        XCTAssertEqual(BackupManager.importJSON(data: backup, context: context), 1)
        XCTAssertEqual(Set(file.instrumentKinds), [.piano, .voice])
        XCTAssertEqual(file.arrangement, "Duet")
        XCTAssertEqual(file.sourceURL, "https://example.com/score")
        XCTAssertTrue(file.metadataEdited)
    }

    @MainActor
    func testDiscoveryAndDetailsLayouts() throws {
        let context = try makeContext()
        let file = FileItem(bookmark: Data(), filename: "Piano and Voice.pdf")
        file.instruments = ["piano", "voice"]
        context.insert(file)
        let views: [(String, AnyView)] = [
            ("Discovery — iPhone", AnyView(ScoreDiscoveryView(query: "Bach", instrumentRaw: "piano", onImport: {}))),
            ("Score details — iPhone", AnyView(ScoreDetailsView(file: file).modelContainer(context.container)))
        ]
        for (name, view) in views {
            let host = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
            let image = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testEmbeddedTextMetadataRoundTripsWithoutChangingTabBody() throws {
        let body = Data("Original credits\r\ne|--0--|\r\nB|--1--|\r\n".utf8)
        let metadata = EmbeddedScoreMetadata(title: "Étude [/TabBuddy Metadata]", composer: " Original\ncomposer ", instruments: ["guitar"], sourceURL: "https://example.com/score")
        let enriched = try metadata.writing(to: body, extension: "txt")
        XCTAssertEqual(try EmbeddedScoreMetadata.read(data: enriched, extension: "txt"), metadata)
        XCTAssertEqual(try EmbeddedScoreMetadata.textBody(enriched), body)
        XCTAssertEqual(try metadata.writing(to: enriched, extension: "txt"), enriched)
    }

    func testEmbeddedPDFMetadataPreservesPageTextAndAnnotations() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { renderer in
            renderer.beginPage()
            ("Original score" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 60, width: 30, height: 30), forType: .text, withProperties: nil)
        annotation.contents = "Original annotation"
        document.page(at: 0)?.addAnnotation(annotation)
        let before = try XCTUnwrap(document.dataRepresentation())
        let metadata = EmbeddedScoreMetadata(title: "Piano study", composer: "Test composer", instruments: ["piano"], sourceURL: "https://example.com/score")
        let after = try metadata.writing(to: before, extension: "pdf")
        XCTAssertEqual(try EmbeddedScoreMetadata.read(data: after, extension: "pdf"), metadata)
        let reopened = try XCTUnwrap(PDFDocument(data: after))
        XCTAssertEqual(reopened.pageCount, 1)
        XCTAssertEqual(reopened.string, document.string)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.contents, "Original annotation")
        XCTAssertEqual(reopened.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, metadata.title)
    }

    func testLegacyGuitarProHeaderEditPreservesMusicalBytes() throws {
        func block(_ value: String) -> Data {
            let bytes = Data(value.utf8)
            var length = UInt32(bytes.count + 1).littleEndian
            return withUnsafeBytes(of: &length) { Data($0) } + Data([UInt8(bytes.count)]) + bytes
        }
        for version in [3, 4, 5] {
            let text = "FICHIER GUITAR PRO v\(version).00"
            var original = Data([UInt8(text.utf8.count)]) + Data(text.utf8)
            original.append(Data(repeating: 0, count: 31 - original.count))
            for _ in 0..<(version == 5 ? 9 : 8) { original += block("Original") }
            original += Data([1, 0, 0, 0]) + block("Keep original notice")
            let music = Data([0, 255, 24, 48, 80, 0, 1, 2])
            original += music
            let metadata = EmbeddedScoreMetadata(title: "Edited", artist: "Artist", composer: "Composer", instruments: ["bass"], sourceURL: "https://example.com/tab", sourceID: String(repeating: "Long source identifier 音", count: 40))
            let updated = try metadata.writing(to: original, extension: "gp\(version)")
            let info = try LegacyGuitarProMetadata(updated)
            XCTAssertEqual(updated.dropFirst(info.suffixOffset), music)
            XCTAssertTrue(info.notices.contains("Keep original notice"))
            XCTAssertEqual(try EmbeddedScoreMetadata.read(data: updated, extension: "gp\(version)"), metadata)
            XCTAssertEqual(try metadata.writing(to: updated, extension: "gp\(version)"), updated)
        }
    }

}
