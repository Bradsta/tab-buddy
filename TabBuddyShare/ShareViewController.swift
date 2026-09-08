//
//  ShareViewController.swift
//  TabBuddyShare
//
//  Created by Hunter Weeks on 3/7/26.
//

import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let appGroupID = "group.com.gamicarts.TabBuddy.shared"
    private let pendingDir = "PendingImports"

    private let spinner = UIActivityIndicatorView(style: .large)
    private let label = UILabel()
    private let nameField = UITextField()
    private let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    /// Loaded file URLs staged in a temp location, waiting for the user to confirm a name.
    private var stagedFiles: [(tempURL: URL, originalName: String)] = []
    private var pendingURL: URL?
    private var attachmentLoadError: Error?

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        // Spinner (shown while loading attachments)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Loading..."
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        view.addSubview(label)

        // Name field (hidden until attachments are loaded)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.borderStyle = .roundedRect
        nameField.placeholder = "Tab name"
        nameField.font = .preferredFont(forTextStyle: .body)
        nameField.returnKeyType = .done
        nameField.clearButtonMode = .whileEditing
        nameField.addTarget(self, action: #selector(nameFieldReturn), for: .editingDidEndOnExit)
        nameField.isHidden = true
        view.addSubview(nameField)

        let nameLabel = UILabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.text = "Name this tab:"
        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.textColor = .secondaryLabel
        nameLabel.isHidden = true
        nameLabel.tag = 100
        view.addSubview(nameLabel)

        // Buttons
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setTitle("Save to TabBuddy", for: .normal)
        saveButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        saveButton.isHidden = true
        view.addSubview(saveButton)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.isHidden = true
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            nameLabel.bottomAnchor.constraint(equalTo: nameField.topAnchor, constant: -6),

            nameField.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            nameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            nameField.heightAnchor.constraint(equalToConstant: 44),

            saveButton.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 20),
            saveButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            cancelButton.topAnchor.constraint(equalTo: saveButton.bottomAnchor, constant: 12),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        loadAttachments()
    }

    // MARK: - Load attachments into temp staging area

    private func loadAttachments() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            done()
            return
        }

        pendingURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(pendingDir)

        guard let pendingURL else {
            showLoadError(NSError(
                domain: "TabBuddy.ShareExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The shared import folder is unavailable."]
            ))
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: pendingURL,
                withIntermediateDirectories: true
            )
        } catch {
            showLoadError(error)
            return
        }

        let group = DispatchGroup()

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if let type = GuitarProFileType.contentTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                    group.enter()
                    stageFile(provider: provider, type: type) { group.leave() }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    group.enter()
                    stageFile(provider: provider, type: UTType.pdf) {
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
                       provider.registeredTypeIdentifiers.contains("public.file-url") {
                        group.enter()
                        stageFile(provider: provider, type: UTType.plainText) {
                            group.leave()
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.showNamePrompt()
        }
    }

    private func stageFile(
        provider: NSItemProvider,
        type: UTType,
        completion: @escaping () -> Void
    ) {
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, error in
            guard let url, error == nil else {
                let loadError = error ?? NSError(
                    domain: "TabBuddy.ShareExtension",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The attachment could not be loaded."]
                )
                DispatchQueue.main.async {
                    self?.attachmentLoadError = loadError
                    completion()
                }
                return
            }

            let originalName = url.lastPathComponent

            // Copy to a temp location so the file survives after this callback
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
            } catch {
                DispatchQueue.main.async {
                    self?.attachmentLoadError = error
                    completion()
                }
                return
            }

            DispatchQueue.main.async {
                self?.stagedFiles.append((tempURL: tmp, originalName: originalName))
                completion()
            }
        }
    }

    // MARK: - Name prompt UI

    private func showNamePrompt() {
        guard !stagedFiles.isEmpty else {
            showLoadError(attachmentLoadError ?? NSError(
                domain: "TabBuddy.ShareExtension",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "No supported PDF or text file was found."]
            ))
            return
        }

        spinner.stopAnimating()
        spinner.isHidden = true
        label.isHidden = true

        // Pre-fill with original filename (without extension)
        let firstName = stagedFiles[0].originalName
        let stem = (firstName as NSString).deletingPathExtension
        nameField.text = stem
        nameField.isHidden = false
        nameField.becomeFirstResponder()
        nameField.selectAll(nil)

        if let nameLabel = view.viewWithTag(100) {
            nameLabel.isHidden = false
        }
        saveButton.isHidden = false
        cancelButton.isHidden = false

        if let attachmentLoadError {
            showAlert(title: "Some Files Couldn’t Be Loaded", error: attachmentLoadError)
        }
    }

    @objc private func nameFieldReturn() {
        saveTapped()
    }

    @objc private func cancelTapped() {
        // Clean up temp files
        for staged in stagedFiles {
            try? FileManager.default.removeItem(at: staged.tempURL)
        }
        extensionContext?.cancelRequest(withError:
            NSError(domain: "TabBuddy", code: 0, userInfo: nil))
    }

    @objc private func saveTapped() {
        guard let pendingURL else {
            showSaveError(NSError(
                domain: "TabBuddy.ShareExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The shared import folder is unavailable."]
            ))
            return
        }

        let chosenName = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = false
        nameField.isEnabled = false
        var movedFiles: [(source: URL, destination: URL)] = []

        do {
            for (index, staged) in stagedFiles.enumerated() {
                let ext = staged.tempURL.pathExtension
                let originalStem = (staged.originalName as NSString).deletingPathExtension
                let requestedBaseName: String
                if !chosenName.isEmpty && stagedFiles.count == 1 {
                    requestedBaseName = chosenName
                } else if !chosenName.isEmpty {
                    requestedBaseName = "\(chosenName) \(index + 1)"
                } else {
                    requestedBaseName = originalStem
                }

                let baseName = sanitizedBaseName(requestedBaseName,
                                                 fallback: originalStem)
                var requested = pendingURL.appendingPathComponent(baseName)
                if !ext.isEmpty { requested.appendPathExtension(ext) }
                let destination = availableDestination(for: requested)
                try FileManager.default.moveItem(at: staged.tempURL, to: destination)
                movedFiles.append((source: staged.tempURL, destination: destination))
            }
        } catch {
            // Restore the staging area so the user can retry. If a rollback
            // itself fails, the successfully moved file remains pending for
            // the main app instead of being deleted.
            for moved in movedFiles.reversed() {
                try? FileManager.default.moveItem(at: moved.destination, to: moved.source)
            }
            saveButton.isEnabled = true
            nameField.isEnabled = true
            showSaveError(error)
            return
        }

        done()
    }

    private func sanitizedBaseName(_ requested: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let components = requested.components(separatedBy: invalid)
            .filter { !$0.isEmpty }
        let sanitized = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ".")
            ))
        if !sanitized.isEmpty { return sanitized }

        let fallbackComponents = fallback.components(separatedBy: invalid)
            .filter { !$0.isEmpty }
        let sanitizedFallback = fallbackComponents.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ".")
            ))
        return sanitizedFallback.isEmpty ? "Shared Tab" : sanitizedFallback
    }

    private func availableDestination(for requested: URL) -> URL {
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let directory = requested.deletingLastPathComponent()
        let ext = requested.pathExtension
        let stem = requested.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            var candidate = directory.appendingPathComponent("\(stem) (\(counter))")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private func showSaveError(_ error: Error) {
        showAlert(title: "Couldn’t Save Tab", error: error)
    }

    private func showLoadError(_ error: Error) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = "Couldn’t load this tab."
        cancelButton.isHidden = false
        let alert = UIAlertController(
            title: "Couldn’t Load Tab",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in
            self?.cancelTapped()
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, error: Error) {
        let alert = UIAlertController(
            title: title,
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
