import SwiftUI
import SwiftData

enum LibrarySettingsAction {
    case exportBackup, restoreBackup, removeAll, generateTabData, rescan, prepare
}

/// The three library options as one selectable list, each with a one-line
/// description. Shared by first-run setup and Settings.
struct LibraryStorageOptionList: View {
    let selected: LibraryStorageOption?
    let iCloudAvailable: Bool
    var isDisabled = false
    let select: (LibraryStorageOption) -> Void

    var body: some View {
        ForEach(LibraryStorageOption.allCases) { option in
            let unavailable = option == .iCloudOnly && !iCloudAvailable
            Button { select(option) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: option.symbol)
                        .frame(width: 28)
                        .foregroundStyle(unavailable ? Color.secondary : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title).font(.body.weight(.semibold))
                        Text(unavailable ? "Needs iCloud Drive on this device." : option.summary)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if selected == option {
                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled || unavailable)
            .opacity(unavailable ? 0.6 : 1)
            .accessibilityAddTraits(selected == option ? .isSelected : [])
        }
    }
}

struct LibraryStorageSettings: View {
    @ObservedObject var libraryManager: LibraryManager
    var performLibraryAction: ((LibrarySettingsAction) -> Void)? = nil
    var isGeneratingTabData = false
    var chooseFolder: (ImportTarget) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pendingOption: LibraryStorageOption?
    @State private var showsMoreOptions = false
    @State private var confirmsMarkerResolve = false

    private var isBusy: Bool {
        libraryManager.isMoving || libraryManager.isProcessingLibrary || libraryManager.isRescanning ||
        libraryManager.isPreparingOffline || libraryManager.isConfiguring || libraryManager.isRemoving ||
        libraryManager.isMergingDuplicates
    }

