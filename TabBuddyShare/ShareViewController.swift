import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let appGroupID = "group.com.gamicarts.TabBuddy"
    private let pendingDir = "PendingImports"

    private let spinner = UIActivityIndicatorView(style: .large)
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Saving to TabBuddy..."
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        view.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        processAttachments()
    }

    private func processAttachments() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            done()
            return
        }

        let pendingURL = FileManager.default
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
                    loadAndCopy(provider: provider, type: UTType.pdf, destination: pendingURL) {
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    // Check if it's a file (not inline text)
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
                       provider.registeredTypeIdentifiers.contains("public.file-url") {
                        group.enter()
                        loadAndCopy(provider: provider, type: UTType.plainText, destination: pendingURL) {
                            group.leave()
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.done()
        }
    }

    private func loadAndCopy(
        provider: NSItemProvider,
        type: UTType,
        destination: URL,
        completion: @escaping () -> Void
    ) {
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
            defer { completion() }
            guard let url, error == nil else { return }

            let filename = url.lastPathComponent
            let dest = destination.appendingPathComponent(filename)

            // Avoid overwriting
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: url, to: dest)
            }
        }
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
