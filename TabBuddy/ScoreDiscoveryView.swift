import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Public source links, not a mirrored catalog. Search terms are explicitly sent
/// to the web only when the user opens a source.
struct ScoreSource: Identifiable {
    let id: String
    let name: String
    let website: String
    let searchDomain: String
    let description: String
    let formats: String
    let access: String
    let instruments: Set<Instrument> // Empty means a general sheet-music source.

    func supports(_ instrument: Instrument?) -> Bool {
        guard let instrument else { return true }
        return instruments.isEmpty || instruments.contains(instrument)
    }

    func searchURL(query: String, instrument: Instrument?) -> URL {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return URL(string: website)! }
        var url = URLComponents(string: "https://duckduckgo.com/")!
        let instrumentTerm = instrument == .unknown ? nil : instrument?.label
        url.queryItems = [URLQueryItem(name: "q", value:
            (["site:\(searchDomain)", query, instrumentTerm].compactMap { $0 }).joined(separator: " "))]
        return url.url!
    }

    static let all: [ScoreSource] = [
        .init(id: "classtab", name: "ClassTab", website: "https://www.classtab.org/", searchDomain: "classtab.org",
              description: "Classical guitar, by composer and piece.", formats: "Text tabs", access: "Free", instruments: [.guitar]),
        .init(id: "gametabs", name: "GameTabs", website: "https://gametabs.net/tabs", searchDomain: "gametabs.net/tabs",
              description: "Game and anime arrangements.", formats: "Text · Guitar Pro · PDF", access: "Free · Login for files", instruments: [.guitar, .bass, .ukulele, .mandolin, .banjo]),
        .init(id: "gprotab", name: "GProTab", website: "https://gprotab.net/", searchDomain: "gprotab.net/en/tabs",
              description: "Community Guitar Pro arrangements and parts.", formats: "Guitar Pro", access: "Free", instruments: []),
        .init(id: "mutopia", name: "Mutopia", website: "https://www.mutopiaproject.org/", searchDomain: "mutopiaproject.org",
              description: "Classical scores for solo instruments and ensembles.", formats: "PDF", access: "Free · Open licenses", instruments: []),
        .init(id: "openscore", name: "OpenScore Lieder", website: "https://github.com/OpenScore/Lieder", searchDomain: "musescore.com/openscore-lieder-corpus",
              description: "Voice and piano. Repository scores need export to PDF before import.", formats: "MuseScore · PDF exports", access: "Free · CC0 corpus", instruments: [.voice, .piano]),
        .init(id: "imslp", name: "IMSLP", website: "https://imslp.org/", searchDomain: "imslp.org/wiki",
              description: "Classical scores and parts. Availability varies by edition and country.", formats: "PDF", access: "Free options", instruments: []),
        .init(id: "sheethappens", name: "Sheet Happens", website: "https://www.sheethappenspublishing.com/", searchDomain: "sheethappenspublishing.com",
              description: "Artist-approved transcription books with downloadable files.", formats: "Guitar Pro · PDF", access: "Purchase", instruments: [.guitar, .bass]),
        .init(id: "musicnotes", name: "Musicnotes", website: "https://www.musicnotes.com/", searchDomain: "musicnotes.com/sheetmusic",
              description: "Published arrangements. Check PDF availability before purchasing.", formats: "PDF where offered", access: "Purchase · PDF may cost extra", instruments: [])
    ]
}

