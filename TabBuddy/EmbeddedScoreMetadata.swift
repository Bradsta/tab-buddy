import Foundation
import PDFKit

/// Portable descriptive fields only. No bookmarks, recents, or practice state.
struct EmbeddedScoreMetadata: Codable, Equatable, Sendable {
    var title: String? = nil
    var artist: String? = nil
    var composer: String? = nil
    var arranger: String? = nil
    var collection: String? = nil
    var arrangement: String? = nil
    var instruments: [String]? = nil
    var tuning: String? = nil
    var sourceName: String? = nil
    var sourceURL: String? = nil
    var sourceID: String? = nil
    var copyright: String? = nil

    static let start = "[TabBuddy Metadata v1]"
    static let end = "[/TabBuddy Metadata]"
    static let pdfPrefix = "TabBuddyMetadata:v1:"
    static let fields = ["Title", "Artist", "Composer", "Arranger", "Collection", "Arrangement", "Instruments", "Tuning", "Source", "Source URL", "Source ID", "Copyright"]

    var values: [String?] {
        [title, artist, composer, arranger, collection, arrangement, instruments?.joined(separator: ", "), tuning, sourceName, sourceURL, sourceID, copyright]
    }

    var header: String {
        let lines = zip(Self.fields, values).compactMap { key, value -> String? in
            guard let value else { return nil }
            // Quote values only when needed to retain whitespace and line breaks.
            let needsQuotes = value.contains("\n") || value.contains("\r") || value.hasPrefix("\"") || value != value.trimmingCharacters(in: .whitespacesAndNewlines)
            let encoded = needsQuotes ? String(decoding: try! JSONEncoder().encode(value), as: UTF8.self) : value
            return key + ": " + encoded
        }
        return ([Self.start] + lines + [Self.end, ""]).joined(separator: "\n")
    }

    static func parseHeader(_ text: String) -> EmbeddedScoreMetadata? {
        let lines = text.components(separatedBy: .newlines)
        let marked = lines.firstIndex(of: start)
        let endIndex = marked.flatMap { begin in lines[(begin + 1)...].firstIndex(of: end) }
        if marked != nil && endIndex == nil { return nil }
        let selected = marked.map { Array(lines[($0 + 1)..<(endIndex ?? lines.count)]) } ?? Array(lines.prefix(100))
        var fields: [String: String] = [:]
        var unfolded: [String] = []
        for line in selected {
            if marked != nil && line.hasPrefix("> ") && !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += line.dropFirst(2)
            } else { unfolded.append(line) }
        }
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard Self.fields.contains(where: { $0.lowercased() == key }) || key == "instrument" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value.hasPrefix("\"") ? ((try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value) : value
        }
        guard !fields.isEmpty else { return nil }
        let instruments = (fields["instruments"] ?? fields["instrument"]).map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        return Self(title: fields["title"], artist: fields["artist"], composer: fields["composer"], arranger: fields["arranger"], collection: fields["collection"], arrangement: fields["arrangement"], instruments: instruments, tuning: fields["tuning"], sourceName: fields["source"], sourceURL: fields["source url"], sourceID: fields["source id"], copyright: fields["copyright"])
    }

    static func textBody(_ data: Data) throws -> Data {
        let startData = Data((start + "\n").utf8)
        let crlfStart = Data((start + "\r\n").utf8)
        guard data.starts(with: startData) || data.starts(with: crlfStart) else { return data }
        let endings = ["\n" + end + "\n", "\n" + end + "\r\n"]
        guard let range = endings.compactMap({ data.range(of: Data($0.utf8)) }).min(by: { $0.lowerBound < $1.lowerBound }) else { throw MetadataError.invalidHeader }
        return Data(data.dropFirst(range.upperBound))
    }

    static func canWrite(extension ext: String) -> Bool { ["txt", "pdf", "gp3", "gp4", "gp5"].contains(ext.lowercased()) }

    static func read(data: Data, extension ext: String) throws -> Self? {
        switch ext.lowercased() {
        case "txt":
            return parseHeader(String(decoding: data.prefix(65536), as: UTF8.self))
        case "gp3", "gp4", "gp5":
            let info = try LegacyGuitarProMetadata(data)
            if info.notices.hasPrefix(start + "\n"), let embedded = parseHeader(info.notices) { return embedded }
            let v = info.strings
            return Self(title: v[0], artist: v[2], composer: info.version >= 5 ? v[5] : nil,
                        arranger: v[info.version >= 5 ? 7 : 6], collection: v[3], copyright: v[info.version >= 5 ? 6 : 5])
        case "pdf":
            guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
            let attrs = document.documentAttributes ?? [:]
            if let keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String],
               let encoded = keywords.first(where: { $0.hasPrefix(pdfPrefix) }),
               let bytes = Data(base64Encoded: String(encoded.dropFirst(pdfPrefix.count))),
               let metadata = try? JSONDecoder().decode(Self.self, from: bytes) { return metadata }
            return Self(title: attrs[PDFDocumentAttribute.titleAttribute] as? String)
        default: return nil
        }
    }

    func writing(to data: Data, extension ext: String) throws -> Data {
        switch ext.lowercased() {
        case "txt":
            guard String(data: data, encoding: .utf8) != nil else { throw MetadataError.invalidHeader }
            return Data(header.utf8) + (try Self.textBody(data))
        case "gp3", "gp4", "gp5": return try LegacyGuitarProMetadata(data).writing(self)
        case "pdf":
            guard let document = PDFDocument(data: data), !document.isEncrypted else { throw MetadataError.protectedPDF }
            // PDFKit preserves document objects instead of drawing pages into a new PDF.
            var attrs = document.documentAttributes ?? [:]
            if let title { attrs[PDFDocumentAttribute.titleAttribute] = title }
            var keywords = (attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] ?? []).filter { !$0.hasPrefix(Self.pdfPrefix) }
            keywords.append(Self.pdfPrefix + (try JSONEncoder().encode(self)).base64EncodedString())
            attrs[PDFDocumentAttribute.keywordsAttribute] = keywords
            document.documentAttributes = attrs
            guard let result = document.dataRepresentation(),
                  let verified = PDFDocument(data: result), verified.pageCount == document.pageCount,
                  try Self.read(data: result, extension: "pdf") == self else { throw MetadataError.verificationFailed }
            return result
        default: throw MetadataError.unsupported
        }
    }
}

