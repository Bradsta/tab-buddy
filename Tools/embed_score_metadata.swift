import Foundation

/// Line-delimited jobs reuse the app's tested codec without re-exporting scores.
@main
struct MetadataTool {
    struct Job: Decodable { let input: String; let output: String; let metadata: EmbeddedScoreMetadata }
    static func main() {
        while let line = readLine() {
            do {
                let job = try JSONDecoder().decode(Job.self, from: Data(line.utf8))
                let input = URL(fileURLWithPath: job.input)
                let original = try Data(contentsOf: input)
                let ext = input.pathExtension.lowercased()
                var metadata = (try EmbeddedScoreMetadata.read(data: original, extension: ext)) ?? EmbeddedScoreMetadata()
                // Source pages fill gaps; they never replace original score credits.
                if metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { metadata.title = job.metadata.title }
                if metadata.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { metadata.artist = job.metadata.artist }
                if metadata.collection?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { metadata.collection = job.metadata.collection }
                metadata.sourceName = job.metadata.sourceName
                metadata.sourceURL = job.metadata.sourceURL
                metadata.sourceID = job.metadata.sourceID
                let updated = try metadata.writing(to: original, extension: ext)
                guard try EmbeddedScoreMetadata.read(data: updated, extension: ext) == metadata else { throw MetadataError.verificationFailed }
                try updated.write(to: URL(fileURLWithPath: job.output), options: .atomic)
                print("{\"ok\":true}")
            } catch {
                let response = ["error": error.localizedDescription]
                print(String(decoding: try! JSONEncoder().encode(response), as: UTF8.self))
            }
            fflush(stdout)
        }
    }
}
