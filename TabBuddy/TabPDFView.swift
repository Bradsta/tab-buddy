import SwiftUI
import PDFKit

struct TabPDFView: View {
    let url: URL
    @Binding var scrollViewProxy: UIScrollView?
    @State private var pdfDocument: PDFDocument? = nil
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var loadAttempt = 0
    @State private var isLightBackground = false
    @Environment(\.colorScheme) private var colorScheme

    private var shouldInvert: Bool {
        colorScheme == .dark && isLightBackground
    }

    var body: some View {
        ZStack {
            if let document = pdfDocument {
                if shouldInvert {
                    InternalPDFView(document: document,
                                   scrollViewProxy: $scrollViewProxy,
                                   forceWhiteBackground: true)
                        .colorInvert()
                } else {
                    InternalPDFView(document: document,
                                   scrollViewProxy: $scrollViewProxy,
                                   forceWhiteBackground: false)
                }
            } else if isLoading {
                ProgressView("Loading PDF...")
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                VStack(spacing: 12) {
                    Text(loadError ?? "This file could not be read as a PDF.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { loadAttempt += 1 }
                }.padding()
            }
        }
        .task(id: "\(url.absoluteString)#\(loadAttempt)#\(colorScheme)") {
            await loadPDF()
        }
    }

    private func loadPDF() async {
        isLoading = true
        loadError = nil
        pdfDocument = nil
        let source = url
        let inspectBackground = colorScheme == .dark
        let access = PDFReadCoordinator()
        let work = Task.detached(priority: .userInitiated) {
            var error: NSError?
            var data: Data?
            var readError: Error?
            access.coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &error) { readableURL in
                do {
                    try Task.checkCancellation()
                    data = try Data(contentsOf: readableURL)
                } catch { readError = error }
            }
            try Task.checkCancellation()
            if let error { throw error }
            if let readError { throw readError }
            guard let data, let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            // The document owns the bytes after coordination ends; PDFKit can lazily
            // render pages without depending on a provider URL or an expired lease.
            return LoadedPDF(document: document, isLight: inspectBackground && Self.hasLightBackground(document))
        }
        do {
            let loaded = try await withTaskCancellationHandler { try await work.value } onCancel: {
                access.coordinator.cancel()
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            pdfDocument = loaded.document
            isLightBackground = loaded.isLight
            isLoading = false
            PerfTrace.endAfterCommit("open", "pdf")
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    /// Renders a small thumbnail of the first page and samples border pixels
    /// to decide whether the PDF has a light (white) background.
    private static func hasLightBackground(_ document: PDFDocument) -> Bool {
        guard let page = document.page(at: 0) else { return false }
        let size = CGSize(width: 36, height: 36)
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = thumb.cgImage else { return false }

        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return false }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cgImage, in: CGRect(origin: .zero,
                                     size: CGSize(width: w, height: h)))

        var brightness: CGFloat = 0
        var count = 0

        // sample top and bottom edges
        for x in stride(from: 0, to: w, by: max(1, w / 8)) {
            for y in [0, h - 1] {
                let i = (y * w + x) * 4
                brightness += (CGFloat(pixels[i]) + CGFloat(pixels[i+1]) + CGFloat(pixels[i+2]))
                             / (3.0 * 255.0)
                count += 1
            }
        }
        // sample left and right edges
        for y in stride(from: 0, to: h, by: max(1, h / 8)) {
            for x in [0, w - 1] {
                let i = (y * w + x) * 4
                brightness += (CGFloat(pixels[i]) + CGFloat(pixels[i+1]) + CGFloat(pixels[i+2]))
                             / (3.0 * 255.0)
                count += 1
            }
        }

        return count > 0 && brightness / CGFloat(count) > 0.85
    }
}

private struct InternalPDFView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var scrollViewProxy: UIScrollView?
    var forceWhiteBackground: Bool

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical

        if forceWhiteBackground {
            pdfView.backgroundColor = .white
        }

        DispatchQueue.main.async {
            if let scrollView = pdfView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                self.scrollViewProxy = scrollView
            }
        }

        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document { uiView.document = document }
        if forceWhiteBackground {
            uiView.backgroundColor = .white
        }
    }
}

/// The worker owns document creation, then transfers exclusive use to the UI.
private struct LoadedPDF: @unchecked Sendable {
    let document: PDFDocument
    let isLight: Bool
}

/// Only cancellation crosses actors while the worker coordinates the read.
private final class PDFReadCoordinator: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
}