enum MetadataError: LocalizedError {
    case invalidHeader, unsupported, protectedPDF, verificationFailed, fieldTooLong, changedFile
    var errorDescription: String? {
        switch self {
        case .invalidHeader: return "The embedded metadata header is invalid. The file was not changed."
        case .unsupported: return "Writing metadata to this file format is not yet supported."
        case .protectedPDF: return "This PDF is protected. Its metadata cannot be changed here."
        case .verificationFailed: return "The metadata update could not be verified. The original file was kept."
        case .fieldTooLong: return "A metadata field is too long for this Guitar Pro version (255 UTF-8 bytes per line)."
        case .changedFile: return "The score changed while metadata was being saved. Try saving again."
        }
    }
}

/// GP3–5 place descriptive strings before all musical data. Preserve every
/// unedited field byte-for-byte, and copy the entire musical suffix unchanged.
struct LegacyGuitarProMetadata {
    let data: Data
    let version: Int
    let strings: [String]
    let blocks: [Data]
    let notices: String
    let noticeBlocks: [Data]
    let suffixOffset: Int

    init(_ data: Data) throws {
        guard data.count >= 31 else { throw MetadataError.invalidHeader }
        let versionText = String(decoding: data.prefix(31), as: UTF8.self)
        guard versionText.contains("FICHIER GUITAR PRO v"),
              let v = [3,4,5].first(where: { versionText.contains("v\($0).") }) else { throw MetadataError.invalidHeader }
        version = v
        self.data = data
        var offset = 31
        func int32() throws -> Int {
            guard offset + 4 <= data.count else { throw MetadataError.invalidHeader }
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
            offset += 4
            return Int(value)
        }
        func block() throws -> (Data, String) {
            let begin = offset
            _ = try int32()
            guard offset < data.count else { throw MetadataError.invalidHeader }
            let count = Int(data[offset]); offset += 1
            guard offset + count <= data.count else { throw MetadataError.invalidHeader }
            let text = String(decoding: data[offset..<(offset + count)], as: UTF8.self)
            offset += count
            return (Data(data[begin..<offset]), text)
        }
        var parsed: [(Data,String)] = []
        for _ in 0..<(v >= 5 ? 9 : 8) { parsed.append(try block()) }
        blocks = parsed.map(\.0); strings = parsed.map(\.1)
        let count = try int32()
        guard count <= 1000 else { throw MetadataError.invalidHeader }
        var notes: [(Data,String)] = []
        for _ in 0..<count { notes.append(try block()) }
        noticeBlocks = notes.map(\.0)
        notices = notes.map(\.1).joined(separator: "\n")
        suffixOffset = offset
    }

