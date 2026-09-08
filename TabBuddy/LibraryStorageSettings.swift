import SwiftUI
import SwiftData

enum LibrarySettingsAction {
    case exportBackup, restoreBackup, removeAll, generateTabData, rescan, prepare
}

struct LibraryStorageSettings: View {
    @ObservedObject var libraryManager: LibraryManager
    var performLibraryAction: ((LibrarySettingsAction) -> Void)? = nil
    var isGeneratingTabData = false
    var chooseFolder: (ImportTarget) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

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
                    LabeledContent("Location", value: storageLocationLabel)
                    if libraryManager.isConfigured {
                        Toggle("Sync library with iCloud", isOn: Binding(
                            get: { libraryManager.mode == .managedICloud },
                            set: { enabled in libraryManager.moveLibrary(to: enabled ? .managedICloud : .managedLocal, context: context) }
                        ))
                        .disabled(libraryManager.isMoving || libraryManager.isProcessingLibrary || libraryManager.isRescanning || libraryManager.isPreparingOffline ||
                                  (libraryManager.iCloudAvailable != true && libraryManager.mode != .managedICloud))
                        if libraryManager.mode == .externalFolder {
                            Button("Use App Library on This Device") {
                                libraryManager.moveLibrary(to: .managedLocal, context: context)
                            }
                        }
                    }
                } header: { Text("Library Storage") } footer: {
                    Text("Sync songs, tags, favorites, and recent activity across devices. Turning this off keeps a local library and stops metadata sync on this device. Existing iCloud data is kept.")
                }
                if libraryManager.mode == .managedICloud {
                    Section {
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
                    } header: { Text("Offline Access") } footer: {
                        Text("Keep an additional copy of your songs on this device. Sync stays on. Turning this off removes only these extra offline copies.")
                    }
                }
                if libraryManager.iCloudAvailable != true {
                    Section {
                        Text("iCloud Drive is unavailable. You can use the local app library without an iCloud account.")
                            .foregroundStyle(.secondary)
                        Button("Check Again") { libraryManager.refreshStorageAvailability() }
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
                if let performLibraryAction {
                    Section("Library Maintenance") {
                        Toggle("Prepare library automatically", isOn: $libraryManager.automaticallyProcessesLibrary)
                        Text("Off by default. Prepare metadata and text tabs on demand, or enable preparation when the library opens. Individual scores still prepare when opened.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Prepare Library", systemImage: "doc.text.magnifyingglass") {
                            performLibraryAction(.prepare)
                            dismiss()
                        }.disabled(!libraryManager.isConfigured || libraryManager.isProcessingLibrary || libraryManager.isRescanning || isGeneratingTabData)

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
                        }
                    }
                }
                Section {
                    DisclosureGroup("Advanced") {
                        Button("Use Existing Folder…") {
                            chooseFolder(.existingLibrary)
                            dismiss()
                        }
                        Text("Use the selected folder directly and find the scores already inside it. Your previous library stays intact. The folder’s provider handles file sync; TabBuddy metadata sync is off.")
                            .font(.caption).foregroundStyle(.secondary)
                        if libraryManager.isConfigured {
                            Button("Copy Library to New Folder…") {
                                chooseFolder(.moveDestination)
                                dismiss()
                            }
                            Text("Create a Tab Buddy Library subfolder inside the selected location and copy your current songs into it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if libraryManager.mode == .externalFolder {
                            Button("Reconnect Folder…") {
                                chooseFolder(.externalLibrary)
                                dismiss()
                            }
                        }
                    }
                }.disabled(libraryManager.isMoving || libraryManager.isProcessingLibrary || libraryManager.isRescanning || libraryManager.isPreparingOffline)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var storageLocationLabel: String {
        switch libraryManager.mode {
        case .managedLocal: return "On This Device"
        case .managedICloud: return "iCloud Drive"
        case .externalFolder: return libraryManager.libraryName ?? "Custom Folder"
        case nil: return "Not Set Up"
        }
    }

}
