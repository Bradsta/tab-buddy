//
//  ShareViewController.swift
//  TabBuddyShare
//
//  Created by Hunter Weeks on 3/7/26.
//

import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let appGroupID = "group.com.gamicarts.TabBuddy"
    private let pendingDir = "PendingImports"

    private let spinner = UIActivityIndicatorView(style: .large)
    private let label = UILabel()
    private let nameField = UITextField()
    private let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    /// Loaded file URLs staged in a temp location, waiting for the user to confirm a name.
    private var stagedFiles: [(tempURL: URL, originalName: String)] = []
    private var pendingURL: URL?

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
            done()
            return
        }

        try? FileManager.default.createDirectory(
            at: pendingURL,
            withIntermediateDirectories: true
        )

        let group = DispatchGroup()

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
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
            defer { completion() }
            guard let url, error == nil else { return }

            let originalName = url.lastPathComponent

            // Copy to a temp location so the file survives after this callback
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            try? FileManager.default.copyItem(at: url, to: tmp)

            DispatchQueue.main.async {
                self?.stagedFiles.append((tempURL: tmp, originalName: originalName))
            }
        }
    }

    // MARK: - Name prompt UI

    private func showNamePrompt() {
        guard !stagedFiles.isEmpty else {
            done()
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
        guard let pendingURL else { done(); return }

        let chosenName = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        for (index, staged) in stagedFiles.enumerated() {
            let ext = staged.tempURL.pathExtension
            let baseName: String
            if !chosenName.isEmpty && stagedFiles.count == 1 {
                baseName = chosenName
            } else if !chosenName.isEmpty {
                baseName = "\(chosenName) \(index + 1)"
            } else {
                baseName = (staged.originalName as NSString).deletingPathExtension
            }

            let finalName = "\(baseName).\(ext)"
            let dest = pendingURL.appendingPathComponent(finalName)

            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.moveItem(at: staged.tempURL, to: dest)
            } else {
                try? FileManager.default.removeItem(at: staged.tempURL)
            }
        }

        done()
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