struct ScoreDiscoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @State var query = ""
    @State var instrumentRaw = ""
    let onImport: () -> Void

    private var instrument: Instrument? { Instrument(rawValue: instrumentRaw) }
    private var sources: [ScoreSource] { ScoreSource.all.filter { $0.supports(instrument) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Song, composer, artist, or game", text: $query)
                        .autocorrectionDisabled()
                    Picker("Instrument", selection: $instrumentRaw) {
                        Text("All instruments").tag("")
                        ForEach(Instrument.allCases.filter { $0 != .unknown }, id: \.rawValue) { item in
                            Text(item.label).tag(item.rawValue)
                        }
                    }
                } footer: {
                    Text("Choose a source to browse, or enter a title to search that source with DuckDuckGo.")
                }
                Section("Sources") {
                    ForEach(sources) { source in
                        Link(destination: source.searchURL(query: query, instrument: instrument)) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(source.name).font(.headline)
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.caption)
                                }
                                Text(source.description).font(.subheadline).foregroundStyle(.secondary)
                                Text(source.formats + " · " + source.access).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.foregroundStyle(DS.fg1)
                    }
                }
                Section {
                    Button(action: onImport) { Label("Import Downloaded Files", systemImage: "square.and.arrow.down") }
                } footer: {
                    Text("Download a PDF, text tab, or Guitar Pro file from the source, then import it here or share it to TabBuddy. Purchases and accounts stay with the source.")
                }
            }
            .navigationTitle("Find music")
            .onAppear { if instrumentRaw == Instrument.unknown.rawValue { instrumentRaw = "" } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct ScoreDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let file: FileItem
    @State private var title: String
    @State private var artist: String
    @State private var copyright: String
    @State private var isSaving = false
    @State private var instruments: Set<Instrument>
    @State private var tuning: String
    @State private var composer: String
    @State private var arranger: String
    @State private var collection: String
    @State private var arrangement: String
    @State private var sourceName: String
    @State private var sourceURL: String
    @State private var error: String?

    init(file: FileItem) {
        self.file = file
        _title = State(initialValue: file.displayTitle)
        _artist = State(initialValue: file.artist ?? "")
        _copyright = State(initialValue: file.copyrightNotice ?? "")
        _tuning = State(initialValue: file.tuning ?? "")
        _instruments = State(initialValue: Set(file.instrumentKinds.filter { $0 != .unknown }))
        _composer = State(initialValue: file.composer ?? "")
        _arranger = State(initialValue: file.arranger ?? "")
        _collection = State(initialValue: file.collectionTitle ?? "")
        _arrangement = State(initialValue: file.arrangement ?? "")
        _sourceName = State(initialValue: file.sourceName ?? "")
        _sourceURL = State(initialValue: file.sourceURL ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Instruments in this arrangement") {
                    ForEach(instruments.sorted { $0.label < $1.label }, id: \.rawValue) { instrument in
                        HStack {
                            Label(instrument.label, systemImage: instrument.symbol)
                            Spacer()
                            Button { instruments.remove(instrument) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove \(instrument.label)").buttonStyle(.borderless)
                        }
                    }
                    Menu {
                        ForEach(Instrument.allCases.filter { $0 != .unknown && !instruments.contains($0) }, id: \.rawValue) { instrument in
                            Button(instrument.label) { instruments.insert(instrument) }
                        }
                    } label: { Label("Add instrument", systemImage: "plus.circle") }

                }
                Section {
                    TextField("Tuning (name or string pitches)", text: $tuning)
                        .autocorrectionDisabled()
                    Menu("Choose tuning") {
                        ForEach(GuitarTuning.allPresets, id: \.name) { preset in
                            Button(preset.name) { tuning = preset.name }
                        }
                    }
                    if !tuning.isEmpty {
                        Button("Clear tuning") { tuning = "" }
                    }
                } header: { Text("Tuning") } footer: {
                    Text("Describe the arrangement’s tuning for library filtering and display. This does not change the score’s notes or retune its tracks.")
                }
                Section("Credits & arrangement") {
                    TextField("Title", text: $title)
                    TextField("Artist / performer", text: $artist)
                    TextField("Copyright / rights notice", text: $copyright)
                    TextField("Composer", text: $composer)
                    TextField("Arranger / transcriber", text: $arranger)
                    TextField("Game, album, or collection", text: $collection)
                    TextField("Arrangement (e.g. solo, duet, lead sheet)", text: $arrangement)
                }
                Section("Source") {
                    TextField("Source name", text: $sourceName)
                    TextField("Source page URL", text: $sourceURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                Section {
                    Text(EmbeddedScoreMetadata.canWrite(extension: (file.filename as NSString).pathExtension)
                         ? "Descriptive details are saved inside the score file. Practice history stays in your library."
                         : "These details are saved in your library. Writing this Guitar Pro format is not yet supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle(isSaving ? "Saving details…" : "Score details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
    }

    private func save() {
        func clean(_ value: String) -> String? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if let value = clean(sourceURL),
           URL(string: value)?.host == nil || !["https", "http"].contains(URL(string: value)?.scheme?.lowercased() ?? "") {
            error = "Enter a complete http or https source URL."
            return
        }
        var metadata = file.portableMetadata
        metadata.title = clean(title) ?? ""
        metadata.artist = clean(artist) ?? ""
        metadata.copyright = clean(copyright) ?? ""
        metadata.instruments = instruments.map(\.rawValue).sorted()
        metadata.tuning = clean(tuning) ?? ""
        metadata.composer = clean(composer) ?? ""
        metadata.arranger = clean(arranger) ?? ""
        metadata.collection = clean(collection) ?? ""
        metadata.arrangement = clean(arrangement) ?? ""
        metadata.sourceName = clean(sourceName) ?? ""
        metadata.sourceURL = clean(sourceURL) ?? ""
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                if EmbeddedScoreMetadata.canWrite(extension: (file.filename as NSString).pathExtension) {
                    try await LibraryManager.shared.saveMetadata(metadata, for: file, context: context)
                } else {
                    file.applyEmbeddedMetadata(metadata, overwrite: true)
                    file.metadataEdited = true
                }
                file.customTitle = nil
                try context.save()
                dismiss()
            } catch { self.error = "Could not save score details: \(error.localizedDescription)" }
        }
    }
}
