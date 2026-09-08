import Foundation
import SwiftData

/// UI-facing import progress. Every import copies into the single active root;
/// adding files in place is done by placing them under an external root and
/// refreshing the library.
@MainActor
final class FolderImporter: ObservableObject {
    @Published var total = 0
    @Published var processed = 0
    @Published var isRunning = false
    @Published var lastError: String?

    private var task: Task<Void, Never>?
    private var taskID: UUID?

    func start(urls: [URL], context: ModelContext) {
        startWithLibraryCopy(urls: urls, context: context,
                             libraryManager: .shared)
    }

    func startWithLibraryCopy(urls: [URL], context: ModelContext,
                              libraryManager: LibraryManager) {
        cancel()
        total = 0
        processed = 0
        isRunning = true
        lastError = nil
        let currentTaskID = UUID()
        taskID = currentTaskID

        // Retain the picker grant before returning from its completion handler.
        let sourceLeases = urls.map { url in
            let scoped = url.startAccessingSecurityScopedResource()
            return FileAccessLease(url: url, release: scoped ? { url.stopAccessingSecurityScopedResource() } : nil)
        }
        task = Task {
            defer { sourceLeases.forEach { $0.close() } }
            do {
                _ = try await libraryManager.importFiles(urls, context: context) { done, count in
                    await MainActor.run {
                        guard self.taskID == currentTaskID else { return }
                        self.processed = done
                        self.total = count
                    }
                }
            } catch is CancellationError {
                // Successfully committed files remain; temporary files are removed.
            } catch {
                if taskID == currentTaskID {
                    lastError = error.localizedDescription
                }
            }
            guard taskID == currentTaskID else { return }
            isRunning = false
            task = nil
            taskID = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        taskID = nil
        isRunning = false
    }
}