    var body: some View {
        NavigationStack {
            Form {
                if libraryManager.isProcessingLibrary {
                    Section {
                        Button("Pause Library Processing") { libraryManager.pauseBackgroundProcessing() }
                        Text("Pause preparation before changing library storage.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    LibraryStorageOptionList(selected: libraryManager.storageOption,
                                             iCloudAvailable: libraryManager.iCloudAvailable == true,
                                             isDisabled: isBusy, select: request)
                } header: { Text("Library") } footer: {
                    Text("Library info means tags, favorites, recents, play counts, and score details. Changing options never copies songs; each option shows the songs in its own location.")
                }
                if libraryManager.isConfigured { locationSection }
                if libraryManager.iCloudAvailable == false {
                    Section {
                        Text("iCloud is unavailable on this device. Local only works without it; with Hybrid, library info stays on this device until iCloud is back.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Check Again") { libraryManager.refreshStorageAvailability(force: true) }
                    }
                }
                if libraryManager.isMoving {
                    Section {
                        ProgressView("Copying and verifying songs…", value: Double(libraryManager.moveProcessed), total: Double(max(1, libraryManager.moveTotal)))
                        Button("Cancel", role: .cancel) { libraryManager.cancelMove() }
                    }
                }
                if let error = libraryManager.lastError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let names = libraryManager.markerConflictNames {
                    Section {
                        Button("Resolve Library Marker…") { confirmsMarkerResolve = true }.disabled(isBusy)
                    } footer: {
                        Text("iCloud Drive kept more than one library marker (\(names.joined(separator: ", "))). Resolve keeps the one for this library and moves the others to the Trash.")
                    }
                }
                if let performLibraryAction {
                    Section("Library Maintenance") {
                        Toggle("Prepare library automatically", isOn: $libraryManager.automaticallyProcessesLibrary)
                        Text("Off by default. Prepare metadata and text tabs on demand, or enable preparation when the library opens. Individual scores still prepare when opened.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Prepare Library", systemImage: "doc.text.magnifyingglass") {
                            performLibraryAction(.prepare)
                            dismiss()
                        }.disabled(!libraryManager.isConfigured || libraryManager.isProcessingLibrary || libraryManager.isRescanning
                                   || libraryManager.isMergingDuplicates || isGeneratingTabData)

                        Button("Rescan Library", systemImage: "arrow.clockwise") {
                            performLibraryAction(.rescan)
                            dismiss()
                        }.disabled(!libraryManager.isConfigured || libraryManager.isRescanning)
                        Button("Generate Tab Data", systemImage: "wand.and.stars") {
                            performLibraryAction(.generateTabData)
                            dismiss()
                        }.disabled(!libraryManager.isConfigured || isGeneratingTabData)
                    }
                    Section {
                        Button("Export Backup", systemImage: "square.and.arrow.up") {
                            performLibraryAction(.exportBackup)
                            dismiss()
                        }
                        Button("Restore Backup", systemImage: "square.and.arrow.down") {
                            performLibraryAction(.restoreBackup)
                            dismiss()
                        }
                    } header: { Text("Metadata Backup") } footer: {
                        Text("Back up library details and practice settings. Song files are stored separately.")
                    }
                    Section {
                        Button("Remove All Files", role: .destructive) {
                            performLibraryAction(.removeAll)
                            dismiss()
                        }.disabled(!libraryManager.isConfigured)
                    }
                }
                if libraryManager.isConfigured {
                    Section {
                        DisclosureGroup("More Storage Options", isExpanded: $showsMoreOptions) { moreOptions }
                    } footer: {
                        Text("Less common storage actions.")
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Resolve library marker?", isPresented: $confirmsMarkerResolve) {
                Button("Keep This Library’s Marker", role: .destructive) {
                    Task { await libraryManager.resolveMarkerConflict() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Keeps the marker that matches this library. The other marker copies (\((libraryManager.markerConflictNames ?? []).joined(separator: ", "))) move to the Trash; nothing is permanently deleted. Your other device may then ask you to choose the folder again.")
            }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-LibraryMoreOptionsOpen") { showsMoreOptions = true }
            }
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert(pendingOption.map { "Switch to \($0.title)?" } ?? "",
                   isPresented: Binding(get: { pendingOption != nil }, set: { if !$0 { pendingOption = nil } }),
                   presenting: pendingOption) { option in
                if libraryManager.offersBackupBeforeSwitching(to: option), let performLibraryAction {
                    // First sync on this device: save a metadata backup, then switch afterwards.
                    Button("Export a Library Backup First") {
                        pendingOption = nil
                        performLibraryAction(.exportBackup)
                        dismiss()
                    }
                }
                Button(libraryManager.plannedLocation(for: option) == nil ? "Choose Folder…" : "Switch") { confirm(option) }
                Button("Cancel", role: .cancel) { }
            } message: { option in
                Text(libraryManager.switchConfirmation(to: option, context: context))
            }
        }
    }

    // MARK: - Current location

    @ViewBuilder
    private var locationSection: some View {
        Section {
            LabeledContent("Songs", value: songsLocation)
            LabeledContent("Library info", value: libraryInfoStatus)
            switch libraryManager.storageOption {
            case .localOnly:
                if libraryManager.mode == .externalFolder {
                    Button("Change Folder…") { chooseFolder(.localFolder); dismiss() }.disabled(isBusy)
                    Button("Use App Folder Instead") { libraryManager.useAppFolder(context: context) }.disabled(isBusy)
                } else {
                    Button("Choose Folder…") { chooseFolder(.localFolder); dismiss() }.disabled(isBusy)
                }
            case .hybrid:
                Button("Change Folder…") { chooseFolder(.hybridFolder); dismiss() }.disabled(isBusy)
            case .iCloudOnly, nil:
                EmptyView()
            }
        } header: { Text("Current Location") } footer: {
            if libraryManager.storageOption == .hybrid {
                Text("Choose the same folder on each device. Songs not in this device’s folder are hidden here, not deleted.")
            }
        }
    }

    private var songsLocation: String {
        switch libraryManager.mode {
        case .managedLocal: return "On This Device"
        case .managedICloud: return "TabBuddy iCloud Library"
        case .externalFolder: return libraryManager.libraryName ?? "Chosen Folder"
        case nil: return "Not Set Up"
        }
    }

    private var libraryInfoStatus: String {
        guard libraryManager.storageOption?.syncsMetadata == true else { return "On This Device" }
        return libraryManager.iCloudAvailable == false ? "Waiting for iCloud" : "Syncs with iCloud"
    }

    // MARK: - More storage options

    @ViewBuilder
    private var moreOptions: some View {
        if libraryManager.isCloudBackedLocation {
            Toggle("Keep available offline", isOn: Binding(
                get: { libraryManager.keepAvailableOffline },
                set: { libraryManager.setKeepAvailableOffline($0, context: context) }
            ))
            .disabled(libraryManager.isMoving)
            if libraryManager.isPreparingOffline {
                ProgressView("Downloading songs…", value: Double(libraryManager.offlineProcessed),
                             total: Double(max(1, libraryManager.offlineTotal)))
            } else if libraryManager.keepAvailableOffline {
                Button("Refresh Downloads") { libraryManager.refreshOfflineCopies(context: context) }
            }
            Text("Keeps an extra copy of each song on this device for playing without a connection. Turning this off removes only the extra copies.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if libraryManager.mode == .externalFolder {
            Button("Reconnect Folder…") { chooseFolder(.externalLibrary); dismiss() }.disabled(isBusy)
            Text("Renews this device’s access to the current folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Button("Copy Library to New Folder…") { chooseFolder(.moveDestination); dismiss() }.disabled(isBusy)
        Text(libraryManager.storageOption == .iCloudOnly
             ? "Copies your songs into a new Tab Buddy Library folder in the location you pick, then switches to Hybrid with that folder. The current songs stay where they are."
             : "Copies your songs into a new Tab Buddy Library folder in the location you pick, then shows the library from there. The current songs stay where they are.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Switching

    private func request(_ option: LibraryStorageOption) {
        guard libraryManager.isConfigured else {
            // First setup from Settings mirrors the first-run choice.
            switch option {
            case .localOnly: libraryManager.configureManaged(context: context, useICloud: false)
            case .iCloudOnly: libraryManager.configureManaged(context: context, useICloud: true)
            case .hybrid: chooseFolder(.hybridFolder); dismiss()
            }
            return
        }
        guard option != libraryManager.storageOption else { return }
        pendingOption = option
    }

    private func confirm(_ option: LibraryStorageOption) {
        pendingOption = nil
        if libraryManager.switchStorageOption(to: option, context: context) == .needsFolder {
            chooseFolder(.hybridFolder)
            dismiss()
        }
    }
}