    func writing(_ metadata: EmbeddedScoreMetadata) throws -> Data {
        func encoded(_ text: String) throws -> Data {
            let bytes = Data(text.utf8)
            guard bytes.count <= 255 else { throw MetadataError.fieldTooLong }
            var length = UInt32(bytes.count + 1).littleEndian
            return withUnsafeBytes(of: &length) { Data($0) } + Data([UInt8(bytes.count)]) + bytes
        }
        var result = Data(data.prefix(31))
        var edits: [Int:String] = [:]
        edits[0] = metadata.title; edits[2] = metadata.artist; edits[3] = metadata.collection
        if version >= 5 { edits[5] = metadata.composer }
        edits[version >= 5 ? 7 : 6] = metadata.arranger
        edits[version >= 5 ? 6 : 5] = metadata.copyright
        for i in blocks.indices {
            if let value = edits[i], value != strings[i] { result += try encoded(value) }
            else { result += blocks[i] }
        }
        var kept = noticeBlocks
        let oldLines = notices.components(separatedBy: "\n")
        if oldLines.first == EmbeddedScoreMetadata.start {
            guard let end = oldLines.firstIndex(of: EmbeddedScoreMetadata.end) else { throw MetadataError.invalidHeader }
            kept = Array(kept.dropFirst(end + 1))
            if oldLines.indices.contains(end + 1), oldLines[end + 1].isEmpty { kept = Array(kept.dropFirst()) }
        }
        var wrapped: [String] = []
        for line in metadata.header.components(separatedBy: "\n") {
            var chunk = ""
            for scalar in line.unicodeScalars {
                let next = String(scalar)
                if chunk.utf8.count + next.utf8.count > 240 {
                    wrapped.append(chunk)
                    chunk = "> "
                }
                chunk += next
            }
            wrapped.append(chunk)
        }
        let added = try wrapped.map(encoded)
        guard added.count + kept.count <= 1000 else { throw MetadataError.fieldTooLong }
        var count = UInt32(added.count + kept.count).littleEndian
        result += withUnsafeBytes(of: &count) { Data($0) }
        for block in added + kept { result += block }
        result += data.dropFirst(suffixOffset)
        let verified = try LegacyGuitarProMetadata(result)
        guard result.dropFirst(verified.suffixOffset) == data.dropFirst(suffixOffset) else { throw MetadataError.verificationFailed }
        return result
    }
}

#if !METADATA_STANDALONE
extension FileItem {
    var portableMetadata: EmbeddedScoreMetadata {
        EmbeddedScoreMetadata(title: customTitle ?? embeddedTitle ?? displayTitle, artist: artist, composer: composer,
                              arranger: arranger, collection: collectionTitle, arrangement: arrangement,
                              instruments: instrumentKinds.filter { $0 != .unknown }.map(\.rawValue), tuning: tuning,
                              sourceName: sourceName, sourceURL: sourceURL, sourceID: sourceID, copyright: copyrightNotice)
    }

    func applyEmbeddedMetadata(_ value: EmbeddedScoreMetadata, overwrite: Bool = false) {
        guard overwrite || !metadataEdited else { return }
        if let v = value.title { embeddedTitle = v }
        if let v = value.artist { artist = v }
        if let v = value.composer { composer = v }
        if let v = value.arranger { arranger = v }
        if let v = value.collection { collectionTitle = v }
        if let v = value.arrangement { arrangement = v }
        if let v = value.instruments {
            instruments = v.compactMap { Instrument(rawValue: $0.lowercased())?.rawValue }
            instrument = instruments.first ?? Instrument.unknown.rawValue
        }
        if let v = value.tuning { tuning = v }
        if let v = value.sourceName { sourceName = v }
        if let v = value.sourceURL { sourceURL = v }
        if let v = value.sourceID { sourceID = v }
        if let v = value.copyright { copyrightNotice = v }
    }
}

#endif
